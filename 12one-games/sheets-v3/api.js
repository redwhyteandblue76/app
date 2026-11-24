(function(global){
"use strict";
function endpoint(raw){const u=new URL(raw);if(u.protocol!=="https:"||u.hostname!=="script.google.com"||!/^\/macros\/s\/[A-Za-z0-9_-]+\/exec$/.test(u.pathname)||u.username||u.password||u.port||u.search||u.hash)throw Error("Configure a valid Apps Script /exec URL.");return u.href;}
async function request(url,action,payload={},transport=global.fetch){
 const body=JSON.stringify({...payload,action});const abort=new AbortController(),timer=setTimeout(()=>abort.abort(),35000);
 try{const res=await transport(endpoint(url),{method:"POST",headers:{"Content-Type":"text/plain;charset=UTF-8"},body,mode:"cors",credentials:"omit",redirect:"follow",cache:"no-store",referrerPolicy:"no-referrer",signal:abort.signal});
 if(!res.ok)throw Error("Backend returned HTTP "+res.status+".");let j;try{j=await res.json();}catch{throw Error("Backend did not return JSON. Check deployment access and URL.");}if(j.ok!==true)throw Error(j.error||"Request failed.");return j.data;
 }catch(e){if(e.name==="AbortError")throw Error("Request timed out. Refresh to check whether it succeeded before retrying.");if(e instanceof TypeError)throw Error("Cannot reach the backend. Check connection, deployment access, and CORS.");throw e;}finally{clearTimeout(timer);}
}
global.GamesV3API={endpoint,request};
})(typeof window==="undefined"?globalThis:window);
