'use strict';
const db=window.supabase.createClient('https://dfsthxttqxbmafhykfqh.supabase.co','sb_publishable_OFz4bRAe0_9jgoGXp4xXIQ_Nr7STWWR',{auth:{storageKey:'12one_host_auth'}});
const $=id=>document.getElementById(id);
let currentUser=null,currentGame=null,selectedHostGame=null,allHostGames=[],showArchives=false,adminIsHost=false;
function msg(s){$('notice').textContent=s||''}
function fail(e){msg(e?.message||String(e))}
function busy(form,v){form.querySelectorAll('button').forEach(b=>b.disabled=v)}
async function task(form,fn){busy(form,true);msg('');try{await fn();await refresh()}catch(e){fail(e)}finally{busy(form,false)}}
function show(id,v){$(id).classList.toggle('hidden',!v)}
function node(tag,text){const n=document.createElement(tag);n.textContent=text;return n}
function linkFor(code,type){const page=type==='assassins'?'assassins2.html':type==='mafia'?'mafia2.html':'host.html';const u=new URL(page,location.href);u.searchParams.set('game',code);return u.href}
async function refresh(){
 const {data,error}=await db.auth.getSession();if(error)throw error;
 currentUser=data.session?.user||null;
 const guest=!!currentUser?.is_anonymous;
 show('auth',!currentUser);show('dashboard',!!currentUser&&!guest&&!selectedHostGame);show('guestPanel',guest);show('owner',false);
 $('identity').textContent=currentUser?(guest?'Guest session (this browser)':'Signed in as '+currentUser.email):'';
 if(!currentUser){selectedHostGame=null;show('lobby',false);show('assassinsPanel',false);show('mafiaPanel',false);applyHostView();return}
 const {data:games,error:ge}=await db.from('games').select('id,name,game_type,game_code,status,owner_user_id,archived_at').eq('owner_user_id',currentUser.id).order('created_at',{ascending:false});if(ge)throw ge;

 const {data:gameCounts}=await db.rpc('host_game_counts');
 const byId=new Map((gameCounts||[]).map(x=>[x.id,x]));
 allHostGames=games.map(g=>({...g,...(byId.get(g.id)||{})}));
 renderGameCards();

 if(!guest){
 const {data:profile}=await db.from('host_profiles').select('full_name').eq('user_id',currentUser.id).maybeSingle();
 if($('profileName')&&document.activeElement!==$('profileName'))$('profileName').value=profile?.full_name||currentUser.user_metadata?.full_name||'';
 const [credits,admin]=await Promise.all([db.from('game_credits').select('id').is('consumed_at',null),db.rpc('is_platform_admin')]);
 if(credits.error)throw credits.error;
 $('creditCount').textContent=String(credits.data.length);
 adminIsHost=!admin.error&&admin.data===true;
 show('owner',adminIsHost&&!selectedHostGame);
 if(!admin.error&&admin.data===true)renderAdminDirectory().catch(e=>msg(e.message));
 }
 if(currentGame)await loadLobby(currentGame);
 if(window.refreshAssassins)await window.refreshAssassins();
 if(window.refreshMafia)await window.refreshMafia();
 applyHostView();
 if(selectedHostGame)decorateGamePanel(selectedHostGame);
}
async function lookup(){
 const code=$('joinCode').value.trim().toUpperCase();
 const {data,error}=await db.rpc('lookup_joinable_game',{p_code:code});if(error)throw error;
 const g=data?.[0];if(!g)throw Error('No game found for that code.');
 const target=linkFor(code,g.game_type);
 $('foundGame').replaceChildren(node('span',g.game_name+' · '+g.game_type+' · '+g.game_status+' · '));
 const a=node('a','Open game');a.href=target;$('foundGame').append(a);
}
async function loadLobby(id){
 const {data,error}=await db.rpc('list_game_lobby',{p_game_id:id});if(error)throw error;
 currentGame=id;show('lobby',true);$('lobbyList').replaceChildren();
 $('lobbyList').append(node('p',data.length+' player(s) registered'));
 for(const p of data)$('lobbyList').append(node('div',p.real_name));
}


