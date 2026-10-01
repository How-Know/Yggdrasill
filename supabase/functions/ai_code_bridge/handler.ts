import type { AiRunRecord } from '../_shared/ai/usage.ts';
import {
  FAIL_CODES,
  LEASE_SECONDS,
  MAX_ERROR,
  parseApplyResult,
  parseInfo,
  parseRound,
  sameText,
  toAiUsage,
  uuidOrNull,
  workerIdOrNull,
  type RoundPayload,
} from './validate.ts';

export interface RpcResult {
  data: unknown;
  error: { message: string } | null;
}

export interface BridgeDeps {
  /** 비밀값 CODE_BRIDGE_WORKER_TOKEN_SHA256. 없으면 503. */
  tokenSha256: string | null;
  hash(token: string): Promise<string>;
  rpc(fn: string, args: Record<string, unknown>): Promise<RpcResult>;
  recordRun(rec: AiRunRecord): Promise<unknown>;
  /** 결과 자동 검토(code_review.ts). 작업자 응답을 기다리게 하지 않도록 background로 넘긴다. */
  review?(requestId: string): Promise<unknown>;
  background?(task: Promise<unknown>): void;
}

type Body = Record<string, unknown>;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

function fail(status: number, error: string): Response {
  return json({ ok: false, error }, status);
}

function rpcFailure(error: { message: string }, action: string): Response {
  if (error.message.includes('bridge_not_owner')) return fail(409, 'not_owner');
  console.error(`[ai_code_bridge] ${action} rpc failed:`, error.message);
  return fail(500, 'internal_error');
}

function runRecord(round: RoundPayload, status: AiRunRecord['status'], owner: Body, error?: string): AiRunRecord {
  return {
    feature: 'code_request',
    provider: 'cursor',
    model: round.model ?? 'unknown',
    promptVersion: round.prompt_version,
    status,
    error: error ?? null,
    usage: toAiUsage(round.usage),
    toolCalls: round.tool_calls.reduce((n, t) => n + t.count, 0),
    costUsd: null,
    latencyMs: round.duration_ms,
    conversationId: typeof owner.conversation_id === 'string' ? owner.conversation_id : null,
    createdBy: typeof owner.created_by === 'string' ? owner.created_by : null,
  };
}

async function claim(deps: BridgeDeps, workerId: string, body: Body): Promise<Response> {
  const { data, error } = await deps.rpc('ai_code_bridge_claim', {
    p_worker_id: workerId,
    p_lease_seconds: LEASE_SECONDS,
    p_info: parseInfo(body.info),
  });
  if (error) return rpcFailure(error, 'claim');
  const out = (data ?? {}) as Body;
  const req = out.request && typeof out.request === 'object' ? (out.request as Body) : null;
  const round = out.round && typeof out.round === 'object' ? (out.round as Body) : null;
  const job = out.job === 'apply' || out.job === 'revert' ? out.job : 'run';
  const result = round?.result && typeof round.result === 'object' ? (round.result as Body) : {};
  return json({
    ok: true,
    lease_seconds: LEASE_SECONDS,
    request: req
      ? {
          id: req.id,
          job,
          mode: req.mode === 'change' ? 'change' : 'investigate',
          title: req.title,
          request: req.request,
          round: req.round,
          max_rounds: req.max_rounds,
          attempts: req.attempts,
          cursor_agent_id: req.cursor_agent_id ?? null,
          followup_prompt: job === 'run' && typeof round?.prompt === 'string' ? round.prompt : null,
          diff: job === 'run' ? null : typeof result.diff === 'string' ? result.diff : null,
          base_commit: job === 'run' ? null : typeof result.base_commit === 'string' ? result.base_commit : null,
        }
      : null,
  });
}

async function applyDone(deps: BridgeDeps, workerId: string, body: Body): Promise<Response> {
  const requestId = uuidOrNull(body.request_id);
  if (!requestId) return fail(400, 'request_id_invalid');
  const result = parseApplyResult(body.result);
  if (!result.ok) return fail(400, result.error);
  const { data, error } = await deps.rpc('ai_code_bridge_apply_done', {
    p_worker_id: workerId,
    p_request_id: requestId,
    p_ok: body.ok === true,
    p_result: result.value,
  });
  if (error) return rpcFailure(error, 'apply_done');
  return json({ ok: true, status: ((data ?? {}) as Body).status ?? null });
}

