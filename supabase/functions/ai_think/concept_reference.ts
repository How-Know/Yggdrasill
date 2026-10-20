// 개념 탭 질문에 붙는 "고른 개념의 최신 저장본". 대화 접근을 확인한 뒤 요청마다 사용자 권한으로 다시 읽는다.
// 원문은 모델 입력에만 넣고 메시지·기억·자료 스냅샷에는 남기지 않는다. SSE·실행 기록에는 상태만 남긴다.
// 설계: docs/architecture/ai-think.md §13 개념 탭 대화

import {
  conceptReferenceNote,
  type ConceptCoreText,
  type ConceptSelectedStatementView,
  type ConceptStatementText,
} from './prompts.ts';

/**
 * status 응답 capabilities.concept_reference. 앱은 이 값이 없으면(옛 Edge) 개념 참고 전송을 막는다.
 * 2: 사용자가 이은 정리 기준(제목·상태)과 교재 출처 목록을 함께 읽는다.
 * 3: 고른 서술(statement_id)의 확정본·저장된 초안, 공통 내용, 서술 목록(제목·상태), 교육과정 등장 위치를 함께 읽는다.
 *    앱은 기본 서술이 아닌 서술을 고르면 3 이상일 때만 보낸다.
 */
export const CONCEPT_REFERENCE_VERSION = 3;
export const CONCEPT_REFERENCE_MAX_CHARS = 12000;
/** 분류 경로를 이보다 깊게 따라가지 않는다(순환·끊긴 부모 대비). */
export const CONCEPT_PATH_MAX_DEPTH = 12;
/** 이은 기준·출처·서술 목록·등장 위치는 이만큼만 넣는다. 저장소는 하나 더 읽어 더 있는지 알린다. */
export const CONCEPT_LINK_LIMIT = 30;
/** 서술은 고른 것을 목록에서 찾아야 해서 넉넉히 읽는다. 이보다 많으면 못 찾은 서술은 "읽지 못함"이다. */
export const CONCEPT_STATEMENT_READ_LIMIT = 100;
/** 0072 concepts 열만 읽는다. 뒤 마이그레이션 열(symbol, family_id 등)은 쓰지 않는다. */
export const CONCEPT_REFERENCE_COLUMNS = 'id,kind,sub_type,name,content,level,main_category_id,updated_at';

export interface ConceptRecord {
  id: string;
  kind: string;
  sub_type: string | null;
  name: string;
  content: string;
  level: number | null;
  main_category_id: string | null;
  updated_at: string | null;
}

/** 사용자가 이 개념에 이은 정리 기준. 본문은 읽지 않는다. */
export interface ConceptLinkedCriterion {
  id: string;
  /** 확정본 제목. 확정한 적 없으면 null. */
  title: string | null;
  version: number;
  /** 저장된 초안 제목. 초안이 없으면 null. */
  draft_title: string | null;
}

/** 사용자가 이 개념에 이은 교재 쪽. 책 이름을 볼 수 없으면 book_name=null. */
export interface ConceptSourceRecord {
  book_name: string | null;
  grade_label: string;
  raw_page: number;
  display_page: number | null;
  unit_path: string[];
  /** 이 쪽이 붙은 서술. null(또는 없음) = 기본 서술(개념 본문). */
  statement_id?: string | null;
}

/** concept_statements 한 줄. content·draft는 DB가 정리한 jsonb 그대로다. */
export interface ConceptStatementRecord {
  id: string;
  role: 'core' | 'statement';
  version: number;
  content: Record<string, unknown> | null;
  confirmed_at: string | null;
  draft: Record<string, unknown> | null;
  draft_origin: string | null;
  draft_saved_at: string | null;
}

/** 사용자가 넣은 교육과정 등장 위치. curriculum_code=null = 교육과정 판 미기록. */
export interface ConceptAppearanceRecord {
  statement_id: string | null;
  curriculum_code: string | null;
  school_level: string;
  course_label: string;
  unit_path: string[];
  note: string | null;
}

/** 저장소 조회 결과. 개념이 없거나 볼 수 없으면 concept=null. 경로는 최상위부터, 끊기면 읽은 데까지. */
export interface ConceptReferenceRead {
  concept: ConceptRecord | null;
  categoryPath: string[];
  pathComplete: boolean;
  /** null(또는 없음) = 연결을 읽지 못했다. 빈 배열 = 연결이 없다. */
  linkedCriteria?: ConceptLinkedCriterion[] | null;
  sources?: ConceptSourceRecord[] | null;
  /** 공통 내용·서술(정렬된 순서). null(또는 없음) = 읽지 못했다. */
  statements?: ConceptStatementRecord[] | null;
  appearances?: ConceptAppearanceRecord[] | null;
}

