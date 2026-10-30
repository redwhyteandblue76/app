-- Migration 005: secure game lookup, joining, and public lobby codenames
-- Run after 001-004. Only registration-status games accept new players.
create or replace function public.lookup_joinable_game(p_code text)
returns table(game_id uuid, game_name text, game_type text, game_status text)
language sql stable security definer set search_path = ''
as $$
 select g.id, g.name::text, g.game_type::text, g.status::text
 from public.games g
 where g.game_code = upper(trim(p_code))
 and g.status in ('draft','registration','active','finished')
 limit 1;
$$;
revoke all on function public.lookup_joinable_game(text) from public;
grant execute on function public.lookup_joinable_game(text) to anon, authenticated;

create or replace function public.join_game(p_code text, p_codename text)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_user uuid := (select auth.uid()); v_game uuid; v_name text := trim(p_codename);
begin
 if v_user is null then raise exception 'Sign in or continue as guest first'; end if;
 if v_name is null or char_length(v_name) < 2 or char_length(v_name) > 32
    or v_name !~ '^[[:alnum:] _-]+$' then
    raise exception 'Codename must be 2-32 letters, numbers, spaces, hyphens, or underscores';
 end if;
 select g.id into v_game from public.games g
 where g.game_code = upper(trim(p_code)) and g.status = 'registration'
 for update;
 if v_game is null then raise exception 'Game not found or registration is closed'; end if;
 if exists(select 1 from public.game_memberships m where m.game_id=v_game and m.user_id=v_user) then
   return v_game;
 end if;
 insert into public.game_memberships(game_id,user_id,codename)
 values(v_game,v_user,v_name);
 return v_game;
exception when unique_violation then
 raise exception 'Codename is already taken in this game';
end;
$$;
revoke all on function public.join_game(text,text) from public, anon;
grant execute on function public.join_game(text,text) to authenticated;

create or replace function public.list_game_lobby(p_game_id uuid)
returns table(codename text, joined_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
begin
 if (select auth.uid()) is null or not exists(
  select 1 from public.games g where g.id=p_game_id and g.owner_user_id=(select auth.uid())
 ) and not exists(
  select 1 from public.game_memberships m where m.game_id=p_game_id and m.user_id=(select auth.uid())
 ) then raise exception 'Not a participant in this game'; end if;
 return query select m.codename::text,m.joined_at from public.game_memberships m
 where m.game_id=p_game_id order by m.joined_at;
end;
$$;
revoke all on function public.list_game_lobby(uuid) from public, anon;
grant execute on function public.list_game_lobby(uuid) to authenticated;

create or replace function public.set_game_registration(p_game_id uuid,p_open boolean)
returns void language plpgsql security definer set search_path = ''
as $$
begin
 if (select auth.uid()) is null then raise exception 'Authentication required'; end if;
 update public.games set status=case when p_open then 'registration' else 'draft' end
 where id=p_game_id and owner_user_id=(select auth.uid())
 and status in ('draft','registration');
 if not found then raise exception 'Game not found, not owned, or already started'; end if;
end;
$$;
revoke all on function public.set_game_registration(uuid,boolean) from public, anon;
grant execute on function public.set_game_registration(uuid,boolean) to authenticated;
