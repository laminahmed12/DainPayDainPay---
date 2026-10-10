const json=(data,status=200)=>new Response(JSON.stringify(data),{status,headers:{'content-type':'application/json;charset=utf-8','access-control-allow-origin':'*','access-control-allow-methods':'POST,OPTIONS','access-control-allow-headers':'content-type'}});
const clean=value=>String(value||'').replace(/[٠-٩]/g,c=>String('٠١٢٣٤٥٦٧٨٩'.indexOf(c))).replace(/[۰-۹]/g,c=>String('۰۱۲۳۴۵۶۷۸۹'.indexOf(c))).trim();
async function hash(value){const bytes=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value));return [...new Uint8Array(bytes)].map(x=>x.toString(16).padStart(2,'0')).join('');}
function randomToken(){const bytes=new Uint8Array(24);crypto.getRandomValues(bytes);return [...bytes].map(x=>(x%36).toString(36)).join('').toUpperCase();}
export default {
 async fetch(request,env){
  if(request.method==='OPTIONS')return new Response(null,{status:204,headers:{'access-control-allow-origin':'*','access-control-allow-methods':'POST,OPTIONS','access-control-allow-headers':'content-type'}});
  if(request.method!=='POST')return json({success:false,error:'method_not_allowed'},405);
  let data;try{data=await request.json();}catch{return json({success:false,error:'invalid_json'},400);}
  if(!env.OWNER_ADMIN_PIN||!env.ACTIVATION_CODES)return json({success:false,error:'service_not_configured'},503);
  const action=String(data.action||'');
  if(action==='owner_login'){
   if(clean(data.adminPin)!==env.OWNER_ADMIN_PIN)return json({success:false,error:'owner_denied'},403);
   const token=randomToken()+randomToken();
   await env.ACTIVATION_CODES.put('owner:'+await hash(token),JSON.stringify({createdAt:Date.now()}),{expirationTtl:900});
   return json({success:true,token,expiresIn:900});
  }
  if(action==='generate'){
   const token=String(data.ownerToken||'');
   if(!token||!await env.ACTIVATION_CODES.get('owner:'+await hash(token)))return json({success:false,error:'owner_session_expired'},401);
   const code=randomToken()+randomToken();
   await env.ACTIVATION_CODES.put('code:'+await hash(code),JSON.stringify({createdAt:Date.now(),used:false}),{expirationTtl:31536000});
   return json({success:true,code});
  }
  if(action==='redeem'){
   const code=clean(data.code).replace(/[^A-Z0-9]/g,'');
   if(code.length<20)return json({success:false,error:'invalid_code'},400);
   const key='code:'+await hash(code);const raw=await env.ACTIVATION_CODES.get(key);
   if(!raw)return json({success:false,error:'invalid_or_used_code'},403);
   const record=JSON.parse(raw);if(record.used)return json({success:false,error:'invalid_or_used_code'},403);
   record.used=true;record.activatedAt=Date.now();
   await env.ACTIVATION_CODES.put(key,JSON.stringify(record),{expirationTtl:31536000});
   return json({success:true,activated:true});
  }
  return json({success:false,error:'unknown_action'},400);
 }
};
