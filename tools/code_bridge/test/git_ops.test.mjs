import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, test } from 'node:test';
import { applyToWorkingTree, collectDiff, conflictFiles, createWorktree, pruneRefs, removeWorktree, snapshot } from '../src/git_ops.mjs';

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
