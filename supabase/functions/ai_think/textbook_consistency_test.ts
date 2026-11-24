import { assert, assertEquals, assertNotEquals } from 'jsr:@std/assert@1';
import {
  answerAgreement,
  answerNumbers,
  checkItemConsistency,
  fixTabularRowEnds,
  hasRenderBreakingMarkup,
  issueSignature,
  mathDelimiterProblems,
  setCommonFigureMap,
} from './textbook_consistency.ts';

type Rec = Record<string, unknown>;

const asset = (i: number) => ({ id: `fig-${i}`, figure_index: i, path: `p/${i}.png` });

function item(over: Rec = {}): Rec {
  return {
    crop_id: 'c1',
    pb_question_id: 'q1',
    problem_number: '07',
    stem: '다음 수의 약수를 모두 구하여라.',
    common_stem: '',
    choices: [],
    pb_figure_assets: [],
    existing_answer: '1, 2, 4',
    solution_answer: '1, 2, 4',
    ai_answer: '1, 2, 4',
    solution_transcribed: '4의 약수는 1, 2, 4이다.',
    math_status: 'approved',
    quality_status: 'approved',
    staged_changes: {},
    ...over,
  };
}

const ok = { setHasCommonFigure: false };
const codes = (r: { issues: Array<{ code: string }> }) => r.issues.map((i) => i.code).sort();
const fixCodes = (r: { fixes: Array<{ code: string }> }) => r.fixes.map((f) => f.code).sort();

Deno.test('정상 문항은 고칠 것도 지적도 없다', () => {
  const r = checkItemConsistency(item(), ok);
  assertEquals(r.patch, {});
  assertEquals(r.issues, []);
});

Deno.test('공통 발문이 개별 발문 앞머리에 다시 들어 있으면 개별 발문에서 뺀다', () => {
  const r = checkItemConsistency(
    item({ common_stem: '다음을 계산하여라.', stem: '다음을 계산하여라.\n[문단]\n(-32) \\div 8 \\times (-5)' }),
    ok,
  );
  assertEquals(r.patch, { stem: '(-32) \\div 8 \\times (-5)' });
  assertEquals(fixCodes(r), ['common_stem_duplicate']);
});

Deno.test('공통 발문에 개별 본문이 통째로 들어 있으면 공통 발문을 지시문만 남기고 줄인다', () => {
  const body = 'x=8일 때, y=2';
  const instr = 'y가 x에 정비례하고 다음 조건을 만족시킬 때, x와 y 사이의 관계식을 구하여라.';
  const r = checkItemConsistency(item({ common_stem: `${instr}\n[문단]\n${body}`, stem: `${instr}\n[문단]\n${body}` }), ok);
  assertEquals(r.patch, { stem: body, common_stem: instr });
});

Deno.test('공통 발문을 원래 없던 글(개별 본문)로 바꾸는 복구는 자동으로 하지 않는다', () => {
  const r = checkItemConsistency(
    item({
      common_stem: '그림에 대한 설명으로 옳은 것은 ○표, 옳지 않은 것은 ×표를 (   ) 안에 써넣어라.[문단][그림]',
      stem: '$\\angle g$의 동위각은 $\\angle c$, $\\angle k$이고 엇각은 $\\angle i$이다.[문단]([공백:2])',
      pb_figure_assets: [asset(1)],
    }),
    ok,
  );
  assertEquals(r.patch, {});
  assertEquals(r.issues, []);
});

Deno.test('사장님이 고친 항목은 코드 점검도 덮어쓰지 않는다', () => {
  const r = checkItemConsistency(
    item({
      common_stem: '다음을 계산하여라.',
      stem: '다음을 계산하여라.\n[문단]\n(-32) \\div 8',
      staged_changes: { stem: '다음을 계산하여라.\n[문단]\n(-32) \\div 8', sources: { stem: 'owner' } },
    }),
    ok,
  );
  assertEquals(r.patch, {});
});

