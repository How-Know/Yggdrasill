import { assert, assertEquals } from 'jsr:@std/assert@1';
import type { AiRunRecord } from '../_shared/ai/usage.ts';
import { sha256Hex } from '../_shared/hash.ts';
import { handleBridge, type BridgeDeps, type RpcResult } from './handler.ts';
import { parseRound } from './validate.ts';

const TOKEN = 'worker-token-for-tests';
const REQ_ID = '11111111-2222-3333-4444-555555555555';

interface Harness {
  deps: BridgeDeps;
  calls: { fn: string; args: Record<string, unknown> }[];
  runs: AiRunRecord[];
}

async function harness(reply: (fn: string) => RpcResult, tokenSha256?: string | null): Promise<Harness> {
  const calls: Harness['calls'] = [];
  const runs: AiRunRecord[] = [];
  return {
    calls,
    runs,
    deps: {
      tokenSha256: tokenSha256 === undefined ? await sha256Hex(TOKEN) : tokenSha256,
      hash: sha256Hex,
      rpc: (fn, args) => {
        calls.push({ fn, args });
        return Promise.resolve(reply(fn));
      },
      recordRun: (rec) => {
        runs.push(rec);
        return Promise.resolve('run-id');
      },
    },
  };
}

function post(body: unknown, token: string | null = TOKEN): Request {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  return new Request('http://localhost/ai_code_bridge', { method: 'POST', headers, body: JSON.stringify(body) });
}

const ok = (data: unknown): RpcResult => ({ data, error: null });

Deno.test('비밀값이 없으면 503, 토큰이 틀리면 401', async () => {
  const off = await harness(() => ok({}), null);
  assertEquals((await handleBridge(post({ action: 'claim', worker_id: 'w1' }), off.deps)).status, 503);

  const h = await harness(() => ok({}));
  assertEquals((await handleBridge(post({ action: 'claim', worker_id: 'w1' }, 'wrong'), h.deps)).status, 401);
  assertEquals((await handleBridge(post({ action: 'claim', worker_id: 'w1' }, null), h.deps)).status, 401);
  assertEquals(h.calls.length, 0);
});

Deno.test('작업자 id 형식이 틀리면 RPC를 부르지 않는다', async () => {
  const h = await harness(() => ok({}));
  const res = await handleBridge(post({ action: 'claim', worker_id: 'bad id!' }), h.deps);
  assertEquals(res.status, 400);
  assertEquals((await res.json()).error, 'worker_id_invalid');
  assertEquals(h.calls.length, 0);
});

Deno.test('가져가기는 작업자에게 필요한 값만 돌려준다', async () => {
  const h = await harness(() =>
    ok({
      request: {
        id: REQ_ID,
        title: '홈 화면',
        request: { goal: 'g' },
        round: 1,
        max_rounds: 2,
        attempts: 1,
        created_by: 'user-1',
        worker_id: 'w1',
      },
      round: { prompt: null },
    })
  );
  const res = await handleBridge(post({ action: 'claim', worker_id: 'w1', info: { version: '1', hostname: 'pc', model: 'm' } }), h.deps);
  const body = await res.json();
  assertEquals(res.status, 200);
  assertEquals(h.calls[0].fn, 'ai_code_bridge_claim');
  assertEquals(h.calls[0].args.p_info, { version: '1', model: 'm' });
  assertEquals(body.request.id, REQ_ID);
  assertEquals(body.request.created_by, undefined);
  assertEquals(body.request.followup_prompt, null);
  assertEquals(body.lease_seconds, 120);
});

Deno.test('대기열이 비어 있으면 request는 null', async () => {
  const h = await harness(() => ok({ request: null }));
  const body = await (await handleBridge(post({ action: 'claim', worker_id: 'w1' }), h.deps)).json();
  assertEquals(body, { ok: true, lease_seconds: 120, request: null });
});

