// 요청한 필수 검사·node 폴더 자동 탐지·사전 확인·기록. 요청 34b9d6ae에서 gateway/test와 tools/v2_a4_compare/test가
// "자동 검사 없음"으로 건너뛰어졌고, 요청 명령(node --test <폴더>)은 Node 22에서 폴더를 찾아 들어가지 않아 그대로는 실패했다.
import assert from 'node:assert/strict';
import { existsSync, lstatSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, test } from 'node:test';
import {
  checkVerdict,
  expandNodeTestArgs,
  fsView,
  linkNodeModules,
  missingModule,
  nodeTestFailures,
  parseRequiredCheck,
  planChecks,
  preflightChecks,
  runChecks,
} from '../src/checks.mjs';
import { buildChangePrompt, parsePlanResult } from '../src/lib.mjs';

const fakeFs = (files, json = {}) => {
  const set = new Set(files);
  const under = (rel) => (rel === '.' || rel === '' ? [...set] : [...set].filter((f) => f.startsWith(`${rel}/`)).map((f) => f.slice(rel.length + 1)));
  return {
    exists: (rel) => set.has(rel) || [...set].some((f) => f.startsWith(`${rel}/`)),
    list: (rel) => [...new Set(under(rel).map((f) => f.split('/')[0]))],
    isDir: (rel) => [...set].some((f) => f.startsWith(`${rel}/`)),
    walk: (rel) => under(rel).filter((f) => !f.split('/').includes('node_modules')),
    readJson: (rel) => json[rel] ?? null,
  };
};
const GATEWAY_PKG = { 'gateway/package.json': { dependencies: { ajv: '^8' } } };
const repoFiles = [
  'gateway/package.json',
  'gateway/src/index.js',
  'gateway/test/a.test.js',
  'gateway/test/xelatex_v2_a4_naesin_source.test.js',
  'gateway/test/xelatex_v2_a4_naesin_source_checks.js',
  'tools/v2_a4_compare/prepare.mjs',
  'tools/v2_a4_compare/test/prepare.test.mjs',
];
const tools = (hasModules = true) => ({ flutter: true, deno: true, dbTest: true, nodeModules: (d) => (hasModules ? `/repo/${d}/node_modules` : null) });

test('필수 검사 명령: node --test와 저장소 안 경로·glob만 받는다', () => {
  assert.deepEqual(parseRequiredCheck({ cwd: 'gateway', command: 'node --test test/' }), { ok: true, cwd: 'gateway', args: ['test'] });
  assert.deepEqual(parseRequiredCheck({ cwd: '', command: 'node --test "tools/v2_a4_compare/test/**/*.test.mjs"' }), {
    ok: true,
    cwd: '.',
    args: ['tools/v2_a4_compare/test/**/*.test.mjs'],
  });
  assert.deepEqual(parseRequiredCheck({ cwd: '.', command: 'node --test' }), { ok: true, cwd: '.', args: [] });
  for (const bad of [
    { cwd: 'gateway', command: 'npm test' },
    { cwd: 'gateway', command: 'node --test --require x test/' },
    { cwd: 'gateway', command: 'node --test ../secret' },
    { cwd: 'gateway', command: 'node --test test/ && del x' },
    { cwd: '../x', command: 'node --test' },
    { cwd: '.git', command: 'node --test' },
  ]) {
    assert.equal(parseRequiredCheck(bad).ok, false, JSON.stringify(bad));
  }
});

