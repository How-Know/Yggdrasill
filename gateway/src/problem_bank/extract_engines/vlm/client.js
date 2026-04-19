// VLM(PDF) 추출 엔진의 Gemini 호출 클라이언트.
//
// scripts/vlm_extract_experiment.mjs 의 callGeminiWithPdf / repairLatexBackslashes 를
// 운영 워커에서 import 가능한 ESM 모듈로 분리한 것.
// 외부 의존성은 없고 global fetch / AbortController 만 사용한다 (Node >= 18).

import { buildPrompt } from './prompt.js';

// JSON 문자열 리터럴 안에서 "\X (X 가 허용 escape 아님)" 을 "\\X" 로 바꿔 파싱 가능하게 만든다.
// 허용 escape: \" \\ \/ \b \f \n \r \t \uXXXX.
// 문자열 리터럴 밖은 건드리지 않는다 ("스캔 상태머신" 이 필요함).
export function repairLatexBackslashes(input) {
  if (typeof input !== 'string' || !input) return input;
  const out = [];
  let inString = false;
  let escapeNext = false;
  for (let i = 0; i < input.length; i += 1) {
    const ch = input[i];
    if (!inString) {
      out.push(ch);
      if (ch === '"') {
        inString = true;
        escapeNext = false;
      }
      continue;
    }
    if (escapeNext) {
      out.push(ch);
      escapeNext = false;
      continue;
    }
    if (ch === '\\') {
      const nx = input[i + 1];
      const valid = nx && /["\\/bfnrtu]/.test(nx);
      if (valid) {
        out.push(ch);
        escapeNext = true;
      } else {
        out.push('\\', '\\');
      }
      continue;
    }
    if (ch === '"') {
      out.push(ch);
      inString = false;
      continue;
    }
    out.push(ch);
  }
  return out.join('');
}

export async function callGeminiWithPdf({
  pdfBuffer,
  model,
  apiKey,
  timeoutMs = 180000,
}) {
  const key = String(apiKey || '').trim();
  if (!key) throw new Error('vlm_gemini_api_key_missing');
  if (!Buffer.isBuffer(pdfBuffer) || pdfBuffer.length === 0) {
    throw new Error('vlm_pdf_buffer_empty');
  }
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
              mime_type: 'application/pdf',
              data: pdfBuffer.toString('base64'),
            },
          },
          { text: buildPrompt() },
        ],
      },
    ],
    generationConfig: {
      temperature: 0.1,
      responseMimeType: 'application/json',
      maxOutputTokens: 32768,
      thinkingConfig: {
        thinkingLevel: 'low',
      },
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
      `vlm_gemini_http_${res.status}: ${String(textBody).slice(0, 500)}`,
    );
  }
  let payload;
  try {
    payload = JSON.parse(textBody);
  } catch (_) {
    throw new Error(
      `vlm_gemini_non_json_response: ${String(textBody).slice(0, 500)}`,
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
    // Gemini 가 LaTeX 백슬래시를 JSON 이스케이프 없이 내보내는 경우 한 번 더 복구.
    const repaired = repairLatexBackslashes(modelText);
    try {
      parsedJson = JSON.parse(repaired);
    } catch (_) {
      const m = repaired.match(/\{[\s\S]*\}/);
      if (m) {
        try {
          parsedJson = JSON.parse(m[0]);
        } catch (_) {
          // swallow — parsedJson null 로 남아 상위에서 실패 처리.
        }
      }
    }
  }
  if (!parsedJson) {
    throw new Error(
      `vlm_gemini_parse_failed: finish=${candidate?.finishReason || '-'} text_head="${modelText.slice(
        0,
        180,
      )}"`,
    );
  }
  return {
    rawPayload: payload,
    modelText,
    parsedJson,
    elapsedMs,
    usageMetadata: payload?.usageMetadata || null,
    finishReason: candidate?.finishReason || '',
  };
}
