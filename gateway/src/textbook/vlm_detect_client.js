// 교재 페이지 이미지를 Gemini Vision 에 보내 "문항번호 bbox" 를 받아오는 클라이언트.
//
// 기존 `extract_engines/vlm/client.js` 는 PDF inline_data 전용이고 프롬프트도
// 문제은행 전용이라 재사용하지 않고 별도 모듈로 분리했다.
//
// Node >= 18 의 global fetch / AbortController 만 사용한다. 외부 의존성 없음.

import { buildDetectProblemsPrompt } from './vlm_detect_prompt.js';
import { repairLatexBackslashes } from '../problem_bank/extract_engines/vlm/client.js';

export async function detectProblemsOnPage({
  imageBase64,
  mimeType = 'image/png',
  rawPage,
  displayPage,
  pageOffset,
  model,
  apiKey,
  timeoutMs = 90000,
}) {
  const key = String(apiKey || '').trim();
  if (!key) throw new Error('vlm_detect_api_key_missing');
  const img = String(imageBase64 || '').trim();
  if (!img) throw new Error('vlm_detect_image_empty');

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
            text: buildDetectProblemsPrompt({ rawPage, displayPage, pageOffset }),
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
  } finally {
    clearTimeout(timer);
  }
  const elapsedMs = Date.now() - t0;
  const textBody = await res.text();
  if (!res.ok) {
    throw new Error(
      `vlm_detect_http_${res.status}: ${String(textBody).slice(0, 500)}`,
    );
  }
  let payload;
  try {
    payload = JSON.parse(textBody);
  } catch (_) {
    throw new Error(
      `vlm_detect_non_json_response: ${String(textBody).slice(0, 500)}`,
    );
  }
  const candidate = (payload?.candidates || [])[0];
  const modelText = (candidate?.content?.parts || [])
    .map((p) => p?.text || '')
    .join('\n')
    .trim();
  let parsedJson = null;
  try {
    parsedJson = JSON.parse(modelText);
  } catch (_) {
    const repaired = repairLatexBackslashes(modelText);
    try {
      parsedJson = JSON.parse(repaired);
    } catch (_) {
      const m = repaired.match(/\{[\s\S]*\}/);
      if (m) {
        try {
          parsedJson = JSON.parse(m[0]);
        } catch (_) {
          // leave null
        }
      }
    }
  }
  if (!parsedJson) {
    throw new Error(
      `vlm_detect_parse_failed: finish=${candidate?.finishReason || '-'} text_head="${modelText.slice(
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
  };
}

export function normalizeDetectResult(parsedJson) {
  const out = {
    section: 'unknown',
    page_layout: 'unknown',
    items: [],
    notes: '',
  };
  if (!parsedJson || typeof parsedJson !== 'object') return out;

  const section = String(parsedJson.section || '').trim();
  out.section = ['basic_drill', 'type_practice', 'mastery', 'unknown'].includes(
    section,
  )
    ? section
    : 'unknown';

  const layout = String(parsedJson.page_layout || '').trim();
  out.page_layout = ['two_column', 'one_column', 'unknown'].includes(layout)
    ? layout
    : 'unknown';
  out.notes = String(parsedJson.notes || '').trim();

  const rawItems = Array.isArray(parsedJson.items) ? parsedJson.items : [];
  for (const raw of rawItems) {
    if (!raw || typeof raw !== 'object') continue;
    const number = String(raw.number ?? '').trim();
    if (!number) continue;
    const label = String(raw.label ?? '').trim();
    const isSet = Boolean(raw.is_set_header);
    let setRange = null;
    if (raw.set_range && typeof raw.set_range === 'object') {
      const from = Number(raw.set_range.from);
      const to = Number(raw.set_range.to);
      if (Number.isFinite(from) && Number.isFinite(to)) {
        setRange = { from, to };
      }
    }
    const colRaw = raw.column;
    const column =
      colRaw === 1 || colRaw === 2 ? colRaw : colRaw == null ? null : null;
    const bbox = parseBbox4(raw.bbox);
    const itemRegion = parseBbox4(raw.item_region);
    out.items.push({
      number,
      label,
      is_set_header: isSet,
      set_range: setRange,
      column,
      bbox,
      item_region: itemRegion,
    });
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
