-- Minimal Supabase-compatible schema for isolated migration integration tests only.
-- This file must NEVER be applied to the live project.
create extension if not exists pgcrypto;
create schema if not exists auth;
create or replace function auth.uid() returns uuid language sql stable as $$
 select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid
$$;
do $$begin
 if not exists(select 1 from pg_roles where rolname='anon') then create role anon; end if;
 if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
end$$;
create table public.games (
 id uuid primary key default gen_random_uuid(),
 game_code text not null unique,
 name text not null default '',
 game_type text not null,
 status text not null default 'draft',
 owner_user_id uuid not null,
 created_at timestamptz not null default now()
);
create table public.game_memberships (
 id uuid primary key default gen_random_uuid(),
 game_id uuid not null references public.games(id) on delete cascade,
 user_id uuid not null,
 codename text not null,
 joined_at timestamptz not null default now(),
 unique(game_id,user_id),
 unique(game_id,codename)
);
create table public.assassins_players (
 game_id uuid not null references public.games(id) on delete cascade,
 member_id uuid not null references public.game_memberships(id) on delete cascade,
 turn_order integer not null,
 alive boolean not null default true,
 primary key(game_id,member_id),
 unique(game_id,turn_order)
);
create table public.assassins_reports (
 game_id uuid not null references public.games(id) on delete cascade,
 id uuid primary key default gen_random_uuid()
);
create or replace function public.assassins_report(p_game_id uuid)
returns void language sql as $$select null::void$$;
create or replace function public.assassins_resolve(p_game_id uuid,p_approve boolean)
returns void language sql as $$select null::void$$;
