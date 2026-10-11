import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, test } from 'node:test';
import {
  analyzeIssues,
  migrationVersionCheck,
  planChecks,
  runChecks,
  scrubEnv,
  secretAssetPlaceholders,
  summarize,
  tail,
} from '../src/checks.mjs';

const fakeFs = (files) => {
  const set = new Set(files);
  return {
    exists: (rel) => set.has(rel) || [...set].some((f) => f.startsWith(`${rel}/`)),
    list: (rel) => [...new Set([...set].filter((f) => f.startsWith(`${rel}/`)).map((f) => f.slice(rel.length + 1).split('/')[0]))],
  };
};
const allTools = { flutter: true, deno: true, dbTest: true };

test('바뀐 경로에 맞는 검사만 고른다', () => {
  const fs = fakeFs([
    'apps/yggdrasill_manager/pubspec.yaml',
    'apps/yggdrasill_manager/lib/a.dart',
    'apps/yggdrasill_manager/test/a_test.dart',
    'supabase/functions/ai_think/index.ts',
    'supabase/functions/ai_think/store_test.ts',
    'supabase/functions/kiosk_api/index.ts',
    'supabase/migrations/20261001000000_ai_old.sql',
    'supabase/migrations/20261009000000_ai_new.sql',
    'tools/code_bridge/test/lib.test.mjs',
  ]);
  const items = planChecks({
    paths: [
      'apps/yggdrasill_manager/lib/a.dart',
      'apps/yggdrasill_manager/lib/gone.dart',
      'supabase/functions/ai_think/store.ts',
      'supabase/migrations/20261009000000_ai_new.sql',
      'tools/code_bridge/src/lib.mjs',
      'docs/architecture/ai-think.md',
      'gateway/server.js',
    ],
    ...fs,
    baseMigrations: ['20261001000000_ai_old.sql'],
    tools: allTools,
  });
  assert.deepEqual(
    items.map((i) => i.id),
    [
      'flutter-pub:yggdrasill_manager',
      'flutter-analyze:yggdrasill_manager',
      'flutter-test:yggdrasill_manager',
      'deno-check',
      'deno-test:ai_think',
      'node-test:code_bridge',
      'db-version',
      'db-test',
      'unchecked:gateway/server.js',
    ],
  );
  const analyze = items.find((i) => i.id === 'flutter-analyze:yggdrasill_manager');
  assert.deepEqual(analyze.steps[0].files, ['lib/a.dart'], '지운 파일은 분석하지 않는다');
  assert.deepEqual(items.find((i) => i.id === 'deno-check').steps[0].files, ['ai_think/index.ts']);
  assert.equal(items.find((i) => i.id === 'db-version').status, 'passed');
  assert.equal(items.find((i) => i.id.startsWith('unchecked')).status, 'skipped');
});

test('_shared가 바뀌면 모든 Edge Function을 검사하고, 도구가 없으면 미실행', () => {
  const fs = fakeFs(['supabase/functions/_shared/ai/x.ts', 'supabase/functions/a/index.ts', 'supabase/functions/b/index.ts']);
  const items = planChecks({ paths: ['supabase/functions/_shared/ai/x.ts'], ...fs, baseMigrations: [], tools: allTools });
  assert.deepEqual(items.find((i) => i.id === 'deno-check').steps[0].files, ['a/index.ts', 'b/index.ts']);
  const none = planChecks({ paths: ['supabase/functions/_shared/ai/x.ts'], ...fs, baseMigrations: [], tools: { ...allTools, deno: false } });
  assert.deepEqual(none.map((i) => [i.id, i.status]), [['deno', 'skipped']]);
});

test('파일 이름에 셸 특수 문자가 있으면 flutter analyze를 돌리지 않는다', () => {
  const fs = fakeFs(['apps/x/pubspec.yaml', 'apps/x/lib/a&b.dart']);
  const items = planChecks({ paths: ['apps/x/lib/a&b.dart'], ...fs, baseMigrations: [], tools: allTools });
  const analyze = items.find((i) => i.id === 'flutter-analyze:x');
  assert.equal(analyze.status, 'skipped');
  assert.equal(analyze.steps, undefined);
});

