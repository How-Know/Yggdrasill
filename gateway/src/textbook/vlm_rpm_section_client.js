// 쎈/RPM 중단원 본문 페이지 묶음에서 A/B/C 파트 경계를 찾는 경량 Gemini 클라이언트.
//
// 문항 좌표/본문은 추출하지 않고 페이지별 파트와 정확한 상단 헤더 가시성만
// 반환한다. 목차에서 얻은 중단원 시작/끝 범위를 A/B/C 입력칸으로 나눌 때 쓴다.

import {
  joinGeminiTextParts,
  repairLatexBackslashes,
} from '../problem_bank/extract_engines/vlm/client.js';

const TRANSIENT_STATUSES = new Set([429, 499, 500, 502, 503, 504]);
const DEFAULT_MAX_RETRIES = 3;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// 첫 JSON 오브젝트만 문자열/이스케이프를 고려해 잘라낸다.
// Gemini가 유효 JSON 뒤에 `}`나 따옴표를 덧붙여도 앞 오브젝트를 복구한다.
export function extractBalancedJsonObject(text) {
  const src = String(text || '');
  const start = src.indexOf('{');
  if (start < 0) return null;
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let index = start; index < src.length; index += 1) {
    const char = src[index];
    if (inString) {
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === '"') inString = false;
      continue;
    }
    if (char === '"') inString = true;
    else if (char === '{') depth += 1;
    else if (char === '}') {
      depth -= 1;
      if (depth === 0) return src.slice(start, index + 1);
    }
  }
  return null;
}

/// RPM 경계 응답 전용 느슨한 JSON 파서.
///
/// 전체 오브젝트의 닫힘이 누락돼도 이미 완성된 pages 원소는 복구한다.
export function parseRpmSectionModelJson(text) {
  const source = String(text || '').trim();
  for (const candidateText of [source, repairLatexBackslashes(source)]) {
    try {
      return JSON.parse(candidateText);
    } catch (_) {
      const balanced = extractBalancedJsonObject(candidateText);
      if (balanced) {
        try {
          return JSON.parse(balanced);
        } catch (_) {
          // 아래 복구로 진행한다.
        }
      }
      const greedy = candidateText.match(/\{[\s\S]*\}/);
      if (greedy) {
        try {
          return JSON.parse(greedy[0]);
        } catch (_) {
          // 완성된 개별 page 오브젝트 복구로 진행한다.
        }
      }
      const pages = [];
      const pageObjects =
        candidateText.match(/\{[^{}]*"image_index"[^{}]*\}/g) || [];
      for (const rawPageObject of pageObjects) {
        try {
          const page = JSON.parse(rawPageObject);
          if (page && typeof page === 'object') pages.push(page);
        } catch (_) {
          // 깨진 원소만 제외한다.
        }
      }
      if (pages.length > 0) {
        return {
          pages,
          notes: 'recovered_complete_pages_from_malformed_json',
        };
      }
    }
  }
  return null;
}