let activeHostTab='overview';
window.organizeHostGameView=function(type,area){
 if(!area)return;
 const children=[...area.children].filter(n=>!n.classList.contains('host-tabs')&&!n.classList.contains('host-tab'));
 if(!children.length)return;
 let nav=document.createElement('nav');nav.className='host-tabs';nav.setAttribute('aria-label','Game management sections');
 const groups={overview:document.createElement('div'),players:document.createElement('div'),settings:document.createElement('div'),activity:document.createElement('div')};
 for(const [key,node] of Object.entries(groups)){node.className='host-tab';node.dataset.tab=key}
 let current='overview';
 for(const child of children){
  const summary=child.tagName==='DETAILS'?child.querySelector('summary')?.textContent?.toLowerCase()||'':'';
  const heading=/^H[234]$/.test(child.tagName)?child.textContent?.toLowerCase()||'':'';
  if(summary.includes('player')||heading.includes('registered player'))current='players';
  else if(summary.includes('setting')||summary.includes('original assassins'))current='settings';
  else if(summary.includes('log')||summary.includes('elimination history')||heading.includes('elimination feed'))current='activity';
  else if(summary.includes('start game')||heading.includes('host management'))current='overview';
  if(child.tagName==='BUTTON'&&/^(Reset|Full wipe|Shuffle|Eliminate players|Refresh)/i.test(child.textContent||''))groups.overview.append(child);
  else groups[current].append(child);
 }
 const playerSearch=document.createElement('input');
 playerSearch.type='search';playerSearch.placeholder='Search player names, codenames, or halls';
 playerSearch.setAttribute('aria-label','Search players');playerSearch.style.margin='10px 0';
 playerSearch.oninput=()=>{
  const needle=playerSearch.value.trim().toLowerCase();
  for(const line of groups.players.querySelectorAll('.game'))line.hidden=!!needle&&!line.textContent.toLowerCase().includes(needle);
 };
 groups.players.prepend(playerSearch);
 for(const details of groups.players.querySelectorAll('details'))details.open=true;
 for(const details of groups.activity.querySelectorAll('details'))details.open=true;
 for(const d of groups.settings.querySelectorAll('details'))d.open=true;
 for(const [key,title] of [['overview','Game overview'],['players','Player management'],['settings','Game settings'],['activity','Game activity']]){
  const h=document.createElement('h3');h.textContent=title;groups[key].prepend(h);
 }
 const tabs=[['overview','Overview'],['players','Players'],['settings','Settings'],['activity','Activity']];
 for(const [id,label] of tabs){
  const btn=document.createElement('button');btn.type='button';btn.textContent=label;btn.className='secondary';
  btn.onclick=()=>{activeHostTab=id;window.organizeHostTabState(area)};
  btn.dataset.tab=id;nav.append(btn);
 }
 area.prepend(nav,...Object.values(groups));
 window.organizeHostTabState(area);
};
window.organizeHostTabState=function(area){
 for(const tab of area.querySelectorAll(':scope > .host-tab'))tab.hidden=tab.dataset.tab!==activeHostTab;
 for(const btn of area.querySelectorAll(':scope > .host-tabs > button'))btn.setAttribute('aria-selected',String(btn.dataset.tab===activeHostTab));
};

