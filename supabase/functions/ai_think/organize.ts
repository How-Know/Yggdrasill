// Think 자동 정리 제안: 맥락 제외·중요 표시·진행 요약·부서 기준 변경(운영자 결정 2026-10-12).
// 제안 도구는 전용 RPC로 ai_actions에 제안 1행만 남긴다. 실행은 사용자가 카드나 정리 패널에서 승인할 때 ai_action_apply가 한다.
// 메시지 id는 list_conversation_messages로만 얻는다. 맥락에서 제외된 메시지는 거기에도 나오지 않는다.
// 설계: docs/architecture/ai-think-actions.md §11

import type { AiFunctionTool } from '../_shared/ai/types.ts';
import type { ActionRow, ActionToolContext } from './actions.ts';
import { clip } from './prompts.ts';
import type { ToolRunResult } from './tools.ts';

export const LIST_MESSAGES_TOOL_NAME = 'list_conversation_messages';
export const EXCLUSION_TOOL_NAME = 'propose_context_exclusion';
export const IMPORTANCE_TOOL_NAME = 'propose_importance_mark';
export const SUMMARY_TOOL_NAME = 'propose_progress_summary';
export const CRITERIA_TOOL_NAME = 'propose_department_criteria_change';

/** 정리 도구 전체. 부서 기준 도구는 역할이 적용된 대화에서만 준다. */
export const ORGANIZE_TOOL_NAMES = new Set([
  LIST_MESSAGES_TOOL_NAME,
  EXCLUSION_TOOL_NAME,
  IMPORTANCE_TOOL_NAME,
  SUMMARY_TOOL_NAME,
  CRITERIA_TOOL_NAME,
]);
export const ORGANIZE_PROPOSE_TOOL_NAMES = new Set([EXCLUSION_TOOL_NAME, IMPORTANCE_TOOL_NAME, SUMMARY_TOOL_NAME, CRITERIA_TOOL_NAME]);

export const ORGANIZE_TOOL_LABELS: Record<string, string> = {
  [LIST_MESSAGES_TOOL_NAME]: '대화 메시지 확인',
  [EXCLUSION_TOOL_NAME]: '맥락 제외 제안',
  [IMPORTANCE_TOOL_NAME]: '중요 표시 제안',
  [SUMMARY_TOOL_NAME]: '진행 요약 제안',
  [CRITERIA_TOOL_NAME]: '부서 기준 변경 제안',
};

export interface OrganizeMessageRow {
  id: string;
  role: 'user' | 'assistant';
  content: string;
  created_at: string;
  marked_important: boolean;
}

export interface ProgressNextAction {
  what: string;
  owner: string;
  prerequisite: string;
  done_when: string;
}

export interface ProgressSummaryInput {
  purpose: string;
  decided: string[];
  open: string[];
  status: string;
  next: ProgressNextAction[];
}

export interface CriteriaInput {
  questions: string[];
  risks: string[];
  priority_memory_ids: string[];
}

export interface DepartmentCriteria extends CriteriaInput {
  department: string;
  version: number;
}

export interface OrganizeToolSource {
  /** 이 대화에서 맥락에 들어가는(제외되지 않은) 최근 메시지. 오래된 것부터. */
  listOrganizeMessages?(conversationId: string, limit: number): Promise<OrganizeMessageRow[]>;
  proposeExclusion?(conversationId: string, messageIds: string[], reason: string, impact: string, userRequested: boolean): Promise<ActionRow>;
  proposeImportance?(conversationId: string, messageIds: string[], reason: string, userRequested: boolean): Promise<ActionRow>;
  proposeProgressSummary?(conversationId: string, summary: ProgressSummaryInput, reason: string, throughMessageId: string): Promise<ActionRow>;
  proposeCriteriaChange?(conversationId: string, department: string, criteria: CriteriaInput, reason: string): Promise<ActionRow>;
}

