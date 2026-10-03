// 코드 조사·조율·수정 결과가 도착하면 Think가 검토해 같은 대화에 답을 붙인다.
// 조사·조율 모드는 결과로 풀리지 않는 점이 있으면 다음 회차 질문을 보낸다(max_rounds까지).
// 조율 모드는 끝나면 조율본을 수정 제안(code_change)으로 올린다. 실행은 운영자 승인 뒤에만 한다.
// 작업자 응답과 별개로 백그라운드(waitUntil)에서 돈다. 실패해도 요청 상태는 그대로이고 review_status만 남긴다.
// 설계: docs/architecture/ai-think-actions.md §4.1, §4.3

import { denoEnv, estimateCostUsd, maxOutputTokensFor, modelFor, reasoningFor, type EnvReader } from '../_shared/ai/config.ts';
import { emptyUsage, finalText, type AiProvider, type AiResult } from '../_shared/ai/types.ts';
import type { AiRunRecord } from '../_shared/ai/usage.ts';
import type { NewMessage } from '../ai_think/chat.ts';
import type { MemoryRow, MessageRow } from '../ai_think/context.ts';
import { transcript } from '../ai_think/drafts.ts';
import { clip } from '../ai_think/prompts.ts';

export const REVIEW_PROMPT_VERSION = 'code-review-2026-10-02';

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
  /** 2회차부터: 이 회차에 Think가 물은 것. */
  think_questions: string[];
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
  followup(id: string, prompt: string, questions: string[]): Promise<boolean>;
  /** 조율본을 수정 제안으로 올린다. 만든 제안 id. */
  proposePlan(requestId: string, messageId: string, title: string, spec: Record<string, unknown>, preview: Record<string, unknown>): Promise<string | null>;
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

export interface PlanDraft {
  title: string;
  goal: string;
  instructions: string[];
  focus_paths: string[];
  constraints: string[];
  do_not: string[];
}

export interface PlanOption {
  id: string;
  label: string;
  detail: string;
  recommended: boolean;
}

/** 조율로 풀리지 않아 운영자가 고를 객관식 질문. 추천 보기가 있으면 맨 앞이다. id는 서버가 붙인다. */
export interface PlanDecision {
  id: string;
  kind: 'owner' | 'disagreement';
  question: string;
  context: string;
  options: PlanOption[];
}

export interface PlanReviewOutput extends ReviewOutput {
  plan: PlanDraft;
  decisions: PlanDecision[];
}

/** ai_code_plan_revise가 운영자 답을 제약에 붙일 때 쓰는 머리말. 다음 조율본에서도 지우지 않는다. */
export const OWNER_DECISION_PREFIX = '운영자 결정 — ';
const MAX_DECISIONS = 5;

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

const strArray = (description: string) => ({ type: 'array', items: { type: 'string' }, description });

export const PLAN_REVIEW_SCHEMA: Record<string, unknown> = {
  type: 'object',
  properties: {
    answer: { type: 'string', description: '운영자에게 보일 조율 요약 마크다운' },
    followup_questions: strArray('Cursor에게 다시 물을 질문·반론(최대 3개). 조율을 끝내면 빈 배열'),
    conflicts: strArray('철학·원칙·결정과 부딪히는 점. 없으면 빈 배열'),
    plan: {
      type: 'object',
      description: '조율본. 지금까지 합의한 구현 계획',
      properties: {
        title: { type: 'string', description: '작업 제목 (40자 이내)' },
        goal: { type: 'string', description: '이 작업으로 이루려는 것' },
        instructions: strArray('Cursor가 그대로 따라 구현할 단계. 하지 않기로 했으면 빈 배열'),
        focus_paths: strArray('고칠 폴더나 파일'),
        constraints: strArray('지켜야 할 조건'),
        do_not: strArray('하지 말 것'),
      },
      required: ['title', 'goal', 'instructions', 'focus_paths', 'constraints', 'do_not'],
      additionalProperties: false,
    },
    decisions: {
      type: 'array',
      description: `운영자가 골라야 할 객관식 질문(최대 ${MAX_DECISIONS}개). 없으면 빈 배열`,
      items: {
        type: 'object',
        properties: {
          kind: {
            type: 'string',
            enum: ['owner', 'disagreement'],
            description: 'owner: 운영자만 정할 수 있는 것, disagreement: Think와 Cursor 의견이 끝까지 다른 점',
          },
          question: { type: 'string', description: '운영자에게 묻는 한 문장' },
          context: { type: 'string', description: '왜 정해야 하는지. 갈린 의견이면 Think 의견과 Cursor 의견을 이유와 함께 한두 문장씩' },
          options: {
            type: 'array',
            description: '보기 2~4개. 추천하는 보기를 맨 앞에',
            items: {
              type: 'object',
              properties: {
                label: { type: 'string', description: '보기 (한 줄)' },
                detail: {
                  type: 'string',
                  description: '고르면 무엇이 달라지는지, 장점과 단점, 영향 범위(파일·화면·데이터), 나중에 바꾸기 쉬운지. 2~4문장',
                },
                recommended: { type: 'boolean', description: '추천하는 보기 하나만 true' },
              },
              required: ['label', 'detail', 'recommended'],
              additionalProperties: false,
            },
          },
        },
        required: ['kind', 'question', 'context', 'options'],
        additionalProperties: false,
      },
    },
  },
  required: ['answer', 'followup_questions', 'conflicts', 'plan', 'decisions'],
  additionalProperties: false,
};

