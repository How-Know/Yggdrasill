// Think 작업 도구: 트리·대화·코드 요청 읽기 + 제안(propose_*) + 조율 시작(start_code_plan).
// 제안 도구는 ai_actions에 "제안" 1행만 남긴다. 실행은 사용자가 카드에서 승인할 때 ai_action_apply가 한다.
// 조율 시작만 예외로 바로 대기열에 넣는다(읽기 전용, 운영자 결정 2026-10-01).
// 조율 뒤 수정·자동 검사·재수정은 결과 검토(ai_code_bridge/code_review.ts)가 이어 간다(운영자 결정 2026-10-06).
// 대화 나누기(propose_conversation_split)는 메시지 범위를 모델에게 받지 않는다. 이번 턴의 사용자 메시지 id는 서버가 넣는다(§7).
// 설계: docs/architecture/ai-think-actions.md

import type { AiFunctionTool } from '../_shared/ai/types.ts';
import { EFFORT_TOOL_PROPERTIES, effortReason, normalizeEffort } from '../_shared/code_effort.ts';
import { clip } from './prompts.ts';
import type { ToolRunResult } from './tools.ts';

export type ActionKind =
  | 'code_request'
  | 'code_change'
  | 'code_plan'
  | 'place_conversation'
  | 'delete_code_request'
  | 'delete_folder'
  | 'delete_conversation'
  | 'split_conversation'
  | 'save_memory'
  | 'memory_card_change';

export interface ActionRow {
  id: string;
  conversation_id: string;
  message_id: string | null;
  kind: ActionKind;
  status: string;
  payload: Record<string, unknown>;
  preview: Record<string, unknown>;
  result: Record<string, unknown> | null;
  error: string | null;
  superseded?: boolean;
  created_at: string;
}

export interface TreeFolderRow {
  id: string;
  parent_id: string | null;
  title: string;
}

/** 폴더가 아닌 노드. 제목·요약은 읽지 않는다(발췌 내용은 AI에게 보이지 않는다). */
export interface TreeItemRow {
  parent_id: string | null;
  kind: string;
  conversation_id: string | null;
}

export interface ConversationHit {
  id: string;
  title: string;
  last_message_at: string | null;
}

export interface ConversationStats {
  id: string;
  title: string;
  messages: number;
  excerpts: number;
  documents: number;
  code_requests: number;
}

export interface CodeRequestHit {
  id: string;
  title: string;
  status: string;
  mode: string;
  conversation_id: string | null;
  created_at: string;
}

export interface CodeRequestDetail extends CodeRequestHit {
  request: Record<string, unknown>;
  round: number;
  max_rounds: number;
  review_status: string | null;
  last_error: string | null;
  latest: {
    round: number;
    status: string;
    result: Record<string, unknown> | null;
    result_text: string | null;
  } | null;
}

export interface MemoryRef {
  id: string;
  kind: string;
  title: string;
  version: number | null;
  content: string;
}

export interface ActionToolSource {
  listTreeFolders(): Promise<{ folders: TreeFolderRow[]; items: TreeItemRow[] }>;
  listConversations(query: string | null, limit: number): Promise<ConversationHit[]>;
  conversationStats(id: string): Promise<ConversationStats | null>;
  listCodeRequests(query: string | null, limit: number): Promise<CodeRequestHit[]>;
  getCodeRequest(id: string): Promise<CodeRequestDetail | null>;
  proposeAction(conversationId: string, kind: ActionKind, payload: Record<string, unknown>, preview: Record<string, unknown>): Promise<ActionRow>;
  /** 조율 요청을 만들어 바로 보낸다. 하루 한도를 넘으면 'code_request_daily_limit'가 든 오류를 던진다. */
  startCodePlan(conversationId: string, title: string, spec: Record<string, unknown>): Promise<ActionRow>;
  /** 나누기 제안. 범위는 DB가 startMessageId(이번 턴의 사용자 메시지)로 정한다. 거절된 대화면 'split_suppressed' 오류. */
  proposeSplit(
    conversationId: string,
    startMessageId: string,
    payload: Record<string, unknown>,
    preview: Record<string, unknown>,
    userRequested: boolean,
  ): Promise<ActionRow>;
}

export interface WorkState {
  actions: ActionRow[];
  codeRequests: CodeRequestDetail[];
}

/** 이번 턴에 나누기 도구를 쓸 수 있을 때만 채운다(기능 준비됨, 앞 대화 있음, 거절로 꺼지지 않았거나 사용자가 직접 요청). */
export interface SplitToolContext {
  userMessageId: string;
  userRequested: boolean;
  proposed: boolean;
}

/** 기억 저장 제안을 쓸 수 있을 때만 채운다(기능 준비됨, 커서 질문 아님). 한 답변에 기억 카드는 하나만. */
export interface MemoryToolContext {
  proposed: boolean;
}

export interface ActionToolContext {
  conversationId: string;
  memoryRefs: MemoryRef[];
  split?: SplitToolContext;
  memory?: MemoryToolContext;
  /** get_memory·search_memories 범위 판정 */
  access?: import('./access_context.ts').ConversationAccessState;
  /** 도구로 AI에 전달된 자료 id 기록(스냅샷용) */
  recordDelivered?: (ref: import('./access_context.ts').DeliveredMaterial) => void;
}

export const SPLIT_TOOL_NAME = 'propose_conversation_split';
export const MEMORY_TOOL_NAME = 'propose_memory';
export const MEMORY_CHANGE_TOOL_NAME = 'propose_memory_card_change';
export const MEMORY_TOOL_NAMES = new Set([MEMORY_TOOL_NAME, MEMORY_CHANGE_TOOL_NAME]);

export const DELETABLE_CODE_STATUSES = [
  'draft', 'ready', 'needs_review', 'failed', 'cancelled', 'applied', 'apply_failed', 'reverted', 'revert_failed',
];

const nullable = (schema: Record<string, unknown>) => ({ ...schema, type: [schema.type, 'null'] });
const strList = (description: string) => nullable({ type: 'array', items: { type: 'string' }, description });
const noArgs = { type: 'object', properties: {}, required: [], additionalProperties: false };

