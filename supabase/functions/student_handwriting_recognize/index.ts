// 학생용 앱 필기 인식 VLM 폴백 Edge Function.
//
// 온디바이스 ML Kit(en-US 텍스트 모델)은 긴 다항식·문자 답을 잘 읽지 못한다
// (필기 탭 신고 #1~#3의 공통 원인). 온디바이스 후보가 전부 "답 형태가
// 아닐 때"만 학생앱이 필기 렌더 PNG를 이 함수로 보내 Gemini 로 2차 인식한다.
// 온디바이스 성공 시에는 호출되지 않으므로 비용은 실패 사례에만 발생한다.
//
// 요청:  { image_base64, mime_type?, answer_kind? }
// 응답:  { ok: true, text: "3x^2+2x-1", model: "..." }
//
// 모델: GEMINI_HANDWRITING_MODEL > GEMINI_MODEL > 기본값.
// GEMINI_API_KEY 미설정 시 { ok: false, error: 'ai_unavailable' }.

import { corsHeaders } from '../_shared/cors.ts';
import { createAdminClient } from '../_shared/supabase.ts';

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

// deno-lint-ignore no-explicit-any
type Admin = any;

async function resolveStudent(req: Request, admin: Admin) {
  const auth = req.headers.get('Authorization') ?? '';
  const token = auth.replace(/^Bearer\s+/i, '').trim();
  if (!token) return null;
  const { data: userData, error } = await admin.auth.getUser(token);
  if (error || !userData?.user) return null;
  const { data: account } = await admin
    .from('student_app_accounts')
    .select('academy_id, student_id')
    .eq('user_id', userData.user.id)
    .maybeSingle();
  if (!account) return null;
  return {
    academyId: account.academy_id as string,
    studentId: account.student_id as string,
  };
}

const ALLOWED_MIMES = new Set(['image/png', 'image/jpeg', 'image/webp']);

function buildPrompt(answerKind: string): string {
  const lines = [
    '첨부된 이미지는 학생이 수학 문제의 답을 손으로 쓴 필기다',
    '(흰 배경, 검정 획).',
    '필기를 읽어 답을 선형 표기 텍스트로 정확히 옮겨라.',
    '',
    '규칙:',
    '- 분수는 (분자)/(분모), 거듭제곱은 ^, 제곱근은 √( ) 로 쓴다.',
    '  예: 3x^2+2x-1, (2)/(3), 2√(3), -5, 0.75, x=3',
    '- 지수처럼 위로 올려 쓴 작은 숫자는 ^ 로 해석한다.',
    '- 필기에 없는 내용을 추가하거나 수식을 정리/계산하지 마라.',
    '  쓰인 그대로 옮긴다.',
    answerKind === 'objective'
      ? '- 이 답은 객관식 보기 번호(1~5 중 하나)일 가능성이 높다.'
      : '',
    '- 읽을 수 없으면 빈 문자열을 반환한다.',
    '',
    'JSON 객체 하나만 출력하라: {"text": "읽은 내용"}',
  ];
  return lines.filter((l) => l !== '').join('\n');
}

async function recognize(
  imageBase64: string,
  mimeType: string,
  answerKind: string,
): Promise<{ text: string; model: string } | null> {
  const apiKey = Deno.env.get('GEMINI_API_KEY')?.trim();
  if (!apiKey) return null;
  const model = Deno.env.get('GEMINI_HANDWRITING_MODEL')?.trim() ||
    Deno.env.get('GEMINI_MODEL')?.trim() ||
    'gemini-3.1-pro-preview';

  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent?key=${encodeURIComponent(apiKey)}`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        contents: [{
          role: 'user',
          parts: [
            { inline_data: { mime_type: mimeType, data: imageBase64 } },
            { text: buildPrompt(answerKind) },
          ],
        }],
        generationConfig: {
          temperature: 0,
          responseMimeType: 'application/json',
          maxOutputTokens: 256,
        },
      }),
    },
  );
  if (!res.ok) throw new Error(`gemini_http_${res.status}`);
  const payload = await res.json();
  const raw = (payload?.candidates?.[0]?.content?.parts ?? [])
    .map((p: { text?: string }) => p?.text ?? '')
    .join('\n')
    .trim();
  const parsed = JSON.parse(raw);
  return { text: String(parsed?.text ?? '').trim(), model };
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

  const admin = createAdminClient();
  const student = await resolveStudent(req, admin);
  if (!student) return json({ ok: false, error: 'unauthorized' }, 401);

  const imageBase64 = String(body.image_base64 ?? '').trim();
  if (!imageBase64) return json({ ok: false, error: 'missing_image' }, 400);
  // 필기 렌더 PNG 는 수십 KB 수준 — 비정상적으로 큰 요청은 거절.
  if (imageBase64.length > 2_000_000) {
    return json({ ok: false, error: 'image_too_large' }, 400);
  }
  const mimeType = String(body.mime_type ?? 'image/png').trim();
  if (!ALLOWED_MIMES.has(mimeType)) {
    return json({ ok: false, error: 'invalid_mime_type' }, 400);
  }
  const answerKind = String(body.answer_kind ?? 'subjective').trim();

  try {
    const result = await recognize(imageBase64, mimeType, answerKind);
    if (result === null) {
      return json({ ok: false, error: 'ai_unavailable' }, 503);
    }
    return json({ ok: true, text: result.text, model: result.model });
  } catch (e) {
    return json(
      {
        ok: false,
        error: 'recognize_failed',
        detail: String((e as Error)?.message ?? e),
      },
      502,
    );
  }
});
