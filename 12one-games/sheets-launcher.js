/* 12one Games Sheets edition: GitHub Pages entrypoints.
 * Set APPS_SCRIPT_WEB_APP_URL to your deployed Google Apps Script /exec URL.
 * The actual interactive app and spreadsheet authorization remain in Apps Script.
 * Supabase edition is untouched.
 */
(function(){
 'use strict';
 const APPS_SCRIPT_WEB_APP_URL = ''; // paste your deployed /exec URL here
 const $ = id => document.getElementById(id);
 const normalize = url => {
  try {const u=new URL(String(url||'').trim());if(u.protocol!=='https:'||u.hostname!=='script.google.com'||!/^\/macros\/s\/[^/]+\/exec\/?$/.test(u.pathname))return '';return u.origin+u.pathname;}catch{return '';}
 };
 const saved = (()=>{try{return localStorage.getItem('12one_sheets_script_url')||'';}catch{return '';}})();
 const endpoint = () => normalize(APPS_SCRIPT_WEB_APP_URL)||normalize(saved);
 const page = document.body.dataset.page||'player';
 const gameType = document.body.dataset.type||'';
 const status = $('connectionStatus'), link=$('openApp');
 const urlFor = () => {
  const base=endpoint();
  if(!base)return '';
  const u=new URL(base);u.searchParams.set('page',page);
  if(page==='player'){
   const raw=($('gameCode')?.value||'').trim().toUpperCase();
   if(raw){
    if(!/^(MAFIA|ASSASSINS)[0-9]{6}$/.test(raw)||gameType&&!raw.startsWith(gameType.toUpperCase()))throw Error('Enter a '+(gameType||'game')+' code in the correct format.');
    u.searchParams.set('game',raw);
   }
  }
  return u.href;
 };
 const update = () => {
  const ready=!!endpoint();
  if(status)status.textContent=ready?'Google Sheets backend configured':'Google Apps Script deployment URL not configured yet.';
  if(link){link.disabled=!ready;link.textContent=page==='admin'?'Open administrator dashboard':page==='host'?'Open host dashboard':'Open '+gameType+' game';}
 };
 if($('gameCode')){
  const given=new URLSearchParams(location.search).get('game');
  if(given&&/^(MAFIA|ASSASSINS)[0-9]{6}$/.test(given.toUpperCase()))$('gameCode').value=given.toUpperCase();
 }
 if($('scriptUrl'))$('scriptUrl').value=endpoint();
 if($('saveUrl'))$('saveUrl').addEventListener('click',()=>{
  const url=normalize($('scriptUrl').value);
  if(!url){status.textContent='Enter a valid Google Apps Script /exec deployment URL.';return;}
  try{localStorage.setItem('12one_sheets_script_url',url);}catch{status.textContent='Browser storage is unavailable. Add the URL to sheets-launcher.js instead.';return;}
  update();
 });
 if(link)link.addEventListener('click',()=>{
  try{
   const url=urlFor();
   if(!url){update();return;}
   location.assign(url);
  }catch(e){status.textContent=e.message;}
 });
 update();
})();