test('AI 영역 밖 DB 함수 파일은 미실행으로 따로 알린다', () => {
  const fs = fakeFs(['supabase/migrations/20261009000000_lesson_x.sql']);
  const items = planChecks({ paths: ['supabase/migrations/20261009000000_lesson_x.sql'], ...fs, baseMigrations: [], tools: allTools });
  assert.deepEqual(items.map((i) => [i.id, i.status]), [['db-version', 'passed'], ['db-test-other', 'skipped']]);
});

test('DB 함수 파일 번호: 기존 파일 수정·삭제, 번호 겹침, 이른 번호, 이름 모양', () => {
  const base = ['20261005000000_ai_a.sql', '20261006000000_ai_b.sql'];
  const fs = fakeFs([
    'supabase/migrations/20261005000000_ai_a.sql',
    'supabase/migrations/20261007000000_ai_c.sql',
    'supabase/migrations/20261007000000_ai_d.sql',
    'supabase/migrations/20261001000000_ai_early.sql',
    'supabase/migrations/Bad-Name.sql',
  ]);
  const r = migrationVersionCheck(
    ['20261005000000_ai_a.sql', '20261006000000_ai_b.sql', '20261007000000_ai_c.sql', '20261001000000_ai_early.sql', 'Bad-Name.sql'],
    { ...fs, baseMigrations: base },
  );
  assert.equal(r.status, 'failed');
  assert.match(r.output, /20261005000000_ai_a\.sql: 이미 있던 DB 함수 파일을 고쳤습니다/);
  assert.match(r.output, /20261006000000_ai_b\.sql: 이미 있던 DB 함수 파일을 지웠습니다/);
  assert.match(r.output, /20261007000000_ai_c\.sql: 번호 20261007000000을 20261007000000_ai_d\.sql도/);
  assert.match(r.output, /20261001000000_ai_early\.sql: 번호가 기존 마지막 파일/);
  assert.match(r.output, /Bad-Name\.sql: 이름이/);
  assert.equal(migrationVersionCheck(['20261007000000_ai_d.sql'], { ...fakeFs(['supabase/migrations/20261007000000_ai_d.sql']), baseMigrations: base }).status, 'passed');
});

test('analyze 출력에서 문제 줄을 줄 번호 없이 모은다', () => {
  const out = `Analyzing x...
  warning • The value of the local variable 'a' isn't used • lib/a.dart:12:9 • unused_local_variable
   info - Prefer const • lib/b.dart:3:1 • prefer_const_constructors
2 issues found.`;
  assert.deepEqual([...analyzeIssues(out)], [
    "warning • lib/a.dart • unused_local_variable • The value of the local variable 'a' isn't used",
    'info • lib/b.dart • prefer_const_constructors • Prefer const',
  ]);
});

test('검사 환경 변수에서 키·토큰·작업자 설정을 뺀다', () => {
  const env = scrubEnv({ PATH: 'p', CURSOR_API_KEY: 'x', CODE_BRIDGE_WORKER_TOKEN: 'y', OPENAI_API_KEY: 'z', GITHUB_TOKEN: 't', SUPABASE_URL: 'u', HOME: 'h' });
  assert.deepEqual(Object.keys(env).sort(), ['HOME', 'PATH']);
});

test('출력 꼬리: 색 코드 제거, 키 가림, 길이 제한', () => {
  const t = tail(`\x1b[31mred\x1b[0m sk-${'a'.repeat(30)} ${'x'.repeat(5000)}`, 100);
  assert.ok(t.length <= 102);
  assert.ok(!t.includes('\x1b'));
  assert.equal(tail('\x1b[31mred\x1b[0m sk-' + 'a'.repeat(30)), 'red [가림: 키]');
});

