// 쎈/RPM 중단원 본문 페이지 묶음에서 A/B/C 파트 경계를 찾는 경량 Gemini 클라이언트.
//
// 문항 좌표/본문은 추출하지 않고 페이지별 파트와 정확한 상단 헤더 가시성만
// 반환한다. 목차에서 얻은 중단원 시작/끝 범위를 A/B/C 입력칸으로 나눌 때 쓴다.

import { repairLatexBackslashes } from '../problem_bank/extract_engines/vlm/client.js';

const TRANSIENT_STATUSES = new Set([429, 500, 502, 503, 504]);
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

const SECTION_SERIES_CONFIG = Object.freeze({
  ssen: {
    bookName: '쎈',
    partA: '기본다잡기',
    partB: '유형뽀개기',
    partC: '만점도전하기',
    aRule:
      'A에는 개념 설명 페이지가 섞일 수 있다. 문항이 없는 개념 페이지도 A이므로 section="basic_drill"이다.',
    cRule:
      '"서술형", "사고의 기술" 같은 표시는 C 내부 코너이며 별도 파트가 아니다.',
  },
  rpm: {
    bookName: 'RPM',
    partA: '교과서문제 정복하기',
    partB: '유형 익히기',
    partC: '시험에 꼭 나오는 문제',
    aRule:
      '개념 페이지와 "교과서문제 정복하기" 문제 페이지가 1페이지씩 교대로 반복된다. 개념만 있는 페이지도 A이다.',
    cRule:
      '"서술형 주관식", "실력 UP"은 C 내부 코너이며 별도 파트가 아니다.',
  },
});

export function buildProblemBookSectionPrompt(rawPages, series = 'rpm') {
  const seriesKey = String(series || '').trim().toLowerCase();
  const cfg = SECTION_SERIES_CONFIG[seriesKey] || SECTION_SERIES_CONFIG.rpm;
  const pageList = rawPages.map((page, index) => `${index}:${page}`).join(', ');
  return [
    `당신은 한국 수학 교재 ${cfg.bookName}의 본문 페이지들을 순서대로 분류하는 비전 AI다.`,
    `문항이나 좌표를 추출하지 말고, 각 이미지가 ${cfg.bookName}의 어느 파트인지와 정확한 헤더 가시성만 판정하라.`,
    '반드시 JSON만 출력하고 설명·마크다운·코드펜스는 금지한다.',
    '',
    `첨부 이미지 순서(image_index: PDF raw page)는 다음과 같다: ${pageList}`,
    '',
    `=== ${cfg.bookName}의 고정 순서 ===`,
    '한 중단원은 항상 다음 순서로 진행되며 뒤로 되돌아가지 않는다.',
    `1) A basic_drill: "${cfg.partA}" 파트. ${cfg.aRule}`,
    `2) B type_practice: 페이지 상단에 "${cfg.partB}"가 인쇄된 첫 페이지부터 시작한다.`,
    `3) C mastery: 페이지 상단에 "${cfg.partC}"가 인쇄된 첫 페이지부터 시작한다.`,
    `   이후 ${cfg.cRule}`,
    '',
    '=== 헤더 플래그 규칙 ===',
    `- type_practice_header_visible은 해당 이미지 상단에 정확한 문구 "${cfg.partB}"가 실제로 보일 때만 true.`,
    `- mastery_header_visible은 해당 이미지 상단에 정확한 문구 "${cfg.partC}"가 실제로 보일 때만 true.`,
    '- 이전/다음 이미지의 문맥이나 문항 모양만으로 헤더 플래그를 true로 추측하지 마라.',
    '- 헤더가 없는 이어지는 B/C 페이지도 순서와 지면 스타일을 이용해 section은 올바르게 유지하라.',
    '',
    '=== 출력 스키마 ===',
    '{',
    '  "pages": [',
    '    {',
    '      "image_index": <0부터 시작하는 첨부 이미지 순번>,',
    '      "raw_page": <위 목록의 PDF raw page>,',
    '      "section": "basic_drill" | "type_practice" | "mastery" | "unknown",',
    '      "type_practice_header_visible": <bool>,',
    '      "mastery_header_visible": <bool>',
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
          { text: buildProblemBookSectionPrompt(rawPages, series) },
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
    const modelText = (candidate?.content?.parts || [])
      .map((part) => part?.text || '')
      .join('\n')
      .trim();
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

export function normalizeRpmSectionResult(parsedJson, rawPages) {
  const allowed = new Set(['basic_drill', 'type_practice', 'mastery']);
  const inputPages = Array.isArray(rawPages) ? rawPages : [];
  const byIndex = new Map();
  const rows = Array.isArray(parsedJson?.pages) ? parsedJson.pages : [];
  for (const raw of rows) {
    if (!raw || typeof raw !== 'object') continue;
    const imageIndex = Number.parseInt(String(raw.image_index ?? ''), 10);
    if (!Number.isFinite(imageIndex) || imageIndex < 0 || imageIndex >= inputPages.length) {
      continue;
    }
    const sectionRaw = String(raw.section || '').trim();
    byIndex.set(imageIndex, {
      image_index: imageIndex,
      raw_page: inputPages[imageIndex],
      section: allowed.has(sectionRaw) ? sectionRaw : 'unknown',
      type_practice_header_visible:
        raw.type_practice_header_visible === true,
      mastery_header_visible: raw.mastery_header_visible === true,
    });
  }
  return {
    pages: inputPages.map((page, imageIndex) => (
      byIndex.get(imageIndex) || {
        image_index: imageIndex,
        raw_page: page,
        section: 'unknown',
        type_practice_header_visible: false,
        mastery_header_visible: false,
      }
    )),
    notes: String(parsedJson?.notes || '').trim(),
  };
}