/** 이번 턴에 정리 도구를 줄 때만 채운다(기능 준비됨, 커서 질문 아님, 자동 제안이 켜져 있거나 사용자가 직접 요청). */
export interface OrganizeToolContext {
  /** 이번 질문(사용자 메시지) id. 진행 요약이 반영한 마지막 메시지로 남긴다. */
  userMessageId: string;
  /** 부서 기준 도구를 쓸 수 있으면 이 대화의 부서. 아니면 null. */
  criteriaDepartment: string | null;
  /** 사용자가 이번 메시지에서 직접 빼 달라고/중요 표시해 달라고 했는지. 거절한 같은 묶음을 다시 낼 수 있다. */
  userAskedExclusion: boolean;
  userAskedImportance: boolean;
  /** 한 답변에 종류마다 하나. 제안한 도구 이름을 담는다. */
  proposed: Set<string>;
}

const nullable = (schema: Record<string, unknown>) => ({ ...schema, type: [schema.type, 'null'] });
const textList = (description: string) => ({ type: 'array', items: { type: 'string' }, description });

export const ORGANIZE_TOOLS: AiFunctionTool[] = [
  {
    name: LIST_MESSAGES_TOOL_NAME,
    description:
      '이 대화의 최근 메시지 목록(id, 역할, 짧은 발췌, 중요 표시 여부)을 가져온다. 맥락 제외·중요 표시를 제안하기 전에 대상 id를 확인할 때 쓴다. ' +
      '맥락에서 제외된 메시지는 나오지 않는다. 다른 대화는 볼 수 없다.',
    parameters: {
      type: 'object',
      properties: { limit: nullable({ type: 'integer', description: '최대 개수(1~30). 기본 20이면 null.' }) },
      required: ['limit'],
      additionalProperties: false,
    },
  },
  {
    name: EXCLUSION_TOOL_NAME,
    description:
      '정정돼 더 이상 맞지 않는 설명이나 폐기한 접근처럼, 앞으로 참고하면 혼동되는 메시지를 이후 답변 맥락에서 빼자고 카드로 제안한다. ' +
      '메시지는 지워지지 않고 화면에 남으며, 사용자가 승인해야 빠진다. 비판·실패 기록·의견 차이를 감추려고 쓰지 않는다.',
    parameters: {
      type: 'object',
      properties: {
        message_ids: textList('뺄 메시지 id(list_conversation_messages에서 확인). 최대 20개'),
        reason: { type: 'string', description: '무엇이 어떻게 정정되거나 폐기됐는지 구체적으로 한두 문장' },
        impact: { type: 'string', description: '빼면 이후 답변이 무엇을 참고하지 않게 되는지 한 문장' },
      },
      required: ['message_ids', 'reason', 'impact'],
      additionalProperties: false,
    },
  },
  {
    name: IMPORTANCE_TOOL_NAME,
    description:
      '중요한 결정·할 일·미결 문제가 나온 메시지에 중요 표시를 하자고 카드로 제안한다. 화면에서 눈여겨볼 표시일 뿐 원칙이나 지시가 아니다. ' +
      '사용자가 승인해야 표시된다.',
    parameters: {
      type: 'object',
      properties: {
        message_ids: textList('표시할 메시지 id(list_conversation_messages에서 확인). 최대 10개'),
        reason: { type: 'string', description: '그 메시지에 무엇(결정·할 일·미결 문제)이 있는지 한 문장' },
      },
      required: ['message_ids', 'reason'],
      additionalProperties: false,
    },
  },
  {
    name: SUMMARY_TOOL_NAME,
    description:
      '논의가 한 단락 정리됐을 때 이 대화의 진행 요약(목적·확정·미결·진행 상태·다음 행동)을 카드로 제안한다. 사용자가 승인하면 이 대화의 ' +
      '진행 요약이 되고 다음 답변부터 참고 자료로 들어간다. 승인돼도 코드 작업·배포·DB 변경은 시작되지 않는다.',
    parameters: {
      type: 'object',
      properties: {
        summary: {
          type: 'object',
          properties: {
            purpose: { type: 'string', description: '이 대화의 목적 한두 문장' },
            decided: textList('사용자가 확정한 것만. 네 제안이나 답하지 않은 것은 넣지 않는다'),
            open: textList('아직 정하지 않은 것'),
            status: { type: 'string', description: '지금 어디까지 왔는지 한두 문장' },
            next: {
              type: 'array',
              description: '다음 행동. 최대 10개',
              items: {
                type: 'object',
                properties: {
                  what: { type: 'string', description: '할 일' },
                  owner: nullable({ type: 'string', description: '담당(부서·사람). 사용자가 말했을 때만, 아니면 null' }),
                  prerequisite: nullable({ type: 'string', description: '먼저 필요한 것. 없으면 null' }),
                  done_when: nullable({ type: 'string', description: '무엇으로 완료를 판단하는지. 모르면 null' }),
                },
                required: ['what', 'owner', 'prerequisite', 'done_when'],
                additionalProperties: false,
              },
            },
          },
          required: ['purpose', 'decided', 'open', 'status', 'next'],
          additionalProperties: false,
        },
        reason: { type: 'string', description: '왜 지금 요약을 제안하는지 한 문장' },
      },
      required: ['summary', 'reason'],
      additionalProperties: false,
    },
  },
  {
    name: CRITERIA_TOOL_NAME,
    description:
      '이 대화 부서의 기준(우선 확인할 질문·놓치면 안 되는 위험·우선 참고할 승인 기억)을 바꾸자고 카드로 제안한다. 사용자가 그 기준을 정했을 때만 쓴다. ' +
      '바꾼 뒤의 기준 전체를 준다(지시문의 "이 부서의 기준"이 지금 값). 사용자가 승인해야 바뀐다.',
    parameters: {
      type: 'object',
      properties: {
        questions: textList('이 부서가 답할 때 먼저 확인할 질문. 최대 8개'),
        risks: textList('이 부서가 놓치면 안 되는 위험. 최대 8개'),
        priority_memory_ids: textList('우선 참고할 확정 기억 id(공통이거나 이 부서 범위). 최대 8개'),
        reason: { type: 'string', description: '사용자가 어느 발언에서 이 기준을 정했는지 한 문장' },
      },
      required: ['questions', 'risks', 'priority_memory_ids', 'reason'],
      additionalProperties: false,
    },
  },
];

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_OUTPUT_CHARS = 12000;

