-- 013: Secure one-use recovery tokens for anonymous game player sessions.
-- Tokens generated client-side using crypto.getRandomValues (128-bit), never persisted in plaintext.
create table if not exists public.game_recovery_tokens (
 game_id uuid not null references public.games(id) on delete cascade,
 member_id uuid not null references public.game_memberships(id) on delete cascade,
 token_hash text not null,
 created_at timestamptz not null default now(),
 primary key(game_id,member_id),
 unique(game_id,token_hash)
);
alter table public.game_recovery_tokens enable row level security;
revoke all on public.game_recovery_tokens from anon,authenticated;

create or replace function public.game_issue_recovery(p_game_id uuid,p_token text)
returns boolean language plpgsql security definer set search_path='' as $$
declare v_member uuid;
begin
 if (select auth.uid()) is null then raise exception 'Guest session required'; end if;
 if p_token !~ '^[a-f0-9]{32}$' then raise exception 'Invalid recovery code format'; end if;
 select id into v_member from public.game_memberships where game_id=p_game_id and user_id=(select auth.uid());
 if v_member is null then raise exception 'Not registered in this game'; end if;
 insert into public.game_recovery_tokens(game_id,member_id,token_hash)
 values(p_game_id,v_member,encode(public.digest(p_token,'sha256'),'hex'))
 on conflict(game_id,member_id) do update set token_hash=excluded.token_hash,created_at=now();
 return true;
end $$;

create or replace function public.game_recover(p_code text,p_codename text,p_token text)
returns boolean language plpgsql security definer set search_path='' as $$
declare g public.games%rowtype; target_member uuid; v_user uuid:=(select auth.uid());
begin
 if v_user is null then raise exception 'Guest session required'; end if;
 if p_token !~ '^[a-f0-9]{32}$' then raise exception 'Invalid recovery code'; end if;
 select * into g from public.games where game_code=upper(trim(p_code));
 if not found then raise exception 'Invalid game'; end if;
 if exists(select 1 from public.game_memberships where game_id=g.id and user_id=v_user) then
  raise exception 'Already registered in this game';
 end if;
 select m.id into target_member from public.game_memberships m
 join public.game_recovery_tokens t on t.game_id=m.game_id and t.member_id=m.id
 where m.game_id=g.id and lower(m.codename)=lower(trim(p_codename))
 and t.token_hash=encode(public.digest(p_token,'sha256'),'hex') for update of m,t;
 if target_member is null then raise exception 'Invalid codename or recovery code'; end if;
 update public.game_memberships set user_id=v_user where game_id=g.id and id=target_member;
 delete from public.game_recovery_tokens where game_id=g.id and member_id=target_member;
 return true;
end $$;

revoke all on function public.game_issue_recovery(uuid,text),public.game_recover(text,text,text) from public,anon;
grant execute on function public.game_issue_recovery(uuid,text),public.game_recover(text,text,text) to authenticated;
