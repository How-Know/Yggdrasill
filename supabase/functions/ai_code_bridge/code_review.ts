// 코드 조사·수정 결과가 도착하면 Think가 검토해 같은 대화에 답을 붙인다.
// 조사 결과로 원래 질문이 안 풀리면 2회차 질문을 한 번 더 보낸다(max_rounds까지, 조사 모드만).
// 작업자 응답과 별개로 백그라운드(waitUntil)에서 돈다. 실패해도 요청 상태는 그대로이고 review_status만 남긴다.
// 설계: docs/architecture/ai-think-actions.md §4.1

import { denoEnv, estimateCostUsd, maxOutputTokensFor, modelFor, reasoningFor, type EnvReader } from '../_shared/ai/config.ts';
import { emptyUsage, finalText, type AiProvider, type AiResult } from '../_shared/ai/types.ts';
import type { AiRunRecord } from '../_shared/ai/usage.ts';
import type { NewMessage } from '../ai_think/chat.ts';
import type { MemoryRow, MessageRow } from '../ai_think/context.ts';
import { transcript } from '../ai_think/drafts.ts';
import { clip } from '../ai_think/prompts.ts';

export const REVIEW_PROMPT_VERSION = 'code-review-2026-09-30';

/** 월 한도 상태. 읽지 못하면 null(제한 없음으로 본다). */
export type BudgetGate = () => Promise<{ exceeded: boolean; mode: string } | null>;

async function budgetOk(gate: BudgetGate): Promise<boolean> {
  const b = await gate().catch(() => null);
  return !(b?.exceeded && b.mode === 'block');
}

export interface ReviewRound {
  round: number;
  result: Record<string, unknown> | null;
  result_text: string | null;
}

export interface ReviewRequest {
  id: string;
  title: string;
  mode: string;
  status: string;
  round: number;
  max_rounds: number;
  conversation_id: string | null;
  created_by: string | null;
  request: Record<string, unknown>;
  /** 끝난 회차들, 오래된 것부터. */
  rounds: ReviewRound[];
}

export interface ReviewStore {
  loadRequest(id: string): Promise<ReviewRequest | null>;
  listMessages(conversationId: string, limit: number): Promise<MessageRow[]>;
  listActiveMemories(kinds: string[]): Promise<MemoryRow[]>;
  insertMessage(msg: NewMessage): Promise<string>;
  followup(id: string, prompt: string): Promise<boolean>;
  reviewDone(id: string, status: 'done' | 'skipped' | 'error', messageId: string | null, error: string | null): Promise<void>;
}

export interface ReviewDeps {
  provider: AiProvider | null;
  store: ReviewStore;
  recordRun: (rec: AiRunRecord) => Promise<string | null>;
  budget: BudgetGate;
  safetyId: (userId: string) => Promise<string>;
  env?: EnvReader;
  now?: () => number;
}

export interface ReviewOutput {
  answer: string;
  followup_questions: string[];
  conflicts: string[];
}

export type ReviewOutcome = 'done' | 'followup' | 'skipped' | 'error';

export const REVIEW_SCHEMA: Record<string, unknown> = {
  type: 'object',
  properties: {
    answer: { type: 'string', description: '운영자에게 보일 마크다운 답변' },
    followup_questions: { type: 'array', items: { type: 'string' }, description: 'Cursor에게 한 번 더 물을 질문(최대 3개). 없으면 빈 배열' },
    conflicts: { type: 'array', items: { type: 'string' }, description: '철학·원칙·결정과 부딪히는 점. 없으면 빈 배열' },
  },
  required: ['answer', 'followup_questions', 'conflicts'],
  additionalProperties: false,
};

