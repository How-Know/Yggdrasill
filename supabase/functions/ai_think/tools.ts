// Think 대화에서 AI가 부를 수 있는 도구. 정해진 조회만 한다(임의 SQL 없음).
// 쓰기처럼 보이는 propose_* 도구(actions.ts)도 제안 1행만 남기고, 실행은 사용자 승인 RPC가 한다.

import { extractSearchTerms } from '../_shared/ai/search_terms.ts';
import type { AiFunctionTool } from '../_shared/ai/types.ts';
import {
  ACTION_TOOLS,
  ACTION_TOOL_LABELS,
  ACTION_TOOL_NAMES,
  dispatchActionTool,
  type ActionRow,
  type ActionToolContext,
  type ActionToolSource,
} from './actions.ts';
import type { MemoryDetail, MemoryRow } from './context.ts';

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
  content: string;
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

export interface ThinkToolSource extends ActionToolSource {
  searchMemories(terms: string[], limit: number): Promise<MemoryRow[]>;
  getMemory(id: string): Promise<MemoryDetail | null>;
  curriculumOutline(q: CurriculumOutlineQuery): Promise<CurriculumNode[]>;
  searchConcepts(query: string, limit: number): Promise<ConceptHit[]>;
  listConceptCategories(parentId: string | null): Promise<ConceptCategory[]>;
  searchBehaviorCards(query: string | null, limit: number): Promise<BehaviorCard[]>;
}

const nullable = (schema: Record<string, unknown>) => ({ ...schema, type: [schema.type, 'null'] });

export const THINK_TOOLS: AiFunctionTool[] = [
  {
    name: 'search_memories',
    description: '저장된 기억(교육철학, 원칙, 결정, 메모)을 검색한다. 과거에 무엇을 정했는지 확인할 때 쓴다.',
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
    description: '기억 하나의 전체 내용(배경, 이유, 대안 포함)을 id로 가져온다.',
    parameters: {
      type: 'object',
      properties: { id: { type: 'string', description: '기억 id (uuid)' } },
      required: ['id'],
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
    description: '개념(정의·정리) 데이터를 이름과 내용으로 검색한다.',
    parameters: {
      type: 'object',
      properties: {
        query: { type: 'string', description: '개념 이름이나 키워드' },
        limit: nullable({ type: 'integer', description: '최대 개수(1~20). 기본 10이면 null.' }),
      },
      required: ['query', 'limit'],
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
];

export const TOOL_LABELS: Record<string, string> = {
  ...ACTION_TOOL_LABELS,
  search_memories: '기억 검색',
  get_memory: '기억 열람',
  get_curriculum_outline: '교육과정 조회',
  search_concepts: '개념 검색',
  list_concept_categories: '개념 분류 조회',
  search_behavior_cards: '학습 행동 카드 조회',
  web_search: '웹 검색',
};

export interface ToolRunResult {
  name: string;
  ok: boolean;
  output: string;
  summary: string;
  /** 제안 도구가 남긴 제안. 화면에 카드로 바로 보낸다. */
  action?: ActionRow;
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

async function dispatch(
  name: string,
  args: Record<string, unknown>,
  src: ThinkToolSource,
  ctx: ActionToolContext | undefined,
): Promise<ToolRunResult> {
  if (ACTION_TOOL_NAMES.has(name)) return await dispatchActionTool(name, args, src, ctx);
  switch (name) {
    case 'search_memories': {
      const query = str(args.query);
      if (!query) return fail(name, 'query_required', '검색어 없음');
      const kinds = Array.isArray(args.kinds)
        ? args.kinds.filter((k): k is string => typeof k === 'string' && ['identity', 'principle', 'decision', 'note'].includes(k))
        : [];
      const terms = extractSearchTerms(query);
      const hits = (await src.searchMemories(terms.length > 0 ? terms : [query], 20))
        .filter((m) => kinds.length === 0 || kinds.includes(m.kind))
        .slice(0, 10);
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
      const m = await src.getMemory(id);
      if (!m) return fail(name, 'not_found', '찾을 수 없음');
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
      const hits = await src.searchConcepts(query, int(args.limit, 10, 1, 20));
      return { name, ok: true, output: toOutput(hits), summary: `"${query}" ${hits.length}건` };
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