const MEMORY_SCHEMA: Record<string, unknown> = {
  type: 'object',
  description: '저장할 기억. 범위(memory_scope·scope_department)는 네 제안값이고 사용자가 카드에서 확인·수정한다.',
  properties: {
    kind: { type: 'string', enum: ['decision', 'principle'], description: 'decision: 한 번 정한 결정, principle: 계속 지킬 원칙' },
    title: { type: 'string', description: '제목 (40자 안팎의 명사구)' },
    content: { type: 'string', description: '확정된 내용만. 네 제안이나 아직 정하지 않은 것은 넣지 않는다' },
    decision_context: nullable({ type: 'string', description: '결정이면 왜 이 문제를 다뤘는지. 원칙이면 null' }),
    decision_reason: nullable({ type: 'string', description: '결정이면 이렇게 정한 이유. 원칙이면 null' }),
    alternatives: strList('결정이면 검토한 대안(한 줄에 하나). 없거나 원칙이면 null'),
    tags: strList('태그. 없으면 null'),
    memory_scope: { type: 'string', enum: ['common', 'department'], description: '모든 부서에 해당하면 common' },
    scope_department: nullable({ type: 'string', enum: ['education', 'product', 'engineering'], description: 'department일 때 부서. common이면 null' }),
    supersedes_id: nullable({ type: 'string', description: '바뀐 내용으로 대체할 기존 확정 기억 id. 새 기억이면 null' }),
  },
  required: [
    'kind', 'title', 'content', 'decision_context', 'decision_reason', 'alternatives', 'tags', 'memory_scope',
    'scope_department', 'supersedes_id',
  ],
  additionalProperties: false,
};

