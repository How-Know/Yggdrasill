import { assert, assertEquals } from 'jsr:@std/assert@1';
import {
  cleanSolutionTranscribedText,
  combineStem,
  commonStemFix,
  effectiveSolution,
  figureMarkerCount,
  figureReviewVerdict,
  figureSizeRatioOk,
  foldCommonStemIntoStem,
  isCorruptedCommonStem,
  isDataFixableSymptom,
  isFalseBlankComplaint,
  isFillInBlankProblem,
  isMathResolveTarget,
  isReviewTodo,
  itemHasFigures,
  normalizeIssueKind,
  normalizeProposedChoices,
  parseReviewImages,
  pbQuestionHasFigures,
  sanitizeProblemMarkup,
  stripCommonStem,
  stripGuidedSolution,
  withoutDependentSetCommonStem,
} from './textbook_problem_review.ts';

const CROP = '0f6a2c1e-7b3d-4e8f-9a1b-2c3d4e5f6a7b';

Deno.test('종속형 세트는 공통 발문을 따로 넘기지 않고, 공통 지시문 제안은 본문 앞에 붙인다', () => {
  const dep = withoutDependentSetCommonStem({ set_type: 'dependent_set', common_stem: '다음을 읽고, 물음에 답하여라.', stem: '1) 표를 채워라.' });
  assertEquals(dep.common_stem, '');
  const ind = withoutDependentSetCommonStem({ set_type: 'independent_set', common_stem: '다음 수의 약수를 구하여라.', stem: '7' });
  assertEquals(ind.common_stem, '다음 수의 약수를 구하여라.');
  assertEquals(foldCommonStemIntoStem('다음을 읽고, 물음에 답하여라.', '1) 표를 채워라.'), '다음을 읽고, 물음에 답하여라.\n[문단]\n1) 표를 채워라.');
  const already = '다음을 읽고, 물음에 답하여라.\n[문단]\n1) 표를 채워라.';
  assertEquals(foldCommonStemIntoStem('다음을 읽고, 물음에 답하여라.', already), already);
});

Deno.test("'해' 빈칸 풀이 안내와 그것만 감싼 상자를 본문에서 빼고 뒤 소문항은 남긴다", () => {
  const stem = [
    '다음을 읽고, 물음에 답하여라.', '[문단]', '[박스시작]', '포도를 x\\text{ kg} 산다.', '[박스끝]', '[문단]',
    '2) 5\\text{ kg} 살 때 금액을 구하여라.', '[문단]', '[박스시작]', '해 y=box{~~}에 x=5를 대입하면', '[문단]',
    'y=box{~~}\\times 5', '[문단]', '3) 6000원일 때 몇 kg 산 것인지 구하여라.', '[문단]',
    '해 y=box{~~}에 y=6000을 대입하면', '[박스끝]',
  ].join('\n');
  assertEquals(
    stripGuidedSolution(stem),
    [
      '다음을 읽고, 물음에 답하여라.', '[문단]', '[박스시작]', '포도를 x\\text{ kg} 산다.', '[박스끝]', '[문단]',
      '2) 5\\text{ kg} 살 때 금액을 구하여라.', '[문단]', '3) 6000원일 때 몇 kg 산 것인지 구하여라.',
    ].join('\n'),
  );
  const unboxed = '1) 관계식을 구하여라.\n[문단]\n해 y=ax 꼴이다.\n[문단]\n[소문항2]\n2) 거리를 구하여라.';
  assertEquals(stripGuidedSolution(unboxed), '1) 관계식을 구하여라.\n[문단]\n[소문항2]\n2) 거리를 구하여라.');
  const inline = '\\overline{AB}=□\\,\\overline{NM}[문단][박스시작]\n해 점 N은 중점이므로 □배이다.[문단]\\therefore □\n[박스끝]';
  assertEquals(stripGuidedSolution(inline), '\\overline{AB}=□\\,\\overline{NM}');
  const plain = '해 뜨는 시각을 x라 할 때\n[문단]\n[박스시작]\n해마다 1분씩 늦어진다.\n[박스끝]';
  assertEquals(stripGuidedSolution(plain), plain);
});

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
  assertEquals(b.originalImageDataUrl, null);
});

