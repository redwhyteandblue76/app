-- 12ONE Games: expose a safe boolean check for showing the owner UI.
-- Run after migrations 001 and 002.
create or replace function public.is_platform_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null
    and exists (
      select 1 from public.platform_admins
      where user_id = (select auth.uid())
    );
$$;
revoke all on function public.is_platform_admin() from public, anon;
grant execute on function public.is_platform_admin() to authenticated;
