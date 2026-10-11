// 이어받기 재현: 앞 수정 요청의 최종 패치는 서버(DB)에만 있고 작업 폴더에는 없다.
// 후속 요청은 지금 작업 폴더 스냅샷 + 그 패치를 얹은 복사본에서 시작해야 하고, 작업 폴더는 그대로여야 한다.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, test } from 'node:test';
import {
  applyToWorkingTree,
  collectDiff,
  createContinueWorktree,
  createWorktree,
  removeWorktree,
  snapshot,
} from '../src/git_ops.mjs';
import { buildChangePrompt, buildPlanPrompt, continuePatch, continueSection } from '../src/lib.mjs';

const PREV = '11111111-1111-4111-8111-111111111111';
const NEXT = '22222222-2222-4222-8222-222222222222';
const MARK = 'PATCH_BODY_MARKER_7f3a';
const repo = mkdtempSync(join(tmpdir(), 'ygg-continue-'));
const git = (...args) => execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { cwd: repo, encoding: 'utf8' }).trim();
const put = (path, text, root = repo) => {
  mkdirSync(join(root, path, '..'), { recursive: true });
  writeFileSync(join(root, path), text);
};
const read = (path, root = repo) => readFileSync(join(root, path), 'utf8');
const lines = (n, f = (i) => `line ${i}`) => Array.from({ length: n }, (_, i) => `${f(i + 1)}\n`).join('');

git('init', '-q', '-b', 'main');
git('config', 'core.autocrlf', 'false');
put('memory.ts', lines(12));
put('old_name.ts', 'export const x = 1;\n');
put('gone.ts', 'remove me\n');
put('other.ts', 'other\n');
git('add', '-A');
git('commit', '-q', '-m', 'init');

// 앞 요청(PREV)이 복사본에서 만든 최종 패치. 서버에는 diff·통계·기준 커밋으로 저장된다.
const prevBase = snapshot(repo, PREV, 'base');
const prevDir = createWorktree(repo, PREV, prevBase.commit);
put('memory.ts', lines(12, (i) => (i === 6 ? `line 6 ${MARK}` : `line ${i}`)), prevDir);
put('memory_conflict.ts', `export const created = '${MARK}';\n`, prevDir);
unlinkSync(join(prevDir, 'gone.ts'));
renameSync(join(prevDir, 'old_name.ts'), join(prevDir, 'new_name.ts'));
const stored = collectDiff(prevDir, prevBase.commit);
removeWorktree(repo, prevDir);
const patch = {
  ok: true,
  request_id: PREV,
  title: '개인화 기억',
  status: 'ready',
  round: 2,
  diff: stored.diff,
  diff_stats: stored.stats,
  base_commit: prevBase.commit,
};

const statusOf = () => git('status', '--porcelain');
const dirs = [];
after(() => {
  for (const d of dirs) removeWorktree(repo, d);
  rmSync(repo, { recursive: true, force: true });
});

/** 각 시험은 작업 폴더를 init 커밋 + 주어진 변경으로 맞춘다. */
function workingFolder(edit = () => {}) {
  git('reset', '-q', '--hard', 'main');
  git('clean', '-qfd');
  edit();
}

test('재현 전제: 패치는 저장돼 있지만 작업 폴더에는 없다', () => {
  workingFolder();
  assert.equal(stored.stats.files, 4);
  assert.ok(!read('memory.ts').includes(MARK));
  assert.ok(!existsSync(join(repo, 'memory_conflict.ts')));
});

test('그대로 얹기: 복사본에 앞 패치와 지금 작업 폴더 변경이 함께 있고, 작업 폴더는 그대로다', () => {
  workingFolder(() => put('other.ts', 'other edited in working folder\n'));
  const before = statusOf();
  const base = snapshot(repo, NEXT, 'base');
  const c = createContinueWorktree(repo, NEXT, base.commit, patch);
  dirs.push(c.dir);
  assert.equal(c.applied, 'applied');
  assert.deepEqual(c.stats, stored.stats);
  assert.ok(read('memory.ts', c.dir).includes(MARK));
  assert.ok(existsSync(join(c.dir, 'memory_conflict.ts')));
  assert.ok(existsSync(join(c.dir, 'new_name.ts')));
  assert.ok(!existsSync(join(c.dir, 'gone.ts')));
  assert.equal(read('other.ts', c.dir), 'other edited in working folder\n');
  assert.equal(statusOf(), before, '작업 폴더·인덱스는 바뀌지 않음');
  assert.ok(!read('memory.ts').includes(MARK));

  // 후속 수정의 diff는 스냅샷 기준이라 앞 패치를 담고, 작업 폴더에 그대로 적용된다
  put('memory.ts', read('memory.ts', c.dir).replace('line 2\n', 'line 2 follow-up\n'), c.dir);
  const next = collectDiff(c.dir, base.commit);
  assert.match(next.diff, /memory_conflict\.ts/);
  assert.match(next.diff, /follow-up/);
  applyToWorkingTree(repo, NEXT, next.diff);
  assert.ok(read('memory.ts').includes(MARK));
  assert.ok(read('memory.ts').includes('follow-up'));
  assert.equal(read('other.ts'), 'other edited in working folder\n', '기존 사용자 변경 보존');
  removeWorktree(repo, c.dir);
});