function str(v: unknown, max: number): string | null {
  if (typeof v !== 'string') return null;
  const t = v.trim();
  return t ? t.slice(0, max) : null;
}

function list(v: unknown, maxItems: number, maxChars: number): string[] {
  if (!Array.isArray(v)) return [];
  return v
    .map((x) => (typeof x === 'string' ? x.trim().slice(0, maxChars) : ''))
    .filter(Boolean)
    .slice(0, maxItems);
}

/** 중복을 뺀 uuid 목록. 형식이 틀린 값이 하나라도 있으면 null(추측한 id로 제안하지 않게). */
function ids(v: unknown, max: number): string[] | null {
  if (!Array.isArray(v)) return null;
  const out: string[] = [];
  for (const x of v) {
    if (typeof x !== 'string' || !UUID_RE.test(x.trim())) return null;
    const id = x.trim().toLowerCase();
    if (!out.includes(id)) out.push(id);
  }
  return out.length > max ? null : out;
}

function out(name: string, value: unknown, summary: string, action?: ActionRow): ToolRunResult {
  const text = JSON.stringify(value);
  const output = text.length <= MAX_OUTPUT_CHARS ? text : JSON.stringify({ truncated: true, preview: text.slice(0, MAX_OUTPUT_CHARS) });
  return { name, ok: true, output, summary, action };
}

function bad(name: string, error: string, summary: string, extra: Record<string, unknown> = {}): ToolRunResult {
  return { name, ok: false, output: JSON.stringify({ error, ...extra }), summary };
}

function missing(name: string, fields: string[]): ToolRunResult {
  return bad(name, 'missing_fields', `정보 부족: ${fields.join(', ')}`, {
    missing: fields,
    next: '제안하지 않았다. 빠진 내용을 채울 수 없으면 제안하지 않는다.',
  });
}

const UNAVAILABLE = { next: '실행 환경 기능 상태 메모를 따른다. 제안하지 않는다.' };