export function reviewInstructions(memories: MemoryRow[], canFollowup: boolean): string {
  const principles = memories.filter((m) => m.kind === 'identity' || m.kind === 'principle');
  const decisions = memories.filter((m) => m.kind === 'decision').slice(0, 15);
  const lines = [
    '너는 Yggdrasill 운영자의 생각 파트너 Think다. 운영자가 대화에서 보낸 코드 요청에 대해 Cursor(코딩 에이전트)의 결과가 도착했다.',
    '결과를 검토해 같은 대화에 붙일 답변을 쓴다.',
    '',
    '## 답변(answer)',
    '- 한국어 마크다운. 결론을 먼저, 근거 파일 경로를 함께 쓴다. 필요 이상으로 길게 쓰지 않는다.',
    '- Cursor 결과에 근거가 없는 내용은 추측하지 않는다. 확인 안 된 것은 확인 안 됐다고 쓴다.',
    '- 수정 결과(diff)면 무엇이 바뀌었는지, 요청과 맞는지, 요청 밖 파일·대량 삭제·설정 변경 같은 위험이 있는지 짚는다.',
    '  작업 폴더 적용은 운영자가 요청 카드에서 diff를 보고 정한다고 안내한다.',
    '- 다음 할 일을 제안할 수 있다(예: 이 제안대로 수정을 요청할지). 실행했다고 말하지 않는다.',
    '- 운영자에게 물어야 할 것이 있으면 answer 끝에 질문으로 쓴다.',
    '',
    '## 원칙 충돌(conflicts)',
    '- 아래 교육철학·원칙·결정과 부딪히는 결과나 제안이 있으면 한 줄씩. 없으면 빈 배열.',
    '',
    '## 추가 조사(followup_questions)',
    canFollowup
      ? '- 결과만으로 운영자의 원래 질문에 답할 수 없고 코드를 더 보면 풀리는 경우에만, Cursor에게 물을 질문을 최대 3개 쓴다. 그 밖에는 빈 배열.'
      : '- 이번에는 추가 조사를 할 수 없다. 항상 빈 배열로 둔다.',
    '',
    '## 교육철학·원칙',
    ...(principles.length ? principles.map((m) => `- ${m.title}: ${clip(m.content, 400).replace(/\n+/g, ' ')}`) : ['(없음)']),
    '',
    '## 최근 결정',
    ...(decisions.length ? decisions.map((m) => `- ${m.title}: ${clip(m.content, 200).replace(/\n+/g, ' ')}`) : ['(없음)']),
  ];
  return lines.join('\n');
}

function withoutDiff(result: Record<string, unknown> | null): Record<string, unknown> | null {
  if (!result) return null;
  const { diff: _diff, ...rest } = result;
  return rest;
}

export function reviewInput(req: ReviewRequest, history: string): string {
  const spec = req.request ?? {};
  const lines = [`[코드 요청] ${req.mode === 'change' ? '수정' : '조사'} · "${req.title}" · ${req.round}/${req.max_rounds}회차`];
  lines.push('', '[요청 내용]', clip(JSON.stringify({ ...spec, memory_refs: undefined }), 6000));
  for (const r of req.rounds) {
    lines.push('', `[${r.round}회차 결과 (정리)]`, clip(JSON.stringify(withoutDiff(r.result)), 8000));
  }
  const last = req.rounds.at(-1);
  if (last?.result_text) lines.push('', '[마지막 회차 원문 앞부분]', clip(last.result_text, 4000));
  const diff = last?.result?.diff;
  if (req.mode === 'change' && typeof diff === 'string') lines.push('', '[diff 앞부분]', clip(diff, 12000));
  if (history) lines.push('', '[이 요청이 나온 대화 (최근)]', history);
  return lines.join('\n');
}

function strArr(v: unknown, max: number): string[] {
  return Array.isArray(v) ? v.map((x) => (typeof x === 'string' ? x.trim() : '')).filter(Boolean).slice(0, max) : [];
}

export function parseReview(text: string): ReviewOutput | null {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    return null;
  }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const o = raw as Record<string, unknown>;
  const answer = typeof o.answer === 'string' ? o.answer.trim() : '';
  if (!answer) return null;
  return { answer, followup_questions: strArr(o.followup_questions, 3), conflicts: strArr(o.conflicts, 8) };
}

