// 답지 페이지 이미지를 Gemini Vision 에 보내 "문항별 정답" 을 받아오는 클라이언트.
//
// `vlm_detect_client.js` 와 뼈대는 같지만 프롬프트와 결과 정규화 규칙이 다르다.
// Answer 전용이라 섹션/레이아웃 필드 없이 `items[].problem_number/kind/answer_text/...` 만
// 정제해서 돌려준다.

import { buildExtractAnswersPrompt } from './vlm_answer_prompt.js';
import {
  joinGeminiTextParts,
  parseTextbookVlmJson,
} from './vlm_json_parse.js';
import {
  buildExpectedIndex,
  canonicalCorner,
  expandBadgeRange,
  resolveExpectedBox,
} from './vlm_corner_guard.js';
import {
  normalizeProblemNumberKey,
  parseProblemNumberRange,
  parseSingleProblemNumber,
} from './problem_number_key.js';

const ANSWER_TRANSIENT_STATUSES = new Set([429, 500, 502, 503, 504]);
// 한 지면에 블록이 여러 개 쌓이고 블록마다 번호가 1번부터 다시 시작하는 교재.
const ANSWER_DENSE_SERIES = new Set(['gaeyu', 'suryeok']);
const ANSWER_DEFAULT_MAX_RETRIES = 3;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isDailyQuotaExceededBody(input) {
  const text = String(input || '').toLowerCase();
  return (
    text.includes('resource_exhausted') &&
    (text.includes('generate_requests_per_model_per_day') ||
      text.includes('please retry in'))
  );
}

export async function extractAnswersOnPage({
  imageBase64,
  mimeType = 'image/png',
  rawPage,
  displayPage,
  pageOffset,
  expectedNumbers,
  expectedEntries,
  skipBadges,
  series,
  model,
  apiKey,
  timeoutMs = 90000,
  maxRetries = ANSWER_DEFAULT_MAX_RETRIES,
}) {
  const key = String(apiKey || '').trim();
  if (!key) throw new Error('vlm_answer_api_key_missing');
  const img = String(imageBase64 || '').trim();
  if (!img) throw new Error('vlm_answer_image_empty');

  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/` +
    `${encodeURIComponent(model)}:generateContent?key=` +
    `${encodeURIComponent(key)}`;

  const body = {
    contents: [
      {
        role: 'user',
        parts: [
          {
            inline_data: {
              mime_type: mimeType,
              data: img,
            },
          },
          {
            text: buildExtractAnswersPrompt({
              rawPage,
              displayPage,
              pageOffset,
              expectedNumbers,
              expectedEntries,
              skipBadges,
              series,
            }),
          },
        ],
      },
    ],
    generationConfig: {
      temperature: 0.1,
      responseMimeType: 'application/json',
      maxOutputTokens: 32768,
      // 개념+유형 답지는 한 지면에 코너별 박스가 6~10개 쌓이고, 각 박스 안에서
      // 필수 문제와 따름 문제가 다시 갈린다. thinkingLevel=low 로는 박스 하나당
      // 첫 문항만 뽑고 멈추는 누락이 재현된다. 수력충전도 소단원 블록이 여럿에
      // 블록당 20~30문항이 이어져 같은 누락이 난다. 두 시리즈만 예산을 올린다.
      thinkingConfig: {
        thinkingLevel: ANSWER_DENSE_SERIES.has(
          String(series || '').trim().toLowerCase(),
        )
          ? 'medium'
          : 'low',
      },
    },
  };

  let lastStatus = 0;
  let lastBody = '';
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
        `vlm_answer_fetch_error: ${compactErrMsg(err)} (attempts=${attempt + 1})`,
      );
    } finally {
      clearTimeout(timer);
    }
    const elapsedMs = Date.now() - t0;
    const textBody = await res.text();
    if (!res.ok) {
      lastStatus = res.status;
      lastBody = textBody;
      if (
        ANSWER_TRANSIENT_STATUSES.has(res.status) &&
        !isDailyQuotaExceededBody(textBody) &&
        attempt + 1 < attempts
      ) {
        await sleep(800 * Math.pow(2, attempt));
        continue;
      }
      throw new Error(
        `vlm_answer_http_${res.status}: ${String(textBody).slice(0, 500)} (attempts=${attempt + 1})`,
      );
    }
    let payload;
    try {
      payload = JSON.parse(textBody);
    } catch (_) {
      throw new Error(
        `vlm_answer_non_json_response: ${String(textBody).slice(0, 500)}`,
      );
    }
    const candidate = (payload?.candidates || [])[0];
    const modelText = joinGeminiTextParts(candidate?.content?.parts);
    const parsedJson = parseTextbookVlmJson(modelText);
    if (!parsedJson) {
      throw new Error(
        `vlm_answer_parse_failed: finish=${candidate?.finishReason || '-'} text_head="${modelText.slice(
          0,
          180,
        )}"`,
      );
    }
    return {
      rawPayload: payload,
      parsedJson,
      elapsedMs,
      usageMetadata: payload?.usageMetadata || null,
      finishReason: candidate?.finishReason || '',
      attempts: attempt + 1,
    };
  }
  throw new Error(
    `vlm_answer_exhausted: status=${lastStatus} lastErr=${compactErrMsg(lastErr)} body=${String(
      lastBody,
    ).slice(0, 300)}`,
  );
}

