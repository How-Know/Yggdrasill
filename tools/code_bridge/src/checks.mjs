// 수정 결과 자동 검사. Cursor는 셸이 없으므로, 작업자가 복사본(worktree)에서 정해진 검사만 돌린다.
// 운영 DB·Supabase에는 연결하지 않는다. DB 검사는 일회용 메모리 DB(tools/db_test, PGlite)만 쓴다.
// 설계: docs/architecture/ai-code-bridge.md "자동 검사"
import { spawn, execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { cpSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, statSync, symlinkSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { isSecretPath, redact } from './lib.mjs';

// 2: 요청한 필수 검사(spec.checks), node 패키지 시험 자동 탐지, 항목별 cwd·종료 코드·범위(scope)·환경 표시, 판정(verdict).
export const CHECKS_VERSION = 2;
export const STATUS = ['passed', 'failed', 'skipped', 'preexisting'];
/** node --test가 시험으로 보는 파일 이름(작업자가 직접 파일 목록을 넘긴다. Node 22는 폴더 인자를 찾아 들어가지 않는다). */
export const NODE_TEST_FILE = /[._-]test\.(c|m)?js$/;
/** 요청한 검사의 node --test 인자: 저장소 안 상대 경로나 glob만. 옵션(-로 시작)·..·따옴표는 받지 않는다. */
const NODE_TEST_ARG = /^[A-Za-z0-9_][A-Za-z0-9_\-./*]*$/;
const MAX_TEST_FILES = 400;

const MIGRATIONS = 'supabase/migrations/';
const FUNCTIONS = 'supabase/functions/';
const MIGRATION_NAME = /^(\d{14})_[a-z0-9_]+\.sql$/;
const AI_MIGRATION = /^\d{14}_ai_[a-z0-9_]+\.sql$/;
/** 셸(cmd.exe)로 넘기는 파일 이름. AI가 만든 이름이 명령·옵션이 되지 않게 이 모양만 허용한다. */
const SAFE_ARG = /^[A-Za-z0-9_][A-Za-z0-9_\-./]*$/;
/** 작업자가 정한 옵션(--no-pub 등)까지 포함한 cmd.exe 인자. */
const SAFE_CMD_ARG = /^-{0,2}[A-Za-z0-9_][A-Za-z0-9_\-./=]*$/;
/** 검사 없이 넘어가는 파일(문서·규칙). 미실행으로 세지 않는다. */
const NO_CHECK = /\.(md|mdc|txt)$/i;

const OUTPUT_CHARS = 3_000;
const SECRET_ENV = /KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|^CODE_BRIDGE_|^CURSOR_|^SUPABASE_/i;

const safe = (p) => SAFE_ARG.test(p) && !p.split('/').includes('..');

/** 저장소 기준 폴더 표기를 맞춘다('.'은 루트). 쓸 수 없는 경로면 null. */
export function normalizeCwd(raw) {
  const s = String(raw ?? '').trim().replace(/\\/g, '/').replace(/^\.\/+/, '').replace(/\/+$/, '');
  if (s === '' || s === '.') return '.';
  if (!safe(s) || s.startsWith('.git') || isSecretPath(s)) return null;
  return s;
}

const joinRel = (a, b) => (a === '.' || a === '' ? b : b === '.' || b === '' ? a : `${a}/${b}`);

function globRegex(glob) {
  let re = '';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*' && glob[i + 1] === '*') {
      i += 1;
      if (glob[i + 1] === '/') {
        i += 1;
        re += '(?:.*/)?';
      } else re += '.*';
    } else if (c === '*') re += '[^/]*';
    else re += c.replace(/[.+?^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp(`^${re}$`);
}

/**
 * 요청한 검사 명령을 해석한다. 지금은 `node --test [경로·glob ...]`만 받는다.
 * @returns {{ ok: true, cwd: string, args: string[] } | { ok: false, reason: string }}
 */
export function parseRequiredCheck(raw) {
  const cwd = normalizeCwd(raw?.cwd);
  if (cwd == null) return { ok: false, reason: '검사 폴더(cwd)가 저장소 안 경로가 아닙니다.' };
  const tokens = String(raw?.command ?? '').trim().split(/\s+/).filter(Boolean).map((t) => t.replace(/^["']|["']$/g, ''));
  if (tokens[0] !== 'node' || tokens[1] !== '--test') {
    return { ok: false, reason: '지금은 "node --test <시험 파일·폴더·glob>" 모양의 검사만 돌릴 수 있습니다.' };
  }
  const args = tokens.slice(2).map((a) => a.replace(/\/+$/, '') || '.');
  const bad = args.find((a) => a !== '.' && (!NODE_TEST_ARG.test(a) || a.split('/').includes('..')));
  if (bad) return { ok: false, reason: `쓸 수 없는 인자입니다: ${bad} (옵션·상위 폴더·따옴표 없이 저장소 안 경로만)` };
  return { ok: true, cwd, args };
}

/** cwd 기준 인자(폴더·파일·glob)를 실제 시험 파일 목록(cwd 기준)으로 펼친다. 인자가 없으면 cwd 아래 전체. */
export function expandNodeTestArgs(cwd, args, { exists, isDir, walk }) {
  const out = new Set();
  const all = () => walk(cwd);
  for (const a of args.length ? args : ['.']) {
    if (a.includes('*')) {
      const re = globRegex(a);
      for (const f of all()) if (re.test(f)) out.add(f);
    } else if (a === '.' || isDir(joinRel(cwd, a))) {
      for (const f of walk(joinRel(cwd, a))) if (NODE_TEST_FILE.test(f)) out.add(a === '.' ? f : `${a}/${f}`);
    } else if (exists(joinRel(cwd, a))) out.add(a);
  }
  return [...out].sort().slice(0, MAX_TEST_FILES);
}

/** 바뀐 파일이 속한 node 폴더: 가장 가까운 package.json 폴더, 없으면 test/ 폴더가 있는 가장 가까운 폴더. 저장소 루트는 보지 않는다. */
export function nodeRootOf(path, exists) {
  const parts = path.split('/');
  for (let i = parts.length - 1; i >= 1; i--) {
    const d = parts.slice(0, i).join('/');
    if (exists(`${d}/package.json`)) return { dir: d, pkg: true };
  }
  for (let i = parts.length - 1; i >= 1; i--) {
    const d = parts.slice(0, i).join('/');
    if (exists(`${d}/test`)) return { dir: d, pkg: false };
  }
  return null;
}

/** cwd에서 위로 올라가며 의존성이 있는 package.json 폴더. 없으면 null(의존성 준비가 필요 없다). */
export function depsRootOf(cwd, { exists, readJson }) {
  const parts = cwd === '.' ? [] : cwd.split('/');
  for (let i = parts.length; i >= 1; i--) {
    const d = parts.slice(0, i).join('/');
    if (!exists(`${d}/package.json`)) continue;
    const pkg = readJson(`${d}/package.json`) ?? {};
    const deps = Object.keys(pkg.dependencies ?? {}).length + Object.keys(pkg.devDependencies ?? {}).length;
    return deps > 0 ? d : null;
  }
  return null;
}

/**
 * node 시험 항목. 의존성이 필요한데 작업 폴더에 node_modules가 없으면 환경 문제로 미실행.
 * 복사본에는 node_modules가 없다(무시 파일). 작업 폴더의 것을 캐시로 복사해 연결한다(prepare 'node-modules').
 */
function nodeTestItem({ id, label, cwd, files, source, view, tools }) {
  const base = { id, label, scope: 'required', source };
  const depsDir = depsRootOf(cwd, view);
  if (depsDir && !tools.nodeModules?.(depsDir)) {
    return {
      ...base,
      status: 'skipped',
      env: true,
      reason: `${depsDir}/node_modules가 작업 폴더에 없어 시험을 돌리지 못했습니다. 작업 폴더의 ${depsDir}에서 npm ci(또는 npm install)를 한 번 해 주세요.`,
    };
  }
  return {
    ...base,
    compare: 'node-test',
    ...(depsDir ? { prepare: 'node-modules', depsDir } : {}),
    steps: [{ cmd: 'node', args: ['--test'], files, cwd }],
  };
}

/**
 * 바뀐 경로로 돌릴 검사를 정한다. 파일 시스템은 넘겨받은 함수로만 본다(시험 가능).
 * 모든 항목에 scope(required: 이번 수정에 필요한 검사, followup: 실제 데이터가 있어야 하는 후속 확인)와
 * source(auto | request)를 붙인다. 도구·의존성이 없어 못 돌리는 항목은 env: true.
 * @param {{ paths: string[], exists: (rel: string) => boolean, list: (relDir: string) => string[],
 *   isDir?: (rel: string) => boolean, walk?: (relDir: string) => string[], readJson?: (rel: string) => any,
 *   baseMigrations: string[], required?: Array<{cwd, command, why?}>,
 *   tools: { flutter: boolean, deno: boolean, dbTest: boolean, nodeModules?: (dir: string) => string|null } }} input
 * @returns {Array<{ id, label, scope, source, steps?, after?, files?, status?, reason?, output?, compare?, env? }>}
 */
export function planChecks(input) {
  const items = planChecksRaw(input);
  for (const i of items) {
    i.scope ??= 'required';
    i.source ??= 'auto';
  }
  return items;
}

function planChecksRaw({ paths, exists, list, isDir = () => false, walk = () => [], readJson = () => null, baseMigrations, required = [], tools }) {
  const view = { exists, isDir, walk, readJson };
  const items = [];
  const covered = new Set();
  (Array.isArray(required) ? required : []).slice(0, 6).forEach((raw, n) => {
    const command = String(raw?.command ?? '').trim().slice(0, 300);
    const parsed = parseRequiredCheck(raw);
    const label = `요청한 검사: ${command || '(명령 없음)'}${parsed.ok && parsed.cwd !== '.' ? ` (${parsed.cwd})` : ''}`;
    const id = `request:${n + 1}`;
    if (!parsed.ok) {
      items.push({ id, label, scope: 'required', source: 'request', status: 'skipped', reason: parsed.reason });
      return;
    }
    const files = expandNodeTestArgs(parsed.cwd, parsed.args, view);
    if (files.length === 0) {
      items.push({
        id,
        label,
        scope: 'required',
        source: 'request',
        status: 'failed',
        output: `요청한 검사에 해당하는 시험 파일(*.test.js|mjs|cjs)이 ${parsed.cwd} 아래 ${parsed.args.join(' ') || '.'}에 없습니다.`,
      });
      return;
    }
    if (!files.every(safe)) {
      items.push({ id, label, scope: 'required', source: 'request', status: 'skipped', reason: '시험 파일 이름에 쓸 수 없는 글자가 있습니다.' });
      return;
    }
    for (const f of files) covered.add(joinRel(parsed.cwd, f));
    items.push(nodeTestItem({ id, label, cwd: parsed.cwd, files, source: 'request', view, tools }));
  });
  const unchecked = new Set();
  const nodeRoots = new Map();
  const apps = new Map();
  const fns = new Set();
  let shared = false;
  let codeBridge = false;
  let dbTest = false;
  const migrations = [];

  for (const p of paths) {
    if (p.startsWith(MIGRATIONS)) {
      migrations.push(p.slice(MIGRATIONS.length));
      continue;
    }
    const app = /^apps\/([^/]+)\/(.+)$/.exec(p);
    if (app && exists(`apps/${app[1]}/pubspec.yaml`)) {
      if (!apps.has(app[1])) apps.set(app[1], []);
      apps.get(app[1]).push(app[2]);
      continue;
    }
    const fn = /^supabase\/functions\/([^/]+)\//.exec(p);
    if (fn) {
      if (fn[1] === '_shared') shared = true;
      else fns.add(fn[1]);
      continue;
    }
    if (p.startsWith('tools/code_bridge/')) {
      codeBridge = true;
      continue;
    }
    if (p.startsWith('tools/db_test/')) {
      dbTest = true;
      continue;
    }
    if (NO_CHECK.test(p) || p.startsWith('docs/') || p.startsWith('.cursor/rules/')) continue;
    const root = nodeRootOf(p, exists);
    if (root) {
      if (!nodeRoots.has(root.dir)) nodeRoots.set(root.dir, []);
      nodeRoots.get(root.dir).push(p.slice(root.dir.length + 1));
      continue;
    }
    unchecked.add(app ? `apps/${app[1]}` : p.split('/').slice(0, 2).join('/'));
  }

  for (const [dir, changed] of [...nodeRoots].sort(([a], [b]) => a.localeCompare(b))) {
    const tests = walk(dir).filter((f) => NODE_TEST_FILE.test(f) && safe(f)).sort().slice(0, MAX_TEST_FILES);
    const fresh = tests.filter((f) => !covered.has(joinRel(dir, f)));
    if (tests.length > 0 && fresh.length === 0) continue;
    if (tests.length > 0) {
      const rest = fresh.length < tests.length ? `, 요청한 검사에 없는 ${fresh.length}개` : '';
      items.push(nodeTestItem({ id: `node-test:${dir}`, label: `${dir} 시험 (node --test${rest})`, cwd: dir, files: fresh, source: 'auto', view, tools }));
      continue;
    }
    const scripts = changed.filter((f) => /\.(c|m)?js$/.test(f) && safe(f) && exists(`${dir}/${f}`)).sort().slice(0, 20);
    if (scripts.length > 0) {
      items.push({
        id: `node-syntax:${dir}`,
        label: `${dir} 문법 검사 (node --check, 시험 파일 없음)`,
        steps: scripts.map((f) => ({ cmd: 'node', args: ['--check'], files: [f], cwd: dir })),
      });
    }
    items.push({ id: `unchecked:${dir}`, label: `${dir} 시험 (시험 파일 없음)`, status: 'skipped', reason: '이 폴더에는 node 시험 파일(*.test.js|mjs|cjs)이 없습니다.' });
  }

  for (const [app, files] of [...apps].sort(([a], [b]) => a.localeCompare(b))) {
    const cwd = `apps/${app}`;
    const pub = `flutter-pub:${app}`;
    if (!tools.flutter) {
      items.push({ id: `flutter:${app}`, label: `${app} 분석·시험`, status: 'skipped', env: true, reason: 'flutter를 찾지 못했습니다.' });
      continue;
    }
    items.push({
      id: pub,
      label: `${app} 패키지 준비 (flutter pub get)`,
      prepare: 'secret-assets',
      steps: [{ cmd: 'flutter', args: ['pub', 'get'], cwd }],
    });
    const dart = files.filter((f) => f.endsWith('.dart') && exists(`${cwd}/${f}`)).sort();
    const unsafe = dart.filter((f) => !safe(f));
    if (unsafe.length > 0) {
      items.push({
        id: `flutter-analyze:${app}`,
        label: `${app} 정적 분석 (flutter analyze)`,
        status: 'skipped',
        reason: `파일 이름에 쓸 수 없는 글자가 있어 검사하지 않았습니다: ${unsafe.slice(0, 3).join(', ')}`,
      });
    } else {
      items.push({
        id: `flutter-analyze:${app}`,
        label: `${app} 정적 분석 (flutter analyze)`,
        after: pub,
        compare: 'analyze',
        steps: [{ cmd: 'flutter', args: ['analyze', '--no-fatal-infos'], files: dart, cwd }],
      });
    }
    if (exists(`${cwd}/test`)) {
      items.push({
        id: `flutter-test:${app}`,
        label: `${app} 시험 (flutter test)`,
        after: pub,
        steps: [{ cmd: 'flutter', args: ['test', '--no-pub'], cwd }],
      });
    }
  }

  const targets = shared
    ? list(FUNCTIONS.slice(0, -1)).filter((f) => f !== '_shared' && exists(`${FUNCTIONS}${f}/index.ts`))
    : [...fns].filter((f) => exists(`${FUNCTIONS}${f}/index.ts`));
  targets.sort();
  for (const f of fns) if (!exists(`${FUNCTIONS}${f}/index.ts`)) unchecked.add(`${FUNCTIONS}${f}`);
  if (targets.length > 0 || shared) {
    if (!tools.deno) {
      items.push({ id: 'deno', label: 'Edge Function 검사 (deno)', status: 'skipped', env: true, reason: 'deno를 찾지 못했습니다. CODE_BRIDGE_DENO에 경로를 넣거나 tools/code_bridge에서 npm install 하세요.' });
    } else {
      if (targets.length > 0) {
        items.push({
          id: 'deno-check',
          label: `Edge Function 형식 검사 (deno check: ${targets.join(', ')})`,
          steps: [{ cmd: 'deno', args: ['check'], files: targets.map((t) => `${t}/index.ts`), cwd: FUNCTIONS.slice(0, -1) }],
        });
      }
      for (const t of shared ? ['_shared', ...targets] : targets) {
        if (!list(`${FUNCTIONS}${t}`).some((n) => /_test\.ts$/.test(n))) continue;
        items.push({
          id: `deno-test:${t}`,
          label: `${t} 시험 (deno test)`,
          steps: [{ cmd: 'deno', args: ['test', '--allow-env', '.'], cwd: `${FUNCTIONS}${t}` }],
        });
      }
    }
  }

  if (codeBridge) {
    const dir = 'tools/code_bridge';
    const tests = list(`${dir}/test`).filter((n) => n.endsWith('.test.mjs')).sort().map((t) => `test/${t}`);
    const fresh = tests.filter((f) => !covered.has(joinRel(dir, f)));
    if (fresh.length > 0) {
      const rest = fresh.length < tests.length ? `, 요청한 검사에 없는 ${fresh.length}개` : '';
      items.push(nodeTestItem({ id: 'node-test:code_bridge', label: `코드 작업자 시험 (node --test${rest})`, cwd: dir, files: fresh, source: 'auto', view, tools }));
    }
  }

  if (migrations.length > 0) items.push(migrationVersionCheck(migrations, { exists, list, baseMigrations }));
  const aiMigrations = migrations.filter((m) => AI_MIGRATION.test(m));
  const otherMigrations = migrations.filter((m) => MIGRATION_NAME.test(m) && !AI_MIGRATION.test(m) && exists(MIGRATIONS + m));
  if (aiMigrations.length > 0 || dbTest) {
    items.push(
      tools.dbTest
        ? {
            id: 'db-test',
            label: '일회용 시험 DB (PGlite, AI 영역 DB 함수 파일 전체 적용 + tools/db_test 시험)',
            prepare: 'db-test-modules',
            steps: [{ cmd: 'node', args: ['--test'], cwd: 'tools/db_test' }],
          }
        : {
            id: 'db-test',
            label: '일회용 시험 DB (PGlite)',
            status: 'skipped',
            env: true,
            reason: '작업 폴더의 tools/db_test에 npm install이 되어 있지 않습니다.',
          },
    );
  }
  if (otherMigrations.length > 0) {
    items.push({
      id: 'db-test-other',
      label: 'AI 영역 밖 DB 함수 파일',
      scope: 'followup',
      status: 'skipped',
      reason: `일회용 시험 DB에는 AI 영역 테이블만 있어 검사하지 못했습니다: ${otherMigrations.join(', ')}. 운영 DB에 올리기 전 따로 확인해야 합니다.`,
    });
  }

  for (const u of [...unchecked].sort()) {
    items.push({ id: `unchecked:${u}`, label: `${u} (자동 검사 없음)`, status: 'skipped', reason: '이 폴더는 자동 검사가 정해져 있지 않습니다.' });
  }
  return items;
}

/** DB 함수 파일 이름·번호. 이미 있던 파일을 고치거나 지우면 운영 DB에는 반영되지 않으므로 실패로 본다. */
export function migrationVersionCheck(changed, { exists, list, baseMigrations }) {
  const base = new Set(baseMigrations);
  const baseMax = baseMigrations.map((n) => MIGRATION_NAME.exec(n)?.[1]).filter(Boolean).sort().pop() ?? '';
  const all = list(MIGRATIONS.slice(0, -1)).filter((n) => n.endsWith('.sql'));
  const problems = [];
  for (const name of [...new Set(changed)].sort()) {
    const present = exists(MIGRATIONS + name);
    if (!present) {
      if (base.has(name)) problems.push(`${name}: 이미 있던 DB 함수 파일을 지웠습니다.`);
      continue;
    }
    if (base.has(name)) {
      problems.push(`${name}: 이미 있던 DB 함수 파일을 고쳤습니다. 운영 DB에 이미 적용된 파일이면 다시 적용되지 않습니다. 새 번호의 파일로 만드세요.`);
      continue;
    }
    const m = MIGRATION_NAME.exec(name);
    if (!m) {
      problems.push(`${name}: 이름이 "14자리번호_소문자_이름.sql" 모양이 아닙니다.`);
      continue;
    }
    const same = all.filter((n) => n !== name && n.startsWith(`${m[1]}_`));
    if (same.length > 0) problems.push(`${name}: 번호 ${m[1]}을 ${same.join(', ')}도 씁니다.`);
    if (baseMax && m[1] <= baseMax) problems.push(`${name}: 번호가 기존 마지막 파일(${baseMax})보다 앞서 운영 DB에 올릴 때 건너뛰어집니다.`);
  }
  return {
    id: 'db-version',
    label: 'DB 함수 파일 이름·번호 검사',
    status: problems.length > 0 ? 'failed' : 'passed',
    output: problems.length > 0 ? problems.join('\n') : `새 파일 ${changed.filter((n) => !base.has(n)).length}개, 번호 겹침 없음`,
  };
}

/** flutter analyze 출력의 문제 줄(줄 번호 제외)을 모은다. 기준 상태와 비교해 새로 생긴 것만 탓한다. */
export function analyzeIssues(output) {
  const out = new Set();
  for (const line of String(output ?? '').split(/\r?\n/)) {
    const m = /\b(error|warning|info)\s+[•·-]\s+(.+?)\s+[•·-]\s+([^\s:]+\.dart):\d+:\d+\s+[•·-]\s+(\S+)/.exec(line);
    if (m) out.add(`${m[1]} • ${m[3]} • ${m[4]} • ${m[2]}`);
  }
  return out;
}

export function stripAnsi(s) {
  // eslint-disable-next-line no-control-regex
  return String(s ?? '').replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, '').replace(/\r(?!\n)/g, '\n');
}

export function tail(s, max = OUTPUT_CHARS) {
  const t = redact(stripAnsi(s)).trim();
  return t.length <= max ? t : `…\n${t.slice(t.length - max)}`;
}

/**
 * 검사 프로세스에 넘길 환경 변수. 키·토큰과 작업자 설정은 뺀다.
 * NODE_TEST_CONTEXT가 남아 있으면 안쪽 node --test가 결과를 바깥 실행기로만 보내고 실패해도 0으로 끝난다.
 */
export function scrubEnv(env) {
  const out = {};
  for (const [k, v] of Object.entries(env)) if (!SECRET_ENV.test(k) && k !== 'NODE_TEST_CONTEXT') out[k] = v;
  return out;
}

export function summarize(items) {
  const summary = { passed: 0, failed: 0, skipped: 0, preexisting: 0 };
  for (const i of items) summary[i.status] = (summary[i.status] ?? 0) + 1;
  return summary;
}

/**
 * pubspec이 자산으로 쓰는 비밀 파일(env.local.json 등)은 스냅샷에서 빠지므로 빈 자리표시 파일을 만든다.
 * 진짜 값은 복사하지 않는다. 만든 파일 이름을 돌려준다.
 */
export function secretAssetPlaceholders(appDir) {
  const pubspec = join(appDir, 'pubspec.yaml');
  if (!existsSync(pubspec)) return [];
  const made = [];
  for (const m of readFileSync(pubspec, 'utf8').matchAll(/^\s*-\s*["']?([^\s"'#]+)["']?\s*$/gm)) {
    const rel = m[1];
    if (!isSecretPath(rel) || rel.split('/').includes('..')) continue;
    const file = join(appDir, rel);
    if (existsSync(file)) continue;
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, rel.endsWith('.json') ? '{}\n' : '');
    made.push(rel);
  }
  return made;
}

/** 이 PC에서 검사 도구를 찾는다. 없으면 그 검사는 미실행이 된다. */
export function findTools(env, workerDir, repo) {
  const which = (name) => {
    try {
      const out = execFileSync(process.platform === 'win32' ? 'where' : 'which', [name], {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'ignore'],
      });
      const found = out.split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
      // where는 확장자 없는 sh 스크립트도 돌려준다. Windows에서는 실행 파일·배치만 쓴다.
      return process.platform === 'win32' ? (found.find((f) => /\.(exe|bat|cmd)$/i.test(f)) ?? null) : (found[0] ?? null);
    } catch {
      return null;
    }
  };
  const bundled = join(workerDir, 'node_modules', '@deno', `${process.platform}-${process.arch}`, process.platform === 'win32' ? 'deno.exe' : 'deno');
  const deno = (env.CODE_BRIDGE_DENO ?? '').trim() || (existsSync(bundled) ? bundled : which('deno'));
  const flutter = (env.CODE_BRIDGE_FLUTTER ?? '').trim() || which('flutter');
  const dbTestModules = join(repo, 'tools', 'db_test', 'node_modules');
  return {
    deno: deno && existsSync(deno) ? deno : null,
    flutter: flutter || null,
    dbTestModules: existsSync(join(dbTestModules, '@electric-sql', 'pglite')) ? dbTestModules : null,
    /** 작업 폴더(repo)의 <dir>/node_modules. 없으면 null. */
    nodeModules: (dir) => {
      const p = join(repo, dir, 'node_modules');
      return existsSync(p) ? p : null;
    },
  };
}

const WALK_SKIP = new Set(['node_modules', '.git', '.dart_tool', 'build', '.venv', '__pycache__']);

/** 저장소 기준 파일 존재·목록 함수. walk는 relDir 아래 파일을 relDir 기준 경로로(node_modules 등은 건너뜀). */
export function fsView(dir) {
  const isDir = (rel) => {
    try {
      return statSync(join(dir, rel)).isDirectory();
    } catch {
      return false;
    }
  };
  return {
    exists: (rel) => existsSync(join(dir, rel)),
    list: (rel) => (isDir(rel) ? readdirSync(join(dir, rel)) : []),
    isDir,
    walk: (rel) => {
      const out = [];
      const visit = (sub, depth) => {
        if (out.length >= 5000 || depth > 8) return;
        let entries;
        try {
          entries = readdirSync(join(dir, rel, sub), { withFileTypes: true });
        } catch {
          return;
        }
        for (const e of entries) {
          const p = sub ? `${sub}/${e.name}` : e.name;
          if (e.isDirectory()) {
            if (!WALK_SKIP.has(e.name)) visit(p, depth + 1);
          } else if (e.isFile()) out.push(p);
        }
      };
      visit('', 0);
      return out;
    },
    readJson: (rel) => {
      try {
        return JSON.parse(readFileSync(join(dir, rel), 'utf8'));
      } catch {
        return null;
      }
    },
  };
}

/** node --test(TAP) 출력의 실패한 시험 이름. 바꾸기 전 상태와 비교해 새로 실패한 것만 이번 수정 탓으로 본다. */
export function nodeTestFailures(output) {
  const out = new Set();
  for (const line of String(output ?? '').split(/\r?\n/)) {
    const m = /^\s*not ok \d+ - (.+?)\s*(?:#.*)?$/.exec(line);
    if (m) out.add(m[1]);
  }
  return out;
}

/**
 * 작업 폴더의 node_modules를 임시 캐시로 한 번 복사하고, 복사본에는 연결(junction)만 만든다.
 * 시험이 node_modules에 써도 작업 폴더는 바뀌지 않는다. 캐시는 lock 파일 내용이 바뀌면 새로 만든다.
 * 만든 연결 경로를 돌려준다(검사가 끝나면 runChecks가 지운다).
 */
export function linkNodeModules(root, depsDir, source, cacheRoot = join(tmpdir(), 'ygg-code-bridge', 'deps')) {
  const target = join(root, depsDir, 'node_modules');
  if (existsSync(target)) return null;
  const lock = [join(source, '.package-lock.json'), join(dirname(source), 'package-lock.json'), join(dirname(source), 'package.json')].find((f) => existsSync(f));
  const key = createHash('sha1').update(lock ? readFileSync(lock) : Buffer.from(source)).digest('hex').slice(0, 12);
  const cache = join(cacheRoot, `${depsDir.replace(/[^A-Za-z0-9_-]/g, '_')}-${key}`);
  // node는 연결을 실제 경로로 풀어 패키지끼리 찾으므로, 캐시 안에서도 폴더 이름이 node_modules여야 한다.
  const modules = join(cache, 'node_modules');
  if (!existsSync(modules)) {
    const tmp = `${cache}.tmp-${process.pid}`;
    rmSync(tmp, { recursive: true, force: true });
    mkdirSync(cacheRoot, { recursive: true });
    cpSync(source, join(tmp, 'node_modules'), { recursive: true });
    rmSync(cache, { recursive: true, force: true });
    renameSync(tmp, cache);
  }
  mkdirSync(dirname(target), { recursive: true });
  symlinkSync(modules, target, 'junction');
  return target;
}

/** node 시험 출력에서 불러오지 못한 패키지 이름. 상대 경로(./, ../) 모듈은 코드 문제이므로 보지 않는다. */
export function missingModule(output) {
  const m = /Cannot find (?:package|module) '([^'./\\][^':]*)'/.exec(String(output ?? ''));
  return m ? m[1] : null;
}

function unlinkQuiet(link) {
  try {
    if (lstatSync(link).isSymbolicLink()) unlinkSync(link);
  } catch {
    // 이미 없음
  }
}

/** 필수 검사 판정. code_review.ts checkVerdict와 같은 규칙. */
export function checkVerdict(items, stopped = false) {
  const required = items.filter((i) => (i.scope ?? 'required') === 'required');
  if (required.some((i) => i.status === 'failed')) return 'failed';
  if (stopped || required.some((i) => i.status === 'skipped')) return 'not_run';
  return required.length > 0 ? 'passed' : 'none';
}

/**
 * 수정 시작 전 확인: 요청한 필수 검사를 이 PC에서 돌릴 수 있는지(명령 모양, 폴더, 의존성).
 * 폴더가 아직 없으면 수정이 만들 수 있으므로 문제로 보지 않고 알리기만 한다.
 * @returns {Array<{ cwd: string|null, command: string, ok: boolean, env: boolean, problem: string|null, note: string|null }>}
 */
export function preflightChecks(required, { exists, readJson, tools }) {
  return (Array.isArray(required) ? required : []).slice(0, 6).map((raw) => {
    const command = String(raw?.command ?? '').trim().slice(0, 300);
    const parsed = parseRequiredCheck(raw);
    if (!parsed.ok) return { cwd: null, command, ok: false, env: false, problem: parsed.reason, note: null };
    const note = parsed.cwd !== '.' && !exists(parsed.cwd) ? `${parsed.cwd} 폴더가 아직 없습니다. 수정에서 만들어야 합니다.` : null;
    const depsDir = depsRootOf(parsed.cwd, { exists, readJson });
    if (depsDir && !tools.nodeModules?.(depsDir)) {
      return {
        cwd: parsed.cwd,
        command,
        ok: false,
        env: true,
        problem: `${depsDir}/node_modules가 작업 폴더에 없습니다. ${depsDir}에서 npm ci(또는 npm install)가 필요합니다.`,
        note,
      };
    }
    return { cwd: parsed.cwd, command, ok: true, env: false, problem: null, note };
  });
}

function command(step, tools) {
  const argv = [...step.args, ...(step.files ?? [])];
  if (step.cmd === 'node') return { file: process.execPath, argv, shown: `node ${argv.join(' ')}` };
  if (step.cmd === 'deno') return { file: tools.deno, argv, shown: `deno ${argv.join(' ')}` };
  if (step.cmd === 'flutter') {
    const shown = `flutter ${argv.join(' ')}`;
    if (process.platform !== 'win32') return { file: tools.flutter, argv, shown };
    if (!step.args.every((a) => SAFE_CMD_ARG.test(a)) || !(step.files ?? []).every(safe)) throw new Error('unsafe argument');
    // flutter.bat은 cmd.exe로만 돌릴 수 있다. 인자는 위에서 걸렀다.
    return { file: process.env.ComSpec || 'cmd.exe', argv: ['/d', '/s', '/c', `""${tools.flutter}" ${argv.join(' ')}"`], shown, verbatim: true };
  }
  throw new Error(`unknown command ${step.cmd}`);
}

function killTree(child) {
  if (!child.pid) return;
  if (process.platform === 'win32') {
    try {
      execFileSync('taskkill', ['/pid', String(child.pid), '/T', '/F'], { stdio: 'ignore' });
    } catch {
      // 이미 끝남
    }
  } else {
    child.kill('SIGKILL');
  }
}

/** 프로세스 하나. 이벤트 루프를 막지 않아 진행 신호(heartbeat)가 계속 간다. */
function runStep(cwd, cmd, { env, timeoutMs, shouldStop }) {
  return new Promise((resolvePromise) => {
    const started = Date.now();
    let out = '';
    let killed = null;
    const child = spawn(cmd.file, cmd.argv, {
      cwd,
      env,
      windowsHide: true,
      windowsVerbatimArguments: Boolean(cmd.verbatim),
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const add = (b) => {
      out += b.toString('utf8');
      if (out.length > 200_000) out = out.slice(-100_000);
    };
    child.stdout.on('data', add);
    child.stderr.on('data', add);
    const timer = setInterval(() => {
      if (shouldStop()) killed = 'stopped';
      else if (Date.now() - started > timeoutMs) killed = 'timeout';
      if (killed) {
        clearInterval(timer);
        killTree(child);
      }
    }, 1_000);
    const done = (code, error) => {
      clearInterval(timer);
      resolvePromise({ code, error, killed, output: out, duration_ms: Date.now() - started });
    };
    child.on('error', (e) => done(null, e));
    child.on('close', (code) => done(code, null));
  });
}

/**
 * 계획한 검사를 차례로 돌린다. 실패한 검사는 기준 상태(baseline)에서 한 번 더 돌려,
 * 원래도 실패하던 것이면 'preexisting'으로 바꾼다(Cursor 탓이 아니므로 다시 고치게 하지 않는다).
 * @param {{ dir: string, items: any[], tools: any, baseline?: () => Promise<string|null>,
 *   shouldStop?: () => boolean, stepTimeoutMs?: number, budgetMs?: number, env?: object, log?: Function }} opts
 */
export async function runChecks(opts) {
  const { dir, items, tools } = opts;
  const shouldStop = opts.shouldStop ?? (() => false);
  const stepTimeoutMs = opts.stepTimeoutMs ?? 10 * 60_000;
  const deadline = Date.now() + (opts.budgetMs ?? 25 * 60_000);
  const env = scrubEnv(opts.env ?? process.env);
  const log = opts.log ?? (() => {});
  const started = Date.now();
  const results = [];
  const byId = new Map();
  let baseDir;
  const baseReady = new Set();
  let stopped = false;
  const links = [];

  const runSteps = async (root, item) => {
    if (item.prepare === 'secret-assets') secretAssetPlaceholders(join(root, item.steps[0].cwd));
    if (item.prepare === 'db-test-modules') {
      const target = join(root, 'tools', 'db_test', 'node_modules');
      if (!existsSync(target)) cpSync(tools.dbTestModules, target, { recursive: true });
    }
    if (item.prepare === 'node-modules') {
      const source = tools.nodeModules?.(item.depsDir);
      if (!source) return { status: 'skipped', env: true, reason: `${item.depsDir}/node_modules가 작업 폴더에 없습니다.`, command: null };
      const link = (opts.linkNodeModules ?? linkNodeModules)(root, item.depsDir, source);
      if (link) links.push(link);
    }
    let output = '';
    let duration = 0;
    let exitCode = null;
    let cwd = null;
    const commands = [];
    const rec = (r) => ({ output, duration_ms: duration, command: commands.join(' && '), exit_code: exitCode, cwd, ...r });
    for (const step of item.steps) {
      const files = root === dir ? step.files : step.files?.filter((f) => existsSync(join(root, step.cwd, f)));
      if (step.files?.length && !files?.length) return rec({ status: 'no-baseline' });
      const cmd = command({ ...step, files }, tools);
      commands.push(cmd.shown);
      cwd = step.cwd;
      const left = deadline - Date.now();
      if (left <= 0) return rec({ status: 'skipped', reason: '검사 전체 제한 시간을 넘어 돌리지 못했습니다.' });
      const r = await runStep(join(root, step.cwd), cmd, { env, timeoutMs: Math.min(stepTimeoutMs, left), shouldStop });
      output += `$ ${cmd.shown}\n${r.output}\n`;
      duration += r.duration_ms;
      exitCode = r.code;
      if (r.killed === 'stopped') return rec({ status: 'stopped' });
      if (r.killed === 'timeout') {
        return rec({ status: 'failed', output: `${output}\n${Math.round(Math.min(stepTimeoutMs, left) / 60_000)}분 안에 끝나지 않아 멈췄습니다.` });
      }
      if (r.error) return rec({ status: 'skipped', reason: `실행하지 못했습니다: ${r.error.message}` });
      if (r.code !== 0) return rec({ status: 'failed' });
    }
    return rec({ status: 'passed' });
  };

  const onBaseline = async (item) => {
    if (!opts.baseline) return null;
    if (baseDir === undefined) {
      try {
        baseDir = await opts.baseline();
      } catch (e) {
        log('기준 상태 준비 실패:', e.message);
        baseDir = null;
      }
    }
    if (!baseDir) return null;
    if (item.after && !baseReady.has(item.after)) {
      const dep = items.find((i) => i.id === item.after);
      if (!dep || (await runSteps(baseDir, dep)).status !== 'passed') return null;
      baseReady.add(item.after);
    }
    return runSteps(baseDir, item);
  };

  const empty = { output: null, command: null, cwd: null, exit_code: null, duration_ms: 0 };
  try {
    for (const item of items) {
      const base = { id: item.id, label: item.label, scope: item.scope ?? 'required', source: item.source ?? 'auto', env: item.env === true };
      if (item.status) {
        results.push({ ...base, ...empty, status: item.status, reason: item.reason ?? null, output: item.output ?? null });
        byId.set(item.id, item.status);
        continue;
      }
      if (stopped || shouldStop()) {
        stopped = true;
        break;
      }
      if (item.after && byId.get(item.after) !== 'passed') {
        results.push({ ...base, ...empty, status: 'skipped', reason: '앞 단계(패키지 준비)가 통과하지 않아 돌리지 않았습니다.' });
        byId.set(item.id, 'skipped');
        continue;
      }
      log(`검사: ${item.label}`);
      let r;
      try {
        r = await runSteps(dir, item);
      } catch (e) {
        r = { ...empty, status: 'skipped', reason: `실행하지 못했습니다: ${e.message}`, output: '' };
      }
      if (r.status === 'stopped') {
        stopped = true;
        break;
      }
      let note = null;
      if (r.status === 'failed' && item.id.startsWith('flutter-pub:') === false) {
        const b = await onBaseline(item).catch(() => null);
        if (b?.status === 'stopped') {
          stopped = true;
          break;
        }
        if (b && (b.status === 'failed' || b.status === 'passed')) {
          const parse = item.compare === 'analyze' ? analyzeIssues : item.compare === 'node-test' ? nodeTestFailures : null;
          if (parse && b.status === 'failed') {
            const before = parse(b.output);
            const fresh = [...parse(r.output)].filter((k) => !before.has(k));
            if (fresh.length === 0) {
              r.status = 'preexisting';
              note = item.compare === 'analyze' ? '바꾸기 전에도 있던 문제만 남아 있습니다.' : '바꾸기 전에도 실패하던 시험만 실패합니다.';
            } else {
              note = `수정으로 새로 생긴 ${item.compare === 'analyze' ? '문제' : '실패 시험'} ${fresh.length}개:\n${fresh.slice(0, 30).join('\n')}`;
            }
          } else if (b.status === 'failed') {
            r.status = 'preexisting';
            note = '바꾸기 전 상태에서도 같은 검사가 실패합니다. 이번 수정 때문이 아닐 수 있습니다.';
          }
          const missing = item.compare === 'node-test' && r.status === 'preexisting' ? missingModule(r.output) : null;
          if (missing) {
            r.status = 'skipped';
            r.env = true;
            r.reason =
              `시험 파일이 쓰는 패키지 '${missing}'를 찾지 못해 시험을 불러오지 못했습니다(바꾸기 전에도 같음). ` +
              `시험이 실제로 돌지 않았으므로 통과가 아닙니다. 작업 폴더의 ${item.depsDir ?? item.steps?.[0]?.cwd ?? '해당 폴더'}에서 의존성을 설치(npm ci)하고 package.json에 적어 주세요.`;
            note = null;
          }
        }
      }
      const output = note ? `${note}\n\n${tail(r.output, OUTPUT_CHARS - Math.min(note.length, 1500))}` : tail(r.output ?? '');
      results.push({
        ...base,
        env: base.env || r.env === true,
        status: r.status,
        reason: r.reason ?? null,
        output,
        command: r.command ?? null,
        cwd: r.cwd ?? null,
        exit_code: typeof r.exit_code === 'number' ? r.exit_code : null,
        duration_ms: r.duration_ms ?? 0,
      });
      byId.set(item.id, r.status);
      log(`검사 결과: ${item.label} → ${r.status}`);
    }
  } finally {
    for (const link of links) unlinkQuiet(link);
  }
  if (stopped) {
    for (const item of items) {
      if (byId.has(item.id)) continue;
      results.push({
        id: item.id,
        label: item.label,
        scope: item.scope ?? 'required',
        source: item.source ?? 'auto',
        env: false,
        ...empty,
        status: 'skipped',
        reason: '검사가 중간에 멈춰 돌리지 못했습니다.',
      });
    }
  }

  return {
    version: CHECKS_VERSION,
    stopped,
    duration_ms: Date.now() - started,
    summary: summarize(results),
    verdict: checkVerdict(results, stopped),
    items: results,
  };
}
