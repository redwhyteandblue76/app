'use strict';
const fs=require('fs');
const vm=require('vm');
const assert=require('assert/strict');
const path=require('path');
const root=path.resolve(__dirname,'../..');
const read=p=>fs.readFileSync(path.join(root,p),'utf8');
const pages=['assassins2.html','mafia2.html','host.html'];
const scripts=['12one-games/platform.js','12one-games/assassins.js','12one-games/mafia.js'];
function fail(msg){throw new Error(msg)}
for(const page of pages){
 const html=read(page);
 assert(!html.includes('script.google.com'),page+' must not call the original Google Apps Script');
 for(const x of html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)){
  new vm.Script(x[1],{filename:page});
 }
}
for(const file of scripts)new vm.Script(read(file),{filename:file});
const host=read('host.html');
const script=read('12one-games/platform.js');
const ids=new Set([...host.matchAll(/\bid="([^"]+)"/g)].map(x=>x[1]));
for(const m of script.matchAll(/(?:\$|show)\('([^']+)'/g)){
 assert(ids.has(m[1]),'Missing host element #'+m[1]);
}
assert(!/guestStart|joinForm|assassinsSignupFields/.test(script),'Obsolete player forms remain on host');
assert(host.includes('id="mafiaPanel"')&&host.includes('id="assassinsPanel"'),'Both host game dashboards required');
assert(!read('assassins2.html').includes('function renderAdmin('),'Assassins administration must remain on host');
assert(!read('mafia2.html').includes('function renderAdminLogin('),'Mafia administration must remain on host');
for(const [name,sqlName] of [
 ['assassins2.html','assassins_v2_public'],
 ['mafia2.html','mafia_public']
]){
 assert(read(name).includes(sqlName),name+' must read from isolated public RPC');
}
const sql=read('12one-games/sql/010_mafia_game.sql');
for(const fn of ['mafia_public','mafia_join','mafia_state','mafia_action','mafia_host','mafia_login','mafia_verify']){
 assert(sql.includes('function public.'+fn+'('),'Missing Mafia RPC: '+fn);
}
assert(!sql.includes('target_id=target_id'),'Ambiguous target reference may affect other votes');
assert(sql.includes('security definer set search_path=\'\''),'Restrict SQL SECURITY DEFINER search_path');

for(const name of ['011_settings_parity.sql','012_mafia_settings_parity.sql']){
 const source=read('12one-games/sql/'+name);
 assert(source.length>100,name+' must not be empty');
}
const assassinsPage=read('assassins2.html');
const mafiaPage=read('mafia2.html');
for(const [file,source] of [['assassins2.html',assassinsPage],['mafia2.html',mafiaPage]]){
 assert(!source.includes('game_recover')&&!source.includes('game_issue_recovery'),'Recovery references remain in '+file);
 assert(source.includes('game_player_sign_in'),'Missing cross-device PIN login: '+file);
 assert(source.includes('storageKey:'),'Game must isolate browser sessions: '+file);
}
assert(assassinsPage.includes('assassins_join_with_pin'),'Assassins signup must require a PIN');
assert(assassinsPage.includes('assassins_set_my_pin'),'Existing Assassins players need a PIN setup');
const pinSql=read('12one-games/sql/014_player_pin_login.sql');
for(const fn of ['assassins_join_with_pin','game_player_sign_in','assassins_set_my_pin']){
 assert(pinSql.includes('function public.'+fn+'('),'Missing PIN RPC '+fn);
}
assert(pinSql.includes('drop function if exists public.game_recover'),'Remove legacy recovery API');
assert(pinSql.includes('revoke execute on function public.assassins_join'),'Close direct PIN-less registration');
assert(read('12one-games/platform.js').includes('12one_host_auth'),'Host login must use independent browser session');
const assassinsSettings=['master_lock','game_status','signup_enabled','dashboard_enabled','eliminate_enabled','signup_off_message','dashboard_off_message','eliminate_off_message','master_lock_message','admin_password','last_updated','reset_password','hall_field_enabled','hall_options','phone_field_enabled','instructions_enabled','instruction_verification_enabled','instructions_text'];
const assConfig=read('12one-games/sql/011_settings_parity.sql');
for(const setting of assassinsSettings)assert(assConfig.includes(setting),'Missing Assassins host setting '+setting);
const mafiaSettings=['setupEnabled','dashboardEnabled','gameActive','mafiaCooldownHours','detectiveCooldownHours','citizenCooldownHours','citizenVotesRequired','voteExpirationMinutes','minActiveForGameEnd','allowMafiaInCitizenVotes','allowDetectiveInCitizenVotes','announcementMessage','hallOptions','mafiaInstructions','detectiveInstructions','citizenInstructions','hallFieldEnabled'];
const mafiaConfig=read('12one-games/sql/012_mafia_settings_parity.sql')+read('12one-games/sql/010_mafia_game.sql');
for(const setting of mafiaSettings)assert(mafiaConfig.includes(setting),'Missing Mafia host setting '+setting);

console.log('PASS: JS syntax, backend isolation, host elements, game routes and RPC coverage.');
