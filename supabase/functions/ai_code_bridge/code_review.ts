// 코드 조사·조율·수정 결과가 도착하면 Think가 검토해 같은 대화에 답을 붙인다.
// Think는 운영자 아래에서 Cursor 작업을 이끈다(운영자 결정 2026-10-06). 운영자는 작업 폴더 적용과 운영 DB 반영만 승인한다.
// - 조사·조율: 결과로 풀리지 않는 점이 있으면 다음 회차 질문을 보낸다(max_rounds까지).
// - 조율이 끝나면: 운영자에게 물을 것이 없으면 조율본대로 바로 수정을 맡기고, 있으면 조율본 카드에 질문을 올린다.
// - 수정이 끝나면: 작업자 자동 검사 결과를 보고, 이번 수정 때문에 실패한 검사가 있으면 최대 2회 다시 고치게 한다.
// 작업자 응답과 별개로 백그라운드(waitUntil)에서 돈다. 실패해도 요청 상태는 그대로이고 review_status만 남긴다.
// 설계: docs/architecture/ai-think-actions.md §4.1, §4.3, §4.6

import { denoEnv, estimateCostUsd, maxOutputTokensFor, modelFor, reasoningFor, type EnvReader } from '../_shared/ai/config.ts';
import { emptyUsage, finalText, type AiProvider, type AiResult } from '../_shared/ai/types.ts';
import type { AiRunRecord } from '../_shared/ai/usage.ts';
import { type ConversationAccessState, scopedMemoriesForConversation } from '../ai_think/access_context.ts';
import type { NewMessage } from '../ai_think/chat.ts';
import type { MemoryRow, MessageRow } from '../ai_think/context.ts';
import { transcript } from '../ai_think/drafts.ts';
import { clip } from '../ai_think/prompts.ts';
import { EFFORT_TOOL_PROPERTIES, effortReason, normalizeEffort, type CodeEffort } from '../_shared/code_effort.ts';
import {
  checkVerdict,
  STATUS_LABELS,
  VERDICT_LABELS,
  verdictLabel,
  type CheckVerdict,
  type Verification,
  type VerificationItem,
  verificationOf,
} from '../_shared/code_verification.ts';

export { checkVerdict, VERDICT_LABELS, verificationOf };
export type { CheckVerdict, Verification, VerificationItem };

// code-review-2026-10-10: 조율본에 수정 작업 강도(effort) 선택.
// code-review-2026-10-13: 보기별 단계·답 대기 조건(holds)·필수 검사(checks), 최종 지시 검사, 검사 기록만 근거로 보고.
export const REVIEW_PROMPT_VERSION = 'code-review-2026-10-13';
/** 자동 검사 실패 뒤 Think가 Cursor에게 다시 고치게 하는 최대 횟수(운영자 결정 2026-10-06). */
export const MAX_FIX_ATTEMPTS = 2;

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
  /** 요청이 나온 대화의 역할·자료 범위. 없으면 공통 기억만 쓴다. */
  loadConversationAccess?(conversationId: string, rolesFeatureReady: boolean): Promise<ConversationAccessState>;
  insertMessage(msg: NewMessage): Promise<string>;
  followup(id: string, prompt: string, questions: string[]): Promise<boolean>;
  /** 조율본을 승인 대기 수정 제안으로 올린다(운영자에게 물을 것이 있을 때, 또는 바로 보내지 못했을 때). 만든 제안 id. */
  proposePlan(requestId: string, messageId: string, title: string, spec: Record<string, unknown>, preview: Record<string, unknown>): Promise<string | null>;
  /** 조율본대로 바로 수정 요청을 보낸다(ai_code_bridge_start_change). */
  startChange(planRequestId: string, messageId: string, title: string, spec: Record<string, unknown>): Promise<StartResult>;
  /** 자동 검사 실패 → 앞 수정 위에서 다시 고치는 요청을 보낸다(ai_code_bridge_fix). */
  fixChange(requestId: string, messageId: string, spec: Record<string, unknown>): Promise<StartResult>;
  reviewDone(id: string, status: 'done' | 'skipped' | 'error', messageId: string | null, error: string | null): Promise<void>;
}

export type StartResult = { ok: true; codeRequestId: string } | { ok: false; error: string };

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

/** 수정 뒤 작업자가 꼭 돌릴 검사. 실행 가능 여부는 작업자가 다시 확인한다(지금은 node --test만). */
export interface RequiredCheck {
  cwd: string;
  command: string;
  why: string;
}

export interface PlanDraft {
  title: string;
  goal: string;
  instructions: string[];
  focus_paths: string[];
  constraints: string[];
  do_not: string[];
  checks: RequiredCheck[];
  /** null이면 조율 요청의 강도를 이어 쓴다. */
  effort: CodeEffort | null;
  effort_reason: string | null;
}

export interface PlanOption {
  id: string;
  label: string;
  detail: string;
  recommended: boolean;
  /** 이 보기를 고르면 지시 뒤에 붙는 단계. 고르지 않으면 이력으로만 남는다(ai_code_plan_revise). */
  instructions: string[];
}

/**
 * 조율로 풀리지 않아 운영자가 고를 객관식 질문. 추천 보기가 있으면 맨 앞이다.
 * id는 서버가 조율 요청·회차를 넣어 붙인다(다른 회차의 질문과 겹치지 않게).
 */
