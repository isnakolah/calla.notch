export function campaignFrom(search){const params=new URLSearchParams(search);return Object.fromEntries(['utm_source','utm_medium','utm_campaign','utm_content','utm_term'].map(key=>[key,(params.get(key)||'').replace(/[^a-zA-Z0-9 _.,+\-]/g,'').slice(0,100)]));}
export function createAnalytics(){
 const enabled=navigator.doNotTrack!=='1'&&navigator.globalPrivacyControl!==true;
 const currentCampaign=campaignFrom(location.search);
 let memory=null;const sent=new Set();
 function visit(){
  const now=Date.now();let stored=memory;
  try{stored=JSON.parse(sessionStorage.getItem('calla-visit'))||stored;}catch{}
  if(!stored||now-stored.last>1800000||(Object.values(currentCampaign).some(Boolean)&&JSON.stringify(currentCampaign)!==JSON.stringify(stored.campaign))){stored={id:crypto.randomUUID(),last:now,campaign:currentCampaign,seen:[]};}
  stored.last=now;memory=stored;
  try{sessionStorage.setItem('calla-visit',JSON.stringify(stored));}catch{}
  return stored;
 }
 function post(name,detail='',eventId=crypto.randomUUID()){
  if(!enabled)return;
  const key=`${name}:${detail}`;
  if(memory&&Date.now()-memory.last>=1800000)sent.clear();
  if(name!=='pageview'&&sent.has(key))return;
  const state=visit();
  sent.add(key);
  if(name!=='pageview'&&state.seen.includes(key))return;
  state.seen.push(key);memory=state;
  try{sessionStorage.setItem('calla-visit',JSON.stringify(state));}catch{}
  let referrer='';try{referrer=document.referrer?new URL(document.referrer).origin:'';}catch{}
  const body=JSON.stringify({id:eventId,session_id:state.id,name,detail,campaign:state.campaign,referrer,device:innerWidth<=760?'mobile':innerWidth<=1100?'tablet':'desktop'});
  fetch('/api/events',{method:'POST',headers:{'Content-Type':'application/json'},body,keepalive:true}).catch(()=>{});
 }
 if(enabled){post('pageview');let active=0;const timer=setInterval(()=>{if(!document.hidden)active++;if(active>=10){post('engaged');clearInterval(timer);}},1000);}
 return {track:post,context(){return {session_id:enabled?visit().id:'',campaign:enabled?visit().campaign:currentCampaign};}};
}