test('이미 작업 폴더에 있는 패치는 다시 얹지 않는다(already_present)', () => {
  workingFolder(() => applyToWorkingTree(repo, PREV, stored.diff));
  const base = snapshot(repo, NEXT, 'base');
  const c = createContinueWorktree(repo, NEXT, base.commit, patch);
  dirs.push(c.dir);
  assert.equal(c.applied, 'already_present');
  assert.equal(collectDiff(c.dir, base.commit).stats.files, 0);
  removeWorktree(repo, c.dir);
});

test('주변 줄만 바뀌었으면 3-way로 합쳐 얹는다(merged)', () => {
  workingFolder(() => put('memory.ts', lines(12, (i) => (i === 3 ? 'line 3 user' : `line ${i}`))));
  const base = snapshot(repo, NEXT, 'base');
  const c = createContinueWorktree(repo, NEXT, base.commit, patch);
  dirs.push(c.dir);
  assert.equal(c.applied, 'merged');
  const merged = read('memory.ts', c.dir);
  assert.ok(merged.includes('line 3 user') && merged.includes(MARK));
  assert.ok(!read('memory.ts').includes(MARK));
  removeWorktree(repo, c.dir);
});

test('같은 줄을 사용자가 바꿨으면 얹지 않고 충돌 파일을 알린다. 작업 폴더·복사본 모두 남지 않는다', () => {
  workingFolder(() => put('memory.ts', lines(12, (i) => (i === 6 ? 'line 6 user' : `line ${i}`))));
  const before = statusOf();
  const userText = read('memory.ts');
  const base = snapshot(repo, NEXT, 'base');
  let err;
  try {
    createContinueWorktree(repo, NEXT, base.commit, patch);
  } catch (e) {
    err = e;
  }
  assert.ok(err, '충돌은 예외');
  assert.deepEqual(err.detail.conflicts, ['memory.ts']);
  assert.match(err.message, /memory\.ts/);
  assert.ok(!err.message.includes(MARK), '오류에 패치 본문 없음');
  assert.equal(read('memory.ts'), userText);
  assert.equal(statusOf(), before);
  assert.ok(!git('worktree', 'list').includes(NEXT), '복사본 정리');
});

test('잘린 패치·통계가 다른 패치(다른 회차)는 쓰지 않는다', () => {
  workingFolder();
  const base = snapshot(repo, NEXT, 'base');
  const cut = stored.diff.slice(0, stored.diff.indexOf('diff --git', 10));
  for (const bad of [
    { ...patch, diff: cut },
    { ...patch, diff_stats: { ...stored.stats, additions: stored.stats.additions + 1 } },
    { ...patch, diff_stats: null },
    { ...patch, diff: `${stored.diff.slice(0, -40)}` },
  ]) {
    assert.throws(
      () => createContinueWorktree(repo, NEXT, base.commit, bad),
      (e) => /불완전|읽지 못했습니다/.test(e.message) && !e.message.includes(MARK),
    );
    assert.ok(!git('worktree', 'list').includes(NEXT));
  }
  assert.throws(() => createContinueWorktree(repo, NEXT, base.commit, { ...patch, diff: '' }), /비어 있습니다/);
  const secret = 'diff --git a/.env b/.env\nnew file mode 100644\n--- /dev/null\n+++ b/.env\n@@ -0,0 +1 @@\n+K=1\n';
  assert.throws(
    () => createContinueWorktree(repo, NEXT, base.commit, { ...patch, diff: secret, diff_stats: { files: 1, additions: 1, deletions: 0 } }),
    /보호된 경로/,
  );
});

