import { applyInlineAlignmentMarkers, normalizeLineAlignValue }
  from '../src/problem_bank/render_engine/utils/text.js';

let pass = 0;
let fail = 0;

function assertEq(actual, expected, label) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) {
    pass += 1;
    console.log(`  OK  ${label}`);
  } else {
    fail += 1;
    console.log(`  FAIL ${label}`);
    console.log(`       expected: ${e}`);
    console.log(`       actual:   ${a}`);
  }
}

console.log('--- normalizeLineAlignValue ---');
assertEq(normalizeLineAlignValue('center'), 'center', 'en:center');
assertEq(normalizeLineAlignValue('가운데'), 'center', 'kr:가운데');
assertEq(normalizeLineAlignValue('오른쪽'), 'right', 'kr:오른쪽');
assertEq(normalizeLineAlignValue('JUSTIFY'), 'justify', 'en:JUSTIFY');
assertEq(normalizeLineAlignValue(''), 'left', 'empty');
assertEq(normalizeLineAlignValue(null), 'left', 'null');

console.log('\n--- applyInlineAlignmentMarkers ---');

// case 1: 독립 마커 라인 `[문단:가운데]` → 다음 라인 center
{
  const input = '앞 내용\n[문단:가운데]\n가운데 내용\n[문단]\n뒤 내용';
  const { stem, stemLineAligns } = applyInlineAlignmentMarkers(input, []);
  assertEq(stem, '앞 내용\n[문단]\n가운데 내용\n[문단]\n뒤 내용', 'case1.stem');
  assertEq(stemLineAligns, ['left', 'left', 'center', 'left', 'left'], 'case1.aligns');
}

// case 2: 영어 속성
{
  const input = 'A\n[문단:center]\nB';
  const { stem, stemLineAligns } = applyInlineAlignmentMarkers(input, []);
  assertEq(stem, 'A\n[문단]\nB', 'case2.stem');
  assertEq(stemLineAligns, ['left', 'left', 'center'], 'case2.aligns');
}

// case 3: HWPX meta aligns 선반영 + 마커 없음 (변경 없음)
{
  const input = 'A\n[문단]\nB';
  const { stem, stemLineAligns } =
    applyInlineAlignmentMarkers(input, ['left', 'left', 'right']);
  assertEq(stem, 'A\n[문단]\nB', 'case3.stem');
  assertEq(stemLineAligns, ['left', 'left', 'right'], 'case3.aligns');
}

// case 4: 오른쪽 속성
{
  const input = 'A\n[문단:오른쪽]\nB\n[문단]\nC';
  const { stem, stemLineAligns } = applyInlineAlignmentMarkers(input, []);
  assertEq(stem, 'A\n[문단]\nB\n[문단]\nC', 'case4.stem');
  assertEq(stemLineAligns, ['left', 'left', 'right', 'left', 'left'], 'case4.aligns');
}

// case 5: 빈 속성 `[문단:]` 는 plain [문단] 과 동일
{
  const input = 'A\n[문단:]\nB';
  const { stem, stemLineAligns } = applyInlineAlignmentMarkers(input, []);
  assertEq(stem, 'A\n[문단]\nB', 'case5.stem');
  assertEq(stemLineAligns, ['left', 'left', 'left'], 'case5.aligns');
}

// case 6: 인라인 속성 마커 (내용 뒤) → 다음 라인 center
{
  const input = '앞 내용[문단:가운데]\n가운데 내용\n[문단]\n뒤';
  const { stem, stemLineAligns } = applyInlineAlignmentMarkers(input, []);
  assertEq(stem, '앞 내용[문단]\n가운데 내용\n[문단]\n뒤', 'case6.stem');
  assertEq(stemLineAligns, ['left', 'center', 'left', 'left'], 'case6.aligns');
}

// case 7: 입력 stemLineAligns 가 콘텐츠 라인에 이미 center 였으면 유지
{
  const input = 'A\n[문단]\nB';
  const { stem, stemLineAligns } =
    applyInlineAlignmentMarkers(input, ['left', 'left', 'center']);
  assertEq(stem, 'A\n[문단]\nB', 'case7.stem');
  assertEq(stemLineAligns, ['left', 'left', 'center'], 'case7.aligns');
}

// case 8: 연속된 여러 [문단:가운데] — 마지막 pending 만 다음 콘텐츠에 적용
{
  const input = 'A\n[문단:가운데]\n[문단:오른쪽]\nB';
  const { stem, stemLineAligns } = applyInlineAlignmentMarkers(input, []);
  assertEq(stem, 'A\n[문단]\n[문단]\nB', 'case8.stem');
  // 독립 마커 라인 자체의 align 은 base(left). 다음 콘텐츠 B 에 마지막 pending(right) 적용.
  assertEq(stemLineAligns, ['left', 'left', 'left', 'right'], 'case8.aligns');
}

console.log(`\nPASS=${pass} FAIL=${fail}`);
process.exit(fail === 0 ? 0 : 1);