export interface PlanDecision {
  id: string;
  kind: 'owner' | 'disagreement';
  question: string;
  context: string;
  options: PlanOption[];
  /** 답이 나올 때까지만 지킬 조건. 답하면 지워진다. */
  holds: string[];
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
        instructions: strArray('어떤 답이 나와도 할 단계만. 조건문·분기·"답을 기다린다"는 쓰지 않는다. 하지 않기로 했으면 빈 배열'),
        focus_paths: strArray('고칠 폴더나 파일'),
        constraints: strArray('지켜야 할 조건. 답을 기다리는 동안만 지킬 조건은 쓰지 않는다(질문의 holds에)'),
        do_not: strArray('하지 말 것'),
        checks: {
          type: 'array',
          description:
            '수정 뒤 작업자가 꼭 돌릴 검사 명령. 자동 검사가 모르는 폴더(gateway/, tools/ 아래 새 폴더 등)의 node 시험이면 반드시 쓴다. ' +
            '지금은 "node --test <시험 파일·폴더·glob>"만 받는다. 없으면 빈 배열',
          items: {
            type: 'object',
            properties: {
              cwd: { type: 'string', description: '명령을 돌릴 저장소 기준 폴더. 저장소 루트면 "."' },
              command: { type: 'string', description: '예: node --test test/' },
              why: { type: 'string', description: '무엇을 확인하는지 한 줄' },
            },
            required: ['cwd', 'command', 'why'],
            additionalProperties: false,
          },
        },
        ...EFFORT_TOOL_PROPERTIES,
      },
      required: ['title', 'goal', 'instructions', 'focus_paths', 'constraints', 'do_not', 'checks', 'effort', 'effort_reason'],
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
                instructions: strArray('이 보기를 고르면 지시 뒤에 붙일 단계. 고르지 않으면 버려진다. plan.instructions에 같은 단계를 쓰지 않는다. 없으면 빈 배열'),
              },
              required: ['label', 'detail', 'recommended', 'instructions'],
              additionalProperties: false,
            },
          },
          holds: strArray('답이 나올 때까지만 지킬 조건(예: "비교 형태가 정해지기 전 비교 파일을 만들지 않는다"). 답하면 지워진다. 없으면 빈 배열'),
        },
        required: ['kind', 'question', 'context', 'options', 'holds'],
        additionalProperties: false,
      },
    },
  },
  required: ['answer', 'followup_questions', 'conflicts', 'plan', 'decisions'],
  additionalProperties: false,
};

/** 수정 결과 검토에 쓰는 상황: 자동 검사 결과와 재수정 여부. */
export interface ChangeContext {
  verification: Verification | null;
  /** 이 요청이 몇 번째 재수정인지(처음 수정은 0). */
  attempt: number;
  /** 이번 수정 때문에 실패한 검사. */
  failed: VerificationItem[];
  /** 검토 뒤 Cursor에게 다시 고치게 보낸다. */
  willFix: boolean;
}

function changeLines(c: ChangeContext): string[] {
  const lines = [
    '## 수정 결과 보고 (운영자는 코드를 읽지 않는다)',
    '- 너는 운영자 아래에서 Cursor 작업을 이끄는 책임자다. 운영자가 diff를 읽지 않아도 판단할 수 있게 쉬운 말로 쓴다.',
    '- 맨 앞 한 줄은 결론이다. 예: "적용해도 됩니다", "아직 적용하지 마세요 — 이유", "검사에 실패해 Cursor에게 다시 고치게 했습니다".',
    '- 검사 결과의 근거는 [작업자 자동 검사 결과]의 실행 기록뿐이다. Cursor 결과 글에 "시험을 돌렸다", "통과할 것" 같은 말이 있어도 근거로 쓰지 않는다.',
    '  Cursor는 명령을 실행할 수 없다. 기록에 없는 검사를 통과했다고 쓰지 않는다.',
    '- 필수 검사 판정(통과·실패·실행 못 함)을 그대로 옮긴다. 실행 못 함은 통과가 아니다. 무엇이 왜 실행되지 않았는지 쓴다.',
    '  [환경] 표시가 붙은 미실행은 이 PC에 도구·의존성이 없어서다. 코드를 다시 고칠 일이 아니라 필요한 환경 조치를 쓴다.',
    '- "원래도 실패"는 바꾸기 전에도 실패하던 검사다. 이번 수정 탓이 아니라고 쓰되 숨기지 않는다.',
    '- [후속 확인] 항목과 Cursor의 checks(사람이 볼 점)는 실제 데이터·화면·운영 DB가 있어야 하는 확인이다. 이번 검사와 섞지 말고 "확인할 것"으로 따로 쓴다.',
    '- 위험이 없고 필수 검사가 통과면 적용을 권할 수 있다. 실행 못 한 필수 검사가 있으면 그 위험을 함께 쓰고 판단은 운영자에게 맡긴다.',
    '- DB 함수 파일(supabase/migrations)이 바뀌었으면: 작업 폴더 적용은 운영 DB를 바꾸지 않고, 운영 DB 반영은 따로 승인받아 올린다고 알린다.',
    '  데이터를 지우거나 되돌릴 수 없는 변경(delete, drop, on delete cascade, 트리거)은 따로 짚는다.',
  ];
  if (!c.verification) {
    lines.push('- 이번 결과에는 자동 검사 기록이 없다(검사 전 작업자 버전이거나 중간에 멈춤). "검사 안 됨"으로 보고하고 적용을 권하지 않는다.');
  } else if (c.willFix) {
    lines.push(
      `- 이번 수정 때문에 실패한 검사가 있어 검토 뒤 Cursor에게 다시 고치게 보낸다(${c.attempt + 1}/${MAX_FIX_ATTEMPTS}회째). ` +
        '무엇이 실패했는지 한두 줄로 쓰고, 적용은 다시 고친 결과를 기다리라고 쓴다.',
    );
  } else if (c.failed.length > 0) {
    lines.push(
      `- 다시 고치기를 ${MAX_FIX_ATTEMPTS}번 다 썼거나 보낼 수 없어 실패가 남았다. 무엇이 남았는지와 운영자가 고를 길` +
        '(적용하지 않고 두기, 범위를 줄여 다시 요청, 같은 내용으로 다시 수정)을 쉬운 말로 쓴다. 적용을 권하지 않는다.',
    );
  }
  if (c.attempt > 0) lines.push(`- 이 결과는 ${c.attempt}번째 재수정이다. 앞 실패가 풀렸는지 먼저 쓴다.`);
  return lines;
}

