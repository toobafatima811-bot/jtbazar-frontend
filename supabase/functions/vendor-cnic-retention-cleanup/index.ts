import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{'Content-Type':'application/json','Cache-Control':'no-store'}})
Deno.serve(async(req)=>{
 if(req.method!=='POST') return json({error:'Method not allowed.'},405)
 const url=Deno.env.get('SUPABASE_URL'), anon=Deno.env.get('SUPABASE_ANON_KEY'), service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
 if(!url||!anon||!service) return json({error:'Retention cleanup is not configured.'},500)
 const verifier=createClient(url,anon,{auth:{persistSession:false}})
 const {data:ok,error:authError}=await verifier.rpc('validate_vendor_cnic_retention_cron_token',{p_token:req.headers.get('x-cron-token')??''})
 if(authError||ok!==true) return json({error:'Scheduled job authentication failed.'},401)
 const admin=createClient(url,service,{auth:{persistSession:false}})
 const {data:batch,error:claimError}=await admin.rpc('claim_vendor_cnic_retention_batch',{p_limit:100})
 if(claimError) return json({error:'Could not claim retention work.'},500)
 let completed=0,failed=0
 for(const item of batch??[]){
  const paths=[item.cnic_front_path,item.cnic_back_path].filter((p):p is string=>typeof p==='string'&&p.length>0)
  let failure:string|null=null
  if(paths.length){const {error}=await admin.storage.from('vendor-documents').remove(paths);if(error)failure='Storage object deletion failed'}
  const {error:finishError}=await admin.rpc('complete_vendor_cnic_retention_item',{p_queue_id:item.queue_id,p_success:failure===null,p_error:failure})
  if(finishError||failure)failed++;else completed++
 }
 return json({ok:failed===0,processed:(batch??[]).length,completed,failed})
})
