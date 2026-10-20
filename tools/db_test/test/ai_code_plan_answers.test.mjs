// 조율본 질문에 답하면: 고른 보기의 단계만 지시에 남고, 고르지 않은 분기와 답 대기 조건은 이력으로만 남는다.
// 회차마다 q1부터 다시 세는 질문 id도 답이 덮이지 않는다.
import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { openAiTestDb } from '../harness.mjs';

let t;
let C;

before(async () => {
  t = await openAiTestDb();
  await t.exec(`update ai_platform_settings set code_request_daily_limit = 100`);
  C = (await t.one(`insert into ai_conversations (title) values ('c') returning id`)).id;
});
after(() => t?.close());

const planCard = async (spec) => {
  const planReq = (await t.one(
    `insert into ai_code_requests (conversation_id, title, request, mode, status, max_rounds)
     values ($1, '조율', '{"goal":"g"}'::jsonb, 'plan', 'ready', 1) returning id`,
    [C],
  )).id;
  const id = (await t.one(
    `insert into ai_actions (conversation_id, kind, payload) values ($1, 'code_change', $2::jsonb) returning id`,
    [C, JSON.stringify({ title: '비교 준비', plan_request_id: planReq, spec })],
  )).id;
  return { id, planReq };
};
const revise = (id, answers) =>
  t.asSuperadmin(() => t.one(`select * from ai_code_plan_revise($1, $2::jsonb)`, [id, JSON.stringify(answers)]));

const FIRST = {
  goal: '원본 비교 준비',
  instructions: ['공통 입력 파일을 만든다', '축소안 승인 시 gateway/test에 시험만 추가한다'],
  constraints: ['산출물 범위는 운영자 답변 전 확정하지 않는다', '운영 DB에 연결하지 않는다'],
  checks: [{ cwd: 'gateway', command: 'node --test test/', why: '시험' }],
  decisions: [
    {
      id: 'q1',
      kind: 'owner',
      question: '산출물 범위를 줄일까요?',
      context: '',
      holds: ['산출물 범위는 운영자 답변 전 확정하지 않는다'],
      options: [
        { id: 'q1_1', label: '전체 유지', detail: '비교 준비까지', recommended: true, instructions: ['비교 준비 스크립트를 만든다'] },
        { id: 'q1_2', label: '축소', detail: '시험만', recommended: false, instructions: ['축소안 승인 시 gateway/test에 시험만 추가한다'] },
      ],
    },
  ],
};

test('답하면 고른 보기의 단계만 붙고, 버린 분기와 대기 조건은 이력으로만 남는다', async () => {
  const { id, planReq } = await planCard(FIRST);
  const row = await revise(id, [{ id: 'q1', option_id: 'q1_1' }]);
  const spec = row.payload.spec;
  assert.deepEqual(spec.instructions, ['공통 입력 파일을 만든다', '비교 준비 스크립트를 만든다']);
  assert.deepEqual(spec.constraints, ['운영 DB에 연결하지 않는다', '운영자 결정 — 산출물 범위를 줄일까요?: 전체 유지']);
  assert.equal(spec.decisions, undefined);
  assert.deepEqual(spec.checks, FIRST.checks, '필수 검사는 그대로 이어진다');
  assert.equal(spec.owner_answers.length, 1);
  assert.deepEqual(
    { ...spec.owner_answers[0] },
    { id: 'q1', plan_request_id: planReq, answer_round: 1, question: '산출물 범위를 줄일까요?', answer: '전체 유지', option_id: 'q1_1', detail: '비교 준비까지', custom: false },
  );
  assert.deepEqual(spec.discarded_branches.map((d) => d.kind), ['option', 'hold']);
  assert.deepEqual(spec.discarded_branches[0].instructions, ['축소안 승인 시 gateway/test에 시험만 추가한다']);
  const req = await t.one(`select request, mode, max_rounds from ai_code_requests where id = $1`, [row.result.code_request_id]);
  assert.deepEqual(req.request, spec);
  const old = await t.one(`select status, superseded, result from ai_actions where id = $1`, [id]);
  assert.equal(old.status, 'rejected');
  assert.equal(old.superseded, true);
  assert.equal(old.result.discarded.length, 2);
});

