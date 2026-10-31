-- 12ONE Games production upgrade: migrations 008, 009, 010, 011, 012, 014.
-- This is for the existing ORIGINAL Supabase production project only.
-- Run once after backing up existing production data.
-- Migration 013 is intentionally omitted: it creates obsolete recovery-code
-- functionality, which migration 014 replaces with PIN authentication.
-- Run as one SQL Editor query; all DDL is inside one transaction.
begin;
do $preflight$
begin
  if to_regclass('public.games') is null
    or to_regclass('public.game_memberships') is null
    or to_regclass('public.assassins_config') is null
    or to_regclass('public.assassins_players') is null
    or to_regclass('public.assassins_eliminations') is null
    then raise exception 'Foundations (migrations 001-007) missing. Do not run this upgrade.';
  end if;
  if to_regprocedure('extensions.crypt(text,text)') is null
    or to_regprocedure('extensions.gen_salt(text)') is null
    then raise exception 'pgcrypto encryption functions are not in extensions schema';
  end if;
end
$preflight$;

-- ================ 008_assassins_v2_public.sql ================
-- Migration 008: safe public Assassins v2 bootstrap and spectator feed.
-- Apply after 007. This exposes no codenames, phone numbers, or player identities beyond public names/feed.
create or replace function public.assassins_v2_public(p_code text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare g public.games%rowtype; c public.assassins_config%rowtype; v_feed jsonb;
begin
 select * into g from public.games where game_code=upper(trim(p_code)) and game_type='assassins';
 if not found then raise exception 'Assassins game not found'; end if;
 select * into c from public.assassins_config where game_id=g.id;
 select coalesce(jsonb_agg(jsonb_build_object('details',victim.real_name||' was eliminated by '||killer.real_name,'time',e.created_at) order by e.created_at desc),'[]'::jsonb)
 into v_feed from public.assassins_eliminations e
 join public.game_memberships victim on victim.id=e.target_id
 join public.game_memberships killer on killer.id=e.assassin_id where e.game_id=g.id;
 return jsonb_build_object('id',g.id,'status',g.status,'paused',coalesce(c.paused,false),
 'dashboard_enabled',coalesce(c.dashboard_enabled,true),'eliminate_enabled',coalesce(c.eliminate_enabled,true),
 'phone_enabled',coalesce(c.phone_enabled,false),'hall_enabled',coalesce(c.hall_enabled,false),
 'hall_options',coalesce(c.hall_options,''),'instructions_enabled',coalesce(c.instructions_enabled,false),
 'instruction_verification_enabled',coalesce(c.instruction_verification_enabled,false),
 'instructions_text',coalesce(c.instructions_text,''),'feed',v_feed);
end $$;
revoke all on function public.assassins_v2_public(text) from public;
grant execute on function public.assassins_v2_public(text) to anon,authenticated;


-- ================ 009_assassins_host_parity.sql ================
-- 009: Assassins host removal and randomized hall-aware assignments.
-- Requires migrations 007 and 008. Existing games are not re-ordered.
create or replace function public.assassins_remove_player(p_game_id uuid,p_codename text)
returns void language plpgsql security definer set search_path='' as $$
declare g public.games%rowtype; target_id uuid;
begin
 select * into g from public.games where id=p_game_id for update;
 if not found or g.game_type<>'assassins' or g.owner_user_id is distinct from (select auth.uid()) then raise exception 'Host only'; end if;
 if g.status not in ('draft','registration') then raise exception 'Players can only be removed before the game starts'; end if;
 select id into target_id from public.game_memberships where game_id=p_game_id and lower(codename)=lower(trim(p_codename));
 if target_id is null then raise exception 'Player not found'; end if;
 delete from public.game_memberships where id=target_id and game_id=p_game_id;
end $$;
revoke all on function public.assassins_remove_player(uuid,text) from public,anon;
grant execute on function public.assassins_remove_player(uuid,text) to authenticated;

create or replace function public.assassins_start(p_game_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare g public.games%rowtype; n integer;
begin
 select * into g from public.games where id=p_game_id for update;
 if not found or g.owner_user_id is distinct from (select auth.uid()) then raise exception 'Host only'; end if;
 if g.game_type<>'assassins' or g.status<>'registration' then raise exception 'Open Assassins registration first'; end if;
 select count(*) into n from public.game_memberships where game_id=p_game_id;
 if n<3 then raise exception 'At least three players required'; end if;
 if exists(select 1 from public.game_memberships where game_id=p_game_id and nullif(trim(real_name),'') is null) then raise exception 'A registration is missing a real name'; end if;
 -- Shuffle within halls and alternate halls by round whenever hall data is present.
 with shuffled as (
  select id,coalesce(nullif(trim(hall),''),'__no_hall__') as group_hall,
    row_number() over(partition by coalesce(nullif(trim(hall),''),'__no_hall__') order by random()) as hall_rank,
    random() as jitter
  from public.game_memberships where game_id=p_game_id
 ), numbered as (
  select id,row_number() over(order by hall_rank,group_hall,jitter)::integer as position from shuffled
 )
 insert into public.assassins_players(game_id,member_id,turn_order)
 select p_game_id,id,position from numbered;
 insert into public.assassins_config(game_id) values(p_game_id) on conflict do nothing;
 update public.games set status='active' where id=p_game_id;
end $$;
revoke all on function public.assassins_start(uuid) from public,anon;
grant execute on function public.assassins_start(uuid) to authenticated;

create or replace function public.assassins_host_shuffle(p_game_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare g public.games%rowtype;
begin
 select * into g from public.games where id=p_game_id for update;
 if not found or g.owner_user_id is distinct from (select auth.uid()) or g.game_type<>'assassins' then raise exception 'Host only'; end if;
 if g.status<>'active' or exists(select 1 from public.assassins_eliminations where game_id=p_game_id) then raise exception 'Shuffle is allowed only in an active game before first elimination'; end if;
 with shuffled as (
  select a.member_id,coalesce(nullif(trim(m.hall),''),'__no_hall__') as group_hall,
    row_number() over(partition by coalesce(nullif(trim(m.hall),''),'__no_hall__') order by random()) as hall_rank,
    random() as jitter
  from public.assassins_players a join public.game_memberships m on m.id=a.member_id where a.game_id=p_game_id
 ), numbered as (
  select member_id,row_number() over(order by hall_rank,group_hall,jitter)::integer as position from shuffled
 )
 update public.assassins_players a set turn_order=-n.position from numbered n
 where a.game_id=p_game_id and a.member_id=n.member_id;
 update public.assassins_players set turn_order=-turn_order where game_id=p_game_id;
end $$;
revoke all on function public.assassins_host_shuffle(uuid) from public,anon;
grant execute on function public.assassins_host_shuffle(uuid) to authenticated;


-- ================ 010_mafia_game.sql ================
-- 010: Independent continuous Mafia implementation. Run after 007-009.
-- All game mutations are server-authorized, game-scoped and atomic.
create table if not exists public.mafia_config (
 game_id uuid primary key references public.games(id) on delete cascade,
 setup_enabled boolean not null default true,
 dashboard_enabled boolean not null default true,
 game_active boolean not null default true,
 hall_field_enabled boolean not null default false,
 hall_options text not null default '',
 allow_mafia_votes boolean not null default true,
 allow_detective_votes boolean not null default true,
 mafia_cooldown_hours integer not null default 24 check(mafia_cooldown_hours between 0 and 720),
 detective_cooldown_hours integer not null default 24 check(detective_cooldown_hours between 0 and 720),
 citizen_cooldown_hours integer not null default 24 check(citizen_cooldown_hours between 0 and 720),
 votes_required integer not null default 3 check(votes_required between 1 and 100),
 vote_expiry_hours integer not null default 24 check(vote_expiry_hours between 1 and 720),
 mafia_instructions text not null default 'Mafia: find your target, learn their codename, then record the elimination. Do not reveal your team.',
 detective_instructions text not null default 'Detective: quietly investigate suspects and share your findings without exposing your role.',
 citizen_instructions text not null default 'Citizen: discuss suspects and coordinate votes. Reaching the voting threshold eliminates a player.',
 game_instructions text not null default 'Continuous Mafia: sign up, receive a secret role, and play through the player dashboard. Keep your dashboard private.',
 announcement text not null default ''
);
create table if not exists public.mafia_players (
 game_id uuid not null references public.games(id) on delete cascade,
 member_id uuid not null references public.game_memberships(id) on delete cascade,
 role text check(role in ('mafia','detective','citizen') or role is null),
 alive boolean not null default true,
 pin_hash text not null,
 mafia_last_at timestamptz,
 detective_last_at timestamptz,
 citizen_last_at timestamptz,
 primary key(game_id,member_id)
);
create table if not exists public.mafia_votes (
 game_id uuid not null references public.games(id) on delete cascade,
 voter_id uuid not null references public.game_memberships(id) on delete cascade,
 target_id uuid not null references public.game_memberships(id) on delete cascade,
 created_at timestamptz not null default now(),
 primary key(game_id,voter_id)
);
create index if not exists mafia_votes_game_target on public.mafia_votes(game_id,target_id);
create table if not exists public.mafia_log (
 id bigint generated by default as identity primary key,
 game_id uuid not null references public.games(id) on delete cascade,
 message text not null,
 event_type text not null,
 created_at timestamptz not null default now()
);
create index if not exists mafia_log_recent on public.mafia_log(game_id,created_at desc);
create table if not exists public.mafia_vote_results (
 game_id uuid not null references public.games(id) on delete cascade,
 voter_id uuid not null references public.game_memberships(id) on delete cascade,
 target_name text not null,
 was_mafia boolean not null,
 created_at timestamptz not null default now(),
 primary key(game_id,voter_id)
);
alter table public.mafia_vote_results enable row level security;
revoke all on public.mafia_vote_results from anon,authenticated;
alter table public.mafia_config enable row level security;
alter table public.mafia_players enable row level security;
alter table public.mafia_votes enable row level security;
alter table public.mafia_log enable row level security;
revoke all on public.mafia_config, public.mafia_players, public.mafia_votes, public.mafia_log from anon,authenticated;

create or replace function public.mafia_public(p_code text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare g public.games%rowtype; c public.mafia_config%rowtype; roster jsonb;
begin
 select * into g from public.games where game_code=upper(trim(p_code)) and game_type='mafia';
 if not found then raise exception 'Mafia game not found'; end if;
 select * into c from public.mafia_config where game_id=g.id;
 select coalesce(jsonb_agg(case when coalesce(p.alive,true) then m.real_name||' is currently active.' else m.real_name||' was eliminated.' end order by m.joined_at),'[]'::jsonb)
 into roster from public.game_memberships m left join public.mafia_players p on p.member_id=m.id and p.game_id=g.id where m.game_id=g.id;
 return jsonb_build_object('id',g.id,'status',g.status,'setupEnabled',g.status='registration' and coalesce(c.setup_enabled,true),
 'dashboardEnabled',coalesce(c.dashboard_enabled,true),'gameActive',coalesce(c.game_active,true) and g.status<>'finished',
 'announcement',coalesce(c.announcement,''),'announcementMessage',coalesce(c.announcement,''),
 'hallFieldEnabled',coalesce(c.hall_field_enabled,false),
 'hallOptions',coalesce(to_jsonb(string_to_array(c.hall_options,',')),'[]'::jsonb),
 'gameInstructions',coalesce(c.game_instructions,''),'players',roster);
end $$;

create or replace function public.mafia_join(p_code text,p_real_name text,p_codename text,p_password text,p_phone text default '',p_hall text default '')
returns uuid language plpgsql security definer set search_path='' as $$
declare g public.games%rowtype; c public.mafia_config%rowtype; v_id uuid; v_name text:=trim(p_real_name); v_code text:=lower(trim(p_codename));
begin
 if (select auth.uid()) is null then raise exception 'Session is required'; end if;
 select * into g from public.games where game_code=upper(trim(p_code)) and game_type='mafia' for update;
 if not found or g.status<>'registration' then raise exception 'Registration is closed'; end if;
 insert into public.mafia_config(game_id) values(g.id) on conflict do nothing;
 select * into c from public.mafia_config where game_id=g.id;
 if not c.setup_enabled then raise exception 'Registration is disabled'; end if;
 if length(v_name)<2 or length(v_name)>120 then raise exception 'Enter your first and last name'; end if;
 if v_code !~ '^[a-z0-9]+$' or length(v_code)>32 then raise exception 'Codename must be 1-32 letters or numbers'; end if;
 if p_password !~ '^[0-9]{4}$' then raise exception 'Use a 4-digit game PIN'; end if;
 if c.hall_field_enabled and nullif(trim(p_hall),'') is null then raise exception 'Hall is required'; end if;
 if c.hall_field_enabled and not (trim(p_hall)=any(string_to_array(replace(c.hall_options,', ',','),','))) then raise exception 'Invalid hall'; end if;
 if exists(select 1 from public.game_memberships where game_id=g.id and user_id=(select auth.uid())) then raise exception 'Already registered on this device'; end if;
 if exists(select 1 from public.game_memberships where game_id=g.id and lower(codename)=v_code) then raise exception 'Codename already taken'; end if;
 if exists(select 1 from public.game_memberships where game_id=g.id and lower(real_name)=lower(v_name)) then raise exception 'That real name is already registered'; end if;
 insert into public.game_memberships(game_id,user_id,codename,real_name,phone,hall)
 values(g.id,(select auth.uid()),v_code,v_name,left(trim(p_phone),40),nullif(trim(p_hall),'')) returning id into v_id;
 insert into public.mafia_players(game_id,member_id,pin_hash) values(g.id,v_id,extensions.crypt(p_password,extensions.gen_salt('bf')));
 return g.id;
end $$;

create or replace function public.mafia_state(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare g public.games%rowtype; c public.mafia_config%rowtype; me public.game_memberships%rowtype;
p public.mafia_players%rowtype; team jsonb; vote jsonb; last_result jsonb; cool jsonb; d timestamptz;
begin
 select * into g from public.games where id=p_game_id and game_type='mafia';
 if not found then raise exception 'Mafia game not found'; end if;
 select * into me from public.game_memberships where game_id=p_game_id and user_id=(select auth.uid());
 if not found then raise exception 'Not registered in this game'; end if;
 select * into p from public.mafia_players where game_id=p_game_id and member_id=me.id;
 if not found then raise exception 'Player profile missing'; end if;
 select * into c from public.mafia_config where game_id=p_game_id;
 select coalesce(jsonb_agg(jsonb_build_object('official_name',m.real_name,'status',case when q.alive then 'active' else 'eliminated' end) order by m.real_name),'[]'::jsonb)
 into team from public.mafia_players q join public.game_memberships m on m.id=q.member_id
 where q.game_id=p_game_id and q.role='mafia' and p.role='mafia';
 select jsonb_build_object('targetOfficialName',t.real_name,'votesSoFar',
   (select count(*) from public.mafia_votes v2 where v2.game_id=p_game_id and v2.target_id=v.target_id and v2.created_at>now()-make_interval(hours=>coalesce(c.vote_expiry_hours,24))),
   'votesRequired',coalesce(c.votes_required,3))
 into vote from public.mafia_votes v join public.game_memberships t on t.id=v.target_id
 where v.game_id=p_game_id and v.voter_id=me.id and v.created_at>now()-make_interval(hours=>coalesce(c.vote_expiry_hours,24));
 return jsonb_build_object('official_name',me.real_name,'codename',me.codename,'status',case when p.alive then 'active' else 'eliminated' end,
 'gameActive',g.status<>'finished' and coalesce(c.game_active,true),'dashboardEnabled',coalesce(c.dashboard_enabled,true),'role',p.role,
 'gameStatus',g.status,'roleInstructions',case p.role when 'mafia' then c.mafia_instructions when 'detective' then c.detective_instructions else c.citizen_instructions end,
 'mafiaTeam',team,
 'mafiaCooldown',jsonb_build_object('ready',p.mafia_last_at is null or p.mafia_last_at+make_interval(hours=>coalesce(c.mafia_cooldown_hours,24))<=now(),
 'remaining',greatest(0,ceil(extract(epoch from (p.mafia_last_at+make_interval(hours=>coalesce(c.mafia_cooldown_hours,24))-now()))/60))::integer||' min'),
 'detectiveCooldown',jsonb_build_object('ready',p.detective_last_at is null or p.detective_last_at+make_interval(hours=>coalesce(c.detective_cooldown_hours,24))<=now(),
 'remaining',greatest(0,ceil(extract(epoch from (p.detective_last_at+make_interval(hours=>coalesce(c.detective_cooldown_hours,24))-now()))/60))::integer||' min'),
 'citizenCooldown',jsonb_build_object('ready',p.citizen_last_at is null or p.citizen_last_at+make_interval(hours=>coalesce(c.citizen_cooldown_hours,24))<=now(),
 'remaining',greatest(0,ceil(extract(epoch from (p.citizen_last_at+make_interval(hours=>coalesce(c.citizen_cooldown_hours,24))-now()))/60))::integer||' min'),
 'activeVote',vote,'lastVoteResult',(select jsonb_build_object('targetName',r.target_name,'wasMafia',r.was_mafia,'time',r.created_at) from public.mafia_vote_results r where r.game_id=p_game_id and r.voter_id=me.id),'allowCitizenVotes',p.role='citizen' or (p.role='mafia' and coalesce(c.allow_mafia_votes,true)) or (p.role='detective' and coalesce(c.allow_detective_votes,true)));
end $$;

create or replace function public.mafia_action(p_game_id uuid,p_action text,p_codename text default '',p_password text default '',p_target text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare g public.games%rowtype; c public.mafia_config%rowtype; me public.game_memberships%rowtype;
p public.mafia_players%rowtype; v_target uuid; target_role text; target_name text; votes integer; eligible boolean;
begin
 select * into g from public.games where id=p_game_id for update;
 if not found or g.game_type<>'mafia' or g.status<>'active' then raise exception 'Game is not active'; end if;
 select * into c from public.mafia_config where game_id=p_game_id;
 if not c.game_active or not c.dashboard_enabled then raise exception 'Game actions are paused'; end if;
 select * into me from public.game_memberships where game_id=p_game_id and user_id=(select auth.uid()) and lower(codename)=lower(trim(p_codename));
 if not found then raise exception 'Player session or codename does not match'; end if;
 select * into p from public.mafia_players where game_id=p_game_id and member_id=me.id for update;
 if not found or not p.alive then raise exception 'You have been eliminated'; end if;
 if p_password !~ '^[0-9]{4}$' or p.pin_hash<>extensions.crypt(p_password,p.pin_hash) then raise exception 'Incorrect PIN'; end if;
 if p_action='retract' then
  delete from public.mafia_votes where game_id=p_game_id and voter_id=me.id;
  return jsonb_build_object('success','Vote retracted');
 end if;
 if p_action='mafia' then
  if p.role<>'mafia' then raise exception 'Mafia role required'; end if;
  if p.mafia_last_at+make_interval(hours=>c.mafia_cooldown_hours)>now() then raise exception 'Mafia cooldown active'; end if;
  select m.id,m.real_name,q.role into v_target,target_name,target_role from public.game_memberships m
  join public.mafia_players q on q.member_id=m.id and q.game_id=p_game_id and q.alive
  where m.game_id=p_game_id and lower(m.codename)=lower(trim(p_target));
  if v_target is null or v_target=me.id or target_role='mafia' then raise exception 'Invalid Mafia target'; end if;
  update public.mafia_players set alive=false where game_id=p_game_id and member_id=v_target;
  delete from public.mafia_votes where game_id=p_game_id and (target_id=v_target or voter_id=v_target);
  update public.mafia_players set mafia_last_at=now() where game_id=p_game_id and member_id=me.id;
 elsif p_action in ('detective','vote') then
  select m.id,m.real_name,q.role into v_target,target_name,target_role from public.game_memberships m
  join public.mafia_players q on q.member_id=m.id and q.game_id=p_game_id and q.alive
  where m.game_id=p_game_id and lower(m.real_name)=lower(trim(p_target));
  if v_target is null or v_target=me.id then raise exception 'Invalid target name'; end if;
  if p_action='detective' then
   if p.role<>'detective' then raise exception 'Detective role required'; end if;
   if p.detective_last_at+make_interval(hours=>c.detective_cooldown_hours)>now() then raise exception 'Detective cooldown active'; end if;
   update public.mafia_players set detective_last_at=now() where game_id=p_game_id and member_id=me.id;
   insert into public.mafia_log(game_id,event_type,message) values(p_game_id,'detective','A detective made a guess');
   return jsonb_build_object('success',case when target_role='mafia' then 'Correct: this player is Mafia.' else 'Incorrect: this player is not Mafia.' end);
  end if;
  eligible=p.role='citizen' or (p.role='mafia' and c.allow_mafia_votes) or (p.role='detective' and c.allow_detective_votes);
  if not eligible then raise exception 'You cannot cast citizen votes'; end if;
  if p.citizen_last_at+make_interval(hours=>c.citizen_cooldown_hours)>now() then raise exception 'Voting cooldown active'; end if;
  delete from public.mafia_votes where game_id=p_game_id and created_at<=now()-make_interval(hours=>c.vote_expiry_hours);
  insert into public.mafia_votes(game_id,voter_id,target_id) values(p_game_id,me.id,v_target)
   on conflict(game_id,voter_id) do update set target_id=excluded.target_id,created_at=now();
  -- Explicitly match the scoped target, not the column name (avoids accidental all-target aggregation).
  select count(*) into votes from public.mafia_votes v join public.mafia_players voter on voter.game_id=v.game_id and voter.member_id=v.voter_id and voter.alive where v.game_id=p_game_id and v.target_id=v_target;
  if votes < c.votes_required then
   return jsonb_build_object('success','Vote recorded','votesSoFar',votes,'votesRequired',c.votes_required);
  end if;
  update public.mafia_players set alive=false where game_id=p_game_id and member_id=v_target;
  insert into public.mafia_vote_results(game_id,voter_id,target_name,was_mafia,created_at)
  select p_game_id,v.voter_id,target_name,target_role='mafia',now() from public.mafia_votes v
  where v.game_id=p_game_id and v.target_id=v_target
  on conflict(game_id,voter_id) do update set target_name=excluded.target_name,was_mafia=excluded.was_mafia,created_at=excluded.created_at;
  update public.mafia_players set citizen_last_at=now() where game_id=p_game_id and member_id in
   (select voter_id from public.mafia_votes where game_id=p_game_id and target_id=v_target);
  delete from public.mafia_votes where game_id=p_game_id and (target_id=v_target or voter_id=v_target);
 else
  raise exception 'Unsupported Mafia action';
 end if;
 insert into public.mafia_log(game_id,event_type,message) values(p_game_id,p_action,target_name||' was eliminated');
 if not exists(select 1 from public.mafia_players where game_id=p_game_id and role='mafia' and alive)
    or (select count(*) from public.mafia_players where game_id=p_game_id and alive and role='mafia') >=
       (select count(*) from public.mafia_players where game_id=p_game_id and alive and role<>'mafia') then
  update public.games set status='finished' where id=p_game_id;
 end if;
 return jsonb_build_object('success',target_name||' was eliminated','votesSoFar',votes,'votesRequired',coalesce(c.votes_required,3));
end $$;

create or replace function public.mafia_host(p_game_id uuid,p_action text,p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare g public.games%rowtype; c public.mafia_config%rowtype; players jsonb; logs jsonb;
n_mafia integer; n_detectives integer; n integer; target uuid; setting text; v text; setting_col text;
begin
 select * into g from public.games where id=p_game_id for update;
 if not found or g.game_type<>'mafia' or g.owner_user_id is distinct from (select auth.uid()) then raise exception 'Host only'; end if;
 insert into public.mafia_config(game_id) values(p_game_id) on conflict do nothing;
 select * into c from public.mafia_config where game_id=p_game_id;
 if p_action='randomize' then
  n_mafia:=coalesce((p_payload->>'mafia')::integer,1); n_detectives:=coalesce((p_payload->>'detectives')::integer,1);
  select count(*) into n from public.mafia_players where game_id=p_game_id;
  if n<3 or n_mafia<1 or n_detectives<0 or n_mafia+n_detectives>=n then raise exception 'Invalid role counts'; end if;
  delete from public.mafia_votes where game_id=p_game_id;
  delete from public.mafia_vote_results where game_id=p_game_id;
  delete from public.mafia_log where game_id=p_game_id;
  with numbered as (select member_id,row_number() over(order by random()) as rn from public.mafia_players where game_id=p_game_id)
  update public.mafia_players p set role=case when numbered.rn<=n_mafia then 'mafia' when numbered.rn<=n_mafia+n_detectives then 'detective' else 'citizen' end,
  alive=true,mafia_last_at=null,detective_last_at=null,citizen_last_at=null
  from numbered where p.game_id=p_game_id and p.member_id=numbered.member_id;
  update public.games set status='active' where id=p_game_id;
  update public.mafia_config set game_active=true,dashboard_enabled=true where game_id=p_game_id;
  insert into public.mafia_log(game_id,event_type,message) values(p_game_id,'randomize','Host randomized Mafia roles');
  return jsonb_build_object('total',n,'mafia',n_mafia,'detectives',n_detectives,'citizens',n-n_mafia-n_detectives);
 elsif p_action='reset' then
  delete from public.mafia_votes where game_id=p_game_id;
  delete from public.mafia_vote_results where game_id=p_game_id;
  delete from public.mafia_log where game_id=p_game_id;
  update public.mafia_players set role=null,alive=true,mafia_last_at=null,detective_last_at=null,citizen_last_at=null where game_id=p_game_id;
  update public.games set status='draft' where id=p_game_id;
  update public.mafia_config set game_active=true,dashboard_enabled=true where game_id=p_game_id;
 elsif p_action='remove' then
  if g.status not in ('draft','registration') then raise exception 'Remove players only before game start'; end if;
  select id into target from public.game_memberships where game_id=p_game_id and lower(codename)=lower(trim(p_payload->>'codename'));
  if target is null then raise exception 'Player not found'; end if;
  delete from public.mafia_players where game_id=p_game_id and member_id=target;
  delete from public.game_memberships where id=target;
 elsif p_action='player' then
  select id into target from public.game_memberships where game_id=p_game_id and lower(codename)=lower(trim(p_payload->>'codename'));
  if target is null then raise exception 'Player not found'; end if;
  if coalesce(p_payload->>'role','') not in ('','citizen','mafia','detective') then raise exception 'Invalid role'; end if;
  if coalesce(p_payload->>'status','') not in ('active','eliminated') then raise exception 'Invalid status'; end if;
  update public.mafia_players set role=nullif(p_payload->>'role',''),alive=(p_payload->>'status'='active') where game_id=p_game_id and member_id=target;
  if p_payload->>'status'='eliminated' then
   delete from public.mafia_votes where game_id=p_game_id and (target_id=target or voter_id=target);
  end if;
  insert into public.mafia_log(game_id,event_type,message) values(p_game_id,'host_player','Host updated '||(select coalesce(real_name,'player') from public.game_memberships where id=target));
  if g.status in ('active','finished') then
   update public.games set status=case
    when not exists(select 1 from public.mafia_players where game_id=p_game_id and alive and role='mafia')
      or (select count(*) from public.mafia_players where game_id=p_game_id and alive and role='mafia') >=
         (select count(*) from public.mafia_players where game_id=p_game_id and alive and role<>'mafia')
    then 'finished' else 'active' end where id=p_game_id;
  end if;
 elsif p_action='setting' then
  setting:=p_payload->>'key'; v:=p_payload->>'value';
  setting_col:=case setting
   when 'setupEnabled' then 'setup_enabled' when 'dashboardEnabled' then 'dashboard_enabled'
   when 'gameActive' then 'game_active' when 'hallFieldEnabled' then 'hall_field_enabled'
   when 'allowMafiaInCitizenVotes' then 'allow_mafia_votes' when 'allowDetectiveInCitizenVotes' then 'allow_detective_votes'
   when 'hallOptions' then 'hall_options' when 'gameInstructions' then 'game_instructions'
   when 'mafiaInstructions' then 'mafia_instructions' when 'detectiveInstructions' then 'detective_instructions'
   when 'citizenInstructions' then 'citizen_instructions' when 'announcementMessage' then 'announcement'
   when 'mafiaCooldownHours' then 'mafia_cooldown_hours' when 'detectiveCooldownHours' then 'detective_cooldown_hours'
   when 'citizenCooldownHours' then 'citizen_cooldown_hours' when 'votesRequired' then 'votes_required'
   when 'voteExpiryHours' then 'vote_expiry_hours' else null end;
  if setting_col is null or length(coalesce(v,''))>5000 then raise exception 'Invalid setting'; end if;
  if setting_col in ('setup_enabled','dashboard_enabled','game_active','hall_field_enabled','allow_mafia_votes','allow_detective_votes') then
   if lower(v) not in ('true','false') then raise exception 'Expected true or false'; end if;
   execute format('update public.mafia_config set %I=$1::boolean where game_id=$2',setting_col) using v,p_game_id;
  elsif setting_col in ('mafia_cooldown_hours','detective_cooldown_hours','citizen_cooldown_hours','votes_required','vote_expiry_hours') then
   if v !~ '^[0-9]{1,3}$' then raise exception 'Enter a valid number'; end if;
   execute format('update public.mafia_config set %I=$1::integer where game_id=$2',setting_col) using v,p_game_id;
  else
   execute format('update public.mafia_config set %I=$1 where game_id=$2',setting_col) using v,p_game_id;
  end if;
 else
  if p_action<>'read' then raise exception 'Unsupported host command'; end if;
 end if;
 select * into c from public.mafia_config where game_id=p_game_id;
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'official_name',m.real_name,'codename',m.codename,'role',p.role,
 'status',case when p.alive then 'active' else 'eliminated' end) order by m.joined_at),'[]'::jsonb)
 into players from public.mafia_players p join public.game_memberships m on m.id=p.member_id where p.game_id=p_game_id;
 select coalesce(jsonb_agg(jsonb_build_object('time',l.created_at,'message',l.message) order by l.created_at desc),'[]'::jsonb)
 into logs from (select * from public.mafia_log where game_id=p_game_id order by created_at desc limit 200) l;
 return jsonb_build_object('players',players,'log',logs,'status',(select status from public.games where id=p_game_id),
 'settings',jsonb_build_object('setupEnabled',c.setup_enabled,'dashboardEnabled',c.dashboard_enabled,'gameActive',c.game_active,
 'hallFieldEnabled',c.hall_field_enabled,'hallOptions',c.hall_options,
 'allowMafiaInCitizenVotes',c.allow_mafia_votes,'allowDetectiveInCitizenVotes',c.allow_detective_votes,
 'mafiaCooldownHours',c.mafia_cooldown_hours,'detectiveCooldownHours',c.detective_cooldown_hours,
 'citizenCooldownHours',c.citizen_cooldown_hours,'votesRequired',c.votes_required,'voteExpiryHours',c.vote_expiry_hours,
 'mafiaInstructions',c.mafia_instructions,'detectiveInstructions',c.detective_instructions,
 'citizenInstructions',c.citizen_instructions,'gameInstructions',c.game_instructions,'announcementMessage',c.announcement));
end $$;


-- Login requires ownership of the anonymous session AND the selected PIN.
create or replace function public.mafia_login(p_game_id uuid,p_codename text,p_password text)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare hash text;
begin
 select p.pin_hash into hash from public.game_memberships m
 join public.mafia_players p on p.game_id=m.game_id and p.member_id=m.id
 where m.game_id=p_game_id and m.user_id=(select auth.uid()) and lower(m.codename)=lower(trim(p_codename));
 if hash is null then return false; end if;
 return hash=extensions.crypt(p_password,hash);
end $$;

-- Verification returns only validity; never exposes secret codenames or roles.
create or replace function public.mafia_verify(p_game_id uuid,p_type text,p_target text)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare me uuid; target uuid;
begin
 select id into me from public.game_memberships where game_id=p_game_id and user_id=(select auth.uid());
 if me is null then raise exception 'Not registered'; end if;
 if p_type='mafia' then
  if not exists(select 1 from public.mafia_players where game_id=p_game_id and member_id=me and role='mafia' and alive) then return false; end if;
  select m.id into target from public.game_memberships m join public.mafia_players p on p.member_id=m.id and p.game_id=p_game_id and p.alive
  where m.game_id=p_game_id and lower(m.codename)=lower(trim(p_target)) and p.role<>'mafia' and m.id<>me;
 elsif p_type='detective' or p_type='vote' then
  select m.id into target from public.game_memberships m join public.mafia_players p on p.member_id=m.id and p.game_id=p_game_id and p.alive
  where m.game_id=p_game_id and lower(m.real_name)=lower(trim(p_target)) and m.id<>me;
 else raise exception 'Unknown verification type'; end if;
 return target is not null;
end $$;
revoke all on function public.mafia_public(text),public.mafia_join(text,text,text,text,text,text),
 public.mafia_state(uuid),public.mafia_action(uuid,text,text,text,text),public.mafia_host(uuid,text,jsonb),public.mafia_login(uuid,text,text),public.mafia_verify(uuid,text,text) from public,anon;
grant execute on function public.mafia_public(text) to anon,authenticated;
grant execute on function public.mafia_join(text,text,text,text,text,text),public.mafia_state(uuid),
 public.mafia_action(uuid,text,text,text,text),public.mafia_host(uuid,text,jsonb),public.mafia_login(uuid,text,text),public.mafia_verify(uuid,text,text) to authenticated;


-- ================ 011_settings_parity.sql ================
-- 011: Host dashboard settings parity for original Assassins and Mafia games.
-- Passwords are replaced by authenticated, per-game host ownership; never store plaintext admin/reset passwords.
alter table public.assassins_config
 add column if not exists master_lock boolean not null default false,
 add column if not exists signup_enabled boolean not null default true,
 add column if not exists signup_off_message text not null default 'Registration is currently closed.',
 add column if not exists dashboard_off_message text not null default 'The player dashboard is temporarily unavailable.',
 add column if not exists eliminate_off_message text not null default 'Eliminations are currently disabled.',
 add column if not exists master_lock_message text not null default 'The game is temporarily unavailable.',
 add column if not exists last_updated timestamptz not null default now();

create or replace function public.assassins_host_setting(p_game_id uuid,p_key text,p_value text)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.games where id=p_game_id and owner_user_id=(select auth.uid()) and game_type='assassins') then raise exception 'Host only'; end if;
 insert into public.assassins_config(game_id) values(p_game_id) on conflict do nothing;
 if p_key in ('master_lock','signup_enabled','dashboard_enabled','eliminate_enabled','phone_enabled','hall_enabled','instructions_enabled','instruction_verification_enabled','paused') then
  if lower(p_value) not in ('true','false') then raise exception 'Expected true or false'; end if;
  execute format('update public.assassins_config set %I=$1::boolean,last_updated=now() where game_id=$2',p_key) using p_value,p_game_id;
 elsif p_key in ('hall_options','instructions_text','signup_off_message','dashboard_off_message','eliminate_off_message','master_lock_message') then
  if length(coalesce(p_value,''))>5000 then raise exception 'Setting too long'; end if;
  execute format('update public.assassins_config set %I=$1,last_updated=now() where game_id=$2',p_key) using p_value,p_game_id;
 else raise exception 'Unsupported setting'; end if;
end $$;
create or replace function public.assassins_host_settings(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c public.assassins_config%rowtype; g public.games%rowtype;
begin
 select * into g from public.games where id=p_game_id and game_type='assassins' and owner_user_id=(select auth.uid());
 if not found then raise exception 'Host only'; end if;
 select * into c from public.assassins_config where game_id=p_game_id;
 return jsonb_build_object(
 'master_lock',coalesce(c.master_lock,false),'game_status',g.status,
 'signup_enabled',coalesce(c.signup_enabled,true),'dashboard_enabled',coalesce(c.dashboard_enabled,true),
 'eliminate_enabled',coalesce(c.eliminate_enabled,true),
 'signup_off_message',coalesce(c.signup_off_message,''),'dashboard_off_message',coalesce(c.dashboard_off_message,''),
 'eliminate_off_message',coalesce(c.eliminate_off_message,''),'master_lock_message',coalesce(c.master_lock_message,''),
 'last_updated',c.last_updated,'hall_field_enabled',coalesce(c.hall_enabled,false),
 'hall_options',coalesce(c.hall_options,''),'phone_field_enabled',coalesce(c.phone_enabled,false),
 'instructions_enabled',coalesce(c.instructions_enabled,false),
 'instruction_verification_enabled',coalesce(c.instruction_verification_enabled,false),
 'instructions_text',coalesce(c.instructions_text,''),'paused',coalesce(c.paused,false),
 'admin_password','Host account authentication','reset_password','Host account authentication');
end $$;
create or replace function public.assassins_join(p_code text,p_codename text,p_real_name text,p_phone text default '',p_hall text default '',p_accepted boolean default false)
returns uuid language plpgsql security definer set search_path='' as $$
declare g public.games%rowtype; c public.assassins_config%rowtype; v_code text:=lower(trim(p_codename)); v_name text:=trim(p_real_name);
begin
 if (select auth.uid()) is null then raise exception 'Sign in or continue as guest'; end if;
 select * into g from public.games where game_code=upper(trim(p_code)) and game_type='assassins' for update;
 if not found or g.status<>'registration' then raise exception 'Registration closed'; end if;
 insert into public.assassins_config(game_id) values(g.id) on conflict do nothing;
 select * into c from public.assassins_config where game_id=g.id;
 if c.master_lock or not c.signup_enabled then raise exception '%',case when c.master_lock then c.master_lock_message else c.signup_off_message end; end if;
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

create or replace function public.assassins_confirm(p_game_id uuid,p_target_codename text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare g public.games%rowtype; c public.assassins_config%rowtype; me uuid; target uuid; target_name text; next_id uuid; next_name text;
begin
 select * into g from public.games where id=p_game_id for update;
 if not found or g.game_type<>'assassins' or g.status<>'active' then raise exception 'Game is not active'; end if;
 select * into c from public.assassins_config where game_id=p_game_id;
 if c.master_lock then raise exception '%',c.master_lock_message; end if;
 if c.paused or not c.eliminate_enabled or not c.dashboard_enabled then raise exception '%',c.eliminate_off_message; end if;
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

create or replace function public.assassins_v2_public(p_code text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare g public.games%rowtype; c public.assassins_config%rowtype; v_feed jsonb;
begin
 select * into g from public.games where game_code=upper(trim(p_code)) and game_type='assassins';
 if not found then raise exception 'Assassins game not found'; end if;
 select * into c from public.assassins_config where game_id=g.id;
 select coalesce(jsonb_agg(jsonb_build_object('details',victim.real_name||' was eliminated by '||killer.real_name,'time',e.created_at) order by e.created_at desc),'[]'::jsonb)
 into v_feed from public.assassins_eliminations e
 join public.game_memberships victim on victim.id=e.target_id
 join public.game_memberships killer on killer.id=e.assassin_id where e.game_id=g.id;
 return jsonb_build_object('id',g.id,'status',g.status,'paused',coalesce(c.paused,false),
 'master_lock',coalesce(c.master_lock,false),'signup_enabled',coalesce(c.signup_enabled,true),
 'signup_off_message',coalesce(c.signup_off_message,''),'dashboard_off_message',coalesce(c.dashboard_off_message,''),
 'eliminate_off_message',coalesce(c.eliminate_off_message,''),'master_lock_message',coalesce(c.master_lock_message,''),
 'dashboard_enabled',coalesce(c.dashboard_enabled,true),'eliminate_enabled',coalesce(c.eliminate_enabled,true),
 'phone_enabled',coalesce(c.phone_enabled,false),'hall_enabled',coalesce(c.hall_enabled,false),
 'hall_options',coalesce(c.hall_options,''),'instructions_enabled',coalesce(c.instructions_enabled,false),
 'instruction_verification_enabled',coalesce(c.instruction_verification_enabled,false),
 'instructions_text',coalesce(c.instructions_text,''),'feed',v_feed);
end $$;

revoke all on function public.assassins_host_settings(uuid) from public,anon;
grant execute on function public.assassins_host_settings(uuid) to authenticated;

-- Original Mafia sheet labels preserved as host-dashboard keys.
alter table public.mafia_config add column if not exists min_active_for_game_end integer not null default 3 check(min_active_for_game_end between 1 and 100);


-- ================ 012_mafia_settings_parity.sql ================
-- 012: Original Mafia sheet settings parity, preserving canonical labels.
-- Sheet adminPassword is replaced by authenticated host access, not plaintext storage.
alter table public.mafia_config add column if not exists vote_expiration_minutes integer not null default 1440 check(vote_expiration_minutes between 1 and 43200);
create or replace function public.mafia_state(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare g public.games%rowtype; c public.mafia_config%rowtype; me public.game_memberships%rowtype;
p public.mafia_players%rowtype; team jsonb; vote jsonb; last_result jsonb; cool jsonb; d timestamptz;
begin
 select * into g from public.games where id=p_game_id and game_type='mafia';
 if not found then raise exception 'Mafia game not found'; end if;
 select * into me from public.game_memberships where game_id=p_game_id and user_id=(select auth.uid());
 if not found then raise exception 'Not registered in this game'; end if;
 select * into p from public.mafia_players where game_id=p_game_id and member_id=me.id;
 if not found then raise exception 'Player profile missing'; end if;
 select * into c from public.mafia_config where game_id=p_game_id;
 select coalesce(jsonb_agg(jsonb_build_object('official_name',m.real_name,'status',case when q.alive then 'active' else 'eliminated' end) order by m.real_name),'[]'::jsonb)
 into team from public.mafia_players q join public.game_memberships m on m.id=q.member_id
 where q.game_id=p_game_id and q.role='mafia' and p.role='mafia';
 select jsonb_build_object('targetOfficialName',t.real_name,'votesSoFar',
   (select count(*) from public.mafia_votes v2 where v2.game_id=p_game_id and v2.target_id=v.target_id and v2.created_at>now()-make_interval(mins=>coalesce(c.vote_expiration_minutes,1440))),
   'votesRequired',coalesce(c.votes_required,3))
 into vote from public.mafia_votes v join public.game_memberships t on t.id=v.target_id
 where v.game_id=p_game_id and v.voter_id=me.id and v.created_at>now()-make_interval(mins=>coalesce(c.vote_expiration_minutes,1440));
 return jsonb_build_object('official_name',me.real_name,'codename',me.codename,'status',case when p.alive then 'active' else 'eliminated' end,
 'gameActive',g.status<>'finished' and coalesce(c.game_active,true),'dashboardEnabled',coalesce(c.dashboard_enabled,true),'role',p.role,
 'gameStatus',g.status,'roleInstructions',case p.role when 'mafia' then c.mafia_instructions when 'detective' then c.detective_instructions else c.citizen_instructions end,
 'mafiaTeam',team,
 'mafiaCooldown',jsonb_build_object('ready',p.mafia_last_at is null or p.mafia_last_at+make_interval(hours=>coalesce(c.mafia_cooldown_hours,24))<=now(),
 'remaining',greatest(0,ceil(extract(epoch from (p.mafia_last_at+make_interval(hours=>coalesce(c.mafia_cooldown_hours,24))-now()))/60))::integer||' min'),
 'detectiveCooldown',jsonb_build_object('ready',p.detective_last_at is null or p.detective_last_at+make_interval(hours=>coalesce(c.detective_cooldown_hours,24))<=now(),
 'remaining',greatest(0,ceil(extract(epoch from (p.detective_last_at+make_interval(hours=>coalesce(c.detective_cooldown_hours,24))-now()))/60))::integer||' min'),
 'citizenCooldown',jsonb_build_object('ready',p.citizen_last_at is null or p.citizen_last_at+make_interval(hours=>coalesce(c.citizen_cooldown_hours,24))<=now(),
 'remaining',greatest(0,ceil(extract(epoch from (p.citizen_last_at+make_interval(hours=>coalesce(c.citizen_cooldown_hours,24))-now()))/60))::integer||' min'),
 'activeVote',vote,'lastVoteResult',(select jsonb_build_object('targetName',r.target_name,'wasMafia',r.was_mafia,'time',r.created_at) from public.mafia_vote_results r where r.game_id=p_game_id and r.voter_id=me.id),'allowCitizenVotes',p.role='citizen' or (p.role='mafia' and coalesce(c.allow_mafia_votes,true)) or (p.role='detective' and coalesce(c.allow_detective_votes,true)));
end $$;
create or replace function public.mafia_action(p_game_id uuid,p_action text,p_codename text default '',p_password text default '',p_target text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare g public.games%rowtype; c public.mafia_config%rowtype; me public.game_memberships%rowtype;
p public.mafia_players%rowtype; v_target uuid; target_role text; target_name text; votes integer; eligible boolean;
begin
 select * into g from public.games where id=p_game_id for update;
 if not found or g.game_type<>'mafia' or g.status<>'active' then raise exception 'Game is not active'; end if;
 select * into c from public.mafia_config where game_id=p_game_id;
 if not c.game_active or not c.dashboard_enabled then raise exception 'Game actions are paused'; end if;
 select * into me from public.game_memberships where game_id=p_game_id and user_id=(select auth.uid()) and lower(codename)=lower(trim(p_codename));
 if not found then raise exception 'Player session or codename does not match'; end if;
 select * into p from public.mafia_players where game_id=p_game_id and member_id=me.id for update;
 if not found or not p.alive then raise exception 'You have been eliminated'; end if;
 if p_password !~ '^[0-9]{4}$' or p.pin_hash<>extensions.crypt(p_password,p.pin_hash) then raise exception 'Incorrect PIN'; end if;
 if p_action='retract' then
  delete from public.mafia_votes where game_id=p_game_id and voter_id=me.id;
  return jsonb_build_object('success','Vote retracted');
 end if;
 if p_action='mafia' then
  if p.role<>'mafia' then raise exception 'Mafia role required'; end if;
  if p.mafia_last_at+make_interval(hours=>c.mafia_cooldown_hours)>now() then raise exception 'Mafia cooldown active'; end if;
  select m.id,m.real_name,q.role into v_target,target_name,target_role from public.game_memberships m
  join public.mafia_players q on q.member_id=m.id and q.game_id=p_game_id and q.alive
  where m.game_id=p_game_id and lower(m.codename)=lower(trim(p_target));
  if v_target is null or v_target=me.id or target_role='mafia' then raise exception 'Invalid Mafia target'; end if;
  update public.mafia_players set alive=false where game_id=p_game_id and member_id=v_target;
  delete from public.mafia_votes where game_id=p_game_id and (target_id=v_target or voter_id=v_target);
  update public.mafia_players set mafia_last_at=now() where game_id=p_game_id and member_id=me.id;
 elsif p_action in ('detective','vote') then
  select m.id,m.real_name,q.role into v_target,target_name,target_role from public.game_memberships m
  join public.mafia_players q on q.member_id=m.id and q.game_id=p_game_id and q.alive
  where m.game_id=p_game_id and lower(m.real_name)=lower(trim(p_target));
  if v_target is null or v_target=me.id then raise exception 'Invalid target name'; end if;
  if p_action='detective' then
   if p.role<>'detective' then raise exception 'Detective role required'; end if;
   if p.detective_last_at+make_interval(hours=>c.detective_cooldown_hours)>now() then raise exception 'Detective cooldown active'; end if;
   update public.mafia_players set detective_last_at=now() where game_id=p_game_id and member_id=me.id;
   insert into public.mafia_log(game_id,event_type,message) values(p_game_id,'detective','A detective made a guess');
   return jsonb_build_object('success',case when target_role='mafia' then 'Correct: this player is Mafia.' else 'Incorrect: this player is not Mafia.' end);
  end if;
  eligible=p.role='citizen' or (p.role='mafia' and c.allow_mafia_votes) or (p.role='detective' and c.allow_detective_votes);
  if not eligible then raise exception 'You cannot cast citizen votes'; end if;
  if p.citizen_last_at+make_interval(hours=>c.citizen_cooldown_hours)>now() then raise exception 'Voting cooldown active'; end if;
  delete from public.mafia_votes where game_id=p_game_id and created_at<=now()-make_interval(mins=>c.vote_expiration_minutes);
  insert into public.mafia_votes(game_id,voter_id,target_id) values(p_game_id,me.id,v_target)
   on conflict(game_id,voter_id) do update set target_id=excluded.target_id,created_at=now();
  -- Explicitly match the scoped target, not the column name (avoids accidental all-target aggregation).
  select count(*) into votes from public.mafia_votes v join public.mafia_players voter on voter.game_id=v.game_id and voter.member_id=v.voter_id and voter.alive where v.game_id=p_game_id and v.target_id=v_target;
  if votes < c.votes_required then
   return jsonb_build_object('success','Vote recorded','votesSoFar',votes,'votesRequired',c.votes_required);
  end if;
  update public.mafia_players set alive=false where game_id=p_game_id and member_id=v_target;
  insert into public.mafia_vote_results(game_id,voter_id,target_name,was_mafia,created_at)
  select p_game_id,v.voter_id,target_name,target_role='mafia',now() from public.mafia_votes v
  where v.game_id=p_game_id and v.target_id=v_target
  on conflict(game_id,voter_id) do update set target_name=excluded.target_name,was_mafia=excluded.was_mafia,created_at=excluded.created_at;
  update public.mafia_players set citizen_last_at=now() where game_id=p_game_id and member_id in
   (select voter_id from public.mafia_votes where game_id=p_game_id and target_id=v_target);
  delete from public.mafia_votes where game_id=p_game_id and (target_id=v_target or voter_id=v_target);
 else
  raise exception 'Unsupported Mafia action';
 end if;
 insert into public.mafia_log(game_id,event_type,message) values(p_game_id,p_action,target_name||' was eliminated');
 if not exists(select 1 from public.mafia_players where game_id=p_game_id and role='mafia' and alive)
    or (select count(*) from public.mafia_players where game_id=p_game_id and alive)<=c.min_active_for_game_end
    or (select count(*) from public.mafia_players where game_id=p_game_id and alive and role='mafia') >=
       (select count(*) from public.mafia_players where game_id=p_game_id and alive and role<>'mafia') then
  update public.games set status='finished' where id=p_game_id;
 end if;
 return jsonb_build_object('success',target_name||' was eliminated','votesSoFar',votes,'votesRequired',coalesce(c.votes_required,3));
end $$;
create or replace function public.mafia_host(p_game_id uuid,p_action text,p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare g public.games%rowtype; c public.mafia_config%rowtype; players jsonb; logs jsonb;
n_mafia integer; n_detectives integer; n integer; target uuid; setting text; v text; setting_col text;
begin
 select * into g from public.games where id=p_game_id for update;
 if not found or g.game_type<>'mafia' or g.owner_user_id is distinct from (select auth.uid()) then raise exception 'Host only'; end if;
 insert into public.mafia_config(game_id) values(p_game_id) on conflict do nothing;
 select * into c from public.mafia_config where game_id=p_game_id;
 if p_action='randomize' then
  n_mafia:=coalesce((p_payload->>'mafia')::integer,1); n_detectives:=coalesce((p_payload->>'detectives')::integer,1);
  select count(*) into n from public.mafia_players where game_id=p_game_id;
  if n<3 or n_mafia<1 or n_detectives<0 or n_mafia+n_detectives>=n then raise exception 'Invalid role counts'; end if;
  delete from public.mafia_votes where game_id=p_game_id;
  delete from public.mafia_vote_results where game_id=p_game_id;
  delete from public.mafia_log where game_id=p_game_id;
  with numbered as (select member_id,row_number() over(order by random()) as rn from public.mafia_players where game_id=p_game_id)
  update public.mafia_players p set role=case when numbered.rn<=n_mafia then 'mafia' when numbered.rn<=n_mafia+n_detectives then 'detective' else 'citizen' end,
  alive=true,mafia_last_at=null,detective_last_at=null,citizen_last_at=null
  from numbered where p.game_id=p_game_id and p.member_id=numbered.member_id;
  update public.games set status='active' where id=p_game_id;
  update public.mafia_config set game_active=true,dashboard_enabled=true where game_id=p_game_id;
  insert into public.mafia_log(game_id,event_type,message) values(p_game_id,'randomize','Host randomized Mafia roles');
  return jsonb_build_object('total',n,'mafia',n_mafia,'detectives',n_detectives,'citizens',n-n_mafia-n_detectives);
 elsif p_action='reset' then
  delete from public.mafia_votes where game_id=p_game_id;
  delete from public.mafia_vote_results where game_id=p_game_id;
  delete from public.mafia_log where game_id=p_game_id;
  update public.mafia_players set role=null,alive=true,mafia_last_at=null,detective_last_at=null,citizen_last_at=null where game_id=p_game_id;
  update public.games set status='draft' where id=p_game_id;
  update public.mafia_config set game_active=true,dashboard_enabled=true where game_id=p_game_id;
 elsif p_action='remove' then
  if g.status not in ('draft','registration') then raise exception 'Remove players only before game start'; end if;
  select id into target from public.game_memberships where game_id=p_game_id and lower(codename)=lower(trim(p_payload->>'codename'));
  if target is null then raise exception 'Player not found'; end if;
  delete from public.mafia_players where game_id=p_game_id and member_id=target;
  delete from public.game_memberships where id=target;
 elsif p_action='player' then
  select id into target from public.game_memberships where game_id=p_game_id and lower(codename)=lower(trim(p_payload->>'codename'));
  if target is null then raise exception 'Player not found'; end if;
  if coalesce(p_payload->>'role','') not in ('','citizen','mafia','detective') then raise exception 'Invalid role'; end if;
  if coalesce(p_payload->>'status','') not in ('active','eliminated') then raise exception 'Invalid status'; end if;
  update public.mafia_players set role=nullif(p_payload->>'role',''),alive=(p_payload->>'status'='active') where game_id=p_game_id and member_id=target;
  if p_payload->>'status'='eliminated' then
   delete from public.mafia_votes where game_id=p_game_id and (target_id=target or voter_id=target);
  end if;
  insert into public.mafia_log(game_id,event_type,message) values(p_game_id,'host_player','Host updated '||(select coalesce(real_name,'player') from public.game_memberships where id=target));
  if g.status in ('active','finished') then
   update public.games set status=case
    when not exists(select 1 from public.mafia_players where game_id=p_game_id and alive and role='mafia')
      or (select count(*) from public.mafia_players where game_id=p_game_id and alive)<=c.min_active_for_game_end
      or (select count(*) from public.mafia_players where game_id=p_game_id and alive and role='mafia') >=
         (select count(*) from public.mafia_players where game_id=p_game_id and alive and role<>'mafia')
    then 'finished' else 'active' end where id=p_game_id;
  end if;
 elsif p_action='setting' then
  setting:=p_payload->>'key'; v:=p_payload->>'value';
  setting_col:=case setting
   when 'setupEnabled' then 'setup_enabled' when 'dashboardEnabled' then 'dashboard_enabled'
   when 'gameActive' then 'game_active' when 'hallFieldEnabled' then 'hall_field_enabled'
   when 'allowMafiaInCitizenVotes' then 'allow_mafia_votes' when 'allowDetectiveInCitizenVotes' then 'allow_detective_votes'
   when 'hallOptions' then 'hall_options' when 'gameInstructions' then 'game_instructions'
   when 'mafiaInstructions' then 'mafia_instructions' when 'detectiveInstructions' then 'detective_instructions'
   when 'citizenInstructions' then 'citizen_instructions' when 'announcementMessage' then 'announcement'
   when 'mafiaCooldownHours' then 'mafia_cooldown_hours' when 'detectiveCooldownHours' then 'detective_cooldown_hours'
   when 'citizenCooldownHours' then 'citizen_cooldown_hours'
   when 'votesRequired' then 'votes_required' when 'citizenVotesRequired' then 'votes_required'
   when 'voteExpiryHours' then 'vote_expiry_hours'
   when 'voteExpirationMinutes' then 'vote_expiration_minutes'
   when 'minActiveForGameEnd' then 'min_active_for_game_end' else null end;
  if setting_col is null or length(coalesce(v,''))>5000 then raise exception 'Invalid setting'; end if;
  if setting_col in ('setup_enabled','dashboard_enabled','game_active','hall_field_enabled','allow_mafia_votes','allow_detective_votes') then
   if lower(v) not in ('true','false') then raise exception 'Expected true or false'; end if;
   execute format('update public.mafia_config set %I=$1::boolean where game_id=$2',setting_col) using v,p_game_id;
  elsif setting_col in ('mafia_cooldown_hours','detective_cooldown_hours','citizen_cooldown_hours','votes_required','vote_expiry_hours','vote_expiration_minutes','min_active_for_game_end') then
   if v !~ '^[0-9]{1,3}$' then raise exception 'Enter a valid number'; end if;
   execute format('update public.mafia_config set %I=$1::integer where game_id=$2',setting_col) using v,p_game_id;
  else
   execute format('update public.mafia_config set %I=$1 where game_id=$2',setting_col) using v,p_game_id;
  end if;
 else
  if p_action<>'read' then raise exception 'Unsupported host command'; end if;
 end if;
 select * into c from public.mafia_config where game_id=p_game_id;
 select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'official_name',m.real_name,'codename',m.codename,'role',p.role,
 'status',case when p.alive then 'active' else 'eliminated' end) order by m.joined_at),'[]'::jsonb)
 into players from public.mafia_players p join public.game_memberships m on m.id=p.member_id where p.game_id=p_game_id;
 select coalesce(jsonb_agg(jsonb_build_object('time',l.created_at,'message',l.message) order by l.created_at desc),'[]'::jsonb)
 into logs from (select * from public.mafia_log where game_id=p_game_id order by created_at desc limit 200) l;
 return jsonb_build_object('players',players,'log',logs,'status',(select status from public.games where id=p_game_id),
 'settings',jsonb_build_object('setupEnabled',c.setup_enabled,'dashboardEnabled',c.dashboard_enabled,'gameActive',c.game_active,
 'hallFieldEnabled',c.hall_field_enabled,'hallOptions',c.hall_options,
 'allowMafiaInCitizenVotes',c.allow_mafia_votes,'allowDetectiveInCitizenVotes',c.allow_detective_votes,
 'mafiaCooldownHours',c.mafia_cooldown_hours,'detectiveCooldownHours',c.detective_cooldown_hours,
 'citizenCooldownHours',c.citizen_cooldown_hours,'votesRequired',c.votes_required,
 'citizenVotesRequired',c.votes_required,'voteExpiryHours',c.vote_expiry_hours,
 'voteExpirationMinutes',c.vote_expiration_minutes,'minActiveForGameEnd',c.min_active_for_game_end,
 'mafiaInstructions',c.mafia_instructions,'detectiveInstructions',c.detective_instructions,
 'citizenInstructions',c.citizen_instructions,'gameInstructions',c.game_instructions,'announcementMessage',c.announcement));
end $$;
revoke all on function public.mafia_state(uuid),public.mafia_action(uuid,text,text,text,text),public.mafia_host(uuid,text,jsonb) from public,anon;
grant execute on function public.mafia_state(uuid),public.mafia_action(uuid,text,text,text,text),public.mafia_host(uuid,text,jsonb) to authenticated;


-- ================ 014_player_pin_login.sql ================
-- Migration 014: per-game player PIN authentication.
-- Run after 013. All player sign-in requests are server validated.
create table if not exists public.player_pin_credentials (
 game_id uuid not null references public.games(id) on delete cascade,
 member_id uuid not null references public.game_memberships(id) on delete cascade,
 pin_hash text not null,
 failed_attempts integer not null default 0,
 locked_until timestamptz,
 primary key(game_id,member_id)
);
alter table public.player_pin_credentials enable row level security;
revoke all on public.player_pin_credentials from public, anon, authenticated;

create or replace function public.assassins_join_with_pin(
 p_code text,p_codename text,p_real_name text,p_pin text,
 p_phone text default '',p_hall text default '',p_accepted boolean default false
) returns uuid language plpgsql security definer set search_path='' as $$
declare v_game uuid; v_member uuid;
begin
 if p_pin !~ '^[0-9]{4}$' then raise exception 'Choose a four-digit PIN'; end if;
 v_game:=public.assassins_join(p_code,p_codename,p_real_name,p_phone,p_hall,p_accepted);
 select id into v_member from public.game_memberships
 where game_id=v_game and user_id=(select auth.uid());
 if v_member is null then raise exception 'Registration failed'; end if;
 insert into public.player_pin_credentials(game_id,member_id,pin_hash)
 values(v_game,v_member,extensions.crypt(p_pin,extensions.gen_salt('bf')));
 return v_game;
end $$;

create or replace function public.game_player_sign_in(p_code text,p_codename text,p_pin text)
returns boolean language plpgsql security definer set search_path='' as $$
declare v_game public.games%rowtype; v_member uuid; v_hash text;
 v_fail integer; v_locked timestamptz; v_user uuid := (select auth.uid());
begin
 if v_user is null then raise exception 'Player session required'; end if;
 if p_pin !~ '^[0-9]{4}$' then return false; end if;
 select * into v_game from public.games where game_code=upper(trim(p_code));
 if not found then return false; end if;
 if exists(select 1 from public.game_memberships
   where game_id=v_game.id and user_id=v_user and lower(codename)<>lower(trim(p_codename)))
 then raise exception 'This session already belongs to a different player'; end if;
 select m.id,
   case when v_game.game_type='mafia' then mp.pin_hash else ap.pin_hash end,
   coalesce(ap.failed_attempts,0),ap.locked_until
 into v_member,v_hash,v_fail,v_locked
 from public.game_memberships m
 left join public.mafia_players mp on mp.game_id=m.game_id and mp.member_id=m.id
 left join public.player_pin_credentials ap on ap.game_id=m.game_id and ap.member_id=m.id
 where m.game_id=v_game.id and lower(m.codename)=lower(trim(p_codename))
 for update of m;
 if v_member is null or v_hash is null then return false; end if;
 if v_locked>now() then raise exception 'Too many login attempts; try again later'; end if;
 if v_hash<>extensions.crypt(p_pin,v_hash) then
   insert into public.player_pin_credentials(game_id,member_id,pin_hash,failed_attempts,locked_until)
   values(v_game.id,v_member,v_hash,1,null)
   on conflict(game_id,member_id) do update
     set failed_attempts=case when public.player_pin_credentials.locked_until is not null and public.player_pin_credentials.locked_until<=now()
                               then 1 else public.player_pin_credentials.failed_attempts+1 end,
         locked_until=case when public.player_pin_credentials.failed_attempts>=4
                              then now()+interval '15 minutes'
                              else null end;
   return false;
 end if;
 insert into public.player_pin_credentials(game_id,member_id,pin_hash,failed_attempts,locked_until)
 values(v_game.id,v_member,v_hash,0,null)
 on conflict(game_id,member_id) do update set failed_attempts=0,locked_until=null;
 update public.game_memberships set user_id=v_user where game_id=v_game.id and id=v_member;
 return true;
end $$;

revoke all on function public.assassins_join_with_pin(text,text,text,text,text,text,boolean),
 public.game_player_sign_in(text,text,text) from public,anon;
grant execute on function public.assassins_join_with_pin(text,text,text,text,text,text,boolean),
 public.game_player_sign_in(text,text,text) to authenticated;

-- Existing Assassins registrations can assign a PIN while signed into their
-- original browser session, without deleting players or restarting the game.
create or replace function public.assassins_set_my_pin(p_game_id uuid,p_pin text)
returns boolean language plpgsql security definer set search_path='' as $$
declare v_member uuid;
begin
 if (select auth.uid()) is null then raise exception 'Player session required'; end if;
 if p_pin !~ '^[0-9]{4}$' then raise exception 'Use a four-digit PIN'; end if;
 if not exists(select 1 from public.games where id=p_game_id and game_type='assassins') then raise exception 'Assassins game not found'; end if;
 select id into v_member from public.game_memberships
 where game_id=p_game_id and user_id=(select auth.uid());
 if v_member is null then raise exception 'You must sign in from your original registered browser'; end if;
 insert into public.player_pin_credentials(game_id,member_id,pin_hash)
 values(p_game_id,v_member,extensions.crypt(p_pin,extensions.gen_salt('bf')))
 on conflict(game_id,member_id) do update set pin_hash=excluded.pin_hash,
 failed_attempts=0,locked_until=null;
 return true;
end $$;
revoke all on function public.assassins_set_my_pin(uuid,text) from public,anon;
grant execute on function public.assassins_set_my_pin(uuid,text) to authenticated;

-- The old public registration RPC has no PIN argument. Disable direct
-- Assassins enrollment through it; only the wrapper records a hashed PIN.
revoke execute on function public.assassins_join(text,text,text,text,text,boolean) from authenticated;

-- Obsolete recovery functions and token storage are not required for PIN login.
drop function if exists public.game_issue_recovery(uuid,text);
drop function if exists public.game_recover(text,text,text);
drop table if exists public.game_recovery_tokens;

commit;