test('pubspec이 쓰는 비밀 자산은 빈 자리표시 파일로 채우고, 있는 파일은 건드리지 않는다', () => {
  const app = mkdtempSync(join(tmpdir(), 'ygg-app-'));
  try {
    writeFileSync(join(app, 'pubspec.yaml'), 'flutter:\n  assets:\n    - env.local.json\n    - assets/a.png\n    - "../env.local.json"\n    - config/.env.prod\n');
    writeFileSync(join(app, 'keep.json'), 'x');
    assert.deepEqual(secretAssetPlaceholders(app), ['env.local.json', 'config/.env.prod']);
    assert.equal(readFileSync(join(app, 'env.local.json'), 'utf8'), '{}\n');
    assert.equal(readFileSync(join(app, 'config/.env.prod'), 'utf8'), '');
    assert.ok(!existsSync(join(app, 'assets', 'a.png')));
    writeFileSync(join(app, 'env.local.json'), '{"real":1}');
    assert.deepEqual(secretAssetPlaceholders(app), []);
    assert.equal(readFileSync(join(app, 'env.local.json'), 'utf8'), '{"real":1}');
  } finally {
    rmSync(app, { recursive: true, force: true });
  }
});

const root = mkdtempSync(join(tmpdir(), 'ygg-checks-'));
const dir = join(root, 'after');
const base = join(root, 'before');
for (const d of [dir, base]) mkdirSync(d, { recursive: true });
writeFileSync(join(dir, 'broken'), '');
after(() => rmSync(root, { recursive: true, force: true }));

const nodeStep = (code) => ({ cmd: 'node', args: ['-e', code], cwd: '.' });
const failIfBroken = nodeStep("process.exit(require('fs').existsSync('broken') ? 1 : 0)");

test('검사 실행: 통과·실패·원래도 실패·앞 단계 실패로 건너뜀', async () => {
  const items = [
    { id: 'ok', label: '통과', steps: [nodeStep('process.exit(0)')] },
    { id: 'new', label: '이번 수정으로 실패', steps: [failIfBroken] },
    { id: 'old', label: '원래도 실패', steps: [nodeStep("console.log('boom'); process.exit(2)")] },
    { id: 'prep', label: '준비', steps: [nodeStep('process.exit(3)')] },
    { id: 'dep', label: '준비 뒤', after: 'prep', steps: [nodeStep('process.exit(0)')] },
    { id: 'fixed', label: '미리 정한 결과', status: 'skipped', reason: '도구 없음' },
  ];
  let baselines = 0;
  const v = await runChecks({
    dir,
    items,
    tools: {},
    baseline: async () => {
      baselines += 1;
      return base;
    },
  });
  assert.deepEqual(Object.fromEntries(v.items.map((i) => [i.id, i.status])), {
    ok: 'passed',
    new: 'failed',
    old: 'preexisting',
    prep: 'preexisting',
    dep: 'skipped',
    fixed: 'skipped',
  });
  assert.equal(baselines, 1, '기준 상태는 한 번만 준비한다');
  assert.match(v.items.find((i) => i.id === 'old').output, /boom/);
  assert.deepEqual(v.summary, summarize(v.items));
  assert.equal(v.stopped, false);
});

test('멈추라고 하면 남은 검사는 미실행으로 남긴다', async () => {
  let stop = false;
  const v = await runChecks({
    dir,
    tools: {},
    items: [
      { id: 'a', label: 'a', steps: [nodeStep('process.exit(0)')] },
      { id: 'b', label: 'b', steps: [nodeStep('setTimeout(() => {}, 60000)')] },
      { id: 'c', label: 'c', steps: [nodeStep('process.exit(0)')] },
    ],
    shouldStop: () => stop,
    log: (msg) => {
      if (String(msg).includes('검사: b')) setTimeout(() => (stop = true), 200);
    },
  });
  assert.equal(v.stopped, true);
  assert.deepEqual(v.items.map((i) => [i.id, i.status]), [['a', 'passed'], ['b', 'skipped'], ['c', 'skipped']]);
});

test('단계 제한 시간을 넘으면 실패로 본다', async () => {
  const v = await runChecks({
    dir,
    tools: {},
    stepTimeoutMs: 500,
    items: [{ id: 'slow', label: 'slow', steps: [nodeStep('setTimeout(() => {}, 60000)')] }],
  });
  assert.equal(v.items[0].status, 'failed');
  assert.match(v.items[0].output, /끝나지 않아 멈췄습니다/);
});
