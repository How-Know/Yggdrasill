// Edge Function ai_code_bridge 호출. 작업자 토큰만 보낸다(Supabase 서비스 키는 쓰지 않는다).

export class BridgeError extends Error {
  constructor(message, status, code) {
    super(message);
    this.name = 'BridgeError';
    this.status = status;
    this.code = code;
  }
}

export function createBridgeClient(cfg, fetchImpl = fetch) {
  async function call(action, payload = {}) {
    const headers = { 'Content-Type': 'application/json', Authorization: `Bearer ${cfg.token}` };
    if (cfg.anonKey) headers.apikey = cfg.anonKey;
    let res;
    try {
      res = await fetchImpl(cfg.url, {
        method: 'POST',
        headers,
        body: JSON.stringify({ action, worker_id: cfg.workerId, ...payload }),
        signal: AbortSignal.timeout(30_000),
      });
    } catch (e) {
      throw new BridgeError(`bridge ${action}: ${e?.message ?? e}`, 0, 'network');
    }
    let body = null;
    try {
      body = await res.json();
    } catch {
      body = null;
    }
    if (!res.ok || body?.ok !== true) {
      throw new BridgeError(`bridge ${action}: HTTP ${res.status} ${body?.error ?? ''}`.trim(), res.status, body?.error ?? null);
    }
    return body;
  }

  return {
    claim: (info) => call('claim', { info }),
    heartbeat: (requestId, agentId, runId) =>
      call('heartbeat', { request_id: requestId ?? null, agent_id: agentId ?? null, run_id: runId ?? null }),
    complete: (requestId, round) => call('complete', { request_id: requestId, round }),
    fail: (requestId, code, error, retryable, round) =>
      call('fail', { request_id: requestId, code, error, retryable, round: round ?? null }),
    applyDone: (requestId, ok, result) => call('apply_done', { request_id: requestId, ok, result }),
  };
}