test('폴더·glob 인자는 시험 파일 목록으로 펼친다(도우미 파일은 넣지 않는다)', () => {
  const fs = fakeFs(repoFiles);
  assert.deepEqual(expandNodeTestArgs('gateway', ['test'], fs), ['test/a.test.js', 'test/xelatex_v2_a4_naesin_source.test.js']);
  assert.deepEqual(expandNodeTestArgs('.', ['tools/v2_a4_compare/test'], fs), ['tools/v2_a4_compare/test/prepare.test.mjs']);
  assert.deepEqual(expandNodeTestArgs('gateway', ['test/xelatex_*.test.js'], fs), ['test/xelatex_v2_a4_naesin_source.test.js']);
  assert.deepEqual(expandNodeTestArgs('gateway', ['test/a.test.js'], fs), ['test/a.test.js']);
  assert.deepEqual(expandNodeTestArgs('gateway', ['nope'], fs), []);
});

test('요청 34b9d6ae 재현: 요청한 두 검사가 실제 시험 항목이 되고, 같은 시험을 자동 검사로 또 돌리지 않는다', () => {
  const items = planChecks({
    paths: [
      'gateway/test/xelatex_v2_a4_naesin_source.test.js',
      'gateway/test/xelatex_v2_a4_naesin_source_checks.js',
      'tools/v2_a4_compare/prepare.mjs',
      'tools/v2_a4_compare/test/prepare.test.mjs',
      'docs/v2_a4_original_compare.md',
    ],
    ...fakeFs(repoFiles, GATEWAY_PKG),
    baseMigrations: [],
    required: [
      { cwd: 'gateway', command: 'node --test test/', why: 'gateway 시험' },
      { cwd: '.', command: 'node --test tools/v2_a4_compare/test/', why: '비교 준비 시험' },
    ],
    tools: tools(),
  });
  assert.deepEqual(items.map((i) => i.id), ['request:1', 'request:2']);
  const [gw, cmp] = items;
  assert.equal(gw.source, 'request');
  assert.equal(gw.scope, 'required');
  assert.equal(gw.prepare, 'node-modules');
  assert.equal(gw.depsDir, 'gateway');
  assert.deepEqual(gw.steps, [{ cmd: 'node', args: ['--test'], files: ['test/a.test.js', 'test/xelatex_v2_a4_naesin_source.test.js'], cwd: 'gateway' }]);
  assert.equal(cmp.prepare, undefined, 'package.json이 없으면 의존성 준비가 필요 없다');
  assert.deepEqual(cmp.steps[0], { cmd: 'node', args: ['--test'], files: ['tools/v2_a4_compare/test/prepare.test.mjs'], cwd: '.' });
});

test('요청한 검사가 폴더 시험 일부만 덮으면 자동 검사는 나머지 파일만 돌린다(같은 시험을 두 번 돌리지 않는다)', () => {
  const items = planChecks({
    paths: ['gateway/src/index.js'],
    ...fakeFs([...repoFiles, 'gateway/src/util.test.js'], GATEWAY_PKG),
    baseMigrations: [],
    required: [{ cwd: 'gateway', command: 'node --test test/', why: '' }],
    tools: tools(),
  });
  assert.deepEqual(items.map((i) => i.id), ['request:1', 'node-test:gateway']);
  assert.deepEqual(items[1].steps[0].files, ['src/util.test.js']);
  assert.match(items[1].label, /요청한 검사에 없는 1개/);
});

test('요청한 검사가 없어도 node 폴더(package.json 또는 test/)의 시험을 자동으로 돌린다', () => {
  const items = planChecks({
    paths: ['gateway/src/index.js', 'tools/v2_a4_compare/prepare.mjs'],
    ...fakeFs(repoFiles, GATEWAY_PKG),
    baseMigrations: [],
    tools: tools(),
  });
  assert.deepEqual(items.map((i) => [i.id, i.source, i.scope]), [
    ['node-test:gateway', 'auto', 'required'],
    ['node-test:tools/v2_a4_compare', 'auto', 'required'],
  ]);
  assert.equal(items[0].compare, 'node-test');
  assert.deepEqual(items[1].steps[0].files, ['test/prepare.test.mjs']);
});