/** RPC 오류 코드 → 모델에게 돌려줄 요약과 다음 행동. 모르는 오류는 그대로 올린다(조회 실패로 기록). */
const ORGANIZE_ERRORS: [code: string, summary: string, next: string][] = [
  ['organize_target_missing', '대상 메시지 없음', 'list_conversation_messages로 이 대화의 메시지 id를 다시 확인한다. 추측한 id를 쓰지 않는다.'],
  ['organize_targets_invalid', '대상 없음', '대상 메시지 id를 하나 이상 준다.'],
  ['organize_too_many', '대상이 너무 많음', '대상을 줄인다(맥락 제외 20개, 중요 표시 10개, 우선 기억 8개까지).'],
  ['organize_id_invalid', 'id 형식 오류', 'id는 도구 결과에서 그대로 가져온다.'],
  ['organize_rejected_before', '거절된 제안', '사용자가 같은 메시지에 대한 이 제안을 거절했다. 다시 제안하지 않는다. 사용자가 직접 요청할 때만 다시 낼 수 있다.'],
  ['exclusion_reason_required', '이유 없음', 'reason에 무엇이 어떻게 정정·폐기됐는지 적어 다시 제안한다.'],
  ['exclusion_already_excluded', '이미 제외됨', '이미 맥락에서 빠진 메시지다. 제안하지 않는다.'],
  ['importance_reason_required', '이유 없음', 'reason에 그 메시지에 무엇이 있는지 적어 다시 제안한다.'],
  ['importance_target_excluded', '제외된 메시지', '맥락에서 뺀 메시지에는 중요 표시를 제안하지 않는다.'],
  ['importance_already_marked', '이미 중요 표시됨', '이미 표시된 메시지다. 제안하지 않는다.'],
  ['summary_purpose_required', '목적 없음', 'summary.purpose를 채워 다시 제안한다.'],
  ['criteria_reason_required', '이유 없음', 'reason에 사용자가 어느 발언에서 기준을 정했는지 적는다.'],
  ['criteria_unchanged', '바뀐 것 없음', '지금 기준과 같다. 제안하지 않는다.'],
  ['criteria_memory_not_allowed', '쓸 수 없는 기억', '이 부서가 볼 수 있는 확정 기억(공통·이 부서 범위)만 고른다. 권한을 넓히지 않는다.'],
  ['criteria_department_invalid', '부서 오류', '이 대화의 부서 기준만 바꿀 수 있다.'],
  ['criteria_not_found', '기준 없음', '부서 기준을 찾지 못했다. 사용자에게 알린다.'],
];

function organizeError(name: string, e: unknown): ToolRunResult {
  const message = e instanceof Error ? e.message : String(e);
  const known = ORGANIZE_ERRORS.find(([code]) => message.includes(code));
  if (!known) throw e;
  return bad(name, known[0], known[1], { next: known[2] });
}

const EXCLUSION_NOTE =
  '맥락 제외 카드가 사용자에게 보였다. 아직 빠지지 않았다. 사용자가 승인해야 이후 답변 맥락에서 빠지고, 메시지는 화면에 그대로 남는다. ' +
  '답변 끝에 무엇을 빼자고 제안했는지 한 줄로 알린다.';
const IMPORTANCE_NOTE = '중요 표시 카드가 사용자에게 보였다. 아직 표시되지 않았다. 사용자가 승인해야 표시된다.';
const SUMMARY_NOTE =
  '진행 요약 카드가 사용자에게 보였다. 아직 저장되지 않았다. 사용자가 승인해야 이 대화의 진행 요약이 된다. ' +
  '승인돼도 다음 행동을 실행하지 않는다. 답변 끝에 요약을 제안했다고 한 줄로 알린다.';
const CRITERIA_NOTE = '부서 기준 변경 카드가 사용자에게 보였다. 아직 바뀌지 않았다. 사용자가 승인해야 바뀐다.';

