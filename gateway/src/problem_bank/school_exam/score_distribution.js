// 내신 시험지에서 점수를 못 읽은 문항에 점수를 나눠 총합을 맞춘다(2026-11-17 사장님 결정).
//
//   고정 점수   = 원본에서 읽은 점수, 사람이 넣은 점수. 건드리지 않는다.
//   나눌 점수   = 총점(기본 100) − 고정 점수의 합. 점수 없는 문항에만 나눈다.
//   가중치      = 같은 시험지에서 읽은 점수의 유형별(객관식 / 주관식·서술형) 평균.
//                 한쪽 유형에 읽은 점수가 없으면 기본 비율(객관식 1 : 주관식·서술형 1.5)로 채운다.
//   점수 단위   = 읽은 점수에 소수가 있으면 0.1점, 아니면 1점.
//   끝수        = 단위로 내림한 뒤 남는 점수를 뒤 번호 주관식·서술형부터 한 단위씩 더한다.
//
// 추정한 점수는 meta.score_estimate = { value, total, at } 로 표시한다. meta.score_point 가 그 값과 같을 때만
// 추정 점수로 보고 다시 나눈다. 사람이 값을 바꾸면 고정 점수가 된다.

export const DEFAULT_EXAM_TOTAL = 100;
export const DEFAULT_SUBJECTIVE_RATIO = 1.5;

function positive(value) {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? n : null;
}

function isObjective(row) {
  const type = String(row?.question_type ?? '').trim();
  if (type) return type === '객관식' || type.toLowerCase() === 'objective';
  return Array.isArray(row?.choices) && row.choices.length >= 2;
}

/// 저장된 점수와 그 점수가 추정값인지. 소문항 점수(score_parts)가 있으면 그 합이 문항 점수이고 고정이다.
export function storedScore(meta) {
  const m = meta && typeof meta === 'object' ? meta : {};
  if (Array.isArray(m.score_parts) && m.score_parts.length > 0) {
    let sum = 0;
    for (const part of m.score_parts) sum += positive(part?.value ?? part?.score) ?? 0;
    if (sum > 0) return { score: Math.round(sum * 100) / 100, estimated: false };
  }
  const score = positive(m.score_point);
  if (score === null) return { score: null, estimated: false };
  const est = m.score_estimate && typeof m.score_estimate === 'object' ? positive(m.score_estimate.value) : null;
  return { score, estimated: est !== null && Math.abs(est - score) < 1e-9 };
}

/// rows: [{ id, question_type, choices, meta }] (문항 순서대로).
/// 반환: { ok, reason?, unit, total, fixedSum, scores: Map(id → 점수) }. scores 에는 추정한 문항만 들어 있다.
export function distributeExamScores(rows, { total = DEFAULT_EXAM_TOTAL } = {}) {
  const list = Array.isArray(rows) ? rows : [];
  const fixed = [];
  const free = [];
  list.forEach((row, index) => {
    const { score, estimated } = storedScore(row?.meta);
    const entry = { id: row?.id, index, objective: isObjective(row), score };
    if (score !== null && !estimated) fixed.push(entry);
    else free.push(entry);
  });
  const fixedSum = Math.round(fixed.reduce((acc, e) => acc + e.score, 0) * 100) / 100;
  const unit = fixed.some((e) => Math.abs(e.score - Math.round(e.score)) > 1e-9) ? 0.1 : 1;
  const base = { unit, total, fixedSum, scores: new Map() };
  if (free.length === 0) return { ok: true, ...base };

  // 단위 개수(정수)로 계산해 소수 오차를 없앤다.
  const remainingUnits = Math.round((total - fixedSum) / unit);
  if (remainingUnits < free.length) return { ok: false, reason: 'no_room', ...base };

  const mean = (items) => (items.length ? items.reduce((acc, e) => acc + e.score, 0) / items.length : null);
  let objWeight = mean(fixed.filter((e) => e.objective));
  let subjWeight = mean(fixed.filter((e) => !e.objective));
  if (objWeight === null && subjWeight === null) {
    objWeight = 1;
    subjWeight = DEFAULT_SUBJECTIVE_RATIO;
  } else if (objWeight === null) {
    objWeight = subjWeight / DEFAULT_SUBJECTIVE_RATIO;
  } else if (subjWeight === null) {
    subjWeight = objWeight * DEFAULT_SUBJECTIVE_RATIO;
  }

  const weightSum = free.reduce((acc, e) => acc + (e.objective ? objWeight : subjWeight), 0);
  const units = free.map((e) =>
    Math.max(1, Math.floor((remainingUnits * (e.objective ? objWeight : subjWeight)) / weightSum + 1e-9)),
  );
  // 끝수: 뒤 번호 주관식·서술형부터, 그다음 뒤 번호 객관식. 최소 한 단위 때문에 넘쳤으면 큰 점수부터 뺀다.
  const order = free
    .map((e, i) => ({ i, objective: e.objective, index: e.index }))
    .sort((a, b) => Number(a.objective) - Number(b.objective) || b.index - a.index)
    .map((x) => x.i);
  let left = remainingUnits - units.reduce((acc, u) => acc + u, 0);
  for (let k = 0; left > 0; k += 1, left -= 1) units[order[k % order.length]] += 1;
  while (left < 0) {
    let big = 0;
    for (let i = 1; i < units.length; i += 1) if (units[i] > units[big]) big = i;
    if (units[big] <= 1) return { ok: false, reason: 'no_room', ...base };
    units[big] -= 1;
    left += 1;
  }

  free.forEach((e, i) => {
    base.scores.set(e.id, unit === 1 ? units[i] : Math.round(units[i]) / 10);
  });
  return { ok: true, ...base };
}

/// 문항 meta 에 추정 점수를 적는다(다른 키는 그대로). 값이 이미 같으면 null.
export function metaWithEstimatedScore(meta, value, { total = DEFAULT_EXAM_TOTAL, at = new Date().toISOString() } = {}) {
  const m = meta && typeof meta === 'object' ? meta : {};
  const cur = storedScore(m);
  if (cur.estimated && Math.abs(cur.score - value) < 1e-9) return null;
  return { ...m, score_point: value, score_estimate: { value, total, at } };
}
