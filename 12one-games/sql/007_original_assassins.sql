-- Migration 007: Restore original Assassins gameplay per supplied Apps Script.
-- Run after 006. Each game is isolated by game_id; existing game data is preserved.
alter table public.game_memberships add column if not exists real_name text;
alter table public.game_memberships add column if not exists phone text;
alter table public.game_memberships add column if not exists hall text;
alter table public.assassins_players add column if not exists eliminated_by uuid;
alter table public.assassins_players add column if not exists eliminated_at timestamptz;
create table if not exists public.assassins_config (
 game_id uuid primary key references public.games(id) on delete cascade,
 dashboard_enabled boolean not null default true,
 eliminate_enabled boolean not null default true,
 phone_enabled boolean not null default false,
 hall_enabled boolean not null default false,
 hall_options text not null default '',
 instructions_enabled boolean not null default false,
 instruction_verification_enabled boolean not null default false,
 instructions_text text not null default '',
 paused boolean not null default false
);
alter table public.assassins_config enable row level security;
revoke all on public.assassins_config from anon,authenticated;
create table if not exists public.assassins_eliminations (
 id uuid primary key default gen_random_uuid(),
 game_id uuid not null references public.games(id) on delete cascade,
 assassin_id uuid not null references public.game_memberships(id),
 target_id uuid not null references public.game_memberships(id),
 created_at timestamptz not null default now()
);
create index if not exists assassins_eliminations_game_time on public.assassins_eliminations(game_id,created_at desc);
alter table public.assassins_eliminations enable row level security;
revoke all on public.assassins_eliminations from anon,authenticated;

