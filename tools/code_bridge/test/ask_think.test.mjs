import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createBridgeClient } from '../src/bridge_client.mjs';
import {
  ASK_QUESTION_CHARS,
  ASK_THINK_LIMIT,
  ASK_TOOLS,
  READ_ONLY_TOOLS,
  askThinkAllowed,
  createAskThinkTool,
  formatAskResult,
  loadConfig,
  promptFor,
} from '../src/lib.mjs';

const env = { CODE_BRIDGE_WORKER_TOKEN: 't', CURSOR_API_KEY: 'k' };
const job = (mode) => ({ id: 'req-1', mode, title: '수업 기록 순서', request: { goal: '정렬 기준 확인', instructions: ['정렬 바꾸기'] } });

const answered = {
  ok: true,
  verdict: 'answered',
  answer: '날짜순으로 정했습니다.',
  basis: [{ id: 'm1', kind: 'decision', title: '수업 기록은 날짜순' }],
  owner_questions: [],
};
const needsOwner = { ok: true, verdict: 'needs_owner', answer: '정한 적 없습니다.', basis: [], owner_questions: ['과목별로 묶을까요?'] };

test('Think 묻기: 기본은 켜짐, off면 꺼짐. 조사·조율만 허용한다', () => {
  const on = loadConfig(env);
  assert.equal(on.askThink, true);
  assert.equal(loadConfig({ ...env, CODE_BRIDGE_ASK_THINK: ' OFF ' }).askThink, false);
  assert.equal(askThinkAllowed(on, job('investigate')), true);
  assert.equal(askThinkAllowed(on, job('plan')), true);
  assert.equal(askThinkAllowed(on, job('change')), false);
  assert.equal(askThinkAllowed(on, { ...job('plan'), job: 'apply' }), false);
  assert.equal(askThinkAllowed({ ...on, askThink: false }, job('plan')), false);
  assert.deepEqual(ASK_TOOLS, [...READ_ONLY_TOOLS, 'mcp']);
  assert.ok(!ASK_TOOLS.includes('edit') && !ASK_TOOLS.includes('shell'));
});

test('프롬프트: 켰을 때만 규칙을 붙이고, 조율은 확인 질문을 questions_for_owner로 보낸다', () => {
  assert.ok(!promptFor(job('plan')).includes('ask_think'));
  const plan = promptFor(job('plan'), { askThink: true });
  assert.match(plan, /ask_think/);
  assert.match(plan, new RegExp(`최대 ${ASK_THINK_LIMIT}번`));
  assert.match(plan, /needs_owner[^\n]*questions_for_owner/);
  const investigate = promptFor(job('investigate'), { askThink: true });
  assert.match(investigate, /needs_owner[^\n]*questions_for_think/);
  assert.ok(!promptFor(job('change'), { askThink: true }).includes('ask_think'), '수정 작업에는 붙이지 않는다');
});

test('답 정리: answered는 근거를, needs_owner는 진행 금지와 확인 질문을 보인다', () => {
  const a = formatAskResult(answered);
  assert.equal(a.verdict, 'answered');
  assert.match(a.text, /수업 기록은 날짜순/);
  const n = formatAskResult(needsOwner);
  assert.equal(n.verdict, 'needs_owner');
  assert.match(n.text, /진행하지 마세요/);
  assert.match(n.text, /과목별로 묶을까요/);
  const f = formatAskResult({ ok: false, error: 'relay_run_limit', message: '한도' });
  assert.equal(f.ok, false);
  assert.match(f.text, /relay_run_limit/);
  assert.equal(formatAskResult(null).ok, false);
});

test('도구: 빈 질문·긴 질문·비밀값은 보내지 않고, 한도를 넘으면 묻지 않는다', async () => {
  const sent = [];
  const logged = [];
  const tool = createAskThinkTool({
    ask: (q) => {
      sent.push(q);
      return Promise.resolve(sent.length === 2 ? needsOwner : answered);
    },
    onAsk: (e) => logged.push(e),
  });
  assert.equal(tool.annotations.readOnlyHint, true);
  assert.deepEqual(tool.inputSchema.required, ['question']);

  assert.equal((await tool.execute({ question: ' ' })).isError, true);
  assert.equal((await tool.execute({ question: 'x'.repeat(ASK_QUESTION_CHARS + 1) })).isError, true);
  assert.equal((await tool.execute({ question: 'api_key = sk-abcdefghijklmnopqrstuvwxyz123' })).isError, true);
  assert.equal(sent.length, 0);

  const first = await tool.execute({ question: '정렬 기준은?' });
  assert.equal(first.isError, false);
  assert.match(first.content[0].text, /answered/);
  assert.match((await tool.execute({ question: '묶을까?' })).content[0].text, /needs_owner/);
  await tool.execute({ question: '세 번째' });
  const over = await tool.execute({ question: '네 번째' });
  assert.equal(over.isError, true);
  assert.equal(sent.length, ASK_THINK_LIMIT);
  assert.deepEqual(logged.map((e) => e.verdict), ['answered', 'needs_owner', 'answered']);
});

test('도구: 호출이 던져도 에이전트에게는 실패 글로 돌려준다', async () => {
  const tool = createAskThinkTool({ ask: () => Promise.reject(new Error('socket hang up')) });
  const out = await tool.execute({ question: '질문' });
  assert.equal(out.isError, true);
  assert.match(out.content[0].text, /network/);
});

test('클라이언트: ask_think는 작업자 id와 요청 id를 보내고, 실패 응답도 본문 그대로 돌려준다', async () => {
  const calls = [];
  const reply = [new Response(JSON.stringify(answered), { status: 200 }), new Response(JSON.stringify({ ok: false, error: 'relay_run_limit' }), { status: 429 }), new Response('oops', { status: 502 })];
  const fetchImpl = (url, init) => {
    calls.push(JSON.parse(init.body));
    return Promise.resolve(reply.shift());
  };
  const bridge = createBridgeClient({ url: 'http://x', token: 't', workerId: 'pc-1', anonKey: null }, fetchImpl);
  assert.equal((await bridge.askThink('req-1', '질문')).verdict, 'answered');
  assert.deepEqual(calls[0], { action: 'ask_think', worker_id: 'pc-1', request_id: 'req-1', question: '질문' });
  assert.equal((await bridge.askThink('req-1', '질문')).error, 'relay_run_limit');
  assert.equal((await bridge.askThink('req-1', '질문')).error, 'http_502');
  const broken = createBridgeClient({ url: 'http://x', token: 't', workerId: 'pc-1' }, () => Promise.reject(new Error('down')));
  assert.equal((await broken.askThink('req-1', 'q')).error, 'network');
});
