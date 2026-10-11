// 커서 질문 1건 처리: 접수(한도·자격, ai_relay_reserve) → Think 답(조회 도구만) → 마감(ai_relay_finish).
// ai_think_relay(운영자 PC의 Cursor 작업창)와 ai_code_bridge ask_think(코드 작업자)가 함께 쓴다.
// 설계: docs/architecture/ai-think.md §12

import type { BudgetStatus } from '../_shared/ai/budget.ts';
import type { EnvReader } from '../_shared/ai/config.ts';
import type { AiProvider } from '../_shared/ai/types.ts';
import type { AiRunRecord } from '../_shared/ai/usage.ts';
import { runThinkChat, type ThinkStore } from './chat.ts';
import type { RelayAsker, RelayBasis } from './relay_verdict.ts';
import type { RelayReservation, RelayReserveInput } from './store.ts';
import { MAX_MESSAGE_CHARS } from './validate.ts';

export const RELAY_DEFAULT_DAILY_LIMIT = 60;
/** 작업자가 조사·조율 한 번(회차)에 물을 수 있는 수. 운영자 결정(2026-10-10). */
export const RELAY_RUN_LIMIT = 3;
export const RELAY_MAX_QUESTION_CHARS = Math.min(MAX_MESSAGE_CHARS, 8000);

export interface RelayStore extends ThinkStore {
  reserveRelay(input: RelayReserveInput): Promise<RelayReservation>;
  finishRelay(
    id: string,
    status: 'answered' | 'needs_owner' | 'error',
    conversationId: string | null,
    runId: string | null,
    error: string | null,
  ): Promise<void>;
}

export interface RelayAskDeps {
  provider: AiProvider | null;
  store: RelayStore;
  recordRun: (rec: AiRunRecord) => Promise<string | null>;
  budget: () => Promise<BudgetStatus | null>;
  safetyId: string;
  env?: EnvReader;
  now?: () => number;
}

export interface RelayAskInput {
  asker: RelayAsker;
  question: string;
  conversationId: string | null;
  workerId?: string | null;
  requestId?: string | null;
  dailyLimit: number;
  wallClockMs: number;
  signal?: AbortSignal;
}

export type RelayAskResult =
  | {
    ok: true;
    ask_id: string;
    conversation_id: string;
    verdict: 'answered' | 'needs_owner';
    answer: string;
    basis: RelayBasis[];
    owner_questions: string[];
    downgraded: string | null;
  }
  | { ok: false; status: number; error: string; message: string; conversation_id?: string | null };

const RESERVE_ERRORS: [RegExp, number, string, string][] = [
  [/relay_daily_limit/, 429, 'relay_daily_limit', '오늘 커서 질문 한도를 다 썼습니다.'],
  [/relay_run_limit/, 429, 'relay_run_limit', `이번 조사·조율에서 물을 수 있는 ${RELAY_RUN_LIMIT}번을 다 썼습니다. 남은 의문은 결과의 questions_for_think에 적으세요.`],
  [/relay_conversation_not_cursor/, 403, 'relay_conversation_not_cursor', '커서는 커서가 시작한 대화에만 이어 물을 수 있습니다.'],
  [/relay_conversation_not_found/, 404, 'relay_conversation_not_found', '이어 물을 대화를 찾지 못했습니다.'],
  [/relay_request_not_found/, 404, 'relay_request_not_found', '코드 요청을 찾지 못했습니다.'],
  [/relay_request_not_running/, 409, 'relay_request_not_running', '이 작업자가 지금 돌리는 요청이 아닙니다.'],
  [/relay_request_required/, 400, 'relay_request_required', '작업자 질문에는 요청 id가 필요합니다.'],
  [/relay_mode_not_allowed/, 403, 'relay_mode_not_allowed', 'Think에게 묻기는 조사·조율 실행에서만 쓸 수 있습니다.'],
  [/Could not find the function|PGRST202|function public\.ai_relay_reserve.* does not exist/i, 503, 'db_required', 'DB에 커서 연결 마이그레이션(20261010100000_ai_think_relay.sql)이 아직 없습니다.'],
];

