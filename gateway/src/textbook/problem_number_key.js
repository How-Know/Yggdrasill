// 교재 문항번호를 비교용 키로 정규화한다.
//
// 이 규칙은 답지 매칭·해설 좌표 매칭·문제은행 추출이 **모두 같아야** 한다.
// 예전에는 세 곳이 각자 다른 규칙을 갖고 있었고, 문제은행 추출 쪽만
// `Number.parseInt` 였다. 그래서 개념+유형의 "개념확인8", "예제1" 같은 번호가
// NaN 으로 떨어져 기대 목록이 통째로 비었고, 추출 런이
// `vlm_textbook_crop_scope_empty` 로 죽었다. "1-1"(따름 문제)은 "1" 로 뭉개져
// 대표 문항과 같은 키가 되면서 조용히 사라졌다.
//
// 규칙
//   "0012"        → "12"        선행 0 은 무시한다.
//   "12"          → "12"
//   "0113~0116"   → "113-116"   범위 배지는 양 끝을 붙인 한 개의 키.
//   "1-1", "7-2"  → "1-1"       따름 문제는 대표 문항과 다른 문항이다.
//   "109-2"       → "109-2"     블록 접두어(본문 페이지)도 번호의 일부다.
//   "개념확인105"  → "개념확인105" 코너 이름이 번호의 일부인 경우.
//   "예제1"        → "예제1"      예제·유제·연습은 각각 1번부터 시작한다.

export function parseProblemNumberRange(input) {
  const match = String(input || '')
    .trim()
    .match(/^0*(\d+)\s*[~\-\u2013\u2014\u301c]\s*0*(\d+)$/);
  if (!match) return null;
  const from = Number(match[1]);
  const to = Number(match[2]);
  if (!Number.isFinite(from) || !Number.isFinite(to) || from > to) return null;
  return { from, to };
}

export function parseSingleProblemNumber(input) {
  const text = String(input || '').trim();
  if (!/^\d+$/.test(text)) return null;
  const n = Number(text);
  return Number.isFinite(n) ? n : null;
}

export function normalizeProblemNumberKey(input) {
  const text = String(input || '').trim();
  if (!text) return '';
  const range = parseProblemNumberRange(text);
  if (range) return `${range.from}-${range.to}`;
  const compact = text.replace(/\s+/g, '');
  // 숫자 앞뒤에 붙은 조각이 의미를 갖는 번호는 통째로 남긴다. 첫 숫자만
  // 남기면 "2-1"→"2", "109-1"/"109-2"→"109" 이 돼서 서로 다른 문항이 같은
  // 키가 되고, 뒤에 온 쪽이 조용히 버려진다.
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
