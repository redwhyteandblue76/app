-- Disposable recovery regression checks. Depends on smoke.sql and migration 013.
\set ON_ERROR_STOP on
select set_config('test.user_id','00000000-0000-4000-8000-000000000021',false);
select public.game_issue_recovery((select id from public.games where game_code='ASS100'),'abcdef0123456789abcdef0123456789');
select set_config('test.user_id','00000000-0000-4000-8000-000000000099',false);
do $$
begin
 if not public.game_recover('ASS100','first','abcdef0123456789abcdef0123456789') then
 raise exception 'Recovery unsuccessful';end if;
 if not exists(select 1 from public.game_memberships where game_id=(select id from public.games where game_code='ASS100')
 and codename='first' and user_id=auth.uid()) then
 raise exception 'Recovery did not transfer player identity';end if;
end $$;
-- Tokens can be used only once.
do $$
begin
 begin
 perform public.game_recover('ASS100','first','abcdef0123456789abcdef0123456789');
 raise exception 'SECURITY FAILURE: token reused';
 exception when raise_exception then
 if sqlerrm='SECURITY FAILURE: token reused' then raise; end if;
 end;
end $$;
select 'PASS: one-time player recovery' as result;
