'use strict';
const db=window.supabase.createClient('https://kzhrcwptyyyqodqlwngg.supabase.co','sb_publishable_37UbHH_v8-RyRFsEwril4A_oaEjDecl');
const $=id=>document.getElementById(id);
let currentUser=null,currentGame=null;
function msg(s){$('notice').textContent=s||''}
function fail(e){msg(e?.message||String(e))}
function busy(form,v){form.querySelectorAll('button').forEach(b=>b.disabled=v)}
async function task(form,fn){busy(form,true);msg('');try{await fn();await refresh()}catch(e){fail(e)}finally{busy(form,false)}}
function show(id,v){$(id).classList.toggle('hidden',!v)}
function node(tag,text){const n=document.createElement(tag);n.textContent=text;return n}
function linkFor(code){const u=new URL(location.href);u.searchParams.set('join',code);return u.href}
async function refresh(){
 const {data,error}=await db.auth.getSession();if(error)throw error;
 currentUser=data.session?.user||null;
 const guest=!!currentUser?.is_anonymous;
 show('auth',!currentUser);show('dashboard',!!currentUser&&!guest);show('guestPanel',guest);show('owner',false);
 $('identity').textContent=currentUser?(guest?'Guest session (this browser)':'Signed in as '+currentUser.email):'';
 if(!currentUser){show('lobby',false);show('assassinsPanel',false);return}
 const {data:games,error:ge}=await db.from('games').select('id,name,game_type,game_code,status,owner_user_id').order('created_at',{ascending:false});if(ge)throw ge;
 $('gamesList').replaceChildren();
 if(!games.length)$('gamesList').append(node('p','No games yet.'));
 for(const g of games){
 const el=node('div','');el.className='game';el.append(node('strong',g.name),node('p',g.game_type.toUpperCase()+' · '+g.status+' · '+g.game_code));
 const a=node('a','Share join link');a.href=linkFor(g.game_code);el.append(a);
 const open=node('button','View lobby');open.className='secondary';open.onclick=()=>loadLobby(g.id).catch(fail);el.append(open);
 if(g.game_type==='assassins'){const play=node('button','Assassins game');play.onclick=()=>window.openAssassins(g.id).catch(fail);el.append(play)}
 if(g.owner_user_id===currentUser.id&&['draft','registration'].includes(g.status)){
 const b=node('button',g.status==='registration'?'Close registration':'Open registration');
 b.onclick=async()=>{try{const {error}=await db.rpc('set_game_registration',{p_game_id:g.id,p_open:g.status==='draft'});if(error)throw error;await refresh()}catch(e){fail(e)}};el.append(b);
 }
 $('gamesList').append(el);
 }
 if(guest){show('guestGames',true);$('guestGames').replaceChildren();for(const g of games){if(g.game_type==='assassins'){const b=node('button','Open '+g.name);b.onclick=()=>window.openAssassins(g.id).catch(fail);$('guestGames').append(b)}}}else show('guestGames',false);
 if(!guest){
 const [credits,admin]=await Promise.all([db.from('game_credits').select('id').is('consumed_at',null),db.rpc('is_platform_admin')]);
 if(credits.error)throw credits.error;
 $('creditCount').textContent=String(credits.data.length);
 show('owner',!admin.error&&admin.data===true);
 }
 if(currentGame)await loadLobby(currentGame);
 if(window.refreshAssassins)await window.refreshAssassins();
}
async function lookup(){
 const code=$('joinCode').value.trim().toUpperCase();
 const {data,error}=await db.rpc('lookup_joinable_game',{p_code:code});if(error)throw error;
 const g=data?.[0];if(!g)throw Error('No game found for that code.');
 $('foundGame').textContent=g.game_name+' · '+g.game_type+' · '+g.game_status;
 $('joinForm').classList.toggle('hidden',g.game_status!=='registration');
 $('joinForm').dataset.code=code;
 $('joinForm').dataset.gameType=g.game_type;
 show('assassinsSignupFields',g.game_type==='assassins');
 if(g.game_type==='assassins'){
 const {data:config,error:ce}=await db.rpc('assassins_public_config',{p_code:code});if(ce)throw ce;
 show('playerPhoneLabel',config.phone_enabled);$('playerPhone').required=config.phone_enabled;
 show('playerHallLabel',config.hall_enabled);$('playerHall').required=config.hall_enabled;
 $('instructionsText').textContent=config.instructions_enabled?config.instructions_text:'';
 show('instructionsArea',config.instructions_enabled);
 show('acceptInstructionsLabel',config.instructions_enabled&&config.instruction_verification_enabled);
 $('instructionsAccepted').required=config.instructions_enabled&&config.instruction_verification_enabled;
 const sel=$('playerHall');sel.replaceChildren(node('option','Choose hall'));
 for(const h of config.hall_options.split(',').map(x=>x.trim()).filter(Boolean)){const opt=node('option',h);opt.value=h;sel.append(opt)}
 }
 if(g.game_status!=='registration')msg('Registration is not open for this game.');
}
async function loadLobby(id){
 const {data,error}=await db.rpc('list_game_lobby',{p_game_id:id});if(error)throw error;
 currentGame=id;show('lobby',true);$('lobbyList').replaceChildren();
 $('lobbyList').append(node('p',data.length+' player(s) registered'));
 for(const p of data)$('lobbyList').append(node('div',p.real_name));
}
$('authForm').onsubmit=e=>{e.preventDefault();task(e.currentTarget,async()=>{const {error}=await db.auth.signInWithPassword({email:$('email').value.trim(),password:$('password').value});if(error)throw error;msg('Signed in.')})};
$('signup').onclick=()=>task($('authForm'),async()=>{const {data,error}=await db.auth.signUp({email:$('email').value.trim(),password:$('password').value});if(error)throw error;msg(data.session?'Account created.':'Check your email to confirm your account.')});
$('guestStart').onclick=()=>task($('guestActions'),async()=>{const {error}=await db.auth.signInAnonymously();if(error)throw error;msg('Guest session ready. Keep this browser session to return to your game.')});
$('signout').onclick=$('guestSignout').onclick=async()=>{const {error}=await db.auth.signOut();if(error)fail(error);else{currentGame=null;msg('Signed out.');await refresh()}};
$('redeemForm').onsubmit=e=>{e.preventDefault();task(e.currentTarget,async()=>{const {error}=await db.rpc('redeem_game_invite',{p_code:$('invite').value.trim()});if(error)throw error;$('invite').value='';msg('Game credit added.')})};
$('createForm').onsubmit=e=>{e.preventDefault();task(e.currentTarget,async()=>{const {data,error}=await db.rpc('create_hosted_game',{p_game_type:$('gameType').value,p_name:$('gameName').value.trim()});if(error)throw error;$('gameName').value='';msg('Game created: '+data[0].join_code+'. Open registration to accept players.')})};
$('issueForm').onsubmit=e=>{e.preventDefault();task(e.currentTarget,async()=>{const date=$('expiry').value;const {data,error}=await db.rpc('admin_issue_game_invite',{p_expires_at:date?new Date(date+'T23:59:59').toISOString():null});if(error)throw error;$('issuedCode').textContent='Copy this invitation code now: '+data;msg('Invitation generated.')})};
$('lookupForm').onsubmit=e=>{e.preventDefault();task(e.currentTarget,lookup)};
$('joinForm').onsubmit=e=>{e.preventDefault();task(e.currentTarget,async()=>{if(!currentUser)throw Error('Sign in or continue as guest first.');const gameType=$('joinForm').dataset.gameType;
 const {data,error}=gameType==='assassins'?await db.rpc('assassins_join',{p_code:$('joinForm').dataset.code,p_codename:$('codename').value.trim(),p_real_name:$('realName').value.trim(),p_phone:$('playerPhone').value.trim(),p_hall:$('playerHall').value.trim(),p_accepted:$('instructionsAccepted').checked}):await db.rpc('join_game',{p_code:$('joinForm').dataset.code,p_codename:$('codename').value.trim()});if(error)throw error;currentGame=data;msg('Joined successfully!')})};
const queryCode=new URL(location.href).searchParams.get('join');if(queryCode)$('joinCode').value=queryCode;
db.auth.onAuthStateChange(()=>setTimeout(()=>refresh().catch(fail),0));
refresh().then(()=>{if(queryCode)return lookup().catch(fail)}).catch(fail);