function reserveFailure(e: unknown): RelayAskResult {
  const message = e instanceof Error ? e.message : String(e);
  for (const [re, status, error, text] of RESERVE_ERRORS) {
    if (re.test(message)) return { ok: false, status, error, message: text };
  }
  console.error('[relay] reserve failed:', message);
  return { ok: false, status: 500, error: 'internal_error', message: '질문을 접수하지 못했습니다.' };
}

export async function runRelayAsk(deps: RelayAskDeps, input: RelayAskInput): Promise<RelayAskResult> {
  const question = input.question.trim();
  if (!question) return { ok: false, status: 400, error: 'question_required', message: '질문이 비었습니다.' };
  if (question.length > RELAY_MAX_QUESTION_CHARS) {
    return { ok: false, status: 400, error: 'question_too_long', message: `질문은 ${RELAY_MAX_QUESTION_CHARS}자 이하여야 합니다.` };
  }
  if (!deps.provider) return { ok: false, status: 503, error: 'ai_not_configured', message: 'OPENAI_API_KEY 비밀값이 설정되지 않았습니다.' };
  const budget = await deps.budget().catch(() => null);
  if (budget?.exceeded && budget.mode === 'block') {
    return { ok: false, status: 429, error: 'budget_exceeded', message: '이번 달 AI 한도를 넘었습니다.' };
  }

  let reservation: RelayReservation;
  try {
    reservation = await deps.store.reserveRelay({
      asker: input.asker,
      conversationId: input.conversationId,
      workerId: input.workerId ?? null,
      requestId: input.requestId ?? null,
      dailyLimit: input.dailyLimit,
      runLimit: RELAY_RUN_LIMIT,
    });
  } catch (e) {
    return reserveFailure(e);
  }

  const now = deps.now ?? Date.now;
  const startedAt = now();
  const signal = input.signal ?? AbortSignal.timeout(input.wallClockMs);
  const title = input.asker === 'cursor_worker' && reservation.request_title ? `작업자 문의: ${reservation.request_title}` : null;

  let outcome;
  try {
    outcome = await runThinkChat(
      {
        userId: '',
        safetyId: deps.safetyId,
        conversationId: reservation.conversation_id,
        message: question,
        attachments: [],
        deep: false,
        webSearch: false,
        signal,
        startedAt,
        wallClockMs: input.wallClockMs,
        features: null,
        relay: { asker: input.asker, title },
      },
      { provider: deps.provider, store: deps.store, recordRun: deps.recordRun, emit: () => {}, env: deps.env, now: deps.now },
    );
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error('[relay] chat failed:', message);
    await deps.store.finishRelay(reservation.id, 'error', null, null, message).catch(() => {});
    return { ok: false, status: 500, error: 'internal_error', message: 'Think가 답을 만들지 못했습니다.' };
  }

  const verdict = outcome.relay ?? null;
  const finalStatus = outcome.status === 'complete' && verdict ? verdict.verdict : 'error';
  await deps.store
    .finishRelay(reservation.id, finalStatus, outcome.conversationId, outcome.runId, finalStatus === 'error' ? (outcome.errorMessage ?? outcome.errorCode ?? 'error') : null)
    .catch((e) => console.error('[relay] finish failed:', e instanceof Error ? e.message : String(e)));

  if (!verdict || outcome.status !== 'complete' || !outcome.conversationId) {
    return {
      ok: false,
      status: outcome.errorCode === 'timeout' ? 504 : 502,
      error: outcome.errorCode ?? 'think_error',
      message: outcome.errorMessage ?? 'Think가 답을 만들지 못했습니다.',
      conversation_id: outcome.conversationId,
    };
  }
  return {
    ok: true,
    ask_id: reservation.id,
    conversation_id: outcome.conversationId,
    verdict: verdict.verdict,
    answer: outcome.content ?? '',
    basis: verdict.basis,
    owner_questions: verdict.owner_questions,
    downgraded: verdict.downgraded ?? null,
  };
}