// 시리즈별 파트 구성. parts[0] 은 중단원 시작부터 열리는 첫 파트라 헤더 없이도
// 시작하고, 나머지는 지면 상단에 인쇄된 머리말로 경계가 잡힌다.
const SECTION_SERIES_CONFIG = Object.freeze({
  ssen: {
    bookName: '쎈',
    parts: [
      {
        code: 'basic_drill',
        slot: 'A',
        header: '기본다잡기',
        rule:
          'A에는 개념 설명 페이지가 섞일 수 있다. 문항이 없는 개념 페이지도 A이므로 section="basic_drill"이다.',
      },
      { code: 'type_practice', slot: 'B', header: '유형뽀개기' },
      {
        code: 'mastery',
        slot: 'C',
        header: '만점도전하기',
        rule: '"서술형", "사고의 기술" 같은 표시는 C 내부 코너이며 별도 파트가 아니다.',
      },
    ],
  },
  rpm: {
    bookName: 'RPM',
    parts: [
      {
        code: 'basic_drill',
        slot: 'A',
        header: '교과서문제 정복하기',
        rule:
          '개념 페이지와 "교과서문제 정복하기" 문제 페이지가 1페이지씩 교대로 반복된다. 개념만 있는 페이지도 A이다.',
      },
      { code: 'type_practice', slot: 'B', header: '유형 익히기' },
      {
        code: 'mastery',
        slot: 'C',
        header: '시험에 꼭 나오는 문제',
        rule: '"서술형 주관식", "실력 UP"은 C 내부 코너이며 별도 파트가 아니다.',
      },
    ],
  },
  // 고쟁이는 단계가 넷이다. 앞 셋은 "Step N" 원형 배지가 붙은 붉은 머리말이고,
  // 넷째 창의융합만 Step 번호 없이 초록 머리말로 붙는다.
  gojaengi: {
    bookName: '고쟁이',
    parts: [
      {
        code: 'core_type',
        slot: 'A',
        header: 'Step 1 … 핵심 유형',
        rule:
          '중단원 첫 지면은 문항이 없는 개념 정리다. 그 개념 지면도 A 이므로 ' +
          'section="core_type" 으로 둔다. 문항 지면에는 "핵심 NN"(주황) 또는 ' +
          '"발전 NN"(보라) 유형 배지가 붙고 문항 번호가 주황색이다.',
      },
      {
        code: 'advanced_type',
        slot: 'B',
        header: 'Step 2 … 심화 유형',
        rule:
          'B 의 첫 한두 지면은 "대표 문항" 과 "스키마 schema" 해설뿐이고 문항이 ' +
          '없다. 그 지면도 B 다. 이어지는 문항 지면에는 "유형 NN"(빨강) 배지가 ' +
          '붙고 문항 번호가 빨간색이다. B 끝의 "서술형" 묶음도 B 안의 코너이며 ' +
          '별도 파트가 아니다.',
      },
      {
        code: 'top_type',
        slot: 'C',
        header: 'Step 3 … 최고난도 유형',
        rule:
          'C 에는 유형 배지가 아예 없고 문항 번호만 파란색으로 이어진다.',
      },
      {
        code: 'creative_type',
        slot: 'D',
        header: '창의융합 유형',
        rule:
          'D 는 "Step" 번호가 없는 초록 머리말("종합적 사고력을 키우는 창의융합 ' +
          '유형")로 시작하고, 문항마다 "창의융합 ❶ <유형명>" 배지가 따로 붙는다. ' +
          '문항 번호는 진한 초록색이다. 이어지는 둘째 지면에는 머리말이 없다.',
      },
    ],
  },
});

