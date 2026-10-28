// Think 대화에서 AI가 부를 수 있는 도구. 정해진 조회만 한다(임의 SQL 없음).
// 쓰기처럼 보이는 propose_* 도구(actions.ts)도 제안 1행만 남기고, 실행은 사용자 승인 RPC가 한다.

import { extractSearchTerms } from '../_shared/ai/search_terms.ts';
import type { AiFunctionTool, AiToolImage } from '../_shared/ai/types.ts';
import {
  ACTION_TOOLS,
  ACTION_TOOL_LABELS,
  ACTION_TOOL_NAMES,
  HANDOVER_TOOL_NAME,
  MEMORY_TOOL_NAMES,
  SPLIT_TOOL_NAME,
  dispatchActionTool,
  type ActionRow,
  type ActionToolContext,
  type ActionToolSource,
} from './actions.ts';
import { canProvideMemoryToAi, legacyVisible, type ConversationAccessState, type MemorySearchScope, scopeMemories, searchScopeFor } from './access_context.ts';
import {
  CONCEPT_DRAFT_TOOL_LABELS,
  CONCEPT_DRAFT_TOOL_NAMES,
  CONCEPT_DRAFT_TOOLS,
  type ConceptDraftToolSource,
  DRAFT_CHANGE_TOOL_NAME,
  dispatchConceptDraftTool,
} from './concept_draft_tools.ts';
import {
  CONCEPT_SOURCE_TOOL_LABELS,
  CONCEPT_SOURCE_TOOL_NAMES,
  CONCEPT_SOURCE_TOOLS,
  type ConceptSourceToolSource,
  dispatchConceptSourceTool,
} from './concept_source_tools.ts';
import { CONSULT_TOOL, CONSULT_TOOL_NAME } from './consult.ts';
import {
  CONCEPT_RELATION_TOOL_NAMES,
  CONCEPT_REVIEW_TOOL_NAMES,
  COURSE_MAP_PROPOSE_TOOL_NAMES,
  COURSE_MAP_TOOL_LABELS,
  COURSE_MAP_TOOL_NAMES,
  COURSE_MAP_TOOLS,
  type CourseMapToolSource,
  dispatchCourseMapTool,
} from './course_map_tools.ts';
import {
  dispatchReviewJobTool,
  REVIEW_JOB_ACTING_TOOL_NAMES,
  REVIEW_JOB_TOOL_LABELS,
  REVIEW_JOB_TOOL_NAMES,
  REVIEW_JOB_TOOLS,
  type ReviewJobToolSource,
} from './concept_review_job_tools.ts';
import { BATCH_TOOL, BATCH_TOOL_LABEL, BATCH_TOOL_NAME } from './concept_review_batch.ts';
import type { MemoryDetail, MemoryRow } from './context.ts';
import {
  CRITERIA_TOOL_NAME,
  dispatchOrganizeTool,
  ORGANIZE_PROPOSE_TOOL_NAMES,
  ORGANIZE_TOOL_LABELS,
  ORGANIZE_TOOL_NAMES,
  ORGANIZE_TOOLS,
  type OrganizeToolSource,
} from './organize.ts';

export interface CurriculumOutlineQuery {
  curriculumName: string | null;
  schoolLevel: '중' | '고' | null;
  depth: 'grade' | 'chapter' | 'section';
}

export interface CurriculumNode {
  name: string;
  children?: CurriculumNode[];
}

export interface ConceptHit {
  id: string;
  name: string;
  kind: string;
  level: number | null;
  category_path: string;
  /** 본문 앞부분. 전체 길이는 content_chars. */
  content: string;
  content_chars: number;
}

export interface ConceptSearchPage {
  /** 검색어에 맞는 전체 개수. 세지 못했으면 null. */
  total: number | null;
  hits: ConceptHit[];
}

export interface ConceptCategory {
  id: string;
  name: string;
  depth: number;
  description: string | null;
  child_count: number;
}

export interface BehaviorCard {
  id: string;
  name: string;
  repeat_days: number;
  is_irregular: boolean;
  level_contents: string[];
}