function compactErrMsg(err) {
  if (!err) return '';
  const name = err?.name ? `${err.name}: ` : '';
  return `${name}${String(err?.message || err).slice(0, 300)}`;
}

const ALLOWED_KINDS = new Set(['objective', 'subjective', 'image']);
const OBJECTIVE_CHOICE_MAP = new Map([
  ['1', '①'],
  ['①', '①'],
  ['⑴', '①'],
  ['(1)', '①'],
  ['2', '②'],
  ['②', '②'],
  ['⑵', '②'],
  ['(2)', '②'],
  ['3', '③'],
  ['③', '③'],
  ['⑶', '③'],
  ['(3)', '③'],
  ['4', '④'],
  ['④', '④'],
  ['⑷', '④'],
  ['(4)', '④'],
  ['5', '⑤'],
  ['⑤', '⑤'],
  ['⑸', '⑤'],
  ['(5)', '⑤'],
]);

function normalizeCompactFractionCommands(input) {
  let out = String(input || '');
  for (let i = 0; i < 4; i += 1) {
    const next = out
      .replace(
        /\\(?:dfrac|tfrac|frac)\s*\{([^{}]+)\}\s*\{([^{}]+)\}/g,
        (_, a, b) => `\\frac{${String(a).trim()}}{${String(b).trim()}}`,
      )
      .replace(
        /\\(?:dfrac|tfrac|frac)\s*\{([^{}]+)\}\s*([A-Za-z0-9])/g,
        (_, a, b) => `\\frac{${String(a).trim()}}{${b}}`,
      )
      .replace(
        /\\(?:dfrac|tfrac|frac)\s*([A-Za-z0-9])\s*\{([^{}]+)\}/g,
        (_, a, b) => `\\frac{${a}}{${String(b).trim()}}`,
      )
      .replace(
        /\\(?:dfrac|tfrac|frac)\s*([A-Za-z0-9])\s*([A-Za-z0-9])/g,
        (_, a, b) => `\\frac{${a}}{${b}}`,
      );
    if (next === out) break;
    out = next;
  }
  return out;
}

function stripLatexTextWrappers(input) {
  let out = String(input || '');
  for (let i = 0; i < 6; i += 1) {
    const next = out
      .replace(/\\(?:text|mathrm)\s*\{([^{}]*)\}/g, '$1')
      .replace(/\\textstyle\b/g, '')
      .replace(/\\displaystyle\b/g, '');
    if (next === out) break;
    out = next;
  }
  return out;
}