const makeButton=(label,fn,cls='secondary')=>{const b=node('button',label);b.className=cls;b.type='button';b.onclick=fn;return b};
const pageTitle=()=>document.querySelector('header h1');
function applyHostView(){
 const active=!!selectedHostGame;
 show('dashboard',!!currentUser&&!currentUser.is_anonymous&&!active);
 show('owner',!active&&adminIsHost&&!!currentUser&&!currentUser.is_anonymous);
 show('joinSection',!active&&!currentUser);
 show('hostWorkspace',active);show('hostHomeView',!active);
 document.body.dataset.view=active?'game':'home';
 if($('workspaceSubtitle'))$('workspaceSubtitle').textContent=active?selectedHostGame.game_type.toUpperCase()+' · '+selectedHostGame.game_code:'';
 show('assassinsPanel',active&&selectedHostGame.game_type==='assassins');
 show('mafiaPanel',active&&selectedHostGame.game_type==='mafia');
 if(pageTitle())pageTitle().textContent=active?selectedHostGame.name:'12one Games';
 const desc=document.querySelector('header+.muted');
 if(desc)desc.textContent=active?'Manage your game':'Your game hosting workspace';
}
function backToGames(){
 selectedHostGame=null;
 show('assassinsPanel',false);show('mafiaPanel',false);
 applyHostView();
 refresh().then(()=>{window.scrollTo({top:0,behavior:'smooth'})}).catch(fail);
}
async function manageGame(g){
 selectedHostGame=g;activeHostTab='overview';msg('');
 show('assassinsPanel',false);show('mafiaPanel',false);
 applyHostView();
 if(g.game_type==='assassins')await window.openAssassins(g.id);
 else await window.openMafia(g.id);
 decorateGamePanel(g);
 window.scrollTo({top:0,behavior:'smooth'});
}
function decorateGamePanel(g){
 const panel=$(g.game_type==='assassins'?'assassinsPanel':'mafiaPanel');
 let bar=panel.querySelector(':scope > .game-toolbar:not(.host-action-bar)');
 if(!bar){bar=node('div');bar.className='game-toolbar';panel.prepend(bar)}
 bar.replaceChildren();
 bar.append(makeButton('← All games',backToGames,'secondary'));
 const status=node('span',g.game_type+' · '+g.game_code+' · '+g.status);status.className='status-chip';bar.append(status);
 const share=makeButton('Copy join link',()=>{navigator.clipboard.writeText(linkFor(g.game_code,g.game_type)).then(()=>msg('Join link copied.')).catch(e=>fail(e))});bar.append(share);
 let actions=panel.querySelector(':scope > .host-action-bar');
 if(actions)actions.remove();
 actions=node('div');actions.className='game-toolbar host-action-bar';
 actions.append(makeButton('Export game records',()=>exportHostedGame(g)));
 actions.append(makeButton('Rename',()=>changeGameName(g)));
 if(g.status!=='finished')actions.append(makeButton('End game',()=>gameCommand(g,'end'),'danger'));
 if(g.status==='finished'){
  actions.append(makeButton(g.archived_at?'Restore from archive':'Archive game',()=>gameCommand(g,g.archived_at?'restore':'archive')));
  actions.append(makeButton('Permanently delete',()=>deleteHostedGame(g),'danger'));
 }
 panel.append(actions);
 const area=$(g.game_type==='assassins'?'assassinsContent':'mafiaContent');
 const overview=area?.querySelector(':scope > .host-tab[data-tab="overview"]');
 if(overview){
  overview.querySelector('.stats')?.remove();
  const stats=node('div');stats.className='stats';
  for(const [title,value] of [['Total players',g.total??'—'],['Active players',g.active??'—'],['Game status',g.status]]){
   const tile=node('div');tile.className='stat';tile.append(node('strong',String(value)),node('span',title));stats.append(tile);
  }
  overview.prepend(stats);
 }
 const targetActivity=panel.querySelector(':scope #'+(g.game_type==='assassins'?'assassinsContent':'mafiaContent')+' > .host-tab[data-tab="activity"]');
 if(targetActivity){
  let section=targetActivity.querySelector('.host-audit');
  if(section)section.remove();
  section=node('div');section.className='host-audit';section.append(node('h3','Host activity history'));
  targetActivity.prepend(section);
  db.rpc('host_recent_events',{p_game_id:g.id}).then(({data,error})=>{
   if(error){section.append(node('p','Activity history unavailable until migration 015 is installed.'));return}
   if(!data?.length)section.append(node('p','No host activity recorded yet.'));
   for(const event of data||[])section.append(node('p',new Date(event.time).toLocaleString()+' · '+event.details));
  }).catch(fail);
 }
}
function renderGameCards(){
 const target=$('gamesList');target.replaceChildren();
 const q=($('gameSearch')?.value||'').trim().toLowerCase(),filter=$('gameFilter')?.value||'all';
 const result=allHostGames.filter(g=>(!q||(g.name+' '+g.game_code+' '+g.game_type).toLowerCase().includes(q))&&
 (filter==='all'?!g.archived_at:filter==='archived'?!!g.archived_at:g.status===filter));
 if(!result.length)target.append(node('p','No matching games.'));
 for(const g of result){
  const card=node('article');card.className='game';
  const tag=node('small',g.game_type.toUpperCase()+' · '+g.status+(g.archived_at?' · archived':''));tag.className='muted';card.append(tag);
  card.append(node('h3',g.name),node('p','Game code: '+g.game_code));
  if(g.total!==undefined)card.append(node('p',g.total+' players · '+g.active+' active'));
  const buttons=node('div');buttons.className='game-toolbar';
  buttons.append(makeButton('Manage game',()=>manageGame(g).catch(fail)));
  buttons.append(makeButton('Copy join link',()=>navigator.clipboard.writeText(linkFor(g.game_code,g.game_type)).then(()=>msg('Join link copied.')).catch(fail)));
  card.append(buttons);target.append(card);
 }
}
async function gameCommand(g,action,value=''){
 if(['end','archive'].includes(action)&&!confirm(action==='end'?'End '+g.name+'? Gameplay will stop and results will remain available.':'Archive '+g.name+'?'))return;
 const {error}=await db.rpc('host_manage_game',{p_game_id:g.id,p_action:action,p_value:value});if(error)throw error;
 msg(action==='end'?'Game ended.':'Game updated.');
 selectedHostGame=null;await refresh();
}
async function changeGameName(g){
 const n=prompt('New game name:',g.name);if(n===null)return;
 if(n.trim().length<2)return msg('Enter at least two characters.');
 return gameCommand(g,'rename',n.trim()).catch(fail);
}
async function exportHostedGame(g){
 const {data,error}=await db.rpc('host_export_game',{p_game_id:g.id});if(error)return fail(error);
 const blob=new Blob([JSON.stringify(data,null,2)],{type:'application/json'});
 const url=URL.createObjectURL(blob),a=document.createElement('a');
 a.href=url;a.download='12one-'+g.game_code+'-game-log.json';a.click();
 setTimeout(()=>URL.revokeObjectURL(url),2000);msg('Game archive exported. Keep this file private: it contains player details.');
}
async function deleteHostedGame(g){
 if(!confirm('PERMANENT DELETION: Delete '+g.name+' and all its player records? This cannot be undone. Export your records first.'))return;
 if(!confirm('Final confirmation: permanently delete '+g.name+'?'))return;
 const typed=prompt('Type the game name exactly to delete it:');
 if(typed!==g.name)return msg('Deletion cancelled: name did not match.');
 await gameCommand(g,'delete').catch(fail);
}
async function renderAdminDirectory(){
 const hosts=$('adminHosts'),games=$('adminGames');if(!hosts||!games)return;
 const {data,error}=await db.rpc('host_admin_directory');
 if(error){hosts.textContent='Administrator directory needs database migration 015.';return}
 hosts.replaceChildren();games.replaceChildren();
 for(const h of data.hosts||[]){
  const line=node('div');line.className='game';line.append(node('strong',h.name||'Name not provided'),node('p',h.email+' · '+h.game_count+' games'));
  hosts.append(line);
 }
 for(const g of data.games||[]){
  const line=node('div');line.className='game';
  line.append(node('strong',g.name),node('p',(g.host||g.host_email)+' · '+g.type+' · '+g.status+' · '+g.players+' players'));
  line.append(makeButton('Export records',()=>exportHostedGame(g)));
  if(g.status!=='finished')line.append(makeButton('End game',()=>gameCommand(g,'end').catch(fail),'danger'));
  else line.append(makeButton('Delete game',()=>deleteHostedGame(g),'danger'));
  games.append(line);
 }
}
$('saveProfile')?.addEventListener('click',async()=>{
 if(!currentUser||currentUser.is_anonymous)return msg('Sign in as a host first.');
 const name=$('profileName').value.trim();
 if(name.length<2||name.length>120)return msg('Enter a full name between 2 and 120 characters.');
 const {error}=await db.from('host_profiles').upsert({user_id:currentUser.id,full_name:name});
 if(error)return fail(error);
 msg('Profile name saved.');await refresh();
});
$('backToDashboard')?.addEventListener('click',backToGames);
$('gameSearch')?.addEventListener('input',renderGameCards);
$('gameFilter')?.addEventListener('change',renderGameCards);

