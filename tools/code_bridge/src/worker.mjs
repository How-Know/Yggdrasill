// Think 코드 작업자. 운영자 PC에서 `npm start`로 켠다. Ctrl+C로 끈다.
// 대기열에서 요청을 하나씩 가져간다.
//   조사: 작업 폴더에서 Cursor를 읽기 전용(plan)으로 돌린다.
//   수정: 작업 폴더 스냅샷의 복사본(worktree)에서 편집·삭제만 허용해 돌리고 diff를 올린다. 작업 폴더는 그대로다.
//   적용·되돌리기: 운영자가 승인한 diff를 `git apply --check` 통과 시에만 작업 폴더에 반영한다.
// 설계: docs/architecture/ai-code-bridge.md, docs/architecture/ai-think-actions.md
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { Agent } from '@cursor/sdk';
import { BridgeError, createBridgeClient } from './bridge_client.mjs';
import { applyToWorkingTree, collectDiff, createWorktree, pruneRefs, removeWorktree, snapshot } from './git_ops.mjs';
import {
  CHANGE_TOOLS,
  ConfigError,
  MAX_DIFF_CHARS,
  PROMPT_VERSION,
  READ_ONLY_TOOLS,
  ToolCounter,
  classifyError,
  loadConfig,
  looksSecret,
  parseChangeResult,
  parseResult,
  promptFor,
  redact,
  redactDeep,
  retryDelayMs,
} from './lib.mjs';

const VERSION = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')).version;

function log(...args) {
  console.log(new Date().toLocaleTimeString('ko-KR', { hour12: false }), ...args);
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

/** 수정 모드 준비: 스냅샷 → 복사본. 실패는 예외로 올려 조사 실패와 같게 보고한다. */
function prepareChange(cfg, job) {
  const base = snapshot(cfg.repo, job.id, 'base');
  const dir = createWorktree(cfg.repo, job.id, base.commit);
  try {
    assertSecretHook(dir);
  } catch (e) {
    removeWorktree(cfg.repo, dir);
    throw e;
  }
  log(`복사본 준비: ${dir} (비밀 경로 ${base.excluded}개 제외)`);
  return { base, dir };
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
    result: { ...redactDeep({ ...parsed.value, summary }), diff: d.diff, diff_stats: d.stats, base_commit: work.base.commit },
  };
}

