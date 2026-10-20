// 부서 협의: 답하는 부서가 다른 부서의 관점이 필요할 때 그 부서에게 따로 묻는다(운영자 결정 2026-10-12).
// - 승인 없이 자동으로, 한 답변에 최대 MAX_CONSULTS_PER_ANSWER번. 기본 모델(primary)로 묻는다.
// - 질문 받은 부서는 묻는 부서가 쓴 질문·배경과, 자기 부서 기억·공통 기억만 본다. 운영자와의 대화 원문은 보지 않는다.
// - 협의 문답은 ai_runs(feature think_consult)에 기록되고, 답변의 도구 기록에 질문·답 요약이 남는다.
// 설계: docs/architecture/ai-think-actions.md §10

import { estimateCostUsd, modelFor, reasoningFor, type EnvReader } from '../_shared/ai/config.ts';
import { emptyUsage, type AiFunctionTool, type AiProvider, type AiResult } from '../_shared/ai/types.ts';
import type { AiRunRecord } from '../_shared/ai/usage.ts';
import type { ConversationAccessState } from './access_context.ts';
import { buildThinkContext, type ThinkContextStore } from './context.ts';
import { clip, ROLE_PROFILE_VERSION, type ThinkRoleId } from './prompts.ts';
import type { ToolRunResult } from './tools.ts';

export const CONSULT_TOOL_NAME = 'consult_department';
export const MAX_CONSULTS_PER_ANSWER = 2;
export const CONSULT_PROMPT_VERSION = 'think-consult-2026-10-12';
/** 협의 한 번에 쓰는 최대 시간. 남은 답변 시간이 더 짧으면 그만큼만 쓴다. */
export const CONSULT_TIMEOUT_MS = 90_000;
const CONSULT_MAX_OUTPUT_TOKENS = 4000;

export const DEPARTMENT_LABELS: Record<ThinkRoleId, string> = {
  lead: '총괄',
  education: '교육',
  product: '문제 풀이',
  engineering: '개발',
};

const ROLES: ThinkRoleId[] = ['lead', 'education', 'product', 'engineering'];

export const CONSULT_TOOL: AiFunctionTool = {
  name: CONSULT_TOOL_NAME,
  description:
    '다른 부서에게 그 부서 관점의 의견을 묻는다. 그 부서는 운영자와의 대화를 보지 못하므로 question과 background에 필요한 사실을 직접 적는다. ' +
    '승인 없이 바로 묻고 답을 받는다. 한 답변에 최대 2번. 지금 부서에게는 묻지 않는다.',
  parameters: {
    type: 'object',
    properties: {
      department: { type: 'string', enum: ROLES, description: '물을 부서. lead 총괄, education 교육, product 문제 풀이, engineering 개발' },
      question: { type: 'string', description: '그 부서에게 묻는 질문 하나. 무엇을 판단해 달라는지 분명하게' },
      background: { type: 'string', description: '판단에 필요한 배경. 대화에서 정해진 것·제약을 요약한다. 없으면 빈 문자열' },
    },
    required: ['department', 'question', 'background'],
    additionalProperties: false,
  },
};

/** 이번 답변에서 협의 도구를 쓸 수 있을 때만 채운다(부서 기능 준비됨, 커서 질문 아님). */
export interface ConsultState {
  fromRole: ThinkRoleId;
  count: number;
}

export interface ConsultDeps {
  provider: AiProvider;
  store: ThinkContextStore;
  recordRun: (rec: AiRunRecord) => Promise<string | null>;
  emit: (event: string, data: Record<string, unknown>) => void;
  env: EnvReader;
  now: () => number;
}

export interface ConsultCall {
  callId: string;
  rawArguments: string;
  conversationId: string;
  userId: string;
  safetyId: string;
  signal: AbortSignal;
  /** 이 시각(ms)을 넘기지 않는다. 답변 전체의 시간 예산에서 정한다. */
  deadline: number;
}

export function consultInstructions(from: ThinkRoleId, to: ThinkRoleId): string {
  return [
    '## 부서 협의 모드',
    `지금 묻는 쪽은 운영자가 아니라 같은 Think의 ${DEPARTMENT_LABELS[from]} 부서다. 너는 ${DEPARTMENT_LABELS[to]} 부서로서 의견을 준다.`,
    '너는 운영자와의 대화를 보지 못한다. 아래 질문과 배경, 너에게 주어진 기억만 안다.',
    `- ${DEPARTMENT_LABELS[to]} 부서 관점의 의견만 준다. 결정하지 않는다. 최종 결정은 운영자가 한다.`,
    '- 확정된 기억에 근거한 부분은 기억 id를 밝힌다. 기억에 없는 판단은 "추천"이라고 밝힌다.',
    '- 이 모드에서는 도구가 없다. 제안·코드 요청·기억 저장을 하지 않고, 했다고 말하지도 않는다.',
    '- 질문과 배경만으로 판단하기 어려우면 무엇이 더 필요한지 적는다.',
    '- 결론부터 짧게(10줄 안팎) 쓴다.',
  ].join('\n');
}

function str(v: unknown, max: number): string {
  return typeof v === 'string' ? v.trim().slice(0, max) : '';
}

function fail(error: string, summary: string, next: string): ToolRunResult {
  return { name: CONSULT_TOOL_NAME, ok: false, output: JSON.stringify({ error, next }), summary };
}

