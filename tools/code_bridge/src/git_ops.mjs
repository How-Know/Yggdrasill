// 수정 모드의 git 작업. 실제 작업 폴더의 인덱스·브랜치·HEAD는 바꾸지 않는다.
//   스냅샷: 임시 인덱스(GIT_INDEX_FILE)에 작업 폴더 전체(커밋 안 된 변경·새 파일)를 담아 커밋 객체를 만들고 ref로 붙잡는다.
//   복사본: 그 커밋으로 `git worktree add --detach`. Cursor는 여기서만 고친다.
//   적용: `git apply --check`가 통과할 때만 작업 폴더에 적용한다. 적용 전 상태는 before-apply ref에 남긴다.
//   이어받기: 스냅샷 복사본에 앞 수정 요청의 최종 패치를 얹는다(createContinueWorktree). 충돌하면 얹지 않는다.
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

export function worktreeDir(requestId, { verify = false, suffix = verify ? 'verify' : '' } = {}) {
  return join(tmpdir(), 'ygg-code-bridge', suffix ? `${requestId}-${suffix}` : requestId);
}

/** diff 헤더에서 바뀌는 저장소 상대 경로를 모은다(중복 제거). */
export function pathsFromDiff(diff) {
  const names = new Set();
  for (const m of String(diff ?? '').matchAll(/^diff --git a\/(.+?) b\/(.+?)$/gm)) {
    names.add(m[1]);
    names.add(m[2]);
  }
  return [...names].sort();
}

/** 패치에 포함된 마이그레이션·Edge·앱 경로 목록(별도 export 없이 diff만으로). */
export function categorizePatchPaths(paths) {
  const migrations = [];
  const edgeFunctions = [];
  const apps = [];
  const docs = [];
  const tools = [];
  const other = [];
  for (const p of paths) {
    if (p.startsWith('supabase/migrations/')) migrations.push(p);
    else if (p.startsWith('supabase/functions/')) edgeFunctions.push(p);
    else if (p.startsWith('apps/')) apps.push(p);
    else if (p.startsWith('docs/')) docs.push(p);
    else if (p.startsWith('tools/')) tools.push(p);
    else other.push(p);
  }
  return { migrations, edgeFunctions, apps, docs, tools, other };
}

function refExists(repo, ref) {
  try {
    git(repo, ['rev-parse', '--verify', ref]);
    return true;
  } catch {
    return false;
  }
}

/**
 * 패치 기준 커밋을 찾는다. `refs/code-bridge/<id>/base`가 있어야 하며 DB의 base_commit과 일치해야 한다.
 * ref가 없으면 DB 해시만으로 재현했다고 보지 않는다.
 */
export function resolveBaseCommit(repo, requestId, baseCommitFromResult) {
  const ref = refName(requestId, 'base');
  const db = typeof baseCommitFromResult === 'string' ? baseCommitFromResult.trim() : '';
  if (!refExists(repo, ref)) {
    return {
      ok: false,
      error: 'base_ref_missing',
      ref,
      db_commit: db || null,
      message: 'refs/code-bridge/<요청 id>/base 객체가 없습니다. DB 해시만으로 기준 상태를 재현하지 마세요.',
    };
  }
  const commit = git(repo, ['rev-parse', ref]);
  if (db && db !== commit) {
    return {
      ok: false,
      error: 'base_commit_mismatch',
      ref,
      ref_commit: commit,
      db_commit: db,
      message: 'DB base_commit과 로컬 ref가 다릅니다.',
    };
  }
  return { ok: true, commit, ref, source: 'ref' };
}

/** 작업 폴더의 미커밋·미추적 경로(저장소 기준). */
export function workingTreeChangedPaths(repo) {
  const raw = run(repo, ['status', '--porcelain']).toString();
  const out = new Set();
  for (const line of raw.split('\n').filter(Boolean)) {
    if (line.length < 4) continue;
    let path = line.slice(3).trim();
    if (path.startsWith('"') && path.endsWith('"')) path = path.slice(1, -1);
    if (path.includes(' -> ')) path = path.split(' -> ').pop().trim();
    if (path) out.add(path);
  }
  return [...out].sort();
}

