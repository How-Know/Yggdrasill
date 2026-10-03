import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  ConfigError,
  ToolCounter,
  buildPrompt,
  classifyError,
  isProtectedPath,
  isSecretPath,
  loadConfig,
  looksSecret,
  modeLabel,
  parseChangeResult,
  parseNumstat,
  parsePlanResult,
  parseResult,
  promptFor,
  redact,
  retryDelayMs,
} from '../src/lib.mjs';

const job = {
  title: '홈 화면 출석 카드',
  request: {
    goal: '출석 카드에 지각 표시를 넣을 수 있는지',
    questions: ['어느 위젯이 카드를 그리나', ' '],
    focus_paths: ['apps/yggdrasill/lib/screens'],
    do_not: ['DB 스키마 변경 제안'],
    memory_refs: [{ kind: 'decision', title: '출결 표시 원칙', version: 3, content: '색만으로 구분하지 않는다' }],
  },
};

test('요청문에 목표·질문·폴더·결정이 들어가고 수정 금지가 명시된다', () => {
  const p = buildPrompt(job);
  assert.match(p, /코드를 고치지 않고/);
  assert.match(p, /목표: 출석 카드에 지각 표시/);
  assert.match(p, /1\. 어느 위젯이 카드를 그리나/);
  assert.doesNotMatch(p, /2\. /);
  assert.match(p, /apps\/yggdrasill\/lib\/screens/);
  assert.match(p, /\[decision\] 출결 표시 원칙 \(v3\)/);
  assert.match(p, /제약:\n\(없음\)/);
  assert.match(p, /배경 \(요청이 나온 Think 대화\):\n\(없음\)/);
  assert.match(buildPrompt({ ...job, request: { ...job.request, background: 'Think가 제안한 방향' } }), /Think가 제안한 방향/);
});

test('답변 끝의 마지막 JSON 블록을 읽고 모양을 맞춘다', () => {
  const raw = [
    '조사했습니다.',
    '```json\n{"summary":"예시"}\n```',
    '최종:',
    '```json',
    JSON.stringify({
      summary: '가능합니다',
      feasibility: 'maybe',
      findings: [{ point: '카드 위젯', evidence: [{ path: 'a.dart', lines: 12 }, { lines: '3' }] }, { point: '' }],
      proposals: [{ title: '배지 추가', change: '...', files: ['a.dart', 3], risk: 'extreme' }],
      risks: ['없음', ''],
    }),
    '```',
  ].join('\n');
  const r = parseResult(raw);
  assert.equal(r.ok, true);
  assert.equal(r.value.summary, '가능합니다');
  assert.equal(r.value.feasibility, 'unclear');
  assert.deepEqual(r.value.findings, [{ point: '카드 위젯', evidence: [{ path: 'a.dart', lines: '12' }] }]);
  assert.deepEqual(r.value.proposals[0].files, ['a.dart']);
  assert.equal(r.value.proposals[0].risk, 'medium');
  assert.deepEqual(r.value.risks, ['없음']);
  assert.deepEqual(r.value.questions_for_think, []);
});

test('JSON이 없거나 요약이 없으면 형식 불일치', () => {
  assert.deepEqual(parseResult('그냥 설명만'), { ok: false, reason: 'no_json_block' });
  assert.deepEqual(parseResult('```json\n{oops}\n```'), { ok: false, reason: 'invalid_json' });
  assert.deepEqual(parseResult('```json\n{"findings":[]}\n```'), { ok: false, reason: 'summary_missing' });
  assert.equal(parseResult('{"summary":"본문 전체가 JSON"}').ok, true);
});