Deno.test('진행 신호는 요청 없이도 보낼 수 있고, 취소 요청을 전한다', async () => {
  const h = await harness(() => ok({ ok: true, cancel_requested: true }));
  const idle = await handleBridge(post({ action: 'heartbeat', worker_id: 'w1' }), h.deps);
  assertEquals(idle.status, 200);
  assertEquals(h.calls[0].args.p_request_id, null);
  const busy = await (await handleBridge(post({ action: 'heartbeat', worker_id: 'w1', request_id: REQ_ID, run_id: 'run-1' }), h.deps)).json();
  assertEquals(busy.cancel_requested, true);
  assertEquals(h.calls[1].args.p_run_id, 'run-1');
  const bad = await handleBridge(post({ action: 'heartbeat', worker_id: 'w1', request_id: 'x' }), h.deps);
  assertEquals(bad.status, 400);
});

Deno.test('완료하면 Cursor 호출을 ai_runs에 금액 없이 남긴다', async () => {
  const h = await harness(() => ok({ status: 'ready', conversation_id: 'conv-1', created_by: 'user-1' }));
  const res = await handleBridge(
    post({
      action: 'complete',
      worker_id: 'w1',
      request_id: REQ_ID,
      round: {
        prompt: 'p',
        prompt_version: 'code_bridge.v1',
        result_text: 'r',
        result: { findings: [] },
        parse_ok: true,
        model: 'composer-2.5',
        duration_ms: 1234,
        usage: { inputTokens: 100, outputTokens: 20, cacheReadTokens: 30, cacheWriteTokens: 0, totalTokens: 150 },
        tool_calls: [{ name: 'read', count: 3 }, { name: 'grep', count: 2 }],
      },
    }),
    h.deps,
  );
  assertEquals((await res.json()).status, 'ready');
  assertEquals(h.runs.length, 1);
  const run = h.runs[0];
  assertEquals(run.provider, 'cursor');
  assertEquals(run.feature, 'code_request');
  assertEquals(run.costUsd, null);
  assertEquals(run.usage.cachedInputTokens, 30);
  assertEquals(run.toolCalls, 5);
  assertEquals(run.createdBy, 'user-1');
  assertEquals(run.conversationId, 'conv-1');
});

Deno.test('점유를 잃은 작업자의 완료는 409', async () => {
  const h = await harness(() => ({ data: null, error: { message: 'bridge_not_owner' } }));
  const res = await handleBridge(post({ action: 'complete', worker_id: 'w1', request_id: REQ_ID, round: { model: 'm' } }), h.deps);
  assertEquals(res.status, 409);
  assertEquals(h.runs.length, 0);
});

Deno.test('실패: 모델 호출이 없었으면 ai_runs를 남기지 않고, 취소는 stopped로 남긴다', async () => {
  const h = await harness(() => ok({ status: 'queued' }));
  await handleBridge(post({ action: 'fail', worker_id: 'w1', request_id: REQ_ID, code: 'startup', error: 'net', retryable: true }), h.deps);
  assertEquals(h.calls[0].args.p_retryable, true);
  assertEquals(h.runs.length, 0);

  await handleBridge(
    post({ action: 'fail', worker_id: 'w1', request_id: REQ_ID, code: 'cancelled', error: '취소', round: { model: 'm' } }),
    h.deps,
  );
  assertEquals(h.runs[0].status, 'stopped');

  const bad = await handleBridge(post({ action: 'fail', worker_id: 'w1', request_id: REQ_ID, code: 'weird' }), h.deps);
  assertEquals(bad.status, 400);
});

Deno.test('회차 결과 검증: 너무 긴 원문과 잘못된 도구 기록은 거부한다', () => {
  assertEquals(parseRound({ result_text: 'x'.repeat(200_001) }), { ok: false, error: 'result_text_too_long' });
  assertEquals(parseRound({ tool_calls: [{ name: 'read' }] }), { ok: false, error: 'tool_calls_invalid' });
  assertEquals(parseRound({ result: [1, 2] }), { ok: false, error: 'result_invalid' });
  const okRound = parseRound(null);
  assert(okRound.ok);
  assertEquals(okRound.value.parse_ok, false);
  assertEquals(okRound.value.tool_calls, []);
});

