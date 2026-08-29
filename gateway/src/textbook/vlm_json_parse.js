// 교재 페이지 VLM 응답 공통 JSON 복구.
//
// Gemini가 responseMimeType=application/json, finishReason=STOP으로 끝나도
// 유효 JSON 뒤에 여분 문자를 붙이거나 마지막 닫는 괄호를 누락하는 경우가 있다.

import {
  closeTruncatedJson,
  extractBalancedJsonObject,
  joinGeminiTextParts,
  recoverMangledLatexControls,
  repairLatexBackslashes,
} from '../problem_bank/extract_engines/vlm/client.js';

export { joinGeminiTextParts };

// 모델이 이따금 요청한 객체를 배열로 한 겹 더 감싸 `[{ ... }]` 로 돌려준다.
// 판독기들은 모두 `parsedJson.items` / `parsedJson.entries` 를 읽으므로, 배열이
// 오면 그 값이 undefined 가 되어 **아무 오류 없이 0건**으로 끝난다. 수력충전
// 2-1 답지 14쪽이 그렇게 통째로 비었다(finishReason=STOP, 정답 13건 정상 판독).
// 그래서 파서 단계에서 껍데기를 벗긴다.
export function unwrapTextbookVlmJson(value) {
  if (!Array.isArray(value)) return value;
  const objects = value.filter((v) => v && typeof v === 'object' && !Array.isArray(v));
  if (objects.length === 1) return objects[0];
  // `[{items:[..]}, {items:[..]}]` 처럼 여러 겹이면 같은 열을 이어 붙인다.
  const merged = {};
  for (const obj of objects) {
    for (const [key, val] of Object.entries(obj)) {
      if (Array.isArray(val)) {
        merged[key] = [...(Array.isArray(merged[key]) ? merged[key] : []), ...val];
      } else if (!(key in merged)) {
        merged[key] = val;
      }
    }
  }
  return Object.keys(merged).length > 0 ? merged : value;
}

export function parseTextbookVlmJson(text) {
  const source = String(text || '').trim();
  const done = (value) => unwrapTextbookVlmJson(recoverMangledLatexControls(value));
  for (const candidate of [source, repairLatexBackslashes(source)]) {
    try {
      return done(JSON.parse(candidate));
    } catch (_) {
      const balanced = extractBalancedJsonObject(candidate);
      if (balanced) {
        try {
          return done(JSON.parse(balanced));
        } catch (_) {
          // 아래 복구로 진행한다.
        }
      }
      const greedy = candidate.match(/\{[\s\S]*\}/);
      if (greedy) {
        try {
          return done(JSON.parse(greedy[0]));
        } catch (_) {
          // 마지막 닫는 괄호 복구로 진행한다.
        }
      }
      const closed = closeTruncatedJson(candidate);
      if (closed) return done(closed);
    }
  }
  return null;
}
