/**
 * HTML 렌더러에서도 `[문단:가운데]` 마커가 `stem-line-center` 클래스로 반영되는지 확인.
 */
import { renderQuestionBlock } from '../src/problem_bank/render_engine/html/components/question_block.js';

function dummyMath(latex) {
  return { svg: `<span class="math">${latex}</span>`, hasFraction: false };
}

const base = {
  id: 'dummy',
  question_number: '1',
  stem: '앞 문장입니다.\n[문단:가운데]\n이 줄은 가운데 정렬.\n[문단]\n뒤 문장입니다.',
  choices: [],
  equations: [],
};

const htmlWithMarker = renderQuestionBlock(base, dummyMath, { stemSizePt: 11 });

const baseNoMarker = {
  ...base,
  stem: '앞 문장입니다.\n[문단]\n이 줄은 가운데 정렬.\n[문단]\n뒤 문장입니다.',
};
const htmlNoMarker = renderQuestionBlock(baseNoMarker, dummyMath, { stemSizePt: 11 });

const centerHitsWith = (htmlWithMarker.match(/stem-line-center/g) || []).length;
const centerHitsWithout = (htmlNoMarker.match(/stem-line-center/g) || []).length;

console.log(`HTML with marker    : ${centerHitsWith} × stem-line-center`);
console.log(`HTML without marker : ${centerHitsWithout} × stem-line-center`);

const containsRawMarker = /\[문단:가운데\]/.test(htmlWithMarker);
console.log(`raw marker leaked   : ${containsRawMarker}`);

if (centerHitsWith >= 1 && centerHitsWithout === 0 && !containsRawMarker) {
  console.log('\nHTML SMOKE OK');
  process.exit(0);
}

console.log('\nFAIL - snippet:');
const idx = htmlWithMarker.indexOf('가운데 정렬');
console.log(htmlWithMarker.slice(Math.max(0, idx - 200), idx + 200));
process.exit(1);
