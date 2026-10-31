// 지면 이미지 한 장을 Gemini 에 보내 JSON 을 받는다.

import { joinGeminiTextParts, parseTextbookVlmJson } from '../textbook/vlm_json_parse.js';

const TRANSIENT_STATUSES = new Set([429, 499, 500, 502, 503, 504]);

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isDailyQuotaExceeded(body) {
  const text = String(body || '').toLowerCase();
  return (
    text.includes('resource_exhausted') &&
    (text.includes('per_model_per_day') || text.includes('please retry in'))
  );
}

export async function callGeminiImageJson({
  imageBuffer,
  prompt,
  model,
  apiKey,
  timeoutMs = 120000,
  maxRetries = 3,
  thinkingLevel = 'low',
}) {
  const key = String(apiKey || '').trim();
  if (!key) throw new Error('mock_vlm_api_key_missing');
  if (!Buffer.isBuffer(imageBuffer) || imageBuffer.length === 0) {
    throw new Error('mock_vlm_image_empty');
  }
  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/` +
    `${encodeURIComponent(model)}:generateContent?key=${encodeURIComponent(key)}`;
  const body = {
    contents: [
      {
        role: 'user',
        parts: [
          {
            inline_data: {
              mime_type: 'image/png',
              data: imageBuffer.toString('base64'),
            },
          },
          { text: prompt },
        ],
      },
    ],
    generationConfig: {
      temperature: 0.1,
      responseMimeType: 'application/json',
      maxOutputTokens: 16384,
      thinkingConfig: { thinkingLevel },
    },
  };

  let lastError = '';
  for (let attempt = 0; attempt < Math.max(1, maxRetries); attempt += 1) {
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
      lastError = String(err?.message || err);
      if (attempt + 1 < maxRetries) {
        await sleep(1000 * 2 ** attempt);
        continue;
      }
      throw new Error(`mock_vlm_fetch_error:${lastError.slice(0, 300)}`);
    }
    clearTimeout(timer);
    const text = await res.text();
    if (!res.ok) {
      lastError = `http_${res.status}:${text.slice(0, 300)}`;
      if (
        TRANSIENT_STATUSES.has(res.status) &&
        !isDailyQuotaExceeded(text) &&
        attempt + 1 < maxRetries
      ) {
        await sleep(1000 * 2 ** attempt);
        continue;
      }
      throw new Error(`mock_vlm_${lastError}`);
    }
    let payload;
    try {
      payload = JSON.parse(text);
    } catch (_) {
      throw new Error(`mock_vlm_non_json:${text.slice(0, 300)}`);
    }
    const candidate = (payload?.candidates || [])[0];
    const modelText = joinGeminiTextParts(candidate?.content?.parts);
    const parsedJson = parseTextbookVlmJson(modelText);
    if (!parsedJson) {
      lastError = `parse_failed:finish=${candidate?.finishReason || '-'}`;
      if (attempt + 1 < maxRetries) continue;
      throw new Error(`mock_vlm_${lastError}`);
    }
    return {
      parsedJson,
      usageMetadata: payload?.usageMetadata || null,
      elapsedMs: Date.now() - t0,
    };
  }
  throw new Error(`mock_vlm_exhausted:${lastError}`);
}