export interface ThinkToolSource
  extends
    ActionToolSource,
    OrganizeToolSource,
    ConceptDraftToolSource,
    CourseMapToolSource,
    ConceptSourceToolSource,
    ReviewJobToolSource {
  searchMemories(terms: string[], limit: number, scope?: MemorySearchScope): Promise<MemoryRow[]>;
  getMemory(id: string): Promise<MemoryDetail | null>;
  /** 기억 제안이 켜진 요청에서만 쓴다. 없으면 제안 경로의 검색·열람은 실패한다. */
  openMemoryRead?(conversationId: string): Promise<string>;
  searchMemoryLogged?(sessionId: string, query: string, terms: string[], access?: ConversationAccessState | null): Promise<Record<string, unknown>>;
  readMemoryLogged?(sessionId: string, memoryId: string, offset: number, access?: ConversationAccessState | null): Promise<Record<string, unknown>>;
  noteMemoryOutcome?(sessionId: string, kind: 'search' | 'read', status: 'error' | 'timeout', memoryId?: string | null): Promise<void>;
  curriculumOutline(q: CurriculumOutlineQuery): Promise<CurriculumNode[]>;
  searchConcepts(query: string, limit: number, offset: number): Promise<ConceptSearchPage>;
  listConceptCategories(parentId: string | null): Promise<ConceptCategory[]>;
  searchBehaviorCards(query: string | null, limit: number): Promise<BehaviorCard[]>;
}

const nullable = (schema: Record<string, unknown>) => ({ ...schema, type: [schema.type, 'null'] });

export const THINK_TOOLS: AiFunctionTool[] = [
  {
    name: 'search_memories',
    description: '저장된 기억(교육철학, 원칙, 결정, 메모)을 검색한다. 결과는 발췌다. 내용을 비교하려면 get_memory로 원문을 끝까지 읽는다.',
    parameters: {
      type: 'object',
      properties: {
        query: { type: 'string', description: '찾을 내용. 핵심 단어 위주로.' },
        kinds: nullable({
          type: 'array',
          items: { type: 'string', enum: ['identity', 'principle', 'decision', 'note'] },
          description: '종류 제한. 전체면 null.',
        }),
      },
      required: ['query', 'kinds'],
      additionalProperties: false,
    },
  },
  {
    name: 'get_memory',
    description:
      '기억 하나의 원문을 id로 가져온다. 길면 offset으로 이어 읽는다. complete가 true일 때만 그 version의 원문을 끝까지 본 것이다. ' +
      'version_changed면 offset 0부터 다시 읽는다.',
    parameters: {
      type: 'object',
      properties: {
        id: { type: 'string', description: '기억 id (uuid)' },
        offset: nullable({ type: 'integer', description: '이어서 읽을 시작 위치. 처음이면 null.' }),
      },
      required: ['id', 'offset'],
      additionalProperties: false,
    },
  },
  {
    name: 'get_curriculum_outline',
    description: '교육과정 구조(교육과정 > 학년·과목 > 대단원 > 소단원)를 가져온다.',
    parameters: {
      type: 'object',
      properties: {
        curriculum_name: nullable({ type: 'string', description: '예: "2022 개정". 모르면 null (활성 교육과정 전체).' }),
        school_level: { type: ['string', 'null'], enum: ['중', '고', null], description: '중학교/고등학교. 전체면 null.' },
        depth: { type: 'string', enum: ['grade', 'chapter', 'section'], description: '어느 단계까지 펼칠지.' },
      },
      required: ['curriculum_name', 'school_level', 'depth'],
      additionalProperties: false,
    },
  },
  {
    name: 'search_concepts',
    description:
      '개념을 이름·본문에 검색어가 든 것으로 찾는다(이름순). total(전체 개수)과 next_offset으로 이어 본다. ' +
      '본문은 앞부분(excerpt)만 주고 잘렸으면 excerpt_truncated가 true다. 뜻이 같아도 말이 다르면 나오지 않는다. ' +
      '같은 이름(same_name)이나 비슷한 글은 같은 개념 후보일 뿐 같은 개념이라는 근거가 아니다.',
    parameters: {
      type: 'object',
      properties: {
        query: { type: 'string', description: '개념 이름이나 키워드' },
        limit: nullable({ type: 'integer', description: '최대 개수(1~20). 기본 10이면 null.' }),
        offset: nullable({ type: 'integer', description: '이어 볼 자리(next_offset). 처음이면 null.' }),
      },
      required: ['query', 'limit', 'offset'],
      additionalProperties: false,
    },
  },
  {
    name: 'list_concept_categories',
    description: '개념 분류 트리의 한 단계를 가져온다. parent_id가 null이면 최상위 분류.',
    parameters: {
      type: 'object',
      properties: { parent_id: nullable({ type: 'string', description: '상위 분류 id (uuid)' }) },
      required: ['parent_id'],
      additionalProperties: false,
    },
  },
  {
    name: 'search_behavior_cards',
    description: '학습 행동 카드(반복 주기, 단계별 내용)를 검색한다. query가 null이면 전체 목록.',
    parameters: {
      type: 'object',
      properties: {
        query: nullable({ type: 'string', description: '카드 이름이나 내용 키워드' }),
        limit: nullable({ type: 'integer', description: '최대 개수(1~30). 기본 20이면 null.' }),
      },
      required: ['query', 'limit'],
      additionalProperties: false,
    },
  },
  ...ACTION_TOOLS,
  CONSULT_TOOL,
  ...ORGANIZE_TOOLS,
  ...CONCEPT_DRAFT_TOOLS,
  ...COURSE_MAP_TOOLS,
  ...REVIEW_JOB_TOOLS,
  BATCH_TOOL,
  ...CONCEPT_SOURCE_TOOLS,
];