test('의존성(node_modules)이 작업 폴더에 없으면 환경 문제로 미실행이고, 판정은 통과가 아니다', () => {
  const items = planChecks({
    paths: ['gateway/src/index.js'],
    ...fakeFs(repoFiles, GATEWAY_PKG),
    baseMigrations: [],
    required: [{ cwd: 'gateway', command: 'node --test test/' }],
    tools: tools(false),
  });
  assert.equal(items.length, 1);
  assert.equal(items[0].status, 'skipped');
  assert.equal(items[0].env, true);
  assert.match(items[0].reason, /npm ci/);
  assert.equal(checkVerdict(items), 'not_run');
});

test('허용하지 않는 명령은 미실행, 시험 파일이 없으면 실패(이번 수정이 만들어야 한다)', () => {
  const items = planChecks({
    paths: ['docs/a.md'],
    ...fakeFs(repoFiles, GATEWAY_PKG),
    baseMigrations: [],
    required: [
      { cwd: 'gateway', command: 'npm test' },
      { cwd: 'tools/new_tool', command: 'node --test test/' },
    ],
    tools: tools(),
  });
  assert.deepEqual(items.map((i) => [i.id, i.status]), [['request:1', 'skipped'], ['request:2', 'failed']]);
  assert.match(items[1].output, /시험 파일/);
  assert.equal(checkVerdict(items), 'failed');
});

test('시험 파일이 없는 node 폴더는 문법 검사만 하고 시험은 미실행으로 남긴다', () => {
  const items = planChecks({
    paths: ['scripts/tool/run.mjs'],
    ...fakeFs(['scripts/tool/package.json', 'scripts/tool/run.mjs']),
    baseMigrations: [],
    tools: tools(),
  });
  assert.deepEqual(items.map((i) => [i.id, i.status ?? 'run']), [['node-syntax:scripts/tool', 'run'], ['unchecked:scripts/tool', 'skipped']]);
  assert.deepEqual(items[0].steps, [{ cmd: 'node', args: ['--check'], files: ['run.mjs'], cwd: 'scripts/tool' }]);
});

test('수정 전 확인: 명령 모양·의존성·아직 없는 폴더를 알린다', () => {
  const out = preflightChecks(
    [
      { cwd: 'gateway', command: 'node --test test/' },
      { cwd: 'tools/v2_a4_compare', command: 'node --test test/' },
      { cwd: 'gateway', command: 'npm test' },
    ],
    { ...fakeFs(['gateway/package.json'], GATEWAY_PKG), tools: tools(false) },
  );
  assert.deepEqual(out.map((p) => [p.ok, p.env]), [[false, true], [true, false], [false, false]]);
  assert.match(out[0].problem, /gateway\/node_modules/);
  assert.match(out[1].note, /아직 없습니다/);
});