test('두 번 연달아 답해도 같은 q1 답이 덮이지 않고, 같은 결정 줄은 한 번만 남는다', async () => {
  const first = await planCard(FIRST);
  const spec1 = (await revise(first.id, [{ id: 'q1', option_id: 'q1_1' }])).payload.spec;
  const second = await planCard({
    ...spec1,
    instructions: [...spec1.instructions, '운영자가 이미지 묶음을 선택하면 PNG 쌍을 만든다'],
    constraints: [...spec1.constraints, '비교 형태는 운영자 답변 후 확정한다'],
    decisions: [
      {
        id: 'q1',
        kind: 'owner',
        question: '비교 결과를 어떤 형태로 받을까요?',
        context: '',
        holds: ['비교 형태는 운영자 답변 후 확정한다'],
        options: [
          { id: 'q1_1', label: '이미지 묶음', detail: '', recommended: true, instructions: ['페이지별 PNG 쌍과 목록 파일을 만든다'] },
          { id: 'q1_2', label: '뷰어용 목록', detail: '', recommended: false, instructions: ['운영자가 이미지 묶음을 선택하면 PNG 쌍을 만든다', '기존 뷰어용 CSV를 만든다'] },
        ],
      },
    ],
  });
  const spec2 = (await revise(second.id, [{ id: 'q1', text: '이미지 묶음으로, 파일 이름은 페이지 번호' }])).payload.spec;
  assert.equal(spec2.owner_answers.length, 2);
  assert.deepEqual(spec2.owner_answers.map((a) => [a.id, a.plan_request_id, a.answer_round]), [
    ['q1', first.planReq, 1],
    ['q1', second.planReq, 2],
  ]);
  assert.equal(spec2.owner_answers[1].answer, '이미지 묶음으로, 파일 이름은 페이지 번호');
  assert.equal(spec2.owner_answers[1].custom, true);
  assert.deepEqual(spec2.instructions, ['공통 입력 파일을 만든다', '비교 준비 스크립트를 만든다'], '직접 답하면 어느 보기의 단계도 붙지 않는다');
  assert.ok(!spec2.constraints.includes('비교 형태는 운영자 답변 후 확정한다'));
  assert.equal(spec2.constraints.filter((c) => c === '운영자 결정 — 산출물 범위를 줄일까요?: 전체 유지').length, 1);
  assert.ok(spec2.constraints.includes('운영자 결정 — 비교 결과를 어떤 형태로 받을까요?: 이미지 묶음으로, 파일 이름은 페이지 번호'));
  assert.equal(spec2.discarded_branches.length, 2 + 3);
});

test('예전 모양(보기 단계·holds 없음)의 조율본도 그대로 답할 수 있다', async () => {
  const { id } = await planCard({
    goal: 'g',
    instructions: ['a'],
    constraints: ['c'],
    decisions: [{ id: 'q1', kind: 'owner', question: '할까요?', context: '', options: [{ id: 'q1_1', label: '예', detail: '' }, { id: 'q1_2', label: '아니오', detail: '' }] }],
  });
  const spec = (await revise(id, [{ id: 'q1', option_id: 'q1_2' }])).payload.spec;
  assert.deepEqual(spec.instructions, ['a']);
  assert.deepEqual(spec.constraints, ['c', '운영자 결정 — 할까요?: 아니오']);
  assert.deepEqual(spec.discarded_branches, []);
  await t.asSuperadmin(() => t.rejects(`select ai_code_plan_revise($1, '[]'::jsonb)`, [id], /action_not_pending/));
});
