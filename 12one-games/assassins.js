'use strict';
(function(){
const root=document.getElementById('assassinsPanel');
const area=document.getElementById('assassinsContent');
const el=(tag,text)=>{const n=document.createElement(tag);n.textContent=text??'';return n};
const rpc=async(name,args)=>{const {data,error}=await db.rpc(name,args);if(error)throw error;return data};
let selected=null;
const button=(label,fn)=>{const b=el('button',label);b.className='secondary';b.onclick=async()=>{b.disabled=true;try{await fn()}catch(e){fail(e)}finally{b.disabled=false}};return b};
const field=(label,type='text',value='')=>{const wrap=el('label',label);const inp=el('input');inp.type=type;inp.value=value;wrap.append(inp);return [wrap,inp]};
const heading=t=>area.append(el('h3',t));
async function render(){
 if(!selected)return;
 const s=await rpc('assassins_state',{p_game_id:selected});
 const hostSettings=await rpc('assassins_host_settings',{p_game_id:selected});
 root.classList.remove('hidden');area.replaceChildren();
 document.getElementById('assassinsTitle').textContent='ASSASSINS HOST DASHBOARD · '+s.status.toUpperCase();
 if(!s.host){area.append(el('p','Only the game host can manage this game.'));return;}
 if(s.paused)area.append(el('p','Game paused by host.'));
 if(s.instructions_enabled){heading('INSTRUCTIONS');area.append(el('p',s.instructions_text||'No instructions posted.'))}
 area.append(el('p',s.players.length+' registered player(s)'));
 if(s.host){heading('HOST MANAGEMENT');
  if(s.status==='registration')area.append(button('Start game',async()=>{if(!confirm('Start the game?'))return;await rpc('assassins_start',{p_game_id:selected});await refresh();await render()}));
  const hostPlayers=await rpc('assassins_host_players',{p_game_id:selected});
  area.append(el('p','Host controls are private to this page. Player gameplay takes place on assassins2.html.'));
  const details=el('details');const summary=el('summary','Private host player list (includes codenames)');details.append(summary);
  for(const p of hostPlayers){
   const line=el('div',p.name+' · '+p.codename+' · '+(p.alive?'Active':'Eliminated')+' · '+p.kills+' eliminations'+(p.hall?' · '+p.hall:''));
   line.className='game';
   if(['draft','registration'].includes(s.status))line.append(button('Remove',async()=>{if(!confirm('Remove '+p.name+'?'))return;await rpc('assassins_remove_player',{p_game_id:selected,p_codename:p.codename});await render()}));
   if(['active','finished'].includes(s.status))line.append(button(p.alive?'Mark eliminated':'Reactivate',async()=>{if(!confirm('Change status for '+p.name+'?'))return;await rpc('assassins_host_status',{p_game_id:selected,p_member_id:p.id,p_alive:!p.alive});await render()}));
   details.append(line);
  }
  area.append(details);
  const settings=el('details');settings.append(el('summary','All original Assassins settings'));
  const settingsBool=[
   ['master_lock','Master lock'],['signup_enabled','Sign-ups enabled'],
   ['dashboard_enabled','Player dashboard'],['eliminate_enabled','Eliminations enabled'],
   ['hall_field_enabled','Hall field enabled'],['phone_field_enabled','Phone field enabled'],
   ['instructions_enabled','Show instructions'],['instruction_verification_enabled','Require instructions acknowledgment'],
   ['paused','Pause eliminations']
  ];
  for(const [key,label] of settingsBool){
   const wrap=el('label',label+' ('+key+') ');const inp=el('input');inp.type='checkbox';inp.style.width='auto';
   inp.checked=!!hostSettings[key];
   inp.onchange=async()=>{
    const old= !inp.checked;inp.disabled=true;
    try{
     const mapped=key==='hall_field_enabled'?'hall_enabled':key==='phone_field_enabled'?'phone_enabled':key;
     await rpc('assassins_host_setting',{p_game_id:selected,p_key:mapped,p_value:String(inp.checked)});
     await render();
    }catch(e){inp.checked=old;fail(e)}finally{inp.disabled=false}
   };
   wrap.append(inp);settings.append(wrap);
  }
  for(const [key,label] of [
   ['hall_options','Hall options'],['instructions_text','Registration instructions'],
   ['signup_off_message','Registration closed message'],
   ['dashboard_off_message','Dashboard disabled message'],
   ['eliminate_off_message','Eliminations disabled message'],
   ['master_lock_message','Master lock message']
  ]){
   const wrap=el('label',label+' ('+key+')');const inp=el(key.includes('message')||key==='instructions_text'?'textarea':'input');
   inp.value=hostSettings[key]??'';inp.style.width='100%';wrap.append(inp);settings.append(wrap);
   settings.append(button('Save '+label,async()=>{await rpc('assassins_host_setting',{p_game_id:selected,p_key:key,p_value:inp.value});await render()}));
  }
  settings.append(el('p','game_status: '+hostSettings.game_status+' — controlled through Open Registration, Start Game and Reset.'));
  settings.append(el('p','last_updated: '+(hostSettings.last_updated?new Date(hostSettings.last_updated).toLocaleString():'Not yet updated')));
  settings.append(el('p','admin_password / reset_password: replaced by your secure host account; these are not stored as plaintext game settings.'));
  area.append(settings);
  const feedDetails=el('details');feedDetails.append(el('summary','Elimination history / game log'));
  if(!(s.feed||[]).length)feedDetails.append(el('p','No confirmed eliminations yet.'));
  for(const event of s.feed||[]){
   const stamp=event.time?new Date(event.time).toLocaleString():'';
   feedDetails.append(el('div',event.details+(stamp?' · '+stamp:'')));
  }
  area.append(feedDetails);
  if(['active','finished'].includes(s.status)){
   area.append(button('Shuffle target order (before first elimination)',async()=>{if(!confirm('Reassign target order?'))return;await rpc('assassins_host_shuffle',{p_game_id:selected});await render()}));
   area.append(button('Eliminate players without a first elimination',async()=>{if(!confirm('Eliminate all active players with zero confirmed eliminations?'))return;const n=await rpc('assassins_host_no_first_elimination',{p_game_id:selected});msg(n+' players eliminated.');await render()}));
  }
  area.append(button('Reset game (keep registrations)',async()=>{if(!confirm('Reset this game and erase elimination history?'))return;await rpc('assassins_host_reset',{p_game_id:selected,p_wipe:false});await refresh();await render()}));
  area.append(button('Full wipe (delete all registrations)',async()=>{if(!confirm('Permanently remove all players and elimination history?'))return;await rpc('assassins_host_reset',{p_game_id:selected,p_wipe:true});await refresh();await render()}));
 }
 heading('REGISTERED PLAYERS');
 for(const p of s.players)area.append(el('div',p.name+(s.status==='active'||s.status==='finished'?(p.alive?' · Active':' · Eliminated'):'')));
 heading('ELIMINATION FEED');
 if(!s.feed.length)area.append(el('p','No eliminations yet.'));
 for(const item of s.feed)area.append(el('div',item.details+' · '+new Date(item.time).toLocaleString()));
 area.append(button('Refresh',render));
}
window.openAssassins=async id=>{selected=id;await render();root.scrollIntoView({behavior:'smooth',block:'start'})};
window.refreshAssassins=async()=>{if(selected)await render()};
})();