export const ACTION_TOOLS: AiFunctionTool[] = [
  {
    name: 'list_tree_folders',
    description: '대화 정리 트리의 폴더 목록(id, 경로, 항목 수)과 지금 대화가 놓인 위치를 가져온다. 분류를 제안하기 전에 쓴다.',
    parameters: noArgs,
  },
  {
    name: 'list_conversations',
    description: 'Think 대화 목록(id, 제목, 마지막 시각)을 제목으로 찾는다. 대화 내용은 돌려주지 않는다.',
    parameters: {
      type: 'object',
      properties: {
        query: nullable({ type: 'string', description: '제목에 들어간 말. 최근 대화 전체면 null.' }),
        limit: nullable({ type: 'integer', description: '최대 개수(1~20). 기본 10이면 null.' }),
      },
      required: ['query', 'limit'],
      additionalProperties: false,
    },
  },
  {
    name: 'list_code_requests',
    description: 'Cursor 코드 조사·수정 요청 목록(id, 제목, 상태, 모드)을 찾는다.',
    parameters: {
      type: 'object',
      properties: {
        query: nullable({ type: 'string', description: '제목에 들어간 말. 최근 전체면 null.' }),
      },
      required: ['query'],
      additionalProperties: false,
    },
  },
  {
    name: 'get_code_request',
    description: '코드 요청 하나의 내용과 마지막 결과(결론, 제안, 근거 파일, 수정이면 변경 통계)를 가져온다.',
    parameters: {
      type: 'object',
      properties: { id: { type: 'string', description: '코드 요청 id (uuid)' } },
      required: ['id'],
      additionalProperties: false,
    },
  },
  {
    name: 'propose_code_request',
    description:
      'Cursor에게 저장소 코드를 읽고 조사해 달라는 요청을 제안한다. 코드는 바뀌지 않는다. 사용자가 카드에서 "보내기"를 눌러야 시작된다. 결과는 몇 분 뒤 같은 대화에 정리되어 붙는다.',
    parameters: {
      type: 'object',
      properties: {
        title: { type: 'string', description: '요청 제목 (40자 이내)' },
        goal: { type: 'string', description: '무엇을 알아내려는지 한두 문장' },
        questions: strList('확인할 질문. 없으면 null.'),
        focus_paths: strList('우선 볼 폴더나 파일(저장소 기준 경로). 모르면 null.'),
        constraints: strList('지켜야 할 조건. 없으면 null.'),
        do_not: strList('하지 말 것. 없으면 null.'),
        background: nullable({ type: 'string', description: '이 대화에서 나온 배경을 Cursor가 알아야 할 만큼만 요약. 없으면 null.' }),
        ...EFFORT_TOOL_PROPERTIES,
      },
      required: ['title', 'goal', 'questions', 'focus_paths', 'constraints', 'do_not', 'background', 'effort', 'effort_reason'],
      additionalProperties: false,
    },
  },
  {
    name: 'start_code_plan',
    description:
      '코드를 고치는 일은 바로 고치지 않고 먼저 Cursor(실무 개발자)와 조율한다. 부르면 승인 없이 바로 시작된다(읽기 전용, 하루 한도에 1건). ' +
      'Cursor가 이 계획 초안을 실제 코드에 비춰 문제·빠진 점·더 나은 방법을 검토하고, 네가 그 결과를 보고 필요하면 다시 묻는다(최대 3회). ' +
      '끝나면 사용자에게 물을 것이 없을 때 조율본대로 바로 수정이 시작되고(하루 한도 1건 더), 자동 검사 결과까지 이 대화에 붙는다. ' +
      '물을 것이 있으면 조율본 카드에 객관식 질문이 올라온다. 작업 폴더 적용은 사용자가 따로 승인한다.',
    parameters: {
      type: 'object',
      properties: {
        title: { type: 'string', description: '작업 제목 (40자 이내)' },
        goal: { type: 'string', description: '이 작업으로 이루려는 것' },
        instructions: { type: 'array', items: { type: 'string' }, description: '계획 초안: 무엇을 어떻게 바꿀지 단계별로' },
        questions: strList('Cursor에게 특히 확인받고 싶은 점(구조, 영향 범위, 대안 등). 없으면 null.'),
        focus_paths: strList('관련 폴더나 파일. 모르면 null.'),
        constraints: strList('지켜야 할 조건. 없으면 null.'),
        do_not: strList('하지 말 것. 없으면 null.'),
        background: nullable({ type: 'string', description: '이 대화에서 나온 배경과 의도를 Cursor가 알아야 할 만큼만 요약. 없으면 null.' }),
        based_on_request_id: nullable({ type: 'string', description: '근거가 된 조사 요청 id. 없으면 null.' }),
        continue_from_request_id: nullable({
          type: 'string',
          description:
            '작업 폴더에 아직 적용되지 않은 앞 코드 수정의 결과를 이어받아 고칠 때, 그 코드 수정 요청 id(전체 uuid). ' +
            '검사 실패로 다시 고친 요청이 있으면 마지막 것을 준다. 작업자가 그 요청의 최종 패치를 지금 작업 폴더 복사본에 얹어 시작한다. ' +
            '시간 제한으로 멈춘 수정이면 그 미완성 패치(검사 안 됨)에서 시작한다. 없으면 null.',
        }),
        ...EFFORT_TOOL_PROPERTIES,
      },
      required: [
        'title',
        'goal',
        'instructions',
        'questions',
        'focus_paths',
        'constraints',
        'do_not',
        'background',
        'based_on_request_id',
        'continue_from_request_id',
        'effort',
        'effort_reason',
      ],
      additionalProperties: false,
    },
  },
  {
    name: 'propose_folder',
    description:
      '지금 대화를 넣을 트리 폴더를 제안한다. 기존 폴더면 folder_id, 새 폴더면 new_folder_title(+상위 폴더 id)을 준다. 사용자가 확정하기 전에는 아무것도 저장되지 않는다.',
    parameters: {
      type: 'object',
      properties: {
        folder_id: nullable({ type: 'string', description: '기존 폴더 id. 새 폴더를 제안하면 null.' }),
        new_folder_title: nullable({ type: 'string', description: '새 폴더 이름. 기존 폴더면 null.' }),
        new_folder_parent_id: nullable({ type: 'string', description: '새 폴더의 상위 폴더 id. 최상위면 null.' }),
        reason: { type: 'string', description: '이 폴더가 맞는 이유 한 문장' },
      },
      required: ['folder_id', 'new_folder_title', 'new_folder_parent_id', 'reason'],
      additionalProperties: false,
    },
  },
  {
    name: 'propose_delete',
    description: '삭제를 제안한다. 사용자가 지우자고 할 때만 쓴다. 카드에 지워질 내용을 보여 주고, 사용자가 확인해야 지워진다. 되돌릴 수 없다.',
    parameters: {
      type: 'object',
      properties: {
        target_kind: { type: 'string', enum: ['code_request', 'folder', 'conversation'] },
        target_id: { type: 'string', description: '지울 대상 id (uuid)' },
        reason: { type: 'string', description: '지우는 이유 한 문장' },
      },
      required: ['target_kind', 'target_id', 'reason'],
      additionalProperties: false,
    },
  },
  {
    name: SPLIT_TOOL_NAME,
    description:
      '이번 질문이 지금 대화와 독립된 새 주제일 때, 새 대화로 나눠 이어가자고 제안한다. 승인되면 이번 질문과 네 답변이 새 대화로 복사되고 원본 대화는 그대로 남는다. ' +
      '사용자가 카드에서 "나눠서 이어가기"를 눌러야 실행된다. 메시지 범위는 서버가 정한다. 질문에는 이 대화에서 끝까지 답한다.',
    parameters: {
      type: 'object',
      properties: {
        title: { type: 'string', description: '새 대화 제목 (한국어 명사구, 30자 이내)' },
        reason: { type: 'string', description: '왜 새 주제로 보는지 한 문장' },
        folder_id: nullable({
          type: 'string',
          description: '새 대화를 둘 기존 폴더 id(list_tree_folders). 모르거나 맞는 폴더가 없으면 null(미분류). 새 폴더는 만들지 않는다.',
        }),
        summary: {
          type: 'object',
          description: '새 대화 맨 위에 보이고 새 대화의 참고 맥락이 되는 요약. 사실만 짧게 쓴다.',
          properties: {
            purpose: { type: 'string', description: '새 대화의 목적 한두 문장' },
            background: { type: 'string', description: '앞 대화에서 이어받을 배경. 없으면 빈 문자열' },
            decided: {
              type: 'array',
              items: { type: 'string' },
              description: '사용자가 확정한 사항만. 네가 제안했지만 사용자가 받아들이지 않은 것은 넣지 않는다. 없으면 빈 배열',
            },
            open: { type: 'array', items: { type: 'string' }, description: '아직 정하지 않은 것(네 제안 포함). 없으면 빈 배열' },
            next: { type: 'array', items: { type: 'string' }, description: '새 대화에서 다음에 할 일. 없으면 빈 배열' },
          },
          required: ['purpose', 'background', 'decided', 'open', 'next'],
          additionalProperties: false,
        },
      },
      required: ['title', 'reason', 'folder_id', 'summary'],
      additionalProperties: false,
    },
  },
  {
    name: MEMORY_TOOL_NAME,
    description:
      '사용자가 이 대화에서 명시적으로 확정한 결론·원칙을 기억으로 저장하자고 카드로 제안한다. 사용자가 카드에서 승인해야 저장된다. ' +
      '먼저 search_memories로 같은 기억이 있는지 본다. 같으면 제안하지 않고, 바뀐 것이면 supersedes_id로 대체를 제안한다. 한 답변에 하나만.',
    parameters: {
      type: 'object',
      properties: {
        memory: MEMORY_SCHEMA,
        reason: { type: 'string', description: '지금 저장할 만하다고 본 근거: 사용자가 무엇을 언제 확정했는지 한 문장' },
      },
      required: ['memory', 'reason'],
      additionalProperties: false,
    },
  },
  {
    name: MEMORY_CHANGE_TOOL_NAME,
    description:
      '대기 중인 기억 저장 카드를 고치거나(revise) 새 카드로 바꾸거나(replace) 없애자고(withdraw) 카드로 제안한다. 사용자가 승인해야 처리된다. ' +
      '같은 취지의 대기 카드가 있다고 propose_memory가 알려 줬을 때, 그 카드가 지금 대화와 맞지 않으면 쓴다.',
    parameters: {
      type: 'object',
      properties: {
        target_action_id: { type: 'string', description: '대기 중인 기억 저장 카드 id (propose_memory가 돌려준 pending_action_id)' },
        op: { type: 'string', enum: ['revise', 'replace', 'withdraw'] },
        memory: { ...MEMORY_SCHEMA, type: ['object', 'null'], description: '고치거나 바꿀 내용. withdraw면 null.' },
        reason: { type: 'string', description: '왜 바꾸거나 없애야 하는지 한 문장' },
      },
      required: ['target_action_id', 'op', 'memory', 'reason'],
      additionalProperties: false,
    },
  },
];

export const ACTION_TOOL_LABELS: Record<string, string> = {
  list_tree_folders: '트리 폴더 조회',
  list_conversations: '대화 목록 조회',
  list_code_requests: '코드 요청 조회',
  get_code_request: '코드 요청 열람',
  propose_code_request: '코드 조사 제안',
  start_code_plan: 'Cursor와 조율 시작',
  propose_folder: '분류 제안',
  propose_delete: '삭제 제안',
  [SPLIT_TOOL_NAME]: '대화 나누기 제안',
  [MEMORY_TOOL_NAME]: '기억 저장 제안',
  [MEMORY_CHANGE_TOOL_NAME]: '기억 카드 변경 제안',
};