-- The old public lobby RPC exposed every codename. Replace it with real names only.
drop function if exists public.list_game_lobby(uuid);
create function public.list_game_lobby(p_game_id uuid)
returns table(real_name text,joined_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
begin
 if (select auth.uid()) is null or not exists(
  select 1 from public.games where id=p_game_id and owner_user_id=(select auth.uid())
 ) and not exists(
  select 1 from public.game_memberships where game_id=p_game_id and user_id=(select auth.uid())
 ) then raise exception 'Not a participant'; end if;
 return query select coalesce(nullif(m.real_name,''),'Registered player')::text,m.joined_at
 from public.game_memberships m where m.game_id=p_game_id order by m.joined_at;
end $$;
revoke all on function public.list_game_lobby(uuid) from public,anon;
grant execute on function public.list_game_lobby(uuid) to authenticated;

-- Replace old registration: real name is public; codename remains private.
create or replace function public.assassins_join(p_code text,p_codename text,p_real_name text,p_phone text default '',p_hall text default '',p_accepted boolean default false)
returns uuid language plpgsql security definer set search_path='' as $$
declare g public.games%rowtype; c public.assassins_config%rowtype; v_code text:=lower(trim(p_codename)); v_name text:=trim(p_real_name);
begin
 if (select auth.uid()) is null then raise exception 'Sign in or continue as guest'; end if;
 select * into g from public.games where game_code=upper(trim(p_code)) and game_type='assassins' for update;
 if not found or g.status<>'registration' then raise exception 'Registration closed'; end if;
 insert into public.assassins_config(game_id) values(g.id) on conflict do nothing;
 select * into c from public.assassins_config where game_id=g.id;
 if v_code !~ '^[a-z0-9]+$' then raise exception 'Codename must use letters and numbers only'; end if;
 if char_length(v_code)>32 then raise exception 'Codename too long'; end if;
 if v_name is null or char_length(v_name)<2 or char_length(v_name)>120 then raise exception 'Enter your first and last name'; end if;
 if c.phone_enabled and nullif(trim(p_phone),'') is null then raise exception 'Phone is required'; end if;
 if c.hall_enabled and nullif(trim(p_hall),'') is null then raise exception 'Hall is required'; end if;
 if c.hall_enabled and not (trim(p_hall)=any(string_to_array(replace(c.hall_options,', ',','),','))) then raise exception 'Invalid hall'; end if;
 if c.instructions_enabled and c.instruction_verification_enabled and not p_accepted then raise exception 'Please accept the instructions'; end if;
 if exists(select 1 from public.game_memberships where game_id=g.id and user_id=(select auth.uid())) then raise exception 'You have already registered for this game'; end if;
 if exists(select 1 from public.game_memberships where game_id=g.id and lower(codename)=v_code) then raise exception 'Codename is taken'; end if;
 insert into public.game_memberships(game_id,user_id,codename,real_name,phone,hall)
 values(g.id,(select auth.uid()),v_code,v_name,case when c.phone_enabled then trim(p_phone) else null end,case when c.hall_enabled then trim(p_hall) else null end);
 return g.id;
end $$;

-- Replace legacy registration RPC too, so clients cannot bypass required real names.
create or replace function public.join_game(p_code text,p_codename text)
returns uuid language plpgsql security definer set search_path='' as $join$
declare g public.games%rowtype; v_name text:=trim(p_codename);
begin
 if (select auth.uid()) is null then raise exception 'Authentication required'; end if;
 select * into g from public.games where game_code=upper(trim(p_code)) for update;
 if not found or g.status<>'registration' then raise exception 'Registration closed'; end if;
 if g.game_type='assassins' then raise exception 'Please register with a real name'; end if;
 if v_name is null or length(v_name)<2 or length(v_name)>32 or v_name !~ '^[[:alnum:] _-]+$' then raise exception 'Invalid codename'; end if;
 if exists(select 1 from public.game_memberships where game_id=g.id and user_id=(select auth.uid())) then return g.id; end if;
 insert into public.game_memberships(game_id,user_id,codename) values(g.id,(select auth.uid()),v_name);
 return g.id;
exception when unique_violation then raise exception 'Codename already taken';
end $join$;

-- Original circular next-active-player behavior, excluding self.
create or replace function public.assassins_target(p_game_id uuid,p_member_id uuid)
returns uuid language sql stable security definer set search_path='' as $$
 select a.member_id from public.assassins_players a
 where a.game_id=p_game_id and a.alive and a.member_id<>p_member_id
 order by case when a.turn_order>(select turn_order from public.assassins_players where game_id=p_game_id and member_id=p_member_id)
 then 0 else 1 end,a.turn_order limit 1
$$;
revoke all on function public.assassins_target(uuid,uuid) from public,anon,authenticated;

create or replace function public.assassins_start(p_game_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare g public.games%rowtype; n integer;
begin
 select * into g from public.games where id=p_game_id for update;
 if not found or g.owner_user_id is distinct from (select auth.uid()) then raise exception 'Host only'; end if;
 if g.game_type<>'assassins' or g.status<>'registration' then raise exception 'Open Assassins registration first'; end if;
 select count(*) into n from public.game_memberships where game_id=p_game_id;
 if n<3 then raise exception 'At least three players required'; end if;
 if exists(select 1 from public.game_memberships where game_id=p_game_id and nullif(real_name,'') is null) then
  raise exception 'Some existing registrations have no real name. Re-register these players before starting'; end if;
 insert into public.assassins_players(game_id,member_id,turn_order)
 select p_game_id,id,row_number() over(order by joined_at,id)::integer from public.game_memberships where game_id=p_game_id;
 insert into public.assassins_config(game_id) values(p_game_id) on conflict do nothing;
 update public.games set status='active' where id=p_game_id;
end $$;

-- Atomic codename confirmation, no host approval. The target must be the next active member.
create or replace function public.assassins_confirm(p_game_id uuid,p_target_codename text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare g public.games%rowtype; c public.assassins_config%rowtype; me uuid; target uuid; target_name text; next_id uuid; next_name text;
begin
 select * into g from public.games where id=p_game_id for update;
 if not found or g.game_type<>'assassins' or g.status<>'active' then raise exception 'Game is not active'; end if;
 select * into c from public.assassins_config where game_id=p_game_id;
 if c.paused or not c.eliminate_enabled or not c.dashboard_enabled then raise exception 'Eliminations are currently disabled'; end if;
 select m.id into me from public.game_memberships m join public.assassins_players a on a.game_id=p_game_id and a.member_id=m.id and a.alive
 where m.game_id=p_game_id and m.user_id=(select auth.uid());
 if me is null then raise exception 'You are not an active player'; end if;
 select m.id,m.real_name into target,target_name from public.game_memberships m
 join public.assassins_players a on a.game_id=p_game_id and a.member_id=m.id and a.alive
 where m.game_id=p_game_id and lower(m.codename)=lower(trim(p_target_codename));
 if target is null then raise exception 'Invalid codename or player already eliminated'; end if;
 if target is distinct from public.assassins_target(p_game_id,me) then raise exception 'This player is not your assigned target'; end if;
 update public.assassins_players set alive=false,eliminated_by=me,eliminated_at=now()
 where game_id=p_game_id and member_id=target;
 insert into public.assassins_eliminations(game_id,assassin_id,target_id) values(p_game_id,me,target);
 next_id:=public.assassins_target(p_game_id,me);
 select real_name into next_name from public.game_memberships where id=next_id;
 if next_id is null then update public.games set status='finished' where id=p_game_id; end if;
 return jsonb_build_object('eliminated',target_name,'next_target',next_name,'winner',next_id is null);
end $$;

-- Player and host state: never expose other players' codenames to non-hosts.
create or replace function public.assassins_state(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare g public.games%rowtype; c public.assassins_config%rowtype; me uuid; active_me boolean; t uuid; players jsonb; feed jsonb; host boolean;
begin
 select * into g from public.games where id=p_game_id and game_type='assassins';
 if not found or (select auth.uid()) is null then raise exception 'Game unavailable'; end if;
 host:=g.owner_user_id=(select auth.uid());
 select id into me from public.game_memberships where game_id=p_game_id and user_id=(select auth.uid());
 if not host and me is null then raise exception 'Not in game'; end if;
 select * into c from public.assassins_config where game_id=p_game_id;
 select coalesce(jsonb_agg(jsonb_build_object('name',coalesce(m.real_name,'Registered player'),'alive',coalesce(a.alive,true)) order by m.joined_at),'[]'::jsonb)
 into players from public.game_memberships m left join public.assassins_players a on a.game_id=p_game_id and a.member_id=m.id where m.game_id=p_game_id;
 active_me:=coalesce((select alive from public.assassins_players where game_id=p_game_id and member_id=me),false);
 t:=case when active_me then public.assassins_target(p_game_id,me) else null end;
 select coalesce(jsonb_agg(jsonb_build_object('details',victim.real_name||' was eliminated by '||killer.real_name,'time',e.created_at) order by e.created_at desc),'[]'::jsonb)
 into feed from public.assassins_eliminations e join public.game_memberships victim on victim.id=e.target_id join public.game_memberships killer on killer.id=e.assassin_id where e.game_id=p_game_id;
 return jsonb_build_object('status',g.status,'host',host,'players',players,'my_alive',active_me,
 'my_codename',(select codename from public.game_memberships where id=me),
 'my_target',(select real_name from public.game_memberships where id=t),
 'feed',feed,'paused',coalesce(c.paused,false),'dashboard_enabled',coalesce(c.dashboard_enabled,true),
 'eliminate_enabled',coalesce(c.eliminate_enabled,true),
 'phone_enabled',coalesce(c.phone_enabled,false),'hall_enabled',coalesce(c.hall_enabled,false),
 'hall_options',coalesce(c.hall_options,''),'instructions_enabled',coalesce(c.instructions_enabled,false),
 'instruction_verification_enabled',coalesce(c.instruction_verification_enabled,false),
 'instructions_text',coalesce(c.instructions_text,''));
end $$;

create or replace function public.assassins_host_players(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v jsonb;
begin
 if not exists(select 1 from public.games where id=p_game_id and owner_user_id=(select auth.uid()) and game_type='assassins') then raise exception 'Host only'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'name',m.real_name,'codename',m.codename,'phone',m.phone,'hall',m.hall,'alive',coalesce(a.alive,true),'eliminated_at',a.eliminated_at,'eliminated_by',k.real_name,'kills',(select count(*) from public.assassins_eliminations e where e.game_id=p_game_id and e.assassin_id=m.id)) order by m.joined_at),'[]'::jsonb)
 into v from public.game_memberships m left join public.assassins_players a on a.game_id=p_game_id and a.member_id=m.id left join public.game_memberships k on k.id=a.eliminated_by where m.game_id=p_game_id;
 return v;
end $$;

create or replace function public.assassins_host_setting(p_game_id uuid,p_key text,p_value text)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.games where id=p_game_id and owner_user_id=(select auth.uid()) and game_type='assassins') then raise exception 'Host only'; end if;
 insert into public.assassins_config(game_id) values(p_game_id) on conflict do nothing;
 if p_key in ('dashboard_enabled','eliminate_enabled','phone_enabled','hall_enabled','instructions_enabled','instruction_verification_enabled','paused') then
  if lower(p_value) not in ('true','false') then raise exception 'Expected true or false'; end if;
  execute format('update public.assassins_config set %I=$1 where game_id=$2',p_key) using p_value::boolean,p_game_id;
 elsif p_key in ('hall_options','instructions_text') then
  if length(p_value)>5000 then raise exception 'Setting too long'; end if;
  execute format('update public.assassins_config set %I=$1 where game_id=$2',p_key) using p_value,p_game_id;
 else raise exception 'Unsupported setting'; end if;
end $$;

create or replace function public.assassins_host_status(p_game_id uuid,p_member_id uuid,p_alive boolean)
returns void language plpgsql security definer set search_path='' as $$
declare g public.games%rowtype;
begin
 select * into g from public.games where id=p_game_id for update;
 if not found or g.owner_user_id is distinct from (select auth.uid()) or g.game_type<>'assassins' then raise exception 'Host only'; end if;
 if g.status not in ('active','finished') then raise exception 'Game not started'; end if;
 update public.assassins_players set alive=p_alive,eliminated_by=case when p_alive then null else eliminated_by end,eliminated_at=case when p_alive then null else now() end
 where game_id=p_game_id and member_id=p_member_id;
 if not found then raise exception 'Player not found'; end if;
 update public.games set status=case when (select count(*) from public.assassins_players where game_id=p_game_id and alive)<=1 then 'finished' else 'active' end where id=p_game_id;
end $$;

create or replace function public.assassins_host_reset(p_game_id uuid,p_wipe boolean)
returns void language plpgsql security definer set search_path='' as $$
declare g public.games%rowtype;
begin
 select * into g from public.games where id=p_game_id for update;
 if not found or g.owner_user_id is distinct from (select auth.uid()) or g.game_type<>'assassins' then raise exception 'Host only'; end if;
 delete from public.assassins_eliminations where game_id=p_game_id;
 delete from public.assassins_reports where game_id=p_game_id;
 delete from public.assassins_players where game_id=p_game_id;
 if p_wipe then delete from public.game_memberships where game_id=p_game_id; end if;
 update public.games set status='draft' where id=p_game_id;
end $$;

create or replace function public.assassins_host_shuffle(p_game_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare g public.games%rowtype;
begin
 select * into g from public.games where id=p_game_id for update;
 if not found or g.owner_user_id is distinct from (select auth.uid()) or g.game_type<>'assassins' then raise exception 'Host only'; end if;
 if g.status not in ('active','finished') or exists(select 1 from public.assassins_eliminations where game_id=p_game_id) then raise exception 'Shuffle only before first elimination'; end if;
 with ordered as (select member_id,row_number() over(order by random())::integer as rn from public.assassins_players where game_id=p_game_id)
 update public.assassins_players a set turn_order= -ordered.rn from ordered where a.game_id=p_game_id and a.member_id=ordered.member_id;
 update public.assassins_players set turn_order= -turn_order where game_id=p_game_id;
end $$;

create or replace function public.assassins_host_no_first_elimination(p_game_id uuid)
returns integer language plpgsql security definer set search_path='' as $$
declare g public.games%rowtype; n integer;
begin
 select * into g from public.games where id=p_game_id for update;
 if not found or g.owner_user_id is distinct from (select auth.uid()) or g.game_type<>'assassins' or g.status<>'active' then raise exception 'Active game host only'; end if;
 update public.assassins_players a set alive=false,eliminated_at=now()
 where a.game_id=p_game_id and a.alive and not exists(select 1 from public.assassins_eliminations e where e.game_id=p_game_id and e.assassin_id=a.member_id);
 get diagnostics n=row_count;
 if (select count(*) from public.assassins_players where game_id=p_game_id and alive)<=1 then update public.games set status='finished' where id=p_game_id; end if;
 return n;
end $$;

-- Host-only pregame removal by real name or codename; never reveal codenames in lobby.
-- The older host removal RPC remains available for compatibility.
revoke all on function public.assassins_join(text,text,text,text,text,boolean),public.assassins_confirm(uuid,text),public.assassins_host_players(uuid),public.assassins_host_setting(uuid,text,text),public.assassins_host_status(uuid,uuid,boolean),public.assassins_host_reset(uuid,boolean),public.assassins_host_shuffle(uuid),public.assassins_host_no_first_elimination(uuid) from public,anon;
grant execute on function public.assassins_join(text,text,text,text,text,boolean),public.assassins_confirm(uuid,text),public.assassins_host_players(uuid),public.assassins_host_setting(uuid,text,text),public.assassins_host_status(uuid,uuid,boolean),public.assassins_host_reset(uuid,boolean),public.assassins_host_shuffle(uuid),public.assassins_host_no_first_elimination(uuid) to authenticated;

-- Public registration options are scoped to the supplied game code.
create or replace function public.assassins_public_config(p_code text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c public.assassins_config%rowtype; g uuid;
begin
 select id into g from public.games where game_code=upper(trim(p_code)) and game_type='assassins' and status='registration';
 if g is null then raise exception 'Registration closed'; end if;
 select * into c from public.assassins_config where game_id=g;
 return jsonb_build_object('phone_enabled',coalesce(c.phone_enabled,false),'hall_enabled',coalesce(c.hall_enabled,false),
 'hall_options',coalesce(c.hall_options,''),'instructions_enabled',coalesce(c.instructions_enabled,false),
 'instruction_verification_enabled',coalesce(c.instruction_verification_enabled,false),'instructions_text',coalesce(c.instructions_text,''));
end $$;
revoke all on function public.assassins_public_config(text) from public;
grant execute on function public.assassins_public_config(text) to anon,authenticated;

-- Retire approval-based Assassins RPCs; only codename confirmation is valid now.
revoke execute on function public.assassins_report(uuid) from authenticated;
revoke execute on function public.assassins_resolve(uuid,boolean) from authenticated;
