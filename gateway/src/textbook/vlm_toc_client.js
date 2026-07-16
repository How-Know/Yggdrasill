// 교재 목차('차례') 페이지들에서 대/중/소단원 트리를 추출하는 Gemini Vision 클라이언트.
//
// 입력: 목차 페이지들을 래스터한 PNG 배열 (여러 페이지를 한 호출에 담아
//       책 전체 목차를 한 번에 읽는다 — 페이지를 나눠 부르면 단원 순서/중첩이 깨진다)
// 출력: 책에 인쇄된 계층 그대로의 JSON 트리. 매니저앱이 시리즈별 규칙에 따라
//       우리 단원 구조(대/중/소 슬롯)로 매핑한다.
//
// `vlm_detect_client.js`(문항번호 탐지) 와는 목적이 달라 분리했다.

import {
  closeTruncatedJson,
  extractBalancedJsonObject,
  repairLatexBackslashes,
} from '../problem_bank/extract_engines/vlm/client.js';

const TRANSIENT_STATUSES = new Set([429, 500, 502, 503, 504]);
const DEFAULT_MAX_RETRIES = 3;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/// 목차 VLM 응답 전용 느슨한 JSON 파서.
///
/// Gemini가 finishReason=STOP인데도 마지막 괄호를 빠뜨리거나 정상 JSON 뒤에
/// 여분의 `}`를 붙이는 두 변형을 모두 복구한다.
export function parseTocModelJson(text) {
  const source = String(text || '').trim();
  for (const candidate of [source, repairLatexBackslashes(source)]) {
    try {
      return JSON.parse(candidate);
    } catch (_) {
      const balanced = extractBalancedJsonObject(candidate);
      if (balanced) {
        try {
          return JSON.parse(balanced);
        } catch (_) {
          // 아래 복구로 진행한다.
        }
      }
      const greedy = candidate.match(/\{[\s\S]*\}/);
      if (greedy) {
        try {
          return JSON.parse(greedy[0]);
        } catch (_) {
          // 마지막 닫는 괄호 복구로 진행한다.
        }
      }
      const closed = closeTruncatedJson(candidate);
      if (closed) return closed;
    }
  }
  return null;
}

