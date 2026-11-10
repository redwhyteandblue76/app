-- 019: Editable full Assassins rules, separate from supplementary administrator instructions.
-- Requires migrations 011 and 017. Run in Supabase SQL Editor.
begin;
alter table public.assassins_config add column if not exists full_rules_text text not null default '';
update public.assassins_config set full_rules_text=$rules$THE OVERVIEW
Your mission is to find your assigned target and tag them with a soft sock. After a valid tag, they must reveal their codename. Enter it in the Player Dashboard to confirm the elimination and receive your next target.

HOW TO JOIN
Sign up while registration is open. Choose a private codename and keep it secret.

ONCE THE GAME BEGINS
1. Keep your codename private except to the player who successfully eliminates you.
2. Open the Player Dashboard, sign in with your codename and PIN, and select Find My Target.
3. Find your target and tag them with a soft sock in a permitted location.
4. Request the eliminated player's codename after a valid elimination.
5. Return to the dashboard, select Eliminate a Player, enter their codename, and confirm.
6. Receive your next target and continue playing.

SAFE ZONES
No eliminations or attempts during class, Campus Community, Convocation, on a dorm hall, at work, or during leadership responsibilities including RA/RS/CGL connect classes and RHLMs.

SAFE ITEMS
The designated safe item protects you only while it is IN YOUR HAND. Check the group chat for changes.

HOW TO WIN
There are two winners: the final surviving player and the player with the most confirmed eliminations.

PLAY SAFELY
Use only soft socks, avoid the face, respect personal boundaries, and never chase anyone into unsafe or restricted areas. Contact the game administrator for disputed eliminations.$rules$ where full_rules_text='';
alter table public.assassins_config alter column full_rules_text set default $rules$THE OVERVIEW
Your mission is to find your assigned target and tag them with a soft sock. After a valid tag, they must reveal their codename. Enter it in the Player Dashboard to confirm the elimination and receive your next target.

HOW TO JOIN
Sign up while registration is open. Choose a private codename and keep it secret.

ONCE THE GAME BEGINS
1. Keep your codename private except to the player who successfully eliminates you.
2. Open the Player Dashboard, sign in with your codename and PIN, and select Find My Target.
3. Find your target and tag them with a soft sock in a permitted location.
4. Request the eliminated player's codename after a valid elimination.
5. Return to the dashboard, select Eliminate a Player, enter their codename, and confirm.
6. Receive your next target and continue playing.

SAFE ZONES
No eliminations or attempts during class, Campus Community, Convocation, on a dorm hall, at work, or during leadership responsibilities including RA/RS/CGL connect classes and RHLMs.

SAFE ITEMS
The designated safe item protects you only while it is IN YOUR HAND. Check the group chat for changes.

HOW TO WIN
There are two winners: the final surviving player and the player with the most confirmed eliminations.

PLAY SAFELY
Use only soft socks, avoid the face, respect personal boundaries, and never chase anyone into unsafe or restricted areas. Contact the game administrator for disputed eliminations.$rules$;
update public.game_default_settings
set settings=jsonb_set(settings,'{full_rules_text}',to_jsonb($rules$THE OVERVIEW
Your mission is to find your assigned target and tag them with a soft sock. After a valid tag, they must reveal their codename. Enter it in the Player Dashboard to confirm the elimination and receive your next target.

HOW TO JOIN
Sign up while registration is open. Choose a private codename and keep it secret.

ONCE THE GAME BEGINS
1. Keep your codename private except to the player who successfully eliminates you.
2. Open the Player Dashboard, sign in with your codename and PIN, and select Find My Target.
3. Find your target and tag them with a soft sock in a permitted location.
4. Request the eliminated player's codename after a valid elimination.
5. Return to the dashboard, select Eliminate a Player, enter their codename, and confirm.
6. Receive your next target and continue playing.

SAFE ZONES
No eliminations or attempts during class, Campus Community, Convocation, on a dorm hall, at work, or during leadership responsibilities including RA/RS/CGL connect classes and RHLMs.

SAFE ITEMS
The designated safe item protects you only while it is IN YOUR HAND. Check the group chat for changes.

HOW TO WIN
There are two winners: the final surviving player and the player with the most confirmed eliminations.

PLAY SAFELY
Use only soft socks, avoid the face, respect personal boundaries, and never chase anyone into unsafe or restricted areas. Contact the game administrator for disputed eliminations.$rules$::text),true),updated_at=now()
where game_type='assassins' and not (settings ? 'full_rules_text');

