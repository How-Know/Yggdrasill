// 작업자가 올린 수정 결과의 자동 검사 기록(result.verification) 해석과 필수 검사 판정.
// Think 검토(ai_code_bridge/code_review.ts)와 결과 조회(ai_think get_code_request, ai_think_relay)가 같은 규칙을 쓴다.
// 판정은 작업자 실행 기록으로만 정한다. 모델 글은 근거가 아니다.
// 설계: docs/architecture/ai-code-bridge.md "자동 검사"

export interface VerificationItem {
  id: string;
  label: string;
  status: 'passed' | 'failed' | 'skipped' | 'preexisting';
  reason: string | null;
  command: string | null;
  output: string | null;
  cwd: string | null;
  exit_code: number | null;
  duration_ms: number | null;
  /** required: 이번 수정에 꼭 필요한 검사. followup: 실제 데이터·운영 DB가 있어야 하는 후속 확인. */
  scope: 'required' | 'followup';
  /** request: 요청(조율본 checks)에 적힌 검사. auto: 바뀐 경로로 작업자가 정한 검사. */
  source: 'auto' | 'request';
  /** 미실행 이유가 이 PC 환경(도구·의존성 없음)이면 true. 코드를 다시 고쳐도 풀리지 않는다. */
  env: boolean;
}

/**
 * 필수 검사 판정.
 * passed: 필수 검사가 모두 통과(원래도 실패 포함), failed: 이번 수정 때문에 실패한 필수 검사가 있음,
 * not_run: 돌리지 못한 필수 검사가 있음(통과가 아니다), none: 필수 검사 대상이 없음(문서·규칙만 바뀜).
 */
export type CheckVerdict = 'passed' | 'failed' | 'not_run' | 'none';

export interface Verification {
  summary: { passed: number; failed: number; skipped: number; preexisting: number };
  items: VerificationItem[];
  note: string | null;
  stopped: boolean;
  verdict: CheckVerdict;
  /** 검사한 diff의 sha256(작업자 기록). 예전 작업자면 null. */
  patch_sha256: string | null;
  duration_ms: number | null;
}

export const VERDICT_LABELS: Record<CheckVerdict, string> = {
  passed: '필수 검사 통과',
  failed: '필수 검사 실패',
  not_run: '필수 검사 일부 실행 못 함',
  none: '필수 검사 대상 없음',
};

/** 판정 문구. 원래도 실패하던 필수 검사는 이번 수정을 확인하지 못했으므로 통과 문구에 따로 밝힌다. */
export function verdictLabel(v: Pick<Verification, 'verdict' | 'items'>): string {
  const old = v.items.filter((i) => i.scope === 'required' && i.status === 'preexisting').length;
  return v.verdict === 'passed' && old > 0 ? `${VERDICT_LABELS.passed} (원래도 실패하던 검사 ${old}개 제외)` : VERDICT_LABELS[v.verdict];
}

export const STATUS_LABELS: Record<VerificationItem['status'], string> = {
  passed: '통과',
  failed: '실패',
  skipped: '미실행',
  preexisting: '원래도 실패',
};

const isObj = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);
const str = (v: unknown, max: number): string => (typeof v === 'string' ? v.trim().slice(0, max) : '');
const num = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? v : null);

/** 예전 작업자 기록(scope 없음)은 'db-test-other'만 후속 확인으로 보고 나머지는 필수로 본다. */
function itemScope(i: Record<string, unknown>): VerificationItem['scope'] {
  if (i.scope === 'followup' || i.scope === 'required') return i.scope;
  return i.id === 'db-test-other' ? 'followup' : 'required';
}

export function checkVerdict(items: VerificationItem[], stopped = false): CheckVerdict {
  const required = items.filter((i) => i.scope === 'required');
  if (required.some((i) => i.status === 'failed')) return 'failed';
  if (stopped || required.some((i) => i.status === 'skipped')) return 'not_run';
  return required.length > 0 ? 'passed' : 'none';
}

/** 작업자가 올린 result.verification. 모양이 다르면 null(검사 기록 없음). 판정은 항목에서 다시 계산한다. */
export function verificationOf(result: Record<string, unknown> | null): Verification | null {
  const v = result?.verification;
  if (!isObj(v) || !Array.isArray(v.items)) return null;
  const items: VerificationItem[] = v.items.filter(isObj).map((i) => ({
    id: str(i.id, 200),
    label: str(i.label, 300) || str(i.id, 200),
    status: (['passed', 'failed', 'skipped', 'preexisting'] as const).find((s) => s === i.status) ?? 'skipped',
    reason: str(i.reason, 1000) || null,
    command: str(i.command, 1000) || null,
    output: typeof i.output === 'string' ? i.output : null,
    cwd: str(i.cwd, 300) || null,
    exit_code: num(i.exit_code),
    duration_ms: num(i.duration_ms),
    scope: itemScope(i),
    source: i.source === 'request' ? 'request' : 'auto',
    env: i.env === true,
  }));
  const summary = { passed: 0, failed: 0, skipped: 0, preexisting: 0 };
  for (const i of items) summary[i.status] += 1;
  const stopped = v.stopped === true;
  const sha = str(v.patch_sha256, 64);
  return {
    summary,
    items,
    note: str(v.note, 500) || null,
    stopped,
    verdict: checkVerdict(items, stopped),
    patch_sha256: /^[0-9a-f]{64}$/.test(sha) ? sha : null,
    duration_ms: num(v.duration_ms),
  };
}