async function listMessages(name: string, args: Record<string, unknown>, src: OrganizeToolSource, ctx: ActionToolContext): Promise<ToolRunResult> {
  if (!ctx.organize || !src.listOrganizeMessages) return bad(name, 'organize_unavailable', '지금은 쓸 수 없음', UNAVAILABLE);
  const n = typeof args.limit === 'number' && Number.isFinite(args.limit) ? Math.max(1, Math.min(30, Math.floor(args.limit))) : 20;
  const rows = await src.listOrganizeMessages(ctx.conversationId, n);
  return out(
    name,
    {
      messages: rows.map((m) => ({
        id: m.id,
        role: m.role,
        at: m.created_at,
        excerpt: clip(m.content.replace(/\s+/g, ' '), 160),
        important: m.marked_important,
        ...(m.id === ctx.organize!.userMessageId ? { current: true } : {}),
      })),
      note: '맥락에서 제외된 메시지는 목록에 없다. current는 이번 질문이다.',
    },
    `${rows.length}개`,
  );
}

function guard(name: string, ctx: ActionToolContext, available: boolean): ToolRunResult | null {
  if (!ctx.organize || !available) return bad(name, 'organize_unavailable', '지금은 제안할 수 없음', UNAVAILABLE);
  if (ctx.organize.proposed.has(name)) return bad(name, 'organize_already_proposed', '이미 제안함', { next: '한 답변에 같은 종류의 정리 제안은 하나만 낸다.' });
  return null;
}

async function proposeExclusion(name: string, args: Record<string, unknown>, src: OrganizeToolSource, ctx: ActionToolContext): Promise<ToolRunResult> {
  const blocked = guard(name, ctx, src.proposeExclusion != null);
  if (blocked) return blocked;
  const targets = ids(args.message_ids, 20);
  const reason = str(args.reason, 500);
  const impact = str(args.impact, 500);
  if (targets === null) return bad(name, 'organize_id_invalid', 'id 형식 오류', { next: 'list_conversation_messages의 id를 그대로 20개까지 준다.' });
  const need: string[] = [];
  if (targets.length === 0) need.push('message_ids');
  if (!reason) need.push('reason');
  if (!impact) need.push('impact');
  if (need.length > 0) return missing(name, need);
  if (reason!.length < 8) {
    return bad(name, 'exclusion_reason_too_vague', '이유가 모호함', { next: '무엇이 어떻게 정정·폐기됐는지 구체적으로 적는다. 그럴 수 없으면 제안하지 않는다.' });
  }
  let row: ActionRow;
  try {
    row = await src.proposeExclusion!(ctx.conversationId, targets, reason!, impact!, ctx.organize!.userAskedExclusion);
  } catch (e) {
    return organizeError(name, e);
  }
  ctx.organize!.proposed.add(name);
  return out(name, { ok: true, action_id: row.id, status: 'proposed', note: EXCLUSION_NOTE }, `메시지 ${targets.length}개`, row);
}

async function proposeImportance(name: string, args: Record<string, unknown>, src: OrganizeToolSource, ctx: ActionToolContext): Promise<ToolRunResult> {
  const blocked = guard(name, ctx, src.proposeImportance != null);
  if (blocked) return blocked;
  const targets = ids(args.message_ids, 10);
  const reason = str(args.reason, 500);
  if (targets === null) return bad(name, 'organize_id_invalid', 'id 형식 오류', { next: 'list_conversation_messages의 id를 그대로 10개까지 준다.' });
  const need: string[] = [];
  if (targets.length === 0) need.push('message_ids');
  if (!reason) need.push('reason');
  if (need.length > 0) return missing(name, need);
  let row: ActionRow;
  try {
    row = await src.proposeImportance!(ctx.conversationId, targets, reason!, ctx.organize!.userAskedImportance);
  } catch (e) {
    return organizeError(name, e);
  }
  ctx.organize!.proposed.add(name);
  return out(name, { ok: true, action_id: row.id, status: 'proposed', note: IMPORTANCE_NOTE }, `메시지 ${targets.length}개`, row);
}