function normalizeAnswerText(input) {
  return normalizeCompactFractionCommands(stripLatexTextWrappers(input))
    .replace(/\(\s*image\s*\)/gi, '[image]')
    .replace(/\[\s*image\s*\]/gi, '[image]')
    .replace(/\s+/g, ' ')
    .trim();
}

function normalizeAnswerAssets(rawAssets) {
  if (!Array.isArray(rawAssets)) return [];
  return rawAssets
    .map((asset) => {
      const bbox = parseBbox4(asset?.bbox);
      if (!bbox) return null;
      const assetTypeRaw = String(asset?.asset_type || 'image').trim().toLowerCase();
      const assetType = ['image', 'table', 'grid', 'graph'].includes(assetTypeRaw)
        ? assetTypeRaw
        : 'image';
      return {
        marker: String(asset?.marker || '[image]').trim() || '[image]',
        asset_type: assetType,
        bbox,
      };
    })
    .filter(Boolean);
}

function normalizeObjectiveChoiceText(input) {
  const raw = String(input || '').trim();
  if (!raw) return '';
  const parts = raw
    .split(/[\/,，、\s]+/)
    .map((part) => part.trim())
    .filter(Boolean);
  if (parts.length === 0) return '';
  const normalized = [];
  for (const part of parts) {
    const compact = part.replace(/\s+/g, '');
    const mapped = OBJECTIVE_CHOICE_MAP.get(compact);
    if (!mapped) return '';
    normalized.push(mapped);
  }
  return Array.from(new Set(normalized)).join(', ');
}

export function normalizeAnswerResult(parsedJson, opts = {}) {
  const out = { items: [], notes: '' };
  if (!parsedJson || typeof parsedJson !== 'object') return out;
  out.notes = String(parsedJson.notes || '').trim();
  const expectedNumbers = Array.isArray(opts?.expectedNumbers)
    ? opts.expectedNumbers.map((n) => String(n || '').trim()).filter(Boolean)
    : [];
  const expectedIndex = buildExpectedIndex(
    opts?.expectedEntries,
    normalizeProblemNumberKey,
  );
  const rawItems = Array.isArray(parsedJson.items) ? parsedJson.items : [];
  const seen = new Set();
  for (const raw of rawItems) {
    if (!raw || typeof raw !== 'object') continue;
    let problemNumber = String(raw.problem_number ?? '').trim();
    if (!problemNumber) continue;
    const resolved = resolveExpectedBox(
      raw,
      problemNumber,
      expectedIndex,
      normalizeProblemNumberKey,
    );
    if (resolved.reject) continue;
    const badgeCorner = canonicalCorner(raw.source_corner ?? raw.sourceCorner);
    const kindRaw = String(raw.kind ?? '').trim().toLowerCase();
    let rawAnswerText = normalizeAnswerText(raw.answer_text);
    const subNumberMatch = problemNumber.match(/^(\d{1,5})\s*(\([0-9]+\))$/);
    if (subNumberMatch) {
      problemNumber = subNumberMatch[1];
      if (!rawAnswerText.startsWith(subNumberMatch[2])) {
        rawAnswerText = `${subNumberMatch[2]} ${rawAnswerText}`.trim();
      }
    }
    const rawAnswerLatex2d = normalizeAnswerText(raw.answer_latex_2d);
    const answerAssets = normalizeAnswerAssets(raw.answer_assets);
    const generatedTableAnswer = /\\begin\{tabular\}|\\hline|\[표시작\]|\[표\]/i.test(
      `${rawAnswerText} ${rawAnswerLatex2d}`,
    );
    const imageMarker = /(?:\[\s*image\s*\]|\(\s*image\s*\)|\bimage\b)/i.test(
      `${rawAnswerText} ${rawAnswerLatex2d}`,
    );
    const objectiveText = normalizeObjectiveChoiceText(rawAnswerText);
    const kind = kindRaw === 'image' || imageMarker || answerAssets.length > 0 || generatedTableAnswer
      ? 'image'
      : kindRaw === 'objective' && !objectiveText
        ? 'subjective'
      : ALLOWED_KINDS.has(kindRaw)
        ? kindRaw
        : 'subjective';
    const answerText =
      kind === 'image'
        ? (imageMarker ? rawAnswerText : `${rawAnswerText} [image]`.trim()) || '[image]'
        : kind === 'objective'
          ? objectiveText
        : rawAnswerText || rawAnswerLatex2d;
    const answerLatex2d = rawAnswerLatex2d;
    const bbox = parseBbox4(raw.bbox) || answerAssets[0]?.bbox || null;
    const base = {
      problem_number: problemNumber,
      kind,
      answer_text: answerText,
      answer_latex_2d: answerLatex2d,
      bbox,
      answer_assets: answerAssets,
    };
    if (resolved.matched) {
      // 앱은 번호가 아니라 이 위치로 크롭을 찾는다. 같은 번호가 여러 코너에
      // 있어도 서로 덮어쓰지 않는 유일한 방법이다.
      base.expected_index = resolved.matched.index;
      base.problem_number = resolved.matched.number;
    }
    pushUniqueAnswerItem(out.items, seen, base, badgeCorner);
    for (const expanded of expandAnswerRange(
      problemNumber,
      expectedNumbers,
      expectedIndex,
      raw,
    )) {
      pushUniqueAnswerItem(
        out.items,
        seen,
        {
          ...base,
          problem_number: expanded.number,
          ...(expanded.index >= 0 ? { expected_index: expanded.index } : {}),
        },
        badgeCorner,
      );
    }
  }
  return out;
}