// 고쟁이 워크북 지면 분류.
//
// 본문 A~D 와 달리 워크북은 교재 맨 뒤에 묶음들이 죽 몰려 있다. 지면마다 머리에
// 보라 "중단원 TEST"(그 아래 소단원 번호·이름) 또는 초록 "대단원 TEST"(그 아래
// 대단원 이름)가 반복 인쇄되므로, 지면별로 그 머리말만 읽으면 어느 중단원/대단원
// 묶음인지 그대로 갈린다. 목차에는 워크북 시작 쪽 하나만 인쇄돼 있어서 이 훑기
// 없이는 E·F 슬롯의 쪽 범위를 채울 방법이 없다.
export function buildGojaengiWorkbookPrompt(rawPages) {
  const pageList = rawPages.map((page, index) => `${index}:${page}`).join(', ');
  return [
    '당신은 한국 수학 교재 고쟁이의 **워크북** 지면들을 분류하는 비전 AI 다.',
    '문항이나 좌표를 추출하지 말고, 각 이미지가 어느 TEST 묶음의 지면인지만 판정하라.',
    '반드시 JSON만 출력하고 설명·마크다운·코드펜스는 금지한다.',
    '',
    `첨부 이미지 순서(image_index: PDF raw page)는 다음과 같다: ${pageList}`,
    '',
    '=== 지면 머리말 읽는 법 ===',
    '워크북 지면은 왼쪽 위에 배지가 하나 붙고, 그 아래 줄에 단원 이름이 온다.',
    '[G1] 보라 배지 "중단원 TEST" → corner="mid_unit_test".',
    '   그 아래 줄에 소단원 번호와 이름이 있다("○1 이등변삼각형과 직각삼각형").',
    '   번호를 unit_number, 이름을 unit_name 에 담아라. 번호의 0 은 알파벳 O',
    '   모양으로 디자인돼 있으니 숫자로 읽어라("○1" → 1).',
    '   지면 오른쪽 위의 둥근 띠("❶ 삼각형의 성질")는 이 소단원이 속한 대단원',
    '   표시다. unit_name 에 넣지 마라.',
    '[G2] 초록 배지 "대단원 TEST" → corner="big_unit_test".',
    '   그 아래 줄에 대단원 번호와 이름이 있다("❶ 삼각형의 성질").',
    '   번호를 unit_number, 이름을 unit_name 에 담아라.',
    '   지면 오른쪽 위의 긴 띠("01 이등변삼각형과 직각삼각형 ~ 02 …")는 이',
    '   대단원 TEST 가 다루는 소단원 범위 안내다. unit_name 에 넣지 마라.',
    '[G3] 펼침면의 **오른쪽 지면에는 위쪽 배지가 인쇄되지 않는다.** 대신 지면',
    '   아래 쪽 번호 옆에 꼬리말이 있다("01 이등변삼각형과 직각삼각형  169",',
    '   대단원 TEST 는 "삼각형의 성질  209"). 오른쪽 모서리에는 세로 탭으로',
    '   "중단원 TEST" / "대단원 TEST" 가 붙는다.',
    '   위쪽 배지가 없으면 이 꼬리말과 세로 탭을 읽어 corner 와 unit_number,',
    '   unit_name 을 채워라. 왼쪽 지면과 똑같은 값이 나오는 것이 정상이다.',
    '[G4] 꼬리말과 세로 탭까지 다 안 보이면 corner="unknown" 으로 두고',
    '   unit_name 은 빈 문자열로 남겨라. 앞 지면의 문맥으로 추측해 채우지 마라 —',
    '   빈 값은 앱이 앞 지면에서 이어 준다. 지어낸 이름은 되돌릴 수 없다.',
    '[G5] 문항 번호 오른쪽의 작은 "본문 011" 배지는 본문 문항 참조다. 단원',
    '   번호가 아니다.',
    '',
    '=== 출력 스키마 ===',
    '{',
    '  "pages": [',
    '    {',
    '      "image_index": <0부터 시작하는 첨부 이미지 순번>,',
    '      "raw_page": <위 목록의 PDF raw page>,',
    '      "corner": "mid_unit_test" | "big_unit_test" | "unknown",',
    '      "unit_number": <머리말의 단원 번호 또는 null>,',
    '      "unit_name": "<머리말의 단원 이름. 번호는 빼고 이름만. 없으면 빈 문자열>"',
    '    }',
    '  ],',
    '  "notes": "<판독 불가/누락 이미지가 있으면 간단히, 없으면 빈 문자열>"',
    '}',
    '',
    '모든 첨부 이미지에 대해 pages 항목을 정확히 하나씩, image_index 순서대로 반환하라.',
  ].join('\n');
}

const GOJAENGI_WORKBOOK_CORNERS = new Set([
  'mid_unit_test',
  'big_unit_test',
]);

export function normalizeGojaengiWorkbookResult(parsedJson, rawPages) {
  const inputPages = Array.isArray(rawPages) ? rawPages : [];
  const byIndex = new Map();
  const rows = Array.isArray(parsedJson?.pages) ? parsedJson.pages : [];
  for (const raw of rows) {
    if (!raw || typeof raw !== 'object') continue;
    const imageIndex = Number.parseInt(String(raw.image_index ?? ''), 10);
    if (
      !Number.isFinite(imageIndex) ||
      imageIndex < 0 ||
      imageIndex >= inputPages.length
    ) {
      continue;
    }
    const cornerRaw = String(raw.corner || '').trim();
    const unitNumber = Number.parseInt(String(raw.unit_number ?? ''), 10);
    byIndex.set(imageIndex, {
      image_index: imageIndex,
      raw_page: inputPages[imageIndex],
      corner: GOJAENGI_WORKBOOK_CORNERS.has(cornerRaw) ? cornerRaw : 'unknown',
      unit_number:
        Number.isFinite(unitNumber) && unitNumber > 0 ? unitNumber : null,
      unit_name: String(raw.unit_name || '').trim(),
    });
  }
  return {
    pages: inputPages.map(
      (page, imageIndex) =>
        byIndex.get(imageIndex) || {
          image_index: imageIndex,
          raw_page: page,
          corner: 'unknown',
          unit_number: null,
          unit_name: '',
        },
    ),
    notes: String(parsedJson?.notes || '').trim(),
  };
}

export function problemBookSectionParts(series) {
  const seriesKey = String(series || '').trim().toLowerCase();
  const cfg = SECTION_SERIES_CONFIG[seriesKey];
  return cfg ? cfg.parts : SECTION_SERIES_CONFIG.rpm.parts;
}

