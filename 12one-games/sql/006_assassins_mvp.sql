-- Migration 006: Assassins 2.0 MVP. Run after migration 005.
-- No direct client access to hidden target assignments or elimination reports.
create table if not exists public.assassins_players (
 game_id uuid not null references public.games(id) on delete cascade,
 member_id uuid not null references public.game_memberships(id) on delete cascade,
 turn_order integer not null,
 alive boolean not null default true,
 primary key (game_id,member_id),
 unique (game_id,turn_order)
);
create table if not exists public.assassins_reports (
 id uuid primary key default gen_random_uuid(),
 game_id uuid not null references public.games(id) on delete cascade,
 reporter_member_id uuid not null references public.game_memberships(id),
 target_member_id uuid not null references public.game_memberships(id),
 status text not null default 'pending' check (status in ('pending','approved','rejected')),
 created_at timestamptz not null default now(),
 resolved_at timestamptz,
 resolved_by uuid references auth.users(id)
);
create unique index if not exists assassins_one_pending_per_reporter
 on public.assassins_reports(game_id,reporter_member_id) where status='pending';
create index if not exists assassins_reports_game_status on public.assassins_reports(game_id,status);
alter table public.assassins_players enable row level security;
alter table public.assassins_reports enable row level security;
revoke all on public.assassins_players,public.assassins_reports from anon,authenticated;

create or replace function public.assassins_target(p_game_id uuid,p_member_id uuid)
returns uuid language sql stable security definer set search_path='' as $$
 select coalesce(
  (select a.member_id from public.assassins_players a
   where a.game_id=p_game_id and a.alive
   and a.turn_order>(select turn_order from public.assassins_players where game_id=p_game_id and member_id=p_member_id and alive)
   order by a.turn_order limit 1),
  (select a.member_id from public.assassins_players a
   where a.game_id=p_game_id and a.alive order by a.turn_order limit 1)
 );
$$;
-- Internal helper: never expose arbitrary-member target lookup to clients.
revoke all on function public.assassins_target(uuid,uuid) from public,anon,authenticated;

