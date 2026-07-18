// 교재 페이지 VLM 응답 공통 JSON 복구.
//
// Gemini가 responseMimeType=application/json, finishReason=STOP으로 끝나도
// 유효 JSON 뒤에 여분 문자를 붙이거나 마지막 닫는 괄호를 누락하는 경우가 있다.

import {
  closeTruncatedJson,
  extractBalancedJsonObject,
  recoverMangledLatexControls,
  repairLatexBackslashes,
} from '../problem_bank/extract_engines/vlm/client.js';

export function parseTextbookVlmJson(text) {
  const source = String(text || '').trim();
  for (const candidate of [source, repairLatexBackslashes(source)]) {
    try {
      return recoverMangledLatexControls(JSON.parse(candidate));
    } catch (_) {
      const balanced = extractBalancedJsonObject(candidate);
      if (balanced) {
        try {
          return recoverMangledLatexControls(JSON.parse(balanced));
        } catch (_) {
          // 아래 복구로 진행한다.
        }
      }
      const greedy = candidate.match(/\{[\s\S]*\}/);
      if (greedy) {
        try {
          return recoverMangledLatexControls(JSON.parse(greedy[0]));
        } catch (_) {
          // 마지막 닫는 괄호 복구로 진행한다.
        }
      }
      const closed = closeTruncatedJson(candidate);
      if (closed) return recoverMangledLatexControls(closed);
    }
  }
  return null;
}