test('미완성 패치: 자기 기준 커밋에 적용될 때만 얹고, 기준 커밋이 없거나 안 맞으면 쓰지 않는다', () => {
  const partial = { ...patch, partial: 'timeout' };
  workingFolder(() => put('other.ts', 'other edited in working folder\n'));
  const base = snapshot(repo, NEXT, 'base');
  const c = createContinueWorktree(repo, NEXT, base.commit, partial);
  dirs.push(c.dir);
  assert.equal(c.applied, 'applied');
  assert.ok(read('memory.ts', c.dir).includes(MARK));
  removeWorktree(repo, c.dir);

  assert.throws(
    () => createContinueWorktree(repo, NEXT, base.commit, { ...partial, base_commit: 'f'.repeat(40) }),
    (e) => /기준 커밋을 이 PC에서/.test(e.message) && !e.message.includes(MARK),
  );
  assert.ok(!git('worktree', 'list').includes(NEXT));

  // 같은 줄이 이미 다른 커밋: 통계는 맞아도 그 커밋에는 적용되지 않는다
  workingFolder(() => put('memory.ts', lines(12, (i) => (i === 6 ? 'line 6 other' : `line ${i}`))));
  const other = snapshot(repo, NEXT, 'base');
  workingFolder();
  const fresh = snapshot(repo, NEXT, 'base');
  let err;
  try {
    createContinueWorktree(repo, NEXT, fresh.commit, { ...partial, base_commit: other.commit });
  } catch (e) {
    err = e;
  }
  assert.ok(err, '기준 커밋에 안 맞으면 예외');
  assert.match(err.message, /기준 커밋에 그대로 적용되지 않아/);
  assert.deepEqual(err.detail.conflicts, ['memory.ts']);
  assert.ok(!git('worktree', 'list').includes(NEXT));

  // 표시 없는 패치는 기준 커밋 확인 없이 지금 스냅샷 기준으로만 본다(기존 동작)
  const d = createContinueWorktree(repo, NEXT, fresh.commit, { ...patch, base_commit: other.commit });
  dirs.push(d.dir);
  assert.equal(d.applied, 'applied');
  removeWorktree(repo, d.dir);
});

const job = (mode, extra = {}) => ({
  id: NEXT,
  mode,
  round: 1,
  request: { goal: '기억 충돌 감지', continue_from: { request_id: PREV, title: '개인화 기억' } },
  base_patch: patch,
  ...extra,
});

test('continuePatch: 서버가 준 패치만 쓰고, 못 받았거나 다른 요청 것이면 이유와 함께 멈춘다', () => {
  assert.equal(continuePatch(job('change')), patch);
  assert.equal(continuePatch({ ...job('change'), request: { goal: 'x' } }), null);
  assert.equal(continuePatch({ ...job('change'), request: { ...job('change').request, fix_of: { request_id: PREV } } }), null);
  assert.throws(() => continuePatch(job('change', { base_patch: null })), /받지 못했습니다/);
  assert.throws(
    () => continuePatch(job('change', { base_patch: { ok: false, error: 'not_final', request_id: PREV, status: 'running' } })),
    /끝나지 않았거나.*상태 running/,
  );
  assert.throws(
    () => continuePatch(job('plan', { base_patch: { ok: false, error: 'superseded', request_id: PREV, superseded_by: NEXT } })),
    new RegExp(`대체됐습니다.*${NEXT}`),
  );
  assert.throws(() => continuePatch(job('change', { base_patch: { ok: false, error: 'incomplete', request_id: PREV } })), /불완전/);
  assert.throws(() => continuePatch(job('change', { base_patch: { ...patch, request_id: NEXT } })), /다른 요청/);
  assert.throws(() => continuePatch(job('change', { base_patch: { ...patch, base_commit: '' } })), /기준 커밋/);
});

test('프롬프트: 얹힌 패치의 요청·회차·파일만 알리고 본문은 넣지 않는다', () => {
  for (const p of [buildChangePrompt(job('change')), buildPlanPrompt(job('plan'))]) {
    assert.match(p, /## 이어받은 앞 수정/);
    assert.ok(p.includes(PREV));
    assert.match(p, /2회차/);
    assert.match(p, /- memory_conflict\.ts/);
    assert.ok(!p.includes(MARK), '패치 본문 없음');
  }
  assert.equal(continueSection({ ...job('change'), base_patch: null }), '');
  assert.equal(continueSection({ ...job('change'), request: { goal: 'x' } }), '');
  assert.ok(!continueSection(job('change')).includes('검사된 적이 없다'));
});

test('프롬프트: 미완성 패치는 검사 안 된 출발점이라고 알리고 앞 변경도 검토하게 한다', () => {
  const partial = { ...patch, partial: 'timeout' };
  const change = continueSection(job('change', { base_patch: partial }));
  assert.match(change, /2회차 미완성 패치/);
  assert.match(change, /검사된 적이 없다/);
  assert.match(change, /앞 변경도 요청에 맞는지/);
  assert.match(change, /최종 결과 전체/);
  const plan = continueSection(job('plan', { base_patch: partial }));
  assert.match(plan, /검사된 적이 없다/);
  assert.ok(!plan.includes('고친다.'), '조율은 고치지 않음');
});
