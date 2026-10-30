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
select public.assassins_v2_public('ASS100');
select 'PASS: disposable PostgreSQL migration and RPC smoke test' as result;
