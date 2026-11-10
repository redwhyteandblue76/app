-- 018: Announce the winner when a hosted Mafia game finishes.
-- Apply after migrations 010, 012 and 015 in the Supabase SQL Editor.
-- Does not alter past game results. Works for both player actions and host player updates.
begin;

alter table public.mafia_config
 add column if not exists winner_announcement text,
 add column if not exists previous_announcement text;

create or replace function public.mafia_announce_game_result()
returns trigger
language plpgsql security definer set search_path=''
as $winner$
declare
 v_mafia integer;
 v_others integer;
 v_total integer;
 v_min integer;
 v_message text;
begin
 if new.game_type<>'mafia' or new.status=old.status then return new; end if;

 -- Return to pre-game configuration after a host resets the game.
 if old.status='finished' and new.status in ('draft','registration') then
  update public.mafia_config
   set announcement=case
      when winner_announcement is not null and announcement=winner_announcement
        then coalesce(previous_announcement,'')
      else announcement end,
       winner_announcement=null,
       previous_announcement=null
   where game_id=new.id;
  return new;
 end if;

 -- Never claim a winner merely because a host manually ends a game.
 if old.status<>'active' or new.status<>'finished' then return new; end if;

 select count(*) filter(where alive and role='mafia'),
        count(*) filter(where alive and role in ('citizen','detective')),
        count(*) filter(where alive)
 into v_mafia,v_others,v_total
 from public.mafia_players where game_id=new.id;
 select min_active_for_game_end into v_min
 from public.mafia_config where game_id=new.id;

 if v_mafia=0 then
  v_message:='🎉 Citizens Win! All Mafia members have been eliminated. The citizens have won the game!';
 elsif v_mafia>=v_others or v_total<=coalesce(v_min,3) then
  v_message:='🎉 Mafia Wins! The Mafia has taken control of the game. The Mafia has won!';
 else
  -- This is an administrative finish, not a rules-determined victory.
  return new;
 end if;

 update public.mafia_config
 set previous_announcement=case when winner_announcement is null
       then announcement else previous_announcement end,
     winner_announcement=v_message,
     announcement=v_message
 where game_id=new.id;

 insert into public.mafia_log(game_id,event_type,message)
 values(new.id,'winner',v_message);
 return new;
end
$winner$;

drop trigger if exists mafia_result_announcement on public.games;
create trigger mafia_result_announcement
 after update of status on public.games
 for each row
 when (new.game_type='mafia' and old.status is distinct from new.status)
 execute function public.mafia_announce_game_result();

commit;
