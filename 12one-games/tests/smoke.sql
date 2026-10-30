-- Run only on the disposable fixture database, not Supabase production.
\set ON_ERROR_STOP on
select set_config('test.user_id','00000000-0000-4000-8000-000000000001',false);
insert into public.games(owner_user_id,game_type,status,game_code,name) values
 ('00000000-0000-4000-8000-000000000001','mafia','registration','MAF100','Mafia test'),
 ('00000000-0000-4000-8000-000000000001','mafia','registration','MAF200','Independent Mafia'),
 ('00000000-0000-4000-8000-000000000001','assassins','registration','ASS100','Assassins test');
select public.mafia_host((select id from public.games where game_code='MAF100'),'read');
select public.mafia_host((select id from public.games where game_code='MAF200'),'read');
select (public.mafia_public('MAF100')->>'id')::uuid=(select id from public.games where game_code='MAF100') as correct_mafia_game;
select (public.assassins_v2_public('ASS100')->>'status')='registration' as correct_assassins_status;
select set_config('test.user_id','00000000-0000-4000-8000-000000000011',false);
select public.mafia_join('MAF100','Player One','one','1234');
select set_config('test.user_id','00000000-0000-4000-8000-000000000012',false);
select public.mafia_join('MAF100','Player Two','two','1234');
select set_config('test.user_id','00000000-0000-4000-8000-000000000013',false);
select public.mafia_join('MAF100','Player Three','three','1234');
select set_config('test.user_id','00000000-0000-4000-8000-000000000014',false);
select public.mafia_join('MAF100','Player Four','four','1234');
select set_config('test.user_id','00000000-0000-4000-8000-000000000001',false);
select public.mafia_host((select id from public.games where game_code='MAF100'),'randomize','{"mafia":1,"detectives":1}'::jsonb);
do $$
begin
 if (select count(*) from public.mafia_players where role='mafia')<>1 then raise exception 'Mafia assignment incorrect'; end if;
 if (select count(*) from public.mafia_players where role='detective')<>1 then raise exception 'Detective assignment incorrect'; end if;
 if (select count(*) from public.mafia_players where role='citizen')<>2 then raise exception 'Citizen assignment incorrect'; end if;
end $$;
select set_config('test.user_id',(select m.user_id::text from public.game_memberships m join public.mafia_players p on p.member_id=m.id where p.role='citizen' limit 1),false);
do $$
declare g uuid; v jsonb; identity_code text;
begin
 select id into g from public.games where game_code='MAF100';
 select m.codename into identity_code from public.game_memberships m where m.user_id=auth.uid() and m.game_id=g;
 v:=public.mafia_state(g);
 if v->>'role'<>'citizen' then raise exception 'Wrong player identity'; end if;
 if not public.mafia_login(g,identity_code,'1234') then raise exception 'PIN authentication broken'; end if;
 if public.mafia_login(g,identity_code,'9999') then raise exception 'Wrong PIN accepted'; end if;
end $$;
-- Check game isolation: a Mafia player cannot administer the host game.
do $$
begin
 begin
  perform public.mafia_host((select id from public.games where game_code='MAF100'),'reset');
  raise exception 'SECURITY FAILURE: a player was able to reset Mafia';
 exception when raise_exception then
  if sqlerrm='SECURITY FAILURE: a player was able to reset Mafia' then raise; end if;
 end;
end $$;
-- Explicitly lower the early-end threshold to exercise both elimination actions in a four-player fixture.
select set_config('test.user_id','00000000-0000-4000-8000-000000000001',false);
select public.mafia_host((select id from public.games where game_code='MAF100'),'setting','{"key":"minActiveForGameEnd","value":"2"}'::jsonb);
-- Exercise a real Mafia elimination and assert that the victim is removed from active play.
select set_config('test.user_id',(select m.user_id::text from public.game_memberships m join public.mafia_players p on p.member_id=m.id where p.role='mafia' and p.game_id=(select id from public.games where game_code='MAF100') limit 1),false);
do $$
declare g uuid; actor_code text; victim_code text; victim_id uuid; response jsonb;
begin
 select id into g from public.games where game_code='MAF100';
 select codename into actor_code from public.game_memberships where game_id=g and user_id=auth.uid();
 select m.id,m.codename into victim_id,victim_code from public.game_memberships m
 join public.mafia_players p on p.member_id=m.id and p.game_id=g
 where m.game_id=g and p.role='citizen' limit 1;
 response:=public.mafia_action(g,'mafia',actor_code,'1234',victim_code);
 if not exists(select 1 from public.mafia_players where game_id=g and member_id=victim_id and not alive) then
  raise exception 'Mafia elimination failed'; end if;
 if (select status from public.games where id=g)<>'active' then raise exception 'Unexpected game completion'; end if;
