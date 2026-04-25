// 해설 PDF 페이지 이미지를 Gemini Vision 에 보내 "문항번호 bbox" 를 받아오는 클라이언트.
// `vlm_detect_client.js` 와 뼈대는 같지만, 프롬프트와 결과 정규화 규칙이 다르다.

import { buildDetectSolutionRefsPrompt } from './vlm_solution_refs_prompt.js';
import { repairLatexBackslashes } from '../problem_bank/extract_engines/vlm/client.js';

export async function detectSolutionRefsOnPage({
  imageBase64,
  mimeType = 'image/png',
  rawPage,
  displayPage,
  pageOffset,
  expectedNumbers,
  model,
  apiKey,
  timeoutMs = 90000,
}) {
  const key = String(apiKey || '').trim();
  if (!key) throw new Error('vlm_solref_api_key_missing');
  const img = String(imageBase64 || '').trim();
  if (!img) throw new Error('vlm_solref_image_empty');

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
            inline_data: { mime_type: mimeType, data: img },
          },
          {
            text: buildDetectSolutionRefsPrompt({
              rawPage,
              displayPage,
              pageOffset,
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
      `vlm_solref_http_${res.status}: ${String(textBody).slice(0, 500)}`,
    );
  }
  let payload;
  try {
    payload = JSON.parse(textBody);
  } catch (_) {
    throw new Error(
      `vlm_solref_non_json_response: ${String(textBody).slice(0, 500)}`,
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
      `vlm_solref_parse_failed: finish=${candidate?.finishReason || '-'} text_head="${modelText.slice(
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

export function normalizeSolutionRefsResult(parsedJson) {
  const out = { items: [], notes: '' };
  if (!parsedJson || typeof parsedJson !== 'object') return out;
  out.notes = String(parsedJson.notes || '').trim();
  const rawItems = Array.isArray(parsedJson.items) ? parsedJson.items : [];
  for (const raw of rawItems) {
    if (!raw || typeof raw !== 'object') continue;
    const problemNumber = String(raw.problem_number ?? '').trim();
    if (!problemNumber) continue;
    const numberRegion = parseBbox4(raw.number_region);
    if (!numberRegion) continue;
    const contentRegion = parseBbox4(raw.content_region);
    out.items.push({
      problem_number: problemNumber,
      number_region: numberRegion,
      content_region: contentRegion,
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