Deno.test("세트 문항의 '해' 풀이 안내는 지우고, 안내 안에 그림 자리가 있으면 지적만 한다", () => {
  const guided = checkItemConsistency(
    item({
      common_stem: '오른쪽 그림에서 l//m일 때, 다음을 구하여라.',
      stem: '[그림]\n[문단]\n해 $l\\parallel m$이므로 $box{~~}$의 크기는 같다.',
      pb_figure_assets: [asset(1)],
    }),
    ok,
  );
  assertEquals(guided.patch, { stem: '[그림]' });
  assertEquals(fixCodes(guided), ['guide_residue']);
  assertEquals(guided.issues, []);

  const withFigure = checkItemConsistency(
    item({ stem: '다음을 구하여라.\n[문단]\n해 [그림]과 같이 box{~~}이다.', pb_figure_assets: [asset(1)] }),
    ok,
  );
  assertEquals(withFigure.patch, {});
  assertEquals(codes(withFigure), ['guide_with_figure']);
});

Deno.test('엔진이 못 읽는 마크업만 고치고, 빈 네모(\\boxed{\\phantom{}})는 그대로 둔다', () => {
  assert(hasRenderBreakingMarkup('\\text{box{~~}} 안에 알맞은 수'));
  assert(!hasRenderBreakingMarkup('\\boxed{\\phantom{0}} 안에 알맞은 수'));
  const r = checkItemConsistency(item({ stem: '\\text{box{~~}} 안에 알맞은 수를 써넣어라.' }), ok);
  assertEquals(r.patch, { stem: 'box{~~} 안에 알맞은 수를 써넣어라.' });
  assertEquals(checkItemConsistency(item({ stem: '\\boxed{\\phantom{0}} 안에 알맞은 수를 써넣어라.' }), ok).patch, {});
});

Deno.test('해설 칸에 정답 줄만 있으면 비우고, 직접 입력한 해설은 두지 않는다', () => {
  const answerOnly = item({ solution_transcribed: '답 $4, 8, 12$', solution_answer: '4, 8, 12', existing_answer: '4, 8, 12' });
  const r = checkItemConsistency(answerOnly, ok);
  assertEquals(r.patch, { solution_transcribed: '' });
  assertEquals(fixCodes(r), ['solution_text']);
  assertEquals(checkItemConsistency({ ...answerOnly, solution_source: 'manual' }, ok).patch, {});
});

Deno.test('그림 수와 그림 자리가 다르면 지적한다(그림 선지는 선지가 자리다)', () => {
  assertEquals(codes(checkItemConsistency(item({ stem: '[그림]에서 x의 값', pb_figure_assets: [asset(1), asset(2)] }), ok)), [
    'figure_slots',
  ]);
  assertEquals(codes(checkItemConsistency(item({ stem: '[그림]에서 [도형]의 넓이', pb_figure_assets: [asset(1)] }), ok)), [
    'figure_slots',
  ]);
  assertEquals(checkItemConsistency(item({ stem: '[그림]에서 x의 값', pb_figure_assets: [asset(1)] }), ok).issues, []);
  const imageChoices = item({
    stem: '다음 중 옳은 그래프는?',
    choices: [1, 2, 3, 4, 5].map((n) => ({ label: `${n}`, text: '' })),
    pb_figure_assets: [1, 2, 3, 4, 5].map(asset),
    existing_answer: '②',
    solution_answer: '②',
    ai_answer: '②',
  });
  assertEquals(checkItemConsistency(imageChoices, ok).issues, []);
});

Deno.test('공통 발문에만 그림 자리가 있으면 세트에 그릴 그림이 있어야 한다', () => {
  const setItem = item({ common_stem: '[그림]과 같이 다음을 구하여라.', stem: '$\\angle x$의 크기' });
  assertEquals(codes(checkItemConsistency(setItem, ok)), ['common_figure_missing']);
  assertEquals(checkItemConsistency(setItem, { setHasCommonFigure: true }).issues, []);
  assertEquals(checkItemConsistency({ ...setItem, pb_figure_assets: [asset(1)] }, ok).issues, []);
});