$('authForm').onsubmit=e=>{e.preventDefault();task(e.currentTarget,async()=>{const {error}=await db.auth.signInWithPassword({email:$('email').value.trim(),password:$('password').value});if(error)throw error;msg('Signed in.')})};
$('signup').onclick=()=>task($('authForm'),async()=>{if(($('fullName')?.value.trim()||'').length<2)throw Error('Please enter your full name when creating a host account.');const {data,error}=await db.auth.signUp({email:$('email').value.trim(),password:$('password').value,options:{data:{full_name:$('fullName')?.value.trim()||''}}});if(error)throw error;msg(data.session?'Account created.':'Check your email to confirm your account.')});
$('signout').onclick=$('guestSignout').onclick=async()=>{const {error}=await db.auth.signOut();if(error)fail(error);else{currentGame=null;msg('Signed out.');await refresh()}};
$('redeemForm').onsubmit=e=>{e.preventDefault();task(e.currentTarget,async()=>{const {error}=await db.rpc('redeem_game_invite',{p_code:$('invite').value.trim()});if(error)throw error;$('invite').value='';msg('Game credit added.')})};
$('createForm').onsubmit=e=>{e.preventDefault();task(e.currentTarget,async()=>{const {data,error}=await db.rpc('create_hosted_game',{p_game_type:$('gameType').value,p_name:$('gameName').value.trim()});if(error)throw error;$('gameName').value='';msg('Game created: '+data[0].join_code+'. Open registration to accept players.')})};
$('issueForm').onsubmit=e=>{e.preventDefault();task(e.currentTarget,async()=>{const date=$('expiry').value;const {data,error}=await db.rpc('admin_issue_game_invite',{p_expires_at:date?new Date(date+'T23:59:59').toISOString():null});if(error)throw error;$('issuedCode').textContent='Copy this invitation code now: '+data;msg('Invitation generated.')})};
$('lookupForm').onsubmit=e=>{e.preventDefault();task(e.currentTarget,lookup)};
const queryCode=new URL(location.href).searchParams.get('join');if(queryCode)$('joinCode').value=queryCode;
db.auth.onAuthStateChange(()=>setTimeout(()=>refresh().catch(fail),0));
refresh().then(()=>{if(queryCode)return lookup().catch(fail)}).catch(fail);