export const ACTION_TOOL_NAMES = new Set(ACTION_TOOLS.map((t) => t.name));

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_OUTPUT_CHARS = 12000;

function str(v: unknown, max = 200): string | null {
  if (typeof v !== 'string') return null;
  const t = v.trim();
  return t ? t.slice(0, max) : null;
}

function list(v: unknown, maxItems = 12, maxChars = 500): string[] {
  if (!Array.isArray(v)) return [];
  return v
    .map((x) => (typeof x === 'string' ? x.trim().slice(0, maxChars) : ''))
    .filter(Boolean)
    .slice(0, maxItems);
}

function uuid(v: unknown): string | null {
  const s = str(v, 64);
  return s && UUID_RE.test(s) ? s : null;
}

function int(v: unknown, fallback: number, min: number, max: number): number {
  const n = typeof v === 'number' ? v : Number.NaN;
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(max, Math.floor(n)));
}

function out(name: string, value: unknown, summary: string, action?: ActionRow): ToolRunResult {
  const text = JSON.stringify(value);
  const output = text.length <= MAX_OUTPUT_CHARS ? text : JSON.stringify({ truncated: true, preview: text.slice(0, MAX_OUTPUT_CHARS) });
  return { name, ok: true, output, summary, action };
}

function bad(name: string, error: string, summary: string, extra: Record<string, unknown> = {}): ToolRunResult {
  return { name, ok: false, output: JSON.stringify({ error, ...extra }), summary };
}

/** 필수 값이 비었을 때. 모델이 사용자에게 되묻도록 무엇이 없는지 돌려준다. */
function missing(name: string, fields: string[]): ToolRunResult {
  return bad(name, 'missing_fields', `정보 부족: ${fields.join(', ')}`, {
    missing: fields,
    next: '제안하지 않았다. 빠진 내용을 사용자에게 물어본 뒤 답을 받아 다시 제안한다.',
  });
}

const PROPOSED_NOTE = '제안 카드가 사용자에게 보였다. 아직 실행되지 않았다. 사용자가 승인해야 실행된다. 실행됐다고 말하지 않는다.';

export function folderPaths(folders: TreeFolderRow[]): Map<string, string> {
  const byId = new Map(folders.map((f) => [f.id, f]));
  const paths = new Map<string, string>();
  for (const f of folders) {
    const names: string[] = [];
    let cur: TreeFolderRow | undefined = f;
    let guard = 0;
    while (cur && guard++ < 14) {
      names.unshift(cur.title);
      cur = cur.parent_id ? byId.get(cur.parent_id) : undefined;
    }
    paths.set(f.id, names.join(' > '));
  }
  return paths;
}

function currentPlacement(items: TreeItemRow[], conversationId: string): { placed: boolean; folderId: string | null } {
  const node = items.find((i) => i.kind === 'conversation' && i.conversation_id === conversationId);
  return node ? { placed: true, folderId: node.parent_id } : { placed: false, folderId: null };
}

function placementLabel(p: { placed: boolean; folderId: string | null }, paths: Map<string, string>): string {
  if (!p.placed) return '정리 안 됨';
  if (!p.folderId) return '최상위';
  return paths.get(p.folderId) ?? '알 수 없는 폴더';
}

function codeSpec(args: Record<string, unknown>, ctx: ActionToolContext, plan: boolean) {
  const spec: Record<string, unknown> = {
    goal: str(args.goal, 2000) ?? '',
    questions: list(args.questions),
    focus_paths: list(args.focus_paths, 12, 200),
    constraints: list(args.constraints),
    do_not: list(args.do_not),
    background: str(args.background, 6000) ?? '',
    memory_refs: ctx.memoryRefs.slice(0, 8),
    effort: normalizeEffort(args.effort),
    effort_reason: effortReason(args.effort_reason),
  };
  if (plan) spec.instructions = list(args.instructions, 20, 1000);
  return spec;
}

function latestSummary(d: CodeRequestDetail | null): Record<string, unknown> | null {
  const r = d?.latest?.result;
  if (!r) return null;
  const pick: Record<string, unknown> = {};
  for (const k of ['summary', 'feasibility', 'answers', 'findings', 'proposals', 'risks', 'questions_for_think', 'diff_stats', 'files']) {
    if (r[k] !== undefined) pick[k] = r[k];
  }
  return pick;
}

const PLAN_STARTED_NOTE =
  'Cursor와 조율을 시작했다(읽기 전용). 아직 코드는 바뀌지 않았다. 조율이 끝나면 물을 것이 없을 때 조율본대로 바로 수정과 자동 검사가 이어지고, ' +
  '물을 것이 있으면 조율본 카드에 질문이 올라온다. 작업 폴더 적용은 사용자가 따로 승인한다. ' +
  '답변에는 조율을 시작했고 결과는 몇 분 뒤 이 대화에 붙는다고만 짧게 알린다.';

async function proposeCode(name: string, args: Record<string, unknown>, src: ActionToolSource, ctx: ActionToolContext): Promise<ToolRunResult> {
  const plan = name === 'start_code_plan';
  const title = str(args.title, 120);
  const spec = codeSpec(args, ctx, plan);
  const need: string[] = [];
  if (!title) need.push('title');
  if (!spec.goal) need.push('goal');
  if (plan && (spec.instructions as string[]).length === 0) need.push('instructions');
  if (need.length > 0) return missing(name, need);

  if (plan && args.based_on_request_id != null) {
    const baseId = uuid(args.based_on_request_id);
    const base = baseId ? await src.getCodeRequest(baseId) : null;
    if (!base) return bad(name, 'based_on_request_not_found', '근거 요청 없음');
    const summary = latestSummary(base);
    spec.based_on = { id: base.id, title: base.title, summary: summary?.summary ?? null, proposals: summary?.proposals ?? [] };
  }
  if (plan && args.continue_from_request_id != null) {
    const prevId = uuid(args.continue_from_request_id);
    const prev = prevId ? await src.getCodeRequest(prevId) : null;
    if (!prev) {
      return bad(name, 'continue_from_not_found', '이어받을 요청 없음', { next: '작업 상태 메모의 전체 id(uuid)로 다시 준다. 앞 8자리만으로는 찾지 못한다.' });
    }
    if (prev.mode !== 'change') return bad(name, 'continue_from_not_change', '코드 수정 요청이 아님', { mode: prev.mode });
    spec.continue_from = { request_id: prev.id, title: prev.title };
  }
  if (plan) {
    let row: ActionRow;
    try {
      row = await src.startCodePlan(ctx.conversationId, title!, spec);
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e);
      if (message.includes('code_request_daily_limit')) {
        return bad(name, 'daily_limit', '하루 한도 초과', { next: '오늘 Cursor 요청 한도를 다 썼다고 알리고, 사용량 탭에서 한도를 늘리거나 내일 다시 하자고 안내한다.' });
      }
      throw e;
    }
    return out(name, { ok: true, code_request_id: row.result?.code_request_id ?? null, status: 'started', note: PLAN_STARTED_NOTE }, `"${title}" 조율 시작`, row);
  }
  const preview: Record<string, unknown> = {
    title,
    goal: clip(String(spec.goal), 300),
    questions: (spec.questions as string[]).length,
    focus_paths: spec.focus_paths,
    mode: 'investigate',
    effort: spec.effort,
  };
  const row = await src.proposeAction(ctx.conversationId, 'code_request', { title, spec }, preview);
  return out(name, { ok: true, action_id: row.id, status: 'proposed', note: PROPOSED_NOTE }, `"${title}" 제안`, row);
}

