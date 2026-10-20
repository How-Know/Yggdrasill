// Think 코드 작업자. 운영자 PC에서 `npm start`로 켠다. Ctrl+C로 끈다.
// 대기열에서 요청을 하나씩 가져간다.
//   조사·조율: 작업 폴더에서 Cursor를 읽기 전용(plan)으로 돌린다. 조율은 Think의 계획 초안을 코드에 비춰 검토한다.
//   수정: 작업 폴더 스냅샷의 복사본(worktree)에서 편집·삭제만 허용해 돌리고, 정해진 자동 검사를 돌린 뒤 diff와 검사 결과를 올린다.
//         재수정이면 앞 수정의 기준 커밋에 앞 diff를 얹은 복사본에서 시작한다. 작업 폴더는 그대로다.
//   이어받기: 요청에 continue_from이 있으면 조사·조율·수정 모두 지금 작업 폴더 스냅샷에 앞 수정의 최종 패치를 얹은 복사본에서 돈다.
//   적용·되돌리기: 운영자가 승인한 diff를 `git apply --check` 통과 시에만 작업 폴더에 반영한다.
// 설계: docs/architecture/ai-code-bridge.md, docs/architecture/ai-think-actions.md
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { Agent, Cursor } from '@cursor/sdk';
import { SqliteLocalAgentStore } from '@cursor/sdk/sqlite';
import { BridgeError, createBridgeClient } from './bridge_client.mjs';
import { CHECKS_VERSION, findTools, fsView, planChecks, preflightChecks, runChecks, summarize } from './checks.mjs';
import {
  applyToWorkingTree,
  collectDiff,
  createContinueWorktree,
  createFixWorktree,
  createWorktree,
  intersectPaths,
  listTree,
  pathsFromDiff,
  pruneRefs,
  removeWorktree,
  snapshot,
  workingTreeChangedPaths,
} from './git_ops.mjs';
import {
  ASK_TOOLS,
  CHANGE_TOOLS,
  ConfigError,
  MAX_DIFF_CHARS,
  PROMPT_VERSION,
  READ_ONLY_TOOLS,
  ToolCounter,
  TurnTracker,
  askThinkAllowed,
  classifyError,
  continuePatch,
  createAskThinkTool,
  loadConfig,
  looksSecret,
  modeLabel,
  parseChangeResult,
  parsePlanResult,
  parseResult,
  promptFor,
  redact,
  redactDeep,
  requestEffort,
  resolveModelSelection,
  retryDelayMs,
  sdkStateRoot,
  sdkStorePathFits,
  usedEffort,
} from './lib.mjs';

const VERSION = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')).version;
const WORKER_DIR = fileURLToPath(new URL('..', import.meta.url));
/** 검사 결과(diff 제외)가 서버 한도(100KB)를 넘지 않게 줄이는 기준. */
const VERIFICATION_CHARS = 60_000;

function log(...args) {
  console.log(new Date().toLocaleTimeString('ko-KR', { hour12: false }), ...args);
}

const CATALOG_TTL_MS = 60 * 60_000;
let catalog = { at: 0, list: null };

/** 모델·강도 옵션 목록. 못 읽으면 직전 목록(없으면 null)으로 돌고, 그때는 강도 옵션 없이 실행한다. */
async function modelCatalog(cfg) {
  if (catalog.list && Date.now() - catalog.at < CATALOG_TTL_MS) return catalog.list;
  try {
    catalog = { at: Date.now(), list: await Cursor.models.list({ apiKey: cfg.apiKey }) };
  } catch (e) {
    log('Cursor 모델 목록을 읽지 못했습니다. 강도 옵션 없이 실행합니다:', e?.message ?? e);
  }
  return catalog.list;
}

