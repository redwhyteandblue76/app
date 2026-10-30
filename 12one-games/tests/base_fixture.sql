-- Disposable PostgreSQL fixture representing the database immediately after migration 007.
-- Never run this fixture against production.
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create schema if not exists auth;
create role anon nologin;
create role authenticated nologin;
create or replace function auth.uid() returns uuid language sql stable as $$
 select nullif(current_setting('test.user_id',true),'')::uuid $$;
create table public.games(
 id uuid primary key default gen_random_uuid(),
 owner_user_id uuid not null, game_type text not null,
 status text not null default 'draft', game_code text not null unique,
 name text not null default 'Test game'
);
create table public.game_memberships(
 id uuid primary key default gen_random_uuid(),
 game_id uuid not null references public.games(id) on delete cascade,
 user_id uuid not null, codename text not null, real_name text,
 phone text, hall text, joined_at timestamptz not null default now(),
 unique(game_id,user_id),unique(game_id,codename)
);
create table public.assassins_config(
 game_id uuid primary key references public.games(id) on delete cascade,
 dashboard_enabled boolean not null default true,
 eliminate_enabled boolean not null default true,
 phone_enabled boolean not null default false,
 hall_enabled boolean not null default false,
 hall_options text not null default '',
 instructions_enabled boolean not null default false,
 instruction_verification_enabled boolean not null default false,
 instructions_text text not null default '',
 paused boolean not null default false
);
create table public.assassins_players(
 game_id uuid not null references public.games(id) on delete cascade,
 member_id uuid not null references public.game_memberships(id) on delete cascade,
 turn_order integer not null, alive boolean not null default true,
 eliminated_by uuid, eliminated_at timestamptz,
 primary key(game_id,member_id),unique(game_id,turn_order)
);
create table public.assassins_eliminations(
 id uuid primary key default gen_random_uuid(),
 game_id uuid not null references public.games(id) on delete cascade,
 assassin_id uuid not null references public.game_memberships(id),
 target_id uuid not null references public.game_memberships(id),
 created_at timestamptz not null default now()
);
create or replace function public.assassins_target(p_game_id uuid,p_member_id uuid)
returns uuid language sql stable security definer set search_path='' as $$
 select a.member_id from public.assassins_players a
 where a.game_id=p_game_id and a.alive and a.member_id<>p_member_id
 order by case when a.turn_order>(select turn_order from public.assassins_players where game_id=p_game_id and member_id=p_member_id)
 then 0 else 1 end,a.turn_order limit 1 $$;
