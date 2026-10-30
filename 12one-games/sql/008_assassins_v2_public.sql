-- Migration 008: safe public Assassins v2 bootstrap and spectator feed.
-- Apply after 007. This exposes no codenames, phone numbers, or player identities beyond public names/feed.
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
 'dashboard_enabled',coalesce(c.dashboard_enabled,true),'eliminate_enabled',coalesce(c.eliminate_enabled,true),
 'phone_enabled',coalesce(c.phone_enabled,false),'hall_enabled',coalesce(c.hall_enabled,false),
 'hall_options',coalesce(c.hall_options,''),'instructions_enabled',coalesce(c.instructions_enabled,false),
 'instruction_verification_enabled',coalesce(c.instruction_verification_enabled,false),
 'instructions_text',coalesce(c.instructions_text,''),'feed',v_feed);
end $$;
revoke all on function public.assassins_v2_public(text) from public;
grant execute on function public.assassins_v2_public(text) to anon,authenticated;