function git(repo, args) {
  try {
    return execFileSync('git', args, { cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return null;
  }
}

function repoState(repo) {
  const status = git(repo, ['status', '--porcelain']);
  return {
    head: git(repo, ['rev-parse', '--short', 'HEAD']),
    branch: git(repo, ['rev-parse', '--abbrev-ref', 'HEAD']),
    dirty_files: status == null ? null : status.split('\n').filter(Boolean).length,
  };
}

function assertSecretHook(repo) {
  const hooks = join(repo, '.cursor', 'hooks.json');
  const script = join(repo, '.cursor', 'hooks', 'deny-secrets.mjs');
  if (!existsSync(hooks) || !existsSync(script) || !readFileSync(hooks, 'utf8').includes('deny-secrets.mjs')) {
    throw new ConfigError('비밀 파일 차단 훅(.cursor/hooks.json, deny-secrets.mjs)이 없어 시작하지 않습니다.');
  }
}

let stopping = false;
let activeRun = null;

const CONTINUE_LOG = { applied: '그대로 얹음', merged: '3-way로 합쳐 얹음', already_present: '이미 작업 폴더에 있음' };

/**
 * 복사본 준비. 수정은 늘, 조사·조율은 이어받기일 때만 복사본에서 돈다(아니면 null: 작업 폴더에서 읽기만).
 *   재수정(job.fix): 앞 수정의 기준 커밋 + 앞 diff.
 *   이어받기(request.continue_from): 지금 작업 폴더 스냅샷 + 앞 수정 요청의 최종 패치(job.base_patch).
 *   그 밖: 지금 작업 폴더 스냅샷.
 * 실패는 예외로 올려 조사 실패와 같게 보고한다. 패치 본문은 로그에 찍지 않는다.
 */
function prepareWork(cfg, job) {
  const change = job.mode === 'change';
  const fix = change && job.fix && typeof job.fix === 'object' ? job.fix : null;
  if (change && !fix && job.request?.fix_of) throw new Error('앞 수정의 diff를 서버에서 받지 못해 재수정을 시작하지 못했습니다.');
  const patch = fix ? null : continuePatch(job);
  if (!change && !patch) return null;
  let base;
  let dir;
  let continued = null;
  if (fix) {
    base = { commit: String(fix.base_commit ?? ''), excluded: 0 };
    dir = createFixWorktree(cfg.repo, job.id, base.commit, fix.diff);
  } else {
    base = snapshot(cfg.repo, job.id, 'base');
    if (patch) {
      const c = createContinueWorktree(cfg.repo, job.id, base.commit, patch);
      dir = c.dir;
      continued = {
        request_id: patch.request_id,
        title: patch.title ?? null,
        round: patch.round ?? null,
        base_commit: patch.base_commit,
        files: c.stats.files,
        additions: c.stats.additions,
        deletions: c.stats.deletions,
        applied: c.applied,
        ...(patch.partial === 'timeout' ? { partial: 'timeout' } : {}),
      };
    } else {
      dir = createWorktree(cfg.repo, job.id, base.commit);
    }
  }
  try {
    assertSecretHook(dir);
  } catch (e) {
    removeWorktree(cfg.repo, dir);
    throw e;
  }
  if (fix) log(`재수정 복사본 준비: ${dir} (앞 수정을 얹음)`);
  else if (continued) {
    log(
      `이어받기 복사본 준비: ${dir} (요청 ${continued.request_id} ${continued.round ?? '?'}회차 ${continued.partial ? '미완성 ' : ''}패치 · 파일 ${continued.files}개 ` +
        `+${continued.additions} -${continued.deletions} · ${CONTINUE_LOG[continued.applied] ?? continued.applied})`,
    );
  } else log(`복사본 준비: ${dir} (비밀 경로 ${base.excluded}개 제외)`);
  return { base, dir, continued };
}

/** 검사 결과가 너무 크면 출력부터 줄인다. */
function fitVerification(v) {
  for (const max of [3_000, 1_200, 400, 0]) {
    if (JSON.stringify(v).length <= VERIFICATION_CHARS) break;
    for (const i of v.items) if (i.output && i.output.length > max) i.output = max ? `…${i.output.slice(-max)}` : null;
  }
  return v;
}

/**
 * 복사본에서 자동 검사. 운영 DB에는 연결하지 않는다. 끄려면 CODE_BRIDGE_CHECKS=off.
 * 검사는 AI가 쓴 코드(시험 포함)를 이 PC에서 실행하므로 환경 변수의 키·토큰은 빼고 넘긴다(checks.mjs scrubEnv).
 */
async function verifyChange(cfg, job, work, diff, shouldStop) {
  const record = {
    patch_sha256: createHash('sha256').update(diff, 'utf8').digest('hex'),
    base_commit: work.base.commit,
    checked_at: new Date().toISOString(),
  };
  const empty = (note, verdict = 'none') => ({ version: CHECKS_VERSION, stopped: false, duration_ms: 0, summary: summarize([]), verdict, items: [], note, ...record });
  if ((process.env.CODE_BRIDGE_CHECKS ?? '').trim().toLowerCase() === 'off') {
    return empty('작업자 설정(CODE_BRIDGE_CHECKS=off)으로 자동 검사를 껐습니다.', 'not_run');
  }
  const tools = findTools(process.env, WORKER_DIR, cfg.repo);
  let baseMigrations = [];
  try {
    baseMigrations = listTree(cfg.repo, work.base.commit, 'supabase/migrations');
  } catch {
    // 기준에 폴더가 없으면 빈 목록
  }
  const items = planChecks({
    paths: pathsFromDiff(diff),
    ...fsView(work.dir),
    baseMigrations,
    required: requiredChecks(job),
    tools: { flutter: Boolean(tools.flutter), deno: Boolean(tools.deno), dbTest: Boolean(tools.dbTestModules), nodeModules: tools.nodeModules },
  });
  if (items.length === 0) return empty('자동 검사할 파일이 없습니다(문서·규칙만 바뀜).');
  let baseDir = null;
  try {
    const v = await runChecks({
      dir: work.dir,
      items,
      tools,
      shouldStop,
      budgetMs: cfg.checksTimeoutMs,
      stepTimeoutMs: cfg.checkStepTimeoutMs,
      log,
      baseline: async () => {
        log('실패한 검사를 바꾸기 전 상태에서도 돌려 봅니다.');
        baseDir = createWorktree(cfg.repo, job.id, work.base.commit, { suffix: 'baseline' });
        return baseDir;
      },
    });
    return fitVerification({ ...v, ...record });
  } finally {
    if (baseDir) removeWorktree(cfg.repo, baseDir);
  }
}

/** 요청(조율본)에 적힌 필수 검사. */
function requiredChecks(job) {
  const r = job.request && typeof job.request === 'object' ? job.request : {};
  return Array.isArray(r.checks) ? r.checks : [];
}

/** 수정 시작 전: 요청한 필수 검사를 이 PC에서 돌릴 수 있는지 본다. 결과는 프롬프트와 결과 기록에 남긴다. */
function preflight(cfg, job, work) {
  const required = requiredChecks(job);
  if (required.length === 0 || !work) return [];
  const tools = findTools(process.env, WORKER_DIR, cfg.repo);
  const out = preflightChecks(required, { ...fsView(work.dir), tools });
  for (const p of out) log(`필수 검사 사전 확인: ${p.command} (${p.cwd ?? '?'}) → ${p.ok ? '가능' : `불가: ${p.problem}`}${p.note ? ` · ${p.note}` : ''}`);
  return out;
}

const VERDICT_LOG = { passed: '필수 검사 통과', failed: '필수 검사 실패', not_run: '필수 검사 일부 실행 못 함', none: '필수 검사 대상 없음' };

function verificationLine(v) {
  if (!v) return '';
  const s = v.summary;
  if (v.items.length === 0) return ` · ${VERDICT_LOG[v.verdict] ?? '검사 없음'} (${v.note ?? ''})`;
  return ` · ${VERDICT_LOG[v.verdict] ?? '검사'}: 통과 ${s.passed} / 실패 ${s.failed} / 미실행 ${s.skipped}${s.preexisting ? ` / 원래도 실패 ${s.preexisting}` : ''}${v.stopped ? ' (중간에 멈춤)' : ''}`;
}

/** 복사본의 변경을 결과로 만든다. 올리면 안 되는 diff면 { error }. */
function changeResult(work, text) {
  const d = collectDiff(work.dir, work.base.commit);
  if (d.protectedPaths.length > 0) return { error: `보호된 경로를 바꿔 결과를 버렸습니다: ${d.protectedPaths.slice(0, 5).join(', ')}` };
  if (!d.utf8) return { error: 'UTF-8이 아닌 파일이 바뀌어 diff를 올리지 않았습니다.' };
  if (d.diff.length > MAX_DIFF_CHARS) return { error: `diff가 ${Math.round(d.diff.length / 1000)}KB로 한도(400KB)를 넘습니다. 요청을 나눠 주세요.` };
  if (looksSecret(d.diff)) return { error: 'diff에 키처럼 보이는 문자열이 있어 올리지 않았습니다.' };
  const parsed = parseChangeResult(text);
  const summary = parsed.value.summary || (d.stats.files === 0 ? '바뀐 파일이 없습니다.' : `파일 ${d.stats.files}개를 바꿨습니다.`);
  return {
    parse_ok: parsed.ok || d.stats.files > 0,
    result: {
      ...redactDeep({ ...parsed.value, summary }),
      diff: d.diff,
      diff_stats: d.stats,
      base_commit: work.base.commit,
      ...(work.continued ? { continued_from: work.continued } : {}),
    },
  };
}

async function processApply(cfg, bridge, job) {
  const reverse = job.job === 'revert';
  log(`${reverse ? '되돌리기' : '적용'} 시작: "${job.title}"`);
  if (!reverse && job.diff) {
    const patchPaths = pathsFromDiff(job.diff);
    const overlap = intersectPaths(patchPaths, workingTreeChangedPaths(cfg.repo));
    if (overlap.length > 0) {
      log(
        `패치와 작업 폴더 미커밋 변경이 ${overlap.length}개 경로에서 겹칩니다. git apply --check가 실패하면 아무것도 바꾸지 않습니다.`,
      );
    }
  }
  let out;
  try {
    await bridge.heartbeat(job.id, null, null);
    out = applyToWorkingTree(cfg.repo, job.id, job.diff ?? '', { reverse });
  } catch (e) {
    out = { ok: false, error: String(e?.message ?? e).slice(0, 1500) };
  }
  try {
    const res = await bridge.applyDone(job.id, out.ok, out);
    log(`${reverse ? '되돌리기' : '적용'} 끝: ${res.status}${out.ok ? '' : ` (${out.error})`}`);
  } catch (e) {
    log('결과 보고 실패. 운영자 화면에는 "상태 알 수 없음"으로 보입니다:', e.message);
  }
}

async function processJob(cfg, bridge, job) {
  if (job.job === 'apply' || job.job === 'revert') return processApply(cfg, bridge, job);
  const change = job.mode === 'change';
  const label = modeLabel(job.mode);
  const timeoutMs = change ? cfg.changeTimeoutMs : cfg.roundTimeoutMs;
  // 'mcp'는 저장소 .cursor/mcp.json의 서버까지 켜므로, 그 파일이 있으면 묻기를 끈다.
  const askThink = askThinkAllowed(cfg, job) && !existsSync(join(cfg.repo, '.cursor', 'mcp.json'));
  let prompt = promptFor(job, { askThink });
  let checksBefore = [];
  const timings = { prepare_ms: 0, agent_ms: 0, checks_ms: 0 };
  const tools = new ToolCounter();
  const turn = new TurnTracker();
  const state = repoState(cfg.repo);
  const startedAt = Date.now();
  let agent = null;
  let run = null;
  let cancelled = false;
  let timedOut = false;
  let lost = false;
  let stuck = false;
  let grace = null;
  let beating = null;
  let work = null;
  let store = null;
  let stateRoot = null;
  let completed = false;
  const wantedEffort = requestEffort(job);
  let chosen = { selection: { id: cfg.model }, effort: null };

  const round = (extra = {}) => ({
    prompt: redact(prompt),
    prompt_version: PROMPT_VERSION,
    model: extra.model ?? (run ? chosen.selection.id : null),
    effort: run ? chosen.effort : null,
    duration_ms: Date.now() - startedAt,
    tool_calls: tools.list(),
    repo_state: state,
    cursor_agent_id: agent?.agentId ?? null,
    cursor_run_id: run?.id ?? null,
    ...extra,
  });

  const stopRun = async () => {
    try {
      await run?.cancel();
    } catch {
      // 이미 끝남
    }
  };

  let lastProgress = Date.now();
  const progress = () => {
    if (Date.now() - lastProgress < cfg.progressLogMs) return;
    lastProgress = Date.now();
    const calls = tools.list().reduce((n, t) => n + t.count, 0);
    const minutes = Math.floor((Date.now() - startedAt) / 60_000);
    const files = change && work ? git(work.dir, ['status', '--porcelain']) : null;
    const changed = files == null ? '' : ` · 바뀐 파일 ${files.split('\n').filter(Boolean).length}개`;
    log(`${label} 진행 중 · ${minutes}분 · 도구 ${calls}회${changed} (제한 ${Math.round(timeoutMs / 60_000)}분)`);
  };

  const beat = async () => {
    progress();
    try {
      const hb = await bridge.heartbeat(job.id, agent?.agentId, run?.id);
      if (hb.lost) {
        lost = true;
        await stopRun();
      } else if (hb.cancel_requested && !cancelled) {
        cancelled = true;
        log('운영자가 취소를 요청해 멈춥니다.');
        await stopRun();
      }
    } catch (e) {
      log('진행 신호 실패:', e.message);
    }
  };
  let beatInFlight = null;
  const tick = () => {
    beatInFlight ??= beat().finally(() => {
      beatInFlight = null;
    });
    return beatInFlight;
  };
  // complete·fail RPC는 요청 행 → 작업자 행, heartbeat RPC는 작업자 행 → 요청 행 순서로 잠가 겹치면 교착된다.
  const quiet = async () => {
    if (beating) clearInterval(beating);
    beating = null;
    await beatInFlight;
  };
  const report = {
    complete: async (...args) => (await quiet(), bridge.complete(...args)),
    fail: async (...args) => (await quiet(), bridge.fail(...args)),
  };

  log(`${label} 시작: "${job.title}" (회차 ${job.round}, 시도 ${job.attempts})`);
  const timeout = setTimeout(() => {
    timedOut = true;
    log(`${Math.round(timeoutMs / 60_000)}분이 지나 멈춥니다.`);
    void stopRun();
  }, timeoutMs);

  try {
    work = prepareWork(cfg, job);
    // 차단 훅이 이 값을 보고 복사본 밖 경로를 막는다(훅은 작업자 환경 변수를 물려받는다).
    if (work) process.env.CODE_BRIDGE_WRITE_ROOT = work.dir;
    if (change) {
      checksBefore = preflight(cfg, job, work);
      if (checksBefore.length > 0) prompt = promptFor(job, { askThink, preflight: checksBefore });
    }
    timings.prepare_ms = Date.now() - startedAt;
    const local = { cwd: work ? work.dir : cfg.repo, settingSources: ['project'] };
    stateRoot = sdkStateRoot(job.id);
    if (!sdkStorePathFits(stateRoot)) throw new Error(`Cursor 대화 기록 경로가 Windows 경로 길이 한도를 넘습니다: ${stateRoot}`);
    rmSync(stateRoot, { recursive: true, force: true });
    store = await SqliteLocalAgentStore.open({ workspaceRef: local.cwd, stateRoot });
    local.store = store;
    if (askThink) {
      local.customTools = {
        ask_think: createAskThinkTool({
          ask: (question) => bridge.askThink(job.id, question),
          onAsk: ({ n, limit, verdict, error }) => log(`Think에게 물음 (${n}/${limit}): ${verdict ?? `실패 ${error}`}`),
        }),
      };
    }
    chosen = resolveModelSelection(await modelCatalog(cfg), cfg.model, wantedEffort);
    log(`모델 ${chosen.selection.id} · 강도 ${chosen.effort ?? '옵션 없음'}${chosen.effort && chosen.effort !== wantedEffort ? ` (요청 ${wantedEffort}, 지원 강도 중 가장 가까운 값)` : ''}`);
    agent = await Agent.create({
      apiKey: cfg.apiKey,
      model: chosen.selection,
      mode: change ? 'agent' : 'plan',
      tools: change ? CHANGE_TOOLS : askThink ? ASK_TOOLS : READ_ONLY_TOOLS,
      local,
    });
    run = await agent.send(prompt);
    activeRun = run;
    await tick();
    beating = setInterval(tick, cfg.heartbeatMs);

    for await (const event of run.stream()) {
      tools.add(event);
      turn.add(event);
      if (turn.ended && !grace) {
        grace = setTimeout(() => {
          if (!turn.ended) return;
          stuck = true;
          log(`Cursor 답변은 끝났는데 실행이 ${Math.round(cfg.finishGraceMs / 1000)}초 동안 닫히지 않아 받아 둔 답으로 마칩니다.`);
          void stopRun();
        }, cfg.finishGraceMs);
      } else if (!turn.ended && grace) {
        clearTimeout(grace);
        grace = null;
      }
    }
    const result = await run.wait();
    clearTimeout(timeout);
    timings.agent_ms = Date.now() - startedAt - timings.prepare_ms;
    if (lost) {
      log('점유를 잃어 결과를 올리지 않습니다.');
      return;
    }
    const model = result.model?.id ?? chosen.selection.id;
    chosen = { ...chosen, effort: usedEffort(result.model, chosen.effort) };
    const finished = result.status === 'finished' || (stuck && !cancelled && !stopping);
    if (cancelled) {
      await report.fail(job.id, 'cancelled', '운영자 취소', false, round({ model }));
    } else if (stopping) {
      await report.fail(job.id, 'internal', '작업자를 꺼서 대기열로 돌려놓았습니다.', true, round({ model }));
    } else if (timedOut && !stuck) {
      const minutes = Math.round(timeoutMs / 60_000);
      const partial = change ? changeResult(work, '') : null;
      if (partial && !partial.error && partial.result.diff_stats.files > 0) {
        // 고친 데까지는 남겨 운영자가 보게 한다. 형식 확인 필요(needs_review)라 적용 버튼은 나오지 않는다.
        // partial 표시가 있어야 서버가 이 패치를 후속 요청의 출발점(이어받기)으로 내준다.
        partial.result.summary = `${minutes}분 안에 끝나지 않아 멈췄습니다. 여기까지 고친 내용입니다(완성되지 않음). ${partial.result.summary}`;
        partial.result.partial = 'timeout';
        const out = await report.complete(job.id, round({ model, usage: result.usage ?? null, result: partial.result, parse_ok: false }));
        completed = true;
        log(`시간 초과: 여기까지 고친 diff를 남겼습니다 (${out.status}, 파일 ${partial.result.diff_stats.files}개).`);
      } else {
        await report.fail(job.id, 'timeout', `${minutes}분 안에 끝나지 않았습니다.`, false, round({ model }));
      }
    } else if (!finished) {
      const message = result.error?.message ?? `run ${result.status}`;
      log(`${label} 실패 (Cursor 실행 ${result.status}): ${message}`);
      await report.fail(job.id, 'run_error', message, false, round({ model, usage: result.usage ?? null }));
    } else if (change) {
      const text = redact((stuck ? turn.text : result.result) || turn.text);
      const c = changeResult(work, text);
      if (c.error) {
        await report.fail(job.id, 'run_error', c.error, false, round({ model, usage: result.usage ?? null, result_text: text }));
        log(`수정 결과를 버렸습니다: ${c.error}`);
        return;
      }
      if (c.result.diff_stats.files > 0) {
        log(`수정 끝 · 파일 ${c.result.diff_stats.files}개. 자동 검사를 시작합니다.`);
        const checksStarted = Date.now();
        c.result.verification = await verifyChange(cfg, job, work, c.result.diff, () => cancelled || lost || stopping);
        timings.checks_ms = Date.now() - checksStarted;
      }
      if (checksBefore.length > 0) c.result.preflight = checksBefore;
      c.result.timings = timings;
      if (lost) {
        log('점유를 잃어 결과를 올리지 않습니다.');
        return;
      }
      if (cancelled) {
        await report.fail(job.id, 'cancelled', '운영자 취소(자동 검사 중)', false, round({ model }));
        return;
      }
      const out = await report.complete(job.id, round({
        model,
        usage: result.usage ?? null,
        result_text: text,
        result: c.result,
        parse_ok: c.parse_ok,
      }));
      completed = true;
      log(
        `수정 끝: ${out.status} · 파일 ${c.result.diff_stats.files}개 +${c.result.diff_stats.additions} -${c.result.diff_stats.deletions}` +
          `${verificationLine(c.result.verification)}${out.review ? ' · Think가 검토합니다' : ''}`,
      );
    } else {
      const text = redact((stuck ? turn.text : result.result) || turn.text);
      const parsed = job.mode === 'plan' ? parsePlanResult(text) : parseResult(text);
      const out = await report.complete(job.id, round({
        model,
        usage: result.usage ?? null,
        result_text: text,
        result: parsed.ok ? { ...redactDeep(parsed.value), ...(work?.continued ? { continued_from: work.continued } : {}), timings } : null,
        parse_ok: parsed.ok,
      }));
      completed = true;
      log(`${label} 끝: ${out.status}${parsed.ok ? '' : ` (형식 불일치: ${parsed.reason})`}${out.review ? ' · Think가 검토합니다' : ''}`);
    }
  } catch (e) {
    if (lost || (e instanceof BridgeError && e.code === 'not_owner')) {
      log('점유를 잃어 결과를 올리지 않습니다.');
      return;
    }
    const c = classifyError(e);
    log(`${label} 실패 (${c.code}${c.retryable ? ', 다시 시도' : ''}): ${c.message}`);
    try {
      await report.fail(job.id, c.code, c.message, c.retryable, round());
    } catch (reportError) {
      log('실패 보고도 못 했습니다. 점유가 끝나면 서버가 정리합니다:', reportError.message);
    }
    if (c.retryable) await sleep(retryDelayMs(job.attempts));
  } finally {
    clearTimeout(timeout);
    if (grace) clearTimeout(grace);
    if (beating) clearInterval(beating);
    activeRun = null;
    try {
      agent?.close();
    } catch {
      // 무시
    }
    await store?.dispose().catch(() => {});
    if (stateRoot && existsSync(stateRoot)) {
      if (completed) {
        try {
          rmSync(stateRoot, { recursive: true, force: true });
        } catch (e) {
          log('Cursor 실행 기록 정리 실패(계속 진행):', e.message);
        }
      } else log(`Cursor 실행 기록을 남겨 둡니다(원인 확인용): ${stateRoot}`);
    }
    if (work) {
      delete process.env.CODE_BRIDGE_WRITE_ROOT;
      // diff는 서버에 있고 기준 커밋은 ref로 남아 있으므로 복사본은 지운다.
      removeWorktree(cfg.repo, work.dir);
    }
  }
}

async function main() {
  const cfg = loadConfig(process.env);
  assertSecretHook(cfg.repo);
  const bridge = createBridgeClient(cfg);
  const info = { version: VERSION, model: cfg.model, node: process.versions.node, sdk: '@cursor/sdk' };
  log(`작업자 ${cfg.workerId} 시작 · 모델 ${cfg.model} · 저장소 ${cfg.repo} · Think 묻기 ${cfg.askThink ? '켬(조사·조율)' : '끔'}`);
  log(
    `조사·조율: 읽기 전용(제한 ${Math.round(cfg.roundTimeoutMs / 60_000)}분). ` +
      `수정: 복사본에서 편집·삭제만, 셸 없음(제한 ${Math.round(cfg.changeTimeoutMs / 60_000)}분). 적용은 운영자 승인 뒤. Ctrl+C로 끕니다.`,
  );
  try {
    const pruned = pruneRefs(cfg.repo, 30);
    if (pruned > 0) log(`30일 지난 참조 ${pruned}개를 지웠습니다.`);
  } catch (e) {
    log('참조 정리 실패(계속 진행):', e.message);
  }

  process.on('SIGINT', () => {
    if (stopping) process.exit(130);
    stopping = true;
    log('끄는 중입니다. 진행 중인 조사는 대기열로 돌려놓습니다. 한 번 더 누르면 바로 끕니다.');
    void activeRun?.cancel().catch(() => {});
  });

  let idleNotice = 0;
  while (!stopping) {
    let job = null;
    try {
      const out = await bridge.claim(info);
      job = out.request;
    } catch (e) {
      log('대기열 확인 실패:', e.message);
      if (e instanceof BridgeError && (e.status === 401 || e.status === 503)) {
        log('작업자 토큰이나 서버 비밀값을 확인하세요. 1분 뒤 다시 시도합니다.');
      }
      await sleep(60_000);
      continue;
    }
    if (!job) {
      if (Date.now() - idleNotice > 10 * 60_000) {
        log('대기 중인 요청이 없습니다.');
        idleNotice = Date.now();
      }
      await sleep(cfg.pollMs);
      continue;
    }
    await processJob(cfg, bridge, job);
  }
  log('작업자를 껐습니다.');
}

main().catch((e) => {
  console.error(e instanceof ConfigError ? e.message : e);
  process.exit(1);
});