Deno.test('적용 작업을 가져가면 diff와 기준 커밋을 주고, 2회차 질문은 주지 않는다', async () => {
  const h = await harness(() =>
    ok({
      job: 'apply',
      request: { id: REQ_ID, title: 't', mode: 'change', request: {}, round: 1, max_rounds: 2, attempts: 0 },
      round: { prompt: '1회차 프롬프트', result: { diff: '--- a/x\n+++ b/x\n', base_commit: 'abc123', summary: 's' } },
    })
  );
  const body = await (await handleBridge(post({ action: 'claim', worker_id: 'w1' }), h.deps)).json();
  assertEquals(body.request.job, 'apply');
  assertEquals(body.request.mode, 'change');
  assertEquals(body.request.diff, '--- a/x\n+++ b/x\n');
  assertEquals(body.request.base_commit, 'abc123');
  assertEquals(body.request.followup_prompt, null);
});

Deno.test('조사 작업에는 diff를 싣지 않는다', async () => {
  const h = await harness(() =>
    ok({ job: 'run', request: { id: REQ_ID, title: 't', request: {}, round: 2, max_rounds: 2, attempts: 1 }, round: { prompt: '추가 질문' } })
  );
  const body = await (await handleBridge(post({ action: 'claim', worker_id: 'w1' }), h.deps)).json();
  assertEquals(body.request.job, 'run');
  assertEquals(body.request.mode, 'investigate');
  assertEquals(body.request.followup_prompt, '추가 질문');
  assertEquals(body.request.diff, null);
});

Deno.test('적용 결과 보고', async () => {
  const h = await harness(() => ok({ status: 'apply_failed' }));
  const res = await handleBridge(
    post({ action: 'apply_done', worker_id: 'w1', request_id: REQ_ID, ok: false, result: { error: 'conflict', conflicts: ['a.dart'] } }),
    h.deps,
  );
  assertEquals((await res.json()).status, 'apply_failed');
  assertEquals(h.calls[0].fn, 'ai_code_bridge_apply_done');
  assertEquals(h.calls[0].args.p_ok, false);
  assertEquals(h.calls[0].args.p_result, { error: 'conflict', conflicts: ['a.dart'] });
  const big = await handleBridge(
    post({ action: 'apply_done', worker_id: 'w1', request_id: REQ_ID, ok: true, result: { files: ['x'.repeat(30000)] } }),
    h.deps,
  );
  assertEquals(big.status, 400);
});

Deno.test('완료 뒤 검토 대상이면 검토를 백그라운드로 넘긴다', async () => {
  const reviewed: string[] = [];
  const tasks: Promise<unknown>[] = [];
  const h = await harness(() => ok({ status: 'ready', review: true }));
  h.deps.review = (id) => {
    reviewed.push(id);
    return Promise.resolve('done');
  };
  h.deps.background = (t) => tasks.push(t);
  await handleBridge(post({ action: 'complete', worker_id: 'w1', request_id: REQ_ID, round: { parse_ok: true } }), h.deps);
  assertEquals(reviewed, [REQ_ID]);
  assertEquals(tasks.length, 1);

  const h2 = await harness(() => ok({ status: 'ready', review: false }));
  h2.deps.review = (id) => {
    reviewed.push(id);
    return Promise.resolve('done');
  };
  await handleBridge(post({ action: 'complete', worker_id: 'w1', request_id: REQ_ID, round: {} }), h2.deps);
  assertEquals(reviewed.length, 1);
});

Deno.test('diff는 결과 JSON 한도와 따로 400KB까지 받는다', () => {
  assert(parseRound({ result: { summary: 's', diff: 'x'.repeat(300_000) } }).ok);
  assertEquals(parseRound({ result: { diff: 'x'.repeat(400_001) } }), { ok: false, error: 'diff_too_large' });
  assertEquals(parseRound({ result: { diff: 1 } }), { ok: false, error: 'diff_too_large' });
  assertEquals(parseRound({ result: { big: 'x'.repeat(100_001) } }), { ok: false, error: 'result_too_large' });
});

Deno.test('POST가 아니면 405', async () => {
  const h = await harness(() => ok({}));
  const res = await handleBridge(new Request('http://localhost/ai_code_bridge', { method: 'GET' }), h.deps);
  assertEquals(res.status, 405);
});