export function intersectPaths(a, b) {
  const set = new Set(b);
  return a.filter((p) => set.has(p)).sort();
}

/** `git apply --stat` 출력과 diff_stats·경로 수를 대조한다. */
export function patchApplyStat(repo, diff) {
  if (typeof diff !== 'string' || diff.trim() === '') {
    return { ok: false, error: 'empty_patch', stat: '', paths: [] };
  }
  const file = patchFile('stat-check', diff);
  try {
    const stat = run(repo, ['apply', '--stat', '--summary', file]).toString();
    const paths = pathsFromDiff(diff);
    return { ok: true, stat: stat.trim(), paths, file_count: paths.length };
  } catch (e) {
    const stderr = e instanceof GitOpError ? e.detail.stderr : String(e);
    return { ok: false, error: 'apply_stat_failed', detail: String(stderr).slice(0, 1500), paths: pathsFromDiff(diff) };
  } finally {
    rmSync(file, { force: true });
  }
}

/** 카드 diff_stats와 패치 본문·apply --stat이 맞는지 검사한다. */
export function validatePatchConsistency(repo, diff, { diff_stats: expected } = {}) {
  const paths = pathsFromDiff(diff);
  const issues = [];
  if (!diff || !String(diff).trim()) issues.push('empty_diff');
  const stat = patchApplyStat(repo, diff);
  if (!stat.ok) issues.push(`apply_stat:${stat.error}`);
  if (expected && typeof expected === 'object') {
    const expFiles = Number(expected.files);
    if (Number.isFinite(expFiles) && expFiles !== paths.length) {
      issues.push(`file_count_mismatch:expected=${expFiles},patch=${paths.length}`);
    }
    if (stat.ok && Number.isFinite(expFiles) && stat.file_count !== expFiles) {
      issues.push(`apply_stat_file_count:expected=${expFiles},stat=${stat.file_count}`);
    }
  }
  return {
    ok: issues.length === 0 && stat.ok,
    issues,
    paths,
    apply_stat: stat.ok ? stat.stat : null,
    categories: categorizePatchPaths(paths),
  };
}

/**
 * 격리 worktree에만 패치를 적용한다. 본 작업 폴더는 바꾸지 않는다.
 * `git apply --check`가 통과할 때만 적용한다.
 */
export function applyPatchInVerifyWorktree(repo, requestId, baseCommit, diff) {
  if (typeof diff !== 'string' || diff.trim() === '') {
    return { ok: false, error: '적용할 변경이 없습니다.', files: 0 };
  }
  const names = pathsFromDiff(diff);
  const blocked = names.filter(isProtectedPath);
  if (blocked.length > 0) {
    return { ok: false, error: '보호된 경로가 들어 있어 적용하지 않았습니다.', conflicts: blocked, files: 0 };
  }

  const dir = worktreeDir(requestId, { verify: true });
  removeWorktree(repo, dir);
  mkdirSync(join(tmpdir(), 'ygg-code-bridge'), { recursive: true });
  run(repo, ['worktree', 'add', '--detach', '--force', dir, baseCommit]);

  const file = patchFile(`${requestId}-verify`, diff);
  const args = ['apply', '--binary', '--whitespace=nowarn'];
  try {
    try {
      run(dir, [...args, '--check', file]);
    } catch (e) {
      const stderr = e instanceof GitOpError ? e.detail.stderr : String(e);
      return {
        ok: false,
        error: '격리 worktree에서 git apply --check가 실패했습니다.',
        conflicts: conflictFiles(stderr),
        detail: String(stderr).slice(0, 1500),
        worktree: dir,
        files: 0,
      };
    }
    run(dir, [...args, file]);
    return { ok: true, worktree: dir, files: names.length, paths: names, base_commit: baseCommit };
  } finally {
    rmSync(file, { force: true });
  }
}

export function removeVerifyWorktree(repo, requestId) {
  removeWorktree(repo, worktreeDir(requestId, { verify: true }));
}

