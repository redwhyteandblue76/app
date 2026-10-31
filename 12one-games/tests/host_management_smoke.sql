\set ON_ERROR_STOP on
-- A different host cannot read, export or modify another host's records.
select set_config('test.user_id','00000000-0000-4000-8000-000000000099',false);
do $test$
declare g uuid;
begin
 select id into g from public.games where game_code='HOST02';
 begin
  perform public.host_manage_game(g,'end','');
  raise exception 'SECURITY FAILURE: unauthorized host changed game';
 exception when raise_exception then
  if sqlerrm like 'SECURITY FAILURE%' then raise; end if;
 end;
 begin
  perform public.host_export_game(g);
  raise exception 'SECURITY FAILURE: unauthorized host exported game';
 exception when raise_exception then
  if sqlerrm like 'SECURITY FAILURE%' then raise; end if;
 end;
 begin
  perform public.host_player_contacts(g);
  raise exception 'SECURITY FAILURE: unauthorized host read contacts';
 exception when raise_exception then
  if sqlerrm like 'SECURITY FAILURE%' then raise; end if;
 end;
 begin
  perform public.host_admin_directory();
  raise exception 'SECURITY FAILURE: non-admin read directory';
 exception when raise_exception then
  if sqlerrm like 'SECURITY FAILURE%' then raise; end if;
 end;
end $test$;

-- Host may rename, end, archive, export, and delete only their game.
select set_config('test.user_id','00000000-0000-4000-8000-000000000002',false);
select public.host_manage_game((select id from public.games where game_code='HOST02'),'rename','New Host Name');
do $test$
begin
 if (select name from public.games where game_code='HOST02')<>'New Host Name' then
 raise exception 'Rename failed'; end if;
end $test$;
select public.host_manage_game((select id from public.games where game_code='HOST02'),'end','');
do $test$
begin
 if (select status from public.games where game_code='HOST02')<>'finished' then
 raise exception 'Ending game failed'; end if;
end $test$;
select public.host_manage_game((select id from public.games where game_code='HOST02'),'archive','');
select public.host_export_game((select id from public.games where game_code='HOST02'));
select public.host_manage_game((select id from public.games where game_code='HOST02'),'delete','');
do $test$
begin
 if exists(select 1 from public.games where game_code='HOST02') then raise exception 'Game was not deleted'; end if;
 if not exists(select 1 from public.game_credits where consumed_at is not null and consumed_by_game_id is null) then
 raise exception 'Spent credit not retained'; end if;
 if not exists(select 1 from public.host_events where action='delete' and game_name='New Host Name') then
 raise exception 'Deletion audit missing'; end if;
end $test$;

-- Platform admin sees host directory but must use explicit authorization.
select set_config('test.user_id','00000000-0000-4000-8000-000000000001',false);
do $test$
declare v jsonb;
begin
 v:=public.host_admin_directory();
 if jsonb_array_length(v->'hosts')<2 then raise exception 'Host directory incomplete';end if;
end $test$;
select 'PASS: host permissions, export, end, archive, deletion and credit retention' as result;