/** 부서 협의·넘기기 도구. 부서 기능이 준비된 요청에만 준다. 협의는 chat.ts가 직접 실행한다(모델 호출이 필요해서). */
export const DEPARTMENT_TOOL_NAMES = new Set([HANDOVER_TOOL_NAME, CONSULT_TOOL_NAME]);

/** 제안을 남기거나 작업을 시작하는 도구. 커서 질문(readOnly)에는 하나도 주지 않는다. */
export const ACTING_TOOL_NAMES = new Set([
  'propose_code_request',
  'start_code_plan',
  'propose_folder',
  'propose_delete',
  SPLIT_TOOL_NAME,
  ...MEMORY_TOOL_NAMES,
  ...DEPARTMENT_TOOL_NAMES,
  ...ORGANIZE_PROPOSE_TOOL_NAMES,
  ...CONCEPT_DRAFT_TOOL_NAMES,
  ...COURSE_MAP_PROPOSE_TOOL_NAMES,
  ...REVIEW_JOB_ACTING_TOOL_NAMES,
  BATCH_TOOL_NAME,
]);

/**
 * 이번 요청에 노출할 도구. 나누기·기억 제안·부서·정리 도구는 서버가 쓸 수 있다고 판단한 요청에만 넣는다.
 * folder·handover는 자동 정리 제안이 꺼진 턴에 분류·넘기기 제안을 뺄 때 false로 준다(생략하면 노출).
 * readOnly(커서 질문)면 조회 도구만 준다. Think와 Cursor가 서로 일을 시키며 맴돌지 않게 한다.
 * conceptDraft는 검토 창에서 열린 초안을 읽었을 때만 준다. 변경 도구는 저장된 검토가 있을 때만(change).
 * courseMap(과정 탐색도·개념 배치·개념 고치기의 읽기·제안 도구)은 그 기능이 준비된 요청에만 준다.
 * conceptReview(개념 검토 목록·검토 기록)는 courseMap에 더해 그 기능까지 준비된 요청에만 준다.
 * conceptRelations(개념 관계 읽기·관계 카드)도 courseMap에 더해 그 기능까지 준비된 요청에만 준다.
 * conceptSources(개념 출처 원본 다시 읽기)도 courseMap에 더해 그 기능까지 준비된 요청에만 준다. 커서 질문에는 주지 않는다.
 * reviewJobs(개념 검수 작업 이어하기)는 conceptReview에 더해 그 기능까지 준비된 요청에만 준다.
 * reviewBatch(50개 묶음 검수)는 reviewJobs에 더해 그 기능까지 준비된 요청에만 준다. 실행은 chat.ts가 한다(판단 모델 호출).
 */
