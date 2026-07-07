// 학생용 앱 회원가입 Edge Function.
//
// 흐름:
//   1) 원장이 학습앱에서 student_issue_signup_code RPC로 가입코드를 발급
//   2) 학생이 앱에서 { code, username, password } 로 이 함수를 호출
//   3) service role로 가입코드 검증 → auth 계정 생성(이메일 인증 완료 상태)
//      → student_app_accounts 매핑 → 코드 사용 처리
//   4) 앱은 반환된 email로 signInWithPassword 하여 로그인
//
// 학생 아이디는 실제 이메일이 아니므로 <username>@student.yggdrasill.app 로
// 변환해 저장한다. (이메일 인증은 admin.createUser(email_confirm: true)로 우회)

import { corsHeaders } from '../_shared/cors.ts';
import { createAdminClient } from '../_shared/supabase.ts';

const EMAIL_DOMAIN = 'student.yggdrasill.app';
const USERNAME_RE = /^[a-z0-9._-]{3,20}$/;

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

  const code = String(body.code ?? '').trim().toUpperCase();
  const username = String(body.username ?? '').trim().toLowerCase();
  const password = String(body.password ?? '');

  if (!code) return json({ ok: false, error: 'code_required' });
  if (!USERNAME_RE.test(username)) {
    return json({ ok: false, error: 'invalid_username' });
  }
  if (password.length < 6) {
    return json({ ok: false, error: 'weak_password' });
  }

  const admin = createAdminClient();
  const email = `${username}@${EMAIL_DOMAIN}`;

  // 1) 가입코드 사전 검증 (계정 생성 전에 코드 유효성만 확인)
  const { data: codeRow, error: codeErr } = await admin
    .from('student_signup_codes')
    .select('code, academy_id, student_id, expires_at, used_at')
    .eq('code', code)
    .maybeSingle();

  if (codeErr) return json({ ok: false, error: 'code_lookup_failed' });
  if (!codeRow) return json({ ok: false, error: 'code_not_found' });
  if (codeRow.used_at) return json({ ok: false, error: 'code_used' });
  if (new Date(codeRow.expires_at) <= new Date()) {
    return json({ ok: false, error: 'code_expired' });
  }

  // 2) 계정 생성 (이메일 인증 완료 상태)
  const { data: created, error: createErr } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: {
      kind: 'student',
      username,
      academy_id: codeRow.academy_id,
      student_id: codeRow.student_id,
    },
  });

  if (createErr || !created?.user) {
    const msg = String(createErr?.message ?? '');
    if (msg.toLowerCase().includes('already') || msg.includes('registered')) {
      return json({ ok: false, error: 'username_taken' });
    }
    return json({ ok: false, error: 'create_failed', detail: msg });
  }

  // 3) 코드 사용 처리 + 계정 매핑 (원자적 RPC)
  const { data: redeemed, error: redeemErr } = await admin.rpc(
    'student_signup_redeem',
    {
      p_code: code,
      p_user_id: created.user.id,
      p_username: username,
    },
  );

  const redeemOk =
    !redeemErr && redeemed && (redeemed as Record<string, unknown>).ok === true;

  if (!redeemOk) {
    // 매핑 실패 시 고아 계정을 남기지 않는다.
    await admin.auth.admin.deleteUser(created.user.id);
    const errCode = redeemErr
      ? 'redeem_failed'
      : String((redeemed as Record<string, unknown>)?.error ?? 'redeem_failed');
    return json({ ok: false, error: errCode });
  }

  return json({ ok: true, email });
});
