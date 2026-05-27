/**
 * V2 (xelatex-v2) 렌더 파이프라인 전용 매직 넘버 모음.
 *
 * V1(xelatex) 코드 곳곳에 흩어져 있던 +5pt, -2.3pt, 0.5em 등의 경험값들이
 *   회귀 추적을 어렵게 만들었던 점을 반영, V2 에서는 *모든* 경험값을 이 한
 *   파일에서만 정의한다.
 *
 * 새 매직넘버를 추가하려면:
 *   1. 여기에 const 로 선언
 *   2. 의미/근거를 주석에 명시 (어느 폰트/시각 효과에서 도출된 경험값인지)
 *   3. template.js 에서는 *반드시* 이 파일을 import 해서 사용 (literal 금지)
 */

// ─── 옵션 2: 인라인 수식 한글 시각 중심 보정값 ────────────────────────────
// 산업 표준 방식(InDesign 디자이너 baseline-shift, MS Word Cambria Math 사례)을
//   참고한 경험적 보정값. math axis(\fontdimen22\textfont2) 에 위치한 수식 글리프를
//   한글 잉크 시각 중심(baseline +4~5pt)에 *시각적으로* 가깝게 끌어올리기 위해
//   추가로 위로 1.5pt 끌어올린다.
// - 한글 폰트(KoPubWorldBatangPro/Malgun Gothic/HCRBatang) 기준 1.2~1.8pt 범위에서
//   가장 자연스러움.
// - 폰트 교체 시 이 값만 조정하면 됨.
export const V2_INLINE_MATH_VISUAL_SHIFT_PT = 1.5;

// ─── 옵션 3: 수식 줄 strut 대칭화 관련 ─────────────────────────────────
// 큰 수식이 포함된 라인의 ht/dp 를 *명시적*으로 대칭화하기 위한 phantom strut 의
//   기본 폭(em). 본문 한 줄의 평균 ht/dp 가 약 0.5em 임을 기준으로 산출.
//   라인 자체의 자연 ht/dp 가 이 값보다 크면 그쪽이 채택됨 (\vphantom 식으로).
export const V2_LINE_SYMMETRIC_HALF_EM = 0.5;

// ─── 짝슬롯(row-pair) 라벨 박스 ↔ 가로 구분선 gap (pt) ─────────────────
// V1 의 14pt - 2.3pt = 11.7pt 가 시각적으로 가장 자연스럽다는 평가가 누적되어
//   V2 에서도 동일한 값을 디폴트로 사용. strut 변경의 영향이 있을 경우 여기서
//   재튜닝.
export const V2_LABEL_TO_DIVIDER_GAP_PT = 11.7;

/**
 * V2 매크로 영역(visualCenterMacroLines 안)에 삽입할 LaTeX 매크로 정의 줄들.
 * 매직넘버를 LaTeX 상수 매크로로 노출해, template.js 안의 다른 매크로들이
 * `\YggV2InlineMathShift` 등으로 참조하게 한다.
 *
 * 주의: 이 줄들은 *kotex 로드 직전* preamble 위치에 들어간다. 그 시점에는
 *   XeLaTeX 의 한글/유니코드 catcode 가 안전하지 않으므로 LaTeX 코멘트 줄에도
 *   *ASCII 글자만* 사용해야 한다. (한글이나 box-drawing 글자를 주석에 넣으면
 *   "Missing \begin{document}" 등의 typeset-mode 강제 진입 에러 발생.)
 */
export function v2ConstantMacroLines() {
  // 매크로 이름에 *숫자 금지* — LaTeX 매크로 이름은 `\backslash + 알파벳만` 허용한다.
  //   `\YggV2InlineMathShift` 처럼 숫자가 들어가면 LaTeX 가 `\YggV` 까지만 매크로로
  //   인식하고 `2InlineMathShift` 를 *typeset 모드의 일반 텍스트*로 처리 → 자동
  //   `\begin{document}` 진입 시도 → "Missing \begin{document}" 에러로 컴파일 실패.
  //   따라서 V2 식별자는 `Vtwo` 처럼 알파벳으로 풀어 쓴다.
  return [
    '% --- V2 (xelatex-v2) magic constants (mirror of v2_constants.js) ---',
    `\\providecommand{\\YggVtwoInlineMathShift}{${V2_INLINE_MATH_VISUAL_SHIFT_PT}pt}`,
    `\\providecommand{\\YggVtwoLineHalfEm}{${V2_LINE_SYMMETRIC_HALF_EM}em}`,
  ];
}