test('키처럼 보이는 문자열을 가린다', () => {
  const s = redact([
    'OPENAI=sk-proj-abcdefghijklmnopqrstuvwxyz0123',
    'jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmnop',
    'api_key: "abcd1234efgh5678ijkl"',
    '-----BEGIN PRIVATE KEY-----\nMIIE\n-----END PRIVATE KEY-----',
    'commit 3f2a9c1d',
  ].join('\n'));
  assert.doesNotMatch(s, /sk-proj-abc/);
  assert.doesNotMatch(s, /eyJhbGciOiJIUzI1NiJ9\.eyJ/);
  assert.doesNotMatch(s, /abcd1234efgh5678ijkl/);
  assert.doesNotMatch(s, /MIIE/);
  assert.match(s, /api_key: "\[가림\]/);
  assert.match(s, /commit 3f2a9c1d/);
});

test('SDK 오류는 isRetryable을 따르고, 모르는 오류는 다시 시도하지 않는다', () => {
  const retryable = Object.assign(new Error('Rate limit exceeded'), { isRetryable: true, code: 'rate_limited' });
  assert.deepEqual(classifyError(retryable), { code: 'startup', retryable: true, message: 'rate_limited: Rate limit exceeded' });
  const auth = Object.assign(new Error('Invalid API key'), { isRetryable: false });
  assert.equal(classifyError(auth).retryable, false);
  assert.equal(classifyError(new TypeError('fetch failed')).retryable, true);
  assert.deepEqual(classifyError(new Error('boom')), { code: 'internal', retryable: false, message: 'boom' });
});

test('도구 호출은 call_id 기준으로 한 번만 센다', () => {
  const c = new ToolCounter();
  c.add({ type: 'tool_call', call_id: '1', name: 'read', status: 'running' });
  c.add({ type: 'tool_call', call_id: '1', name: 'read', status: 'completed' });
  c.add({ type: 'tool_call', call_id: '2', name: 'grep', status: 'running' });
  c.add({ type: 'tool_call', call_id: '3', name: 'read', status: 'running' });
  c.add({ type: 'assistant' });
  assert.deepEqual(c.list(), [{ name: 'read', count: 2 }, { name: 'grep', count: 1 }]);
});

test('설정: 키가 없으면 시작하지 않고, 값은 범위 안으로 맞춘다', () => {
  assert.throws(() => loadConfig({ CURSOR_API_KEY: 'k' }), ConfigError);
  assert.throws(() => loadConfig({ CODE_BRIDGE_WORKER_TOKEN: 't' }), ConfigError);
  assert.throws(() => loadConfig({ CODE_BRIDGE_WORKER_TOKEN: 't', CURSOR_API_KEY: 'k', CODE_BRIDGE_WORKER_ID: 'bad id' }), ConfigError);
  const cfg = loadConfig({ CODE_BRIDGE_WORKER_TOKEN: 't', CURSOR_API_KEY: 'k', CODE_BRIDGE_POLL_MS: '10' });
  assert.equal(cfg.pollMs, 3000);
  assert.equal(cfg.model, 'composer-2.5');
  assert.match(cfg.workerId, /^pc-/);
  assert.match(cfg.url, /functions\/v1\/ai_code_bridge$/);
  assert.equal(cfg.roundTimeoutMs, 15 * 60_000);
  assert.equal(cfg.changeTimeoutMs, 30 * 60_000);
  assert.equal(loadConfig({ CODE_BRIDGE_WORKER_TOKEN: 't', CURSOR_API_KEY: 'k', CODE_BRIDGE_CHANGE_TIMEOUT_MS: '999999999' }).changeTimeoutMs, 90 * 60_000);
  assert.deepEqual(['change', 'plan', 'investigate'].map(modeLabel), ['수정', '조율', '조사']);
});

test('조율 프롬프트: 계획 초안과 확인할 점을 넣고 고치지 않음을 밝힌다. 다음 회차는 Think 질문을 뒤에 붙인다', () => {
  const planJob = {
    ...job,
    mode: 'plan',
    request: { ...job.request, instructions: ['배지 위젯 추가'], questions: ['영향 범위'], background: '운영자 의도' },
  };
  const first = promptFor(planJob);
  assert.match(first, /실무 개발자/);
  assert.match(first, /아직 아무것도 고치지 않는다/);
  assert.match(first, /1\. 배지 위젯 추가/);
  assert.match(first, /1\. 영향 범위/);
  assert.match(first, /운영자 의도/);
  assert.match(first, /questions_for_owner/);
  assert.match(first, /출결 표시 원칙/);
  const next = promptFor({ ...planJob, followup_prompt: '## 2회차: Think가 보낸 질문·반론\n1. 정말?' });
  assert.ok(next.startsWith(first));
  assert.match(next, /1\. 정말\?$/);
});

test('조율 결과: 조사 칸에 계획 검토 칸을 더한다', () => {
  const r = parsePlanResult(
    '검토했습니다.\n```json\n{"summary":"고쳐야 가능","feasibility":"possible_with_changes",' +
      '"issues":[{"step":"2","problem":"중복","suggestion":"기존 것 재사용"},{"step":"x"}],' +
      '"suggested_steps":["a","b"],"questions_for_owner":["범위?"]}\n```',
  );
  assert.equal(r.ok, true);
  assert.equal(r.value.feasibility, 'possible_with_changes');
  assert.deepEqual(r.value.issues, [{ step: '2', problem: '중복', suggestion: '기존 것 재사용' }]);
  assert.deepEqual(r.value.suggested_steps, ['a', 'b']);
  assert.deepEqual(r.value.questions_for_owner, ['범위?']);
  assert.equal(parsePlanResult('설명만').ok, false);
});

test('수정 프롬프트: 승인된 조율본이면 그대로 따르라고 하고 이견을 함께 준다', () => {
  const change = promptFor({
    ...job,
    mode: 'change',
    request: {
      ...job.request,
      instructions: ['a'],
      based_on_plan: { title: '조율본', rounds: 2 },
      disagreements: [{ point: '보관 기간', think: '전부', cursor: '10개' }],
    },
  });
  assert.match(change, /2회 조율하고 운영자가 승인한 조율본 "조율본"/);
  assert.match(change, /보관 기간 \(Think: 전부 \/ Cursor: 10개\)/);
  assert.doesNotMatch(promptFor({ ...job, mode: 'change', request: { ...job.request, instructions: ['a'] } }), /조율본/);
});

test('작업 종류별 프롬프트: 2회차는 원래 요청 뒤에 추가 질문, 수정은 셸 없음과 복사본을 밝힌다', () => {
  const follow = promptFor({ ...job, followup_prompt: '## 2회차 추가 질문\n1. 크기는?' });
  assert.match(follow, /목표: 출석 카드에 지각 표시/);
  assert.match(follow, /2회차 추가 질문\n1\. 크기는\?$/);

  const change = promptFor({
    ...job,
    mode: 'change',
    request: {
      ...job.request,
      instructions: ['배지 위젯 추가'],
      based_on: { title: '조사', summary: '가능', proposals: [{ title: '배지', change: 'Badge 추가' }] },
    },
  });
  assert.match(change, /복사본/);
  assert.match(change, /명령을 실행할 수 없다/);
  assert.match(change, /1\. 배지 위젯 추가/);
  assert.match(change, /제안 "배지": Badge 추가/);
  assert.doesNotMatch(change, /코드를 고치지 않고/);
});

test('수정 결과: 요약이 없어도 빈 값으로 돌려준다', () => {
  const r = parseChangeResult('고쳤습니다.\n```json\n{"summary":"배지 추가","changes":[{"path":"a.dart","what":"x"},{}],"checks":["flutter analyze a.dart"]}\n```');
  assert.equal(r.ok, true);
  assert.deepEqual(r.value.changes, [{ path: 'a.dart', what: 'x' }]);
  assert.deepEqual(r.value.checks, ['flutter analyze a.dart']);
  assert.deepEqual(parseChangeResult('설명만').value.changes, []);
  assert.equal(parseChangeResult('설명만').ok, false);
});

test('numstat: 추가·삭제 합계, 바이너리, 이름 바뀜', () => {
  const s = parseNumstat('3\t1\ta.dart\0-\t-\timg.png\0' + '2\t0\t\0old.dart\0new.dart\0');
  assert.equal(s.files, 3);
  assert.equal(s.additions, 5);
  assert.equal(s.deletions, 1);
  assert.equal(s.list[1].additions, -1);
  assert.equal(s.list[2].path, 'new.dart');
});

test('비밀·보호 경로와 키처럼 보이는 diff', () => {
  for (const p of ['.env', 'apps/x/.env.local', 'apps/yggdrasill/env.local.json', 'certs/a.pem', 'supabase/.temp/cli-latest']) assert.ok(isSecretPath(p), p);
  for (const p of ['.env.example', 'lib/keyboard.dart', 'docs/env.md']) assert.ok(!isSecretPath(p), p);
  assert.ok(isProtectedPath('.cursor/hooks.json'));
  assert.ok(isProtectedPath('.cursor/hooks/deny-secrets.mjs'));
  assert.ok(!isProtectedPath('.cursor/rules/ai-think.mdc'));
  assert.ok(looksSecret('+const key = "sk-proj-abcdefghijklmnopqrstuvwxyz0123";'));
  assert.ok(!looksSecret('+const color = Colors.red;'));
});

test('재시도 간격은 늘어나되 5분을 넘지 않는다', () => {
  assert.equal(retryDelayMs(1), 30_000);
  assert.equal(retryDelayMs(2), 60_000);
  assert.equal(retryDelayMs(9), 300_000);
});
