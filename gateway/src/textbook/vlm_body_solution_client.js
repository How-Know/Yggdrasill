// 개념원리 필수유형 전용: 본문 PDF 의 유형 페이지에서 각 필수유형의
// "풀이" 단락 좌표와 굵은 글씨 정답을 추출하는 Gemini Vision 클라이언트.
//
// 쎈/RPM 은 정답이 답지 PDF(vlm_answer_client), 해설이 해설 PDF
// (vlm_solution_refs_client) 에 있지만, 개념원리 필수유형은 문제 바로 아래
// 본문에 "풀이" 단락이 인쇄돼 있고 그 안의 굵은 값이 정답이다.
// 한 번의 호출로 정답(answer_text)과 해설 좌표(content_region)를 함께 얻는다.

import { parseTextbookVlmJson } from './vlm_json_parse.js';

const TRANSIENT_STATUSES = new Set([429, 500, 502, 503, 504]);
const DEFAULT_MAX_RETRIES = 3;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function buildBodySolutionsPrompt({ rawPage, displayPage, expectedNumbers }) {
  const pageLine =
    displayPage != null && Number.isFinite(displayPage)
      ? `이 이미지는 교재(개념원리) 본문 PDF 의 ${displayPage}페이지이다. 이 값은 PDF raw page ${rawPage}와 동일한 입력 페이지 기준이다.`
      : `이 이미지는 교재(개념원리) 본문 PDF 의 한 페이지 (PDF raw page ${rawPage}) 이다.`;
  const expected = Array.isArray(expectedNumbers)
    ? expectedNumbers.map((n) => String(n || '').trim()).filter(Boolean)
    : [];
  const expectedBlock = expected.length
    ? [
        '=== 기대 필수유형 번호 (매우 중요) ===',
        `이 페이지에서 아래 필수유형 번호들의 "풀이" 단락과 정답을 찾고 싶다: ${expected.join(', ')}`,
        '이 페이지에 보이지 않는 번호는 item 을 만들지 말고 완전히 생략하라.',
      ]
    : [
        '=== 기대 필수유형 번호 ===',
        '이 페이지에서 보이는 모든 필수유형의 "풀이" 단락과 정답을 찾아라.',
      ];

  return [
    '당신은 한국 고등 수학 개념서(개념원리)의 본문 페이지에서 "필수유형" 예제의',
    '"풀이" 단락 위치와 정답을 추출하는 비전 AI 입니다.',
    '반드시 아래 JSON 스키마만 출력하세요. 설명·마크다운·주석·코드펜스 모두 금지.',
    '',
    pageLine,
    '',
    '=== 페이지 구조 ===',
    '유형 페이지에는 위쪽에 "필수"(또는 "발전"/"특강") 배지가 붙은 예제',
    '(번호+유형 제목+문제)가 있고, 그 아래에 "풀이" 라고 적힌 단락이 이어진다.',
    '풀이 안에 굵은 글씨로 인쇄된 최종 값이 정답이다.',
    '"필수"/"발전"/"특강" 어느 배지든 처리 방식은 동일하다. 배지 번호를 problem_number 로 쓴다.',
    '페이지 하단의 "확인 체크" 문항들은 이번 호출 대상이 아니다.',
    '',
    ...expectedBlock,
    '',
    '=== 출력 스키마 ===',
    '{',
    '  "items": [',
    '    {',
    '      "problem_number": "<필수유형 번호. 원문 그대로 (예: \\"01\\", \\"12\\")>",',
    '      "answer_kind": "objective" | "subjective",',
    '      "answer_text": "<풀이의 굵은 최종 정답. 수식은 LaTeX. 객관식(①~⑤)이면 원문자만. 못 찾으면 빈 문자열>",',
    '      "answer_latex_2d": "<주관식일 때 2D 렌더용 LaTeX. 단순하면 answer_text 와 동일. 객관식이면 빈 문자열>",',
    '      "number_region": [<ymin>, <xmin>, <ymax>, <xmax>],',
    '      "content_region": [<ymin>, <xmin>, <ymax>, <xmax>]',
    '    }',
    '  ],',
    '  "notes": "<특이사항 간단히, 없으면 빈 문자열>"',
    '}',
    '',
    '=== 규칙 ===',
    '[B1] number_region 은 필수유형 번호(와 "필수" 배지)만 감싸는 최소 박스.',
    '     좌표계: 이미지 좌상단 (0,0), 우하단 (1000,1000). [ymin, xmin, ymax, xmax] 순서.',
    '[B2] content_region 은 해당 필수유형의 "풀이" 단락 전체를 감싸는 박스다.',
    '     "풀이" 헤더 글자부터 풀이 마지막 줄(그림/표 포함)까지. 문제 본문과 확인 체크는 제외.',
    '[B3] answer_text 는 풀이 단락 안에서 굵게 강조된 최종 값이다.',
    '     - 수식은 LaTeX 로: 분수 "3/4" → "\\\\frac{3}{4}", 루트 "√2" → "\\\\sqrt{2}".',
    '     - 소문항 (1)(2) 가 있으면 "(1) 12 (2) ㄱ, ㄷ" 형식으로 이어라.',
    '     - 한글 답은 \\\\text{...} 로 감싸지 말고 원문 그대로.',
    '[B4] 문제 본문, 유형 제목, 개념 요약을 answer_text 에 넣지 마라. 정답만.',
    '[B5] 같은 번호가 중복되면 더 신뢰도 높은 것 하나만 남겨라.',
    '[B6] 없는 번호/정답을 추측해서 만들지 마라. 보이는 것만 담는다.',
    '',
    '지금 첨부된 이미지를 분석해 위 스키마로만 출력하라.',
  ].join('\n');
}

