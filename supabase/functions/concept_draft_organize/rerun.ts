// 승인한 "다시 정리" 카드(ai_actions.kind='concept_draft_rerun')와 지금 초안 행으로 새 초안을 만들 요청을 꾸린다.
// 책·학년·단원·쪽은 지금 초안 저장값 그대로, 기준은 카드에 담긴 것만 쓴다(앱이 보낸 값은 받지 않는다).

import { isUuid } from '../_shared/concept_book.ts';

type Row = Record<string, unknown>;

export type RerunRefusal = { ok: false; status: number; error: string };
export type RerunHead = { ok: true; draftId: string } | RerunRefusal;
export type RerunPlan = { ok: true; draftId: string; body: Row } | RerunRefusal;

/** 카드를 읽은 뒤: 종류·상태·초안 id를 확인한다. */
export function rerunDraftId(action: Row | null): RerunHead {
  if (!action) return { ok: false, status: 404, error: 'action_not_found' };
  if (action.kind !== 'concept_draft_rerun') return { ok: false, status: 400, error: 'action_kind_invalid' };
  if (action.status !== 'proposed') return { ok: false, status: 409, error: 'action_not_pending' };
  const payload = (action.payload ?? {}) as Row;
  if (!isUuid(payload.draft_id)) return { ok: false, status: 400, error: 'invalid_draft' };
  return { ok: true, draftId: String(payload.draft_id) };
}

/** 지금 초안을 읽은 뒤: 열린 초안이면 create 요청 본문을 만든다. */
export function rerunPlan(action: Row, draft: Row | null): RerunPlan {
  const head = rerunDraftId(action);
  if (!head.ok) return head;
  if (!draft) return { ok: false, status: 404, error: 'draft_not_found' };
  if (String(draft.id) !== head.draftId) return { ok: false, status: 400, error: 'invalid_draft' };
  if (draft.status !== 'open') return { ok: false, status: 409, error: 'draft_closed' };
  const payload = (action.payload ?? {}) as Row;
  return {
    ok: true,
    draftId: head.draftId,
    body: {
      academy_id: draft.academy_id,
      book_id: draft.book_id,
      grade_label: draft.grade_label,
      unit_path: Array.isArray(draft.unit_path) ? draft.unit_path : [],
      pages: Array.isArray(draft.pages) ? draft.pages : [],
      criterion_ids: Array.isArray(payload.criterion_ids) ? payload.criterion_ids.filter(isUuid) : [],
    },
  };
}

/** 마무리 RPC 오류 메시지에서 앱에 돌려줄 코드. */
export function rerunFinishCode(message: string): string {
  return /action_not_found|action_not_pending|concept_draft_closed|concept_draft_not_found|forbidden/.exec(message)?.[0] ?? 'rerun_finish_failed';
}