/** 모델이 준 요약을 정리한다. 최종 검사는 DB(ai_progress_summary_clean)가 한다. */
export function progressSummaryInput(raw: unknown): ProgressSummaryInput | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const r = raw as Record<string, unknown>;
  const purpose = str(r.purpose, 1000);
  if (!purpose) return null;
  const next: ProgressNextAction[] = [];
  for (const item of Array.isArray(r.next) ? r.next : []) {
    if (!item || typeof item !== 'object') continue;
    const n = item as Record<string, unknown>;
    const what = str(n.what, 300);
    if (!what) continue;
    next.push({
      what,
      owner: str(n.owner, 60) ?? '',
      prerequisite: str(n.prerequisite, 300) ?? '',
      done_when: str(n.done_when, 300) ?? '',
    });
    if (next.length >= 10) break;
  }
  return {
    purpose,
    decided: list(r.decided, 12, 500),
    open: list(r.open, 12, 500),
    status: str(r.status, 1000) ?? '',
    next,
  };
}

async function proposeSummary(name: string, args: Record<string, unknown>, src: OrganizeToolSource, ctx: ActionToolContext): Promise<ToolRunResult> {
  const blocked = guard(name, ctx, src.proposeProgressSummary != null);
  if (blocked) return blocked;
  const summary = progressSummaryInput(args.summary);
  const reason = str(args.reason, 500);
  const need: string[] = [];
  if (!summary) need.push('summary.purpose');
  if (!reason) need.push('reason');
  if (need.length > 0) return missing(name, need);
  let row: ActionRow;
  try {
    row = await src.proposeProgressSummary!(ctx.conversationId, summary!, reason!, ctx.organize!.userMessageId);
  } catch (e) {
    return organizeError(name, e);
  }
  ctx.organize!.proposed.add(name);
  return out(name, { ok: true, action_id: row.id, status: 'proposed', note: SUMMARY_NOTE }, clip(summary!.purpose, 60), row);
}

async function proposeCriteria(name: string, args: Record<string, unknown>, src: OrganizeToolSource, ctx: ActionToolContext): Promise<ToolRunResult> {
  const blocked = guard(name, ctx, src.proposeCriteriaChange != null && ctx.organize?.criteriaDepartment != null);
  if (blocked) return blocked;
  const memoryIds = ids(args.priority_memory_ids ?? [], 8);
  const reason = str(args.reason, 500);
  if (memoryIds === null) return bad(name, 'organize_id_invalid', 'id 형식 오류', { next: '기억 id는 도구 결과나 지시문에서 그대로 8개까지 준다.' });
  if (!reason) return missing(name, ['reason']);
  const criteria: CriteriaInput = {
    questions: list(args.questions, 8, 200),
    risks: list(args.risks, 8, 200),
    priority_memory_ids: memoryIds,
  };
  const department = ctx.organize!.criteriaDepartment!;
  let row: ActionRow;
  try {
    row = await src.proposeCriteriaChange!(ctx.conversationId, department, criteria, reason);
  } catch (e) {
    return organizeError(name, e);
  }
  ctx.organize!.proposed.add(name);
  return out(name, { ok: true, action_id: row.id, status: 'proposed', note: CRITERIA_NOTE }, String(row.preview?.title ?? '부서 기준'), row);
}

export async function dispatchOrganizeTool(
  name: string,
  args: Record<string, unknown>,
  src: OrganizeToolSource,
  ctx: ActionToolContext | undefined,
): Promise<ToolRunResult> {
  if (!ctx) return bad(name, 'organize_unavailable', '지금은 쓸 수 없음', UNAVAILABLE);
  switch (name) {
    case LIST_MESSAGES_TOOL_NAME:
      return await listMessages(name, args, src, ctx);
    case EXCLUSION_TOOL_NAME:
      return await proposeExclusion(name, args, src, ctx);
    case IMPORTANCE_TOOL_NAME:
      return await proposeImportance(name, args, src, ctx);
    case SUMMARY_TOOL_NAME:
      return await proposeSummary(name, args, src, ctx);
    case CRITERIA_TOOL_NAME:
      return await proposeCriteria(name, args, src, ctx);
    default:
      return bad(name, 'unknown_tool', '알 수 없는 도구');
  }
}