export function createWorktree(repo, requestId, commit, { suffix = '' } = {}) {
  const dir = worktreeDir(requestId, { suffix });
  removeWorktree(repo, dir);
  mkdirSync(join(tmpdir(), 'ygg-code-bridge'), { recursive: true });
  run(repo, ['worktree', 'add', '--detach', '--force', dir, commit]);
  return dir;
}

/**
 * 재수정용 복사본: 앞 수정의 기준 커밋에 앞 diff를 얹는다. 새 diff도 같은 기준에서 모아 누적 diff가 된다.
 * 새 요청의 base ref도 같은 기준 커밋을 가리킨다.
 */
export function createFixWorktree(repo, requestId, baseCommit, diff) {
  if (!/^[0-9a-f]{40}$/i.test(String(baseCommit ?? ''))) throw new GitOpError('앞 수정의 기준 커밋이 없습니다.');
  try {
    run(repo, ['cat-file', '-e', `${baseCommit}^{commit}`]);
  } catch {
    throw new GitOpError('앞 수정의 기준 커밋을 이 PC에서 찾지 못했습니다(30일이 지나 정리됐을 수 있습니다).');
  }
  if (typeof diff !== 'string' || diff.trim() === '') throw new GitOpError('앞 수정의 diff가 없습니다.');
  const blocked = pathsFromDiff(diff).filter(isProtectedPath);
  if (blocked.length > 0) throw new GitOpError(`앞 수정 diff에 보호된 경로가 있습니다: ${blocked.slice(0, 5).join(', ')}`);
  const dir = createWorktree(repo, requestId, baseCommit);
  const file = patchFile(`${requestId}-fix`, diff);
  try {
    run(dir, ['apply', '--binary', '--whitespace=nowarn', file]);
  } catch (e) {
    removeWorktree(repo, dir);
    throw new GitOpError(`앞 수정 diff를 복사본에 다시 얹지 못했습니다: ${e.message}`);
  } finally {
    rmSync(file, { force: true });
  }
  run(repo, ['update-ref', refName(requestId, 'base'), baseCommit]);
  return dir;
}

function succeeds(fn) {
  try {
    fn();
    return true;
  } catch {
    return false;
  }
}

/**
 * 시간 제한으로 멈춘 미완성 패치가 자기 기준 커밋에 그대로 적용되는지 본다(임시 인덱스만 쓰고 폴더는 만들지 않는다).
 * 기준 커밋이 이 PC에 없거나 적용되지 않으면 쓰지 않는다.
 */
function assertAppliesToBase(repo, baseCommit, file) {
  const commit = String(baseCommit ?? '');
  if (!/^[0-9a-f]{40}$/i.test(commit) || !succeeds(() => run(repo, ['cat-file', '-e', `${commit}^{commit}`]))) {
    throw new GitOpError('미완성 패치의 기준 커밋을 이 PC에서 찾지 못해 적용 가능 여부를 확인할 수 없어 쓰지 않습니다.');
  }
  const index = join(tmpdir(), `ygg-code-bridge-index-${process.pid}-${Date.now()}-basecheck`);
  const env = { GIT_INDEX_FILE: index };
  try {
    run(repo, ['read-tree', commit], { env });
    run(repo, ['apply', '--cached', '--check', '--binary', '--whitespace=nowarn', file], { env });
  } catch (e) {
    const conflicts = conflictFiles(e instanceof GitOpError ? e.detail.stderr : '');
    throw new GitOpError(
      `미완성 패치가 자기 기준 커밋에 그대로 적용되지 않아 쓰지 않습니다${conflicts.length ? ` (파일: ${conflicts.slice(0, 10).join(', ')})` : ''}.`,
      { conflicts },
    );
  } finally {
    rmSync(index, { force: true });
  }
}

