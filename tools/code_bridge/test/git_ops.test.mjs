import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, test } from 'node:test';
import {
  applyPatchInVerifyWorktree,
  applyToWorkingTree,
  collectDiff,
  conflictFiles,
  createFixWorktree,
  createWorktree,
  intersectPaths,
  listTree,
  pathsFromDiff,
  pruneRefs,
  removeVerifyWorktree,
  removeWorktree,
  resolveBaseCommit,
  snapshot,
  worktreeDir,
} from '../src/git_ops.mjs';

const ID = '0f0e0d0c-0b0a-4908-8706-050403020100';
const repo = mkdtempSync(join(tmpdir(), 'ygg-git-ops-'));
const git = (...args) => execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@t', ...args], { cwd: repo, encoding: 'utf8' }).trim();
const put = (path, text) => {
  mkdirSync(join(repo, path, '..'), { recursive: true });
  writeFileSync(join(repo, path), text);
};
const read = (path) => readFileSync(join(repo, path), 'utf8');

git('init', '-q', '-b', 'main');
git('config', 'core.autocrlf', 'false');
put('a.txt', 'one\ntwo\nthree\n');
put('supabase/.temp/cli-latest', 'v1\n');
put('.cursor/hooks.json', '{}\n');
git('add', '-A');
git('commit', '-q', '-m', 'init');
// 커밋 안 된 변경, 새 파일, 비밀 파일
put('a.txt', 'one\nTWO\nthree\n');
put('b.txt', 'new file\n');
put('.env', 'SECRET=1\n');
git('add', 'b.txt');
const statusBefore = git('status', '--porcelain');
const indexBefore = git('diff', '--cached', '--name-only');

let base;
let dir;
after(() => {
  if (dir) removeWorktree(repo, dir);
  rmSync(repo, { recursive: true, force: true });
});

test('스냅샷: 커밋 안 된 변경·새 파일은 담고, 비밀 경로는 빼고, 실제 인덱스·브랜치는 그대로', () => {
  base = snapshot(repo, ID, 'base');
  assert.equal(git('cat-file', '-p', `${base.commit}:a.txt`), 'one\nTWO\nthree');
  assert.equal(git('cat-file', '-p', `${base.commit}:b.txt`), 'new file');
  const files = git('ls-tree', '-r', '--name-only', base.commit).split('\n');
  assert.ok(!files.includes('.env'));
  assert.ok(!files.some((f) => f.startsWith('supabase/.temp')));
  assert.equal(base.excluded, 2);
  assert.equal(git('status', '--porcelain'), statusBefore);
  assert.equal(git('diff', '--cached', '--name-only'), indexBefore);
  assert.equal(git('rev-parse', '--abbrev-ref', 'HEAD'), 'main');
  assert.equal(git('rev-parse', `refs/code-bridge/${ID}/base`), base.commit);
});

test('복사본에서 고친 내용을 diff로 모은다', () => {
  dir = createWorktree(repo, ID, base.commit);
  writeFileSync(join(dir, 'a.txt'), 'one\nTWO\nthree\nfour\n');
  unlinkSync(join(dir, 'b.txt'));
  writeFileSync(join(dir, 'c.txt'), 'created\n');
  const d = collectDiff(dir, base.commit);
  assert.ok(d.utf8);
  assert.equal(d.stats.files, 3);
  assert.deepEqual(d.protectedPaths, []);
  assert.match(d.diff, /^diff --git a\/c\.txt b\/c\.txt/m);
  assert.equal(read('a.txt'), 'one\nTWO\nthree\n', '실제 작업 폴더는 아직 그대로');
});

test('훅 파일을 건드리면 보호 경로로 잡힌다', () => {
  const other = createWorktree(repo, 'aaaaaaaa-0b0a-4908-8706-050403020100', base.commit);
  try {
    writeFileSync(join(other, '.cursor', 'hooks.json'), '{"x":1}\n');
    assert.deepEqual(collectDiff(other, base.commit).protectedPaths, ['.cursor/hooks.json']);
  } finally {
    removeWorktree(repo, other);
  }
});

test('적용 → 되돌리기. 실제 인덱스는 바뀌지 않는다', () => {
  const { diff } = collectDiff(dir, base.commit);
  const r = applyToWorkingTree(repo, ID, diff);
  assert.equal(r.ok, true, JSON.stringify(r));
  assert.equal(read('a.txt'), 'one\nTWO\nthree\nfour\n');
  assert.ok(!existsSync(join(repo, 'b.txt')));
  assert.equal(read('c.txt'), 'created\n');
  assert.equal(read('.env'), 'SECRET=1\n');
  assert.equal(git('diff', '--cached', '--name-only'), indexBefore);
  assert.ok(git('rev-parse', `refs/code-bridge/${ID}/before-apply`));

  const back = applyToWorkingTree(repo, ID, diff, { reverse: true });
  assert.equal(back.ok, true, JSON.stringify(back));
  assert.equal(read('a.txt'), 'one\nTWO\nthree\n');
  assert.equal(read('b.txt'), 'new file\n');
  assert.ok(!existsSync(join(repo, 'c.txt')));
});

test('그사이 작업 폴더가 바뀌어 충돌하면 아무것도 바꾸지 않는다', () => {
  const { diff } = collectDiff(dir, base.commit);
  put('a.txt', 'one\nchanged by user\nthree\n');
  const r = applyToWorkingTree(repo, ID, diff);
  assert.equal(r.ok, false);
  assert.deepEqual(r.conflicts, ['a.txt']);
  assert.equal(read('a.txt'), 'one\nchanged by user\nthree\n');
  assert.equal(read('b.txt'), 'new file\n');
  assert.ok(!existsSync(join(repo, 'c.txt')), '다른 파일도 적용되지 않는다');
});

