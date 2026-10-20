// 백그라운드 정리 작업(concept_draft_jobs). 시작할 때 서버가 읽은 입력을 작업에 두고, 결과를 받을 때 그 값으로 검사한다.
// 여기에는 DB·공급자 없이 정할 수 있는 판단만 둔다. 흐름은 index.ts 의 startOrganize·collect.

import type { AiBackgroundPoll } from '../_shared/ai/types.ts';
import type { ConceptTypeRef, PreparedUnit } from './organize.ts';
import { type ConceptDraftOutcome, conceptDraftOutcome } from './run.ts';

/** 이보다 오래 끝나지 않은 작업은 취소하고 실패로 둔다. */
export const JOB_MAX_MS = 20 * 60_000;
/** 결과를 저장하던 요청이 이만큼 소식이 없으면 다른 요청이 이어받는다. */
export const SAVING_STALE_MS = 2 * 60_000;
/** 한 사람이 동시에 돌릴 수 있는 정리 작업 수. */
export const MAX_ACTIVE_JOBS = 3;
/** 앱이 다음에 물어볼 때까지 기다릴 시간(안내값). */
export const POLL_AFTER_MS = 5_000;

export interface JobRow {
  id: string;
  academy_id: string;
  book_id: string;
  grade_label: string;
  book_name: string;
  unit_path: string[];
  pages: number[];
  page_meta: { raw_page: number; display_page: number | null }[];
  criteria: Record<string, unknown>[];
  concept_types: ConceptTypeRef[];
  prepared: PreparedUnit;
  model: string;
  effort: string;
  response_id: string;
  rerun_action_id: string | null;
  rerun_of: string | null;
  status: 'running' | 'saving' | 'done' | 'failed';
  draft_id: string | null;
  error: string | null;
  created_by: string | null;
  created_at: string;
  updated_at: string;
}

export type CollectStep = 'done' | 'failed' | 'wait' | 'poll';

/** 작업 상태만 보고 정한다. poll 이면 공급자에게 결과를 물어본다. */
export function collectStep(job: Pick<JobRow, 'status' | 'updated_at'>, now: number): CollectStep {
  if (job.status === 'done') return 'done';
  if (job.status === 'failed') return 'failed';
  if (job.status === 'saving' && now - Date.parse(job.updated_at) < SAVING_STALE_MS) return 'wait';
  return 'poll';
}

export type PollStep = 'running' | 'timeout' | 'finish';

export function pollStep(poll: AiBackgroundPoll, ageMs: number): PollStep {
  if (poll.state !== 'running') return 'finish';
  return ageMs > JOB_MAX_MS ? 'timeout' : 'running';
}

/** 끝난 결과를 바로 부른 정리와 같은 길로 읽는다. */
export function jobOutcome(poll: Exclude<AiBackgroundPoll, { state: 'running' }>, job: Pick<JobRow, 'prepared' | 'concept_types'>): ConceptDraftOutcome {
  if (poll.state === 'failed') return { result: null, draft: null, checks: null, error: poll.error };
  return conceptDraftOutcome(poll.result, { prepared: job.prepared, types: job.concept_types });
}

export function jobAgeMs(job: Pick<JobRow, 'created_at'>, now: number): number {
  const t = Date.parse(job.created_at);
  return Number.isFinite(t) ? Math.max(0, now - t) : 0;
}
