import { assert, assertEquals } from 'jsr:@std/assert@1';
import type { CodeRequestDetail } from './actions.ts';
import { codeRequestBrief, codeRequestSection, SECTION_CHARS } from './code_brief.ts';
import { MemoryThinkStore } from './test_support.ts';
import { runThinkTool } from './tools.ts';

const REQ_ID = '44444444-4444-4444-8444-444444444444';

function item(partial: Record<string, unknown>) {
  return {
    id: 'request:1',
    label: '요청한 검사: node --test test/',
    status: 'passed',
    reason: null,
    command: 'node --test test/a.test.mjs',
    output: '# pass 3',
    cwd: 'tools/gateway',
    exit_code: 0,
    duration_ms: 1200,
    scope: 'required',
    source: 'request',
    env: false,
    ...partial,
  };
}

function verification(items: Record<string, unknown>[], verdict: string) {
  return { summary: { passed: 0, failed: 0, skipped: 0, preexisting: 0 }, items, note: null, stopped: false, verdict, patch_sha256: 'abc123', duration_ms: 1500 };
}

function changeRequest(result: Record<string, unknown> | null, partial: Partial<CodeRequestDetail> = {}): CodeRequestDetail {
  return {
    id: REQ_ID,
    title: '게이트웨이 수정',
    status: 'ready',
    mode: 'change',
    conversation_id: null,
    created_at: '2026-10-13T00:00:00Z',
    request: {
      goal: '게이트웨이 응답 형식을 고친다',
      instructions: ['a', 'b'],
      checks: [{ cwd: 'tools/gateway', command: 'node --test test/', why: '회귀' }],
      background: '긴 배경 '.repeat(8000),
    },
    round: 1,
    max_rounds: 1,
    review_status: null,
    last_error: null,
    latest: result
      ? {
        round: 1,
        status: 'finished',
        result,
        result_text: '원문 '.repeat(5000),
        started_at: '2026-10-13T00:00:30Z',
        finished_at: '2026-10-13T00:03:30Z',
        duration_ms: 180_000,
        parse_ok: true,
      }
      : null,
    ...partial,
  };
}

const passedResult = {
  summary: '응답 형식을 고쳤다',
  changes: [{ path: 'tools/gateway/src/a.mjs', what: '형식 수정' }],
  diff_stats: { files: 1, additions: 3, deletions: 1, list: [{ path: 'tools/gateway/src/a.mjs', additions: 3, deletions: 1 }] },
  checks: ['실데이터로 응답 확인'],
  verification: verification([item({})], 'passed'),
  timings: { prepare_ms: 2000, agent_ms: 120_000, checks_ms: 5000 },
};

Deno.test('긴 요청이어도 요약은 짧고 결과·검사·적용 행동이 앞에 있다', () => {
  const d = changeRequest(passedResult);
  const b = codeRequestBrief(d);
  assert(JSON.stringify(b).length <= 9000);
  assertEquals((b.checks as { verdict: string }).verdict, 'passed');
  const it = (b.checks as { items: Record<string, unknown>[] }).items[0];
  assertEquals([it.command, it.cwd, it.exit_code, it.requested], ['node --test test/a.test.mjs', 'tools/gateway', 0, true]);
  assertEquals((b.state as { apply: string }).apply, '적용 대기 (운영자 승인 필요)');
  assertEquals(b.status_label, '코드 작성 완료');
  assertEquals((b.changed_files as { path: string }[])[0].path, 'tools/gateway/src/a.mjs');
  assertEquals(b.needs_check, ['실데이터로 응답 확인']);
  assertEquals(b.timings_ms, { queue_wait_ms: 30_000, prepare_ms: 2000, agent_ms: 120_000, checks_ms: 5000, worker_total_ms: 180_000 });
  const sections = (b.not_included as { sections: { section: string }[] }).sections.map((s) => s.section);
  for (const s of ['request', 'result', 'result_text', 'check_logs', 'diff']) assert(sections.includes(s), s);
  assert(!JSON.stringify(b).includes('긴 배경'));
});