async function proposeFolder(name: string, args: Record<string, unknown>, src: ActionToolSource, ctx: ActionToolContext): Promise<ToolRunResult> {
  const folderIdRaw = args.folder_id;
  const newTitle = str(args.new_folder_title, 120);
  const reason = str(args.reason, 300) ?? '';
  if (folderIdRaw == null && !newTitle) return missing(name, ['folder_id 또는 new_folder_title']);
  if (folderIdRaw != null && newTitle) return bad(name, 'choose_one', '폴더 지정 중복', { next: '기존 폴더(folder_id)와 새 폴더(new_folder_title) 중 하나만 준다.' });

  const tree = await src.listTreeFolders();
  const paths = folderPaths(tree.folders);
  const current = currentPlacement(tree.items, ctx.conversationId);
  let payload: Record<string, unknown>;
  let path: string;
  if (folderIdRaw != null) {
    const folderId = uuid(folderIdRaw);
    if (!folderId || !paths.has(folderId)) return bad(name, 'folder_not_found', '폴더 없음', { next: 'list_tree_folders로 id를 다시 확인한다.' });
    if (current.placed && current.folderId === folderId) return bad(name, 'already_in_folder', '이미 그 폴더에 있음');
    payload = { folder_id: folderId };
    path = paths.get(folderId)!;
  } else {
    const parentRaw = args.new_folder_parent_id;
    const parentId = parentRaw == null ? null : uuid(parentRaw);
    if (parentRaw != null && (!parentId || !paths.has(parentId))) {
      return bad(name, 'parent_not_found', '상위 폴더 없음', { next: 'list_tree_folders로 id를 다시 확인한다.' });
    }
    payload = { new_folder_title: newTitle, new_folder_parent_id: parentId };
    path = parentId ? `${paths.get(parentId)} > ${newTitle}` : newTitle!;
  }
  const preview = { path, is_new: newTitle != null, current: placementLabel(current, paths), reason };
  const row = await src.proposeAction(ctx.conversationId, 'place_conversation', payload, preview);
  return out(name, { ok: true, action_id: row.id, status: 'proposed', note: PROPOSED_NOTE }, path, row);
}

async function proposeDelete(name: string, args: Record<string, unknown>, src: ActionToolSource, ctx: ActionToolContext): Promise<ToolRunResult> {
  const kind = args.target_kind;
  const targetId = uuid(args.target_id);
  const reason = str(args.reason, 300) ?? '';
  if (!targetId) return missing(name, ['target_id']);
  let actionKind: ActionKind;
  let preview: Record<string, unknown>;
  if (kind === 'code_request') {
    const r = await src.getCodeRequest(targetId);
    if (!r) return bad(name, 'not_found', '요청 없음');
    if (!DELETABLE_CODE_STATUSES.includes(r.status)) {
      return bad(name, 'not_deletable', '진행 중이라 삭제 불가', { status: r.status, next: '진행 중인 요청은 먼저 취소해야 한다고 사용자에게 알린다.' });
    }
    actionKind = 'delete_code_request';
    preview = { title: r.title, status: r.status, mode: r.mode, reason };
  } else if (kind === 'folder') {
    const tree = await src.listTreeFolders();
    const paths = folderPaths(tree.folders);
    if (!paths.has(targetId)) return bad(name, 'not_found', '폴더 없음');
    const children = tree.folders.filter((f) => f.parent_id === targetId).length + tree.items.filter((i) => i.parent_id === targetId).length;
    actionKind = 'delete_folder';
    preview = { path: paths.get(targetId), children, reason };
  } else if (kind === 'conversation') {
    const s = await src.conversationStats(targetId);
    if (!s) return bad(name, 'not_found', '대화 없음');
    actionKind = 'delete_conversation';
    preview = {
      title: s.title,
      messages: s.messages,
      excerpts: s.excerpts,
      documents: s.documents,
      code_requests: s.code_requests,
      is_current: targetId === ctx.conversationId,
      reason,
    };
  } else {
    return missing(name, ['target_kind']);
  }
  const row = await src.proposeAction(ctx.conversationId, actionKind, { target_id: targetId }, preview);
  return out(name, { ok: true, action_id: row.id, status: 'proposed', note: PROPOSED_NOTE }, String(preview.title ?? preview.path ?? ''), row);
}

const SPLIT_PROPOSED_NOTE =
  '나누기 제안 카드가 사용자에게 보였다. 아직 새 대화는 만들어지지 않았다. 사용자가 "나눠서 이어가기"를 눌러야 만들어지고 원본 대화는 그대로 남는다. ' +
  '질문에는 이 대화에서 끝까지 답하고, 답변 끝에 새 대화로 나누자고 제안했다고 한 줄로 알린다.';

const SPLIT_ERRORS: [code: string, summary: string, next: string][] = [
  ['split_suppressed', '자동 제안 꺼짐', '사용자가 이 대화에서 나누기 제안을 거절했다. 다시 제안하지 않고 답변만 한다.'],
  ['split_expired', '범위 만료', '대화가 이어져 이번 문답으로 나눌 수 없다. 제안하지 않고 답변만 한다.'],
  ['split_nothing_before', '앞 대화 없음', '이 대화의 첫 문답이라 나눌 필요가 없다. 답변만 한다.'],
  ['split_range_invalid', '범위 확인 실패', '제안하지 않고 답변만 한다.'],
  ['tree_folder_not_found', '폴더 없음', 'list_tree_folders로 id를 다시 확인하거나 folder_id를 null(미분류)로 준다.'],
];

