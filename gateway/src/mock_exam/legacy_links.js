// 가형과 나형에 똑같이 실린 문항 찾기. AI 없이 글자만 비교한다.
// 두 시험지는 따로 추출되므로 같은 문항도 전사가 조금 다를 수 있다(띄어쓰기, 중괄호, [문단] 표시).
// 그래서 본문은 정규화한 뒤 닮은 정도로 보고, "같은 문항"은 답의 값까지 같을 때만 인정한다.
// 같은 문항이라도 선지 순서가 뒤집혀 실린 것이 있어(2020 수능 가형 6번 = 나형 11번) 정답 번호가 아니라 정답 값을 견준다.

/** 본문·선지를 비교용으로 줄인다: 표시, 공백, 글꼴 명령, 중괄호를 지운다. */
export function normalizeForMatch(text) {
  return String(text ?? '')
    .replace(/\[[^\]\n]{1,20}\]/g, '')
    .replace(/\\(?:displaystyle|left|right|,|;|:|!|quad|qquad)(?![a-zA-Z])/g, '')
    .replace(/\\(?:text|mathrm|rm|mathbf|operatorname)(?![a-zA-Z])/g, '')
    .replace(/\\dfrac(?![a-zA-Z])/g, '\\frac')
    .replace(/\\geq(?![a-zA-Z])/g, '\\ge')
    .replace(/\\leq(?![a-zA-Z])/g, '\\le')
    .replace(/\\colon(?![a-zA-Z])/g, ':')
    .replace(/[{}$\s]/g, '');
}

function bigrams(s) {
  const out = new Map();
  for (let i = 0; i < s.length - 1; i += 1) {
    const g = s.slice(i, i + 2);
    out.set(g, (out.get(g) || 0) + 1);
  }
  return out;
}

/** 두 글의 닮은 정도(0~1). 글자 두 개씩 묶음이 겹치는 비율이다. */
export function textSimilarity(a, b) {
  const x = normalizeForMatch(a);
  const y = normalizeForMatch(b);
  if (!x || !y) return 0;
  if (x === y) return 1;
  const gx = bigrams(x);
  const gy = bigrams(y);
  let common = 0;
  let nx = 0;
  let ny = 0;
  for (const n of gx.values()) nx += n;
  for (const n of gy.values()) ny += n;
  for (const [g, n] of gx) common += Math.min(n, gy.get(g) || 0);
  return nx + ny === 0 ? 0 : (2 * common) / (nx + ny);
}

const CIRCLED = ['①', '②', '③', '④', '⑤'];

function choiceTexts(item) {
  const choices = Array.isArray(item?.choices) ? item.choices : [];
  return choices.map((c) => ({
    label: String(c?.label ?? '').trim(),
    value: normalizeForMatch(c?.text ?? ''),
  }));
}

/** 정답의 값. 객관식은 정답 번호가 가리키는 선지의 글, 주관식은 적힌 답이다. 알 수 없으면 ''. */
export function answerValue(item) {
  const answer = String(item?.answerText ?? '').trim();
  if (!answer) return '';
  if (item?.answerKind !== 'objective') return normalizeForMatch(answer);
  const choices = choiceTexts(item);
  const byLabel = choices.find((c) => c.label === answer);
  if (byLabel) return byLabel.value;
  const index = CIRCLED.indexOf(answer);
  return index >= 0 && choices[index] ? choices[index].value : '';
}

function sameChoiceSet(a, b) {
  const x = choiceTexts(a).map((c) => c.value).sort();
  const y = choiceTexts(b).map((c) => c.value).sort();
  return x.length > 0 && x.length === y.length && x.every((v, i) => v === y[i]);
}

/**
 * 나형 문항마다 같은 가형 문항을 찾는다.
 * item: { number, stem, choices: [{label, text}], answerKind: 'objective'|'subjective', answerText }
 * same      본문이 sameMin 이상 닮고, 정답 값이 같고, (둘 다 객관식이면) 선지 값 묶음이 같다.
 *           한쪽이 객관식이고 다른 쪽이 주관식이어도 정답 값(객관식은 정답 선지의 글)이 같으면 같은 문항이다
 *           (문항 하나가 객관식·주관식을 모두 받을 수 있다, 사장님 결정 2026-11-24). 그런 쌍은 formDiffers 가 true 다.
 * uncertain 본문은 similarMin 이상 닮았지만 위 조건 중 하나가 어긋난다. 연결하지 않고 사람이 본다.
 * 가형 문항 하나는 나형 문항 하나에만 붙는다(닮은 정도가 높은 쌍부터).
 */
export function matchLegacySameQuestions(gaItems, naItems, { sameMin = 0.92, similarMin = 0.75 } = {}) {
  const pairs = [];
  for (const na of naItems || []) {
    for (const ga of gaItems || []) {
      const similarity = textSimilarity(na.stem, ga.stem);
      if (similarity >= similarMin) pairs.push({ na, ga, similarity });
    }
  }
  pairs.sort((a, b) => b.similarity - a.similarity || a.na.number - b.na.number || a.ga.number - b.ga.number);
  const usedNa = new Set();
  const usedGa = new Set();
  const same = [];
  const uncertain = [];
  for (const { na, ga, similarity } of pairs) {
    if (usedNa.has(na.number) || usedGa.has(ga.number)) continue;
    usedNa.add(na.number);
    usedGa.add(ga.number);
    const reasons = [];
    if (similarity < sameMin) reasons.push('본문이 일부 다름');
    const formDiffers = na.answerKind !== ga.answerKind;
    const x = answerValue(na);
    const y = answerValue(ga);
    if (!x || !y) reasons.push('정답 값을 알 수 없음');
    else if (x !== y) reasons.push('정답 값이 다름');
    if (!formDiffers && na.answerKind === 'objective' && !sameChoiceSet(na, ga)) reasons.push('선지 값이 다름');
    const row = {
      naNumber: na.number,
      gaNumber: ga.number,
      similarity: Math.round(similarity * 1000) / 1000,
      formDiffers,
    };
    if (reasons.length === 0) same.push(row);
    else uncertain.push({ ...row, reasons });
  }
  const byNa = (a, b) => a.naNumber - b.naNumber;
  return { same: same.sort(byNa), uncertain: uncertain.sort(byNa) };
}