async function heartbeat(deps: BridgeDeps, workerId: string, body: Body): Promise<Response> {
  const requestId = body.request_id == null ? null : uuidOrNull(body.request_id);
  if (body.request_id != null && !requestId) return fail(400, 'request_id_invalid');
  const agentId = typeof body.agent_id === 'string' ? body.agent_id.slice(0, 200) : null;
  const runId = typeof body.run_id === 'string' ? body.run_id.slice(0, 200) : null;
  const { data, error } = await deps.rpc('ai_code_bridge_heartbeat', {
    p_worker_id: workerId,
    p_request_id: requestId,
    p_lease_seconds: LEASE_SECONDS,
    p_agent_id: agentId,
    p_run_id: runId,
  });
  if (error) return rpcFailure(error, 'heartbeat');
  const out = (data ?? {}) as Body;
  return json({ ok: true, lost: out.lost === true, cancel_requested: out.cancel_requested === true });
}

async function complete(deps: BridgeDeps, workerId: string, body: Body): Promise<Response> {
  const requestId = uuidOrNull(body.request_id);
  if (!requestId) return fail(400, 'request_id_invalid');
  const round = parseRound(body.round);
  if (!round.ok) return fail(400, round.error);
  const { data, error } = await deps.rpc('ai_code_bridge_complete', {
    p_worker_id: workerId,
    p_request_id: requestId,
    p_round: round.value,
  });
  if (error) return rpcFailure(error, 'complete');
  const out = (data ?? {}) as Body;
  if (round.value.model) await deps.recordRun(runRecord(round.value, 'ok', out));
  if (out.review === true && deps.review) {
    const task = deps.review(requestId).catch((e) => {
      console.error('[ai_code_bridge] review failed:', e instanceof Error ? e.message : String(e));
    });
    if (deps.background) deps.background(task);
    else await task;
  }
  return json({ ok: true, status: out.status ?? null });
}

async function failRound(deps: BridgeDeps, workerId: string, body: Body): Promise<Response> {
  const requestId = uuidOrNull(body.request_id);
  if (!requestId) return fail(400, 'request_id_invalid');
  const code = typeof body.code === 'string' && FAIL_CODES.has(body.code) ? body.code : null;
  if (!code) return fail(400, 'code_invalid');
  const message = typeof body.error === 'string' && body.error.trim() ? body.error.trim().slice(0, MAX_ERROR) : code;
  const round = parseRound(body.round);
  if (!round.ok) return fail(400, round.error);
  const { data, error } = await deps.rpc('ai_code_bridge_fail', {
    p_worker_id: workerId,
    p_request_id: requestId,
    p_code: code,
    p_error: message,
    p_retryable: body.retryable === true,
    p_round: round.value,
  });
  if (error) return rpcFailure(error, 'fail');
  const out = (data ?? {}) as Body;
  if (round.value.model) {
    await deps.recordRun(runRecord(round.value, code === 'cancelled' ? 'stopped' : 'error', out, `${code}: ${message}`));
  }
  return json({ ok: true, status: out.status ?? null });
}

export async function handleBridge(req: Request, deps: BridgeDeps): Promise<Response> {
  if (req.method !== 'POST') return fail(405, 'method_not_allowed');
  const expected = deps.tokenSha256?.trim().toLowerCase() ?? '';
  if (!/^[0-9a-f]{64}$/.test(expected)) return fail(503, 'bridge_not_configured');

  const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '').trim();
  if (!token || !sameText(await deps.hash(token), expected)) return fail(401, 'unauthorized');

  let body: Body;
  try {
    const parsed = await req.json();
    body = parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? (parsed as Body) : {};
  } catch {
    return fail(400, 'invalid_json');
  }
  const workerId = workerIdOrNull(body.worker_id);
  if (!workerId) return fail(400, 'worker_id_invalid');

  try {
    switch (String(body.action ?? '')) {
      case 'claim':
        return await claim(deps, workerId, body);
      case 'heartbeat':
        return await heartbeat(deps, workerId, body);
      case 'complete':
        return await complete(deps, workerId, body);
      case 'fail':
        return await failRound(deps, workerId, body);
      case 'apply_done':
        return await applyDone(deps, workerId, body);
      default:
        return fail(400, 'unknown_action');
    }
  } catch (e) {
    console.error('[ai_code_bridge] handler failed:', e instanceof Error ? e.message : String(e));
    return fail(500, 'internal_error');
  }
}