Deno.test('교재 원본 이미지는 앱이 보낸 base64 와 픽셀 크기·쪽 좌표를 함께 받는다', () => {
  const m = parseReviewImages({
    [CROP]: {
      original_image_base64: 'iVBORw0KGgo=',
      original_width_px: 1100,
      original_height_px: 420,
      original_region_1k: [100, 40, 300, 520],
      original_raw_page: 12,
      set_header_image_base64: 'iVBORw0KGgo=',
    },
  });
  const a = m.get(CROP)!;
  assert(a.originalImageDataUrl!.startsWith('data:image/png;base64,'));
  assertEquals(a.originalSize, { width: 1100, height: 420 });
  assertEquals(a.originalRegion1k, [100, 40, 300, 520]);
  assertEquals(a.originalRawPage, 12);
  assert(a.setHeaderImageDataUrl!.startsWith('data:image/png;base64,'));
  assertEquals(a.solutionImageDataUrl, null);
});

Deno.test('그림 마커 수와 그림 크기 비율 허용 범위', () => {
  assertEquals(figureMarkerCount('다음 그림에서[그림] x 는? [[PB_FIG_3]] [도형]'), 3);
  assertEquals(figureMarkerCount('그림 없음'), 0);
  assert(figureSizeRatioOk(null));
  assert(figureSizeRatioOk(1.1));
  assert(!figureSizeRatioOk(1.4));
  assert(!figureSizeRatioOk(0.6));
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
  // [문단] 없이 한 줄로 붙은 경우
  assertEquals(commonStemFix('다음 수를 소인수분해하여라. 48', '다음 수를 소인수분해하여라. 48'), {
    stem: '48',
    commonStem: '다음 수를 소인수분해하여라.',
  });
  assertEquals(commonStemFix('다음 수를 소인수분해하여라.', '48'), null);
  // 조건 상자처럼 여러 문단으로 된 정당한 공통 발문은 건드리지 않는다
  assertEquals(commonStemFix('다음 물음에 답하여라.[문단][박스시작]a>0[박스끝]', '12'), null);
  // 공통 발문이 다른 문항(9번)의 본문을 담고 있으면 이 문항(12번)에서는 판단하지 않는다
  assertEquals(commonStemFix(full, '다음 수의 약수를 모두 구하고, 소수인지 합성수인지 ([공백:2]) 안에 써넣어라.\n[문단]\n12\n약수: box(~~)'), null);
  // 첫 문단이 지시문이 아니라 숫자·식('36=2^2×3^2')이고 두 번째 문단이 지시문이면 숫자·식으로 줄이지 않고 지시문을 살린다
  const tableStem = '다음 표의 빈칸에 알맞은 수를 써넣어라.\n[문단]15=3\\times5[표시작]×|1[표끝]';
  assertEquals(commonStemFix(`36=2^{2}\\times3^{2}\n[문단]\n${tableStem}`, tableStem), {
    stem: '15=3\\times5[표시작]×|1[표끝]',
    commonStem: '다음 표의 빈칸에 알맞은 수를 써넣어라.',
  });
  // 이미 잘못 줄어든 공통 발문('36=2^2×3^2'만 남은 상태)인데 개별 발문 첫 문단에 실제 공통 지시문이 남아 있으면 지시문을 복구한다
  assertEquals(commonStemFix('36=2^{2}\\times3^{2}', tableStem), {
    stem: '15=3\\times5[표시작]×|1[표끝]',
    commonStem: '다음 표의 빈칸에 알맞은 수를 써넣어라.',
  });
  assertEquals(commonStemFix('36', '36\n480'), null);
  assert(isCorruptedCommonStem('36'));
  assert(isCorruptedCommonStem('36=2^{2}\\times3^{2}'));
  assert(!isCorruptedCommonStem('다음 수의 약수의 개수를 구하여라.'));
  assert(!isCorruptedCommonStem(''));
});

Deno.test('원본 해설 전사 정리: [해설] 머리말과 문항번호·답/정답 줄 이중 추출을 제거한다', () => {
  assertEquals(
    cleanSolutionTranscribedText('16 답 $\\times$\n$\\boxed{2}$는 소수이지만, 나머지 짝수는 합성수이다.', '16', '$\\times$'),
    '$\\boxed{2}$는 소수이지만, 나머지 짝수는 합성수이다.',
  );
  assertEquals(
    cleanSolutionTranscribedText('[정답] ③\n[해설]\n$2^3=8$이므로 답은 ③이다.', '05', '③'),
    '$2^3=8$이므로 답은 ③이다.',
  );
  assertEquals(
    cleanSolutionTranscribedText('[해설] 16 답 × [문단] [해설] 2는 소수이다.', '16', '×'),
    '2는 소수이다.',
  );
  assertEquals(
    cleanSolutionTranscribedText('16 답 $\\times$', '16', '$\\times$'),
    '',
  );
});

