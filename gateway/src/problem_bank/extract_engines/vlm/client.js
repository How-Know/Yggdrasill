// VLM(PDF) 추출 엔진의 Gemini 호출 클라이언트.
//
// scripts/vlm_extract_experiment.mjs 의 callGeminiWithPdf / repairLatexBackslashes 를
// 운영 워커에서 import 가능한 ESM 모듈로 분리한 것.
// 외부 의존성은 없고 global fetch / AbortController 만 사용한다 (Node >= 18).

import { buildPrompt } from './prompt.js';

// JSON.parse 가 성공한 후의 "은닉 에러" 를 복구한다.
//
// Gemini 는 프롬프트에서 "\\frac 처럼 두 번 백슬래시를 쓰라" 고 지시해도,
// 가끔 "\frac" 처럼 한 번만 써서 내보낸다. 이 경우:
//   - JSON 파싱은 성공한다 (JSON 스펙상 \f, \b, \t, \v 는 "유효한" escape)
//   - 결과 문자열에는 form feed (\x0c) / backspace (\x08) / vt (\x0b) / tab (\x09)
//     등 제어 문자가 박혀 있다
//   - 이게 그대로 LaTeX 로 흘러가 "^^L rac{2}{3}" 같은 출력을 만들고 컴파일 실패.
//
// 운영 관측된 사례:
//   "$\displaystyle rac{2}{3}x^2y \div ^^L rac{1}{9}xy^2"
//   → Gemini 가 `\frac{...}` 을 그대로 내보냄 → JSON.parse 가 `\x0c + rac{...}` 로 복원.
//
// 정책:
//   - \x0c (FF)  → "\f" 로 복원 (LaTeX 에서 form feed 는 거의 안 쓰이고 \frac 가 훨씬 흔함)
//   - \x08 (BS)  → "\b" 로 복원 (LaTeX \bullet, \beta, \bigcup 등)
//   - \x0b (VT)  → "\v" 로 복원 (LaTeX \vec, \varphi 등)
//   - \x09 (TAB) → "뒤에 알파벳이 있을 때만" "\t" 로 복원 (LaTeX \text, \times, \theta, \tan)
//                  단순 tab (예: tabular 사이 공백) 은 건드리지 않는다.
//   - \x0d (CR) / \x0a (LF) → "뒤에 LaTeX 명령 이름 패턴(소문자 영문자들 + `\`/`{`/`^`/`_`)"
//                  이 올 때만 "\r" / "\n" 으로 복원. 운영 관측 사례:
//                  "\right\}" → JSON.parse → "\x0dight\}" → "l.120 ight\}$" 컴파일 실패.
//                  자연 줄바꿈("line1\nline2", "첫줄\n둘째줄") 은 뒤에 `{`/`\`/`^`/`_` 가
//                  거의 오지 않으므로 오탐 위험이 낮다.
//                  대상 명령 예시:
//                    \r → \right \rho \rightarrow \rm \ref
//                    \n → \neq \not \newline \nabla \ne
export function recoverMangledLatexControls(value) {
  if (typeof value === 'string') {
    let s = value;
    // 무조건 복원: FF / BS / VT (합법 LaTeX 본문에는 등장하지 않는 제어문자)
    s = s.replace(/\x0c/g, '\\f');
    s = s.replace(/\x08/g, '\\b');
    s = s.replace(/\x0b/g, '\\v');
    // 조건부 복원: TAB 은 "뒤에 알파벳" 인 경우에만 LaTeX 명령으로 간주
    s = s.replace(/\x09(?=[A-Za-z])/g, '\\t');
    // 조건부 복원: CR / LF 는 "뒤에 LaTeX 명령 이름 + special char" 패턴일 때만.
    //   terminator 는 LaTeX 명령 뒤에 자주 오는 문자들 전부 커버해야 한다:
    //     \    다음 명령 시작  (\right\} \not\in)
    //     {}   인자/괄호       (\rho{x} \right\})
    //     ()   수식 괄호       (\right) \left(x\right))
    //     []   선택적/수식     (\right] \left[)
    //     ^_   첨자            (\nabla^2 \alpha_1)
    //   운영에서 "l.119 ight)\right\}$" 처럼 ")" terminator 를 놓쳐 재발한 적 있음.
    s = s.replace(/\x0d(?=[a-z][a-zA-Z]*[\\{}()\[\]^_])/g, '\\r');
    s = s.replace(/\x0a(?=[a-z][a-zA-Z]*[\\{}()\[\]^_])/g, '\\n');
    return s;
  }
  if (Array.isArray(value)) return value.map(recoverMangledLatexControls);
  if (value && typeof value === 'object') {
    const out = {};
    for (const k of Object.keys(value)) {
      out[k] = recoverMangledLatexControls(value[k]);
    }
    return out;
  }
  return value;
}

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
    // Gemini can occasionally emit literal control characters inside a JSON
    // string even when responseMimeType is application/json. Raw LF/CR/TAB (and
    // other < 0x20 controls) are invalid in JSON string literals, so escape
    // them while preserving normal pretty-print whitespace outside strings.
    if (ch === '\n') {
      out.push('\\', 'n');
      continue;
    }
    if (ch === '\r') {
      out.push('\\', 'r');
      continue;
    }
    if (ch === '\t') {
      out.push('\\', 't');
      continue;
    }
    const code = ch.charCodeAt(0);
    if (code >= 0 && code < 0x20) {
      out.push(`\\u${code.toString(16).padStart(4, '0')}`);
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

// Gemini 가 responseMimeType=application/json 이어도 가끔 "마지막 닫는 괄호" 를 누락한 채
// finishReason=STOP 으로 응답을 종료한다 (토큰 절단 아님, 실제 관측된 quirk).
//   예) "{ ...document_meta..., "questions": [ {..}, {..} ]"  ← 루트 객체의 마지막 '}' 누락.
// 이 경우 JSON.parse / repairLatexBackslashes / "{...}" 그리디 매칭이 모두 실패한다.
//
// closeTruncatedJson 은 문자열 리터럴을 인식하며 열린 '{' / '[' 스택을 추적해,
//   - 정상 종료(문자열 밖) + 스택 잔여 → 뒤에 닫는 괄호를 붙여 복구 (데이터 보존 우선)
//   - 문자열 중간/토큰 중간 절단 → "마지막으로 온전히 닫힌 경계" 로 되감고 닫는 괄호를 붙여 복구
// 두 후보를 순서대로 JSON.parse 로 검증해 성공하는 첫 결과를 반환한다. 모두 실패하면 null.
export function closeTruncatedJson(input) {
  if (typeof input !== 'string' || !input) return null;
  let inStr = false;
  let esc = false;
  const stack = []; // 열린 컨테이너의 "닫는 문자" 를 순서대로 보관
  let safeCut = -1; // 여기서 자르고 닫으면 구조적으로 유효해지는 위치(배타적)
  let safeStack = null;
  const markSafe = (idxExclusive) => {
    safeCut = idxExclusive;
    safeStack = stack.slice();
  };
  for (let i = 0; i < input.length; i += 1) {
    const ch = input[i];
    if (inStr) {
      if (esc) {
        esc = false;
        continue;
      }
      if (ch === '\\') {
        esc = true;
        continue;
      }
      if (ch === '"') {
        inStr = false;
      }
      continue;
    }
    if (ch === '"') {
      inStr = true;
      continue;
    }
    if (ch === '{') {
      stack.push('}');
      continue;
    }
    if (ch === '[') {
      stack.push(']');
      continue;
    }
    if (ch === '}' || ch === ']') {
      stack.pop();
      markSafe(i + 1); // 컨테이너 닫힘 뒤는 "요소 사이" 안전 경계
      continue;
    }
    if (ch === ',') {
      markSafe(i); // 쉼표 "앞" 까지가 안전 (불완전한 다음 요소는 버림)
      continue;
    }
  }

  const candidates = [];
  // 후보 1: 문자열 밖에서 정상 종료 + 스택 잔여 → 전체를 살리고 닫는 괄호만 보정.
  if (!inStr && stack.length > 0) {
    let s = input.replace(/[\s,]+$/, '');
    for (let k = stack.length - 1; k >= 0; k -= 1) s += stack[k];
    candidates.push(s);
  }
  // 후보 2: 마지막 안전 경계로 되감고 그 시점 스택으로 닫기 (문자열/토큰 중간 절단 대응).
  if (safeCut > 0 && Array.isArray(safeStack) && safeStack.length > 0) {
    let s = input.slice(0, safeCut).replace(/[\s,]+$/, '');
    for (let k = safeStack.length - 1; k >= 0; k -= 1) s += safeStack[k];
    candidates.push(s);
  }
  for (const c of candidates) {
    try {
      return JSON.parse(c);
    } catch (_) {
      // 다음 후보 시도
    }
  }
  return null;
}

export async function callGeminiWithPdf({
  pdfBuffer,
  model,
  apiKey,
  timeoutMs = 180000,
  textbookScope = null,
  expectedQuestionNumbers = null,
  expectedIndependentSetRanges = null,
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
          {
            text: buildPrompt({
              textbookScope,
              expectedQuestionNumbers,
              expectedIndependentSetRanges,
            }),
          },
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
          // 다음 단계(닫는 괄호 보정)로.
        }
      }
      // 마지막 단계: 모델이 닫는 괄호를 누락/절단한 경우 스택 기반으로 복구.
      if (!parsedJson) {
        parsedJson =
          closeTruncatedJson(repaired) || closeTruncatedJson(modelText);
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
  // Gemini 가 "\\frac" 대신 "\frac" 로 단일 escape 를 내보내면 JSON.parse 가 "유효한"
  //   \f (form feed) 로 해석해 버려 파싱은 성공하지만 문자열 안에 제어 문자가 박힌다.
  //   LaTeX 로 그대로 흘러가면 "^^L rac{...}" 같은 깨진 출력이 되므로 여기서 복구한다.
  parsedJson = recoverMangledLatexControls(parsedJson);
  return {
    rawPayload: payload,
    modelText,
    parsedJson,
    elapsedMs,
    usageMetadata: payload?.usageMetadata || null,
    finishReason: candidate?.finishReason || '',
  };
}
