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

const ANSWER_TRANSIENT_STATUSES = new Set([429, 500, 502, 503, 504]);
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
      // 첫 문항만 뽑고 멈추는 누락이 재현된다. 이 시리즈만 사고 예산을 올린다.
      thinkingConfig: {
        thinkingLevel:
          String(series || '').trim().toLowerCase() === 'gaeyu'
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
  const rawItems = Array.isArray(parsedJson.items) ? parsedJson.items : [];
  const seen = new Set();
  for (const raw of rawItems) {
    if (!raw || typeof raw !== 'object') continue;
    let problemNumber = String(raw.problem_number ?? '').trim();
    if (!problemNumber) continue;
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
    pushUniqueAnswerItem(out.items, seen, base);
    for (const expanded of expandAnswerRange(problemNumber, expectedNumbers)) {
      pushUniqueAnswerItem(out.items, seen, {
        ...base,
        problem_number: expanded,
      });
    }
  }
  return out;
}

function pushUniqueAnswerItem(items, seen, item) {
  const key = normalizeProblemNumberKey(item.problem_number);
  if (!key || seen.has(key)) return;
  seen.add(key);
  items.push(item);
}

function expandAnswerRange(problemNumber, expectedNumbers) {
  const range = parseProblemNumberRange(problemNumber);
  if (!range || expectedNumbers.length === 0) return [];
  const out = [];
  for (const expected of expectedNumbers) {
    const n = parseSingleProblemNumber(expected);
    if (n == null || n < range.from || n > range.to) continue;
    out.push(expected);
  }
  return out;
}

function parseProblemNumberRange(input) {
  const match = String(input || '')
    .trim()
    .match(/^0*(\d+)\s*[~\-\u2013\u2014\u301c]\s*0*(\d+)$/);
  if (!match) return null;
  const from = Number(match[1]);
  const to = Number(match[2]);
  if (!Number.isFinite(from) || !Number.isFinite(to) || from > to) return null;
  return { from, to };
}

function parseSingleProblemNumber(input) {
  const text = String(input || '').trim();
  if (!/^\d+$/.test(text)) return null;
  const n = Number(text);
  return Number.isFinite(n) ? n : null;
}

function normalizeProblemNumberKey(input) {
  const text = String(input || '').trim();
  if (!text) return '';
  const range = parseProblemNumberRange(text);
  if (range) return `${range.from}-${range.to}`;
  const compact = text.replace(/\s+/g, '');
  // "2-1"(따름 문제), "109-2"(블록 접두어), "개념확인105", "예제1" 처럼 숫자
  // 앞뒤에 의미 있는 조각이 붙는 번호는 통째로 키에 남긴다. 첫 숫자만 남기면
  // "2-1"→"2", "109-1"/"109-2"→"109" 이 돼서 서로 다른 문항이 같은 키가 되고,
  // 중복 제거 단계에서 뒤에 온 정답이 통째로 버려진다.
  if (
    /^\d+(?:[-\u2013\u2014~]\d+)+$/.test(compact) ||
    /^[가-힣]+\d/.test(compact)
  ) {
    return compact
      .replace(/[\u2013\u2014~]/g, '-')
      .replace(/\d+/g, (digits) => String(Number(digits)));
  }
  const match = compact.match(/\d+/);
  if (!match) return compact;
  const n = Number(match[0]);
  return Number.isFinite(n) ? `${n}` : compact;
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
