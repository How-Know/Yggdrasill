import { createAdminClient } from '../_shared/supabase.ts';
import { cleanQuestion, cleanTime, normalizePhone } from './validate.ts';

const jsonHeaders = { 'content-type': 'application/json; charset=utf-8' };

function reply(status: number, message: string, ok: boolean) {
  return new Response(JSON.stringify({ ok, message }), {
    status,
    headers: jsonHeaders,
  });
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return reply(405, '허용되지 않은 요청입니다.', false);
  }

  let payload: Record<string, unknown>;
  try {
    const text = await req.text();
    if (text.length > 4000) return reply(413, '내용이 너무 깁니다.', false);
    const parsed = JSON.parse(text);
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return reply(400, '신청 내용을 확인해 주세요.', false);
    }
    payload = parsed as Record<string, unknown>;
  } catch {
    return reply(400, '신청 내용을 확인해 주세요.', false);
  }

  const company = typeof payload.company === 'string' ? payload.company.trim() : '';
  if (company) return reply(200, '', true);
  if (payload.consent !== true) {
    return reply(400, '개인정보 수집에 동의해 주세요.', false);
  }

  const phone = normalizePhone(payload.phone);
  const availableTime = cleanTime(payload.availableTime);
  const question = cleanQuestion(payload.question);
  if (!phone) return reply(400, '휴대폰 번호를 확인해 주세요.', false);
  if (!availableTime) return reply(400, '상담 가능한 시간을 입력해 주세요.', false);
  if (!question.ok) return reply(400, '궁금하신 점이 너무 깁니다.', false);

  const admin = createAdminClient();
  const academies = await admin.from('academies').select('id').limit(2);
  if (academies.error || academies.data?.length !== 1) {
    return reply(500, '신청을 받지 못했습니다. 잠시 후 다시 부탁드리겠습니다.', false);
  }

  const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const recent = await admin
    .from('homepage_consultation_requests')
    .select('id', { count: 'exact', head: true })
    .eq('phone', phone)
    .gte('created_at', since);
  if (recent.error) {
    return reply(500, '신청을 받지 못했습니다. 잠시 후 다시 부탁드리겠습니다.', false);
  }
  if ((recent.count ?? 0) >= 3) {
    return reply(429, '오늘은 신청이 모두 접수되었습니다. 내일 다시 부탁드리겠습니다.', false);
  }

  const inserted = await admin.from('homepage_consultation_requests').insert({
    academy_id: academies.data[0].id,
    phone,
    available_time: availableTime,
    question: question.value,
    consent_at: new Date().toISOString(),
  });
  if (inserted.error) {
    return reply(500, '신청을 받지 못했습니다. 잠시 후 다시 부탁드리겠습니다.', false);
  }
  return reply(200, '', true);
});