test('수정 프롬프트에 필수 검사와 사전 확인 결과를 넣고, 검사를 돌렸다고 쓰지 말라고 한다', () => {
  const job = { mode: 'change', title: 't', request: { goal: 'g', instructions: ['a'], checks: [{ cwd: 'gateway', command: 'node --test test/', why: 'w' }] } };
  const prompt = buildChangePrompt(job, { preflight: [{ ok: false, problem: 'gateway/node_modules가 작업 폴더에 없습니다.' }] });
  assert.match(prompt, /## 필수 검사/);
  assert.match(prompt, /`node --test test\/` \(폴더 gateway\)/);
  assert.match(prompt, /지금은 돌릴 수 없음: gateway\/node_modules/);
  assert.match(prompt, /"통과했다"/);
  assert.doesNotMatch(buildChangePrompt({ ...job, request: { goal: 'g', instructions: ['a'] } }), /## 필수 검사/);
});

test('조율 결과의 운영자 결정 충돌과 제안 검사를 읽는다', () => {
  const raw = 'x\n```json\n' + JSON.stringify({
    summary: 's',
    feasibility: 'possible',
    owner_decision_conflicts: [{ decision: 'd', problem: 'p', evidence: [{ path: 'a.js', lines: '1' }, { lines: '2' }] }, { decision: 'x' }],
    suggested_checks: [{ cwd: '', command: 'node --test tools/x/test/', why: 'w' }, { cwd: 'a' }],
  }) + '\n```';
  const v = parsePlanResult(raw).value;
  assert.deepEqual(v.owner_decision_conflicts, [{ decision: 'd', problem: 'p', evidence: [{ path: 'a.js', lines: '1' }] }]);
  assert.deepEqual(v.suggested_checks, [{ cwd: '.', command: 'node --test tools/x/test/', why: 'w' }]);
});

test('node --test 실패 이름을 읽는다(하위 시험 포함)', () => {
  const names = nodeTestFailures('ok 1 - a\nnot ok 2 - crops API whitelist # TODO\n    not ok 1 - inner case\nnot ok 3 - test/x.test.js');
  assert.deepEqual([...names], ['crops API whitelist', 'inner case', 'test/x.test.js']);
});

// --- 실제 실행 -----------------------------------------------------------------

const root = mkdtempSync(join(tmpdir(), 'cb-required-'));
after(() => rmSync(root, { recursive: true, force: true }));

function writeTests(dir, files) {
  for (const [name, body] of Object.entries(files)) {
    mkdirSync(join(dir, 'pkg', 'test'), { recursive: true });
    writeFileSync(join(dir, 'pkg', 'test', name), body);
  }
}
const OLD_FAIL = "import test from 'node:test'; test('old broken', () => { throw new Error('old'); });\n";
const OK = "import test from 'node:test'; test('works', () => {});\n";
const NEW_FAIL = "import test from 'node:test'; test('new broken', () => { throw new Error('new'); });\n";

test('실제 실행: 바꾸기 전에도 실패하던 시험만 실패하면 원래도 실패, 새로 실패한 시험이 있으면 실패. 명령·폴더·종료 코드를 남긴다', async () => {
  const work = join(root, 'work');
  const base = join(root, 'base');
  writeTests(base, { 'a.test.mjs': OK, 'old.test.mjs': OLD_FAIL });
  writeTests(work, { 'a.test.mjs': OK, 'old.test.mjs': OLD_FAIL });
  const item = (id) => ({ id, label: id, compare: 'node-test', scope: 'required', source: 'request', steps: [{ cmd: 'node', args: ['--test'], files: ['test/a.test.mjs', 'test/old.test.mjs'], cwd: 'pkg' }] });
  const v1 = await runChecks({ dir: work, items: [item('only-old')], tools: {}, baseline: async () => base });
  assert.equal(v1.items[0].status, 'preexisting');
  assert.match(v1.items[0].output, /바꾸기 전에도 실패하던 시험만/);
  assert.equal(v1.items[0].exit_code, 1);
  assert.equal(v1.items[0].cwd, 'pkg');
  assert.equal(v1.items[0].command, 'node --test test/a.test.mjs test/old.test.mjs');
  assert.equal(v1.items[0].source, 'request');
  assert.ok(v1.items[0].duration_ms > 0);
  assert.equal(v1.verdict, 'passed');

  writeFileSync(join(work, 'pkg', 'test', 'a.test.mjs'), NEW_FAIL);
  const v2 = await runChecks({ dir: work, items: [item('new-fail')], tools: {}, baseline: async () => base });
  assert.equal(v2.items[0].status, 'failed');
  assert.match(v2.items[0].output, /새로 생긴 실패 시험 1개:\nnew broken/);
  assert.equal(v2.verdict, 'failed');
});

test('실제 실행: 바꾸기 전에도 패키지를 못 찾아 시험을 불러오지 못하면 원래도 실패가 아니라 환경 문제 미실행(통과 아님)', async () => {
  const MISSING = "import test from 'node:test'; import dep from 'not-installed-pkg'; test('x', () => dep());\n";
  const work = join(root, 'work-missing');
  const base = join(root, 'base-missing');
  writeTests(base, { 'm.test.mjs': MISSING });
  writeTests(work, { 'm.test.mjs': MISSING });
  const item = { id: 'request:1', label: 'r', compare: 'node-test', scope: 'required', source: 'request', depsDir: 'pkg', steps: [{ cmd: 'node', args: ['--test'], files: ['test/m.test.mjs'], cwd: 'pkg' }] };
  const v = await runChecks({ dir: work, items: [item], tools: {}, baseline: async () => base });
  assert.equal(v.items[0].status, 'skipped');
  assert.equal(v.items[0].env, true);
  assert.match(v.items[0].reason, /not-installed-pkg/);
  assert.equal(v.verdict, 'not_run');
  assert.equal(missingModule("Error: Cannot find module './local.mjs'"), null);
  assert.equal(missingModule("Cannot find module 'C:\\x\\y.mjs'"), null);
  assert.equal(missingModule("Cannot find package '@scope/pkg' imported from"), '@scope/pkg');
});

test('실제 실행: node_modules는 캐시에 복사해 연결하고, 검사가 끝나면 연결만 지운다(작업 폴더 원본은 그대로)', async () => {
  const repo = join(root, 'repo');
  const work = join(root, 'work2');
  const cache = join(root, 'cache');
  mkdirSync(join(repo, 'pkg', 'node_modules', 'dep'), { recursive: true });
  mkdirSync(join(repo, 'pkg', 'node_modules', 'dep2'), { recursive: true });
  writeFileSync(join(repo, 'pkg', 'node_modules', 'dep', 'index.js'), "module.exports = require('dep2');\n");
  writeFileSync(join(repo, 'pkg', 'node_modules', 'dep2', 'index.js'), 'module.exports = 42;\n');
  writeFileSync(join(repo, 'pkg', 'package.json'), '{"dependencies":{"dep":"1"}}');
  writeTests(work, {
    'dep.test.mjs': "import test from 'node:test'; import assert from 'node:assert'; import dep from 'dep'; import fs from 'node:fs';\n" +
      "test('dep', () => { assert.equal(dep, 42); fs.writeFileSync(new URL('../node_modules/dep/touched.txt', import.meta.url), 'x'); });\n",
  });
  let link = null;
  const v = await runChecks({
    dir: work,
    tools: { nodeModules: (d) => join(repo, d, 'node_modules') },
    linkNodeModules: (r, d, s) => (link = linkNodeModules(r, d, s, cache)),
    items: [{ id: 'dep', label: 'dep', prepare: 'node-modules', depsDir: 'pkg', steps: [{ cmd: 'node', args: ['--test'], files: ['test/dep.test.mjs'], cwd: 'pkg' }] }],
  });
  assert.equal(v.items[0].status, 'passed', v.items[0].output);
  assert.ok(link);
  assert.equal(existsSync(link), false, '검사가 끝나면 연결을 지운다');
  assert.equal(existsSync(join(repo, 'pkg', 'node_modules', 'dep', 'touched.txt')), false, '작업 폴더의 node_modules는 바뀌지 않는다');
  assert.ok(lstatSync(join(repo, 'pkg', 'node_modules', 'dep', 'index.js')).isFile());
});

test('fsView.walk는 node_modules를 건너뛴다', () => {
  const d = join(root, 'walk');
  mkdirSync(join(d, 'a', 'node_modules', 'x'), { recursive: true });
  mkdirSync(join(d, 'a', 'test'), { recursive: true });
  writeFileSync(join(d, 'a', 'node_modules', 'x', 'y.test.js'), '');
  writeFileSync(join(d, 'a', 'test', 'z.test.js'), '');
  assert.deepEqual(fsView(d).walk('a'), ['test/z.test.js']);
  assert.equal(fsView(d).isDir('a/test'), true);
});