Deno.test('세트 공통 그림: 세트 공통 그림이나 본문 자리 없이 그림을 가진 문항이 있으면 세트 전체가 그린다', () => {
  const common = '[그림]과 같이 다음을 구하여라.';
  const a = item({ crop_id: 'a', pb_question_id: 'qa', sub_key: 's', set_header_number: '01', common_stem: common, stem: '(1)' });
  const b = item({
    crop_id: 'b',
    pb_question_id: 'qb',
    sub_key: 's',
    set_header_number: '01',
    common_stem: common,
    stem: '(2)',
    pb_figure_assets: [asset(1)],
  });
  const c = item({ crop_id: 'c', pb_question_id: 'qc', sub_key: 't', set_header_number: '02', common_stem: common, stem: '(1)' });
  const map = setCommonFigureMap([a, b, c], new Map());
  assertEquals([map.get('a'), map.get('b'), map.get('c')], [true, true, false]);
  assertEquals(setCommonFigureMap([c], new Map([['qc', 1]])).get('c'), true);
});

Deno.test("수식 안의 '해' 안내와 짝이 안 맞는 수식 구분자를 지적한다", () => {
  assertEquals(codes(checkItemConsistency(item({ stem: '$\\text{해 } x=3$이므로 $box{~~}$' }), ok)), ['guide_text']);
  assertEquals(mathDelimiterProblems('x=$3'), ['$']);
  assertEquals(mathDelimiterProblems('\\left( x \\right) + \\begin{cases} a \\end{cases}'), []);
  assertEquals(mathDelimiterProblems('\\left( x'), ['\\left \\right']);
  assertEquals(mathDelimiterProblems('\\frac{1}{2'), ['{ }']);
  assertEquals(codes(checkItemConsistency(item({ solution_transcribed: '$x=3' }), ok)), ['math_delimiters']);
});

Deno.test('줄바꿈 명령 뒤에 붙은 괄호는 수식 구분자로 세지 않는다', () => {
  // 2024 고3 9월 평가원 미적분 30번 해설: cases 의 줄바꿈(\\) 바로 뒤가 여는 괄호다.
  const cases = '$f(x)=\\begin{cases}(k-x)e^{-x}&(x\\geq0)\\\\(k+x)e^{-x}&(x<0)\\end{cases}$';
  assertEquals(mathDelimiterProblems(cases), []);
  assertEquals(mathDelimiterProblems('$\\begin{aligned}a&=1\\\\[2pt]b&=2\\\\{c}&=3\\end{aligned}$'), []);
  assertEquals(codes(checkItemConsistency(item({ solution_transcribed: cases }), ok)), []);
  // 진짜로 짝이 안 맞는 \( 는 그대로 잡는다.
  assertEquals(mathDelimiterProblems('\\(x=3'), ['\\( \\)']);
  assertEquals(mathDelimiterProblems('a\\\\ \\(x=3'), ['\\( \\)']);
});

Deno.test('정답 번호가 선지 수보다 크면 지적한다', () => {
  const choices = [1, 2, 3, 4].map((n) => ({ label: `${n}`, text: `${n}` }));
  const r = checkItemConsistency(
    item({ choices, existing_answer: '⑤', solution_answer: '⑤', ai_answer: '⑤' }),
    ok,
  );
  assertEquals(codes(r), ['answer_choice_range']);
});

Deno.test('정답 비교: 수만 보고, 셋 중 둘이 같으면 지적하지 않는다', () => {
  assertEquals(answerNumbers('1,000원, -2x^2y/z'), ['1000', '2', '2']);
  assertEquals(answerAgreement('6, 9', '$-9$', ''), 'agree');
  assertEquals(answerAgreement('$-\\frac{2x^2y}{z}$', '-2x^2y/z', ''), 'agree');
  assertEquals(answerAgreement('1', '13', '1'), 'majority');
  assertEquals(answerAgreement('1', '13', '7'), 'conflict');

  const conflict = item({ existing_answer: '1', solution_answer: '13', ai_answer: '7' });
  assertEquals(codes(checkItemConsistency(conflict, ok)), ['answer_conflict']);
  assertEquals(checkItemConsistency({ ...conflict, answer_manual: true }, ok).issues, []);
  assertEquals(checkItemConsistency({ ...conflict, math_status: 'issue' }, ok).issues, []);
  assertEquals(checkItemConsistency({ ...conflict, ai_answer: '1' }, ok).issues, []);
});

