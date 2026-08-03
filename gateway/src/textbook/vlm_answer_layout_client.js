// 수력충전 빠른 정답 지면을 "소단원 머리 + 번호/정답" 구조로 읽는다.
//
// 모델은 보이는 요소와 값을 OCR만 한다. 어느 정답이 어느 본문 크롭인지는
// 소단원별 기대 문항 수·번호를 이미 가진 매니저 앱이 결정한다.

import {
  joinGeminiTextParts,
  parseTextbookVlmJson,
} from './vlm_json_parse.js';
import { normalizeAnswerResult } from './vlm_answer_client.js';

const TRANSIENT_STATUSES = new Set([429, 500, 502, 503, 504]);

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function buildAnswerLayoutPrompt({ rawPage }) {
  return [
    '당신은 수력충전 교재의 **빠른 정답 PDF 한 지면**을 구조화하는 비전 AI 입니다.',
    '어느 정답이 어느 본문 문항인지 추론하지 마세요. 보이는 요소를 빠짐없이 OCR만 하세요.',
    '반드시 JSON만 출력하세요.',
    '',
    `이 이미지는 정답 PDF raw page ${rawPage} 이다.`,
    '',
    '=== 소단원 머리 ===',
    '- 연한 하늘색/청록색 띠에 "09 좌표평면 위의 선분의 내분점 ▶p.24~25"처럼',
    '  소단원 번호, 소단원명, 본문 페이지 배지가 함께 적힌 행이다.',
    '- 파란 테두리의 "단원 마무리 평가 [01~32] ▶문제편 p.30~33"도 머리다.',
    '- 지면 첫 단 맨 위가 머리 없이 초록색 문항번호부터 시작하면',
    '  leading_continuation=true다. 앞 지면 소단원이 이어진 것이다.',
    '',
    '=== 정답 항목 ===',
    '[A1] 초록색 두 자리 문항번호 01, 02, 03...을 빠짐없이 읽는다.',
    '[A2] 번호 오른쪽에서 다음 초록색 번호 직전까지가 그 문항의 정답이다.',
    '     (1)(2)(3) 소답이 있으면 한 answer_text에 순서대로 모두 담는다.',
    '[A3] "해설 참조"도 유효한 정답이므로 그대로 담는다.',
    '[A4] 객관식 답 ①~⑤이면 kind="objective", 그 외는 kind="subjective".',
    '     표·격자·그림 자체가 답이면 kind="image", answer_text="[image]".',
    '[A5] 주관식 수식은 LaTeX로 적는다. 분수는 \\\\frac{a}{b}, 근호는 \\\\sqrt{}.',
    '[A6] bbox는 초록색 문항번호와 그 정답 전체를 함께 감싼다.',
    '[A7] 아래 숫자는 문항번호가 아니다: 소단원 번호, 본문 페이지 배지,',
    '     정답 속 숫자, 원문자 ①~⑤, 지면 쪽 번호.',
    '',
    '=== 출력 ===',
    '{',
    '  "leading_continuation": true | false,',
    '  "entries": [',
    '    {',
    '      "kind": "header",',
    '      "title": "<소단원 번호와 이름>",',
    '      "page_start": <본문 배지 시작 쪽>,',
    '      "page_end": <본문 배지 끝 쪽>,',
    '      "bbox": [ymin, xmin, ymax, xmax]',
    '    },',
    '    {',
    '      "kind": "answer",',
    '      "problem_number": "<인쇄된 두 자리 번호>",',
    '      "answer_kind": "objective | subjective | image",',
    '      "answer_text": "<정답>",',
    '      "answer_latex_2d": "<필요하면 LaTeX, 아니면 빈 문자열>",',
    '      "bbox": [ymin, xmin, ymax, xmax]',
    '    }',
    '  ]',
    '}',
    '',
    'entries는 반드시 왼쪽 단 위→아래를 모두 읽은 뒤 다음 단 위→아래 순서다.',
    '좌표는 0..1000 [ymin, xmin, ymax, xmax].',
  ].join('\n');
}

