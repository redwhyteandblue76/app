-- Disposable-only fixtures to test host management; never run in Supabase.
alter table public.games add column if not exists created_at timestamptz not null default now();
create table if not exists auth.users (
 id uuid primary key,
 email text,
 created_at timestamptz not null default now(),
 raw_user_meta_data jsonb not null default '{}'::jsonb,
 is_anonymous boolean not null default false
);
create table if not exists public.platform_admins(user_id uuid primary key);
create table if not exists public.game_credits(
 id uuid primary key default gen_random_uuid(),
 consumed_by_game_id uuid references public.games(id),
 consumed_at timestamptz,
 constraint credit_consumption_consistent check ((consumed_by_game_id is null and consumed_at is null) or (consumed_by_game_id is not null and consumed_at is not null))
);
create or replace function public.is_platform_admin()
returns boolean language sql stable as $auth$
 select exists(select 1 from public.platform_admins where user_id=auth.uid());
$auth$;
insert into auth.users(id,email,raw_user_meta_data) values
 ('00000000-0000-4000-8000-000000000001','admin@example.test','{"full_name":"Primary Administrator"}'),
 ('00000000-0000-4000-8000-000000000002','host2@example.test','{"full_name":"Second Host"}'),
 ('00000000-0000-4000-8000-000000000099','intruder@example.test','{}')
on conflict do nothing;
insert into public.platform_admins(user_id) values('00000000-0000-4000-8000-000000000001')
on conflict do nothing;
insert into public.games(owner_user_id,game_type,status,game_code,name) values
 ('00000000-0000-4000-8000-000000000002','assassins','registration','HOST02','Host Two Game');
insert into public.game_credits(consumed_by_game_id,consumed_at)
select id,now() from public.games where game_code='HOST02';