export function thinkToolsFor(opts: {
  split: boolean;
  memory?: boolean;
  departments?: boolean;
  folder?: boolean;
  handover?: boolean;
  organize?: boolean;
  criteria?: boolean;
  readOnly?: boolean;
  conceptDraft?: { change: boolean } | null;
  courseMap?: boolean;
  conceptReview?: boolean;
  conceptRelations?: boolean;
  conceptSources?: boolean;
  reviewJobs?: boolean;
  reviewBatch?: boolean;
}): AiFunctionTool[] {
  if (opts.readOnly) {
    return THINK_TOOLS.filter((t) =>
      !ACTING_TOOL_NAMES.has(t.name) && !ORGANIZE_TOOL_NAMES.has(t.name) && !COURSE_MAP_TOOL_NAMES.has(t.name) &&
      !CONCEPT_SOURCE_TOOL_NAMES.has(t.name) && !REVIEW_JOB_TOOL_NAMES.has(t.name) && t.name !== BATCH_TOOL_NAME
    );
  }
  const draft = opts.conceptDraft ?? null;
  return THINK_TOOLS.filter((t) =>
    (!CONCEPT_DRAFT_TOOL_NAMES.has(t.name) || (draft !== null && (draft.change || t.name !== DRAFT_CHANGE_TOOL_NAME))) &&
    (opts.courseMap === true || !COURSE_MAP_TOOL_NAMES.has(t.name)) &&
    (opts.conceptReview === true || !CONCEPT_REVIEW_TOOL_NAMES.has(t.name)) &&
    (opts.conceptRelations === true || !CONCEPT_RELATION_TOOL_NAMES.has(t.name)) &&
    ((opts.courseMap === true && opts.conceptSources === true) || !CONCEPT_SOURCE_TOOL_NAMES.has(t.name)) &&
    ((opts.conceptReview === true && opts.reviewJobs === true) || !REVIEW_JOB_TOOL_NAMES.has(t.name)) &&
    ((opts.conceptReview === true && opts.reviewJobs === true && opts.reviewBatch === true) || t.name !== BATCH_TOOL_NAME) &&
    (opts.split || t.name !== SPLIT_TOOL_NAME) &&
    (opts.memory === true || !MEMORY_TOOL_NAMES.has(t.name)) &&
    (opts.departments === true || !DEPARTMENT_TOOL_NAMES.has(t.name)) &&
    (opts.folder !== false || t.name !== 'propose_folder') &&
    (opts.handover !== false || t.name !== HANDOVER_TOOL_NAME) &&
    (opts.organize === true || !ORGANIZE_TOOL_NAMES.has(t.name)) &&
    (opts.criteria === true || t.name !== CRITERIA_TOOL_NAME)
  );
}

export const TOOL_LABELS: Record<string, string> = {
  ...ACTION_TOOL_LABELS,
  ...ORGANIZE_TOOL_LABELS,
  ...CONCEPT_DRAFT_TOOL_LABELS,
  ...COURSE_MAP_TOOL_LABELS,
  ...REVIEW_JOB_TOOL_LABELS,
  [BATCH_TOOL_NAME]: BATCH_TOOL_LABEL,
  ...CONCEPT_SOURCE_TOOL_LABELS,
  [CONSULT_TOOL_NAME]: '부서 협의',
  search_memories: '기억 검색',
  get_memory: '기억 열람',
  get_curriculum_outline: '교육과정 조회',
  search_concepts: '개념 검색',
  list_concept_categories: '개념 분류 조회',
  search_behavior_cards: '학습 행동 카드 조회',
  web_search: '웹 검색',
  code_interpreter: '파이썬 실행',
  code_sandbox: '엑셀 준비',
};

