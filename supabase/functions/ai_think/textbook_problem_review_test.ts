import { assert, assertEquals } from 'jsr:@std/assert@1';
import {
  combineStem,
  commonStemFix,
  isReviewTodo,
  normalizeIssueKind,
  normalizeProposedChoices,
  parseReviewImages,
  stripCommonStem,
} from './textbook_problem_review.ts';

const CROP = '0f6a2c1e-7b3d-4e8f-9a1b-2c3d4e5f6a7b';

Deno.test('해설 크롭 base64 와 V2 서명 URL 만 받는다 (잘못된 키·형식은 버린다)', () => {
  const m = parseReviewImages({
    [CROP]: { solution_image_base64: 'iVBORw0KGgo=', solution_image_mime: 'image/png', v2_problem_url: 'https://x.supabase.co/a.png' },
    'not-a-uuid': { solution_image_base64: 'AAAA' },
    '1f6a2c1e-7b3d-4e8f-9a1b-2c3d4e5f6a7b': { solution_image_base64: 'not base64!!', v2_problem_url: 'http://insecure/a.png' },
  });
  assertEquals(m.size, 2);
  const a = m.get(CROP)!;
  assert(a.solutionImageDataUrl!.startsWith('data:image/png;base64,iVBOR'));
  assertEquals(a.v2ProblemUrl, 'https://x.supabase.co/a.png');
  const b = m.get('1f6a2c1e-7b3d-4e8f-9a1b-2c3d4e5f6a7b')!;
  assertEquals(b.solutionImageDataUrl, null);
  assertEquals(b.v2ProblemUrl, null);
});

Deno.test('세트 문항은 공통 지시문과 개별 문항을 합쳐 읽는다', () => {
  assertEquals(combineStem('다음 수의 약수를 모두 구하여라.', '7'), '[공통 지시문] 다음 수의 약수를 모두 구하여라.\n[문항] 7');
  assertEquals(combineStem('', 'x+1=2'), 'x+1=2');
  assertEquals(combineStem('A', 'A 그리고 B'), 'A 그리고 B');
});

Deno.test('공통 발문이 개별 발문에 중복되면 공통 부분을 뗀 본문을 제안한다', () => {
  const common = '다음 수의 약수를 모두 구하고, 소수인지 합성수인지 ([공백:2]) 안에 써넣어라.';
  assertEquals(
    stripCommonStem(common, '다음 수의 약수를 모두 구하고, 소수인지 합성수인지 ([공백:2]) 안에 써넣어라.\n[문단]\n9\n약수: box(~~)'),
    '9\n약수: box(~~)',
  );
  // 공백·[문단] 차이는 무시한다
  assertEquals(stripCommonStem('다음을 구하여라.', '다음을  구하여라.[문단]7'), '7');
  // 중복이 없으면 null
  assertEquals(stripCommonStem(common, '9\n약수: box(~~)'), null);
  assertEquals(stripCommonStem('', '9'), null);
  // 떼어내면 본문이 비는 경우는 건드리지 않는다
  assertEquals(stripCommonStem('다음을 구하여라.', '다음을 구하여라.'), null);
  // 앞머리가 아니어도 정확히 같은 문자열이면 제거한다
  assertEquals(stripCommonStem('다음을 구하여라.', '[문단]7\n다음을 구하여라.'), '7');
});

Deno.test('공통 발문에 개별 본문까지 통째로 들어 있으면 공통 발문은 지시문만, 개별 발문은 나머지만 남긴다', () => {
  const full = '다음 수의 약수를 모두 구하고, 소수인지 합성수인지 ([공백:2]) 안에 써넣어라.\n[문단]\n9\n약수: box(~~)';
  // common_stem == stem
  assertEquals(commonStemFix(full, full), {
    stem: '9\n약수: box(~~)',
    commonStem: '다음 수의 약수를 모두 구하고, 소수인지 합성수인지 ([공백:2]) 안에 써넣어라.',
  });
  // 지시문만 중복이면 공통 발문은 그대로
  assertEquals(commonStemFix('다음을 구하여라.', '다음을 구하여라.[문단]7'), { stem: '7', commonStem: null });
  // 조건 상자처럼 여러 문단으로 된 정당한 공통 발문은 건드리지 않는다
  assertEquals(commonStemFix('다음 물음에 답하여라.[문단][박스시작]a>0[박스끝]', '12'), null);
  // 공통 발문이 다른 문항(9번)의 본문을 담고 있으면 이 문항(12번)에서는 판단하지 않는다
  assertEquals(commonStemFix(full, '다음 수의 약수를 모두 구하고, 소수인지 합성수인지 ([공백:2]) 안에 써넣어라.\n[문단]\n12\n약수: box(~~)'), null);
});

Deno.test('재검수 대상: 미검수·풀이 없음·해설 미전사(시도 전)만, 승인·전사 시도 후는 제외', () => {
  assert(isReviewTodo({ math_status: 'pending' }, false));
  assert(isReviewTodo({ math_status: 'clean', ai_solution: null }, false));
  assert(isReviewTodo({ math_status: 'clean', ai_solution: 'x', has_solution_ref: true, solution_transcribed: null }, false));
  assert(!isReviewTodo({ math_status: 'clean', ai_solution: 'x', has_solution_ref: true, solution_transcribed: '해설' }, false));
  assert(!isReviewTodo({ math_status: 'approved', ai_solution: 'x', has_solution_ref: true, solution_transcribed: null }, false));
  assert(!isReviewTodo({
    math_status: 'issue', ai_solution: 'x', has_solution_ref: true, solution_transcribed: null,
    quality_checks: { solution_vision: { found: false } },
  }, false));
  assert(!isReviewTodo({ math_status: 'clean', ai_solution: 'x', has_solution_ref: false }, false));
  assert(isReviewTodo({ math_status: 'approved', ai_solution: 'x' }, true));
});

Deno.test('이상 원인 분류: 이상이 없으면 none, 모르는 값은 data 로 본다', () => {
  assertEquals(normalizeIssueKind('engine', false), 'none');
  assertEquals(normalizeIssueKind('engine', true), 'engine');
  assertEquals(normalizeIssueKind('figure', true), 'figure');
  assertEquals(normalizeIssueKind('weird', true), 'data');
  assertEquals(normalizeIssueKind(undefined, true), 'data');
});

Deno.test('선지 수정안은 label 이 있는 {label,text} 배열만 받는다', () => {
  assertEquals(normalizeProposedChoices(null), null);
  assertEquals(normalizeProposedChoices([]), null);
  assertEquals(normalizeProposedChoices([{ label: '①', text: ' 2 ' }, { label: '②', text: '3' }]), [
    { label: '①', text: '2' },
    { label: '②', text: '3' },
  ]);
  assertEquals(normalizeProposedChoices([{ label: '', text: '2' }]), null);
  assertEquals(normalizeProposedChoices(['①']), null);
});
