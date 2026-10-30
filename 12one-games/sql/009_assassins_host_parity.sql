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
