// 수정 결과 자동 검사. Cursor는 셸이 없으므로, 작업자가 복사본(worktree)에서 정해진 검사만 돌린다.
// 운영 DB·Supabase에는 연결하지 않는다. DB 검사는 일회용 메모리 DB(tools/db_test, PGlite)만 쓴다.
// 설계: docs/architecture/ai-code-bridge.md "자동 검사"
import { spawn, execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { isSecretPath, redact } from './lib.mjs';

export const CHECKS_VERSION = 1;
export const STATUS = ['passed', 'failed', 'skipped', 'preexisting'];

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

/**
 * 바뀐 경로로 돌릴 검사를 정한다. 파일 시스템은 넘겨받은 함수로만 본다(시험 가능).
 * @param {{ paths: string[], exists: (rel: string) => boolean, list: (relDir: string) => string[],
 *   baseMigrations: string[], tools: { flutter: boolean, deno: boolean, dbTest: boolean } }} input
 * @returns {Array<{ id, label, steps?, after?, files?, status?, reason?, output?, compare? }>}
 */
export function planChecks({ paths, exists, list, baseMigrations, tools }) {
  const items = [];
  const unchecked = new Set();
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
    unchecked.add(app ? `apps/${app[1]}` : p.split('/').slice(0, 2).join('/'));
  }

  for (const [app, files] of [...apps].sort(([a], [b]) => a.localeCompare(b))) {
    const cwd = `apps/${app}`;
    const pub = `flutter-pub:${app}`;
    if (!tools.flutter) {
      items.push({ id: `flutter:${app}`, label: `${app} 분석·시험`, status: 'skipped', reason: 'flutter를 찾지 못했습니다.' });
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
      items.push({ id: 'deno', label: 'Edge Function 검사 (deno)', status: 'skipped', reason: 'deno를 찾지 못했습니다. CODE_BRIDGE_DENO에 경로를 넣거나 tools/code_bridge에서 npm install 하세요.' });
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
    const tests = list('tools/code_bridge/test').filter((n) => n.endsWith('.test.mjs')).sort();
    if (tests.length > 0) {
      items.push({
        id: 'node-test:code_bridge',
        label: '코드 작업자 시험 (node --test)',
        steps: [{ cmd: 'node', args: ['--test'], files: tests.map((t) => `test/${t}`), cwd: 'tools/code_bridge' }],
      });
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
            reason: '작업 폴더의 tools/db_test에 npm install이 되어 있지 않습니다.',
          },
    );
  }
  if (otherMigrations.length > 0) {
    items.push({
      id: 'db-test-other',
      label: 'AI 영역 밖 DB 함수 파일',
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

/** 검사 프로세스에 넘길 환경 변수. 키·토큰과 작업자 설정은 뺀다. */
export function scrubEnv(env) {
  const out = {};
  for (const [k, v] of Object.entries(env)) if (!SECRET_ENV.test(k)) out[k] = v;
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
  };
}

/** 저장소 기준 파일 존재·목록 함수. */
export function fsView(dir) {
  return {
    exists: (rel) => existsSync(join(dir, rel)),
    list: (rel) => {
      try {
        return statSync(join(dir, rel)).isDirectory() ? readdirSync(join(dir, rel)) : [];
      } catch {
        return [];
      }
    },
  };
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

  const runSteps = async (root, item) => {
    if (item.prepare === 'secret-assets') secretAssetPlaceholders(join(root, item.steps[0].cwd));
    if (item.prepare === 'db-test-modules') {
      const target = join(root, 'tools', 'db_test', 'node_modules');
      if (!existsSync(target)) cpSync(tools.dbTestModules, target, { recursive: true });
    }
    let output = '';
    let duration = 0;
    const commands = [];
    for (const step of item.steps) {
      const files = root === dir ? step.files : step.files?.filter((f) => existsSync(join(root, step.cwd, f)));
      if (step.files?.length && !files?.length) return { status: 'no-baseline', output, duration_ms: duration, command: commands.join(' && ') };
      const cmd = command({ ...step, files }, tools);
      commands.push(cmd.shown);
      const left = deadline - Date.now();
      if (left <= 0) return { status: 'skipped', reason: '검사 전체 제한 시간을 넘어 돌리지 못했습니다.', command: commands.join(' && ') };
      const r = await runStep(join(root, step.cwd), cmd, { env, timeoutMs: Math.min(stepTimeoutMs, left), shouldStop });
      output += `$ ${cmd.shown}\n${r.output}\n`;
      duration += r.duration_ms;
      if (r.killed === 'stopped') return { status: 'stopped', output, duration_ms: duration, command: commands.join(' && ') };
      if (r.killed === 'timeout') {
        return { status: 'failed', output: `${output}\n${Math.round(Math.min(stepTimeoutMs, left) / 60_000)}분 안에 끝나지 않아 멈췄습니다.`, duration_ms: duration, command: commands.join(' && ') };
      }
      if (r.error) return { status: 'skipped', reason: `실행하지 못했습니다: ${r.error.message}`, output, duration_ms: duration, command: commands.join(' && ') };
      if (r.code !== 0) return { status: 'failed', output, duration_ms: duration, command: commands.join(' && ') };
    }
    return { status: 'passed', output, duration_ms: duration, command: commands.join(' && ') };
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

  for (const item of items) {
    const base = { id: item.id, label: item.label };
    if (item.status) {
      results.push({ ...base, status: item.status, reason: item.reason ?? null, output: item.output ?? null, command: null, duration_ms: 0 });
      byId.set(item.id, item.status);
      continue;
    }
    if (stopped || shouldStop()) {
      stopped = true;
      break;
    }
    if (item.after && byId.get(item.after) !== 'passed') {
      results.push({ ...base, status: 'skipped', reason: '앞 단계(패키지 준비)가 통과하지 않아 돌리지 않았습니다.', output: null, command: null, duration_ms: 0 });
      byId.set(item.id, 'skipped');
      continue;
    }
    log(`검사: ${item.label}`);
    let r;
    try {
      r = await runSteps(dir, item);
    } catch (e) {
      r = { status: 'skipped', reason: `실행하지 못했습니다: ${e.message}`, output: '', duration_ms: 0, command: null };
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
        if (item.compare === 'analyze' && b.status === 'failed') {
          const before = analyzeIssues(b.output);
          const fresh = [...analyzeIssues(r.output)].filter((k) => !before.has(k));
          if (fresh.length === 0) {
            r.status = 'preexisting';
            note = '바꾸기 전에도 있던 문제만 남아 있습니다.';
          } else {
            note = `수정으로 새로 생긴 문제 ${fresh.length}개:\n${fresh.slice(0, 30).join('\n')}`;
          }
        } else if (b.status === 'failed') {
          r.status = 'preexisting';
          note = '바꾸기 전 상태에서도 같은 검사가 실패합니다. 이번 수정 때문이 아닐 수 있습니다.';
        }
      }
    }
    const output = note ? `${note}\n\n${tail(r.output, OUTPUT_CHARS - Math.min(note.length, 1500))}` : tail(r.output ?? '');
    results.push({ ...base, status: r.status, reason: r.reason ?? null, output, command: r.command ?? null, duration_ms: r.duration_ms ?? 0 });
    byId.set(item.id, r.status);
    log(`검사 결과: ${item.label} → ${r.status}`);
  }
  if (stopped) {
    for (const item of items) {
      if (byId.has(item.id)) continue;
      results.push({ id: item.id, label: item.label, status: 'skipped', reason: '검사가 중간에 멈춰 돌리지 못했습니다.', output: null, command: null, duration_ms: 0 });
    }
  }

  return {
    version: CHECKS_VERSION,
    stopped,
    duration_ms: Date.now() - started,
    summary: summarize(results),
    items: results,
  };
}