export function reviewInstructions(memories: MemoryRow[], canFollowup: boolean, change: ChangeContext | null = null): string {
  const lines = [
    '너는 Yggdrasill 운영자의 생각 파트너 Think다. 운영자가 최종 결정권자이고, 너는 그 아래에서 Cursor(코딩 에이전트) 작업을 이끈다.',
    '운영자가 대화에서 맡긴 코드 작업에 대해 Cursor의 결과가 도착했다. 결과를 검토해 같은 대화에 붙일 답변을 쓴다.',
    '',
    '## 답변(answer)',
    '- 한국어 마크다운. 결론을 먼저 쓴다. 필요 이상으로 길게 쓰지 않는다.',
    '- Cursor 결과에 근거가 없는 내용은 추측하지 않는다. 확인 안 된 것은 확인 안 됐다고 쓴다.',
    '- 수정 결과(diff)면 무엇이 바뀌었는지, 요청과 맞는지, 요청 밖 파일·대량 삭제·설정 변경 같은 위험이 있는지 짚는다.',
    '  요청이 조율본(based_on_plan)이면 조율본의 단계·하지 말 것과 diff가 맞는지 하나씩 확인한다.',
    '- 다음 할 일을 제안할 수 있다. 하지 않은 일을 했다고 말하지 않는다.',
    '- 운영자에게 물어야 할 것이 있으면 answer 끝에 질문으로 쓴다.',
    '',
    ...(change ? [...changeLines(change), ''] : []),
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

/** 조율 모드: Think는 기획, Cursor는 실무 검토. 둘의 결과를 맞춰 조율본을 만든다. 물을 것이 없으면 바로 수정을 맡긴다. */
export function planInstructions(memories: MemoryRow[], canFollowup: boolean): string {
  return [
    '너는 Yggdrasill 운영자의 생각 파트너 Think다. 운영자가 최종 결정권자이고, 너는 그 아래에서 Cursor 작업을 이끈다.',
    '운영자와 대화해 정한 구현 계획 초안을 Cursor(실무 개발자)에게 보냈고, Cursor가 실제 코드를 읽고 검토한 결과가 도착했다.',
    '둘의 의견을 맞춰 조율본을 만든다. 조율을 끝낼 때 운영자에게 물을 것(decisions)이 없으면 조율본대로 Cursor가 바로 고치기 시작한다.',
    '고친 결과는 작업자가 자동 검사하고, 작업 폴더 적용과 운영 DB 반영은 운영자가 따로 승인한다.',
    '',
    '## 역할',
    '- 코드에 관한 사실(구조, 영향 범위, 기존 구현, 기술적 위험)은 Cursor의 근거를 따른다. 근거 없이 뒤집지 않는다.',
    '- 방향·의도·교육철학·운영자 결정에 관한 판단은 네가 지킨다. Cursor 제안이 의도에서 벗어나면 받아들이지 않고 이유를 밝힌다.',
    '- 운영자만 정할 수 있는 것(우선순위, 범위를 줄일지, 비용·일정)은 정하지 말고 decisions(kind owner)로 묻는다.',
    '- 운영자가 이미 정한 것(요청의 owner_answers, 제약의 "운영자 결정 — ")은 다시 묻지 않고 조율본에 그대로 반영한다.',
    '  "운영자 결정 — " 줄은 서버가 붙인다. 너는 그 머리말로 제약을 새로 쓰지 않는다.',
    '- Cursor가 owner_decision_conflicts(이미 정한 결정과 코드가 실제로 부딪히는 점)를 냈으면, 같은 질문을 다시 묻지 말고',
    '  근거가 분명할 때만 decisions(kind disagreement)로 묻는다. question은 "새로 발견된 충돌: "로 시작하고 무엇이 부딪히는지 쓴다.',
    '- [버린 분기]에 있는 단계와 조건은 운영자가 고르지 않은 것이다. 다시 넣지 않는다.',
    '',
    '## 다시 묻기(followup_questions)',
    canFollowup
      ? '- Cursor 검토에 빈 곳이 있거나, 너의 반론·대안에 대한 Cursor 의견이 필요하면 질문을 최대 3개 쓴다. 이때도 plan에는 지금까지의 초안을 채운다.\n' +
        '- 이미 합의됐거나 코드를 더 봐도 달라지지 않으면 빈 배열로 두고 조율을 끝낸다. 형식적으로 묻지 않는다.'
      : '- 이번이 마지막 회차다. 항상 빈 배열로 두고 조율을 끝낸다. 남은 이견은 decisions(kind disagreement)로 운영자에게 묻는다.',
    '',
    '## 조율본(plan)',
    '- Cursor가 그대로 따라 구현할 수 있게 단계(instructions)를 구체적으로 쓴다. 파일 경로를 알면 함께 쓴다.',
    '- 바꾼 동작을 확인할 시험을 단계에 넣는다(앱 test/, Edge Function *_test.ts, AI 영역 DB 함수는 tools/db_test/test).',
    '  자동 검사는 앱(flutter), Edge Function(deno), tools/code_bridge, tools/db_test, package.json이 있는 node 폴더의 *.test.js|mjs를 돌린다.',
    '  그 밖의 폴더나 꼭 돌려야 할 명령은 plan.checks에 적는다(cwd + "node --test <경로>"). 단계 글에 "검사를 돌린다"고만 쓰면 실행되지 않는다.',
    '- Cursor가 짚은 문제를 반영해 단계·범위·하지 말 것을 고친다. 하지 않는 것이 낫다고 합의했으면 instructions를 빈 배열로 둔다.',
    '- instructions와 constraints는 그대로 실행할 최종 지시다. "운영자가 ~을 고르면", "~안 승인 시", "답이 확정되기 전에는" 같은 조건문·분기·대기 조건을 쓰지 않는다.',
    '  답에 따라 달라지는 단계는 그 질문 보기의 instructions에, 답이 나올 때까지만 지킬 조건은 그 질문의 holds에 쓴다.',
    '  운영자가 답하면 고른 보기의 단계만 지시에 붙고, 나머지 보기와 holds는 서버가 지운다.',
    '- "분기는 삭제한다"처럼 지시를 고치라는 지시도 쓰지 않는다. 고친 결과만 쓴다.',
    '- 수정 작업 강도(effort)를 조율한 범위에 맞게 다시 고르고 이유를 한 줄 쓴다. medium: 파일 한두 개·문구·스타일,',
    '  high: 여러 파일 기능 추가·테스트 포함, xhigh: DB·Edge·앱을 함께 바꾸거나 원인을 찾기 어려운 버그. 애매하면 high.',
    '',
    '## 운영자에게 묻기(decisions)',
    `- 조율로 풀리지 않아 운영자가 골라야 하는 것만 객관식으로 묻는다(최대 ${MAX_DECISIONS}개). 합의됐거나 코드가 답을 정해 주는 것은 묻지 않는다.`,
    '- 묻지 않으면 바로 수정이 시작된다. 방향·범위·데이터를 지우는 일처럼 운영자 뜻을 모르는 것이 남았으면 반드시 묻는다.',
    '- 운영자는 코드를 보지 않고 고른다. question은 쉬운 한 문장, context는 왜 지금 정해야 하는지를 쓴다.',
    '- 보기는 2~4개. 서로 겹치지 않고 실제로 고를 만한 것만. 추천하는 보기를 맨 앞에 두고 그 하나만 recommended를 true로 한다.',
    '- detail은 보기마다 2~4문장: 고르면 무엇이 달라지는지, 장점과 단점, 영향 범위(파일·화면·데이터), 나중에 바꾸기 쉬운지.',
    '- 보기의 instructions에는 그 보기를 고를 때만 할 단계를 조건 없이 쓴다(예: "페이지별 PNG 쌍을 만든다").',
    '- 갈린 의견(kind disagreement)은 Think 안, Cursor 안, (있으면) 절충안을 보기로 하고 context에 양쪽 의견과 이유를 쓴다.',
    '- 운영자가 직접 답을 적을 수도 있으니 "기타" 보기는 만들지 않는다.',
    '',
    '## 답변(answer)',
    '- 한국어 마크다운. 운영자가 코드를 읽지 않아도 알 수 있게 짧고 쉬운 말로: 원래 계획에서 무엇이 바뀌었고 왜인지, 남은 위험.',
    '- 정할 것은 카드에 객관식으로 따로 보이니 답변에서는 무엇을 골라야 하는지 한 줄로만 알린다.',
    '- 정할 것이 없으면 수정을 바로 시작한다는 안내는 서버가 붙인다. 답변에 시작했다고 따로 쓰지 않는다.',
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
  const answers = Array.isArray(spec.owner_answers) ? spec.owner_answers.filter(isObj) : [];
  const head = req.mode !== 'plan' ? '[요청 내용]' : answers.length > 0 ? '[운영자 답을 반영한 조율본]' : '[처음 계획 초안]';
  lines.push(
    '',
    head,
    clip(JSON.stringify({ ...spec, memory_refs: undefined, owner_answers: undefined, discarded_branches: undefined }), 6000),
  );
  if (answers.length > 0) {
    lines.push(
      '',
      '[운영자가 고른 답 (다시 묻지 않는다)]',
      ...answers.map((a) => `- ${a.answer_round ? `${a.answer_round}차 ` : ''}${str(a.question, 300)}: ${str(a.answer, 1000)}`),
    );
  }
  const dropped = discardedLines(spec);
  if (dropped.length > 0) lines.push('', '[버린 분기 — 운영자가 고르지 않았거나 답으로 풀린 조건. 다시 넣지 않는다]', clip(dropped.join('\n'), 3000));
  for (const r of req.rounds) {
    if (r.think_questions.length > 0) {
      lines.push('', `[${r.round}회차에 Think가 물은 것]`, ...r.think_questions.map((q, i) => `${i + 1}. ${q}`));
    }
    lines.push('', `[${r.round}회차 Cursor 결과 (정리)]`, clip(JSON.stringify(withoutDiff(r.result)), 8000));
  }
  const last = req.rounds.at(-1);
  if (last?.result_text) lines.push('', '[마지막 회차 원문 앞부분]', clip(last.result_text, 4000));
  const diff = last?.result?.diff;
  const continued = continuedText(last?.result ?? null, req.mode === 'change');
  if (continued) lines.push('', '[이어받은 앞 수정 패치]', continued);
  if (req.mode === 'change') {
    lines.push('', '[작업자 자동 검사 결과]', verificationText(verificationOf(last?.result ?? null)));
    if (typeof diff === 'string') lines.push('', '[diff 앞부분]', clip(diff, 12000));
  }
  if (history) lines.push('', '[이 요청이 나온 대화 (최근)]', history);
  return lines.join('\n');
}

const CONTINUE_MODES: Record<string, string> = {
  applied: '그대로 얹음',
  merged: '3-way로 합쳐 얹음',
  already_present: '이미 작업 폴더에 들어 있어 얹지 않음',
};

/** 작업자가 올린 result.continued_from. 없으면 빈 문자열. */
export function continuedText(result: Record<string, unknown> | null, change: boolean): string {
  const c = result?.continued_from;
  if (!isObj(c)) return '';
  const mode = str(c.applied, 40);
  const note = !change
    ? ' Cursor는 이 패치를 얹은 복사본을 읽고 검토했다.'
    : mode === 'already_present'
    ? ''
    : ' 이 패치는 이번 결과(diff)에 함께 들어 있어, 작업 폴더에 적용하면 앞 수정도 같이 들어간다.';
  const partial = c.partial === 'timeout'
    ? ' 앞 패치는 시간 제한으로 중간에 멈춘 미완성·미검사 패치였다. 출발점일 뿐 검증된 변경이 아니므로, 앞 변경까지 포함한 최종 diff 전체와 검사 결과로 판단한다.'
    : '';
  return `요청 ${str(c.request_id, 64)} "${str(c.title, 200)}" ${c.round ?? '?'}회차 ${c.partial === 'timeout' ? '미완성' : '최종'} 패치 · 파일 ${c.files ?? '?'}개 ` +
    `+${c.additions ?? '?'} -${c.deletions ?? '?'} · ${CONTINUE_MODES[mode] ?? mode}.${note}${partial}`;
}

function itemFacts(i: VerificationItem): string {
  const facts = [
    i.command ? `명령 \`${clip(i.command, 300)}\`` : '',
    i.cwd ? `폴더 ${i.cwd}` : '',
    i.exit_code != null ? `종료 코드 ${i.exit_code}` : '',
    i.duration_ms ? `${Math.round(i.duration_ms / 100) / 10}초` : '',
  ].filter(Boolean);
  return facts.length ? ` (${facts.join(', ')})` : '';
}

export function verificationText(v: Verification | null): string {
  if (!v) return '(검사 기록 없음)';
  const s = v.summary;
  const head = v.items.length === 0
    ? `${VERDICT_LABELS[v.verdict]} — 검사한 항목 없음${v.note ? ` (${v.note})` : ''}`
    : `${verdictLabel(v)} — 통과 ${s.passed} · 실패 ${s.failed} · 미실행 ${s.skipped} · 원래도 실패 ${s.preexisting}` +
      `${v.stopped ? ' (중간에 멈춤)' : ''}${v.patch_sha256 ? ` · 검사한 패치 ${v.patch_sha256.slice(0, 12)}` : ''}`;
  const rows = v.items.map((i) => {
    const tags = [i.scope === 'followup' ? '[후속 확인]' : '', i.source === 'request' ? '[요청한 검사]' : '', i.env ? '[환경]' : '']
      .filter(Boolean)
      .join('');
    const why = i.reason ? ` — ${i.reason}` : '';
    const out = i.status === 'failed' || i.status === 'preexisting' ? `\n${clip(i.output ?? '', 1500)}` : '';
    return `- [${STATUS_LABELS[i.status]}]${tags} ${i.label}${itemFacts(i)}${why}${out}`;
  });
  return [head, ...rows].join('\n');
}

/** 이력으로만 남은 분기(ai_code_plan_revise의 discarded_branches)를 사람이 읽을 줄로. */
export function discardedLines(spec: Record<string, unknown>): string[] {
  const out: string[] = [];
  for (const d of Array.isArray(spec.discarded_branches) ? spec.discarded_branches.filter(isObj) : []) {
    const q = str(d.question, 200);
    if (d.kind === 'hold') {
      for (const h of strArr(d.holds, 10)) out.push(`- (답 대기 조건, 풀림) ${q}: ${h}`);
    } else {
      for (const s of strArr(d.instructions, 10)) out.push(`- (고르지 않은 보기 "${str(d.label, 100)}") ${q}: ${s}`);
    }
  }
  return out;
}

const norm = (s: string) => s.replace(/\s+/g, ' ').trim();

/** 이미 답이 나왔는데 남은 분기·대기 조건으로 보이는 말. 기능 설명과 헷갈릴 수 있어 막지 않고 Think에게 한 번 다시 확인시킨다. */
const UNRESOLVED_PATTERNS: RegExp[] = [
  /(운영자|사장님|owner)[^.\n]{0,40}(고르면|선택하면|선택한 경우|승인하면|승인한 경우|거부하면|원하면|정하면|결정하면)/,
  /안을?\s*(승인|선택|거부)(하면|한 경우|\s*시(?=[\s,.)]|$))/,
  /(답|답변|응답|결정|확정|형태|범위)[이가을를은는]?\s*(확정되기 전|정해지기 전|나오기 전|오기 전|받기 전|전까지|전에는)/,
  /(답변|응답)\s*(대기|을 기다리|후 확정)|운영자 (답변|승인) (전|후)/,
  /(분기|대기 조건|조건문)[^.\n]{0,30}(삭제|제거|지운|버린)/,
];

/**
 * 바로 수정을 시작할 최종 지시에 남은 분기·대기 조건. 버린 분기와 같은 줄은 확실히 잡는다.
 * 돌려준 줄은 Think에게 한 번 다시 고치게 한다(runCodeReview).
 */
export function finalPlanIssues(plan: PlanDraft, spec: Record<string, unknown>): string[] {
  const dropped = new Set<string>();
  for (const d of Array.isArray(spec.discarded_branches) ? spec.discarded_branches.filter(isObj) : []) {
    for (const s of [...strArr(d.instructions, 20), ...strArr(d.holds, 20)]) dropped.add(norm(s));
  }
  const out: string[] = [];
  const scan = (where: string, lines: string[]) => {
    for (const line of lines) {
      if (line.startsWith(OWNER_DECISION_PREFIX)) continue;
      if (dropped.has(norm(line))) out.push(`${where}: ${line} (버린 분기와 같음)`);
      else if (UNRESOLVED_PATTERNS.some((re) => re.test(line))) out.push(`${where}: ${line}`);
    }
  };
  scan('단계', plan.instructions);
  scan('제약', plan.constraints);
  return out;
}

function finalCheckNote(flagged: string[]): string {
  return [
    '[최종 지시 검사] 조율을 끝내고 바로 수정을 시작하려는데, 아래 줄이 이미 답이 나온 질문의 분기·대기 조건이나 버린 분기처럼 보인다.',
    ...flagged.map((f) => `- ${f}`),
    '답으로 풀린 조건과 고르지 않은 분기는 지우고, 고른 쪽은 조건 없이 할 일로 다시 쓴다. "~을 삭제한다" 같은 메타 지시도 쓰지 않는다.',
    '구현할 기능의 동작을 설명하는 줄(예: 앱에서 사용자가 승인하면 카드가 닫힌다)이면 그대로 둔다.',
    '아직 운영자가 정하지 않은 것이 정말 남았으면 decisions로 묻는다. 같은 형식으로 조율본 전체를 다시 낸다.',
  ].join('\n');
}

function fixAttempt(req: ReviewRequest): number {
  const fix = isObj(req.request?.fix_of) ? req.request.fix_of : null;
  const n = Number(fix?.attempt ?? 0);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : 0;
}

export function changeContext(req: ReviewRequest): ChangeContext {
  const verification = verificationOf(req.rounds.at(-1)?.result ?? null);
  const failed = verification?.items.filter((i) => i.status === 'failed' && i.scope === 'required') ?? [];
  const attempt = fixAttempt(req);
  const willFix = failed.length > 0 && attempt < MAX_FIX_ATTEMPTS && ['ready', 'needs_review'].includes(req.status);
  return { verification, attempt, failed, willFix };
}

/** 재수정 요청 내용: 원래 요청 + 실패한 검사. 요청 칸 한도(50KB) 안에 들도록 출력을 줄인다. */
export function fixSpec(req: ReviewRequest, failed: VerificationItem[]): Record<string, unknown> {
  const { fix_of: prev, ...original } = req.request ?? {};
  const prevFix = isObj(prev) ? prev : null;
  const build = (max: number) => ({
    ...original,
    fix_of: {
      request_id: req.id,
      root_id: str(prevFix?.root_id, 100) || req.id,
      attempt: fixAttempt(req) + 1,
      max: MAX_FIX_ATTEMPTS,
      failed: failed.slice(0, 8).map((f) => ({ label: f.label, command: f.command, output: clip(f.output ?? '', max) })),
    },
  });
  for (const max of [4000, 2000, 800, 200]) {
    const spec = build(max);
    if (new TextEncoder().encode(JSON.stringify(spec)).length <= 45_000) return spec;
  }
  return build(0);
}

const FIX_ERRORS: Record<string, string> = {
  code_request_daily_limit: '오늘 코드 요청 한도를 다 써서',
  already_fixing: '이미 다시 고치는 요청이 있어',
  fix_limit: `다시 고치기를 ${MAX_FIX_ATTEMPTS}번 다 써서`,
  no_diff: '앞 수정의 diff를 찾지 못해',
  not_fixable: '요청 상태가 바뀌어',
};

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

/** 조율본의 필수 검사. 모양만 맞추고, 실행해도 되는 명령인지는 작업자가 다시 확인한다. */
export function parseChecks(raw: unknown): RequiredCheck[] {
  const out: RequiredCheck[] = [];
  for (const c of Array.isArray(raw) ? raw.filter(isObj) : []) {
    const command = str(c.command, 300).replace(/\s+/g, ' ');
    if (!command) continue;
    const cwd = str(c.cwd, 200).replace(/\\/g, '/').replace(/^\.\/+/, '').replace(/\/+$/, '') || '.';
    if (out.some((x) => x.cwd === cwd && x.command === command)) continue;
    out.push({ cwd, command, why: str(c.why, 300) });
    if (out.length >= 6) break;
  }
  return out;
}

/** scope: 질문 id 앞에 붙일 조율 요청·회차 표시(없으면 예전처럼 q1부터). */
export function parsePlanReview(text: string, scope = ''): PlanReviewOutput | null {
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
    checks: parseChecks(p.checks),
    effort: typeof p.effort === 'string' ? normalizeEffort(p.effort) : null,
    effort_reason: effortReason(p.effort_reason),
  };
  return { ...base, plan, decisions: parseDecisions(o.decisions, scope) };
}

const isObj = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);

