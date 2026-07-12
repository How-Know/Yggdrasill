// 실제 정답 DB 전체(/tmp/all_answers.json)를 엔진에 통과시키는 감사 스크립트.
//   node --experimental-strip-types corpus_audit.ts
//
// 확인 항목:
//   1) auto/self 분류 분포
//   2) 자기 일치성: compareAnswers(정답, 정답) == true (auto 문항 전부)
//   3) 키패드 커버리지: 정규화된 auto 정답이 키패드 문자만으로 입력 가능한지

import { readFileSync } from 'node:fs';
import {
  compareAnswers,
  gradingMode,
  normalizeMathLinear,
} from './grading.ts';

interface Row {
  crop_id: string;
  answer_kind: string;
  t: string | null;
}

const rows: Row[] = JSON.parse(readFileSync('/tmp/all_answers.json', 'utf8'));

// 수식 에디터/키패드에서 실제 입력 가능한 문자 집합
//   (apps/yggdrasill_student/lib/widgets/math_keypad.dart 와 동기화)
const KEYPAD_CHARS = new Set(
  (
    '0123456789.,+-*/^()[]=<>≤≥≠±√π°%:|Ⓞ…\u0307' + // 기본 키 + 구조 키 산출물
    'abcdefghijklmnopqrstuvwxyz' + // 변수 선반 (전체 알파벳)
    'ABCDEFGHIJKLMNOPQRSTUVWXYZ' +
    'αβγδ' +
    '∠△□≡∽⊥∥⌒' // 기하 선반
  ).split(''),
);
// 단위/짧은 한글 답은 키보드 모드로 입력 → 한글 음절/자모는 커버로 간주
const isHangul = (c: string) => /[가-힣ㄱ-ㅎㅏ-ㅣ㉠-㉭㈀-㈎]/.test(c);

let auto = 0;
let self = 0;
const selfReasons = new Map<string, number>();
let identityFail = 0;
const identityFailSamples: string[] = [];
let coverageFail = 0;
const uncovered = new Map<string, string[]>();

for (const row of rows) {
  const text = row.t ?? '';
  const mode = gradingMode(row.answer_kind, text);
  if (mode === 'self') {
    self += 1;
    const reason = row.answer_kind === 'image'
      ? 'image'
      : /(^|\s)\(\s*\d\s*\)\s*\S/.test(text)
      ? '세트형'
      : /\((가|나|다|라|마|바|사)\)/.test(text)
      ? '빈칸'
      : text.includes('\\begin')
      ? '행렬/연립'
      : /풀이\s*\d+\s*쪽/.test(text)
      ? '풀이참조'
      : '복수라벨';
    selfReasons.set(reason, (selfReasons.get(reason) ?? 0) + 1);
    continue;
  }
  auto += 1;

  // 2) 자기 일치성
  const out = compareAnswers(row.answer_kind, text, text);
  if (!out.correct) {
    identityFail += 1;
    if (identityFailSamples.length < 30) identityFailSamples.push(text);
  }

  // 3) 커버리지 (객관식은 번호 키만 필요 → 생략)
  if (row.answer_kind === 'objective') continue;
  const norm = normalizeMathLinear(text);
  const missing = [...new Set(
    norm.split('').filter((c) => !KEYPAD_CHARS.has(c) && !isHangul(c) && c !== ' '),
  )];
  if (missing.length > 0) {
    coverageFail += 1;
    const key = missing.join('');
    const list = uncovered.get(key) ?? [];
    if (list.length < 5) list.push(norm);
    uncovered.set(key, list);
  }
}

console.log(`총 ${rows.length}건 → auto ${auto} / self ${self}`);
console.log('self 사유:', Object.fromEntries(selfReasons));
console.log(`\n자기 일치성 실패: ${identityFail}건`);
for (const s of identityFailSamples) console.log('  -', JSON.stringify(s));
console.log(`\n키패드 미커버: ${coverageFail}건`);
for (const [chars, samples] of uncovered) {
  console.log(`  누락문자 [${chars}] × ${samples.length}+ 예:`, samples.slice(0, 3));
}