Deno.test('"문제 없음"으로 닫은 지적은 문항 내용이 같으면 같은 서명이다', () => {
  const it = item({ stem: '[그림]에서 x의 값', pb_figure_assets: [asset(1), asset(2)] });
  const issue = checkItemConsistency(it, ok).issues[0];
  assertEquals(issueSignature(it, issue), issueSignature({ ...it }, issue));
  assertNotEquals(issueSignature(it, issue), issueSignature({ ...it, stem: '[그림]에서 y의 값' }, issue));
});

// ── 모의고사 문항에만 거는 표기 규칙 ─────────────────────────────────────────

const mock = (choiceNumberRegion: unknown = null) => ({ setHasCommonFigure: false, mock: { choiceNumberRegion } });
const fiveChoices = () => ['①', '②', '③', '④', '⑤'].map((label, i) => ({ label, text: String(i + 1) }));

function mockItem(over: Rec = {}): Rec {
  return item({
    problem_number: '13',
    stem: '점 P에서 선분 AB에 내린 수선의 발을 H라 할 때, \\overline{PH}의 값은?',
    choices: fiveChoices(),
    existing_answer: '③',
    solution_answer: '③',
    ai_answer: '③',
    solution_transcribed: '출제의도 : 수선의 길이를 구할 수 있는가?\n\n점 P에서 $\\overline{PH}=3$',
    ...over,
  });
}

Deno.test('모의고사: 점 이름을 곧은 글자로 감싸고 출제의도 머리를 [출제의도] 로 맞춘다', () => {
  const r = checkItemConsistency(mockItem(), mock());
  assertEquals(r.patch, {
    stem: '점 \\text{P}에서 선분 \\text{AB}에 내린 수선의 발을 \\text{H}라 할 때, \\overline{\\text{PH}}의 값은?',
    solution_transcribed: '[출제의도] 수선의 길이를 구할 수 있는가?\n\n점 $\\mathrm{P}$에서 $\\overline{\\mathrm{PH}}=3$',
  });
  assertEquals(fixCodes(r), ['intent_mark', 'point_names', 'point_names']);
  assertEquals(r.issues, []);
  // 고친 값을 다시 점검하면 더 고칠 것이 없다.
  const again = checkItemConsistency(mockItem(r.patch), mock());
  assertEquals(again.patch, {});
  assertEquals(again.fixes, []);
});

Deno.test('모의고사: 선지의 이름도 본문에서 점으로 쓴 이름이면 감싼다', () => {
  const choices = [
    { label: '①', text: '\\overline{AB}' },
    { label: '②', text: 'AB=AC' },
    { label: '③', text: '3' },
  ];
  const r = checkItemConsistency(
    mockItem({ stem: '삼각형 \\text{ABC}에서 옳은 것은?', choices, solution_transcribed: '', existing_answer: '①', solution_answer: '①', ai_answer: '①' }),
    mock(),
  );
  assertEquals(r.patch, {
    choices: [
      { label: '①', text: '\\overline{\\text{AB}}' },
      { label: '②', text: '\\text{AB}=\\text{AC}' },
      { label: '③', text: '3' },
    ],
  });
  assertEquals(fixCodes(r), ['point_names']);
});

Deno.test('모의고사가 아닌 문항(교재·내신)에는 표기 규칙을 걸지 않는다', () => {
  const r = checkItemConsistency(mockItem(), ok);
  assertEquals(r.patch, {});
  assertEquals(r.fixes, []);
});