export function buildProblemBookSectionPrompt(rawPages, series = 'rpm') {
  const seriesKey = String(series || '').trim().toLowerCase();
  const cfg = SECTION_SERIES_CONFIG[seriesKey] || SECTION_SERIES_CONFIG.rpm;
  const parts = cfg.parts;
  const pageList = rawPages.map((page, index) => `${index}:${page}`).join(', ');
  const orderLines = [];
  parts.forEach((part, index) => {
    const opener =
      index === 0
        ? `"${part.header}" 파트로, 중단원 시작 지면부터 열린다.`
        : `지면 상단에 "${part.header}" 머리말이 인쇄된 첫 지면부터 시작한다.`;
    orderLines.push(`${index + 1}) ${part.slot} ${part.code}: ${opener}`);
    if (part.rule) orderLines.push(`   ${part.rule}`);
  });
  const sectionUnion = [...parts.map((part) => `"${part.code}"`), '"unknown"'].join(
    ' | ',
  );
  return [
    `당신은 한국 수학 교재 ${cfg.bookName}의 본문 페이지들을 순서대로 분류하는 비전 AI다.`,
    `문항이나 좌표를 추출하지 말고, 각 이미지가 ${cfg.bookName}의 어느 파트인지와 정확한 헤더 가시성만 판정하라.`,
    '반드시 JSON만 출력하고 설명·마크다운·코드펜스는 금지한다.',
    '',
    `첨부 이미지 순서(image_index: PDF raw page)는 다음과 같다: ${pageList}`,
    '',
    `=== ${cfg.bookName}의 고정 순서 ===`,
    '한 중단원은 항상 다음 순서로 진행되며 뒤로 되돌아가지 않는다.',
    ...orderLines,
    '',
    '=== 헤더 플래그 규칙 ===',
    '- header_visible 은 그 지면 상단에 자기 파트의 머리말이 실제로 인쇄돼',
    '  보일 때만 true 다. 보이는 지면마다 그대로 true 로 두면 된다 —',
    '  교재에 따라 같은 머리말이 펼침면마다 반복 인쇄되기도 하는데, 파트 경계는',
    '  읽는 이가 그중 가장 앞선 지면으로 정하니 너는 판단하지 말고 보이는 대로만 적어라.',
    '- 이전/다음 이미지의 문맥이나 문항 모양만으로 header_visible 을 true 로 추측하지 마라.',
    '- 머리말이 없는 이어지는 지면도 순서와 지면 스타일을 이용해 section 은 올바르게 유지하라.',
    '',
    '=== 출력 스키마 ===',
    '{',
    '  "pages": [',
    '    {',
    '      "image_index": <0부터 시작하는 첨부 이미지 순번>,',
    '      "raw_page": <위 목록의 PDF raw page>,',
    `      "section": ${sectionUnion},`,
    '      "header_visible": <bool — 이 지면에 위 section 의 머리말이 인쇄돼 있으면 true>',
    '    }',
    '  ],',
    '  "notes": "<판독 불가/누락 이미지가 있으면 간단히, 없으면 빈 문자열>"',
    '}',
    '',
    '모든 첨부 이미지에 대해 pages 항목을 정확히 하나씩, image_index 순서대로 반환하라.',
  ].join('\n');
}

export function buildRpmSectionPrompt(rawPages) {
  return buildProblemBookSectionPrompt(rawPages, 'rpm');
}

export function buildSsenSectionPrompt(rawPages) {
  return buildProblemBookSectionPrompt(rawPages, 'ssen');
}