export function buildParseTocPrompt({ pageCount, series = '' }) {
  const seriesKey = String(series || '').trim().toLowerCase();
  const ssenLines =
    seriesKey === 'ssen'
      ? [
          '',
          '=== 쎈 교재 목차 규칙 (매우 중요) ===',
          '이 교재(쎈)의 목차는 2단계다:',
          '  - 대단원: "I 기본 도형"처럼 로마숫자와 큰 제목으로 표기된다.',
          '    로마숫자는 버리고 이름만 big_units[].name에 담아라.',
          '  - 중단원: "01 기본 도형 8"처럼 두 자리 번호, 이름, 시작 페이지가 한 줄에 표기된다.',
          '    번호는 버리고 이름을 mid_units[].name, 줄 오른쪽의 페이지 숫자를 mid_units[].page에 담아라.',
          '쎈의 "A 기본다잡기", "B 유형뽀개기", "C 만점도전하기"는',
          '중단원마다 반복되는 문제 파트이지 소단원이 아니다. sub_units는 반드시 []로 둔다.',
          '"부록", "정답 및 풀이", "빠른 정답" 같은 부속물은 단원트리에 넣지 마라.',
          '그 시작 페이지가 목차에 보이면 마지막 중단원의 종료 경계로 쓸 수 있도록',
          'appendix_boundary_page에 담아라.',
          '각 중단원 줄의 시작 페이지를 빠짐없이 읽어라. 페이지가 선명하게 보이는데 null로 두지 마라.',
        ]
      : [];
  const rpmLines =
    seriesKey === 'rpm'
      ? [
          '',
          '=== RPM 교재 목차 규칙 (매우 중요) ===',
          '이 교재(RPM)의 목차는 2단계다:',
          '  - 대단원: "I. 소인수분해"처럼 로마숫자와 큰 제목으로 표기된다.',
          '    로마숫자는 버리고 이름만 big_units[].name에 담아라.',
          '  - 중단원: "01 소인수분해 8"처럼 두 자리 번호, 이름, 시작 페이지가 한 줄에 표기된다.',
          '    번호는 버리고 이름을 mid_units[].name, 줄 오른쪽의 페이지 숫자를 mid_units[].page에 담아라.',
          'RPM의 "교과서문제 정복하기", "유형 익히기", "시험에 꼭 나오는 문제"는',
          '중단원마다 반복되는 문제 파트이지 소단원이 아니다. sub_units는 반드시 []로 둔다.',
          '"부록 대표문제 다시 풀기"는 단원트리에 넣지 마라. 단, 그 줄 오른쪽의 시작 페이지는',
          '마지막 중단원의 종료 경계이므로 appendix_boundary_page에 반드시 담아라.',
          '각 중단원 줄의 시작 페이지를 빠짐없이 읽어라. 페이지가 선명하게 보이는데 null로 두지 마라.',
        ]
      : [];
  const wonriLines =
    seriesKey === 'wonri'
      ? [
          '',
          '=== 개념원리 교재 힌트 (매우 중요) ===',
          '이 교재(개념원리)의 목차는 3단계다:',
          '  - 대단원: "I. 다항식" 처럼 로마숫자 표기 → big_units[].name.',
          '    로마숫자/번호는 인식할 필요 없다. 이름만 담아라 (예: "다항식").',
          '  - 중단원: "1. 다항식의 연산" 처럼 숫자 표기 → mid_units[].name. 이름만 담아라.',
          '  - 소단원: "01 다항식의 덧셈과 뺄셈" 처럼 두 자리 번호 표기 → sub_units[].name. 이름만 담아라.',
          'sub_units 에는 (a) 번호 붙은 소단원 항목과 (b) "연습문제" 항목을 목차에 인쇄된 순서 그대로 넣는다.',
          '"연습문제" 는 { "name": "연습문제", "is_exercise": true } 로 표시하라.',
          '한 중단원 안에 "연습문제" 가 여러 번(소단원 사이사이에) 나올 수 있다 — 나올 때마다 그 위치에 각각 넣어라.',
          '**매우 중요**: 개념원리 목차는 각 소단원/연습문제 이름 오른쪽(점선 뒤 또는 줄 끝)에 시작 페이지',
          '숫자가 반드시 인쇄돼 있다. 모든 sub_units 항목의 page 를 그 인쇄 숫자로 빠짐없이 채워라.',
          '페이지 숫자를 절대 null 로 비우지 마라 (정말 안 보이는 경우에만 null).',
          '"개념원리 이해", "개념원리 익히기", "필수유형", "확인 체크", "특강", "STEP" 같은',
          '문제 카테고리 라벨은 단원이 아니다 — 어느 레벨에도 절대 넣지 마라.',
        ]
      : [];
  return [
    '당신은 한국 중·고등 수학 교재의 **목차(차례) 페이지**를 읽고 단원 트리를 추출하는 비전 AI 입니다.',
    '반드시 아래 JSON 스키마만 출력하세요. 설명·마크다운·주석·코드펜스 모두 금지.',
    '',
    `첨부된 ${pageCount}장의 이미지는 한 교재의 목차 페이지들을 순서대로 래스터한 것이다.`,
    '모든 이미지를 이어서 하나의 목차로 읽어라 (앞 이미지에서 시작된 단원이 뒤 이미지로 이어질 수 있다).',
    ...ssenLines,
    ...rpmLines,
    ...wonriLines,
    '',
    '=== 출력 스키마 ===',
    '{',
    '  "big_units": [',
    '    {',
    '      "name": "<대단원 이름. 앞에 붙는 번호/로마숫자 표기는 빼고 이름만>",',
    '      "mid_units": [',
    '        {',
    '          "name": "<중단원 이름. 앞에 붙는 번호는 빼고 이름만>",',
    '          "page": <중단원 시작 페이지가 목차에 인쇄돼 있으면 그 정수, 아니면 null>,',
    '          "sub_units": [',
    '            {',
    '              "name": "<소단원 이름. 앞에 붙는 번호는 빼고 이름만. 연습문제 항목이면 \\"연습문제\\">",',
    '              "page": <목차에 인쇄된 시작 페이지 숫자 또는 null>,',
    '              "is_exercise": <bool — "연습문제" 항목이면 true, 일반 소단원이면 false>',
    '            }',
    '          ]',
    '        }',
    '      ]',
    '    }',
    '  ],',
    '  "appendix_boundary_page": <RPM의 트리 제외 부록 시작 페이지 또는 null>,',
    '  "notes": "<특이사항 간단히, 없으면 빈 문자열>"',
    '}',
    '',
    '=== 규칙 ===',
    '[T1] 목차에 인쇄된 이름을 그대로 옮기되, 이름 앞의 번호/로마숫자 표기만 뺀다. 임의로 요약/수정하지 마라.',
    '[T2] 소단원이 없는 교재(2단계 목차)면 sub_units=[] 로 둔다.',
    '[T3] "부록", "빠른 정답", "정답과 풀이" 같은 부속물은 트리에 넣지 마라.',
    '[T4] 페이지 숫자가 점선 오른쪽 등에 인쇄돼 있으면 page 에 정수로 담아라. 없으면 null.',
    '[T5] 순서는 목차에 인쇄된 순서 그대로 유지하라.',
    '[T6] 없는 단원을 추측해서 만들지 마라. 보이는 것만 담는다.',
    '',
    '지금 첨부된 이미지를 분석해 위 스키마로만 출력하라.',
  ].join('\n');
}