Deno.test('모의고사: 사장님이 고친 본문·해설과 직접 입력한 해설은 바꾸지 않는다', () => {
  const staged = { staged_changes: { sources: { stem: 'owner', solution_transcribed: 'owner' } } };
  assertEquals(checkItemConsistency(mockItem(staged), mock()).patch, {});
  const ownerStem = checkItemConsistency(mockItem({ staged_changes: { sources: { stem: 'owner' } } }), mock());
  assertEquals(Object.keys(ownerStem.patch), ['solution_transcribed']);
  const manual = checkItemConsistency(mockItem({ solution_source: 'manual' }), mock());
  assertEquals(Object.keys(manual.patch), ['stem']);
});

Deno.test('모의고사: 원 O·넓이 A 처럼 기울여 찍는 이름과 식 안의 변수는 그대로 둔다', () => {
  const stem = '세 점을 지나는 원을 O라 하자. 넓이를 A라 할 때 \\sin B의 값은?';
  const r = checkItemConsistency(mockItem({ stem, solution_transcribed: '[출제의도] 넓이를 구한다.\n\n$A=3$' }), mock());
  assertEquals(r.patch, {});
});

Deno.test('모의고사: 수식 뒤에 띄어 쓴 조사를 본문·선지·해설에서 붙인다', () => {
  const r = checkItemConsistency(
    mockItem({
      // '\text{A} 와' 는 수식 기호 옆 띄어쓰기만 달라 sameRenderedMath 로는 같은 본문이지만, 찍히는 모양이 다르므로 써야 한다.
      stem: '과목 \\text{A} 와 과목 \\text{B} 를 선택한 학생은 f(x) 의 값이다.',
      choices: [
        { label: '①', text: '3 명' },
        { label: '②', text: '4 명' },
        { label: '③', text: '5' },
      ],
      solution_transcribed: '[출제의도] 값을 구한다.\n\n$f(1)=3$ 이므로 $a=2$',
    }),
    mock(),
  );
  assertEquals(r.patch, {
    stem: '과목 \\text{A}와 과목 \\text{B}를 선택한 학생은 f(x)의 값이다.',
    choices: [
      { label: '①', text: '3명' },
      { label: '②', text: '4명' },
      { label: '③', text: '5' },
    ],
    solution_transcribed: '[출제의도] 값을 구한다.\n\n$f(1)=3$이므로 $a=2$',
  });
  assertEquals(fixCodes(r), ['particle_spacing', 'particle_spacing']);
  assertEquals(r.fixes.map((f) => f.fields), [['stem', 'choices'], ['solution_transcribed']]);
  const again = checkItemConsistency(mockItem(r.patch), mock());
  assertEquals(again.patch, {});
  assertEquals(again.fixes, []);
});

Deno.test('모의고사: 조사 붙여 쓰기도 사장님이 고친 칸과 교재·내신 문항은 건드리지 않는다', () => {
  const over = {
    stem: '함수 f(x) 의 값은?',
    solution_transcribed: '[출제의도] 값을 구한다.\n\n$f(1)=3$ 이므로',
  };
  const owner = checkItemConsistency(
    mockItem({ ...over, staged_changes: { sources: { stem: 'owner', solution_transcribed: 'owner' } } }),
    mock(),
  );
  assertEquals(owner.patch, {});
  const notMock = checkItemConsistency(mockItem(over), ok);
  assertEquals(notMock.patch, {});
  assertEquals(notMock.fixes, []);
});

const layout = (position: string, extra: Rec = {}) => ({
  version: 1,
  groups: [],
  items: [{ assetKey: 'idx:1', widthEm: 12, position, anchor: 'center', offsetXEm: 0, offsetYEm: 0 }],
  ...extra,
});

/** 시험지 5쪽의 문항: 선지 번호 글자는 y 282~292, 그림은 그 아래(y 329~522) */
const FIGURE_STEM = '그림과 같이 두 곡선으로 둘러싸인 부분의 넓이는?';

