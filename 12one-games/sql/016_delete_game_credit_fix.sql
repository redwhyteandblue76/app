-- 016: Repair deletion of completed games with consumed game credits.
-- Spent credits remain spent; unused credits are preserved.
begin;
create or replace function public.host_manage_game(p_game_id uuid,p_action text,p_value text default '')
returns jsonb language plpgsql security definer set search_path='' as $$
declare g public.games%rowtype; v_admin boolean; v_label text; v_spent integer:=0;
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
  -- Retire consumed credit rows, but never refund them or touch unused credits.
  select count(*) into v_spent from public.game_credits
    where consumed_by_game_id=p_game_id and consumed_at is not null;
  if exists(select 1 from public.game_credits where consumed_by_game_id=p_game_id and consumed_at is null)
  then raise exception 'Inconsistent credit record; cannot delete game';end if;
  delete from public.game_credits where consumed_by_game_id=p_game_id and consumed_at is not null;
  delete from public.games where id=p_game_id;
  v_label:='Permanently deleted game; '||v_spent||' spent credit row(s) retired, no refund';
 else raise exception 'Unsupported game action';end if;
 insert into public.host_events(game_id,host_id,action,game_name,details)
 values(case when p_action='delete' then null else p_game_id end,
 (select auth.uid()),p_action,g.name,v_label);
 return jsonb_build_object('success',true);
end $$;

commit;
