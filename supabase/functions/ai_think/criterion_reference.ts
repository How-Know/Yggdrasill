// 개념 탭 질문에 붙는 "고른 정리 기준의 최신 저장본". 개념 참고와 같이 대화 접근을 확인한 뒤 요청마다
// 사용자 권한으로 다시 읽는다. 확정본과 저장된 초안을 따로 넣고, 앱이 보낸 글은 받지 않는다.
// 원문은 모델 입력에만 넣고 메시지·기억·자료 스냅샷에는 남기지 않는다. SSE·실행 기록에는 상태만 남긴다.
// 설계: docs/architecture/concept-library.md, docs/architecture/ai-think.md §13

import { criterionReferenceNote } from './prompts.ts';

/** status 응답 capabilities.criterion_reference. 앱은 이 값이 없으면(옛 Edge) 기준 참고 전송을 막는다. */
export const CRITERION_REFERENCE_VERSION = 1;
/** 확정본·초안 본문을 각각 이만큼까지 넣는다. */
export const CRITERION_TEXT_MAX_CHARS = 8000;
/** 이 기준에 이은 개념 이름은 이만큼만 넣는다. 저장소는 하나 더 읽어 더 있는지 알린다. */
export const CRITERION_LINK_LIMIT = 30;
export const CRITERION_REFERENCE_COLUMNS =
  'id,title,body,version,confirmed_at,draft_title,draft_body,draft_origin,draft_saved_at,updated_at';

export interface CriterionRecord {
  id: string;
  /** 확정본. 확정한 적 없으면 title·body는 null, version 0. */
  title: string | null;
  body: string | null;
  version: number;
  confirmed_at: string | null;
  /** 저장된 초안(논의 중인 변경). 없으면 null. */
  draft_title: string | null;
  draft_body: string | null;
  /** 'owner' | 'template' */
  draft_origin: string | null;
  draft_saved_at: string | null;
}

export interface CriterionLinkedConcept {
  id: string;
  name: string | null;
}

export interface CriterionReferenceRead {
  criterion: CriterionRecord | null;
  /** null(또는 없음) = 연결을 읽지 못했다. 빈 배열 = 연결이 없다. */
  linkedConcepts?: CriterionLinkedConcept[] | null;
}

export type CriterionReferenceStatus = 'ok' | 'truncated' | 'not_found' | 'error';

/** SSE(conversation.context.criterion)와 ai_runs.features.criterion_ref에 남는 상태. 제목·본문은 없다. */
export interface CriterionReferenceMeta {
  id: string;
  status: CriterionReferenceStatus;
  version: number | null;
  confirmed_at: string | null;
  has_draft: boolean | null;
  draft_saved_at: string | null;
  linked_concepts: number | null;
}

export interface CriterionReference {
  status: CriterionReferenceStatus;
  note: string;
  meta: CriterionReferenceMeta;
}

function clipText(text: string | null): { text: string | null; chars: number; cut: boolean } {
  if (text == null) return { text: null, chars: 0, cut: false };
  const cut = text.length > CRITERION_TEXT_MAX_CHARS;
  return { text: cut ? text.slice(0, CRITERION_TEXT_MAX_CHARS) : text, chars: text.length, cut };
}

export async function loadCriterionReference(
  read: ((criterionId: string) => Promise<CriterionReferenceRead>) | null,
  criterionId: string,
): Promise<CriterionReference> {
  const failed = (status: 'not_found' | 'error'): CriterionReference => ({
    status,
    note: criterionReferenceNote({ id: criterionId, status, maxChars: CRITERION_TEXT_MAX_CHARS, linkLimit: CRITERION_LINK_LIMIT }),
    meta: {
      id: criterionId,
      status,
      version: null,
      confirmed_at: null,
      has_draft: null,
      draft_saved_at: null,
      linked_concepts: null,
    },
  });
  if (!read) return failed('error');
  let got: CriterionReferenceRead;
  try {
    got = await read(criterionId);
  } catch (e) {
    console.error('[ai_think] criterion reference failed:', e instanceof Error ? e.message : String(e));
    return failed('error');
  }
  const c = got.criterion;
  if (!c) return failed('not_found');
  const confirmed = clipText(c.version > 0 ? c.body ?? '' : null);
  const draft = clipText(c.draft_title != null ? c.draft_body ?? '' : null);
  const status: CriterionReferenceStatus = confirmed.cut || draft.cut ? 'truncated' : 'ok';
  const links = Array.isArray(got.linkedConcepts)
    ? { rows: got.linkedConcepts.slice(0, CRITERION_LINK_LIMIT), more: got.linkedConcepts.length > CRITERION_LINK_LIMIT }
    : { rows: null, more: false };
  return {
    status,
    note: criterionReferenceNote({
      id: c.id,
      status,
      title: c.version > 0 ? c.title : null,
      version: c.version,
      confirmedAt: c.confirmed_at,
      body: confirmed.text,
      bodyChars: confirmed.chars,
      bodyCut: confirmed.cut,
      draftTitle: c.draft_title,
      draftBody: draft.text,
      draftChars: draft.chars,
      draftCut: draft.cut,
      draftOrigin: c.draft_origin,
      draftSavedAt: c.draft_saved_at,
      linkedConcepts: links.rows,
      linkedConceptsMore: links.more,
      maxChars: CRITERION_TEXT_MAX_CHARS,
      linkLimit: CRITERION_LINK_LIMIT,
    }),
    meta: {
      id: c.id,
      status,
      version: c.version,
      confirmed_at: c.confirmed_at,
      has_draft: c.draft_title != null,
      draft_saved_at: c.draft_saved_at,
      linked_concepts: links.rows ? links.rows.length : null,
    },
  };
}
