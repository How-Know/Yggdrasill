import { assert, assertEquals } from 'jsr:@std/assert@1';
import { combineStem, isReviewTodo, parseReviewImages } from './textbook_problem_review.ts';

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