export async function extractBodySolutionsOnPage({
  imageBase64,
  mimeType = 'image/png',
  rawPage,
  displayPage,
  expectedNumbers = [],
  model,
  apiKey,
  timeoutMs = 120000,
  maxRetries = DEFAULT_MAX_RETRIES,
}) {
  const key = String(apiKey || '').trim();
  if (!key) throw new Error('vlm_body_solutions_api_key_missing');
  const img = String(imageBase64 || '').trim();
  if (!img) throw new Error('vlm_body_solutions_image_empty');

  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/` +
    `${encodeURIComponent(model)}:generateContent?key=` +
    `${encodeURIComponent(key)}`;

  const body = {
    contents: [
      {
        role: 'user',
        parts: [
          { inline_data: { mime_type: mimeType, data: img } },
          {
            text: buildBodySolutionsPrompt({
              rawPage,
              displayPage,
              expectedNumbers,
            }),
          },
        ],
      },
    ],
    generationConfig: {
      temperature: 0.1,
      responseMimeType: 'application/json',
      maxOutputTokens: 8192,
      thinkingConfig: { thinkingLevel: 'low' },
    },
  };

  let lastErr = null;
  const attempts = Math.max(1, Number(maxRetries) || 1);
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    const t0 = Date.now();
    let res;
    try {
      res = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
        signal: controller.signal,
      });
    } catch (err) {
      clearTimeout(timer);
      lastErr = err;
      if (attempt + 1 < attempts) {
        await sleep(800 * Math.pow(2, attempt));
        continue;
      }
      throw new Error(
        `vlm_body_solutions_fetch_error: ${String(err?.message || err).slice(0, 300)}`,
      );
    } finally {
      clearTimeout(timer);
    }
    const elapsedMs = Date.now() - t0;
    const textBody = await res.text();
    if (!res.ok) {
      if (TRANSIENT_STATUSES.has(res.status) && attempt + 1 < attempts) {
        await sleep(800 * Math.pow(2, attempt));
        continue;
      }
      throw new Error(
        `vlm_body_solutions_http_${res.status}: ${String(textBody).slice(0, 500)}`,
      );
    }
    let payload;
    try {
      payload = JSON.parse(textBody);
    } catch (_) {
      throw new Error(
        `vlm_body_solutions_non_json_response: ${String(textBody).slice(0, 500)}`,
      );
    }
    const candidate = (payload?.candidates || [])[0];
    const modelText = (candidate?.content?.parts || [])
      .map((p) => p?.text || '')
      .join('\n')
      .trim();
    // LaTeX 백슬래시가 많은 풀이에서 Gemini JSON 이 그대로 파싱되지 않는
    // 사례가 잦다(예: \sqrt, \frac 연속). 교재 공통 복구 파서를 사용한다.
    const parsedJson = parseTextbookVlmJson(modelText);
    if (!parsedJson) {
      throw new Error(
        `vlm_body_solutions_parse_failed: finish=${candidate?.finishReason || '-'} text_head="${modelText.slice(0, 180)}"`,
      );
    }
    return {
      parsedJson,
      elapsedMs,
      usageMetadata: payload?.usageMetadata || null,
      finishReason: candidate?.finishReason || '',
      attempts: attempt + 1,
    };
  }
  throw new Error(
    `vlm_body_solutions_exhausted: lastErr=${String(lastErr?.message || lastErr).slice(0, 300)}`,
  );
}

export function normalizeBodySolutionsResult(parsedJson) {
  const out = { items: [], notes: '' };
  if (!parsedJson || typeof parsedJson !== 'object') return out;
  out.notes = String(parsedJson.notes || '').trim();
  const rawItems = Array.isArray(parsedJson.items) ? parsedJson.items : [];
  for (const raw of rawItems) {
    if (!raw || typeof raw !== 'object') continue;
    const number = String(raw.problem_number ?? raw.number ?? '').trim();
    if (!number) continue;
    const kindRaw = String(raw.answer_kind || '').trim();
    const kind = ['objective', 'subjective'].includes(kindRaw)
      ? kindRaw
      : 'subjective';
    out.items.push({
      problem_number: number,
      answer_kind: kind,
      answer_text: String(raw.answer_text || '').trim(),
      answer_latex_2d: String(raw.answer_latex_2d || '').trim(),
      number_region: parseBbox4(raw.number_region ?? raw.number_bbox),
      content_region: parseBbox4(raw.content_region ?? raw.content_bbox),
    });
  }
  return out;
}

function parseBbox4(arr) {
  const value =
    Array.isArray(arr) && arr.length === 1 && Array.isArray(arr[0]) && arr[0].length === 4
      ? arr[0]
      : arr;
  if (!Array.isArray(value) || value.length !== 4) return null;
  const nums = value.map((v) => Number(v));
  if (!nums.every((v) => Number.isFinite(v))) return null;
  return nums.map((v) => Math.max(0, Math.min(1000, Math.round(v))));
}
