-- 021: Simplified independent host controls. Run after migrations 017-020.
-- Existing game records and winner data are preserved.
begin;
alter table public.mafia_config add column if not exists master_lock boolean not null default false;
update public.game_default_settings
 set settings = jsonb_set(jsonb_set(settings,'{master_lock}','false'::jsonb,true),'{game_active}','false'::jsonb,true),
 updated_at=now()
 where game_type='mafia';
update public.game_default_settings
 set settings = jsonb_set(settings,'{eliminate_enabled}','false'::jsonb,true),updated_at=now()
 where game_type='assassins';

create or replace function public.host_quick_controls(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $quick$
declare g public.games%rowtype; a public.assassins_config%rowtype; m public.mafia_config%rowtype;
  v_ready boolean; v_players integer;
begin
 select * into g from public.games where id=p_game_id and owner_user_id=(select auth.uid());
 if not found then raise exception 'Host only'; end if;
 select count(*) into v_players from public.game_memberships where game_id=p_game_id;
 if g.game_type='assassins' then
  select * into a from public.assassins_config where game_id=p_game_id;
  select count(*)>=3 into v_ready from public.assassins_players where game_id=p_game_id;
  return jsonb_build_object('masterLock',coalesce(a.master_lock,false),
   'signup',coalesce(a.signup_enabled,true),'dashboard',coalesce(a.dashboard_enabled,true),
   'actions',coalesce(a.eliminate_enabled,false),'ready',v_ready,'players',v_players,'completed',g.status='finished');
 elsif g.game_type='mafia' then
  select * into m from public.mafia_config where game_id=p_game_id;
  select count(*)>=3 and count(*)=count(role) into v_ready from public.mafia_players where game_id=p_game_id;
  return jsonb_build_object('masterLock',coalesce(m.master_lock,false),
   'signup',coalesce(m.setup_enabled,true),'dashboard',coalesce(m.dashboard_enabled,true),
   'actions',coalesce(m.game_active,false),'ready',v_ready,'players',v_players,'completed',g.status='finished');
 end if;
 raise exception 'Unsupported game type';
end; $quick$;

create or replace function public.host_set_quick_control(p_game_id uuid,p_key text,p_enabled boolean)
returns jsonb language plpgsql security definer set search_path='' as $control$
declare g public.games%rowtype; v_count integer; v_roles integer; v_added integer;
begin
 if p_enabled is null or p_key not in ('masterLock','signup','dashboard','actions') then
  raise exception 'Invalid toggle';
 end if;
 select * into g from public.games where id=p_game_id for update;
 if not found or g.owner_user_id is distinct from (select auth.uid()) then raise exception 'Host only'; end if;
 if g.status='finished' and p_enabled and p_key in ('signup','actions') then
  raise exception 'Round completed. Reset the game before reopening registration or gameplay';
 end if;
 if g.game_type='assassins' then
  insert into public.assassins_config(game_id) values(p_game_id) on conflict do nothing;
  if p_key='masterLock' then update public.assassins_config set master_lock=p_enabled where game_id=p_game_id;
  elsif p_key='signup' then update public.assassins_config set signup_enabled=p_enabled where game_id=p_game_id;
  elsif p_key='dashboard' then update public.assassins_config set dashboard_enabled=p_enabled where game_id=p_game_id;
  elsif p_key='actions' then
   if p_enabled and g.status<>'active' then
    select count(*) into v_count from public.game_memberships where game_id=p_game_id;
    if v_count<3 then raise exception 'At least three registered players are needed before gameplay can be enabled'; end if;
    if exists(select 1 from public.game_memberships where game_id=p_game_id and nullif(trim(real_name),'') is null)
      then raise exception 'All registered players need real names'; end if;
    insert into public.assassins_players(game_id,member_id,turn_order)
    select p_game_id,m.id,coalesce((select max(turn_order) from public.assassins_players where game_id=p_game_id),0)
      +row_number() over(order by m.joined_at,m.id)
    from public.game_memberships m
    where m.game_id=p_game_id and not exists(
      select 1 from public.assassins_players a where a.game_id=p_game_id and a.member_id=m.id);
    update public.games set status='active' where id=p_game_id;
   end if;
   update public.assassins_config set eliminate_enabled=p_enabled,paused=false where game_id=p_game_id;
  end if;
 elsif g.game_type='mafia' then
  insert into public.mafia_config(game_id) values(p_game_id) on conflict do nothing;
  if p_key='masterLock' then update public.mafia_config set master_lock=p_enabled where game_id=p_game_id;
  elsif p_key='signup' then update public.mafia_config set setup_enabled=p_enabled where game_id=p_game_id;
  elsif p_key='dashboard' then update public.mafia_config set dashboard_enabled=p_enabled where game_id=p_game_id;
  elsif p_key='actions' then
   if p_enabled then
    select count(*),count(role) into v_count,v_roles from public.mafia_players where game_id=p_game_id;
    if v_count<3 or v_count<>v_roles then raise exception 'Assign roles to all registered Mafia players before enabling gameplay'; end if;
    if g.status<>'active' then update public.games set status='active' where id=p_game_id; end if;
   end if;
   update public.mafia_config set game_active=p_enabled where game_id=p_game_id;
  end if;
 else raise exception 'Unsupported game type';
 end if;
 return public.host_quick_controls(p_game_id);
end; $control$;
revoke all on function public.host_quick_controls(uuid),public.host_set_quick_control(uuid,text,boolean) from public,anon;
grant execute on function public.host_quick_controls(uuid),public.host_set_quick_control(uuid,text,boolean) to authenticated;

create or replace function public.assassins_join(p_code text,p_codename text,p_real_name text,p_phone text default '',p_hall text default '',p_accepted boolean default false)
returns uuid language plpgsql security definer set search_path='' as $$
declare g public.games%rowtype; c public.assassins_config%rowtype; v_code text:=lower(trim(p_codename)); v_name text:=trim(p_real_name); v_member uuid;
begin
 if (select auth.uid()) is null then raise exception 'Sign in or continue as guest'; end if;
 select * into g from public.games where game_code=upper(trim(p_code)) and game_type='assassins' for update;
 if not found or g.status='finished' then raise exception 'Registration closed'; end if;
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
 values(g.id,(select auth.uid()),v_code,v_name,case when c.phone_enabled then trim(p_phone) else null end,case when c.hall_enabled then trim(p_hall) else null end) returning id into v_member;
 if g.status='active' then
  insert into public.assassins_players(game_id,member_id,turn_order)
  select g.id,v_member,coalesce(max(turn_order),0)+1 from public.assassins_players where game_id=g.id;
 end if;
 return g.id;
end; $;

create or replace function public.assassins_v2_public(p_code text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare g public.games%rowtype; c public.assassins_config%rowtype; v_feed jsonb;
begin
 select * into g from public.games where game_code=upper(trim(p_code)) and game_type='assassins';
 if not found then raise exception 'Assassins game not found'; end if;
 select * into c from public.assassins_config where game_id=g.id;
 if coalesce(c.master_lock,false) then
  return jsonb_build_object('id',g.id,'status',g.status,'master_lock',true,'master_lock_message',c.master_lock_message,'signup_enabled',false,'dashboard_enabled',false,'eliminate_enabled',false);
 end if;
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
 'instructions_text',coalesce(c.instructions_text,''),'full_rules_text',coalesce(c.full_rules_text,''),
  'winner_announcement',case when g.status='finished' then coalesce(c.winner_announcement,'') else '' end,'feed',v_feed);
end; $$;

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
 if coalesce(c.master_lock,false) and not host then raise exception '%',coalesce(c.master_lock_message,'Game locked'); end if;
 if not host and not coalesce(c.dashboard_enabled,true) then raise exception 'Player dashboards are disabled'; end if;
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
end; $;

create or replace function public.mafia_join(p_code text,p_real_name text,p_codename text,p_password text,p_phone text default '',p_hall text default '')
returns uuid language plpgsql security definer set search_path='' as $$
declare g public.games%rowtype; c public.mafia_config%rowtype; v_id uuid; v_name text:=trim(p_real_name); v_code text:=lower(trim(p_codename));
begin
 if (select auth.uid()) is null then raise exception 'Session is required'; end if;
 select * into g from public.games where game_code=upper(trim(p_code)) and game_type='mafia' for update;
 if not found or g.status='finished' then raise exception 'Registration is closed'; end if;
 insert into public.mafia_config(game_id) values(g.id) on conflict do nothing;
 select * into c from public.mafia_config where game_id=g.id;
 if coalesce(c.master_lock,false) then raise exception 'Game is locked'; end if;
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
 insert into public.mafia_players(game_id,member_id,pin_hash,role)
 values(g.id,v_id,extensions.crypt(p_password,extensions.gen_salt('bf')),
 case when g.status='active' and c.game_active then 'citizen' else null end);
 return g.id;
end; $;

create or replace function public.mafia_public(p_code text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare g public.games%rowtype; c public.mafia_config%rowtype; roster jsonb;
begin
 select * into g from public.games where game_code=upper(trim(p_code)) and game_type='mafia';
 if not found then raise exception 'Mafia game not found'; end if;
 select * into c from public.mafia_config where game_id=g.id;
 if coalesce(c.master_lock,false) then
  return jsonb_build_object('id',g.id,'status',g.status,'masterLock',true,'setupEnabled',false,'dashboardEnabled',false,'gameActive',false,'announcement','');
 end if;
 select coalesce(jsonb_agg(case when coalesce(p.alive,true) then m.real_name||' is currently active.' else m.real_name||' was eliminated.' end order by m.joined_at),'[]'::jsonb)
 into roster from public.game_memberships m left join public.mafia_players p on p.member_id=m.id and p.game_id=g.id where m.game_id=g.id;
 return jsonb_build_object('id',g.id,'status',g.status,'setupEnabled',g.status<>'finished' and coalesce(c.setup_enabled,true),
 'dashboardEnabled',coalesce(c.dashboard_enabled,true),'gameActive',coalesce(c.game_active,true) and g.status<>'finished',
 'masterLock',false,'announcement',coalesce(c.announcement,''),'announcementMessage',coalesce(c.announcement,''),
 'hallFieldEnabled',coalesce(c.hall_field_enabled,false),
 'hallOptions',coalesce(to_jsonb(string_to_array(c.hall_options,',')),'[]'::jsonb),
 'gameInstructions',coalesce(c.game_instructions,''),'players',roster);
end; $;

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
 if coalesce(c.master_lock,false) then raise exception 'Game is locked'; end if;
 if not coalesce(c.dashboard_enabled,true) then raise exception 'Player dashboards are disabled'; end if;
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
end; $;

create or replace function public.mafia_action(p_game_id uuid,p_action text,p_codename text default '',p_password text default '',p_target text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare g public.games%rowtype; c public.mafia_config%rowtype; me public.game_memberships%rowtype;
p public.mafia_players%rowtype; v_target uuid; target_role text; target_name text; votes integer; eligible boolean;
begin
 select * into g from public.games where id=p_game_id for update;
 if not found or g.game_type<>'mafia' or g.status<>'active' then raise exception 'Game is not active'; end if;
 select * into c from public.mafia_config where game_id=p_game_id;
 if coalesce(c.master_lock,false) or not c.game_active or not c.dashboard_enabled then raise exception 'Game actions are paused'; end if;
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
end; $;

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
   if g.status='finished' then raise exception 'Reset the completed round before assigning roles'; end if;
   if coalesce(c.game_active,false) and g.status='active' then raise exception 'Turn Gameplay Actions OFF before reassigning roles'; end if;
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
  -- Preserve gameplay and dashboard toggle values during role assignment.
  insert into public.mafia_log(game_id,event_type,message) values(p_game_id,'randomize','Host randomized Mafia roles');
  return jsonb_build_object('total',n,'mafia',n_mafia,'detectives',n_detectives,'citizens',n-n_mafia-n_detectives);
 elsif p_action='reset' then
  delete from public.mafia_votes where game_id=p_game_id;
  delete from public.mafia_vote_results where game_id=p_game_id;
  delete from public.mafia_log where game_id=p_game_id;
  update public.mafia_players set role=null,alive=true,mafia_last_at=null,detective_last_at=null,citizen_last_at=null where game_id=p_game_id;
  update public.games set status='draft' where id=p_game_id;
  update public.mafia_config set game_active=false where game_id=p_game_id;
 elsif p_action='remove' then
  if exists(select 1 from public.mafia_players where game_id=p_game_id and role is not null) then raise exception 'Reset assigned roles before removing players'; end if;
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
  if g.status='active' and exists(select 1 from public.mafia_players where game_id=p_game_id and role is not null) then
   update public.games set status=case
    when not exists(select 1 from public.mafia_players where game_id=p_game_id and alive and role='mafia')
      or (select count(*) from public.mafia_players where game_id=p_game_id and alive)<=c.min_active_for_game_end
      or (select count(*) from public.mafia_players where game_id=p_game_id and alive and role='mafia') >=
         (select count(*) from public.mafia_players where game_id=p_game_id and alive and role<>'mafia')
    then 'finished' else 'active' end where id=p_game_id;
  end if;
 elsif p_action='setting' then
  setting:=p_payload->>'key'; v:=p_payload->>'value';
   if setting in ('setupEnabled','dashboardEnabled','gameActive') then
    raise exception 'Use the Overview switches to change this control';
   end if;
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
 'settings',jsonb_build_object('masterLock',coalesce(c.master_lock,false),'setupEnabled',c.setup_enabled,'dashboardEnabled',c.dashboard_enabled,'gameActive',c.game_active,
 'hallFieldEnabled',c.hall_field_enabled,'hallOptions',c.hall_options,
 'allowMafiaInCitizenVotes',c.allow_mafia_votes,'allowDetectiveInCitizenVotes',c.allow_detective_votes,
 'mafiaCooldownHours',c.mafia_cooldown_hours,'detectiveCooldownHours',c.detective_cooldown_hours,
 'citizenCooldownHours',c.citizen_cooldown_hours,'votesRequired',c.votes_required,
 'citizenVotesRequired',c.votes_required,'voteExpiryHours',c.vote_expiry_hours,
 'voteExpirationMinutes',c.vote_expiration_minutes,'minActiveForGameEnd',c.min_active_for_game_end,
 'mafiaInstructions',c.mafia_instructions,'detectiveInstructions',c.detective_instructions,
 'citizenInstructions',c.citizen_instructions,'gameInstructions',c.game_instructions,'announcementMessage',c.announcement));
end; $;

create or replace function public.game_player_sign_in(p_code text,p_codename text,p_pin text)
returns boolean language plpgsql security definer set search_path='' as $$
declare v_game public.games%rowtype; v_member uuid; v_hash text;
 v_fail integer; v_locked timestamptz; v_user uuid := (select auth.uid());
begin
 if v_user is null then raise exception 'Player session required'; end if;
 if p_pin !~ '^[0-9]{4}$' then return false; end if;
 select * into v_game from public.games where game_code=upper(trim(p_code));
 if not found then return false; end if;
 if v_game.game_type='assassins' and (select coalesce(master_lock,false) from public.assassins_config where game_id=v_game.id) then raise exception 'Game is locked'; end if;
 if v_game.game_type='mafia' and (select coalesce(master_lock,false) from public.mafia_config where game_id=v_game.id) then raise exception 'Game is locked'; end if;
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
end; $;

create or replace function public.mafia_verify(p_game_id uuid,p_type text,p_target text)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare me uuid; target uuid;
begin
 if not exists(select 1 from public.games where id=p_game_id and status='active')
  or exists(select 1 from public.mafia_config where game_id=p_game_id and (master_lock or not game_active or not dashboard_enabled))
  then raise exception 'Game actions unavailable'; end if;
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
end; $;

create or replace function public.assassins_host_status(p_game_id uuid,p_member_id uuid,p_alive boolean)
returns void language plpgsql security definer set search_path='' as $
declare g public.games%rowtype;
begin
 select * into g from public.games where id=p_game_id for update;
 if not found or g.owner_user_id is distinct from (select auth.uid()) or g.game_type<>'assassins' then raise exception 'Host only'; end if;
 if g.status<>'active' then raise exception 'Completed rounds cannot be edited. Reset the game first'; end if;
 update public.assassins_players set alive=p_alive,eliminated_by=case when p_alive then null else eliminated_by end,eliminated_at=case when p_alive then null else now() end
 where game_id=p_game_id and member_id=p_member_id;
 if not found then raise exception 'Player not found'; end if;
 update public.games set status=case when (select count(*) from public.assassins_players where game_id=p_game_id and alive)<=1 then 'finished' else 'active' end where id=p_game_id;
end; $;

create or replace function public.admin_game_defaults(p_game_type text default null, p_settings jsonb default null)
returns jsonb language plpgsql security definer set search_path='' as $defaults$
declare
 v_allowed jsonb; v_entry record; v_kind text; v_min integer; v_max integer;
 v_result jsonb;
begin
 if (select auth.uid()) is null or not public.is_platform_admin() then
  raise exception 'Administrator only';
 end if;
 if p_game_type is not null and p_game_type not in ('assassins','mafia') then
  raise exception 'Unknown game type';
 end if;
 if p_settings is not null then
  if p_game_type is null or jsonb_typeof(p_settings)<>'object' then
   raise exception 'Choose one game type and send a settings object';
  end if;
  if length(p_settings::text)>30000 then raise exception 'Settings too large';end if;
  v_allowed:=case p_game_type
   when 'assassins' then '{"master_lock":"boolean","signup_enabled":"boolean","dashboard_enabled":"boolean","eliminate_enabled":"boolean","phone_enabled":"boolean","hall_enabled":"boolean","hall_options":"string","instructions_enabled":"boolean","instruction_verification_enabled":"boolean","instructions_text":"string","full_rules_text":"string","paused":"boolean","signup_off_message":"string","dashboard_off_message":"string","eliminate_off_message":"string","master_lock_message":"string"}'::jsonb
   when 'mafia' then '{"master_lock":"boolean","setup_enabled":"boolean","dashboard_enabled":"boolean","game_active":"boolean","hall_field_enabled":"boolean","hall_options":"string","allow_mafia_votes":"boolean","allow_detective_votes":"boolean","mafia_cooldown_hours":"integer","detective_cooldown_hours":"integer","citizen_cooldown_hours":"integer","votes_required":"integer","vote_expiry_hours":"integer","vote_expiration_minutes":"integer","min_active_for_game_end":"integer","mafia_instructions":"string","detective_instructions":"string","citizen_instructions":"string","game_instructions":"string","announcement":"string"}'::jsonb end;
  for v_entry in select key,value from jsonb_each(p_settings) loop
   v_kind:=v_allowed->>v_entry.key;
   if v_kind is null then raise exception 'Unsupported default setting: %',v_entry.key;end if;
   if v_kind='boolean' and jsonb_typeof(v_entry.value)<>'boolean' then
    raise exception 'Expected true or false for %',v_entry.key;
   elsif v_kind='string' and
     (jsonb_typeof(v_entry.value)<>'string' or length(v_entry.value #>> '{}') > (case when v_entry.key='full_rules_text' then 12000 else 5000 end)) then
    raise exception 'Invalid text for % (length limit exceeded)',v_entry.key;
   elsif v_kind='integer' then
    if jsonb_typeof(v_entry.value)<>'number' or (v_entry.value #>> '{}') !~ '^[0-9]+ from undoing the independent toggle system.
revoke execute on function public.set_game_registration(uuid,boolean) from authenticated;
revoke execute on function public.assassins_start(uuid) from authenticated;
commit;
 then
     raise exception 'Expected a nonnegative whole number for %',v_entry.key;
    end if;
    v_min:=case when v_entry.key in ('votes_required','vote_expiry_hours','vote_expiration_minutes','min_active_for_game_end') then 1 else 0 end;
    v_max:=case when v_entry.key='vote_expiration_minutes' then 43200
      when v_entry.key in ('votes_required','min_active_for_game_end') then 100 else 720 end;
    if (v_entry.value #>> '{}')::numeric not between v_min and v_max then
     raise exception '% must be between % and %',v_entry.key,v_min,v_max;
    end if;
   end if;
  end loop;
  -- Merge with existing defaults, preserving other values; validate before write.
  update public.game_default_settings
   set settings=settings||p_settings,updated_at=now()
   where game_type=p_game_type;
  if not found then raise exception 'Default template missing';end if;
 end if;
 select coalesce(jsonb_object_agg(game_type,settings),'{}'::jsonb)
 into v_result from public.game_default_settings
 where p_game_type is null or game_type=p_game_type;
 return v_result;
end; $defaults$;

-- Prevent old stage-based registration RPC from undoing the independent toggle system.
revoke execute on function public.set_game_registration(uuid,boolean) from authenticated;
revoke execute on function public.assassins_start(uuid) from authenticated;
commit;
