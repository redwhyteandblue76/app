'use strict';
(function(){
const $=id=>document.getElementById(id);
const root=$('assassinsPanel');
let selected=null, owner=false, currentStatus='';
const el=(tag,text)=>{const x=document.createElement(tag);x.textContent=text;return x};
const call=async(name,args)=>{const {data,error}=await db.rpc(name,args);if(error)throw error;return data};
function action(text,fn){const b=el('button',text);b.className='secondary';b.onclick=async()=>{b.disabled=true;try{await fn();await render()}catch(e){fail(e)}finally{b.disabled=false}};return b}
async function render(){
 if(!selected)return;
 const state=await call('assassins_state',{p_game_id:selected});
 owner=state.host;currentStatus=state.status;
 root.classList.remove('hidden');
 $('assassinsTitle').textContent='ASSASSINS 2.0 · '+state.status.toUpperCase();
 const area=$('assassinsContent');area.replaceChildren();
 area.append(el('p',state.players.length+' registered player(s)'));
 for(const p of state.players){
  const line=el('div',p.codename+(state.status==='active'||state.status==='finished'?(p.alive?' · Active':' · Eliminated'):''));
  line.className='game';
  if(owner&&['draft','registration'].includes(state.status)){
   line.append(action('Remove player',async()=>{if(!confirm('Remove '+p.codename+' from this game?'))return;await call('assassins_remove_player',{p_game_id:selected,p_codename:p.codename});await refresh()}));
  }
  area.append(line);
 }
 if(owner&&state.status==='registration')area.append(action('Start Assassins game',async()=>{if(!confirm('Start game and assign targets? Registration will close.'))return;await call('assassins_start',{p_game_id:selected});await refresh()}));
 if(state.status==='active'){
  if(state.my_alive){
   area.append(el('h3','YOUR TARGET'),el('p',state.my_target||'No target assigned'));
   if(!state.my_pending)area.append(action('Report target eliminated',async()=>{if(!confirm('Submit an elimination report for host review?'))return;await call('assassins_report',{p_game_id:selected});msg('Report submitted. Waiting for host approval.')}));
   else area.append(el('p','Your elimination report is pending host review.'));
  } else if(!owner)area.append(el('p','You are not an active player.'));
  if(owner){
   area.append(el('h3','PENDING REPORTS'));
   if(!state.pending_reports.length)area.append(el('p','No pending reports.'));
   for(const r of state.pending_reports){
    const line=el('div',r.reporter+' reports '+r.target);line.className='game';
    line.append(action('Approve',async()=>{await call('assassins_resolve',{p_report_id:r.id,p_approve:true});await refresh()}));
    line.append(action('Reject',async()=>{await call('assassins_resolve',{p_report_id:r.id,p_approve:false});await refresh()}));
    area.append(line);
   }
  }
 }
 if(state.status==='finished')area.append(el('p','Game finished. Final active player is the winner.'));
 area.append(action('Refresh game',async()=>{}));
}
window.openAssassins=async(id)=>{selected=id;await render();root.scrollIntoView({behavior:'smooth',block:'start'})};
window.refreshAssassins=async()=>{if(selected)await render()};
})();