create or replace function public.assassins_host_setting(p_game_id uuid,p_key text,p_value text)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.games where id=p_game_id and owner_user_id=(select auth.uid()) and game_type='assassins') then raise exception 'Host only'; end if;
 insert into public.assassins_config(game_id) values(p_game_id) on conflict do nothing;
 if p_key in ('master_lock','signup_enabled','dashboard_enabled','eliminate_enabled','phone_enabled','hall_enabled','instructions_enabled','instruction_verification_enabled','paused') then
  if lower(p_value) not in ('true','false') then raise exception 'Expected true or false'; end if;
  execute format('update public.assassins_config set %I=$1::boolean,last_updated=now() where game_id=$2',p_key) using p_value,p_game_id;
 elsif p_key in ('hall_options','instructions_text','full_rules_text','signup_off_message','dashboard_off_message','eliminate_off_message','master_lock_message') then
  if length(coalesce(p_value,''))>case when p_key='full_rules_text' then 12000 else 5000 end then raise exception 'Setting too long'; end if;
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
 'instructions_text',coalesce(c.instructions_text,''),'full_rules_text',coalesce(c.full_rules_text,''),'paused',coalesce(c.paused,false),
 'admin_password','Host account authentication','reset_password','Host account authentication');
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
 'instructions_text',coalesce(c.instructions_text,''),'full_rules_text',coalesce(c.full_rules_text,''),'feed',v_feed);
end $$;

create or replace function public.admin_game_defaults(p_game_type text default null, p_settings jsonb default null)
returns jsonb language plpgsql security definer set search_path='' as $defaults$
declare
 v_allowed jsonb; v_entry record; v_kind text; v_min integer; v_max integer;
 v_result jsonb;
begin
 if (select auth.uid()) is null or not public.is_platform_admin() then
  raise exception 'Administrator only';
 end if;
 if p_game_type is not null and p_game_type not in ('assassins','mafia') then
  raise exception 'Unknown game type';
 end if;
 if p_settings is not null then
  if p_game_type is null or jsonb_typeof(p_settings)<>'object' then
   raise exception 'Choose one game type and send a settings object';
  end if;
  if length(p_settings::text)>30000 then raise exception 'Settings too large';end if;
  v_allowed:=case p_game_type
   when 'assassins' then '{"master_lock":"boolean","signup_enabled":"boolean","dashboard_enabled":"boolean","eliminate_enabled":"boolean","phone_enabled":"boolean","hall_enabled":"boolean","hall_options":"string","instructions_enabled":"boolean","instruction_verification_enabled":"boolean","instructions_text":"string","full_rules_text":"string","paused":"boolean","signup_off_message":"string","dashboard_off_message":"string","eliminate_off_message":"string","master_lock_message":"string"}'::jsonb
   when 'mafia' then '{"setup_enabled":"boolean","dashboard_enabled":"boolean","game_active":"boolean","hall_field_enabled":"boolean","hall_options":"string","allow_mafia_votes":"boolean","allow_detective_votes":"boolean","mafia_cooldown_hours":"integer","detective_cooldown_hours":"integer","citizen_cooldown_hours":"integer","votes_required":"integer","vote_expiry_hours":"integer","vote_expiration_minutes":"integer","min_active_for_game_end":"integer","mafia_instructions":"string","detective_instructions":"string","citizen_instructions":"string","game_instructions":"string","announcement":"string"}'::jsonb end;
  for v_entry in select key,value from jsonb_each(p_settings) loop
   v_kind:=v_allowed->>v_entry.key;
   if v_kind is null then raise exception 'Unsupported default setting: %',v_entry.key;end if;
   if v_kind='boolean' and jsonb_typeof(v_entry.value)<>'boolean' then
    raise exception 'Expected true or false for %',v_entry.key;
   elsif v_kind='string' and
     (jsonb_typeof(v_entry.value)<>'string' or length(v_entry.value #>> '{}')>case when v_entry.key='full_rules_text' then 12000 else 5000 end) then
    raise exception 'Invalid text for % (length limit exceeded)',v_entry.key;
   elsif v_kind='integer' then
    if jsonb_typeof(v_entry.value)<>'number' or (v_entry.value #>> '{}') !~ '^[0-9]+$' then
     raise exception 'Expected a nonnegative whole number for %',v_entry.key;
    end if;
    v_min:=case when v_entry.key in ('votes_required','vote_expiry_hours','vote_expiration_minutes','min_active_for_game_end') then 1 else 0 end;
    v_max:=case when v_entry.key='vote_expiration_minutes' then 43200
      when v_entry.key in ('votes_required','min_active_for_game_end') then 100 else 720 end;
    if (v_entry.value #>> '{}')::numeric not between v_min and v_max then
     raise exception '% must be between % and %',v_entry.key,v_min,v_max;
    end if;
   end if;
  end loop;
  -- Merge with existing defaults, preserving other values; validate before write.
  update public.game_default_settings
   set settings=settings||p_settings,updated_at=now()
   where game_type=p_game_type;
  if not found then raise exception 'Default template missing';end if;
 end if;
 select coalesce(jsonb_object_agg(game_type,settings),'{}'::jsonb)
 into v_result from public.game_default_settings
 where p_game_type is null or game_type=p_game_type;
 return v_result;
end $defaults$;
commit;