/** 2회차 작업자는 새 에이전트라 앞 회차를 모른다. 앞 회차 요약과 질문만 담고, 원래 요청은 작업자가 앞에 붙인다. */
export function followupPrompt(req: ReviewRequest, questions: string[]): string {
  const last = withoutDiff(req.rounds.at(-1)?.result ?? null);
  return [
    `## ${req.round}회차 조사 요약 (다시 조사하지 않는다)`,
    clip(JSON.stringify(last ?? {}), 8000),
    '',
    `## ${req.round + 1}회차 추가 질문 (Think가 결과를 검토하고 보냄)`,
    ...questions.map((q, i) => `${i + 1}. ${q}`),
    '',
    '위 질문에만 답한다. 답변 형식은 처음 요청과 같다(끝에 JSON 블록 하나).',
  ].join('\n');
}

export function reviewMessage(out: ReviewOutput): string {
  const parts = [out.answer];
  if (out.conflicts.length > 0) parts.push(['**원칙·결정과 부딪히는 점**', ...out.conflicts.map((c) => `- ${c}`)].join('\n'));
  return parts.join('\n\n');
}

export async function runCodeReview(deps: ReviewDeps, requestId: string): Promise<ReviewOutcome> {
  const env = deps.env ?? denoEnv;
  const now = deps.now ?? Date.now;
  const req = await deps.store.loadRequest(requestId);
  if (!req || !req.conversation_id) return 'skipped';
  const done = (status: 'done' | 'skipped' | 'error', messageId: string | null, error: string | null) =>
    deps.store.reviewDone(req.id, status, messageId, error ? clip(error, 500) : null);

  if (!deps.provider) {
    await done('skipped', null, 'ai_not_configured');
    return 'skipped';
  }
  if (!(await budgetOk(deps.budget))) {
    await done('skipped', null, 'budget_exceeded');
    return 'skipped';
  }

  const canFollowup = req.mode === 'investigate' && req.round < req.max_rounds;
  const [memories, messages] = await Promise.all([
    deps.store.listActiveMemories(['identity', 'principle', 'decision']),
    deps.store.listMessages(req.conversation_id, 30),
  ]);
  const model = modelFor('primary', env);
  const started = now();
  let result: AiResult | null = null;
  let error: string | null = null;
  try {
    result = await deps.provider.complete({
      model,
      instructions: reviewInstructions(memories, canFollowup),
      input: [{ kind: 'message', role: 'user', parts: [{ type: 'text', text: reviewInput(req, transcript(messages, 20000)) }] }],
      jsonSchema: { name: 'code_review', schema: REVIEW_SCHEMA },
      reasoningEffort: reasoningFor('primary', env),
      maxOutputTokens: maxOutputTokensFor('primary', env),
      safetyId: req.created_by ? await deps.safetyId(req.created_by) : undefined,
    });
  } catch (e) {
    error = e instanceof Error ? e.message : String(e);
  }
  const parsed = result ? parseReview(finalText(result)) : null;
  if (result && !parsed) error = 'invalid_output';
  const runId = await deps.recordRun({
    feature: 'code_review',
    provider: deps.provider.name,
    model: result?.model || model,
    promptVersion: REVIEW_PROMPT_VERSION,
    status: error ? 'error' : 'ok',
    error,
    usage: result?.usage ?? emptyUsage(),
    costUsd: result ? estimateCostUsd(result.model || model, result.usage, 0, env) : null,
    latencyMs: now() - started,
    conversationId: req.conversation_id,
    createdBy: req.created_by,
  });
  if (!parsed) {
    await done('error', null, error ?? 'review_failed');
    return 'error';
  }

  if (canFollowup && parsed.followup_questions.length > 0) {
    if (await deps.store.followup(req.id, followupPrompt(req, parsed.followup_questions))) return 'followup';
  }

  const messageId = await deps.store.insertMessage({
    conversation_id: req.conversation_id,
    role: 'assistant',
    content: reviewMessage(parsed),
    status: 'complete',
    tool_calls: [{ name: 'code_review', label: '코드 결과 검토', detail: `${req.title} · ${req.round}회차`, ok: true }],
    model: result?.model || model,
    run_id: runId,
  });
  await done('done', messageId, null);
  return 'done';
}
