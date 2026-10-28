// 검수 집계 조회의 바깥 시간 제한용 진단. 집계 함수를 부르지 않고, 원문·모델 출력은 넣지 않는다.

import type { ReviewJobRpc, ReviewJobToolSource } from './concept_review_job_tools.ts';

/** get_concept_review_job 바깥 제한과 같다. 묶음 검수의 집계 조회도 이 값을 쓴다. */
export const STATUS_QUERY_TIMEOUT_MS = 8000;
const DIAG_SAVE_MS = 2000;

export type StatusOutcome = 'failed' | 'unaggregated' | 'counted' | 'not_run';

export interface StatusTrace {
  traceId: string;
  stage: string;
  started: number;
  timeoutMs: number;
  jobId: string | null;
  abort: AbortController;
  /** 이 조회에 건 제한 시간으로 취소했다. 데이터베이스 문장이 끝났다는 뜻은 아니다. */
  cancelRequested: boolean;
}

export interface StatusDiagnosis {
  trace_id: string;
  stage: string;
  elapsed_ms: number;
  timeout_ms: number;
  code: string;
  outcome: StatusOutcome;
  db_cancel: 'requested' | 'not_requested';
}

export function createStatusTrace(timeoutMs: number): StatusTrace {
  return {
    traceId: crypto.randomUUID(),
    stage: 'db_rpc_wait',
    started: Date.now(),
    timeoutMs,
    jobId: null,
    abort: new AbortController(),
    cancelRequested: false,
  };
}

export function statusDiagnosis(trace: StatusTrace, code: string, outcome: StatusOutcome): StatusDiagnosis {
  return {
    trace_id: trace.traceId,
    stage: trace.stage,
    elapsed_ms: Math.max(0, Date.now() - trace.started),
    timeout_ms: trace.timeoutMs,
    code,
    outcome,
    db_cancel: trace.cancelRequested ? 'requested' : 'not_requested',
  };
}

/** 제한 시간이 되면 onTimeout을 부른 뒤 tool_timeout으로 거절한다. 안쪽 약속이 나중에 거절돼도 삼킨다. */
export function raceTimeout<T>(p: Promise<T>, ms: number, onTimeout?: () => void): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  let settled = false;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      if (!settled) onTimeout?.();
      reject(new Error('tool_timeout'));
    }, ms);
  });
  p.then(() => {
    settled = true;
  }, () => {
    settled = true;
  });
  return Promise.race([p, timeout]).finally(() => clearTimeout(timer));
}

type RpcSource = Pick<ReviewJobToolSource, 'reviewJobRpc'>;

/** 느린 집계가 끝나기를 기다리지 않는다. 저장 실패는 이번 응답을 지우지 않는다. */
export async function saveStatusDiag(src: RpcSource | undefined, jobId: string | null, diag: StatusDiagnosis): Promise<'saved' | 'failed' | 'skipped'> {
  if (!src?.reviewJobRpc || !jobId) return 'skipped';
  const ac = new AbortController();
  const fn: ReviewJobRpc = 'concept_review_job_status_diag_put';
  const pending = src.reviewJobRpc(fn, { p_job_id: jobId, p_diag: diag }, { signal: ac.signal });
  try {
    const saved = await raceTimeout(pending, DIAG_SAVE_MS, () => ac.abort());
    const row = saved && typeof saved === 'object' && !Array.isArray(saved) ? saved as { saved?: unknown } : {};
    return row.saved === true ? 'saved' : 'failed';
  } catch {
    return 'failed';
  }
}