function pushUniqueAnswerItem(items, seen, item, badgeCorner = '') {
  const key = answerDedupKey(item, badgeCorner);
  if (!key || seen.has(key)) return;
  seen.add(key);
  items.push(item);
}

/// 한 지면 응답 안에서 중복을 걸러낼 키.
///
/// 번호만 쓰면 같은 쪽에 나란히 인쇄된 "필수 문제 1" 과 "쏙쏙 1" 중 하나가
/// 통째로 버려진다. 기대 항목이 특정됐으면 그 위치가 가장 정확한 키이고,
/// 아니면 코너를 함께 묶는다.
function answerDedupKey(item, badgeCorner) {
  if (Number.isInteger(item.expected_index) && item.expected_index >= 0) {
    return `#${item.expected_index}`;
  }
  const numberKey = normalizeProblemNumberKey(item.problem_number);
  if (!numberKey) return '';
  return badgeCorner ? `${numberKey}|${badgeCorner}` : numberKey;
}

function expandAnswerRange(problemNumber, expectedNumbers, expectedIndex, raw) {
  const range = parseProblemNumberRange(problemNumber);
  if (!range) return [];
  if (expectedIndex && expectedIndex.all.length > 0) {
    return expandBadgeRange(range, expectedIndex, raw).map((candidate) => ({
      number: candidate.number,
      index: candidate.index,
    }));
  }
  if (expectedNumbers.length === 0) return [];
  const out = [];
  for (const expected of expectedNumbers) {
    const n = parseSingleProblemNumber(expected);
    if (n == null || n < range.from || n > range.to) continue;
    out.push({ number: expected, index: -1 });
  }
  return out;
}

function parseBbox4(arr) {
  if (!Array.isArray(arr) || arr.length !== 4) return null;
  const [ymin, xmin, ymax, xmax] = arr.map((v) => Number(v));
  if (![ymin, xmin, ymax, xmax].every((v) => Number.isFinite(v))) return null;
  return [clamp01k(ymin), clamp01k(xmin), clamp01k(ymax), clamp01k(xmax)];
}

function clamp01k(v) {
  if (!Number.isFinite(v)) return 0;
  if (v < 0) return 0;
  if (v > 1000) return 1000;
  return Math.round(v);
}
