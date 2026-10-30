-- Disposable PostgreSQL regression for PIN logins. Do not run on Supabase.
\set ON_ERROR_STOP on
select set_config('test.user_id','00000000-0000-4000-8000-000000000021',false);
select public.assassins_set_my_pin((select id from public.games where game_code='ASS100'),'2468');
-- Same player can sign in on another device using only codename + PIN.
select set_config('test.user_id','00000000-0000-4000-8000-000000000099',false);
do $$
begin
 if public.game_player_sign_in('ASS100','first','9999') then raise exception 'Wrong Assassins PIN accepted';end if;
 if not public.game_player_sign_in('ASS100','first','2468') then raise exception 'Assassins cross-device login failed';end if;
 if not exists(select 1 from public.game_memberships where game_id=(select id from public.games where game_code='ASS100')
 and codename='first' and user_id=auth.uid()) then raise exception 'Assassins membership not transferred';end if;
 if public.game_player_sign_in('ASS100','second','2468') then raise exception 'Another player admitted';end if;
end $$;
select set_config('test.user_id','00000000-0000-4000-8000-000000000098',false);
do $$
begin
 if public.game_player_sign_in('MAF100','one','0000') then raise exception 'Wrong Mafia PIN accepted';end if;
 if not public.game_player_sign_in('MAF100','one','1234') then raise exception 'Mafia cross-device login failed';end if;
 if not exists(select 1 from public.game_memberships where game_id=(select id from public.games where game_code='MAF100')
 and codename='one' and user_id=auth.uid()) then raise exception 'Mafia membership not transferred';end if;
 if public.game_player_sign_in('MAF200','one','1234') then raise exception 'Cross-game session accepted';end if;
end $$;
select 'PASS: PIN logins, wrong PIN rejection, game isolation' as result;