export function reviewInstructions(memories: MemoryRow[], canFollowup: boolean): string {
  const lines = [
    '너는 Yggdrasill 운영자의 생각 파트너 Think다. 운영자가 대화에서 보낸 코드 요청에 대해 Cursor(코딩 에이전트)의 결과가 도착했다.',
    '결과를 검토해 같은 대화에 붙일 답변을 쓴다.',
    '',
    '## 답변(answer)',
    '- 한국어 마크다운. 결론을 먼저, 근거 파일 경로를 함께 쓴다. 필요 이상으로 길게 쓰지 않는다.',
    '- Cursor 결과에 근거가 없는 내용은 추측하지 않는다. 확인 안 된 것은 확인 안 됐다고 쓴다.',
    '- 수정 결과(diff)면 무엇이 바뀌었는지, 요청과 맞는지, 요청 밖 파일·대량 삭제·설정 변경 같은 위험이 있는지 짚는다.',
    '  요청이 승인된 조율본(based_on_plan)이면 조율본의 단계·하지 말 것과 diff가 맞는지 하나씩 확인한다.',
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
    ...memoryLines(memories),
  ];
  return lines.join('\n');
}

function memoryLines(memories: MemoryRow[]): string[] {
  const principles = memories.filter((m) => m.kind === 'identity' || m.kind === 'principle');
  const decisions = memories.filter((m) => m.kind === 'decision').slice(0, 15);
  return [
    '## 교육철학·원칙',
    ...(principles.length ? principles.map((m) => `- ${m.title}: ${clip(m.content, 400).replace(/\n+/g, ' ')}`) : ['(없음)']),
    '',
    '## 최근 결정',
    ...(decisions.length ? decisions.map((m) => `- ${m.title}: ${clip(m.content, 200).replace(/\n+/g, ' ')}`) : ['(없음)']),
  ];
}

