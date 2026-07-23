// v11 uniform-line 렌더 검증용 임시 스크립트.
// 한 줄짜리 정답들이 동일한 픽셀 높이로 렌더되는지 확인한다.
import { renderAnswerWithXeLatex } from '../src/problem_bank/render_engine/xelatex/renderer.js';

const V11_OPTIONS = {
  cropToInk: 'horizontal',
  paddingPx: 3,
  topPaddingPx: 0,
  bottomPaddingPx: 0,
  alphaGamma: 0.56,
  cropAlphaThreshold: 1,
  topBleedPx: 0,
  strokePx: 0,
};

const cases = [
  ['digit', '2'],
  ['negative', '-4'],
  ['fraction', '$\\dfrac{3}{2}$'],
  ['korean', '풀이 참조'],
  ['sqrt', '$2\\sqrt{3}$'],
  ['set2', '(1) 3 (2) -5'],
  ['expfrac', '$3^{\\frac{1}{2}}$'],
  ['expfrac-d', '$x^{\\dfrac{2}{3}}+1$'],
  ['twoline', '$a=3$, $b=-2$, $c=11$, $d=-7$, $e=13$, $f=-17$'],
  ['twoline-fr', '$\\dfrac{1}{2}$, $\\dfrac{3}{4}$, $\\dfrac{5}{6}$, $\\dfrac{7}{8}$, $\\dfrac{9}{10}$, $\\dfrac{11}{12}$'],
];

for (const [name, answer] of cases) {
  const rendered = await renderAnswerWithXeLatex({
    answer,
    deviceScaleFactor: 1,
    fontFamily: 'Malgun Gothic',
    fontBold: 'Malgun Gothic Bold',
    fontSizePt: 15,
    maxWidthCm: 6.25,
    textColor: 'EAF2F7',
    backgroundColor: '151C21',
    transparent: false,
    transparentOptions: V11_OPTIONS,
    uniformLineBox: true,
  });
  console.log(
    `${name.padEnd(10)} w=${rendered.width} h=${rendered.height}`,
  );
}
