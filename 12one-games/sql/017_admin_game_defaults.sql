-- 017: Administrator-managed defaults for NEW Assassins and Mafia games.
-- Apply AFTER migration 015 (and the 011/012 settings migrations) in Supabase SQL Editor.
-- Existing game configuration rows are never modified by this migration or subsequent saves.
begin;

create table if not exists public.game_default_settings (
 game_type text primary key check(game_type in ('assassins','mafia')),
 settings jsonb not null check(jsonb_typeof(settings)='object'),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
alter table public.game_default_settings enable row level security;
revoke all on public.game_default_settings from public, anon, authenticated;

insert into public.game_default_settings(game_type,settings) values
 ('assassins', '{"master_lock":false,"signup_enabled":true,"dashboard_enabled":true,"eliminate_enabled":true,"phone_enabled":false,"hall_enabled":false,"hall_options":"","instructions_enabled":false,"instruction_verification_enabled":false,"instructions_text":"","paused":false,"signup_off_message":"Registration is currently closed.","dashboard_off_message":"The player dashboard is temporarily unavailable.","eliminate_off_message":"Eliminations are currently disabled.","master_lock_message":"The game is temporarily unavailable."}'::jsonb),
 ('mafia', '{"setup_enabled":true,"dashboard_enabled":true,"game_active":true,"hall_field_enabled":false,"hall_options":"","allow_mafia_votes":true,"allow_detective_votes":true,"mafia_cooldown_hours":24,"detective_cooldown_hours":24,"citizen_cooldown_hours":24,"votes_required":3,"vote_expiry_hours":24,"vote_expiration_minutes":1440,"min_active_for_game_end":3,"mafia_instructions":"Mafia: find your target, learn their codename, then record the elimination. Do not reveal your team.","detective_instructions":"Detective: quietly investigate suspects and share your findings without exposing your role.","citizen_instructions":"Citizen: discuss suspects and coordinate votes. Reaching the voting threshold eliminates a player.","game_instructions":"Continuous Mafia: sign up, receive a secret role, and play through the player dashboard. Keep your dashboard private.","announcement":""}'::jsonb)
on conflict (game_type) do nothing;

-- Only the platform admin can read or change shared game defaults.
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
   when 'assassins' then '{"master_lock":"boolean","signup_enabled":"boolean","dashboard_enabled":"boolean","eliminate_enabled":"boolean","phone_enabled":"boolean","hall_enabled":"boolean","hall_options":"string","instructions_enabled":"boolean","instruction_verification_enabled":"boolean","instructions_text":"string","paused":"boolean","signup_off_message":"string","dashboard_off_message":"string","eliminate_off_message":"string","master_lock_message":"string"}'::jsonb
   when 'mafia' then '{"setup_enabled":"boolean","dashboard_enabled":"boolean","game_active":"boolean","hall_field_enabled":"boolean","hall_options":"string","allow_mafia_votes":"boolean","allow_detective_votes":"boolean","mafia_cooldown_hours":"integer","detective_cooldown_hours":"integer","citizen_cooldown_hours":"integer","votes_required":"integer","vote_expiry_hours":"integer","vote_expiration_minutes":"integer","min_active_for_game_end":"integer","mafia_instructions":"string","detective_instructions":"string","citizen_instructions":"string","game_instructions":"string","announcement":"string"}'::jsonb end;
  for v_entry in select key,value from jsonb_each(p_settings) loop
   v_kind:=v_allowed->>v_entry.key;
   if v_kind is null then raise exception 'Unsupported default setting: %',v_entry.key;end if;
   if v_kind='boolean' and jsonb_typeof(v_entry.value)<>'boolean' then
    raise exception 'Expected true or false for %',v_entry.key;
   elsif v_kind='string' and
     (jsonb_typeof(v_entry.value)<>'string' or length(v_entry.value #>> '{}')>5000) then
    raise exception 'Invalid text for % (max 5000 characters)',v_entry.key;
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
revoke all on function public.admin_game_defaults(text,jsonb) from public,anon;
grant execute on function public.admin_game_defaults(text,jsonb) to authenticated;

-- Initialize config for newly created games. The config BEFORE INSERT triggers
-- apply the current admin template; later changes never touch existing config rows.
create or replace function public.apply_game_default_settings()
returns trigger language plpgsql security definer set search_path='' as $apply$
declare v_settings jsonb; v_since timestamptz; v_created timestamptz;
begin
 select d.settings,d.created_at into v_settings,v_since
 from public.game_default_settings d
 where d.game_type=case TG_TABLE_NAME when 'assassins_config' then 'assassins' else 'mafia' end;
 select created_at into v_created from public.games where id=new.game_id;
 if v_settings is not null and v_created>=v_since then
  new:=jsonb_populate_record(new,v_settings);
 end if;
 return new;
end $apply$;
drop trigger if exists apply_assassins_defaults on public.assassins_config;
create trigger apply_assassins_defaults before insert on public.assassins_config
for each row execute function public.apply_game_default_settings();
drop trigger if exists apply_mafia_defaults on public.mafia_config;
create trigger apply_mafia_defaults before insert on public.mafia_config
for each row execute function public.apply_game_default_settings();

create or replace function public.initialize_new_game_settings()
returns trigger language plpgsql security definer set search_path='' as $initialize$
begin
 if new.game_type='assassins' then
  insert into public.assassins_config(game_id) values(new.id) on conflict do nothing;
 elsif new.game_type='mafia' then
  insert into public.mafia_config(game_id) values(new.id) on conflict do nothing;
 end if;
 return new;
end $initialize$;
drop trigger if exists initialize_game_defaults on public.games;
create trigger initialize_game_defaults after insert on public.games
for each row when (new.game_type in ('assassins','mafia'))
execute function public.initialize_new_game_settings();

commit;