/** 조율 모드: Think는 기획, Cursor는 실무 검토. 둘의 결과를 맞춰 운영자가 승인할 조율본을 만든다. */
export function planInstructions(memories: MemoryRow[], canFollowup: boolean): string {
  return [
    '너는 Yggdrasill 운영자의 생각 파트너 Think다. 운영자와 대화해 정한 구현 계획 초안을 Cursor(실무 개발자)에게 보냈고,',
    'Cursor가 실제 코드를 읽고 검토한 결과가 도착했다. 둘의 의견을 맞춰 운영자가 승인할 조율본을 만든다.',
    '',
    '## 역할',
    '- 코드에 관한 사실(구조, 영향 범위, 기존 구현, 기술적 위험)은 Cursor의 근거를 따른다. 근거 없이 뒤집지 않는다.',
    '- 방향·의도·교육철학·운영자 결정에 관한 판단은 네가 지킨다. Cursor 제안이 의도에서 벗어나면 받아들이지 않고 이유를 밝힌다.',
    '- 운영자만 정할 수 있는 것(우선순위, 범위를 줄일지, 비용·일정)은 정하지 말고 decisions(kind owner)로 묻는다.',
    '- 운영자가 이미 정한 것(요청의 owner_answers, 제약의 "운영자 결정 — ")은 다시 묻지 않고 조율본에 그대로 반영한다.',
    '',
    '## 다시 묻기(followup_questions)',
    canFollowup
      ? '- Cursor 검토에 빈 곳이 있거나, 너의 반론·대안에 대한 Cursor 의견이 필요하면 질문을 최대 3개 쓴다. 이때도 plan에는 지금까지의 초안을 채운다.\n' +
        '- 이미 합의됐거나 코드를 더 봐도 달라지지 않으면 빈 배열로 두고 조율을 끝낸다. 형식적으로 묻지 않는다.'
      : '- 이번이 마지막 회차다. 항상 빈 배열로 두고 조율을 끝낸다. 남은 이견은 decisions(kind disagreement)로 운영자에게 묻는다.',
    '',
    '## 조율본(plan)',
    '- Cursor가 그대로 따라 구현할 수 있게 단계(instructions)를 구체적으로 쓴다. 파일 경로를 알면 함께 쓴다.',
    '- Cursor가 짚은 문제를 반영해 단계·범위·하지 말 것을 고친다. 하지 않는 것이 낫다고 합의했으면 instructions를 빈 배열로 둔다.',
    '- 질문(decisions)에 걸린 부분은 지금까지의 초안대로 두고, 나머지 단계는 빠짐없이 채운다. 운영자가 답하면 다시 조율한다.',
    '',
    '## 운영자에게 묻기(decisions)',
    `- 조율로 풀리지 않아 운영자가 골라야 하는 것만 객관식으로 묻는다(최대 ${MAX_DECISIONS}개). 합의됐거나 코드가 답을 정해 주는 것은 묻지 않는다.`,
    '- 운영자는 코드를 보지 않고 고른다. question은 쉬운 한 문장, context는 왜 지금 정해야 하는지를 쓴다.',
    '- 보기는 2~4개. 서로 겹치지 않고 실제로 고를 만한 것만. 추천하는 보기를 맨 앞에 두고 그 하나만 recommended를 true로 한다.',
    '- detail은 보기마다 2~4문장: 고르면 무엇이 달라지는지, 장점과 단점, 영향 범위(파일·화면·데이터), 나중에 바꾸기 쉬운지.',
    '- 갈린 의견(kind disagreement)은 Think 안, Cursor 안, (있으면) 절충안을 보기로 하고 context에 양쪽 의견과 이유를 쓴다.',
    '- 운영자가 직접 답을 적을 수도 있으니 "기타" 보기는 만들지 않는다.',
    '',
    '## 답변(answer)',
    '- 한국어 마크다운. 운영자가 승인 여부를 판단할 수 있게 짧게: 원래 계획에서 무엇이 바뀌었고 왜인지, 남은 위험.',
    '- 정할 것은 카드에 객관식으로 따로 보이니 답변에서는 무엇을 골라야 하는지 한 줄로만 알린다.',
    '- 조율을 끝낼 때만 쓴다. 다시 묻는 회차에는 한두 문장으로 무엇을 더 확인하는지 쓴다.',
    '- 조율본은 카드로 따로 보이니 단계를 답변에 다시 늘어놓지 않는다. 구현했다고 말하지 않는다.',
    '',
    '## 원칙 충돌(conflicts)',
    '- 아래 교육철학·원칙·결정과 부딪히는 점이 있으면 한 줄씩. 없으면 빈 배열.',
    '',
    ...memoryLines(memories),
  ].join('\n');
}

function withoutDiff(result: Record<string, unknown> | null): Record<string, unknown> | null {
  if (!result) return null;
  const { diff: _diff, ...rest } = result;
  return rest;
}

const MODE_LABELS: Record<string, string> = { change: '수정', plan: '조율', investigate: '조사' };

