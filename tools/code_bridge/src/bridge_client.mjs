// Edge Function ai_code_bridge 호출. 작업자 토큰만 보낸다(Supabase 서비스 키는 쓰지 않는다).

export class BridgeError extends Error {
  constructor(message, status, code) {
    super(message);
    this.name = 'BridgeError';
    this.status = status;
    this.code = code;
  }
}

/** Think 답변은 서버에서 최대 약 150초 걸린다. */
export const ASK_TIMEOUT_MS = 170_000;

export function createBridgeClient(cfg, fetchImpl = fetch) {
  function post(action, payload, timeoutMs) {
    const headers = { 'Content-Type': 'application/json', Authorization: `Bearer ${cfg.token}` };
    if (cfg.anonKey) headers.apikey = cfg.anonKey;
    return fetchImpl(cfg.url, {
      method: 'POST',
      headers,
      body: JSON.stringify({ action, worker_id: cfg.workerId, ...payload }),
      signal: AbortSignal.timeout(timeoutMs),
    });
  }

  async function call(action, payload = {}) {
    let res;
    try {
      res = await post(action, payload, 30_000);
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
    /** 실패도 던지지 않고 { ok:false, error, message }로 돌려준다(에이전트가 읽고 계속한다). */
    async askThink(requestId, question) {
      try {
        const res = await post('ask_think', { request_id: requestId, question }, ASK_TIMEOUT_MS);
        const body = await res.json().catch(() => null);
        if (body && typeof body === 'object') return body;
        return { ok: false, error: `http_${res.status}` };
      } catch (e) {
        return { ok: false, error: 'network', message: String(e?.message ?? e).slice(0, 300) };
      }
    },
  };
}