function figureItem(over: Rec = {}): Rec {
  return mockItem({
    stem: FIGURE_STEM,
    solution_transcribed: '',
    raw_page: 5,
    item_region_1k: [134, 105, 518, 478],
    pb_figure_assets: [{ ...asset(1), bbox_1k: [329, 224, 522, 374], source_page: 5 }],
    pb_figure_layout: layout('below-stem'),
    ...over,
  });
}

const CHOICE_REGION = [282, 120, 292, 440];

Deno.test('모의고사: 원본에서 선지 아래에 있는 그림은 선지 아래 배치로 보낸다', () => {
  const marked = { stem: `${FIGURE_STEM}\n[그림]` };
  const r = checkItemConsistency(figureItem(marked), mock(CHOICE_REGION));
  assertEquals(r.patch, { figure_layout: layout('below-choices') });
  assertEquals(fixCodes(r), ['figure_below_choices']);
  assertEquals(codes(r), []);
  // 이미 선지 아래인 그림은 다시 고치지 않는다.
  const again = checkItemConsistency(figureItem({ ...marked, pb_figure_layout: layout('below-choices') }), mock(CHOICE_REGION));
  assertEquals(again.patch, {});
  // 보기 2단 같은 다른 배치 값은 그대로 가져간다.
  const kept = checkItemConsistency(
    figureItem({ ...marked, pb_figure_layout: layout('below-stem', { bogiColumns: 2 }) }),
    mock(CHOICE_REGION),
  );
  assertEquals(kept.patch, { figure_layout: layout('below-choices', { bogiColumns: 2 }) });
});

Deno.test('모의고사: 선지 아래 그림인데 본문에 그림 자리가 없으면 본문 끝에 자리를 넣는다', () => {
  // 2026 고3 6월 기하 27: 추출이 선지 아래 그림의 자리를 본문에 적지 않았다.
  const r = checkItemConsistency(figureItem(), mock(CHOICE_REGION));
  assertEquals(r.patch, { stem: `${FIGURE_STEM}\n[그림]`, figure_layout: layout('below-choices') });
  assertEquals(fixCodes(r), ['figure_below_choices', 'figure_marker_below_choices']);
  assertEquals(codes(r), []);
  // 반영 대기 값을 겹쳐 다시 점검하면 더 고칠 것이 없다.
  const again = checkItemConsistency(
    figureItem({ stem: r.patch.stem, pb_figure_layout: r.patch.figure_layout }),
    mock(CHOICE_REGION),
  );
  assertEquals(again.patch, {});
  assertEquals(codes(again), []);

  // 그림 둘: 본문에 자리가 있는 첫 그림은 그대로, 자리가 없는 둘째 그림(선지 아래)만 자리를 받는다.
  const two = checkItemConsistency(
    figureItem({
      stem: `[그림]\n${FIGURE_STEM}`,
      pb_figure_assets: [
        { ...asset(1), bbox_1k: [150, 224, 240, 374], source_page: 5 },
        { ...asset(2), bbox_1k: [329, 224, 522, 374], source_page: 5 },
      ],
      pb_figure_layout: twoLayout('below-stem'),
    }),
    mock(CHOICE_REGION),
  );
  assertEquals(two.patch, { stem: `[그림]\n${FIGURE_STEM}\n[그림]`, figure_layout: twoLayout('below-choices') });
  assertEquals(codes(two), []);

  // 이미 선지 아래 배치인 그림(배치는 고칠 것이 없다)도 자리만 넣는다.
  const placed = checkItemConsistency(figureItem({ pb_figure_layout: layout('below-choices') }), mock(CHOICE_REGION));
  assertEquals(placed.patch, { stem: `${FIGURE_STEM}\n[그림]` });
  assertEquals(codes(placed), []);
});

const twoLayout = (second: string) => ({
  version: 1,
  groups: [],
  items: [
    { assetKey: 'idx:1', widthEm: 10, position: 'below-stem', anchor: 'center' },
    { assetKey: 'idx:2', widthEm: 12, position: second, anchor: 'center' },
  ],
});