async function proposeSplit(name: string, args: Record<string, unknown>, src: ActionToolSource, ctx: ActionToolContext): Promise<ToolRunResult> {
  const split = ctx.split;
  if (!split) {
    return bad(name, 'split_unavailable', '지금은 나눌 수 없음', { next: '실행 환경 기능 상태 메모를 따른다. 제안하지 않고 답변만 한다.' });
  }
  if (split.proposed) return bad(name, 'split_already_proposed', '이미 제안함', { next: '한 답변에 나누기 제안은 하나만 한다.' });
  const title = str(args.title, 120);
  const raw = args.summary && typeof args.summary === 'object' && !Array.isArray(args.summary) ? (args.summary as Record<string, unknown>) : {};
  const summary = {
    purpose: str(raw.purpose, 2000) ?? '',
    background: str(raw.background, 4000) ?? '',
    decided: list(raw.decided),
    open: list(raw.open),
    next: list(raw.next),
  };
  const need: string[] = [];
  if (!title) need.push('title');
  if (!summary.purpose) need.push('summary.purpose');
  if (need.length > 0) {
    return bad(name, 'missing_fields', `정보 부족: ${need.join(', ')}`, {
      missing: need,
      next: '채워서 다시 제안하거나, 새 주제인지 확신이 없으면 제안하지 않는다.',
    });
  }

  let folderId: string | null = null;
  let folderPath: string | null = null;
  if (args.folder_id != null) {
    folderId = uuid(args.folder_id);
    const paths = folderPaths((await src.listTreeFolders()).folders);
    if (!folderId || !paths.has(folderId)) {
      return bad(name, 'folder_not_found', '폴더 없음', { next: 'list_tree_folders로 id를 다시 확인하거나, 맞는 폴더가 없으면 folder_id를 null(미분류)로 준다.' });
    }
    folderPath = paths.get(folderId)!;
  }
  const reason = str(args.reason, 500) ?? '';
  let row: ActionRow;
  try {
    row = await src.proposeSplit(
      ctx.conversationId,
      split.userMessageId,
      { title, reason, summary, folder_id: folderId },
      { folder_path: folderPath, reason },
      split.userRequested,
    );
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    const known = SPLIT_ERRORS.find(([code]) => message.includes(code));
    if (known) return bad(name, known[0], known[1], { next: known[2] });
    throw e;
  }
  split.proposed = true;
  return out(name, { ok: true, action_id: row.id, status: 'proposed', note: SPLIT_PROPOSED_NOTE }, `"${title}"`, row);
}

const MEMORY_PROPOSED_NOTE =
  '기억 저장 카드가 사용자에게 보였다. 아직 저장되지 않았다. 사용자가 카드에서 승인해야 저장된다. ' +
  '답변 끝에 무엇을 기억으로 남기자고 제안했는지 한 줄로 알리고, 저장됐다고 말하지 않는다.';

/** 모델이 준 기억 내용을 정리한다. 최종 검사·중복 확인은 DB(ai_memory_proposal_clean·guard)가 한다. */
function memoryPayload(raw: unknown): { memory: Record<string, unknown>; missing: string[] } {
  const m = raw && typeof raw === 'object' && !Array.isArray(raw) ? (raw as Record<string, unknown>) : {};
  const kind = m.kind === 'decision' || m.kind === 'principle' ? m.kind : null;
  const decision = kind === 'decision';
  const scope = m.memory_scope === 'department' ? 'department' : 'common';
  const dept = typeof m.scope_department === 'string' && ['education', 'product', 'engineering'].includes(m.scope_department)
    ? m.scope_department
    : null;
  const memory = {
    kind,
    title: str(m.title, 200),
    content: str(m.content, 8000),
    decision_context: decision ? str(m.decision_context, 4000) : null,
    decision_reason: decision ? str(m.decision_reason, 4000) : null,
    alternatives: decision ? list(m.alternatives) : [],
    tags: list(m.tags, 12, 60),
    memory_scope: scope,
    scope_department: scope === 'department' ? dept : null,
    supersedes_id: m.supersedes_id == null ? null : uuid(m.supersedes_id) ?? String(m.supersedes_id).slice(0, 64),
  };
  const need: string[] = [];
  if (!kind) need.push('memory.kind');
  if (!memory.title) need.push('memory.title');
  if (!memory.content) need.push('memory.content');
  if (scope === 'department' && !dept) need.push('memory.scope_department');
  return { memory, missing: need };
}

const MEMORY_ERRORS: [code: string, summary: string, next: string][] = [
  [
    'memory_duplicate_active',
    '같은 기억이 이미 있음',
    '같은 제목의 확정 기억(memory_id)이 있다. 내용도 같으면 제안하지 않고 이미 기억에 있다고 알린다. ' +
    '바뀐 내용이면 get_memory로 확인한 뒤 supersedes_id에 그 id를 넣어 대체를 제안한다.',
  ],
  [
    'memory_proposal_pending',
    '같은 취지의 카드가 대기 중',
    '같은 취지의 기억 저장 카드(pending_action_id)가 이미 대기 중이다. 새로 제안하지 않는다. 사용자에게 그 카드가 있다고 알리고, ' +
    '내용을 고치거나 새 카드로 바꾸거나 없애야 하면 propose_memory_card_change로 제안한다. 그대로면 그 카드를 승인해 달라고만 한다.',
  ],
  ['memory_card_change_pending', '변경 카드가 이미 대기 중', '그 카드에 대한 변경 제안(pending_action_id)이 이미 대기 중이다. 다시 제안하지 않는다.'],
  ['memory_card_not_pending', '대기 중인 카드가 아님', '이미 처리됐거나 없는 카드다. 작업 상태 메모를 다시 보고, 필요하면 새로 제안한다.'],
  ['memory_supersede_not_active', '대체할 기억이 확정 상태가 아님', 'search_memories로 지금 확정된 기억 id를 다시 찾아 준다. 없으면 supersedes_id를 null로 둔다.'],
  ['scope_department_required', '부서 없음', '부서 범위면 scope_department를 준다. 모든 부서에 해당하면 common으로 둔다.'],
  ['memory_kind_invalid', '종류 오류', 'kind는 decision 또는 principle이다.'],
  ['memory_scope_invalid', '범위 오류', 'memory_scope는 common 또는 department다.'],
];

const UUID_IN_RE = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;

