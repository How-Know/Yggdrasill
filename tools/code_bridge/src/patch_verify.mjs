// 저장된 수정 diff(카드 'diff 복사' → .patch)를 격리 worktree에서만 검증한다. 본 작업 폴더에는 적용하지 않는다.
// 수동 보조 도구다. 작업자는 수정마다 자동 검사(checks.mjs)를 돌려 카드에 남기므로, 이 스크립트는 자동 검사 전에
// 만든 diff나 손으로 받은 .patch를 따로 살펴볼 때만 쓴다. 이 스크립트 자체는 검사를 돌리지 않는다.
// 설계: docs/architecture/ai-think-actions.md §4.5
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  applyPatchInVerifyWorktree,
  intersectPaths,
  removeVerifyWorktree,
  resolveBaseCommit,
  validatePatchConsistency,
  workingTreeChangedPaths,
} from './git_ops.mjs';
const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function git(repo, args) {
  try {
    return execFileSync('git', args, { cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  } catch {
    return null;
  }
}

function repoSnapshot(repo) {
  const status = git(repo, ['status', '--porcelain']);
  const untracked = status == null ? null : status.split('\n').filter((l) => l.startsWith('??')).length;
  return {
    head: git(repo, ['rev-parse', 'HEAD']),
    head_short: git(repo, ['rev-parse', '--short', 'HEAD']),
    branch: git(repo, ['rev-parse', '--abbrev-ref', 'HEAD']),
    dirty_files: status == null ? null : status.split('\n').filter(Boolean).length,
    untracked_files: untracked,
    changed_paths: workingTreeChangedPaths(repo),
  };
}

function parseArgs(argv) {
  const out = { patch: null, requestId: null, baseCommit: null, diffStats: null, cleanupWorktree: false };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--patch' && argv[i + 1]) out.patch = argv[++i];
    else if (a === '--request-id' && argv[i + 1]) out.requestId = argv[++i];
    else if (a === '--base-commit' && argv[i + 1]) out.baseCommit = argv[++i];
    else if (a === '--diff-stats' && argv[i + 1]) {
      try {
        out.diffStats = JSON.parse(argv[++i]);
      } catch {
        out.diffStats = null;
      }
    } else if (a === '--cleanup-worktree') out.cleanupWorktree = true;
    else if (a === '--help' || a === '-h') out.help = true;
  }
  return out;
}

function usage() {
  return `사용법:
  node src/patch_verify.mjs --request-id <uuid> --patch <file.patch> [--base-commit <sha>] [--diff-stats '<json>'] [--cleanup-worktree]

환경: CODE_BRIDGE_REPO(저장소 경로, 기본값 저장소 루트). 기본적으로 격리 worktree는 analyze/test용으로 남깁니다.

stdout: 기능 중심 검증용 JSON 보고(적용·테스트·DB 변경은 수행하지 않음).`;
}

async function main() {
  const args = parseArgs(process.argv);
  if (args.help || !args.requestId || !args.patch) {
    console.error(usage());
    process.exit(args.help ? 0 : 2);
  }
  const repo = resolve((process.env.CODE_BRIDGE_REPO ?? REPO_ROOT).trim());

  if (!existsSync(args.patch)) {
    console.log(JSON.stringify({ ok: false, stage: 'patch_file', error: 'patch_file_missing', path: args.patch }, null, 2));
    process.exit(1);
  }
  const diff = readFileSync(args.patch, 'utf8');
  if (!diff.trim()) {
    console.log(JSON.stringify({ ok: false, stage: 'patch_file', error: 'patch_empty' }, null, 2));
    process.exit(1);
  }

  const report = {
    ok: false,
    request_id: args.requestId,
    repo: repoSnapshot(repo),
    patch_file: resolve(args.patch),
    patch_bytes: Buffer.byteLength(diff, 'utf8'),
    consistency: null,
    base: null,
    path_intersection: [],
    isolated_apply: null,
    notes: [
      '본 스크립트는 작업 폴더에 패치를 적용하지 않습니다.',
      '이 스크립트는 analyze/test·DB 시험을 돌리지 않습니다. 필요하면 격리 worktree에서 직접 실행하고, 실행하지 않은 검사는 미실행으로 남기세요.',
      '작업자 자동 검사 결과는 코드 수정 카드의 "자동 검사" 칸에 있습니다.',
    ],
    recovery: {
      local_code: '격리 worktree만 변경. 본 작업 폴더·before-apply ref는 이 단계에서 건드리지 않음.',
      trial_db: '이 스크립트는 DB에 연결하지 않음.',
      production_db: '운영 DB 마이그레이션·배포 없음.',
    },
  };

  report.consistency = validatePatchConsistency(repo, diff, { diff_stats: args.diffStats ?? undefined });
  if (!report.consistency.ok) {
    console.log(JSON.stringify(report, null, 2));
    process.exit(1);
  }

  report.base = resolveBaseCommit(repo, args.requestId, args.baseCommit ?? null);
  if (!report.base.ok) {
    console.log(JSON.stringify(report, null, 2));
    process.exit(1);
  }

  report.path_intersection = intersectPaths(report.consistency.paths, report.repo.changed_paths);

  report.isolated_apply = applyPatchInVerifyWorktree(repo, args.requestId, report.base.commit, diff);
  report.ok = report.isolated_apply.ok === true;
  if (report.isolated_apply.ok) {
    report.isolated_apply.hint =
      `격리 worktree: ${report.isolated_apply.worktree}. analyze/test는 이 경로를 cwd로 IDE·터미널에서 실행하세요.`;
  }

  if (args.cleanupWorktree && report.isolated_apply.ok) {
    removeVerifyWorktree(repo, args.requestId);
    report.isolated_apply.worktree_removed = true;
  }

  console.log(JSON.stringify(report, null, 2));
  process.exit(report.ok ? 0 : 1);
}

main().catch((e) => {
  console.error(JSON.stringify({ ok: false, error: String(e?.message ?? e) }, null, 2));
  process.exit(1);
});