end $$;
-- One-vote threshold validates the atomic citizen vote elimination and vote cleanup.
select set_config('test.user_id','00000000-0000-4000-8000-000000000001',false);
select public.mafia_host((select id from public.games where game_code='MAF100'),'setting','{"key":"votesRequired","value":"1"}'::jsonb);
select set_config('test.user_id',(select m.user_id::text from public.game_memberships m
 join public.mafia_players p on p.member_id=m.id where p.role='citizen' and p.alive
 and p.game_id=(select id from public.games where game_code='MAF100') limit 1),false);
do $$
declare g uuid; actor_code text; victim_name text; victim_id uuid; result jsonb;
begin
 select id into g from public.games where game_code='MAF100';
 select codename into actor_code from public.game_memberships where game_id=g and user_id=auth.uid();
 select m.id,m.real_name into victim_id,victim_name from public.game_memberships m
 join public.mafia_players p on p.member_id=m.id and p.game_id=g where m.game_id=g and p.role='mafia' and p.alive limit 1;
 result:=public.mafia_action(g,'vote',actor_code,'1234',victim_name);
 if (result->>'votesSoFar')::integer<>1 then raise exception 'Vote threshold not applied'; end if;
 if (select alive from public.mafia_players where game_id=g and member_id=victim_id) then
  raise exception 'Citizen vote did not eliminate target'; end if;
 if (select status from public.games where id=g)<>'finished' then raise exception 'Game did not finish after final Mafia elimination'; end if;
end $$;
select set_config('test.user_id','00000000-0000-4000-8000-000000000001',false);
select public.mafia_host((select id from public.games where game_code='MAF100'),'reset');
do $$
begin
 if (select status from public.games where game_code='MAF100')<>'draft' then raise exception 'Reset did not reset status'; end if;
 if (select count(*) from public.game_memberships where game_id=(select id from public.games where game_code='MAF100'))<>4 then raise exception 'Reset deleted player registrations'; end if;
end $$;
-- Assassins start and the public feed must be scoped to the game.
insert into public.game_memberships(game_id,user_id,codename,real_name,hall)
select g.id, t.user_id::uuid,t.codename,t.real_name,t.hall from public.games g
cross join (values
 ('00000000-0000-4000-8000-000000000021','first','First Player','A'),
 ('00000000-0000-4000-8000-000000000022','second','Second Player','B'),
 ('00000000-0000-4000-8000-000000000023','third','Third Player','A')
) as t(user_id,codename,real_name,hall)
where g.game_code='ASS100';
select public.assassins_start((select id from public.games where game_code='ASS100'));
do $$
begin
 if (select count(*) from public.assassins_players where game_id=(select id from public.games where game_code='ASS100'))<>3 then
 raise exception 'Assassins start did not assign targets'; end if;
end $$;
select public.assassins_host_shuffle((select id from public.games where game_code='ASS100'));
select set_config('test.user_id',(select m.user_id::text from public.game_memberships m join public.assassins_players p on p.member_id=m.id where m.game_id=(select id from public.games where game_code='ASS100') order by p.turn_order limit 1),false);
do $$
declare g uuid; me uuid; target_member uuid; victim_code text; result jsonb;
begin
 select id into g from public.games where game_code='ASS100';
 select id into me from public.game_memberships where game_id=g and user_id=auth.uid();
 target_member:=public.assassins_target(g,me);
 select codename into victim_code from public.game_memberships where id=target_member;
 -- Fixture invokes the existing Assassins target algorithm; eliminate with a scoped atomic update.
 update public.assassins_players set alive=false where game_id=g and member_id=target_member;
 insert into public.assassins_eliminations(game_id,assassin_id,target_id) values(g,me,target_member);
 if jsonb_array_length((public.assassins_v2_public('ASS100')->'feed'))<>1 then
  raise exception 'Public elimination feed did not report a game-specific event'; end if;
end $$;
select set_config('test.user_id','00000000-0000-4000-8000-000000000001',false);
select public.assassins_v2_public('ASS100');
select 'PASS: disposable PostgreSQL migration and RPC smoke test' as result;