function memoryError(name: string, e: unknown): ToolRunResult {
  const message = e instanceof Error ? e.message : String(e);
  const known = MEMORY_ERRORS.find(([code]) => message.includes(code));
  if (!known) throw e;
  const id = message.slice(message.indexOf(known[0])).match(UUID_IN_RE)?.[0] ?? null;
  const extra: Record<string, unknown> = { next: known[2] };
  if (id && known[0] === 'memory_duplicate_active') extra.memory_id = id;
  else if (id) extra.pending_action_id = id;
  return bad(name, known[0], known[1], extra);
}

async function proposeMemory(name: string, args: Record<string, unknown>, src: ActionToolSource, ctx: ActionToolContext): Promise<ToolRunResult> {
  const mem = ctx.memory;
  if (!mem) return bad(name, 'memory_unavailable', '지금은 제안할 수 없음', { next: '실행 환경 기능 상태 메모를 따른다. 제안하지 않는다.' });
  if (mem.proposed) return bad(name, 'memory_already_proposed', '이미 제안함', { next: '한 답변에 기억 카드는 하나만 낸다.' });
  const { memory, missing: need } = memoryPayload(args.memory);
  if (need.length > 0) return missing(name, need);
  const reason = str(args.reason, 500);
  let row: ActionRow;
  try {
    row = await src.proposeAction(ctx.conversationId, 'save_memory', { memory, reason }, {});
  } catch (e) {
    return memoryError(name, e);
  }
  mem.proposed = true;
  return out(name, { ok: true, action_id: row.id, status: 'proposed', note: MEMORY_PROPOSED_NOTE }, `"${memory.title}"`, row);
}

const MEMORY_CHANGE_NOTE =
  '기억 카드 변경 제안이 사용자에게 보였다. 사용자가 승인해야 대기 카드가 바뀐다. 아직 바뀌지 않았다고 알고, 바뀌었다고 말하지 않는다.';

async function proposeMemoryChange(
  name: string,
  args: Record<string, unknown>,
  src: ActionToolSource,
  ctx: ActionToolContext,
): Promise<ToolRunResult> {
  const mem = ctx.memory;
  if (!mem) return bad(name, 'memory_unavailable', '지금은 제안할 수 없음', { next: '실행 환경 기능 상태 메모를 따른다. 제안하지 않는다.' });
  if (mem.proposed) return bad(name, 'memory_already_proposed', '이미 제안함', { next: '한 답변에 기억 카드는 하나만 낸다.' });
  const target = uuid(args.target_action_id);
  const op = args.op === 'revise' || args.op === 'replace' || args.op === 'withdraw' ? args.op : null;
  const need: string[] = [];
  if (!target) need.push('target_action_id');
  if (!op) need.push('op');
  let memory: Record<string, unknown> | null = null;
  if (op && op !== 'withdraw') {
    const parsed = memoryPayload(args.memory);
    memory = parsed.memory;
    need.push(...parsed.missing);
  }
  if (need.length > 0) return missing(name, need);
  const reason = str(args.reason, 500);
  let row: ActionRow;
  try {
    row = await src.proposeAction(ctx.conversationId, 'memory_card_change', { target_action_id: target, op, memory, reason }, {});
  } catch (e) {
    return memoryError(name, e);
  }
  mem.proposed = true;
  return out(name, { ok: true, action_id: row.id, status: 'proposed', note: MEMORY_CHANGE_NOTE }, `${op} "${row.preview?.target_title ?? ''}"`, row);
}

export async function dispatchActionTool(
  name: string,
  args: Record<string, unknown>,
  src: ActionToolSource,
  ctx: ActionToolContext | undefined,
): Promise<ToolRunResult> {
  switch (name) {
    case 'list_tree_folders': {
      const tree = await src.listTreeFolders();
      const paths = folderPaths(tree.folders);
      const counts = new Map<string, number>();
      for (const n of [...tree.folders, ...tree.items]) {
        if (n.parent_id) counts.set(n.parent_id, (counts.get(n.parent_id) ?? 0) + 1);
      }
      const folders = tree.folders.map((f) => ({ id: f.id, path: paths.get(f.id), items: counts.get(f.id) ?? 0 }));
      const current = ctx ? currentPlacement(tree.items, ctx.conversationId) : null;
      return out(
        name,
        { folders, current_conversation: current ? { folder_id: current.folderId, location: placementLabel(current, paths) } : null },
        `폴더 ${folders.length}개`,
      );
    }
    case 'list_conversations': {
      const rows = await src.listConversations(str(args.query, 100), int(args.limit, 10, 1, 20));
      return out(name, rows, `${rows.length}건`);
    }
    case 'list_code_requests': {
      const rows = await src.listCodeRequests(str(args.query, 100), 20);
      return out(name, rows, `${rows.length}건`);
    }
    case 'get_code_request': {
      const id = uuid(args.id);
      if (!id) return bad(name, 'invalid_id', 'id 형식 오류');
      const d = await src.getCodeRequest(id);
      if (!d) return bad(name, 'not_found', '찾을 수 없음');
      return out(
        name,
        {
          id: d.id,
          title: d.title,
          status: d.status,
          mode: d.mode,
          round: d.round,
          max_rounds: d.max_rounds,
          request: d.request,
          last_error: d.last_error,
          result: latestSummary(d),
          result_text_head: d.latest?.result_text ? clip(d.latest.result_text, 3000) : null,
        },
        d.title,
      );
    }
  }
  if (!ctx) return bad(name, 'no_conversation', '대화 없음');
  switch (name) {
    case 'propose_code_request':
    case 'start_code_plan':
      return await proposeCode(name, args, src, ctx);
    case 'propose_folder':
      return await proposeFolder(name, args, src, ctx);
    case 'propose_delete':
      return await proposeDelete(name, args, src, ctx);
    case SPLIT_TOOL_NAME:
      return await proposeSplit(name, args, src, ctx);
    case MEMORY_TOOL_NAME:
      return await proposeMemory(name, args, src, ctx);
    case MEMORY_CHANGE_TOOL_NAME:
      return await proposeMemoryChange(name, args, src, ctx);
    default:
      return bad(name, 'unknown_tool', '알 수 없는 도구');
  }
}

// ---------------------------------------------------------------------------
// "이 대화의 작업 상태" 맥락 블록
// ---------------------------------------------------------------------------