Deno.test('그림 문항 판별: 그림 자산·[그림] 마커·AI figure 판정이 있으면 무조건 그림 문항으로 분류한다', () => {
  assert(itemHasFigures({ pb_figure_assets: [{ figure_index: 1, path: 'a.png' }], stem: 'x' }));
  assert(itemHasFigures({ pb_figure_assets: [], stem: '다음 그림에서[그림]' }));
  assert(itemHasFigures({ pb_figure_assets: [], stem: 'x' }, { issue_kind: 'figure' }));
  assert(!itemHasFigures({ pb_figure_assets: [], stem: '그림 없는 문항' }, { issue_kind: 'none', figure_ok: true }));
});

Deno.test('문제은행 문항 그림 유무: 표만 있는 문항은 그림 문항이 아니다', () => {
  const table = '다음 표를 완성하여라.[표시작]\\begin{tabular}{|c|c|}\\hline x & y \\\\ \\hline\\end{tabular}[표끝]';
  assert(!pbQuestionHasFigures({ stem: table, meta: { figure_assets: [] } }));
  assert(!pbQuestionHasFigures({ stem: table, meta: null }));
  assert(pbQuestionHasFigures({ stem: 'x', meta: { figure_assets: [{ figure_index: 1, path: 'a.png' }] } }));
  assert(pbQuestionHasFigures({ stem: '오른쪽 그림에서[그림]', meta: {} }));
  assert(pbQuestionHasFigures({ stem: 'x', meta: { common_stem: '다음 그림을 보고[그림]' } }));
});

