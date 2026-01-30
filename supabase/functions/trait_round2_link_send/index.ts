import { corsHeaders } from '../_shared/cors.ts';
import { createAdminClient } from '../_shared/supabase.ts';

function isValidEmail(email: string): boolean {
  const v = email.trim();
  if (!v) return false;
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v);
}

function normalizeBaseUrl(raw: string): string | null {
  try {
    const u = new URL(raw);
    return `${u.protocol}//${u.host}`;
  } catch {
    return null;
  }
}

function json(body: unknown) {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

function ok(body: Record<string, unknown> = {}) {
  return json({ ok: true, ...body });
}

function fail(code: string, error: string) {
  return json({ ok: false, code, error });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return fail('method_not_allowed', 'Method not allowed');

  try {
    const payload = await req.json();
    const participantId = String(payload?.participant_id ?? '').trim();
    const responseId = String(payload?.response_id ?? '').trim();
    const email = String(payload?.email ?? '').trim();
    const baseUrl = normalizeBaseUrl(String(payload?.base_url ?? '').trim());

    if (!participantId || !responseId || !email || !baseUrl) {
      return fail('missing_required_fields', '필수 값이 누락되었습니다.');
    }
    if (!isValidEmail(email)) {
      return fail('invalid_email', '이메일 형식이 올바르지 않습니다.');
    }

    const admin = createAdminClient();
    const { data: resp, error: respErr } = await admin
      .from('question_responses')
      .select('id, participant_id')
      .eq('id', responseId)
      .maybeSingle();
    if (respErr || !resp) return fail('invalid_response_id', '응답 ID가 유효하지 않습니다.');
    if (String(resp.participant_id) !== participantId) return fail('participant_mismatch', '참여자 정보가 일치하지 않습니다.');

    await admin
      .from('survey_participants')
      .update({ email })
      .eq('id', participantId);

    const { data: existing } = await admin
      .from('trait_round2_links')
      .select('token')
      .eq('participant_id', participantId)
      .maybeSingle();

    const token = existing?.token ?? crypto.randomUUID();
    const now = new Date();
    const nowIso = now.toISOString();
    const expiresAt = new Date(now.getTime() + 1000 * 60 * 60 * 24 * 30);

    const { error: upsertErr } = await admin
      .from('trait_round2_links')
      .upsert({
        token,
        participant_id: participantId,
        response_id: responseId,
        email,
        updated_at: nowIso,
        expires_at: expiresAt.toISOString(),
      }, { onConflict: 'participant_id' });
    if (upsertErr) throw upsertErr;

    const link = `${baseUrl.replace(/\/$/, '')}/survey?sid=${participantId}&r2=${token}`;

    const resendKey = (Deno.env.get('RESEND_API_KEY') ?? '').trim();
    const resendFrom = (Deno.env.get('RESEND_FROM') ?? '').trim();
    if (!resendKey || !resendFrom) {
      console.error('missing_email_provider_config', { hasKey: !!resendKey, hasFrom: !!resendFrom });
      await admin
        .from('trait_round2_links')
        .update({
          last_send_status: 'error',
          last_send_error: 'missing_email_provider_config',
          last_message_id: null,
          updated_at: nowIso,
        })
        .eq('participant_id', participantId);
      return fail('missing_email_provider_config', '메일 발송 설정이 없습니다.');
    }

    const subject = '2차 설문 링크';
    const text = `안녕하세요.\n\n아래 링크를 통해 2차 설문을 진행해 주세요.\n${link}\n\n감사합니다.`;
    const html = `
      <div style="font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial;">
        <p>안녕하세요.</p>
        <p>아래 링크를 통해 2차 설문을 진행해 주세요.</p>
        <p><a href="${link}">${link}</a></p>
        <p>감사합니다.</p>
      </div>
    `.trim();

    const mailResp = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${resendKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from: resendFrom,
        to: [email],
        subject,
        html,
        text,
      }),
    });
    const mailText = await mailResp.text();
    if (!mailResp.ok) {
      console.error('email_send_failed', mailText.slice(0, 500));
      await admin
        .from('trait_round2_links')
        .update({
          last_send_status: 'error',
          last_send_error: mailText.slice(0, 300),
          last_message_id: null,
          updated_at: nowIso,
        })
        .eq('participant_id', participantId);
      return fail('email_send_failed', mailText.slice(0, 300));
    }

    let messageId: string | null = null;
    try {
      const mailJson = JSON.parse(mailText);
      if (mailJson?.id) messageId = String(mailJson.id);
    } catch {}

    await admin
      .from('trait_round2_links')
      .update({
        sent_at: nowIso,
        last_send_status: 'sent',
        last_send_error: null,
        last_message_id: messageId,
        updated_at: nowIso,
      })
      .eq('participant_id', participantId);

    return ok({ link });
  } catch (e) {
    const msg = String((e as any)?.message ?? e);
    console.error('trait_round2_link_send_exception', msg);
    return fail('exception', msg);
  }
});

