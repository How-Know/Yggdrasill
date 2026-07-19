import { corsHeaders } from '../_shared/cors.ts';
import { createAdminClient } from '../_shared/supabase.ts';

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (req.method !== 'POST') {
    return json({ ok: false, error: 'method_not_allowed' }, 405);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch (_) {
    return json({ ok: false, error: 'invalid_json' }, 400);
  }

  const cropId = String(body.crop_id ?? '').trim();
  if (!cropId) {
    return json({ ok: false, error: 'crop_id_required' }, 400);
  }

  const admin = createAdminClient();
  const auth = req.headers.get('Authorization') ?? '';
  const token = auth.replace(/^Bearer\s+/i, '').trim();
  const { data: userData, error: userError } =
    await admin.auth.getUser(token);
  if (userError || !userData?.user) {
    return json({ ok: false, error: 'unauthorized' }, 401);
  }

  const { data: account, error: accountError } = await admin
    .from('student_app_accounts')
    .select('academy_id,student_id')
    .eq('user_id', userData.user.id)
    .maybeSingle();
  if (accountError || !account?.academy_id || !account?.student_id) {
    return json({ ok: false, error: 'student_account_not_found' }, 403);
  }

  const { data: crop, error: cropError } = await admin
    .from('textbook_problem_crops')
    .select(
      'id,academy_id,book_id,grade_label,raw_page,storage_bucket,storage_key,width_px,height_px',
    )
    .eq('id', cropId)
    .maybeSingle();
  if (cropError || !crop || crop.academy_id !== account.academy_id) {
    return json({ ok: false, error: 'crop_not_found' }, 404);
  }

  const bucket = String(crop.storage_bucket ?? '').trim();
  const path = String(crop.storage_key ?? '').trim();
  if (!bucket || !path) {
    return json({ ok: false, error: 'image_not_available' }, 404);
  }

  const { data: signed, error: signedError } = await admin.storage
    .from(bucket)
    .createSignedUrl(path, 60 * 60);
  if (signedError || !signed?.signedUrl) {
    return json({
      ok: false,
      error: 'signed_url_failed',
      detail: signedError?.message ?? 'missing_signed_url',
    }, 500);
  }

  return json({
    ok: true,
    image_url: signed.signedUrl,
    raw_page: crop.raw_page,
    width: crop.width_px,
    height: crop.height_px,
  });
});