test('보호 경로가 든 diff와 빈 diff는 적용하지 않는다', () => {
  const bad = 'diff --git a/.cursor/hooks.json b/.cursor/hooks.json\n--- a/.cursor/hooks.json\n+++ b/.cursor/hooks.json\n@@ -1 +1 @@\n-{}\n+{"x":1}\n';
  assert.equal(applyToWorkingTree(repo, ID, bad).ok, false);
  assert.equal(applyToWorkingTree(repo, ID, '').ok, false);
});

test('오래된 참조를 정리한다', () => {
  assert.equal(pruneRefs(repo, 30), 0);
  assert.ok(pruneRefs(repo, 30, Date.now() + 40 * 86_400_000) >= 2);
  assert.equal(git('for-each-ref', 'refs/code-bridge/'), '');
});

test('충돌 파일 이름 해석', () => {
  assert.deepEqual(
    conflictFiles('error: patch failed: lib/a.dart:12\nerror: lib/a.dart: patch does not apply\nerror: lib/b.dart: already exists in working directory\n'),
    ['lib/a.dart', 'lib/b.dart'],
  );
});

test('diff 경로·교집합·base ref', () => {
  const { diff } = collectDiff(dir, base.commit);
  assert.deepEqual(pathsFromDiff(diff).sort(), ['a.txt', 'b.txt', 'c.txt'], '지운 파일도 포함');
  assert.deepEqual(intersectPaths(['a.txt', 'c.txt'], ['a.txt', 'b.txt']), ['a.txt']);
  assert.equal(resolveBaseCommit(repo, ID, base.commit).error, 'base_ref_missing', '앞 시험에서 참조를 정리했다');
  git('update-ref', `refs/code-bridge/${ID}/base`, base.commit);
  const resolved = resolveBaseCommit(repo, ID, base.commit);
  assert.equal(resolved.ok, true);
  assert.equal(resolved.commit, base.commit);
  assert.equal(resolveBaseCommit(repo, ID, '0'.repeat(40)).ok, false);
});

test('재수정 복사본: 앞 기준 커밋에 앞 diff를 얹고, 새 diff는 같은 기준에서 누적된다', () => {
  const { diff } = collectDiff(dir, base.commit);
  const NEXT = '1f0e0d0c-0b0a-4908-8706-050403020100';
  const fixDir = createFixWorktree(repo, NEXT, base.commit, diff);
  try {
    assert.equal(readFileSync(join(fixDir, 'a.txt'), 'utf8'), 'one\nTWO\nthree\nfour\n');
    assert.ok(!existsSync(join(fixDir, 'b.txt')));
    assert.equal(git('rev-parse', `refs/code-bridge/${NEXT}/base`), base.commit);
    writeFileSync(join(fixDir, 'c.txt'), 'created\nfixed\n');
    const d = collectDiff(fixDir, base.commit);
    assert.equal(d.stats.files, 3);
    assert.match(d.diff, /\+four/);
    assert.match(d.diff, /\+fixed/);
  } finally {
    removeWorktree(repo, fixDir);
  }
  assert.throws(() => createFixWorktree(repo, NEXT, '0'.repeat(40), diff), /기준 커밋을 이 PC에서 찾지 못했습니다/);
  assert.throws(() => createFixWorktree(repo, NEXT, base.commit, ''), /diff가 없습니다/);
  const hook = 'diff --git a/.cursor/hooks.json b/.cursor/hooks.json\n--- a/.cursor/hooks.json\n+++ b/.cursor/hooks.json\n@@ -1 +1 @@\n-{}\n+{"x":1}\n';
  assert.throws(() => createFixWorktree(repo, NEXT, base.commit, hook), /보호된 경로/);
  const stale = 'diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-nope\n+x\n';
  assert.throws(() => createFixWorktree(repo, NEXT, base.commit, stale), /다시 얹지 못했습니다/);
  assert.ok(!existsSync(worktreeDir(NEXT)), '실패하면 복사본을 남기지 않는다');
});

test('검사 비교용 기준 복사본은 다른 폴더에 만든다', () => {
  const b = createWorktree(repo, ID, base.commit, { suffix: 'baseline' });
  try {
    assert.ok(b.endsWith(`${ID}-baseline`));
    assert.equal(readFileSync(join(b, 'a.txt'), 'utf8'), 'one\nTWO\nthree\n');
    assert.deepEqual(listTree(repo, base.commit, '.cursor'), ['hooks.json']);
  } finally {
    removeWorktree(repo, b);
  }
});

test('격리 worktree에만 패치를 적용하고 본 작업 폴더는 그대로', () => {
  const { diff } = collectDiff(dir, base.commit);
  const mainBefore = read('a.txt');
  const statusMain = git('status', '--porcelain');
  const r = applyPatchInVerifyWorktree(repo, ID, base.commit, diff);
  assert.equal(r.ok, true, JSON.stringify(r));
  assert.ok(r.worktree.includes('-verify'));
  assert.equal(readFileSync(join(r.worktree, 'a.txt'), 'utf8'), 'one\nTWO\nthree\nfour\n');
  assert.equal(read('a.txt'), mainBefore, '본 작업 폴더는 바뀌지 않음');
  assert.equal(git('status', '--porcelain'), statusMain);
  removeVerifyWorktree(repo, ID);
});