/**
 * 이어받기용 복사본: 지금 작업 폴더의 스냅샷(baseCommit)에 앞 수정 요청의 최종 패치를 얹는다.
 * 시간 제한으로 멈춘 미완성 패치(patch.partial = 'timeout')는 먼저 자기 기준 커밋에 적용되는지 확인한다.
 * 새 diff는 이 스냅샷 기준이라 앞 패치도 함께 담긴다. 저장된 통계와 본문이 다르면(잘림·다른 회차) 쓰지 않는다.
 * 그대로 얹히지 않으면 3-way로 합쳐 보고, 그래도 충돌하면 복사본을 지우고 충돌 파일과 함께 실패한다.
 * 오류 메시지에는 경로와 숫자만 넣는다(패치 본문은 넣지 않는다).
 * 반환: { dir, applied: 'applied' | 'merged' | 'already_present', paths, stats }
 */
export function createContinueWorktree(repo, requestId, baseCommit, patch) {
  const diff = typeof patch?.diff === 'string' ? patch.diff : '';
  if (!diff.trim()) throw new GitOpError('이어받을 패치가 비어 있습니다.');
  const paths = pathsFromDiff(diff);
  const blocked = paths.filter(isProtectedPath);
  if (blocked.length > 0) throw new GitOpError(`이어받을 패치에 보호된 경로가 있습니다: ${blocked.slice(0, 5).join(', ')}`);
  const file = patchFile(`${requestId}-continue`, diff);
  let dir = null;
  try {
    let stats;
    try {
      stats = parseNumstat(run(repo, ['apply', '--numstat', '-z', file]).toString());
    } catch {
      throw new GitOpError('저장된 패치를 읽지 못했습니다(형식이 깨졌거나 잘렸습니다). 쓰지 않습니다.');
    }
    const want = patch.diff_stats && typeof patch.diff_stats === 'object' ? patch.diff_stats : null;
    const same = want && ['files', 'additions', 'deletions'].every((k) => Number(want[k]) === stats[k]);
    if (!same) {
      const w = want ? `${want.files}개 +${want.additions} -${want.deletions}` : '없음';
      throw new GitOpError(
        `저장된 패치 본문(파일 ${stats.files}개 +${stats.additions} -${stats.deletions})이 기록된 통계(${w})와 달라 불완전한 패치로 보고 쓰지 않습니다.`,
      );
    }
    if (patch.partial === 'timeout') assertAppliesToBase(repo, patch.base_commit, file);
    dir = createWorktree(repo, requestId, baseCommit);
    const args = ['apply', '--binary', '--whitespace=nowarn'];
    let applied;
    if (succeeds(() => run(dir, [...args, '-R', '--check', file]))) {
      applied = 'already_present';
    } else if (succeeds(() => run(dir, [...args, '--check', file]))) {
      run(dir, [...args, file]);
      applied = 'applied';
    } else {
      try {
        run(dir, [...args, '--3way', file]);
        applied = 'merged';
      } catch (e) {
        let conflicts = [];
        try {
          conflicts = git(dir, ['diff', '--name-only', '--diff-filter=U']).split('\n').filter(Boolean);
        } catch {
          // 아래 stderr에서 찾는다
        }
        if (conflicts.length === 0) conflicts = conflictFiles(e instanceof GitOpError ? e.detail.stderr : '');
        throw new GitOpError(
          `이어받을 패치가 지금 작업 폴더와 충돌해 얹지 못했습니다. 충돌 파일: ${conflicts.slice(0, 20).join(', ') || '(알 수 없음)'}. ` +
            '작업 폴더는 바뀌지 않았습니다.',
          { conflicts },
        );
      }
    }
    return { dir, applied, paths, stats };
  } catch (e) {
    if (dir) removeWorktree(repo, dir);
    throw e;
  } finally {
    rmSync(file, { force: true });
  }
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

/** 커밋 객체 안 한 폴더의 파일 이름들(하위 폴더 제외). */
export function listTree(repo, commit, dir) {
  const out = run(repo, ['ls-tree', '--name-only', '-z', commit, `${dir.replace(/\/$/, '')}/`]).toString();
  return out
    .split('\0')
    .filter(Boolean)
    .map((p) => p.slice(p.lastIndexOf('/') + 1));
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
