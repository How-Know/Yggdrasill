import { corsHeaders } from '../_shared/cors.ts';
import { createAdminClient } from '../_shared/supabase.ts';

const EMAIL_DOMAIN = 'student.yggdrasill.app';

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

function clientIp(req: Request): string {
  return (
    req.headers.get('cf-connecting-ip') ??
    req.headers.get('x-real-ip') ??
    req.headers.get('x-forwarded-for')?.split(',')[0] ??
    ''
  ).trim();
}

function networkAllowed(req: Request): {
  allowed: boolean;
  protected: boolean;
} {
  const allowedIps = (Deno.env.get('STUDENT_QUICK_LOGIN_ALLOWED_IPS') ?? '')
    .split(',')
    .map((value) => value.trim())
    .filter(Boolean);
  if (allowedIps.length === 0) {
    return { allowed: true, protected: false };
  }
  return {
    allowed: allowedIps.includes(clientIp(req)),
    protected: true,
  };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (req.method !== 'POST') {
    return json({ ok: false, error: 'method_not_allowed' }, 405);
  }

  const network = networkAllowed(req);
  if (!network.allowed) {
    return json({ ok: false, error: 'network_not_allowed' }, 403);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch (_) {
    return json({ ok: false, error: 'invalid_json' }, 400);
  }

  const admin = createAdminClient();
  const action = String(body.action ?? '').trim();

  if (action === 'list') {
    const { data, error } = await admin.rpc(
      'student_quick_login_candidates',
    );
    if (error) {
      return json({ ok: false, error: 'candidate_lookup_failed' }, 500);
    }
    return json({
      ok: true,
      students: data ?? [],
      network_protected: network.protected,
    });
  }

  if (action !== 'login') {
    return json({ ok: false, error: 'invalid_action' }, 400);
  }

  const studentId = String(body.student_id ?? '').trim();
  const pin = String(body.pin ?? '').trim();
  if (!studentId || !/^[0-9]{4,8}$/.test(pin)) {
    return json({ ok: false, error: 'invalid_request' }, 400);
  }

  const { data: verified, error: verifyError } = await admin.rpc(
    'student_quick_login_verify',
    {
      p_student_id: studentId,
      p_pin: pin,
    },
  );
  if (verifyError) {
    return json({ ok: false, error: 'verify_failed' }, 500);
  }
  const result = (verified ?? {}) as Record<string, unknown>;
  if (result.ok !== true) {
    return json(result, result.error === 'locked' ? 429 : 401);
  }

  const username = String(result.username ?? '').trim().toLowerCase();
  if (!username) {
    return json({ ok: false, error: 'account_not_found' }, 404);
  }

  const { data: link, error: linkError } =
    await admin.auth.admin.generateLink({
      type: 'magiclink',
      email: `${username}@${EMAIL_DOMAIN}`,
    });
  const tokenHash = link?.properties?.hashed_token ?? '';
  if (linkError || !tokenHash) {
    return json({ ok: false, error: 'session_issue_failed' }, 500);
  }

  return json({
    ok: true,
    token_hash: tokenHash,
  });
});