Deno.test('모의고사: 선지 아래가 아닌 그림, 사장님이 고친 본문, 교재 문항에는 그림 자리를 넣지 않는다', () => {
  // 그림이 선지보다 위: 자리를 모르므로 지적으로 남긴다.
  const above = checkItemConsistency(
    figureItem({ pb_figure_assets: [{ ...asset(1), bbox_1k: [180, 224, 270, 374], source_page: 5 }] }),
    mock(CHOICE_REGION),
  );
  assertEquals(above.patch, {});
  assertEquals(codes(above), ['figure_slots']);
  // 선지 자리를 읽지 못했다.
  const noRegion = checkItemConsistency(figureItem(), mock());
  assertEquals(noRegion.patch, {});
  assertEquals(codes(noRegion), ['figure_slots']);
  // 사장님이 고친 본문
  const owner = checkItemConsistency(figureItem({ staged_changes: { sources: { stem: 'owner' } } }), mock(CHOICE_REGION));
  assertEquals(owner.patch, { figure_layout: layout('below-choices') });
  assertEquals(codes(owner), ['figure_slots']);
  // 선지 아래에 있지만 배치가 선지 아래가 아닌 그림(글 줄 안 그림, 사장님이 정한 배치)
  const inline = checkItemConsistency(figureItem({ pb_figure_layout: layout('inline-text') }), mock(CHOICE_REGION));
  assertEquals(inline.patch, {});
  assertEquals(codes(inline), ['figure_slots']);
  const ownerLayout = checkItemConsistency(
    figureItem({ staged_changes: { sources: { figure_layout: 'owner' } } }),
    mock(CHOICE_REGION),
  );
  assertEquals(ownerLayout.patch, {});
  assertEquals(codes(ownerLayout), ['figure_slots']);
  // 교재·내신 문항
  const notMock = checkItemConsistency(figureItem(), ok);
  assertEquals(notMock.patch, {});
  assertEquals(codes(notMock), ['figure_slots']);
});

Deno.test('모의고사: 선지 위의 그림, 근거가 없는 그림은 옮기지 않는다', () => {
  const noPatch = (it: Rec, region: unknown = CHOICE_REGION) => assertEquals(checkItemConsistency(it, mock(region)).patch, {});
  // 그림이 선지보다 위
  noPatch(figureItem({ pb_figure_assets: [{ ...asset(1), bbox_1k: [180, 224, 270, 374], source_page: 5 }] }));
  // 선지 번호 자리를 읽지 못함(null), 번호 글자가 없음([])
  noPatch(figureItem(), null);
  noPatch(figureItem(), []);
  // 선지 자리가 문항 영역 밖(문항 영역을 다시 잡은 뒤 아직 다시 읽지 않음)
  noPatch(figureItem(), [600, 120, 610, 440]);
  // 그림이 다른 쪽에서 잘렸거나 그림 영역을 모름
  noPatch(figureItem({ pb_figure_assets: [{ ...asset(1), bbox_1k: [329, 224, 522, 374], source_page: 6 }] }));
  noPatch(figureItem({ pb_figure_assets: [asset(1)] }));
  // 그림이 이 문항 영역 밖(옆 단)
  noPatch(figureItem({ pb_figure_assets: [{ ...asset(1), bbox_1k: [329, 600, 522, 800], source_page: 5 }] }));
  // 문항 영역을 모름
  noPatch(figureItem({ item_region_1k: null }));
  // 주관식(선지 없음)과 그림 선지
  noPatch(figureItem({ choices: [] }));
  // 글 줄 안 그림, 가로로 묶인 그림
  noPatch(figureItem({ pb_figure_layout: layout('inline-text') }));
  noPatch(figureItem({ pb_figure_layout: layout('below-stem', { groups: [{ type: 'horizontal', members: ['idx:1', 'idx:2'] }] }) }));
  // 사장님이 그림 배치를 고쳤다
  noPatch(figureItem({ staged_changes: { sources: { figure_layout: 'owner' } } }));
  // 모의고사가 아니다
  assertEquals(checkItemConsistency(figureItem(), ok).patch, {});
});

