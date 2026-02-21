import { corsHeaders } from '../_shared/cors.ts';
import { createAdminClient } from '../_shared/supabase.ts';

function json(body: unknown) {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}
function ok(body: Record<string, unknown> = {}) { return json({ ok: true, ...body }); }
function fail(code: string, error: string) { return json({ ok: false, code, error }); }

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return fail('method_not_allowed', 'Method not allowed');

  try {
    const payload = await req.json();
    const items: Array<{
      participant_id: string;
      email: string;
      name: string;
      report_params: Record<string, unknown>;
    }> = payload?.items;
    const baseUrl = String(payload?.base_url ?? '').replace(/\/$/, '');

    if (!Array.isArray(items) || items.length === 0) {
      return fail('missing_items', 'items 배열이 필요합니다.');
    }
    if (!baseUrl) return fail('missing_base_url', 'base_url이 필요합니다.');

    const admin = createAdminClient();
    const resendKey = (Deno.env.get('RESEND_API_KEY') ?? '').trim();
    const resendFrom = (Deno.env.get('RESEND_FROM') ?? '').trim();
    if (!resendKey || !resendFrom) {
      return fail('missing_email_provider_config', '메일 발송 설정이 없습니다.');
    }

    const results: Array<{ participant_id: string; status: string; error?: string }> = [];
    const delay = (ms: number) => new Promise((r) => setTimeout(r, ms));

    for (let idx = 0; idx < items.length; idx++) {
      if (idx > 0) await delay(600);
      const item = items[idx];
      const pid = String(item.participant_id ?? '').trim();
      const email = String(item.email ?? '').trim();
      const name = String(item.name ?? '').trim() || '학생';
      if (!pid || !email) {
        results.push({ participant_id: pid, status: 'skipped', error: 'missing_fields' });
        continue;
      }

      try {
        const { data: existing } = await admin
          .from('trait_report_tokens')
          .select('token')
          .eq('participant_id', pid)
          .maybeSingle();

        const token = existing?.token ?? crypto.randomUUID();
        const now = new Date().toISOString();

        await admin.from('trait_report_tokens').upsert({
          participant_id: pid,
          token,
          report_params: item.report_params ?? {},
          email,
          updated_at: now,
        }, { onConflict: 'participant_id' });

        const link = `${baseUrl}/report-preview?token=${token}`;

        const html = `
          <div style="font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial; max-width: 480px;">
            <p>${name}님, 안녕하세요.</p>
            <p>수학 학습 성향 조사 결과가 준비되었습니다.</p>
            <p style="margin: 20px 0;">
              <a href="${link}" style="display: inline-block; padding: 12px 24px; background: #22C55E; color: #fff; text-decoration: none; border-radius: 8px; font-weight: 700;">내 결과 보기</a>
            </p>
            <p style="font-size: 13px; color: #888;">위 버튼이 작동하지 않으면 아래 링크를 복사하여 브라우저에 붙여넣어 주세요.</p>
            <p style="font-size: 12px; color: #aaa; word-break: break-all;">${link}</p>
            <p>감사합니다.</p>
          </div>
        `.trim();
        const text = `${name}님, 안녕하세요.\n\n수학 학습 성향 조사 결과가 준비되었습니다.\n\n결과 보기: ${link}\n\n감사합니다.`;

        const mailResp = await fetch('https://api.resend.com/emails', {
          method: 'POST',
          headers: { Authorization: `Bearer ${resendKey}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({
            from: resendFrom,
            to: [email],
            subject: '수학 학습 성향 조사 결과',
            html,
            text,
          }),
        });

        const mailText = await mailResp.text();
        let messageId: string | null = null;
        try { const j = JSON.parse(mailText); if (j?.id) messageId = String(j.id); } catch {}

        if (!mailResp.ok) {
          await admin.from('trait_report_tokens').update({
            sent_at: now,
            last_send_status: 'error',
            last_send_error: mailText.slice(0, 300),
            last_message_id: null,
            updated_at: now,
          }).eq('participant_id', pid);
          results.push({ participant_id: pid, status: 'error', error: mailText.slice(0, 200) });
        } else {
          await admin.from('trait_report_tokens').update({
            sent_at: now,
            last_send_status: 'sent',
            last_send_error: null,
            last_message_id: messageId,
            updated_at: now,
          }).eq('participant_id', pid);
          results.push({ participant_id: pid, status: 'sent' });
        }
      } catch (e) {
        results.push({ participant_id: pid, status: 'error', error: String((e as any)?.message ?? e).slice(0, 200) });
      }
    }

    const sentCount = results.filter((r) => r.status === 'sent').length;
    return ok({ sent: sentCount, total: items.length, results });
  } catch (e) {
    return fail('exception', String((e as any)?.message ?? e));
  }
});