export function parseConsultArgs(raw: string):
  | { ok: true; department: ThinkRoleId; question: string; background: string }
  | { ok: false; error: string } {
  let args: Record<string, unknown>;
  try {
    const parsed = JSON.parse(raw || '{}');
    args = parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return { ok: false, error: 'invalid_arguments' };
  }
  const department = ROLES.find((r) => r === args.department);
  if (!department) return { ok: false, error: 'department_invalid' };
  const question = str(args.question, 2000);
  if (!question) return { ok: false, error: 'question_required' };
  return { ok: true, department, question, background: str(args.background, 4000) };
}

/** 도구 실패는 예외로 올리지 않는다. 모델에게 오류 결과로 돌려주고, 협의 없이 답하게 한다. */
export async function runConsult(call: ConsultCall, state: ConsultState | undefined, deps: ConsultDeps): Promise<ToolRunResult> {
  if (!state) return fail('consult_unavailable', '지금은 협의할 수 없음', '실행 환경 기능 상태 메모를 따른다. 협의 없이 답한다.');
  const parsed = parseConsultArgs(call.rawArguments);
  if (!parsed.ok) {
    return fail(parsed.error, '협의 인자 오류', 'department·question을 채워 다시 묻거나, 협의 없이 답한다.');
  }
  const { department: to, question, background } = parsed;
  if (to === state.fromRole) {
    return fail('consult_same_department', '지금 부서에게는 물을 수 없음', '지금 부서의 관점은 네가 직접 답한다.');
  }
  if (state.count >= MAX_CONSULTS_PER_ANSWER) {
    return fail('consult_limit', '협의 횟수 초과', `한 답변에 협의는 ${MAX_CONSULTS_PER_ANSWER}번까지다. 받은 의견으로 답한다.`);
  }
  const remaining = call.deadline - deps.now();
  if (remaining < 15_000) {
    return fail('consult_no_time', '협의할 시간이 부족함', '협의 없이 답하고, 그 부서와 협의하지 못했다고 밝힌다.');
  }
  state.count += 1;

  const from = state.fromRole;
  const started = deps.now();
  deps.emit('consult', { call_id: call.callId, status: 'running', from, to, question: clip(question, 200) });

  const access: ConversationAccessState = {
    conversationId: call.conversationId,
    thinkRoleId: to,
    extraRefDepartments: [],
    linkedMemoryIds: new Set(),
    linkedDocumentNodeIds: new Set(),
    rolesFeatureReady: true,
  };
  const request = [
    `[${DEPARTMENT_LABELS[from]} 부서의 협의 요청]`,
    `질문: ${question}`,
    `배경: ${background || '없음'}`,
  ].join('\n');
  const model = modelFor('primary', deps.env);
  let result: AiResult | null = null;
  let error: string | null = null;
  let memoryIds: string[] = [];
  try {
    const ctx = await buildThinkContext(deps.store, {
      conversationId: null,
      userMessage: request,
      attachments: [],
      scope: { type: 'general', id: null },
      access,
      thinkRole: to,
      memoryProposalsReady: false,
    });
    memoryIds = ctx.deliveredMaterials.filter((m) => m.kind === 'memory').map((m) => m.id);
    const signal = AbortSignal.any([call.signal, AbortSignal.timeout(Math.min(CONSULT_TIMEOUT_MS, remaining - 5_000))]);
    result = await deps.provider.complete(
      {
        model,
        instructions: `${ctx.instructions}\n\n${consultInstructions(from, to)}`,
        input: ctx.input,
        reasoningEffort: reasoningFor('primary', deps.env),
        maxOutputTokens: CONSULT_MAX_OUTPUT_TOKENS,
        safetyId: call.safetyId,
      },
      signal,
    );
  } catch (e) {
    error = e instanceof Error ? e.message : String(e);
  }
  const answer = result ? result.messages.filter((m) => m.phase !== 'commentary').map((m) => m.text.trim()).filter(Boolean).join('\n\n') : '';
  if (!error && !answer) error = 'empty_answer';
  const usedModel = result?.model || model;
  await deps.recordRun({
    feature: 'think_consult',
    provider: deps.provider.name,
    model: usedModel,
    promptVersion: CONSULT_PROMPT_VERSION,
    roleProfileVersion: ROLE_PROFILE_VERSION,
    status: error ? 'error' : 'ok',
    error,
    usage: result?.usage ?? emptyUsage(),
    costUsd: result ? estimateCostUsd(usedModel, result.usage, 0, deps.env) : null,
    latencyMs: deps.now() - started,
    conversationId: call.conversationId,
    createdBy: call.userId || null,
    features: { consult: { from, to } },
  }).catch((e) => {
    console.error('[ai_think] consult run record failed:', e instanceof Error ? e.message : String(e));
    return null;
  });
  deps.emit('consult', { call_id: call.callId, status: 'done', ok: !error, from, to });

  if (error) {
    console.error('[ai_think] consult failed:', error);
    return fail('consult_failed', `${DEPARTMENT_LABELS[to]} 협의 실패`, '협의 없이 네 판단으로 답하고, 그 부서와 협의하지 못했다고 밝힌다.');
  }
  return {
    name: CONSULT_TOOL_NAME,
    ok: true,
    output: JSON.stringify({
      department: to,
      answer: clip(answer, 6000),
      memory_ids_seen: memoryIds.slice(0, 20),
      note: `${DEPARTMENT_LABELS[to]} 부서의 의견이다. 결정이 아니다. 답변에 반영할 때 어느 부서 의견인지 밝힌다.`,
    }),
    summary: `${DEPARTMENT_LABELS[to]}에게 물음: ${clip(question, 160)} → ${clip(answer.replace(/\s+/g, ' '), 400)}`,
  };
}