export interface ToolRunResult {
  name: string;
  ok: boolean;
  output: string;
  summary: string;
  /** 제안 도구가 남긴 제안. 화면에 카드로 바로 보낸다. */
  action?: ActionRow;
  /** 한 번에 여러 카드를 낸 결과(검수 카드 옮기기 등). */
  actions?: ActionRow[];
  /** 결과와 함께 모델 입력에 넣을 이미지(원본 쪽 등). 화면·기록에는 남기지 않는다. */
  images?: AiToolImage[];
}

const MAX_OUTPUT_CHARS = 12000;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function str(v: unknown, max = 200): string | null {
  if (typeof v !== 'string') return null;
  const t = v.trim();
  return t ? t.slice(0, max) : null;
}

function int(v: unknown, fallback: number, min: number, max: number): number {
  const n = typeof v === 'number' ? v : Number.NaN;
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(max, Math.floor(n)));
}

function toOutput(value: unknown): string {
  const text = JSON.stringify(value);
  if (text.length <= MAX_OUTPUT_CHARS) return text;
  return JSON.stringify({ truncated: true, preview: text.slice(0, MAX_OUTPUT_CHARS) });
}

function fail(name: string, error: string, summary: string): ToolRunResult {
  return { name, ok: false, output: JSON.stringify({ error }), summary };
}

function withTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error('tool_timeout')), ms);
  });
  return Promise.race([p, timeout]).finally(() => clearTimeout(timer));
}

async function ensureMemorySession(src: ThinkToolSource, ctx: ActionToolContext): Promise<string> {
  const mem = ctx.memory;
  if (!mem || !src.openMemoryRead) throw new Error('memory_compare_unavailable');
  if (mem.sessionId) return mem.sessionId;
  const id = await src.openMemoryRead(ctx.conversationId);
  mem.sessionId = id;
  return id;
}

