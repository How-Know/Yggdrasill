// 교재 본문 추출의 "빠진 번호만" 런.
//
// 예전 원스톱으로 본문을 뽑아 둔 소단원은 일부 번호만 본문이 없다. 이때 전체 추출을
// 다시 돌리면 워커가 그 문서의 문항을 모두 지우고 새로 넣으므로, 사람이 고친 본문까지
// 사라진다. 앱은 본문이 없는 크롭 번호를 job.result_summary.textbook_only_numbers 에
// 넣고, 워커는 그 번호가 있는 쪽만 모델에 보내 그 번호만 저장한다.

import { normalizeProblemNumberKey } from '../textbook/problem_number_key.js';

// 세트 범위 머리(0120~0121)가 이보다 넓으면 잘못 읽힌 범위로 보고 형제 번호를 붙이지 않는다.
const MAX_SET_SPAN = 100;

/** 작업에 담긴 대상 번호(앞뒤 공백 제거, 같은 번호 키는 하나만). */
export function textbookOnlyNumbersFromJob(job) {
  const raw = job?.result_summary?.textbook_only_numbers;
  if (!Array.isArray(raw)) return [];
  const seen = new Set();
  const out = [];
  for (const value of raw) {
    const text = String(value ?? '').trim();
    const key = normalizeProblemNumberKey(text);
    if (!key || seen.has(key)) continue;
    seen.add(key);
    out.push(text);
  }
  return out;
}

export function problemNumberKeySet(numbers) {
  const keys = new Set();
  for (const number of Array.isArray(numbers) ? numbers : []) {
    const key = normalizeProblemNumberKey(number);
    if (key) keys.add(key);
  }
  return keys;
}

function setRangeMembers(range) {
  const from = Number(range?.from);
  const to = Number(range?.to);
  if (!Number.isInteger(from) || !Number.isInteger(to) || from <= 0 || to < from) return [];
  if (to - from > MAX_SET_SPAN) return [];
  const members = [];
  for (let n = from; n <= to; n += 1) members.push(String(n));
  return members;
}

/**
 * 크롭 색인을 대상 번호로 좁힌다. 대상이 든 세트의 다른 번호도 남겨,
 * 세트 공통 발문을 같은 세트 문항에서 보충하는 규칙이 그대로 돌게 한다.
 * 남긴 형제 번호는 저장 전에 keepQuestionsWithNumberKeys 로 다시 뺀다.
 */
export function narrowCropIndexToNumbers(cropIndex, onlyKeys) {
  const byNumber = cropIndex?.byNumber instanceof Map ? cropIndex.byNumber : new Map();
  const ranges = Array.isArray(cropIndex?.setHeaderRanges) ? cropIndex.setHeaderRanges : [];
  const keys = onlyKeys instanceof Set ? onlyKeys : new Set();
  const keptRanges = ranges.filter((range) =>
    setRangeMembers(range).some((key) => keys.has(key)),
  );
  const wanted = new Set(keys);
  for (const range of keptRanges) {
    for (const key of setRangeMembers(range)) wanted.add(key);
  }
  const narrowed = new Map();
  for (const [key, row] of byNumber) {
    if (wanted.has(key)) narrowed.set(key, row);
  }
  return { byNumber: narrowed, setHeaderRanges: keptRanges };
}

export function keepQuestionsWithNumberKeys(questions, onlyKeys) {
  const keys = onlyKeys instanceof Set ? onlyKeys : new Set();
  return (Array.isArray(questions) ? questions : []).filter((q) =>
    keys.has(normalizeProblemNumberKey(q?.question_number)),
  );
}

/** 대상 번호 중 이번 결과에 없는 번호. */
export function missingProblemNumbers(numbers, questions) {
  const produced = problemNumberKeySet(
    (Array.isArray(questions) ? questions : []).map((q) => q?.question_number),
  );
  return (Array.isArray(numbers) ? numbers : []).filter(
    (number) => !produced.has(normalizeProblemNumberKey(number)),
  );
}