export async function parseTocPages({
  images, // [{ imageBase64, mimeType? }]
  series = '',
  model,
  apiKey,
  timeoutMs = 180000,
  maxRetries = DEFAULT_MAX_RETRIES,
}) {
  const key = String(apiKey || '').trim();
  if (!key) throw new Error('vlm_toc_api_key_missing');
  const list = Array.isArray(images) ? images.filter((i) => i?.imageBase64) : [];
  if (list.length === 0) throw new Error('vlm_toc_images_empty');

  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/` +
    `${encodeURIComponent(model)}:generateContent?key=` +
    `${encodeURIComponent(key)}`;

  const body = {
    contents: [
      {
        role: 'user',
        parts: [
          ...list.map((img) => ({
            inline_data: {
              mime_type: img.mimeType || 'image/png',
              data: String(img.imageBase64).trim(),
            },
          })),
          { text: buildParseTocPrompt({ pageCount: list.length, series }) },
        ],
      },
    ],
    generationConfig: {
      temperature: 0.1,
      responseMimeType: 'application/json',
      maxOutputTokens: 16384,
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
      throw new Error(`vlm_toc_fetch_error: ${String(err?.message || err).slice(0, 300)}`);
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
        `vlm_toc_http_${res.status}: ${String(textBody).slice(0, 500)}`,
      );
    }
    let payload;
    try {
      payload = JSON.parse(textBody);
    } catch (_) {
      throw new Error(`vlm_toc_non_json_response: ${String(textBody).slice(0, 500)}`);
    }
    const candidate = (payload?.candidates || [])[0];
    const modelText = (candidate?.content?.parts || [])
      .map((p) => p?.text || '')
      .join('\n')
      .trim();
    const parsedJson = parseTocModelJson(modelText);
    if (!parsedJson) {
      throw new Error(
        `vlm_toc_parse_failed: finish=${candidate?.finishReason || '-'} text_head="${modelText.slice(0, 180)}"`,
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
    `vlm_toc_exhausted: lastErr=${String(lastErr?.message || lastErr).slice(0, 300)}`,
  );
}

export function normalizeTocResult(parsedJson) {
  const out = { big_units: [], appendix_boundary_page: null, notes: '' };
  if (!parsedJson || typeof parsedJson !== 'object') return out;
  out.notes = String(parsedJson.notes || '').trim();
  const appendixBoundaryPage = Number.parseInt(
    String(parsedJson.appendix_boundary_page ?? ''),
    10,
  );
  out.appendix_boundary_page =
    Number.isFinite(appendixBoundaryPage) && appendixBoundaryPage > 0
      ? appendixBoundaryPage
      : null;
  const bigs = Array.isArray(parsedJson.big_units) ? parsedJson.big_units : [];
  for (const rawBig of bigs) {
    if (!rawBig || typeof rawBig !== 'object') continue;
    const bigName = String(rawBig.name || '').trim();
    if (!bigName) continue;
    const mids = [];
    const rawMids = Array.isArray(rawBig.mid_units) ? rawBig.mid_units : [];
    for (const rawMid of rawMids) {
      if (!rawMid || typeof rawMid !== 'object') continue;
      const midName = String(rawMid.name || '').trim();
      if (!midName) continue;
      const midPage = Number.parseInt(String(rawMid.page ?? ''), 10);
      const subs = [];
      const rawSubs = Array.isArray(rawMid.sub_units) ? rawMid.sub_units : [];
      for (const rawSub of rawSubs) {
        if (!rawSub || typeof rawSub !== 'object') continue;
        const subName = String(rawSub.name || '').trim();
        if (!subName) continue;
        const page = Number.parseInt(String(rawSub.page ?? ''), 10);
        subs.push({
          name: subName,
          page: Number.isFinite(page) && page > 0 ? page : null,
          is_exercise: Boolean(rawSub.is_exercise) || subName === '연습문제',
        });
      }
      mids.push({
        name: midName,
        page: Number.isFinite(midPage) && midPage > 0 ? midPage : null,
        // 구 스키마(has_exercise 불리언) 호환 — 새 스키마는 연습문제가
        // sub_units 항목(is_exercise=true)으로 위치까지 담겨 온다.
        has_exercise:
          Boolean(rawMid.has_exercise) || subs.some((s) => s.is_exercise),
        sub_units: subs,
      });
    }
    out.big_units.push({ name: bigName, mid_units: mids });
  }
  return out;
}