async function processApply(cfg, bridge, job) {
  const reverse = job.job === 'revert';
  log(`${reverse ? '되돌리기' : '적용'} 시작: "${job.title}"`);
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
  const prompt = promptFor(job);
  const tools = new ToolCounter();
  const state = repoState(cfg.repo);
  const startedAt = Date.now();
  let agent = null;
  let run = null;
  let cancelled = false;
  let timedOut = false;
  let lost = false;
  let beating = null;
  let work = null;

  const round = (extra = {}) => ({
    prompt: redact(prompt),
    prompt_version: PROMPT_VERSION,
    model: extra.model ?? (run ? cfg.model : null),
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

  const beat = async () => {
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

  log(`${change ? '수정' : '조사'} 시작: "${job.title}" (회차 ${job.round}, 시도 ${job.attempts})`);
  const timeout = setTimeout(() => {
    timedOut = true;
    log('시간 초과로 멈춥니다.');
    void stopRun();
  }, cfg.roundTimeoutMs);

  try {
    if (change) {
      work = prepareChange(cfg, job);
      // 차단 훅이 이 값을 보고 복사본 밖 경로를 막는다(훅은 작업자 환경 변수를 물려받는다).
      process.env.CODE_BRIDGE_WRITE_ROOT = work.dir;
    }
    agent = await Agent.create({
      apiKey: cfg.apiKey,
      model: { id: cfg.model },
      mode: change ? 'agent' : 'plan',
      tools: change ? CHANGE_TOOLS : READ_ONLY_TOOLS,
      local: { cwd: change ? work.dir : cfg.repo, settingSources: ['project'] },
    });
    run = await agent.send(prompt);
    activeRun = run;
    await beat();
    beating = setInterval(beat, cfg.heartbeatMs);

    for await (const event of run.stream()) tools.add(event);
    const result = await run.wait();
    if (lost) {
      log('점유를 잃어 결과를 올리지 않습니다.');
      return;
    }
    const model = result.model?.id ?? cfg.model;
    if (cancelled) {
      await bridge.fail(job.id, 'cancelled', '운영자 취소', false, round({ model }));
    } else if (stopping) {
      await bridge.fail(job.id, 'internal', '작업자를 꺼서 대기열로 돌려놓았습니다.', true, round({ model }));
    } else if (timedOut) {
      await bridge.fail(job.id, 'timeout', `${Math.round(cfg.roundTimeoutMs / 60000)}분 안에 끝나지 않았습니다.`, false, round({ model }));
    } else if (result.status !== 'finished') {
      const message = result.error?.message ?? `run ${result.status}`;
      await bridge.fail(job.id, 'run_error', message, false, round({ model, usage: result.usage ?? null }));
    } else if (change) {
      const text = redact(result.result ?? '');
      const c = changeResult(work, text);
      if (c.error) {
        await bridge.fail(job.id, 'run_error', c.error, false, round({ model, usage: result.usage ?? null, result_text: text }));
        log(`수정 결과를 버렸습니다: ${c.error}`);
      } else {
        const out = await bridge.complete(job.id, round({
          model,
          usage: result.usage ?? null,
          result_text: text,
          result: c.result,
          parse_ok: c.parse_ok,
        }));
        log(`수정 끝: ${out.status} · 파일 ${c.result.diff_stats.files}개 +${c.result.diff_stats.additions} -${c.result.diff_stats.deletions}`);
      }
    } else {
      const text = redact(result.result ?? '');
      const parsed = parseResult(text);
      const out = await bridge.complete(job.id, round({
        model,
        usage: result.usage ?? null,
        result_text: text,
        result: parsed.ok ? redactDeep(parsed.value) : null,
        parse_ok: parsed.ok,
      }));
      log(`조사 끝: ${out.status}${parsed.ok ? '' : ` (형식 불일치: ${parsed.reason})`}`);
    }
  } catch (e) {
    if (lost || (e instanceof BridgeError && e.code === 'not_owner')) {
      log('점유를 잃어 결과를 올리지 않습니다.');
      return;
    }
    const c = classifyError(e);
    log(`조사 실패 (${c.code}${c.retryable ? ', 다시 시도' : ''}): ${c.message}`);
    try {
      await bridge.fail(job.id, c.code, c.message, c.retryable, round());
    } catch (reportError) {
      log('실패 보고도 못 했습니다. 점유가 끝나면 서버가 정리합니다:', reportError.message);
    }
    if (c.retryable) await sleep(retryDelayMs(job.attempts));
  } finally {
    clearTimeout(timeout);
    if (beating) clearInterval(beating);
    activeRun = null;
    try {
      agent?.close();
    } catch {
      // 무시
    }
    if (change) {
      delete process.env.CODE_BRIDGE_WRITE_ROOT;
      // diff는 서버에 있고 기준 커밋은 ref로 남아 있으므로 복사본은 지운다.
      if (work) removeWorktree(cfg.repo, work.dir);
    }
  }
}

async function main() {
  const cfg = loadConfig(process.env);
  assertSecretHook(cfg.repo);
  const bridge = createBridgeClient(cfg);
  const info = { version: VERSION, model: cfg.model, node: process.versions.node, sdk: '@cursor/sdk' };
  log(`작업자 ${cfg.workerId} 시작 · 모델 ${cfg.model} · 저장소 ${cfg.repo}`);
  log('조사: 읽기 전용(plan). 수정: 복사본에서 편집·삭제만(셸 없음). 적용은 운영자 승인 뒤. Ctrl+C로 끕니다.');
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
