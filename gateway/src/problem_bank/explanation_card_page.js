// 검수용 정답·해설 카드(/pb/preview/custom-thumbnail, cardKind=explanation)의 쪽 높이.
//
// 해설 카드는 한 덩어리(minipage)로 찍혀 쪽을 넘기지 못한다. 쪽 높이가 800mm 로 고정이었을 때
// 줄이 백 줄을 넘는 해설(모의고사 22번·30번)은 쪽을 넘어가 빈 카드가 나왔다.
// 그래서 해설의 줄 수와 그림 수로 쪽을 넉넉하게 잡는다. 남는 아래쪽은 카드를 만들 때 잘라 낸다.

export const EXPLANATION_CARD_MIN_HEIGHT_MM = 800;
// TeX 의 길이 한계(약 5,758mm) 아래.
export const EXPLANATION_CARD_MAX_HEIGHT_MM = 5000;

const BASE_MM = 200; // 정답 줄과 위아래 여백
const ROW_MM = 12; // 한 줄(분수·큰 괄호가 든 줄 포함)에 넉넉히 잡는 높이
const FIGURE_MM = 90; // 해설 그림 하나
const ROW_CHARS = 60; // 원문 한 줄이 이보다 길면 카드에서 여러 줄로 넘어간다고 본다

/** 해설 글이 카드에서 차지할 줄 수(넉넉하게 어림한다). */
export function explanationCardRows(explanation) {
  let rows = 0;
  for (const line of String(explanation || "").split(/\r?\n/)) {
    const text = line.trim();
    if (text) rows += Math.max(1, Math.ceil(text.length / ROW_CHARS));
  }
  return rows;
}

/** 해설 카드를 찍을 쪽 높이(mm). */
export function explanationCardPageHeightMm(explanation, figureCount = 0) {
  const figures = Math.max(0, Number(figureCount) || 0);
  const need =
    BASE_MM + explanationCardRows(explanation) * ROW_MM + figures * FIGURE_MM;
  return Math.min(
    EXPLANATION_CARD_MAX_HEIGHT_MM,
    Math.max(EXPLANATION_CARD_MIN_HEIGHT_MM, Math.ceil(need)),
  );
}
