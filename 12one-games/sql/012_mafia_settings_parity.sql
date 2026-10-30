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
 if p_password !~ '^[0-9]{4}$' or p.pin_hash<>public.crypt(p_password,p.pin_hash) then raise exception 'Incorrect PIN'; end if;
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