Deno.test('빈칸형 문항 판별 및 빈칸 오판 필터링: 발문·수식의 □ 빈칸은 정상으로 보고 실제 마크업 노출만 오류로 남긴다', () => {
  assert(isFillInBlankProblem('', '90을 소인수분해 하는 과정이다. □ 안에 알맞은 수를 써넣어라.\n[그림]\n$\\Rightarrow 90 = 2 \\times \\square \\times 5$'));
  assert(isFillInBlankProblem('다음 표의 빈칸에 알맞은 수를 써넣어라.', '15=3\\times5'));
  assert(!isFillInBlankProblem('', '다음 수를 소인수분해하여라. 90'));

  assert(
    isFalseBlankComplaint(
      true,
      '도형 외에 용도가 불명확한 빈칸이 추가됨',
      '결론 식 위에 단독 빈칸이 하나 더 보입니다. 아래 수형도 안에는 실제 답을 쓰는 빈칸 두 개가 따로 있어, 학생은 위쪽 빈칸에 무엇을 써야 하는지 알 수 없습니다.',
    ),
  );
  // 실제 [[공백:1]] 마크업 글자 노출은 진짜 오류다
  assert(!isFalseBlankComplaint(true, '마크업 노출', '화면에 [[공백:1]] 글자가 그대로 보입니다.'));
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

Deno.test('수학만 다시 풀 대상은 수학 오류 문항뿐이다', () => {
  assert(isMathResolveTarget({ math_status: 'issue', ai_solution: 'x' }));
  assert(!isMathResolveTarget({ math_status: 'approved' }));
  assert(!isMathResolveTarget({ math_status: 'clean' }));
  assert(!isMathResolveTarget({ math_status: 'pending' }));
  assert(!isMathResolveTarget({}));
});

Deno.test('정답 대조 해설: 직접 고친 해설 → 이번 Vision 전사 → 저장된 Vision 전사', () => {
  const vision = { found: true, solution_transcribed: ' 새 전사 ', solution_answer: ' ③ ' };
  // 직접 고친 해설은 이번 전사보다 우선한다
  assertEquals(
    effectiveSolution({ solution_source: 'manual', solution_transcribed: '직접', solution_answer: '②' }, vision),
    { text: '직접', answer: '②' },
  );
  assertEquals(effectiveSolution({ solution_source: 'textbook_vision', solution_transcribed: '옛 전사' }, vision), {
    text: '새 전사',
    answer: '③',
  });
  // 이번에 해설 이미지를 안 보냈거나 못 읽었으면 저장된 전사로 3자 대조한다
  const stored = { solution_source: 'textbook_vision', solution_transcribed: '옛 전사', solution_answer: '$\\times$' };
  assertEquals(effectiveSolution(stored, undefined), { text: '옛 전사', answer: '$\\times$' });
  assertEquals(effectiveSolution(stored, { found: false, solution_transcribed: '' }), { text: '옛 전사', answer: '$\\times$' });
  assertEquals(effectiveSolution({ solution_source: 'textbook_vision', solution_transcribed: '답 없음', solution_answer: ' ' }, undefined), {
    text: '답 없음',
    answer: null,
  });
  assertEquals(effectiveSolution({}, undefined), null);
  assertEquals(effectiveSolution({ solution_source: 'manual', solution_transcribed: '  ' }, undefined), null);
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

Deno.test('해설 전체 페이지 폴백 이미지 파싱 및 답만 있는 해설 문항(isReviewTodo) 판별', () => {
  const id = '00000000-0000-4000-8000-000000000001';
  const parsed = parseReviewImages({
    [id]: {
      solution_page_image_base64: 'aGVsbG8=',
      solution_page_image_mime: 'image/png',
      solution_page_raw_page: 4,
    },
  });
  assertEquals(parsed.get(id)?.solutionPageImageDataUrl, 'data:image/png;base64,aGVsbG8=');
  assertEquals(parsed.get(id)?.solutionPageRawPage, 4);

  // 해설지에 풀이 없이 정답만 인쇄된 문항(solution_answer 가 있으면 이미 전사된 것으로 본다)
  assertEquals(
    isReviewTodo({
      math_status: 'clean',
      ai_solution: '풀이',
      has_solution_ref: true,
      solution_transcribed: null,
      solution_answer: '$-4$',
      quality_checks: {},
    }, false),
    false,
  );
});

Deno.test('렌더 엔진 문법 정규화(sanitizeProblemMarkup)와 데이터 수정 가능 증상(isDataFixableSymptom) 판별', () => {
  // 1) 삼중 대괄호 공백 마커 → 단일 대괄호 빈칸 [[공백:N]]
  assertEquals(
    sanitizeProblemMarkup('두 수의 [ [[공백:3]] ]의 합에 [ [[공백:2]] ]인 부호를 붙인다.'),
    '두 수의 [[공백:3]]의 합에 [[공백:2]]인 부호를 붙인다.',
  );
  // 2) 수식 블록 안 날한글 라벨 (가)~(라) → \text{(가)}
  assertEquals(
    sanitizeProblemMarkup('\\begin{aligned}\n& = (-7) \\leftarrow (가) \\\\\n& = -10 \\leftarrow (나)\n\\end{aligned}'),
    '\\begin{aligned}\n& = (-7) \\leftarrow \\text{(가)} \\\\\n& = -10 \\leftarrow \\text{(나)}\n\\end{aligned}',
  );
  // 3) \text{box{~~}} → box{~~}
  assertEquals(sanitizeProblemMarkup('= \\text{box{~~}}'), '= box{~~}');

  // 본문 수정으로 해결 가능한 증상은 engine 이 아니라 data 로 분류해야 한다
  assert(isDataFixableSymptom('빈칸 마크업이 이중 대괄호로 노출됨', '[[ ]] 형태로 표시됨', '빈칸 마크업 노출'));
  assert(isDataFixableSymptom('계산 단계의 한글 표지 누락', '(가), (나)가 빈 괄호로 보임', null));
  assert(isDataFixableSymptom(null, null, '저장된 common_stem 대신 개별 계산식을 표시하여 공통 지시문이 누락되고 계산식이 두 번 표시됨.'));
  assert(!isDataFixableSymptom('분수 기호 세로 겹침', '분자와 분모가 겹쳐 보임', '분수 겹침', '\\frac{1}{2}', ''));
});

Deno.test('그림 문항은 원본과 대조해 크기 비율·위치가 맞을 때만 1차 검수를 통과한다', () => {
  assert(figureReviewVerdict({ hasFigures: false, originalCompared: false, positionOk: null, sizeRatio: null }).verified);

  const ok = figureReviewVerdict({ hasFigures: true, originalCompared: true, positionOk: true, sizeRatio: 1.04 });
  assertEquals([ok.verified, ok.sizeRatio, ok.issueTitle], [true, 1.04, null]);

  const big = figureReviewVerdict({ hasFigures: true, originalCompared: true, positionOk: true, sizeRatio: 1.8 });
  assertEquals([big.verified, big.sizeRatio], [false, 1.8]);
  assert(big.issueTitle?.includes('1.8'));

  assertEquals(figureReviewVerdict({ hasFigures: true, originalCompared: true, positionOk: false, sizeRatio: 1 }).verified, false);
  assertEquals(figureReviewVerdict({ hasFigures: true, originalCompared: true, positionOk: true, sizeRatio: null }).verified, false);

  const noOriginal = figureReviewVerdict({ hasFigures: true, originalCompared: false, positionOk: true, sizeRatio: 1 });
  assertEquals([noOriginal.verified, noOriginal.sizeRatio], [false, null]);
});


