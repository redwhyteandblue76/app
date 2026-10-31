-- 12one host dashboard migration 015. Install on staging before live.
begin;
create table if not exists public.host_profiles (
 user_id uuid primary key references auth.users(id) on delete cascade,
 full_name text not null check (length(full_name) between 2 and 120)
);
alter table public.host_profiles enable row level security;
revoke all on public.host_profiles from anon;
grant select,insert,update on public.host_profiles to authenticated;
drop policy if exists host_profile_self on public.host_profiles;
create policy host_profile_self on public.host_profiles for all to authenticated
using (user_id=(select auth.uid())) with check (user_id=(select auth.uid()));

alter table public.games add column if not exists archived_at timestamptz;
create table if not exists public.host_events (
 id bigint generated always as identity primary key,
 game_id uuid references public.games(id) on delete set null,
 host_id uuid,
 action text not null,
 game_name text not null,
 details text not null default '',
 occurred_at timestamptz not null default now()
);
alter table public.host_events enable row level security;
revoke all on public.host_events from anon,authenticated;

create or replace function public.host_manage_game(p_game_id uuid,p_action text,p_value text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare g public.games%rowtype; v_admin boolean; v_label text;
begin
 select * into g from public.games where id=p_game_id for update;
 if not found then raise exception 'Game not found';end if;
 v_admin:=public.is_platform_admin();
 if g.owner_user_id is distinct from (select auth.uid()) and not v_admin then raise exception 'Host only';end if;
 if p_action='rename' then
  if g.owner_user_id is distinct from (select auth.uid()) then raise exception 'Only the host may rename';end if;
  if length(trim(p_value)) not between 2 and 100 then raise exception 'Game name must be 2-100 characters';end if;
  update public.games set name=trim(p_value) where id=p_game_id;
  v_label:='Renamed to '||trim(p_value);
 elsif p_action='end' then
  if g.status='finished' then raise exception 'Game already finished';end if;
  update public.games set status='finished' where id=p_game_id;
  if g.game_type='assassins' then
    update public.assassins_config set paused=true,signup_enabled=false,eliminate_enabled=false where game_id=p_game_id;
  elsif g.game_type='mafia' then
    update public.mafia_config set game_active=false,setup_enabled=false where game_id=p_game_id;
  end if;
  v_label:='Ended game';
 elsif p_action='archive' then
  if g.status<>'finished' then raise exception 'End game before archiving';end if;
  update public.games set archived_at=now() where id=p_game_id;
  v_label:='Archived game';
 elsif p_action='restore' then
  update public.games set archived_at=null where id=p_game_id;
  v_label:='Restored archived game';
 elsif p_action='delete' then
  if g.status<>'finished' then raise exception 'End game before permanent deletion';end if;
  -- Keep the consumed credit spent; unlink it before deleting its game.
  update public.game_credits set consumed_by_game_id=null where consumed_by_game_id=p_game_id;
  delete from public.games where id=p_game_id;
  v_label:='Permanently deleted game';
 else raise exception 'Unsupported game action';end if;
 insert into public.host_events(game_id,host_id,action,game_name,details)
 values(case when p_action='delete' then null else p_game_id end,
 (select auth.uid()),p_action,g.name,v_label);
 return jsonb_build_object('success',true);
end $$;

create or replace function public.host_admin_directory()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_hosts jsonb;v_games jsonb;
begin
 if not public.is_platform_admin() then raise exception 'Administrator only';end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',u.id,'name',coalesce(h.full_name,u.raw_user_meta_data->>'full_name',''),
 'email',u.email,'created_at',u.created_at,'game_count',(select count(*) from public.games where owner_user_id=u.id))
 order by u.created_at desc),'[]'::jsonb)
 into v_hosts from auth.users u left join public.host_profiles h on h.user_id=u.id
 where coalesce(u.is_anonymous,false)=false;
 select coalesce(jsonb_agg(jsonb_build_object('id',g.id,'name',g.name,'type',g.game_type,
 'code',g.game_code,'status',g.status,'created_at',g.created_at,'archived_at',g.archived_at,
 'host',coalesce(h.full_name,u.raw_user_meta_data->>'full_name',''),
 'host_email',u.email,'players',(select count(*) from public.game_memberships m where m.game_id=g.id))
 order by g.created_at desc),'[]'::jsonb)
 into v_games from public.games g join auth.users u on u.id=g.owner_user_id
 left join public.host_profiles h on h.user_id=u.id;
 return jsonb_build_object('hosts',v_hosts,'games',v_games);
end $$;

create or replace function public.host_export_game(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare g public.games%rowtype; v_players jsonb; v_events jsonb; v_feed jsonb;
begin
 select * into g from public.games where id=p_game_id;
 if not found then raise exception 'Game not found';end if;
 if g.owner_user_id is distinct from (select auth.uid()) and not public.is_platform_admin() then raise exception 'Host only';end if;
 select coalesce(jsonb_agg(jsonb_build_object('name',m.real_name,'codename',m.codename,'phone',m.phone,'hall',m.hall,
 'role',case when g.game_type='mafia' then mp.role else null end,
 'active',case when g.game_type='mafia' then mp.alive else ap.alive end)
 order by m.joined_at),'[]'::jsonb) into v_players
 from public.game_memberships m left join public.mafia_players mp on mp.game_id=m.game_id and mp.member_id=m.id
 left join public.assassins_players ap on ap.game_id=m.game_id and ap.member_id=m.id where m.game_id=p_game_id;
 select coalesce(jsonb_agg(jsonb_build_object('action',action,'details',details,'time',occurred_at)
 order by occurred_at),'[]'::jsonb) into v_events from public.host_events where game_id=p_game_id;
 if g.game_type='mafia' then
  select coalesce(jsonb_agg(jsonb_build_object('time',created_at,'event',event_type,'message',message)
  order by created_at),'[]'::jsonb) into v_feed from public.mafia_log where game_id=p_game_id;
 else
  select coalesce(jsonb_agg(jsonb_build_object('time',e.created_at,'assassin',a.real_name,'target',t.real_name)
  order by e.created_at),'[]'::jsonb) into v_feed
  from public.assassins_eliminations e join public.game_memberships a on a.id=e.assassin_id
  join public.game_memberships t on t.id=e.target_id where e.game_id=p_game_id;
 end if;
 return jsonb_build_object('game',jsonb_build_object('name',g.name,'code',g.game_code,
 'type',g.game_type,'status',g.status,'created_at',g.created_at),
 'players',v_players,'events',v_events,'game_log',v_feed);
end $$;

create or replace function public.host_player_contacts(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $
declare g public.games%rowtype; v jsonb;
begin
 select * into g from public.games where id=p_game_id;
 if not found then raise exception 'Game not found';end if;
 if g.owner_user_id is distinct from (select auth.uid()) and not public.is_platform_admin() then
 raise exception 'Host only';end if;
 select coalesce(jsonb_agg(jsonb_build_object('name',real_name,'codename',codename,
 'phone',phone,'hall',hall) order by joined_at),'[]'::jsonb)
 into v from public.game_memberships where game_id=p_game_id;
 return v;
end $;
revoke all on function public.host_player_contacts(uuid) from public,anon;
grant execute on function public.host_player_contacts(uuid) to authenticated;

revoke all on function public.host_manage_game(uuid,text,text),
 public.host_admin_directory(),public.host_export_game(uuid) from public,anon;
grant execute on function public.host_manage_game(uuid,text,text),
 public.host_admin_directory(),public.host_export_game(uuid) to authenticated;
commit;