async function dispatch(
  name: string,
  args: Record<string, unknown>,
  src: ThinkToolSource,
  ctx: ActionToolContext | undefined,
): Promise<ToolRunResult> {
  if (ACTION_TOOL_NAMES.has(name)) return await dispatchActionTool(name, args, src, ctx);
  if (ORGANIZE_TOOL_NAMES.has(name)) return await dispatchOrganizeTool(name, args, src, ctx);
  if (CONCEPT_DRAFT_TOOL_NAMES.has(name)) return await dispatchConceptDraftTool(name, args, src, ctx);
  if (COURSE_MAP_TOOL_NAMES.has(name)) return await dispatchCourseMapTool(name, args, src, ctx);
  if (CONCEPT_SOURCE_TOOL_NAMES.has(name)) return await dispatchConceptSourceTool(name, args, src, ctx);
  if (REVIEW_JOB_TOOL_NAMES.has(name)) return await dispatchReviewJobTool(name, args, src, ctx);
  if (name === BATCH_TOOL_NAME) {
    return { name, ok: false, output: JSON.stringify({ error: 'review_batch_unavailable' }), summary: '지금은 쓸 수 없음' };
  }
  switch (name) {
    case 'search_memories': {
      const query = str(args.query);
      if (!query) return fail(name, 'query_required', '검색어 없음');
      const kinds = Array.isArray(args.kinds)
        ? args.kinds.filter((k): k is string => typeof k === 'string' && ['identity', 'principle', 'decision', 'note'].includes(k))
        : [];
      const terms = extractSearchTerms(query);
      const termList = terms.length > 0 ? terms : [query];
      if (ctx?.memory) {
        if (!src.searchMemoryLogged || !src.openMemoryRead) return fail(name, 'memory_compare_unavailable', '비교 기록을 남길 수 없음');
        let session = '';
        try {
          session = await ensureMemorySession(src, ctx);
          const body = await src.searchMemoryLogged(session, query, termList, ctx.access ?? null);
          if (body.status === 'error' || body.status === 'timeout') return fail(name, 'memory_search_failed', '검색 실패');
          const hits = (Array.isArray(body.hits) ? body.hits : []).filter((h) => {
            if (!h || typeof h !== 'object') return false;
            const kind = (h as { kind?: unknown }).kind;
            return kinds.length === 0 || (typeof kind === 'string' && kinds.includes(kind));
          });
          for (const h of hits) {
            const row = h as { id?: unknown; title?: unknown; excerpt?: unknown };
            if (typeof row.id !== 'string') continue;
            ctx.recordDelivered?.({
              kind: 'memory',
              id: row.id,
              title: typeof row.title === 'string' ? row.title : undefined,
              delivered: false,
              truncated: true,
              excerpt_chars: typeof row.excerpt === 'string' ? row.excerpt.length : 0,
            });
          }
          const hitCount = typeof body.hit_count === 'number' ? body.hit_count : hits.length;
          return {
            name,
            ok: true,
            output: JSON.stringify({
              status: body.status === 'empty' ? 'empty' : 'ok',
              hit_count: hitCount,
              shown: hits.length,
              scope: body.scope ?? null,
              excerpt_only: true,
              note: '발췌만 있다. 비교하려면 get_memory로 원문을 끝까지 읽는다. 이 결과만으로 비교를 끝내지 않는다.',
              hits,
            }),
            summary: `"${query}" ${body.status === 'empty' ? '0건' : `${hitCount}건`}`,
          };
        } catch (e) {
          const message = e instanceof Error ? e.message : String(e);
          if (session) await src.noteMemoryOutcome?.(session, 'search', message === 'tool_timeout' ? 'timeout' : 'error', null).catch(() => {});
          return fail(name, message === 'memory_compare_unavailable' ? 'memory_compare_unavailable' : 'memory_search_failed', '검색 실패');
        }
      }
      const found = await src.searchMemories(termList, 20, searchScopeFor(ctx?.access));
      const hits = scopeMemories(found, ctx?.access).filter((m) => kinds.length === 0 || kinds.includes(m.kind)).slice(0, 10);
      for (const m of hits) {
        ctx?.recordDelivered?.({ kind: 'memory', id: m.id, title: m.title, delivered: true });
      }
      return {
        name,
        ok: true,
        output: toOutput(
          hits.map((m) => ({ id: m.id, kind: m.kind, status: m.status, title: m.title, excerpt: m.content.slice(0, 500) })),
        ),
        summary: `"${query}" ${hits.length}건`,
      };
    }
    case 'get_memory': {
      const id = str(args.id, 64);
      if (!id || !UUID_RE.test(id)) return fail(name, 'invalid_id', 'id 형식 오류');
      const offset = args.offset == null ? 0 : int(args.offset, -1, 0, 1_000_000);
      if (args.offset != null && offset < 0) return fail(name, 'invalid_offset', 'offset 형식 오류');
      if (ctx?.memory) {
        if (!src.readMemoryLogged || !src.openMemoryRead) return fail(name, 'memory_compare_unavailable', '비교 기록을 남길 수 없음');
        let session = '';
        try {
          session = await ensureMemorySession(src, ctx);
          const body = await src.readMemoryLogged(session, id, offset, ctx.access ?? null);
          if (body.status === 'forbidden' || body.status === 'not_found') return fail(name, 'not_found', '찾을 수 없음');
          const text = JSON.stringify(body);
          if (text.length > MAX_OUTPUT_CHARS) return fail(name, 'memory_read_incomplete', '원문이 잘려 전달되지 않음');
          if (typeof body.id === 'string') {
            ctx.recordDelivered?.({
              kind: 'memory',
              id: body.id,
              title: typeof body.title === 'string' ? body.title : undefined,
              delivered: body.complete === true,
              truncated: body.complete !== true,
              excerpt_chars: typeof body.document === 'string' ? body.document.length : 0,
            });
          }
          return {
            name,
            ok: true,
            output: text,
            summary: body.status === 'version_changed' ? '판이 바뀌어 다시 읽어야 함' : (typeof body.title === 'string' ? body.title : id),
          };
        } catch (e) {
          const message = e instanceof Error ? e.message : String(e);
          if (session) await src.noteMemoryOutcome?.(session, 'read', message === 'tool_timeout' ? 'timeout' : 'error', id).catch(() => {});
          return fail(name, message === 'memory_compare_unavailable' ? 'memory_compare_unavailable' : 'memory_read_missing', '원문을 읽지 못함');
        }
      }
      const m = await src.getMemory(id);
      if (!m || m.status !== 'active') return fail(name, 'not_found', '찾을 수 없음');
      // 범위 밖 기억은 있는지조차 알리지 않는다(없는 id와 같은 답).
      const visible = ctx?.access ? canProvideMemoryToAi(m, ctx.access) : legacyVisible(m);
      if (!visible) return fail(name, 'not_found', '찾을 수 없음');
      ctx?.recordDelivered?.({ kind: 'memory', id: m.id, title: m.title, delivered: true });
      return { name, ok: true, output: toOutput(m), summary: m.title };
    }
    case 'get_curriculum_outline': {
      const schoolLevel = args.school_level === '중' || args.school_level === '고' ? args.school_level : null;
      const depth = args.depth === 'chapter' || args.depth === 'section' ? args.depth : 'grade';
      const curriculumName = str(args.curriculum_name, 60);
      const tree = await src.curriculumOutline({ curriculumName, schoolLevel, depth });
      return {
        name,
        ok: true,
        output: toOutput(tree),
        summary: [curriculumName ?? '활성 교육과정', schoolLevel ?? '', depth].filter(Boolean).join(' · '),
      };
    }
    case 'search_concepts': {
      const query = str(args.query, 100);
      if (!query) return fail(name, 'query_required', '검색어 없음');
      const limit = int(args.limit, 10, 1, 20);
      const offset = int(args.offset, 0, 0, 100000);
      const { total, hits } = await src.searchConcepts(query, limit, offset);
      const q = query.toLowerCase();
      const to = offset + hits.length;
      const next = total !== null ? (to < total ? to : null) : hits.length === limit ? to : null;
      const items = hits.map((h) => ({
        id: h.id,
        name: h.name,
        kind: h.kind,
        level: h.level,
        category_path: h.category_path,
        excerpt: h.content,
        excerpt_truncated: h.content_chars > h.content.length,
        content_chars: h.content_chars,
        match: h.name.toLowerCase().includes(q) ? 'name' : 'content',
        same_name: h.name.trim().toLowerCase() === q,
      }));
      return {
        name,
        ok: true,
        output: toOutput({ query, total, offset, next_offset: next, items }),
        summary: `"${query}" ${hits.length}${total !== null ? `/${total}` : ''}건`,
      };
    }
    case 'list_concept_categories': {
      const parentId = str(args.parent_id, 64);
      if (parentId && !UUID_RE.test(parentId)) return fail(name, 'invalid_parent_id', 'id 형식 오류');
      const rows = await src.listConceptCategories(parentId);
      return { name, ok: true, output: toOutput(rows), summary: `${rows.length}개 분류` };
    }
    case 'search_behavior_cards': {
      const query = str(args.query, 100);
      const rows = await src.searchBehaviorCards(query, int(args.limit, 20, 1, 30));
      return { name, ok: true, output: toOutput(rows), summary: `${query ? `"${query}" ` : ''}${rows.length}건` };
    }
    case CONSULT_TOOL_NAME:
      return fail(name, 'consult_unavailable', '지금은 협의할 수 없음');
    default:
      return fail(name, 'unknown_tool', '알 수 없는 도구');
  }
}

/** 도구 실패는 예외로 올리지 않고 모델에게 오류 결과로 돌려준다. */
export async function runThinkTool(
  name: string,
  rawArguments: string,
  src: ThinkToolSource,
  timeoutMs = 8000,
  ctx?: ActionToolContext,
): Promise<ToolRunResult> {
  let args: Record<string, unknown>;
  try {
    const parsed = JSON.parse(rawArguments || '{}');
    args = parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return fail(name, 'invalid_arguments', '인자 형식 오류');
  }
  try {
    return await withTimeout(dispatch(name, args, src, ctx), timeoutMs);
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error(`[ai_think] tool ${name} failed:`, message);
    return fail(name, message === 'tool_timeout' ? 'timeout' : 'lookup_failed', message === 'tool_timeout' ? '시간 초과' : '조회 실패');
  }
}