export async function extractAnswerLayoutOnPage({
  imageBase64,
  mimeType = 'image/png',
  rawPage,
  model,
  apiKey,
  timeoutMs = 90000,
  maxRetries = 3,
}) {
  const key = String(apiKey || '').trim();
  if (!key) throw new Error('vlm_answer_layout_api_key_missing');
  const img = String(imageBase64 || '').trim();
  if (!img) throw new Error('vlm_answer_layout_image_empty');
  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/` +
    `${encodeURIComponent(model)}:generateContent?key=${encodeURIComponent(key)}`;
  const body = {
    contents: [{
      role: 'user',
      parts: [
        { inline_data: { mime_type: mimeType, data: img } },
        { text: buildAnswerLayoutPrompt({ rawPage }) },
      ],
    }],
    generationConfig: {
      temperature: 0,
      responseMimeType: 'application/json',
      maxOutputTokens: 32768,
      thinkingConfig: { thinkingLevel: 'medium' },
    },
  };

  const attempts = Math.max(1, Number(maxRetries) || 1);
  let lastError = '';
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
        signal: controller.signal,
      });
      const text = await res.text();
      if (!res.ok) {
        lastError = `http_${res.status}: ${text.slice(0, 300)}`;
        if (TRANSIENT_STATUSES.has(res.status) && attempt + 1 < attempts) {
          await sleep(800 * Math.pow(2, attempt));
          continue;
        }
        throw new Error(lastError);
      }
      const payload = JSON.parse(text);
      const candidate = (payload?.candidates || [])[0];
      const parsedJson = parseTextbookVlmJson(
        joinGeminiTextParts(candidate?.content?.parts),
      );
      if (!parsedJson) throw new Error('vlm_answer_layout_parse_failed');
      return {
        parsedJson,
        usageMetadata: payload?.usageMetadata || null,
        finishReason: candidate?.finishReason || '',
      };
    } catch (err) {
      lastError = String(err?.message || err);
      if (attempt + 1 < attempts) {
        await sleep(800 * Math.pow(2, attempt));
        continue;
      }
    } finally {
      clearTimeout(timer);
    }
  }
  throw new Error(`vlm_answer_layout_failed: ${lastError}`);
}

function parseBbox4(value) {
  if (!Array.isArray(value) || value.length !== 4) return null;
  const nums = value.map(Number);
  if (nums.some((n) => !Number.isFinite(n))) return null;
  const out = nums.map((n) => Math.max(0, Math.min(1000, Math.round(n))));
  if (out[2] <= out[0] || out[3] <= out[1]) return null;
  return out;
}

export function normalizeAnswerLayoutResult(parsedJson) {
  const out = { leading_continuation: false, entries: [] };
  if (!parsedJson || typeof parsedJson !== 'object') return out;
  out.leading_continuation = parsedJson.leading_continuation === true;
  const rawEntries = Array.isArray(parsedJson.entries) ? parsedJson.entries : [];
  for (const raw of rawEntries) {
    if (!raw || typeof raw !== 'object') continue;
    const bbox = parseBbox4(raw.bbox);
    if (String(raw.kind || '').trim() === 'header') {
      const title = String(raw.title || '').trim();
      const start = Number.parseInt(String(raw.page_start ?? ''), 10);
      const end = Number.parseInt(String(raw.page_end ?? ''), 10);
      if (!title && !Number.isFinite(start)) continue;
      out.entries.push({
        kind: 'header',
        title,
        page_start: Number.isFinite(start) && start > 0 ? start : 0,
        page_end: Number.isFinite(end) && end > 0 ? end : 0,
        bbox,
      });
      continue;
    }
    const normalized = normalizeAnswerResult({
      items: [{
        problem_number: raw.problem_number,
        kind: raw.answer_kind,
        answer_text: raw.answer_text,
        answer_latex_2d: raw.answer_latex_2d,
        bbox: raw.bbox,
      }],
    }).items[0];
    if (!normalized?.problem_number || !normalized.answer_text) continue;
    out.entries.push({
      kind: 'answer',
      ...normalized,
      bbox: normalized.bbox || bbox,
    });
  }
  if (!out.entries.some((e) => e.kind === 'header')) {
    out.leading_continuation = true;
  }
  return out;
}
