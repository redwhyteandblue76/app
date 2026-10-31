'use strict';
(function(){
 const root=document.getElementById('mafiaPanel'),area=document.getElementById('mafiaContent');
 if(!root||!area)return;
 let gameId=null;
 const el=(tag,txt)=>{const n=document.createElement(tag);if(txt!==undefined)n.textContent=String(txt);return n};
 const rpc=async(action,payload={})=>{const {data,error}=await db.rpc('mafia_host',{p_game_id:gameId,p_action:action,p_payload:payload});if(error)throw error;return data};
 const notice=message=>{const n=document.getElementById('notice');n.textContent=message};
 const button=(label,cb,danger=false)=>{const b=el('button',label);b.className=danger?'secondary':'';b.onclick=async()=>{b.disabled=true;try{await cb()}catch(e){notice(e.message||String(e))}finally{b.disabled=false}};return b};
 const label=(title,field)=>{const w=el('label',title);w.append(field);return w};
 const input=(type='text',value='')=>{const n=el('input');n.type=type;n.value=String(value??'');return n};
 const section=title=>{const details=el('details');details.append(el('summary',title));details.style.margin='16px 0';return details};
 const boolSettings=[['setupEnabled','Registration enabled'],['dashboardEnabled','Player dashboards'],['gameActive','Game actions enabled'],['allowMafiaInCitizenVotes','Mafia members can cast citizen votes'],['allowDetectiveInCitizenVotes','Detectives can cast citizen votes'],['hallFieldEnabled','Require hall at registration']];
 const textSettings=[['hallOptions','Hall options (comma-separated)'],['announcementMessage','Announcement'],['gameInstructions','Game instructions'],['mafiaInstructions','Mafia instructions'],['detectiveInstructions','Detective instructions'],['citizenInstructions','Citizen instructions']];
 const numericSettings=[['mafiaCooldownHours','Mafia cooldown (hours)'],['detectiveCooldownHours','Detective cooldown (hours)'],['citizenCooldownHours','Citizen cooldown (hours)'],['citizenVotesRequired','Citizen votes required'],['voteExpirationMinutes','Vote expiration (minutes)'],['minActiveForGameEnd','Minimum active players before game ends']];
 async function render(){
  if(!gameId)return;
  const s=await rpc('read');
  root.classList.remove('hidden');area.replaceChildren();
  document.getElementById('mafiaTitle').textContent='MAFIA HOST DASHBOARD · '+s.status.toUpperCase();
  area.append(el('p',s.players.length+' registered player(s)'));
  const setup=section('Start game / Randomize roles');
  const mafia=input('number','1');mafia.min=1;const detectives=input('number','1');detectives.min=0;
  setup.append(label('Number of Mafia players',mafia),label('Number of detectives',detectives));
  setup.append(button('Randomize roles and start',async()=>{
   if(!confirm('Reset every player to active, clear cooldowns and votes, and reassign roles?'))return;
   const d=await rpc('randomize',{mafia:Number(mafia.value),detectives:Number(detectives.value)});
   notice('Roles assigned: '+d.mafia+' Mafia, '+d.detectives+' detectives, '+d.citizens+' citizens.');
   await render();await refresh();
  }));area.append(setup);
  const settings=section('Game settings');
  for(const [key,title] of boolSettings){
   const check=input('checkbox');check.checked=!!s.settings[key];check.style.width='auto';
   check.onchange=async()=>{check.disabled=true;try{await rpc('setting',{key,value:String(check.checked)});notice(title+' updated.');await render()}catch(e){notice(e.message||String(e));check.checked=!check.checked}finally{check.disabled=false}};
   settings.append(label(title+' ',check));
  }
  for(const [key,title] of textSettings){
   const field=key==='gameInstructions'||key.endsWith('Instructions')||key==='announcementMessage'?el('textarea'):input();
   field.value=s.settings[key]??'';field.style.width='100%';
   settings.append(label(title,field),button('Save '+title,async()=>{await rpc('setting',{key,value:field.value});notice(title+' saved.');await render()}));
  }
  for(const [key,title] of numericSettings){
   const field=input('number',s.settings[key]);field.min=key==='voteExpiryHours'||key==='votesRequired'?1:0;
   settings.append(label(title,field),button('Save '+title,async()=>{await rpc('setting',{key,value:field.value});notice(title+' saved.');await render()}));
  }
  settings.append(el('p','adminPassword: replaced with host-account authentication. No shared game password is stored.'));
  settings.append(el('p','Original Mafia settings not listed here are supported above. Player signup also requires real names and game-specific PINs.'));
  area.append(settings);
  const players=section('Private player management — real names, codenames, roles');
  const {data:contacts}=await db.rpc('host_player_contacts',{p_game_id:gameId});
  const phoneByCode=new Map((contacts||[]).map(p=>[p.codename?.toLowerCase(),p]));
  for(const pl of s.players){
   const line=el('div');line.className='game';
   line.append(el('strong',pl.official_name+' · '+pl.codename));
   const info=phoneByCode.get(pl.codename?.toLowerCase());
   if(info?.phone)line.append(el('p','Phone: '+info.phone));
   if(info?.hall)line.append(el('p','Hall: '+info.hall));
   const role=el('select');
   for(const [v,n] of [['','Unassigned'],['citizen','Citizen'],['mafia','Mafia'],['detective','Detective']]){const o=el('option',n);o.value=v;role.append(o)}
   role.value=pl.role||'';
   const status=el('select');
   for(const v of ['active','eliminated']){const o=el('option',v);o.value=v;status.append(o)}
   status.value=pl.status;
   line.append(label('Role',role),label('Status',status));
   line.append(button('Save player',async()=>{await rpc('player',{codename:pl.codename,role:role.value,status:status.value});await render()}));
   if(['draft','registration'].includes(s.status))line.append(button('Remove',async()=>{
    if(!confirm('Permanently remove '+pl.official_name+'?'))return;
    await rpc('remove',{codename:pl.codename});await render();
   },true));
   players.append(line);
  }
  area.append(players);
  const logs=section('Game event log (latest 200)');
  for(const row of s.log)logs.append(el('div',new Date(row.time).toLocaleString()+' · '+row.message));
  area.append(logs);
  area.append(button('Reset roles and game (keep players)',async()=>{
   if(!confirm('Reset the game, clear votes, roles and cooldowns while keeping player registrations?'))return;
   await rpc('reset');await render();await refresh();
  },true));
  area.append(button('Refresh Mafia dashboard',render));
  window.organizeHostGameView?.('mafia',area);
 }
 window.openMafia=async id=>{gameId=id;document.getElementById('assassinsPanel')?.classList.add('hidden');await render();root.scrollIntoView({behavior:'smooth',block:'start'})};
 window.refreshMafia=async()=>{if(gameId)await render()};
})();
