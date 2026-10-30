-- 011: Host dashboard settings parity for original Assassins and Mafia games.
-- Passwords are replaced by authenticated, per-game host ownership; never store plaintext admin/reset passwords.
alter table public.assassins_config
 add column if not exists master_lock boolean not null default false,
 add column if not exists signup_enabled boolean not null default true,
 add column if not exists signup_off_message text not null default 'Registration is currently closed.',
 add column if not exists dashboard_off_message text not null default 'The player dashboard is temporarily unavailable.',
 add column if not exists eliminate_off_message text not null default 'Eliminations are currently disabled.',
 add column if not exists master_lock_message text not null default 'The game is temporarily unavailable.',
 add column if not exists last_updated timestamptz not null default now();

create or replace function public.assassins_host_setting(p_game_id uuid,p_key text,p_value text)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.games where id=p_game_id and owner_user_id=(select auth.uid()) and game_type='assassins') then raise exception 'Host only'; end if;
 insert into public.assassins_config(game_id) values(p_game_id) on conflict do nothing;
 if p_key in ('master_lock','signup_enabled','dashboard_enabled','eliminate_enabled','phone_enabled','hall_enabled','instructions_enabled','instruction_verification_enabled','paused') then
  if lower(p_value) not in ('true','false') then raise exception 'Expected true or false'; end if;
  execute format('update public.assassins_config set %I=$1::boolean,last_updated=now() where game_id=$2',p_key) using p_value,p_game_id;
 elsif p_key in ('hall_options','instructions_text','signup_off_message','dashboard_off_message','eliminate_off_message','master_lock_message') then
  if length(coalesce(p_value,''))>5000 then raise exception 'Setting too long'; end if;
  execute format('update public.assassins_config set %I=$1,last_updated=now() where game_id=$2',p_key) using p_value,p_game_id;
 else raise exception 'Unsupported setting'; end if;
end $$;
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
 'instructions_text',coalesce(c.instructions_text,''),'paused',coalesce(c.paused,false),
 'admin_password','Host account authentication','reset_password','Host account authentication');
end $$;
create or replace function public.assassins_join(p_code text,p_codename text,p_real_name text,p_phone text default '',p_hall text default '',p_accepted boolean default false)
returns uuid language plpgsql security definer set search_path='' as $$
declare g public.games%rowtype; c public.assassins_config%rowtype; v_code text:=lower(trim(p_codename)); v_name text:=trim(p_real_name);
begin
 if (select auth.uid()) is null then raise exception 'Sign in or continue as guest'; end if;
 select * into g from public.games where game_code=upper(trim(p_code)) and game_type='assassins' for update;
 if not found or g.status<>'registration' then raise exception 'Registration closed'; end if;
 insert into public.assassins_config(game_id) values(g.id) on conflict do nothing;
 select * into c from public.assassins_config where game_id=g.id;
 if c.master_lock or not c.signup_enabled then raise exception '%',case when c.master_lock then c.master_lock_message else c.signup_off_message end; end if;
 if v_code !~ '^[a-z0-9]+$' then raise exception 'Codename must use letters and numbers only'; end if;
 if char_length(v_code)>32 then raise exception 'Codename too long'; end if;
 if v_name is null or char_length(v_name)<2 or char_length(v_name)>120 then raise exception 'Enter your first and last name'; end if;
 if c.phone_enabled and nullif(trim(p_phone),'') is null then raise exception 'Phone is required'; end if;
 if c.hall_enabled and nullif(trim(p_hall),'') is null then raise exception 'Hall is required'; end if;
 if c.hall_enabled and not (trim(p_hall)=any(string_to_array(replace(c.hall_options,', ',','),','))) then raise exception 'Invalid hall'; end if;
 if c.instructions_enabled and c.instruction_verification_enabled and not p_accepted then raise exception 'Please accept the instructions'; end if;
 if exists(select 1 from public.game_memberships where game_id=g.id and user_id=(select auth.uid())) then raise exception 'You have already registered for this game'; end if;
 if exists(select 1 from public.game_memberships where game_id=g.id and lower(codename)=v_code) then raise exception 'Codename is taken'; end if;
 insert into public.game_memberships(game_id,user_id,codename,real_name,phone,hall)
 values(g.id,(select auth.uid()),v_code,v_name,case when c.phone_enabled then trim(p_phone) else null end,case when c.hall_enabled then trim(p_hall) else null end);
 return g.id;
end $$;

create or replace function public.assassins_confirm(p_game_id uuid,p_target_codename text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare g public.games%rowtype; c public.assassins_config%rowtype; me uuid; target uuid; target_name text; next_id uuid; next_name text;
begin
 select * into g from public.games where id=p_game_id for update;
 if not found or g.game_type<>'assassins' or g.status<>'active' then raise exception 'Game is not active'; end if;
 select * into c from public.assassins_config where game_id=p_game_id;
 if c.master_lock then raise exception '%',c.master_lock_message; end if;
 if c.paused or not c.eliminate_enabled or not c.dashboard_enabled then raise exception '%',c.eliminate_off_message; end if;
 select m.id into me from public.game_memberships m join public.assassins_players a on a.game_id=p_game_id and a.member_id=m.id and a.alive
 where m.game_id=p_game_id and m.user_id=(select auth.uid());
 if me is null then raise exception 'You are not an active player'; end if;
 select m.id,m.real_name into target,target_name from public.game_memberships m
 join public.assassins_players a on a.game_id=p_game_id and a.member_id=m.id and a.alive
 where m.game_id=p_game_id and lower(m.codename)=lower(trim(p_target_codename));
 if target is null then raise exception 'Invalid codename or player already eliminated'; end if;
 if target is distinct from public.assassins_target(p_game_id,me) then raise exception 'This player is not your assigned target'; end if;
 update public.assassins_players set alive=false,eliminated_by=me,eliminated_at=now()
 where game_id=p_game_id and member_id=target;
 insert into public.assassins_eliminations(game_id,assassin_id,target_id) values(p_game_id,me,target);
 next_id:=public.assassins_target(p_game_id,me);
 select real_name into next_name from public.game_memberships where id=next_id;
 if next_id is null then update public.games set status='finished' where id=p_game_id; end if;
 return jsonb_build_object('eliminated',target_name,'next_target',next_name,'winner',next_id is null);
end $$;

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
 'instructions_text',coalesce(c.instructions_text,''),'feed',v_feed);
end $$;

revoke all on function public.assassins_host_settings(uuid) from public,anon;
grant execute on function public.assassins_host_settings(uuid) to authenticated;

-- Original Mafia sheet labels preserved as host-dashboard keys.
alter table public.mafia_config add column if not exists min_active_for_game_end integer not null default 3 check(min_active_for_game_end between 1 and 100);