export async function classifyRpmSectionPages({
  images, // [{ imageBase64, mimeType?, rawPage }]
  series = 'rpm',
  // 'body' = 중단원 본문의 단계 경계, 'workbook' = 고쟁이 워크북 묶음 머리말.
  scope = 'body',
  model,
  apiKey,
  timeoutMs = 180000,
  maxRetries = DEFAULT_MAX_RETRIES,
}) {
  const key = String(apiKey || '').trim();
  if (!key) throw new Error('vlm_rpm_section_api_key_missing');
  const list = Array.isArray(images)
    ? images.filter((image) => image?.imageBase64 && Number(image?.rawPage) > 0)
    : [];
  if (list.length === 0) throw new Error('vlm_rpm_section_images_empty');

  const rawPages = list.map((image) => Number.parseInt(String(image.rawPage), 10));
  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/` +
    `${encodeURIComponent(model)}:generateContent?key=${encodeURIComponent(key)}`;
  const body = {
    contents: [
      {
        role: 'user',
        parts: [
          ...list.map((image) => ({
            inline_data: {
              mime_type: image.mimeType || 'image/png',
              data: String(image.imageBase64).trim(),
            },
          })),
          {
            text:
              scope === 'workbook'
                ? buildGojaengiWorkbookPrompt(rawPages)
                : buildProblemBookSectionPrompt(rawPages, series),
          },
        ],
      },
    ],
    generationConfig: {
      temperature: 0,
      responseMimeType: 'application/json',
      maxOutputTokens: 4096,
      thinkingConfig: { thinkingLevel: 'low' },
    },
  };

  const attempts = Math.max(1, Number(maxRetries) || 1);
  let lastErr = null;
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    let res;
    const t0 = Date.now();
    try {
      res = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
        signal: controller.signal,
      });
    } catch (err) {
      lastErr = err;
      if (attempt + 1 < attempts) {
        await sleep(800 * Math.pow(2, attempt));
        continue;
      }
      throw new Error(
        `vlm_rpm_section_fetch_error: ${String(err?.message || err).slice(0, 300)}`,
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
        `vlm_rpm_section_http_${res.status}: ${String(textBody).slice(0, 500)}`,
      );
    }
    let payload;
    try {
      payload = JSON.parse(textBody);
    } catch (_) {
      throw new Error(`vlm_rpm_section_non_json_response: ${textBody.slice(0, 500)}`);
    }
      const candidate = (payload?.candidates || [])[0];
      const modelText = joinGeminiTextParts(candidate?.content?.parts);
    const parsedJson = parseRpmSectionModelJson(modelText);
    if (!parsedJson) {
      throw new Error(
        `vlm_rpm_section_parse_failed: finish=${candidate?.finishReason || '-'} text_head="${modelText.slice(0, 180)}"`,
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
    `vlm_rpm_section_exhausted: lastErr=${String(lastErr?.message || lastErr).slice(0, 300)}`,
  );
}

export function normalizeRpmSectionResult(parsedJson, rawPages, series = 'rpm') {
  const parts = problemBookSectionParts(series);
  const allowed = new Set(parts.map((part) => part.code));
  const inputPages = Array.isArray(rawPages) ? rawPages : [];
  const byIndex = new Map();
  const rows = Array.isArray(parsedJson?.pages) ? parsedJson.pages : [];
  // 쎈/RPM 은 파트별 전용 플래그를 쓰던 옛 스키마를 그대로 받아 준다.
  const legacyFlagKeys = new Map([
    ['type_practice', 'type_practice_header_visible'],
    ['mastery', 'mastery_header_visible'],
  ]);
  const blank = (page, imageIndex) => ({
    image_index: imageIndex,
    raw_page: page,
    section: 'unknown',
    header_visible: false,
    type_practice_header_visible: false,
    mastery_header_visible: false,
  });
  for (const raw of rows) {
    if (!raw || typeof raw !== 'object') continue;
    const imageIndex = Number.parseInt(String(raw.image_index ?? ''), 10);
    if (!Number.isFinite(imageIndex) || imageIndex < 0 || imageIndex >= inputPages.length) {
      continue;
    }
    const sectionRaw = String(raw.section || '').trim();
    const section = allowed.has(sectionRaw) ? sectionRaw : 'unknown';
    const legacyKey = legacyFlagKeys.get(section);
    const headerVisible =
      raw.header_visible === true ||
      (legacyKey != null && raw[legacyKey] === true);
    byIndex.set(imageIndex, {
      image_index: imageIndex,
      raw_page: inputPages[imageIndex],
      section,
      header_visible: headerVisible,
      // 쎈/RPM 앱 쪽이 아직 읽는 파트별 플래그. section 과 header_visible 에서
      // 되짚어 채워 둔다.
      type_practice_header_visible:
        section === 'type_practice' && headerVisible,
      mastery_header_visible: section === 'mastery' && headerVisible,
    });
  }
  return {
    pages: inputPages.map(
      (page, imageIndex) => byIndex.get(imageIndex) || blank(page, imageIndex),
    ),
    notes: String(parsedJson?.notes || '').trim(),
  };
}