export type ConceptReferenceStatus = 'ok' | 'truncated' | 'not_found' | 'error';

/** base = 기본 서술(개념 본문)을 골랐다. unread = 서술을 읽지 못해 고른 서술을 확인하지 못했다. */
export type ConceptStatementReadStatus = 'base' | 'ok' | 'truncated' | 'not_found' | 'unread';

/** SSE·실행 기록에 남는 고른 서술 상태. 제목·본문은 없다. */
export interface ConceptStatementMeta {
  id: string | null;
  status: ConceptStatementReadStatus;
  version: number | null;
  confirmed_at: string | null;
  has_draft: boolean | null;
  draft_saved_at: string | null;
}

/** SSE(conversation.context.concept)와 ai_runs.features.concept_ref에 남는 상태. 본문·이름은 없다. */
export interface ConceptReferenceMeta {
  id: string;
  status: ConceptReferenceStatus;
  updated_at: string | null;
  content_chars: number | null;
  delivered_chars: number | null;
  path_complete: boolean | null;
  /** 넣은 연결 기준·출처 수. null = 읽지 못함. */
  linked_criteria: number | null;
  sources: number | null;
  /** 기본 서술 말고 더 있는 서술 수, 등장 위치 수, 공통 내용 유무. null = 읽지 못함. */
  statements: number | null;
  appearances: number | null;
  has_core: boolean | null;
  statement: ConceptStatementMeta;
}

export interface ConceptReference {
  status: ConceptReferenceStatus;
  /** 모델 입력에 넣는 참고 블록. 실패해도 "읽지 못했다"는 블록이 들어간다. */
  note: string;
  meta: ConceptReferenceMeta;
}

function capped<T>(rows: T[] | null | undefined): { rows: T[] | null; more: boolean } {
  if (!Array.isArray(rows)) return { rows: null, more: false };
  return { rows: rows.slice(0, CONCEPT_LINK_LIMIT), more: rows.length > CONCEPT_LINK_LIMIT };
}

const text = (v: unknown): string | null => (typeof v === 'string' && v.trim() !== '' ? v : null);

function statementText(raw: Record<string, unknown> | null): { text: ConceptStatementText | null; chars: number; cut: boolean } {
  if (!raw) return { text: null, chars: 0, cut: false };
  const body = typeof raw.body === 'string' ? raw.body : '';
  const cut = body.length > CONCEPT_REFERENCE_MAX_CHARS;
  return {
    text: {
      title: text(raw.title) ?? '',
      body: cut ? body.slice(0, CONCEPT_REFERENCE_MAX_CHARS) : body,
      approach: text(raw.approach),
      conditions: text(raw.conditions),
      conditionsInSource: text(raw.conditions_in_source),
      terms: Array.isArray(raw.terms) ? raw.terms.filter((t): t is string => typeof t === 'string') : [],
      basis: raw.basis === 'verbatim' ? 'verbatim' : 'organized',
      quote: text(raw.quote),
      supplementNote: text(raw.supplement_note),
      unverifiedNote: text(raw.unverified_note),
    },
    chars: body.length,
    cut,
  };
}

function coreText(raw: Record<string, unknown> | null): ConceptCoreText | null {
  if (!raw) return null;
  return { meaning: text(raw.meaning) ?? '', scope: text(raw.scope), conditions: text(raw.conditions) };
}

