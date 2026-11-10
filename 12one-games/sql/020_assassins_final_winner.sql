-- 020: Announce the final surviving Assassins player after a confirmed last elimination.
-- Requires migrations 011 and 019. Run once in Supabase SQL Editor.
begin;

alter table public.assassins_config
 add column if not exists winner_announcement text not null default '';

-- A confirmed elimination is the only way to declare the last-survivor winner
-- automatically: host status edits and administrative removals do not trigger this.
create or replace function public.assassins_announce_final_elimination()
returns trigger language plpgsql security definer set search_path='' as $winner$
declare
 v_remaining integer;
 v_survivor uuid;
 v_name text;
begin
 if not exists(
  select 1 from public.games
  where id=new.game_id and game_type='assassins' and status='active'
 ) then return new; end if;
 select count(*) into v_remaining
 from public.assassins_players where game_id=new.game_id and alive;
 if v_remaining=1 then
  select member_id into v_survivor
  from public.assassins_players where game_id=new.game_id and alive limit 1;
 end if;
 if v_remaining=1 and v_survivor=new.assassin_id then
  select real_name into v_name from public.game_memberships
  where id=v_survivor and game_id=new.game_id;
  if v_name is not null then
   update public.assassins_config set
    winner_announcement='🏆 '||v_name||' wins Assassins! The final opponent has been eliminated. '||
     v_name||' is the last player standing!'
   where game_id=new.game_id;
  end if;
 end if;
 return new;
end; $winner$;

drop trigger if exists assassins_last_elimination_announcement on public.assassins_eliminations;
create trigger assassins_last_elimination_announcement
after insert on public.assassins_eliminations
for each row execute function public.assassins_announce_final_elimination();

-- Clear the previous victory if the host resets or reopens a finished game.
create or replace function public.assassins_clear_winner_on_reopen()
returns trigger language plpgsql security definer set search_path='' as $reset$
begin
 if new.game_type='assassins' and old.status='finished' and new.status<>'finished' then
  update public.assassins_config
   set winner_announcement='' where game_id=new.id;
 end if;
 return new;
end; $reset$;

drop trigger if exists assassins_clear_winner_on_reopen on public.games;
create trigger assassins_clear_winner_on_reopen
after update of status on public.games
for each row
when (new.game_type='assassins' and old.status='finished' and new.status<>'finished')
execute function public.assassins_clear_winner_on_reopen();

create or replace function public.assassins_v2_public(p_code text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare g public.games%rowtype; c public.assassins_config%rowtype; v_feed jsonb;
begin
 select * into g from public.games where game_code=upper(trim(p_code)) and game_type='assassins';
 if not found then raise exception 'Assassins game not found'; end if;
 select * into c from public.assassins_config where game_id=g.id;
 select coalesce(jsonb_agg(jsonb_build_object('details',victim.real_name||' was eliminated by '||killer.real_name,'time',e.created_at) order by e.created_at desc),'[]'::jsonb)
 into v_feed from public.assassins_eliminations e
 join public.game_memberships victim on victim.id=e.target_id
 join public.game_memberships killer on killer.id=e.assassin_id where e.game_id=g.id;
 return jsonb_build_object('id',g.id,'status',g.status,'paused',coalesce(c.paused,false),
 'master_lock',coalesce(c.master_lock,false),'signup_enabled',coalesce(c.signup_enabled,true),
 'signup_off_message',coalesce(c.signup_off_message,''),'dashboard_off_message',coalesce(c.dashboard_off_message,''),
 'eliminate_off_message',coalesce(c.eliminate_off_message,''),'master_lock_message',coalesce(c.master_lock_message,''),
 'dashboard_enabled',coalesce(c.dashboard_enabled,true),'eliminate_enabled',coalesce(c.eliminate_enabled,true),
 'phone_enabled',coalesce(c.phone_enabled,false),'hall_enabled',coalesce(c.hall_enabled,false),
 'hall_options',coalesce(c.hall_options,''),'instructions_enabled',coalesce(c.instructions_enabled,false),
 'instruction_verification_enabled',coalesce(c.instruction_verification_enabled,false),
 'instructions_text',coalesce(c.instructions_text,''),'full_rules_text',coalesce(c.full_rules_text,''),
  'winner_announcement',case when g.status='finished' then coalesce(c.winner_announcement,'') else '' end,'feed',v_feed);
end; $$;

create or replace function public.assassins_host_settings(p_game_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c public.assassins_config%rowtype; g public.games%rowtype;
begin
 select * into g from public.games where id=p_game_id and game_type='assassins' and owner_user_id=(select auth.uid());
 if not found then raise exception 'Host only'; end if;
 select * into c from public.assassins_config where game_id=p_game_id;
 return jsonb_build_object(
 'master_lock',coalesce(c.master_lock,false),'game_status',g.status,
 'signup_enabled',coalesce(c.signup_enabled,true),'dashboard_enabled',coalesce(c.dashboard_enabled,true),
 'eliminate_enabled',coalesce(c.eliminate_enabled,true),
 'signup_off_message',coalesce(c.signup_off_message,''),'dashboard_off_message',coalesce(c.dashboard_off_message,''),
 'eliminate_off_message',coalesce(c.eliminate_off_message,''),'master_lock_message',coalesce(c.master_lock_message,''),
 'last_updated',c.last_updated,'hall_field_enabled',coalesce(c.hall_enabled,false),
 'hall_options',coalesce(c.hall_options,''),'phone_field_enabled',coalesce(c.phone_enabled,false),
 'instructions_enabled',coalesce(c.instructions_enabled,false),
 'instruction_verification_enabled',coalesce(c.instruction_verification_enabled,false),
 'instructions_text',coalesce(c.instructions_text,''),'full_rules_text',coalesce(c.full_rules_text,''),
  'winner_announcement',case when g.status='finished' then coalesce(c.winner_announcement,'') else '' end,'paused',coalesce(c.paused,false),
 'admin_password','Host account authentication','reset_password','Host account authentication');
end; $$;

commit;