Deno.test('모의고사: 그림이 여럿이면 선지 아래에 있는 그림만 옮긴다', () => {
  const it = figureItem({
    stem: '[그림]\n[문단]\n그림과 같이 두 곡선으로 둘러싸인 부분의 넓이는?',
    pb_figure_assets: [
      { ...asset(1), bbox_1k: [150, 224, 250, 374], source_page: 5 },
      { ...asset(2), bbox_1k: [329, 224, 522, 374], source_page: 5 },
    ],
    pb_figure_layout: {
      version: 1,
      groups: [],
      items: [
        { assetKey: 'idx:1', widthEm: 10, position: 'below-stem', anchor: 'center' },
        { assetKey: 'ord:2', widthEm: 12, position: 'inline-right', anchor: 'right' },
      ],
    },
  });
  const r = checkItemConsistency(it, mock(CHOICE_REGION));
  assertEquals((r.patch.figure_layout as Rec).items, [
    { assetKey: 'idx:1', widthEm: 10, position: 'below-stem', anchor: 'center' },
    { assetKey: 'ord:2', widthEm: 12, position: 'below-choices', anchor: 'right' },
  ]);
});

// 2026 고3 9월 확통 27: 표의 줄 끝이 '\' 하나로 추출돼 문항 카드가 조판되지 않았다.
const BROKEN_TABLE = [
  '값을 오른쪽 표준정규분포표를 이용하여 구한 것은?',
  '[문단]',
  '[표시작]',
  '\\begin{tabular}{|c|c|}',
  '\\hline',
  'z & \\text{P}(0 \\leq Z \\leq z) \\',
  '\\hline',
  '0.5 & 0.1915 \\',
  '\\hline',
  '1.0 & 0.3413 \\ \\hline',
  '\\end{tabular}',
  '[표끝]',
].join('\n');
const FIXED_TABLE = [
  '값을 오른쪽 표준정규분포표를 이용하여 구한 것은?',
  '[문단]',
  '[표시작]',
  '\\begin{tabular}{|c|c|}',
  '\\hline',
  'z & \\text{P}(0 \\leq Z \\leq z) \\\\',
  '\\hline',
  '0.5 & 0.1915 \\\\',
  '\\hline',
  '1.0 & 0.3413 \\\\ \\hline',
  '\\end{tabular}',
  '[표끝]',
].join('\n');

Deno.test("표의 줄 끝이 '\\' 하나면 '\\\\' 로 고친다(교재·모의고사 공통)", () => {
  assertEquals(fixTabularRowEnds(BROKEN_TABLE), FIXED_TABLE);
  const r = checkItemConsistency(item({ stem: BROKEN_TABLE }), ok);
  assertEquals(r.patch.stem, FIXED_TABLE);
  assertEquals(fixCodes(r), ['table_row_end']);
  const m = checkItemConsistency(mockItem({ stem: BROKEN_TABLE }), mock());
  assertEquals(m.patch.stem, FIXED_TABLE);
  assert(fixCodes(m).includes('table_row_end'));
});

Deno.test('바른 표, 표 밖의 글, 사장님이 고친 본문은 그대로 둔다', () => {
  assertEquals(fixTabularRowEnds(FIXED_TABLE), FIXED_TABLE);
  // 표 밖에서는 줄 끝의 '\' 를 건드리지 않는다.
  const outside = '집합 A \\\n의 원소';
  assertEquals(fixTabularRowEnds(outside), outside);
  assertEquals(checkItemConsistency(item({ stem: FIXED_TABLE }), ok).patch, {});
  const owner = checkItemConsistency(item({ stem: BROKEN_TABLE, staged_changes: { sources: { stem: 'owner' } } }), ok);
  assertEquals(owner.patch, {});
  assertEquals(fixCodes(owner), []);
});
