// 수정 모드의 git 작업. 실제 작업 폴더의 인덱스·브랜치·HEAD는 바꾸지 않는다.
//   스냅샷: 임시 인덱스(GIT_INDEX_FILE)에 작업 폴더 전체(커밋 안 된 변경·새 파일)를 담아 커밋 객체를 만들고 ref로 붙잡는다.
//   복사본: 그 커밋으로 `git worktree add --detach`. Cursor는 여기서만 고친다.
//   적용: `git apply --check`가 통과할 때만 작업 폴더에 적용한다. 적용 전 상태는 before-apply ref에 남긴다.
// 설계: docs/architecture/ai-think-actions.md §4.2
import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { isProtectedPath, isSecretPath, parseNumstat } from './lib.mjs';

const IDENTITY = {
  GIT_AUTHOR_NAME: 'code-bridge',
  GIT_AUTHOR_EMAIL: 'code-bridge@localhost',
  GIT_COMMITTER_NAME: 'code-bridge',
  GIT_COMMITTER_EMAIL: 'code-bridge@localhost',
};

export class GitOpError extends Error {
  constructor(message, detail = {}) {
    super(message);
    this.name = 'GitOpError';
    this.detail = detail;
  }
}

function run(cwd, args, { env = {}, input, buffer = false } = {}) {
  try {
    return execFileSync('git', args, {
      cwd,
      input,
      env: { ...process.env, ...env },
      encoding: buffer ? 'buffer' : 'utf8',
      maxBuffer: 256 * 1024 * 1024,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
  } catch (e) {
    const stderr = e.stderr ? e.stderr.toString('utf8') : '';
    throw new GitOpError(`git ${args[0]} 실패: ${stderr.trim().slice(0, 1500) || e.message}`, { stderr });
  }
}

const git = (cwd, args, opts) => run(cwd, args, opts).toString().trim();

export function refName(requestId, label) {
  if (!/^[0-9a-f-]{36}$/i.test(requestId)) throw new GitOpError('요청 id 형식 오류');
  return `refs/code-bridge/${requestId}/${label}`;
}

/** 작업 폴더 상태를 커밋 객체로 만든다. 비밀 경로는 뺀다. 반환: { commit, excluded } */
export function snapshot(repo, requestId, label) {
  const tmpIndex = join(tmpdir(), `ygg-code-bridge-index-${requestId}-${label}-${process.pid}`);
  const realIndex = resolve(repo, git(repo, ['rev-parse', '--git-path', 'index']));
  // 실제 인덱스를 복사해 쓰면 파일 상태 캐시 덕에 빠르다. 실제 인덱스 파일은 읽기만 한다.
  if (existsSync(realIndex)) copyFileSync(realIndex, tmpIndex);
  const env = { GIT_INDEX_FILE: tmpIndex, ...IDENTITY };
  try {
    run(repo, ['add', '-A'], { env });
    const files = run(repo, ['ls-files', '-z'], { env }).toString().split('\0').filter(Boolean);
    const secret = files.filter(isSecretPath);
    if (secret.length > 0) {
      run(repo, ['update-index', '--force-remove', '-z', '--stdin'], { env, input: `${secret.join('\0')}\0` });
    }
    const tree = git(repo, ['write-tree'], { env });
    const head = git(repo, ['rev-parse', '--verify', 'HEAD']);
    const commit = git(repo, ['commit-tree', tree, '-p', head, '-m', `code-bridge ${label} ${requestId}`], { env });
    run(repo, ['update-ref', refName(requestId, label), commit]);
    return { commit, excluded: secret.length };
  } finally {
    rmSync(tmpIndex, { force: true });
  }
}

export function worktreeDir(requestId) {
  return join(tmpdir(), 'ygg-code-bridge', requestId);
}

export function createWorktree(repo, requestId, commit) {
  const dir = worktreeDir(requestId);
  removeWorktree(repo, dir);
  mkdirSync(join(tmpdir(), 'ygg-code-bridge'), { recursive: true });
  run(repo, ['worktree', 'add', '--detach', '--force', dir, commit]);
  return dir;
}

export function removeWorktree(repo, dir) {
  if (existsSync(dir)) {
    try {
      run(repo, ['worktree', 'remove', '--force', '--force', dir]);
    } catch {
      rmSync(dir, { recursive: true, force: true });
    }
  }
  try {
    run(repo, ['worktree', 'prune']);
  } catch {
    // 정리 실패는 다음 작업 때 다시 한다
  }
}

/**
 * 복사본에서 바뀐 내용을 모은다. 복사본의 인덱스만 쓴다.
 * 반환: { diff, stats, protectedPaths, utf8 }
 */
export function collectDiff(dir, baseCommit) {
  run(dir, ['add', '-A']);
  const raw = run(dir, ['diff', '--cached', '--binary', '--no-color', '--no-ext-diff', baseCommit], { buffer: true });
  const diff = raw.toString('utf8');
  const utf8 = Buffer.from(diff, 'utf8').equals(raw);
  const stats = parseNumstat(run(dir, ['diff', '--cached', '--numstat', '-z', '--no-color', baseCommit]).toString());
  const names = run(dir, ['diff', '--cached', '--name-only', '-z', '--no-renames', baseCommit]).toString().split('\0').filter(Boolean);
  return { diff, stats, protectedPaths: names.filter(isProtectedPath), utf8 };
}

function patchFile(requestId, diff) {
  const file = join(tmpdir(), `ygg-code-bridge-${requestId}.patch`);
  writeFileSync(file, diff, 'utf8');
  return file;
}

/** `error: patch failed: a.dart:12`, `error: a.dart: patch does not apply` 같은 줄에서 경로만 뽑는다. */
export function conflictFiles(stderr) {
  const out = new Set();
  for (const m of String(stderr ?? '').matchAll(/^error: (?:patch failed: )?([^:\n]+?)(?::\d+)?(?:: [^\n]*)?$/gm)) {
    const p = m[1].trim();
    if (p && !/\s/.test(p)) out.add(p);
  }
  return [...out].slice(0, 50);
}

/**
 * 작업 폴더에 적용(reverse=false) 또는 되돌리기(reverse=true).
 * 검사가 실패하면 아무것도 바꾸지 않는다. 반환: { ok, error?, conflicts?, backup_ref?, files }
 */
export function applyToWorkingTree(repo, requestId, diff, { reverse = false } = {}) {
  if (typeof diff !== 'string' || diff.trim() === '') return { ok: false, error: '적용할 변경이 없습니다.', files: 0 };
  const names = [...diff.matchAll(/^diff --git a\/(.+?) b\/(.+)$/gm)].flatMap((m) => [m[1], m[2]]);
  const blocked = names.filter(isProtectedPath);
  if (blocked.length > 0) return { ok: false, error: '보호된 경로가 들어 있어 적용하지 않았습니다.', conflicts: blocked, files: 0 };

  const label = reverse ? 'before-revert' : 'before-apply';
  const backup = snapshot(repo, requestId, label);
  const file = patchFile(requestId, diff);
  const args = ['apply', '--binary', '--whitespace=nowarn', ...(reverse ? ['-R'] : [])];
  try {
    try {
      run(repo, [...args, '--check', file]);
    } catch (e) {
      const stderr = e instanceof GitOpError ? e.detail.stderr : String(e);
      return {
        ok: false,
        error: '작업 폴더가 그사이 바뀌어 충돌합니다. 아무것도 바꾸지 않았습니다.',
        conflicts: conflictFiles(stderr),
        detail: String(stderr).slice(0, 1500),
        backup_ref: refName(requestId, label),
        files: 0,
      };
    }
    run(repo, [...args, file]);
    return { ok: true, backup_ref: refName(requestId, label), backup_commit: backup.commit, files: new Set(names).size };
  } finally {
    rmSync(file, { force: true });
  }
}

/** 30일 지난 참조를 지운다. 반환: 지운 수 */
export function pruneRefs(repo, days = 30, now = Date.now()) {
  const out = git(repo, ['for-each-ref', '--format=%(refname) %(creatordate:unix)', 'refs/code-bridge/']);
  let removed = 0;
  for (const line of out.split('\n').filter(Boolean)) {
    const [ref, ts] = line.split(' ');
    if (Number(ts) * 1000 < now - days * 86_400_000) {
      run(repo, ['update-ref', '-d', ref]);
      removed += 1;
    }
  }
  return removed;
}