Deno.test('검사 기록이 없으면 통과가 아니다', () => {
  const { verification: _v, ...rest } = passedResult;
  const b = codeRequestBrief(changeRequest(rest));
  assertEquals((b.checks as { verdict: string }).verdict, 'no_record');
  assert((b.state as { apply: string }).apply.includes('통과 아님'));
  assert(String(b.next_action).includes('검증되지 않았다'));
});

Deno.test('필수 검사를 못 돌렸으면 실행 불가와 환경 조치를 알린다', () => {
  const env = item({ status: 'skipped', reason: 'tools/gateway에 node_modules가 없다. npm ci', exit_code: null, env: true });
  const followup = item({ id: 'db-test-other', label: '다른 DB 시험', status: 'skipped', scope: 'followup', source: 'auto', reason: '실데이터 필요' });
  const b = codeRequestBrief(changeRequest({ ...passedResult, verification: verification([env, followup], 'not_run') }));
  assertEquals((b.checks as { verdict: string }).verdict, 'not_run');
  assert(String(b.blocked_reason).includes('실행하지 못한 필수 검사'));
  assert(String(b.next_action).includes('환경 조치'));
  assert((b.needs_check as string[]).some((s) => s.startsWith('다른 DB 시험')));
});

Deno.test('원래도 실패하던 필수 검사가 있으면 통과 문구에 제외 수를 밝힌다', () => {
  const v = verification([item({}), item({ id: 'node-test:gw', status: 'preexisting', exit_code: 1, source: 'auto' })], 'passed');
  const b = codeRequestBrief(changeRequest({ ...passedResult, verification: v }));
  assertEquals((b.checks as { label: string }).label, '필수 검사 통과 (원래도 실패하던 검사 1개 제외)');
  assertEquals((b.state as { checks: string }).checks, '필수 검사 통과 (원래도 실패하던 검사 1개 제외)');
});

Deno.test('예전 기록(verdict 없음)도 실패한 필수 검사로 판정한다', () => {
  const old = { summary: { passed: 0, failed: 1, skipped: 0, preexisting: 0 }, items: [{ id: 'deno-test', label: 'Deno 시험', status: 'failed', reason: null, command: 'deno test', output: 'x' }], note: null, stopped: false };
  const b = codeRequestBrief(changeRequest({ ...passedResult, verification: old }));
  assertEquals((b.checks as { verdict: string }).verdict, 'failed');
  assert(String(b.blocked_reason).includes('Deno 시험'));
});

Deno.test('구간 조회는 offset으로 끝까지 이어 읽는다', () => {
  const d = changeRequest(passedResult);
  const first = codeRequestSection(d, 'request', 0);
  assertEquals((first.text as string).length, SECTION_CHARS);
  let offset = first.next_offset as number | null;
  let text = first.text as string;
  while (offset != null) {
    const next = codeRequestSection(d, 'request', offset);
    text += next.text as string;
    offset = next.next_offset as number | null;
  }
  assertEquals(text.length, first.total_chars);
  const logs = codeRequestSection(d, 'check_logs', 0);
  assert((logs.text as string).includes('종료 코드: 0'));
  assertEquals(codeRequestSection(d, 'diff', 0).available, false);
  assertEquals(codeRequestSection(d, 'diff', 0, 'diff --git a b').text, 'diff --git a b');
});

Deno.test('Think 도구: 기본은 요약, section이면 구간, 잘못된 section은 오류', async () => {
  const store = new MemoryThinkStore();
  store.codeRequests.push(changeRequest(passedResult));
  store.codeDiffs[REQ_ID] = 'diff --git a/x b/x\n+1';
  const call = (args: Record<string, unknown>) => runThinkTool('get_code_request', JSON.stringify(args), store, 12000, { conversationId: 'c1', memoryRefs: [] });
  const brief = JSON.parse((await call({ id: REQ_ID, section: null, offset: null })).output);
  assertEquals(brief.checks.verdict, 'passed');
  assertEquals(brief.request, undefined);
  const diff = JSON.parse((await call({ id: REQ_ID, section: 'diff', offset: null })).output);
  assertEquals(diff.text, 'diff --git a/x b/x\n+1');
  const bad = await call({ id: REQ_ID, section: 'secrets', offset: null });
  assertEquals(bad.ok, false);
});
