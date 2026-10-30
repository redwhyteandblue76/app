-- Migration 014: per-game player PIN authentication.
-- Run after 013. All player sign-in requests are server validated.
create table if not exists public.player_pin_credentials (
 game_id uuid not null references public.games(id) on delete cascade,
 member_id uuid not null references public.game_memberships(id) on delete cascade,
 pin_hash text not null,
 failed_attempts integer not null default 0,
 locked_until timestamptz,
 primary key(game_id,member_id)
);
alter table public.player_pin_credentials enable row level security;
revoke all on public.player_pin_credentials from public, anon, authenticated;

create or replace function public.assassins_join_with_pin(
 p_code text,p_codename text,p_real_name text,p_pin text,
 p_phone text default '',p_hall text default '',p_accepted boolean default false
) returns uuid language plpgsql security definer set search_path='' as $$
declare v_game uuid; v_member uuid;
begin
 if p_pin !~ '^[0-9]{4}$' then raise exception 'Choose a four-digit PIN'; end if;
 v_game:=public.assassins_join(p_code,p_codename,p_real_name,p_phone,p_hall,p_accepted);
 select id into v_member from public.game_memberships
 where game_id=v_game and user_id=(select auth.uid());
 if v_member is null then raise exception 'Registration failed'; end if;
 insert into public.player_pin_credentials(game_id,member_id,pin_hash)
 values(v_game,v_member,extensions.crypt(p_pin,extensions.gen_salt('bf')));
 return v_game;
end $$;

create or replace function public.game_player_sign_in(p_code text,p_codename text,p_pin text)
returns boolean language plpgsql security definer set search_path='' as $$
declare v_game public.games%rowtype; v_member uuid; v_hash text;
 v_fail integer; v_locked timestamptz; v_user uuid := (select auth.uid());
begin
 if v_user is null then raise exception 'Player session required'; end if;
 if p_pin !~ '^[0-9]{4}$' then return false; end if;
 select * into v_game from public.games where game_code=upper(trim(p_code));
 if not found then return false; end if;
 if exists(select 1 from public.game_memberships
   where game_id=v_game.id and user_id=v_user and lower(codename)<>lower(trim(p_codename)))
 then raise exception 'This session already belongs to a different player'; end if;
 select m.id,
   case when v_game.game_type='mafia' then mp.pin_hash else ap.pin_hash end,
   coalesce(ap.failed_attempts,0),ap.locked_until
 into v_member,v_hash,v_fail,v_locked
 from public.game_memberships m
 left join public.mafia_players mp on mp.game_id=m.game_id and mp.member_id=m.id
 left join public.player_pin_credentials ap on ap.game_id=m.game_id and ap.member_id=m.id
 where m.game_id=v_game.id and lower(m.codename)=lower(trim(p_codename))
 for update of m;
 if v_member is null or v_hash is null then return false; end if;
 if v_locked>now() then raise exception 'Too many login attempts; try again later'; end if;
 if v_hash<>extensions.crypt(p_pin,v_hash) then
   insert into public.player_pin_credentials(game_id,member_id,pin_hash,failed_attempts,locked_until)
   values(v_game.id,v_member,v_hash,1,null)
   on conflict(game_id,member_id) do update
     set failed_attempts=case when public.player_pin_credentials.locked_until<=now()
                               then 1 else public.player_pin_credentials.failed_attempts+1 end,
         locked_until=case when public.player_pin_credentials.failed_attempts>=4
                              then now()+interval '15 minutes'
                              else null end;
   return false;
 end if;
 insert into public.player_pin_credentials(game_id,member_id,pin_hash,failed_attempts,locked_until)
 values(v_game.id,v_member,v_hash,0,null)
 on conflict(game_id,member_id) do update set failed_attempts=0,locked_until=null;
 update public.game_memberships set user_id=v_user where game_id=v_game.id and id=v_member;
 return true;
end $$;

revoke all on function public.assassins_join_with_pin(text,text,text,text,text,text,boolean),
 public.game_player_sign_in(text,text,text) from public,anon;
grant execute on function public.assassins_join_with_pin(text,text,text,text,text,text,boolean),
 public.game_player_sign_in(text,text,text) to authenticated;