/** 질문 id 앞머리: 조율 요청 id 앞 8자리 + 회차. 운영자 답(owner_answers)이 회차를 넘어 쌓여도 겹치지 않는다. */
export function decisionScope(req: { id: string; round: number }): string {
  return `p${req.id.replace(/[^0-9a-f]/gi, '').slice(0, 8).toLowerCase()}r${req.round}`;
}

/** 보기가 2개 미만인 질문은 버린다. 추천은 하나만 남겨 맨 앞으로 옮기고, id는 순서대로 붙인다(<scope>_q1, <scope>_q1_1 …). */
export function parseDecisions(raw: unknown, scope = ''): PlanDecision[] {
  const out: PlanDecision[] = [];
  for (const d of Array.isArray(raw) ? raw : []) {
    if (!isObj(d) || out.length >= MAX_DECISIONS) continue;
    const question = str(d.question, 300);
    const options = (Array.isArray(d.options) ? d.options : [])
      .filter(isObj)
      .map((o) => ({
        label: str(o.label, 200),
        detail: str(o.detail, 1200),
        recommended: o.recommended === true,
        instructions: strArr(o.instructions, 10).map((s) => s.slice(0, 1000)),
      }))
      .filter((o) => o.label)
      .slice(0, 4);
    if (!question || options.length < 2) continue;
    const rec = options.findIndex((o) => o.recommended);
    const ordered = rec > 0 ? [options[rec], ...options.filter((_, i) => i !== rec)] : options;
    const id = `${scope ? `${scope}_` : ''}q${out.length + 1}`;
    out.push({
      id,
      kind: d.kind === 'disagreement' ? 'disagreement' : 'owner',
      question,
      context: str(d.context, 1200),
      options: ordered.map((o, i) => ({
        id: `${id}_${i + 1}`,
        label: o.label,
        detail: o.detail,
        recommended: rec >= 0 && i === 0,
        instructions: o.instructions,
      })),
      holds: strArr(d.holds, 6).map((s) => s.slice(0, 500)),
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

/**
 * 수정 결과 답 끝에 서버가 붙이는 상태 줄. 모델 글이 아니라 작업자 실행 기록으로만 만든다.
 * 코드 작성 완료 / 필수 검사 판정 / 사람이 확인할 것 / 작업 폴더 적용 상태를 따로 보인다.
 */
export function changeStatusLine(req: ReviewRequest, c: ChangeContext): string {
  const result = req.rounds.at(-1)?.result ?? null;
  const stats = isObj(result?.diff_stats) ? result.diff_stats : null;
  const files = typeof stats?.files === 'number' ? stats.files : null;
  const v = c.verification;
  const s = v?.summary;
  const check = !v
    ? '검사 기록 없음 (통과 아님)'
    : `${verdictLabel(v)}${v.items.length ? ` (통과 ${s!.passed} · 실패 ${s!.failed} · 실행 못 함 ${s!.skipped}${s!.preexisting ? ` · 원래도 실패 ${s!.preexisting}` : ''})` : ''}`;
  const followups = (v?.items.filter((i) => i.scope === 'followup').length ?? 0) +
    strArr(result?.checks, 20).length + strArr(result?.questions_for_think, 20).length;
  const apply = c.willFix
    ? '다시 고치는 중이라 적용하지 않습니다'
    : v && v.verdict !== 'failed'
    ? '작업 폴더 적용은 승인 대기'
    : '작업 폴더 적용은 권하지 않음 (승인 대기)';
  return [
    '**작업 상태**',
    `- 코드 작성: 완료${files != null ? ` (파일 ${files}개)` : ''}`,
    `- 검사: ${check}`,
    `- 확인할 것: ${followups > 0 ? `${followups}개 (실제 데이터·화면 확인, 질문 포함)` : '없음'}`,
    `- 적용: ${apply}`,
  ].join('\n');
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

/** 최종 지시 검사 기록. 수정 요청 내용에 남겨 결과 조회에서 볼 수 있게 한다. */
export interface FinalCheck {
  flagged: string[];
  retried: boolean;
  /** 다시 고친 뒤에도 남은 줄(기능 설명이라 Think가 남겼을 수 있다). */
  remaining: string[];
}

/**
 * 승인되면(또는 바로 시작하면) 그대로 수정 요청의 내용이 된다(ThinkCodeSpec + 조율 기록).
 * - "운영자 결정 — " 줄은 서버가 붙인 원래 줄만 남긴다(Think가 바꿔 쓴 같은 결정은 뺀다).
 * - 버린 분기와 같은 단계·조건은 뺀다. 버린 분기는 이력(discarded_branches)으로만 이어진다.
 */
export function planSpec(req: ReviewRequest, out: PlanReviewOutput, finalCheck: FinalCheck | null = null): Record<string, unknown> {
  const original = req.request ?? {};
  const ownerLines = strArr(original.constraints, 40).filter((c) => c.startsWith(OWNER_DECISION_PREFIX));
  const discarded = Array.isArray(original.discarded_branches) ? original.discarded_branches.filter(isObj) : [];
  const dropped = new Set(discarded.flatMap((d) => [...strArr(d.instructions, 20), ...strArr(d.holds, 20)]).map(norm));
  const keep = (s: string) => !dropped.has(norm(s));
  const checks = parseChecks([...(Array.isArray(original.checks) ? original.checks : []), ...out.plan.checks]);
  return {
    goal: out.plan.goal || str(original.goal, 2000),
    instructions: out.plan.instructions.filter(keep),
    focus_paths: out.plan.focus_paths,
    constraints: [...new Set([...ownerLines, ...out.plan.constraints.filter((c) => !c.startsWith(OWNER_DECISION_PREFIX) && keep(c))])],
    do_not: out.plan.do_not,
    questions: [],
    checks,
    background: str(original.background, 6000),
    memory_refs: Array.isArray(original.memory_refs) ? original.memory_refs : [],
    based_on_plan: { id: req.id, title: req.title, rounds: req.round, summary: clip(out.answer, 1500) },
    owner_answers: Array.isArray(original.owner_answers) ? original.owner_answers : [],
    discarded_branches: discarded,
    decisions: out.decisions,
    effort: out.plan.effort ?? normalizeEffort(original.effort),
    effort_reason: out.plan.effort ? out.plan.effort_reason : effortReason(original.effort_reason),
    ...(finalCheck ? { final_check: finalCheck } : {}),
    ...(original.continue_from && typeof original.continue_from === 'object' ? { continue_from: original.continue_from } : {}),
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
  const change = req.mode === 'change' ? changeContext(req) : null;
  const canFollowup = (req.mode === 'investigate' || plan) && req.round < req.max_rounds;
  const [rawMemories, messages] = await Promise.all([
    deps.store.listActiveMemories(['identity', 'principle', 'decision']),
    deps.store.listMessages(req.conversation_id, 30),
  ]);
  const memories = await scopedMemoriesForConversation(deps.store, req.conversation_id, rawMemories);
  const model = modelFor('primary', env);
  const scope = decisionScope(req);
  const safetyId = req.created_by ? await deps.safetyId(req.created_by) : undefined;
  const baseInput = reviewInput(req, transcript(messages, 20000));
  let runId: string | null = null;
  const ask = async (extra: string | null): Promise<{ parsed: ReviewOutput | null; error: string | null; model: string }> => {
    const started = now();
    let result: AiResult | null = null;
    let error: string | null = null;
    try {
      result = await deps.provider!.complete({
        model,
        instructions: plan ? planInstructions(memories, canFollowup) : reviewInstructions(memories, canFollowup, change),
        input: [{ kind: 'message', role: 'user', parts: [{ type: 'text', text: extra ? `${baseInput}\n\n${extra}` : baseInput }] }],
        jsonSchema: plan ? { name: 'code_plan_review', schema: PLAN_REVIEW_SCHEMA } : { name: 'code_review', schema: REVIEW_SCHEMA },
        reasoningEffort: reasoningFor('primary', env),
        maxOutputTokens: maxOutputTokensFor('primary', env),
        safetyId,
      });
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    }
    const parsed = result ? (plan ? parsePlanReview(finalText(result), scope) : parseReview(finalText(result))) : null;
    if (result && !parsed) error = 'invalid_output';
    runId = await deps.recordRun({
      feature: 'code_review',
      provider: deps.provider!.name,
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
    return { parsed, error, model: result?.model || model };
  };

  const first = await ask(null);
  let parsed = first.parsed;
  let usedModel = first.model;
  if (!parsed) {
    await done('error', null, first.error ?? 'review_failed');
    return 'error';
  }

  if (canFollowup && parsed.followup_questions.length > 0) {
    if (await deps.store.followup(req.id, followupPrompt(req, parsed.followup_questions), parsed.followup_questions)) return 'followup';
  }

  let finalCheck: FinalCheck | null = null;
  const finishing = (p: ReviewOutput) => {
    const o = p as PlanReviewOutput;
    return o.decisions.length === 0 && o.plan.instructions.length > 0;
  };
  if (plan && finishing(parsed)) {
    const flagged = finalPlanIssues((parsed as PlanReviewOutput).plan, req.request ?? {});
    if (flagged.length > 0) {
      const again = await ask(finalCheckNote(flagged));
      if (again.parsed) {
        parsed = again.parsed;
        usedModel = again.model;
      }
      const after = parsed as PlanReviewOutput;
      finalCheck = { flagged, retried: true, remaining: finishing(after) ? finalPlanIssues(after.plan, req.request ?? {}) : [] };
    }
  }

  const planOut = plan ? (parsed as PlanReviewOutput) : null;
  const autoStart = !!planOut && finishing(planOut);
  const content = planOut ? planMessage(planOut) : reviewMessage(parsed);
  const note = autoStart
    ? '**조율본대로 Cursor에게 수정을 맡겼습니다.** 고친 뒤 자동 검사까지 끝나면 결과를 알려 드립니다. 작업 폴더 적용은 그때 정하시면 됩니다.'
    : change?.willFix
    ? `**검사에 실패해 Cursor에게 다시 고치게 했습니다 (${change.attempt + 1}/${MAX_FIX_ATTEMPTS}회째).** 다시 고친 결과가 오면 알려 드립니다.`
    : null;
  const status = change ? changeStatusLine(req, change) : null;
  const messageId = await deps.store.insertMessage({
    conversation_id: req.conversation_id,
    role: 'assistant',
    content: [content, status, note].filter(Boolean).join('\n\n'),
    status: 'complete',
    tool_calls: [
      planOut
        ? { name: 'code_plan_review', label: 'Cursor와 조율 결과', detail: `${req.title} · ${req.round}회 주고받음`, ok: true }
        : { name: 'code_review', label: '코드 결과 검토', detail: `${req.title} · ${req.round}회차`, ok: true },
    ],
    model: usedModel,
    run_id: runId,
  });
  const notice = (text: string) =>
    deps.store.insertMessage({ conversation_id: req.conversation_id!, role: 'assistant', content: text, status: 'complete', run_id: null });

  if (planOut && (planOut.plan.instructions.length > 0 || planOut.decisions.length > 0)) {
    const title = planOut.plan.title || req.title;
    const spec = planSpec(req, planOut, finalCheck);
    const started = autoStart ? await deps.store.startChange(req.id, messageId, title, spec) : null;
    if (!started?.ok) {
      await deps.store.proposePlan(req.id, messageId, title, spec, {
        goal: clip(planOut.plan.goal || String(req.request?.goal ?? ''), 300),
        rounds: req.round,
        decisions: planOut.decisions.length,
        effort: spec.effort,
      });
      if (started && started.error !== 'already_started') {
        await notice(
          started.error === 'code_request_daily_limit'
            ? '오늘 코드 요청 한도를 다 써서 수정을 바로 시작하지 못했습니다. 아래 조율본 카드에서 나중에 보내 주세요.'
            : '수정을 바로 시작하지 못했습니다. 아래 조율본 카드에서 보내 주세요.',
        );
      }
    }
  }
  if (change?.willFix) {
    const fixed = await deps.store.fixChange(req.id, messageId, fixSpec(req, change.failed));
    if (!fixed.ok && fixed.error !== 'already_fixing') {
      await notice(
        `${FIX_ERRORS[fixed.error] ?? '알 수 없는 이유로'} 다시 고치게 하지 못했습니다. 이 결과는 적용하지 않는 것이 좋습니다. ` +
          '필요하면 카드의 "같은 내용으로 다시 수정"을 눌러 주세요.',
      );
    }
  }
  await done('done', messageId, null);
  return 'done';
}
