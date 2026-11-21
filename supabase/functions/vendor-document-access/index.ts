import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': Deno.env.get('ALLOWED_ORIGIN') ?? '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const documentColumns = {
  cnic_front: 'cnic_front_path',
  cnic_back: 'cnic_back_path',
  business_document: 'document_path',
} as const

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (request.method !== 'POST') return json({ error: 'Method not allowed.' }, 405)

  const authorization = request.headers.get('Authorization')
  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!authorization || !supabaseUrl || !anonKey || !serviceRoleKey) {
    return json({ error: 'Administrator sign-in is required.' }, 401)
  }

  const callerClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false },
  })
  const { data: caller, error: authError } = await callerClient.auth.getUser()
  if (authError || !caller.user) return json({ error: 'Your administrator session is not valid.' }, 401)
  const { data: isAdmin, error: roleError } = await callerClient.rpc('current_user_is_admin')
  if (roleError || isAdmin !== true) return json({ error: 'Administrator access is required.' }, 403)

  let input: { seller_profile_id?: string; document_type?: keyof typeof documentColumns }
  try { input = await request.json() } catch { return json({ error: 'Invalid request body.' }, 400) }
  if (!input.seller_profile_id || !uuidPattern.test(input.seller_profile_id)) {
    return json({ error: 'Choose a valid seller application.' }, 400)
  }
  const documentType = input.document_type
  if (!documentType || !(documentType in documentColumns)) {
    return json({ error: 'Choose a supported vendor document.' }, 400)
  }

  const adminClient = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } })
  const column = documentColumns[documentType]
  const { data: seller, error: sellerError } = await adminClient
    .from('seller_profiles')
    .select(`id,user_id,${column}`)
    .eq('id', input.seller_profile_id)
    .maybeSingle()
  if (sellerError) return json({ error: 'The seller document could not be verified.' }, 500)
  if (!seller) return json({ error: 'Seller application was not found.' }, 404)

  const path = (seller as Record<string, unknown>)[column]
  if (typeof path !== 'string' || !path.trim() || !path.startsWith(`${seller.user_id}/`)) {
    return json({ error: 'This seller document is not available.' }, 404)
  }

  const { data: signed, error: signError } = await adminClient.storage
    .from('vendor-documents')
    .createSignedUrl(path, 300)
  if (signError || !signed?.signedUrl) return json({ error: 'A temporary document link could not be created.' }, 500)

  const { error: auditError } = await adminClient.from('admin_audit_logs').insert({
    actor_id: caller.user.id,
    action: 'VIEW_VENDOR_DOCUMENT',
    entity: 'seller_profiles',
    entity_id: seller.id,
    details: {
      document_type: documentType,
      storage_bucket: 'vendor-documents',
      signed_url_ttl_seconds: 300,
    },
  })
  if (auditError) return json({ error: 'Document access could not be recorded, so the document was not opened.' }, 500)

  return json({ signed_url: signed.signedUrl, expires_in_seconds: 300 })
})