create or replace function public.assassins_start(p_game_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v_game public.games%rowtype; v_count integer;
begin
 select * into v_game from public.games where id=p_game_id for update;
 if not found or v_game.owner_user_id is distinct from (select auth.uid()) then raise exception 'Host only'; end if;
 if v_game.game_type<>'assassins' or v_game.status<>'registration' then raise exception 'Open Assassins registration before starting'; end if;
 select count(*) into v_count from public.game_memberships where game_id=p_game_id;
 if v_count<3 then raise exception 'At least 3 players required'; end if;
 insert into public.assassins_players(game_id,member_id,turn_order)
 select p_game_id,m.id,row_number() over(order by gen_random_uuid())::integer
 from public.game_memberships m where m.game_id=p_game_id;
 update public.games set status='active' where id=p_game_id;
 insert into public.game_events(game_id,actor_user_id,event_type,details)
 values(p_game_id,(select auth.uid()),'assassins_started',jsonb_build_object('players',v_count));
end;
$$;

create or replace function public.assassins_report(p_game_id uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_game public.games%rowtype; v_me uuid; v_target uuid; v_report uuid;
begin
 select * into v_game from public.games where id=p_game_id for update;
 if not found or v_game.game_type<>'assassins' or v_game.status<>'active' then raise exception 'Game is not active'; end if;
 select m.id into v_me from public.game_memberships m join public.assassins_players a on a.member_id=m.id and a.game_id=p_game_id and a.alive
 where m.game_id=p_game_id and m.user_id=(select auth.uid());
 if v_me is null then raise exception 'Only active players can report'; end if;
 v_target:=public.assassins_target(p_game_id,v_me);
 if v_target=v_me then raise exception 'No target available'; end if;
 insert into public.assassins_reports(game_id,reporter_member_id,target_member_id)
 values(p_game_id,v_me,v_target) returning id into v_report;
 return v_report;
end;
$$;

create or replace function public.assassins_resolve(p_report_id uuid,p_approve boolean)
returns void language plpgsql security definer set search_path='' as $$
declare v_game_id uuid; v_report public.assassins_reports%rowtype; v_game public.games%rowtype; v_alive integer;
begin
 select game_id into v_game_id from public.assassins_reports where id=p_report_id;
 if v_game_id is null then raise exception 'Report not found'; end if;
 select * into v_game from public.games where id=v_game_id for update;
 if v_game.owner_user_id is distinct from (select auth.uid()) or v_game.status<>'active' or v_game.game_type<>'assassins' then raise exception 'Active game host only'; end if;
 select * into v_report from public.assassins_reports where id=p_report_id for update;
 if v_report.status<>'pending' then raise exception 'Report already resolved'; end if;
 if p_approve then
  if not exists(select 1 from public.assassins_players where game_id=v_game_id and member_id=v_report.reporter_member_id and alive)
   or not exists(select 1 from public.assassins_players where game_id=v_game_id and member_id=v_report.target_member_id and alive)
   or public.assassins_target(v_game_id,v_report.reporter_member_id) is distinct from v_report.target_member_id then
   raise exception 'Assignment changed; reject this stale report';
  end if;
  update public.assassins_players set alive=false where game_id=v_game_id and member_id=v_report.target_member_id;
 end if;
 update public.assassins_reports set status=case when p_approve then 'approved' else 'rejected' end,
 resolved_at=now(),resolved_by=(select auth.uid()) where id=p_report_id;
 if p_approve then
  update public.assassins_reports set status='rejected',resolved_at=now(),resolved_by=(select auth.uid())
  where game_id=v_game_id and status='pending' and id<>p_report_id;
  select count(*) into v_alive from public.assassins_players where game_id=v_game_id and alive;
  if v_alive<=1 then update public.games set status='finished' where id=v_game_id; end if;
 end if;
 insert into public.game_events(game_id,actor_user_id,event_type,details)
 values(v_game_id,(select auth.uid()),'assassins_report_resolved',jsonb_build_object('approved',p_approve));
end;
$$;

create or replace function public.assassins_state(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_owner boolean; v_me uuid; v_status text; v_data jsonb; v_target uuid;
begin
 select g.status,g.owner_user_id=(select auth.uid()) into v_status,v_owner
 from public.games g where g.id=p_game_id and g.game_type='assassins';
 if v_status is null or (select auth.uid()) is null then raise exception 'Game unavailable'; end if;
 select m.id into v_me from public.game_memberships m where m.game_id=p_game_id and m.user_id=(select auth.uid());
 if not coalesce(v_owner,false) and v_me is null then raise exception 'Not in game'; end if;
 select jsonb_agg(jsonb_build_object('codename',m.codename,'alive',coalesce(a.alive,true)) order by m.joined_at)
 into v_data from public.game_memberships m left join public.assassins_players a on a.member_id=m.id and a.game_id=p_game_id where m.game_id=p_game_id;
 v_target:=case when v_status='active' and v_me is not null and exists(select 1 from public.assassins_players where game_id=p_game_id and member_id=v_me and alive)
 then public.assassins_target(p_game_id,v_me) else null end;
 return jsonb_build_object(
  'status',v_status,'host',coalesce(v_owner,false),
  'players',coalesce(v_data,'[]'::jsonb),
  'my_alive',coalesce((select alive from public.assassins_players where game_id=p_game_id and member_id=v_me),false),
  'my_target',(select codename from public.game_memberships where id=v_target),
  'pending_reports',case when v_owner then coalesce((
   select jsonb_agg(jsonb_build_object('id',r.id,'reporter',rm.codename,'target',tm.codename,'created_at',r.created_at) order by r.created_at)
   from public.assassins_reports r
   join public.game_memberships rm on rm.id=r.reporter_member_id
   join public.game_memberships tm on tm.id=r.target_member_id
   where r.game_id=p_game_id and r.status='pending'
  ),'[]'::jsonb) else '[]'::jsonb end,
  'my_pending',exists(select 1 from public.assassins_reports where game_id=p_game_id and reporter_member_id=v_me and status='pending')
 );
end;
$$;

create or replace function public.assassins_remove_player(p_game_id uuid,p_codename text)
returns void language plpgsql security definer set search_path='' as $$
declare v_game public.games%rowtype;
begin
 select * into v_game from public.games where id=p_game_id for update;
 if not found or v_game.owner_user_id is distinct from (select auth.uid()) then raise exception 'Host only'; end if;
 if v_game.status not in ('draft','registration') then raise exception 'Players can only be removed before the game starts'; end if;
 delete from public.game_memberships where game_id=p_game_id and lower(codename)=lower(trim(p_codename));
 if not found then raise exception 'Player not found'; end if;
end;
$$;

revoke all on function public.assassins_start(uuid),public.assassins_report(uuid),public.assassins_resolve(uuid,boolean),public.assassins_state(uuid),public.assassins_remove_player(uuid,text) from public,anon;
grant execute on function public.assassins_start(uuid),public.assassins_report(uuid),public.assassins_resolve(uuid,boolean),public.assassins_state(uuid),public.assassins_remove_player(uuid,text) to authenticated;