const KIND_LABELS: Record<string, string> = {
  code_request: '코드 조사 제안',
  code_change: '코드 수정 제안(조율본)',
  code_plan: 'Cursor와 조율',
  place_conversation: '분류 제안',
  delete_code_request: '코드 요청 삭제 제안',
  delete_folder: '폴더 삭제 제안',
  delete_conversation: '대화 삭제 제안',
  split_conversation: '대화 나누기 제안',
  save_memory: '기억 저장 제안',
  memory_card_change: '기억 카드 변경 제안',
};

const MEMORY_CHANGE_OPS: Record<string, string> = { revise: '수정', replace: '새 카드로 대체', withdraw: '삭제' };

const ACTION_STATUS_LABELS: Record<string, string> = {
  proposed: '사용자 확인 대기',
  applied: '사용자가 승인해 실행됨',
  rejected: '사용자가 거절함',
  failed: '실행 실패',
  undone: '사용자가 되돌림',
  expired: '대화가 이어져 만료됨',
};

export const CODE_STATUS_LABELS: Record<string, string> = {
  draft: '초안',
  queued: '대기 중',
  running: '진행 중',
  followup_queued: '다음 회차 대기',
  ready: '결과 도착',
  needs_review: '결과 도착(형식 확인 필요)',
  failed: '실패',
  cancelled: '취소됨',
  apply_queued: '적용 대기',
  applying: '적용 중',
  applied: '작업 폴더에 적용됨',
  apply_failed: '적용 실패(아무것도 바뀌지 않음)',
  revert_queued: '되돌리기 대기',
  reverting: '되돌리는 중',
  reverted: '되돌림',
  revert_failed: '되돌리기 실패',
};

function actionLine(a: ActionRow): string {
  const p = a.preview ?? {};
  const what = String(p.path ?? p.title ?? '');
  const label = a.superseded ? '새 제안으로 대체됨' : ACTION_STATUS_LABELS[a.status] ?? a.status;
  let extra = a.status === 'failed' && a.error ? ` (${clip(a.error, 120)})` : '';
  if (a.kind === 'split_conversation' && a.status === 'applied') extra = ' (새 대화로 나눔. 이 대화는 그대로 남아 있다)';
  if (a.kind === 'save_memory') {
    if (a.status === 'proposed') extra = ` (카드 id: ${a.id})`;
    else if (a.status === 'applied') extra = ' (확정 기억으로 저장됨)';
    else if (a.result?.withdrawn_by_action_id) extra = ' (삭제 제안 승인으로 닫힘)';
  }
  if (a.kind === 'memory_card_change') {
    extra = ` (${MEMORY_CHANGE_OPS[String(p.op)] ?? String(p.op)}, 대상 "${clip(String(p.target_title ?? ''), 60)}")`;
  }
  return `- ${KIND_LABELS[a.kind] ?? a.kind}${what ? ` "${clip(what, 80)}"` : ''}: ${label}${extra}`;
}

/** 수정 결과의 자동 검사 요약. 미실행은 통과로 세지 않는다. */
export function verificationLine(v: unknown): string {
  const items = v && typeof v === 'object' && Array.isArray((v as Record<string, unknown>).items)
    ? ((v as Record<string, unknown>).items as unknown[])
    : null;
  if (!items) return '자동 검사: 기록 없음';
  const n = (s: string) => items.filter((i) => i && typeof i === 'object' && (i as Record<string, unknown>).status === s).length;
  const known = n('passed') + n('failed') + n('preexisting');
  return `자동 검사: 통과 ${n('passed')} · 실패 ${n('failed')} · 미실행 ${items.length - known} · 원래도 실패 ${n('preexisting')}`;
}

function codeLine(r: CodeRequestDetail): string {
  const mode = r.mode === 'change' ? '코드 수정' : r.mode === 'plan' ? 'Cursor와 조율' : '코드 조사';
  const parts = [`- ${mode} "${clip(r.title, 80)}" (id: ${r.id}): ${CODE_STATUS_LABELS[r.status] ?? r.status}`];
  if (r.mode === 'plan' && r.round > 0) parts.push(`${r.round}/${r.max_rounds}회`);
  const res = r.latest?.result;
  if (res && typeof res.summary === 'string') parts.push(`결론: ${clip(res.summary, 200)}`);
  const stopped = res?.partial === 'timeout' ||
    (typeof res?.summary === 'string' && res.summary.startsWith('30분 안에 끝나지 않아 멈췄습니다'));
  if (r.mode === 'change' && r.status === 'needs_review' && stopped) {
    parts.push('시간 제한으로 멈춘 미완성 패치(검사 안 됨, 이어받기만 가능)');
  }
  if (res && r.mode === 'change' && res.diff_stats && typeof res.diff_stats === 'object') {
    const s = res.diff_stats as Record<string, unknown>;
    parts.push(`변경: 파일 ${s.files ?? '?'}개 +${s.additions ?? '?'} -${s.deletions ?? '?'}`);
    parts.push(verificationLine(res.verification));
  }
  const fix = r.request && typeof r.request.fix_of === 'object' && r.request.fix_of ? (r.request.fix_of as Record<string, unknown>) : null;
  if (r.mode === 'change' && fix) parts.push(`검사 실패로 다시 고친 ${fix.attempt ?? '?'}번째 요청(앞 요청 id: ${fix.request_id ?? '?'})`);
  const from = r.request && typeof r.request.continue_from === 'object' && r.request.continue_from
    ? (r.request.continue_from as Record<string, unknown>)
    : null;
  if (from) parts.push(`앞 수정 ${from.request_id ?? '?'}의 최종 패치를 이어받음`);
  if (r.last_error && ['failed', 'apply_failed', 'revert_failed'].includes(r.status)) parts.push(`오류: ${clip(r.last_error, 150)}`);
  if (r.review_status === 'done') parts.push('검토 답변이 대화에 붙음');
  return parts.join(' / ');
}

/** 대화 기록 뒤, 이번 질문 앞에 넣는다. 작업이 없으면 null. */
export function workStateNote(state: WorkState): string | null {
  if (state.actions.length === 0 && state.codeRequests.length === 0) return null;
  const lines = ['[이 대화의 작업 상태. 최신이 위. 사용자가 카드에서 승인·거절한 결과이며, 진행 상황을 물으면 이것을 근거로 답한다.]'];
  const actions = state.actions.filter((a) => !['code_request', 'code_change', 'code_plan'].includes(a.kind) || a.status !== 'applied');
  for (const a of actions.slice(0, 10)) lines.push(actionLine(a));
  for (const r of state.codeRequests.slice(0, 8)) lines.push(codeLine(r));
  return lines.join('\n');
}