export function reviewInput(req: ReviewRequest, history: string): string {
  const spec = req.request ?? {};
  const lines = [`[코드 요청] ${MODE_LABELS[req.mode] ?? '조사'} · "${req.title}" · ${req.round}/${req.max_rounds}회차`];
  const answered = Array.isArray(spec.owner_answers) ? spec.owner_answers.length : 0;
  const head = req.mode !== 'plan' ? '[요청 내용]' : answered > 0 ? '[이전 조율본 + 운영자가 고른 답 (owner_answers는 다시 묻지 말고 따른다)]' : '[처음 계획 초안]';
  lines.push('', head, clip(JSON.stringify({ ...spec, memory_refs: undefined }), 6000));
  for (const r of req.rounds) {
    if (r.think_questions.length > 0) {
      lines.push('', `[${r.round}회차에 Think가 물은 것]`, ...r.think_questions.map((q, i) => `${i + 1}. ${q}`));
    }
    lines.push('', `[${r.round}회차 Cursor 결과 (정리)]`, clip(JSON.stringify(withoutDiff(r.result)), 8000));
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

function str(v: unknown, max: number): string {
  return typeof v === 'string' ? v.trim().slice(0, max) : '';
}

export function parsePlanReview(text: string): PlanReviewOutput | null {
  const base = parseReview(text);
  if (!base) return null;
  const o = JSON.parse(text) as Record<string, unknown>;
  const p = o.plan && typeof o.plan === 'object' && !Array.isArray(o.plan) ? (o.plan as Record<string, unknown>) : {};
  const plan: PlanDraft = {
    title: str(p.title, 120),
    goal: str(p.goal, 2000),
    instructions: strArr(p.instructions, 20),
    focus_paths: strArr(p.focus_paths, 12),
    constraints: strArr(p.constraints, 12),
    do_not: strArr(p.do_not, 12),
  };
  return { ...base, plan, decisions: parseDecisions(o.decisions) };
}

const isObj = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);

/** 보기가 2개 미만인 질문은 버린다. 추천은 하나만 남겨 맨 앞으로 옮기고, id는 순서대로 붙인다(q1, q1_1 …). */
export function parseDecisions(raw: unknown): PlanDecision[] {
  const out: PlanDecision[] = [];
  for (const d of Array.isArray(raw) ? raw : []) {
    if (!isObj(d) || out.length >= MAX_DECISIONS) continue;
    const question = str(d.question, 300);
    const options = (Array.isArray(d.options) ? d.options : [])
      .filter(isObj)
      .map((o) => ({ label: str(o.label, 200), detail: str(o.detail, 1200), recommended: o.recommended === true }))
      .filter((o) => o.label)
      .slice(0, 4);
    if (!question || options.length < 2) continue;
    const rec = options.findIndex((o) => o.recommended);
    const ordered = rec > 0 ? [options[rec], ...options.filter((_, i) => i !== rec)] : options;
    const id = `q${out.length + 1}`;
    out.push({
      id,
      kind: d.kind === 'disagreement' ? 'disagreement' : 'owner',
      question,
      context: str(d.context, 1200),
      options: ordered.map((o, i) => ({ id: `${id}_${i + 1}`, label: o.label, detail: o.detail, recommended: rec >= 0 && i === 0 })),
    });
  }
  return out;
}

/** 다음 회차 작업자는 새 에이전트라 앞 회차를 모른다. 앞 회차 요약과 질문만 담고, 원래 요청은 작업자가 앞에 붙인다. */
export function followupPrompt(req: ReviewRequest, questions: string[]): string {
  const last = withoutDiff(req.rounds.at(-1)?.result ?? null);
  const plan = req.mode === 'plan';
  return [
    `## ${req.round}회차 ${plan ? '검토' : '조사'} 요약 (다시 처음부터 하지 않는다)`,
    clip(JSON.stringify(last ?? {}), 8000),
    '',
    plan
      ? `## ${req.round + 1}회차: Think가 검토 결과를 보고 보낸 질문·반론`
      : `## ${req.round + 1}회차 추가 질문 (Think가 결과를 검토하고 보냄)`,
    ...questions.map((q, i) => `${i + 1}. ${q}`),
    '',
    plan
      ? '위 질문·반론에 코드 근거로 답한다. 동의하면 동의한다고, 아니면 이유를 쓴다. 답변 형식은 처음 요청과 같다(끝에 JSON 블록 하나).'
      : '위 질문에만 답한다. 답변 형식은 처음 요청과 같다(끝에 JSON 블록 하나).',
  ].join('\n');
}

export function reviewMessage(out: ReviewOutput): string {
  const parts = [out.answer];
  if (out.conflicts.length > 0) parts.push(['**원칙·결정과 부딪히는 점**', ...out.conflicts.map((c) => `- ${c}`)].join('\n'));
  return parts.join('\n\n');
}

export function planMessage(out: PlanReviewOutput): string {
  const parts = [reviewMessage(out)];
  if (out.decisions.length > 0) {
    parts.push([
      `**정해 주셔야 할 것 ${out.decisions.length}개** (아래 조율본 카드에서 골라 주세요)`,
      ...out.decisions.map((d) => `- ${d.kind === 'disagreement' ? '[의견 갈림] ' : ''}${d.question}`),
    ].join('\n'));
  }
  return parts.join('\n\n');
}

/** 승인되면 그대로 수정 요청의 내용이 된다(ThinkCodeSpec + 조율 기록). */
export function planSpec(req: ReviewRequest, out: PlanReviewOutput): Record<string, unknown> {
  const original = req.request ?? {};
  const ownerLines = strArr(original.constraints, 40).filter((c) => c.startsWith(OWNER_DECISION_PREFIX));
  return {
    goal: out.plan.goal || str(original.goal, 2000),
    instructions: out.plan.instructions,
    focus_paths: out.plan.focus_paths,
    constraints: [...new Set([...ownerLines, ...out.plan.constraints])],
    do_not: out.plan.do_not,
    questions: [],
    background: str(original.background, 6000),
    memory_refs: Array.isArray(original.memory_refs) ? original.memory_refs : [],
    based_on_plan: { id: req.id, title: req.title, rounds: req.round, summary: clip(out.answer, 1500) },
    owner_answers: Array.isArray(original.owner_answers) ? original.owner_answers : [],
    decisions: out.decisions,
  };
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

  const plan = req.mode === 'plan';
  const canFollowup = (req.mode === 'investigate' || plan) && req.round < req.max_rounds;
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
      instructions: plan ? planInstructions(memories, canFollowup) : reviewInstructions(memories, canFollowup),
      input: [{ kind: 'message', role: 'user', parts: [{ type: 'text', text: reviewInput(req, transcript(messages, 20000)) }] }],
      jsonSchema: plan ? { name: 'code_plan_review', schema: PLAN_REVIEW_SCHEMA } : { name: 'code_review', schema: REVIEW_SCHEMA },
      reasoningEffort: reasoningFor('primary', env),
      maxOutputTokens: maxOutputTokensFor('primary', env),
      safetyId: req.created_by ? await deps.safetyId(req.created_by) : undefined,
    });
  } catch (e) {
    error = e instanceof Error ? e.message : String(e);
  }
  const parsed = result ? (plan ? parsePlanReview(finalText(result)) : parseReview(finalText(result))) : null;
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
    if (await deps.store.followup(req.id, followupPrompt(req, parsed.followup_questions), parsed.followup_questions)) return 'followup';
  }

  const planOut = plan ? (parsed as PlanReviewOutput) : null;
  const messageId = await deps.store.insertMessage({
    conversation_id: req.conversation_id,
    role: 'assistant',
    content: planOut ? planMessage(planOut) : reviewMessage(parsed),
    status: 'complete',
    tool_calls: [
      planOut
        ? { name: 'code_plan_review', label: 'Cursor와 조율 결과', detail: `${req.title} · ${req.round}회 주고받음`, ok: true }
        : { name: 'code_review', label: '코드 결과 검토', detail: `${req.title} · ${req.round}회차`, ok: true },
    ],
    model: result?.model || model,
    run_id: runId,
  });
  if (planOut && (planOut.plan.instructions.length > 0 || planOut.decisions.length > 0)) {
    await deps.store.proposePlan(req.id, messageId, planOut.plan.title || req.title, planSpec(req, planOut), {
      goal: clip(planOut.plan.goal || String(req.request?.goal ?? ''), 300),
      rounds: req.round,
      decisions: planOut.decisions.length,
    });
  }
  await done('done', messageId, null);
  return 'done';
}