export async function loadConceptReference(
  read: ((conceptId: string) => Promise<ConceptReferenceRead>) | null,
  conceptId: string,
  /** 개념 상세에서 고른 서술. null = 기본 서술(개념 본문). */
  statementId: string | null = null,
): Promise<ConceptReference> {
  const unknownStatement: ConceptStatementMeta = {
    id: statementId,
    status: statementId ? 'unread' : 'base',
    version: null,
    confirmed_at: null,
    has_draft: null,
    draft_saved_at: null,
  };
  const failed = (status: 'not_found' | 'error'): ConceptReference => ({
    status,
    note: conceptReferenceNote({
      id: conceptId,
      status,
      statementId,
      maxChars: CONCEPT_REFERENCE_MAX_CHARS,
      linkLimit: CONCEPT_LINK_LIMIT,
    }),
    meta: {
      id: conceptId,
      status,
      updated_at: null,
      content_chars: null,
      delivered_chars: null,
      path_complete: null,
      linked_criteria: null,
      sources: null,
      statements: null,
      appearances: null,
      has_core: null,
      statement: unknownStatement,
    },
  });
  if (!read) return failed('error');
  let got: ConceptReferenceRead;
  try {
    got = await read(conceptId);
  } catch (e) {
    console.error('[ai_think] concept reference failed:', e instanceof Error ? e.message : String(e));
    return failed('error');
  }
  const c = got.concept;
  if (!c) return failed('not_found');
  const content = c.content ?? '';
  const truncated = content.length > CONCEPT_REFERENCE_MAX_CHARS;
  const body = truncated ? content.slice(0, CONCEPT_REFERENCE_MAX_CHARS) : content;
  const status: ConceptReferenceStatus = truncated ? 'truncated' : 'ok';
  const links = capped(got.linkedCriteria);

  const rows = Array.isArray(got.statements) ? got.statements : null;
  const coreRow = rows?.find((r) => r.role === 'core') ?? null;
  const listRows = rows ? rows.filter((r) => r.role === 'statement') : null;
  const indexOf = new Map((listRows ?? []).map((r, i) => [r.id, i + 1]));
  const titleOf = (r: ConceptStatementRecord) => text(r.content?.title) ?? text(r.draft?.title) ?? '(제목 없음)';
  const labelOf = (id: string | null | undefined): string => {
    if (!id) return '기본 서술';
    const i = indexOf.get(id);
    return i == null ? '서술(목록에서 찾지 못함)' : `서술 ${i} "${titleOf(listRows![i - 1])}"`;
  };
  const list = capped(listRows);

  let selected: ConceptSelectedStatementView;
  let statementMeta: ConceptStatementMeta;
  const row = statementId ? listRows?.find((r) => r.id === statementId) ?? null : null;
  if (!statementId) {
    selected = { id: null, status: 'base' };
    statementMeta = unknownStatement;
  } else if (!row) {
    const unsure = rows == null || rows.length >= CONCEPT_STATEMENT_READ_LIMIT;
    const st = unsure ? 'unread' : 'not_found';
    selected = { id: statementId, status: st };
    statementMeta = { ...unknownStatement, status: st };
  } else {
    const confirmed = statementText(row.content);
    const draft = statementText(row.draft);
    const st = confirmed.cut || draft.cut ? 'truncated' : 'ok';
    selected = {
      id: row.id,
      status: st,
      index: indexOf.get(row.id),
      version: row.version,
      confirmedAt: row.confirmed_at,
      content: confirmed.text,
      contentChars: confirmed.chars,
      contentCut: confirmed.cut,
      draft: draft.text,
      draftChars: draft.chars,
      draftCut: draft.cut,
      draftOrigin: row.draft_origin,
      draftSavedAt: row.draft_saved_at,
    };
    statementMeta = {
      id: row.id,
      status: st,
      version: row.version,
      confirmed_at: row.confirmed_at,
      has_draft: row.draft != null,
      draft_saved_at: row.draft_saved_at,
    };
  }

  const sources = capped(got.sources);
  const appearances = capped(got.appearances);
  return {
    status,
    note: conceptReferenceNote({
      id: c.id,
      status,
      name: c.name,
      kind: c.kind,
      subType: c.sub_type,
      level: c.level,
      categoryPath: got.categoryPath,
      pathComplete: got.pathComplete,
      updatedAt: c.updated_at,
      body,
      contentChars: content.length,
      maxChars: CONCEPT_REFERENCE_MAX_CHARS,
      linkedCriteria: links.rows,
      linkedCriteriaMore: links.more,
      sources: sources.rows ? sources.rows.map((s) => ({ ...s, statementLabel: labelOf(s.statement_id) })) : null,
      sourcesMore: sources.more,
      statementsRead: rows != null,
      core: coreRow
        ? {
          version: coreRow.version,
          confirmedAt: coreRow.confirmed_at,
          content: coreText(coreRow.content),
          draft: coreText(coreRow.draft),
          draftSavedAt: coreRow.draft_saved_at,
        }
        : null,
      statementList: list.rows
        ? list.rows.map((r) => ({
          id: r.id,
          title: titleOf(r),
          version: r.version,
          hasDraft: r.draft != null,
          basis: (r.content ?? r.draft)?.basis === 'verbatim' ? 'verbatim' : 'organized',
        }))
        : [],
      statementListMore: list.more,
      selected,
      appearances: appearances.rows
        ? appearances.rows.map((a) => ({ ...a, statementLabel: labelOf(a.statement_id) }))
        : null,
      appearancesMore: appearances.more,
      linkLimit: CONCEPT_LINK_LIMIT,
    }),
    meta: {
      id: c.id,
      status,
      updated_at: c.updated_at,
      content_chars: content.length,
      delivered_chars: body.length,
      path_complete: got.pathComplete,
      linked_criteria: links.rows ? links.rows.length : null,
      sources: sources.rows ? sources.rows.length : null,
      statements: listRows ? listRows.length : null,
      appearances: appearances.rows ? appearances.rows.length : null,
      has_core: rows ? coreRow != null : null,
      statement: statementMeta,
    },
  };
}
