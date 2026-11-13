import { assert, assertEquals, assertNotEquals } from 'jsr:@std/assert@1';
import {
  answerAgreement,
  answerNumbers,
  checkItemConsistency,
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
