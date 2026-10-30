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
 root.classList.remove('hidden');area.replaceChildren();
 document.getElementById('assassinsTitle').textContent='ASSASSINS · '+s.status.toUpperCase();
 if(s.paused)area.append(el('p','Game paused by host.'));
 if(s.instructions_enabled){heading('INSTRUCTIONS');area.append(el('p',s.instructions_text||'No instructions posted.'))}
 area.append(el('p',s.players.length+' registered player(s)'));
 if(s.host){heading('HOST MANAGEMENT');
  if(s.status==='registration')area.append(button('Start game',async()=>{if(!confirm('Start the game?'))return;await rpc('assassins_start',{p_game_id:selected});await refresh();await render()}));
  const hostPlayers=await rpc('assassins_host_players',{p_game_id:selected});
  const details=el('details');const summary=el('summary','Private host player list (includes codenames)');details.append(summary);
  for(const p of hostPlayers){
   const line=el('div',p.name+' · '+p.codename+' · '+(p.alive?'Active':'Eliminated')+' · '+p.kills+' eliminations'+(p.hall?' · '+p.hall:''));
   line.className='game';
   if(['draft','registration'].includes(s.status))line.append(button('Remove',async()=>{if(!confirm('Remove '+p.name+'?'))return;await rpc('assassins_remove_player',{p_game_id:selected,p_codename:p.codename});await render()}));
   if(['active','finished'].includes(s.status))line.append(button(p.alive?'Mark eliminated':'Reactivate',async()=>{if(!confirm('Change status for '+p.name+'?'))return;await rpc('assassins_host_status',{p_game_id:selected,p_member_id:p.id,p_alive:!p.alive});await render()}));
   details.append(line);
  }
  area.append(details);
  const settings=el('details');settings.append(el('summary','Game settings'));
  for(const [key,label] of [['dashboard_enabled','Player dashboard'],['eliminate_enabled','Eliminations enabled'],['paused','Pause game'],['phone_enabled','Require phone at registration'],['hall_enabled','Require hall at registration'],['instructions_enabled','Show instructions'],['instruction_verification_enabled','Require instructions acknowledgement']]){
   const wrap=el('label',label+' ');const inp=el('input');inp.type='checkbox';inp.checked=!!s[key];inp.onchange=async()=>{try{await rpc('assassins_host_setting',{p_game_id:selected,p_key:key,p_value:String(inp.checked)});await render()}catch(e){fail(e)}};wrap.append(inp);settings.append(wrap);
  }
  for(const [key,label] of [['hall_options','Hall options (comma separated)'],['instructions_text','Instructions']]){
   const [wrap,inp]=field(label,'text',s[key]||'');settings.append(wrap,button('Save '+label,async()=>{await rpc('assassins_host_setting',{p_game_id:selected,p_key:key,p_value:inp.value});await render()}));
  }
  area.append(settings);
  if(['active','finished'].includes(s.status)){
   area.append(button('Shuffle target order (before first elimination)',async()=>{if(!confirm('Reassign target order?'))return;await rpc('assassins_host_shuffle',{p_game_id:selected});await render()}));
   area.append(button('Eliminate players without a first elimination',async()=>{if(!confirm('Eliminate all active players with zero confirmed eliminations?'))return;const n=await rpc('assassins_host_no_first_elimination',{p_game_id:selected});msg(n+' players eliminated.');await render()}));
  }
  area.append(button('Reset game (keep registrations)',async()=>{if(!confirm('Reset this game and erase elimination history?'))return;await rpc('assassins_host_reset',{p_game_id:selected,p_wipe:false});await refresh();await render()}));
  area.append(button('Full wipe (delete all registrations)',async()=>{if(!confirm('Permanently remove all players and elimination history?'))return;await rpc('assassins_host_reset',{p_game_id:selected,p_wipe:true});await refresh();await render()}));
 }
 heading('PLAYER DASHBOARD');
 if(s.my_codename){
  area.append(el('p','Signed in as '+s.my_codename+'.'));
  if(s.status==='active'&&s.my_alive&&s.dashboard_enabled&&!s.paused){
   area.append(button('Find My Target',async()=>{msg(s.my_target?'Your current target is '+s.my_target+'.':'No active targets remaining.');}));
   if(s.eliminate_enabled){
    const [wrap,inp]=field('Enter your target\'s secret codename');area.append(wrap);
    area.append(button('Eliminate a Player',async()=>{
     if(!inp.value.trim())throw Error('Enter the target codename');
     if(!confirm('Confirm elimination? This cannot be undone.'))return;
     const result=await rpc('assassins_confirm',{p_game_id:selected,p_target_codename:inp.value.trim()});
     msg('Confirmed: '+result.eliminated+'. '+(result.winner?'You are the last active player!':('Next target: '+result.next_target)));
     await refresh();await render();
    }));
   }
  }else if(!s.my_alive&&['active','finished'].includes(s.status))area.append(el('p','You have been eliminated.'));
 }else area.append(el('p','You are the host. Player dashboards are accessible to registered participants.'));
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
