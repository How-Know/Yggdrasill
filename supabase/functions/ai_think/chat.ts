// Think 대화 한 턴: 컨텍스트 조립 → 모델 스트리밍 → (도구 호출 반복) → 저장·기록.
// AI 호출이 실패해도 사용자 메시지와 오류 상태는 남긴다.

import {
  codeSessionCostUsd,
  estimateCostUsd,
  maxOutputTokensFor,
  modelFor,
  reasoningFor,
  type EnvReader,
  denoEnv,
} from '../_shared/ai/config.ts';
import {
  AiProviderError,
  addUsage,
  emptyUsage,
  type AiFileCitation,
  type AiInputItem,
  type AiProvider,
  type AiResult,
  type AiSandboxSession,
  type AiSource,
  type AiUsage,
} from '../_shared/ai/types.ts';
import type { AiRunRecord } from '../_shared/ai/usage.ts';
import { ORGANIZE_KINDS, restoredContextNote, workStateNote, type ActionToolContext, type WorkState } from './actions.ts';
import { loadConceptReference, type ConceptReferenceRead } from './concept_reference.ts';
import { loadCriterionReference, type CriterionReferenceRead } from './criterion_reference.ts';
import { CONCEPT_DRAFT_CHAT_TITLE, loadConceptDraftReference, type ConceptDraftReferenceRead } from './concept_draft_reference.ts';
import {
  CONCEPT_SOURCE_TOOL_NAMES,
  SOURCE_ADJACENT_LIMIT,
  SOURCE_IMAGE_LIMIT,
  SOURCE_PAGE_TOOL_NAME,
  SOURCE_PAGE_TOOL_TIMEOUT_MS,
} from './concept_source_tools.ts';
import { CONSULT_TOOL_NAME, runConsult, type ConsultState } from './consult.ts';
import { BATCH_TOOL_NAME, runReviewBatch } from './concept_review_batch.ts';
import { COURSE_MAP_TOOL_NAMES } from './course_map_tools.ts';
import {
  SPREADSHEET_MIME,
  buildThinkContext,
  normalizeProgressSummary,
  normalizeSplitSummary,
  type AttachmentRef,
  type ThinkContextStore,
} from './context.ts';
import type { DeliveredMaterial, DepartmentId } from './access_context.ts';
import {
  featureReady,
  isExclusionRequest,
  isImportanceRequest,
  isOrganizeRequest,
  isSplitRequest,
  type ThinkFeatures,
} from './features.ts';
import type { DepartmentCriteria } from './organize.ts';
import {
  ROLE_PROFILE_VERSION,
  THINK_PROMPT_VERSION,
  TITLE_PROMPT_VERSION,
  clip,
  featureStatusNote,
  relayInstructions,
  spreadsheetNote,
  titleInstructions,
  type ThinkRoleId,
} from './prompts.ts';
import { resolveRelayVerdict, splitRelayBlock, type RelayAsker, type RelayVerdict } from './relay_verdict.ts';
import { ACTING_TOOL_NAMES, TOOL_LABELS, runThinkTool, thinkToolsFor, type ThinkToolSource } from './tools.ts';

export interface ConversationRow {
  id: string;
  title: string;
  status: string;
  scope_type: string;
  scope_id: string | null;
  /** 'cursor'면 커서가 시작한 대화. 마이그레이션 전 DB에는 열이 없어 비어 있다. */
  origin?: string;
  /** false면 사용자가 나누기 제안을 거절한 대화. 마이그레이션 전 DB에는 열이 없어 비어 있다. */
  auto_split_suggestions?: boolean;
  split_summary?: Record<string, unknown> | null;
  split_from_conversation_id?: string | null;
  think_role_id?: import('./prompts.ts').ThinkRoleId;
  role_profile_version?: string | null;
  extra_ref_departments?: import('./access_context.ts').DepartmentId[];
  /** 승인된 진행 요약. 마이그레이션 전 DB에는 열이 없어 비어 있다. */
  progress_summary?: Record<string, unknown> | null;
  /** 사용자가 고른 다른 대화. 없으면 이전 자료를 넣지 않는다. */
  context_from_conversation_id?: string | null;
}

export interface NewMessage {
  conversation_id: string;
  role: 'user' | 'assistant';
  content: string;
  status: 'complete' | 'error' | 'stopped';
  attachments?: AttachmentRef[];
  sources?: AiSource[];
  tool_calls?: ToolTrace[];
  commentary?: string | null;
  model?: string | null;
  run_id?: string | null;
  /** 커서가 보낸 질문(user)일 때만 채운다. 비어 있으면 열을 보내지 않는다(마이그레이션 전 DB 호환). */
  asked_by?: RelayAsker | null;
  /** 커서 질문에 대한 답(assistant)의 판정. */
  relay?: RelayVerdict | null;
}

export interface ThinkPersistence {
  getConversation(id: string): Promise<ConversationRow | null>;
  createConversation(title: string, origin?: 'cursor'): Promise<ConversationRow>;
  updateConversationTitle(id: string, title: string): Promise<void>;
  insertMessage(msg: NewMessage): Promise<string>;
  getWorkState(conversationId: string): Promise<WorkState>;
  attachActions(ids: string[], messageId: string): Promise<void>;
  loadConversationAccess?(conversationId: string, rolesFeatureReady: boolean): Promise<import('./access_context.ts').ConversationAccessState>;
  setConversationRole?(conversationId: string, role: ThinkRoleId, extraRefs: DepartmentId[], profileVersion: string): Promise<void>;
  listLinkedDocumentBodies?(
    conversationId: string,
    allowedNodeIds: Set<string>,
  ): Promise<import('./context.ts').LinkedDocumentBody[]>;
  saveMessageContextSnapshot?(input: {
    messageId: string;
    runId: string | null;
    thinkRoleId: string;
    roleProfileVersion: string | null;
    access: import('./access_context.ts').ConversationAccessState;
    materials: import('./access_context.ts').DeliveredMaterial[];
  }): Promise<void>;
  /** 자동 정리 제안 설정(ai_platform_settings.auto_organize_enabled). 기능이 준비된 요청에서만 읽는다. */
  getAutoOrganizeEnabled?(): Promise<boolean>;
  getDepartmentCriteria?(department: string): Promise<DepartmentCriteria | null>;
  /** 이 대화에서 확인을 기다리는 정리 제안 수(코드·삭제 제안 제외). */
  countPendingOrganize?(conversationId: string): Promise<number>;
  /** 첨부 원본을 읽는다(엑셀을 파이썬 실행 환경에 올릴 때). */
  readAttachment?(path: string): Promise<Uint8Array>;
  /** 파이썬 실행 환경이 만든 파일을 첨부 버킷에 저장한다. */
  saveAnswerFile?(userId: string, name: string, mime: string, bytes: Uint8Array): Promise<AttachmentRef>;
  /** 개념 탭이 고른 개념의 저장본과 분류 경로(사용자 권한). 없거나 볼 수 없으면 concept=null. */
  getConceptReference?(conceptId: string): Promise<ConceptReferenceRead>;
  /** 개념 탭이 고른 정리 기준의 확정본·저장된 초안과 이은 개념(사용자 권한). 없거나 볼 수 없으면 criterion=null. */
  getCriterionReference?(criterionId: string): Promise<CriterionReferenceRead>;
  /** 검토 창의 개념 초안 저장본·쓴 기준·확정 유형·영역(사용자 권한). 없거나 볼 수 없으면 draft=null. */
  getConceptDraftReference?(draftId: string): Promise<ConceptDraftReferenceRead>;
}

export type ThinkStore = ThinkContextStore & ThinkToolSource & ThinkPersistence;

export interface ToolTrace {
  name: string;
  label: string;
  detail: string;
  ok: boolean;
}

export type Emit = (event: string, data: Record<string, unknown>) => void;

export interface ChatDeps {
  provider: AiProvider;
  store: ThinkStore;
  recordRun: (rec: AiRunRecord) => Promise<string | null>;
  emit: Emit;
  env?: EnvReader;
  now?: () => number;
}

export interface ChatInput {
  /** 커서 질문(relay)은 사람이 아니라서 빈 문자열이다. 기록에는 null로 남긴다. */
  userId: string;
  safetyId: string;
  conversationId: string | null;
  message: string;
  attachments: AttachmentRef[];
  deep: boolean;
  webSearch: boolean;
  signal: AbortSignal;
  startedAt: number;
  wallClockMs: number;
  /** 서버가 이번 요청에서 계산한 기능 상태. 없으면 상태 메모를 넣지 않고 기능 도구도 노출하지 않는다. */
  features?: ThinkFeatures | null;
  /**
   * 커서가 보낸 질문(ai_think_relay, ai_code_bridge ask_think). 조회 도구만 주고, 커서가 시작한 대화에만 잇고,
   * 답 끝의 판정 블록을 떼어 서버가 다시 판정한다. title이 있으면 새 대화 제목으로 쓰고 제목을 만들지 않는다.
   */
  relay?: { asker: RelayAsker; title?: string | null } | null;
  /**
   * 새 대화를 만들 때 사용자가 고른 역할·참조 부서. 역할 기능이 준비됐을 때만 대화에 저장하고(ai_conversation_set_think_role),
   * 이어지는 대화에서는 무시한다(저장된 대화 값을 쓴다).
   */
  newConversationRole?: { thinkRoleId: ThinkRoleId; extraRefDepartments: DepartmentId[] } | null;
  /**
   * 개념 탭에서 고른 개념(concepts.id). 기존 대화에만 붙는다. 앱은 본문을 보내지 않고, 서버가 요청마다
   * 최신 저장본을 다시 읽어 참고 블록으로만 넣는다.
   */
  conceptId?: string | null;
  /** 개념 상세에서 고른 서술(concept_statements.id). conceptId와 함께만 온다. null = 기본 서술(개념 본문). */
  conceptStatementId?: string | null;
  /** 개념 탭에서 고른 정리 기준(concept_criteria.id). conceptId와 같은 규칙: 기존 대화에만, 본문 없이 id만. */
  criterionId?: string | null;
  /**
   * 개념 초안 검토 창에서 보낸 질문의 초안(concept_drafts.id). 새 대화에도 붙는다(그때 제목은 고정).
   * 앱은 초안 본문·저장하지 않은 편집을 보내지 않고, 서버가 요청마다 저장본을 다시 읽는다.
   */
  conceptDraftId?: string | null;
  /** 답변 뒤 자동 이어하기 실행. 관문이 준 임대 gen만 쓰고 넘겨받지 않으며, 저장 개수에 한도가 있다. */
  reviewJobRun?: { jobId: string; gen: number; maxItems: number } | null;
}

export interface ChatOutcome {
  conversationId: string | null;
  userMessageId: string | null;
  assistantMessageId: string | null;
  runId: string | null;
  status: 'complete' | 'error' | 'stopped';
  errorCode?: string;
  errorMessage?: string | null;
  /** 저장한 답 본문(판정 블록을 뗀 것). */
  content?: string;
  relay?: RelayVerdict | null;
  costUsd?: number | null;
}

export const MAX_TOOL_ROUNDS = 6;
/** 묶음 검수가 끝나야 하는 시각 = 요청 한도 - 이 값. 그 뒤 마지막 답변(도구 없음)을 쓸 시간이다. */
export const REVIEW_BATCH_FINAL_RESERVE_MS = 30_000;

/** 파이썬 실행 환경이 만든 파일 중 답변에 붙이는 형식. */
export const ANSWER_FILE_MIME: Record<string, string> = {
  '.xlsx': SPREADSHEET_MIME,
  '.csv': 'text/csv',
  '.png': 'image/png',
};
export const MAX_ANSWER_FILES = 6;
export const MAX_ANSWER_FILE_BYTES = 20 * 1024 * 1024;
const ANSWER_FILE_COLLECT_MS = 30000;

function answerFileMime(name: string): string | null {
  const i = name.lastIndexOf('.');
  return i >= 0 ? ANSWER_FILE_MIME[name.slice(i).toLowerCase()] ?? null : null;
}

function fallbackTitle(message: string): string {
  const firstLine = message.trim().split('\n')[0] ?? '';
  return clip(firstLine, 30) || '새 대화';
}

function sanitizeTitle(raw: string): string | null {
  const t = raw.replace(/["'“”‘’`]/g, '').replace(/[.。]+$/, '').replace(/\s+/g, ' ').trim();
  return t ? clip(t, 40) : null;
}

function abortReason(signal: AbortSignal): 'stopped' | 'timeout' {
  const r = signal.reason;
  if (r === 'client_closed') return 'stopped';
  if (r instanceof DOMException && r.name === 'TimeoutError') return 'timeout';
  return 'stopped';
}

function dedupeSources(sources: AiSource[]): AiSource[] {
  const seen = new Set<string>();
  return sources.filter((s) => {
    if (!s.url || seen.has(s.url)) return false;
    seen.add(s.url);
    return true;
  });
}

async function generateTitle(deps: ChatDeps, input: ChatInput, conversationId: string): Promise<void> {
  const env = deps.env ?? denoEnv;
  const model = modelFor('fast', env);
  const started = (deps.now ?? Date.now)();
  let result: AiResult | null = null;
  let error: string | null = null;
  try {
    result = await deps.provider.complete(
      {
        model,
        instructions: titleInstructions(),
        input: [{ kind: 'message', role: 'user', parts: [{ type: 'text', text: clip(input.message, 2000) }] }],
        reasoningEffort: reasoningFor('fast', env),
        maxOutputTokens: 60,
        safetyId: input.safetyId,
      },
      input.signal,
    );
    const title = sanitizeTitle(result.messages.map((m) => m.text).join(' '));
    if (title) {
      await deps.store.updateConversationTitle(conversationId, title);
      deps.emit('title', { conversation_id: conversationId, title });
    }
  } catch (e) {
    error = e instanceof Error ? e.message : String(e);
  }
  await deps.recordRun({
    feature: 'think_title',
    provider: deps.provider.name,
    model: result?.model || model,
    promptVersion: TITLE_PROMPT_VERSION,
    status: error ? 'error' : 'ok',
    error,
    usage: result?.usage ?? emptyUsage(),
    costUsd: result ? estimateCostUsd(result.model || model, result.usage, 0, env) : null,
    latencyMs: (deps.now ?? Date.now)() - started,
    conversationId,
    createdBy: input.userId || null,
  });
}

export async function runThinkChat(input: ChatInput, deps: ChatDeps): Promise<ChatOutcome> {
  const env = deps.env ?? denoEnv;
  const now = deps.now ?? Date.now;
  const tier = input.deep ? 'deep' : 'primary';
  const model = modelFor(tier, env);
  const emit = deps.emit;

  // 1) 대화 준비
  const relay = input.relay ?? null;
  const relayTitle = relay?.title ? clip(relay.title, 40) : null;
  const draftId = relay ? null : input.conceptDraftId ?? null;
  let conversation: ConversationRow | null = null;
  let isNew = false;
  if (input.conversationId) {
    conversation = await deps.store.getConversation(input.conversationId);
    if (!conversation) {
      emit('error', { code: 'conversation_not_found', message: '대화를 찾을 수 없습니다.' });
      return { conversationId: null, userMessageId: null, assistantMessageId: null, runId: null, status: 'error', errorCode: 'conversation_not_found' };
    }
    if (relay && conversation.origin !== 'cursor') {
      emit('error', { code: 'relay_conversation_not_cursor', message: '커서는 커서가 시작한 대화에만 이어 물을 수 있습니다.' });
      return {
        conversationId: null,
        userMessageId: null,
        assistantMessageId: null,
        runId: null,
        status: 'error',
        errorCode: 'relay_conversation_not_cursor',
      };
    }
  } else {
    conversation = relay
      ? await deps.store.createConversation(relayTitle ?? fallbackTitle(input.message), 'cursor')
      : await deps.store.createConversation(draftId ? CONCEPT_DRAFT_CHAT_TITLE : fallbackTitle(input.message));
    isNew = true;
  }
  const conversationId = conversation.id;

  // 나누기 도구는 기능이 준비됐고, 앞 대화가 있고, 이 대화에서 거절되지 않았거나 사용자가 직접 요청했을 때만 노출한다.
  // 커서 질문에는 노출하지 않는다.
  const features = input.features ?? null;
  // 자동 정리 제안이 꺼져 있으면 사용자가 이번 메시지에서 직접 정리를 요청할 때만 분류·나누기·기억·넘기기·정리 도구를 준다.
  // 기능이 준비되지 않은 환경(옛 DB·앱)에는 설정이 없으므로 예전처럼 동작한다. 설정을 읽지 못하면 꺼진 것으로 본다.
  const organizeReady = !relay && featureReady(features, 'auto_organize');
  let autoOrganize: boolean | null = null;
  if (organizeReady && deps.store.getAutoOrganizeEnabled) {
    autoOrganize = await deps.store.getAutoOrganizeEnabled().catch((e) => {
      console.error('[ai_think] auto organize setting failed:', e instanceof Error ? e.message : String(e));
      return null;
    });
  }
  const userAskedOrganize = isOrganizeRequest(input.message);
  const proactive = !organizeReady || autoOrganize === true || userAskedOrganize;
  const splitSuppressed = conversation.auto_split_suggestions === false;
  const userAskedSplit = isSplitRequest(input.message);
  const splitAllowed = !relay && featureReady(features, 'conversation_split') && !isNew && (!splitSuppressed || userAskedSplit) &&
    proactive;
  const rolesReady = featureReady(features, 'think_roles');
  const memoryAllowed = !relay && featureReady(features, 'memory_proposals') && proactive;
  const courseMapAllowed = !relay && featureReady(features, 'course_map_actions');
  const conceptReviewAllowed = courseMapAllowed && featureReady(features, 'concept_review');
  const conceptRelationAllowed = courseMapAllowed && featureReady(features, 'concept_relation_change');
  const conceptSourceAllowed = courseMapAllowed && featureReady(features, 'concept_source_pages');
  const reviewJobsAllowed = conceptReviewAllowed && featureReady(features, 'concept_review_jobs');
  const reviewBatchAllowed = reviewJobsAllowed && !input.reviewJobRun && featureReady(features, 'concept_review_job_batch');

  // 새 대화에 고른 역할은 첫 답변 전에 저장한다. 저장하지 못하면 총괄로 답하고 그렇게 알린다.
  const wanted = isNew && !relay && rolesReady ? input.newConversationRole ?? null : null;
  if (wanted && (wanted.thinkRoleId !== 'lead' || wanted.extraRefDepartments.length > 0) && deps.store.setConversationRole) {
    try {
      await deps.store.setConversationRole(conversationId, wanted.thinkRoleId, wanted.extraRefDepartments, ROLE_PROFILE_VERSION);
    } catch (e) {
      console.error('[ai_think] set role failed:', e instanceof Error ? e.message : String(e));
      emit('notice', { code: 'role_not_applied' });
    }
  }

  // 개념 탭 질문: 대화를 확인한 뒤 고른 개념의 최신 저장본과 분류 경로를 사용자 권한으로 다시 읽는다.
  // 읽지 못하면 "읽지 못했다"는 블록만 넣고 앞 요청의 본문은 쓰지 않는다. 원문은 어디에도 저장하지 않는다.
  const conceptRef = input.conceptId && !relay && !isNew
    ? await loadConceptReference(
      deps.store.getConceptReference?.bind(deps.store) ?? null,
      input.conceptId,
      input.conceptStatementId ?? null,
    )
    : null;
  const criterionRef = input.criterionId && !relay && !isNew
    ? await loadCriterionReference(deps.store.getCriterionReference?.bind(deps.store) ?? null, input.criterionId)
    : null;
  // 검토 창 질문: 새 대화여도 초안 저장본을 읽는다. 열린 초안을 읽었을 때만 제안 도구를 준다.
  const draftRef = draftId
    ? await loadConceptDraftReference(deps.store.getConceptDraftReference?.bind(deps.store) ?? null, draftId)
    : null;
  const draftTools = draftRef?.open && (draftRef.status === 'ok' || draftRef.status === 'truncated') ? draftRef : null;

  // 2) 컨텍스트는 이번 메시지를 저장하기 전에 만든다(지난 대화에 이번 질문이 중복되지 않도록).
  //    역할·참조 부서·자료 링크는 요청마다 DB에서 다시 읽는다(앱이 보낸 값이 아니라 저장된 값).
  const splitSummary = normalizeSplitSummary(conversation.split_summary);
  const access = deps.store.loadConversationAccess
    ? await deps.store.loadConversationAccess(conversationId, rolesReady)
    : null;
  // 부서 협의·넘기기는 역할 범위가 실제로 적용된 대화에서만 쓴다.
  const departmentsAllowed = !relay && featureReady(features, 'department_work') && access?.rolesFeatureReady === true;
  const currentRole = access?.thinkRoleId ?? conversation.think_role_id ?? 'lead';
  const deliveredMap = new Map<string, DeliveredMaterial>();
  const recordDelivered = (ref: DeliveredMaterial) => {
    deliveredMap.set(`${ref.kind}:${ref.id}`, ref);
  };
  const organizeTools = organizeReady && proactive;
  let criteria: DepartmentCriteria | null = null;
  if (organizeReady && access?.rolesFeatureReady === true && deps.store.getDepartmentCriteria) {
    criteria = await deps.store.getDepartmentCriteria(currentRole).catch((e) => {
      console.error('[ai_think] department criteria failed:', e instanceof Error ? e.message : String(e));
      return null;
    });
  }
  const criteriaAllowed = organizeTools && criteria !== null;
  let workState: WorkState | null = null;
  let workNote: string | null = null;
  if (!isNew) {
    try {
      workState = await deps.store.getWorkState(conversationId);
      workNote = workStateNote(workState);
    } catch (e) {
      console.error('[ai_think] work state failed:', e instanceof Error ? e.message : String(e));
      workNote = '[이 대화의 작업 상태를 읽지 못했다. 작업이 없는 것이 아니다. 이 실패를 근거로 새 작업이나 기억 제안을 만들지 않는다.]';
    }
  }
  let pendingOrganize: number | null = null;
  if (organizeReady) {
    pendingOrganize = isNew
      ? 0
      : deps.store.countPendingOrganize
      ? await deps.store.countPendingOrganize(conversationId).catch(() => null)
      : workState
      ? workState.actions.filter((a) => a.status === 'proposed' && !a.superseded && ORGANIZE_KINDS.has(a.kind)).length
      : null;
  }
  const progressView = normalizeProgressSummary(conversation.progress_summary);
  const approvedAt = progressView?.approved_at ? Date.parse(progressView.approved_at) : Number.NaN;
  const excludedAfter = Number.isFinite(approvedAt) &&
    (workState?.actions ?? []).some((a) =>
      a.kind === 'exclude_context' && a.status === 'applied' && a.decided_at != null && Date.parse(a.decided_at) > approvedAt
    );
  const organizeItems = organizeReady
    ? [
      ...(proactive ? ['분류'] : []),
      ...(splitAllowed ? ['나누기'] : []),
      ...(memoryAllowed ? ['기억'] : []),
      ...(departmentsAllowed && proactive ? ['부서 넘기기'] : []),
      ...(organizeTools ? ['중요 표시', '맥락 제외', '진행 요약'] : []),
      ...(criteriaAllowed ? ['부서 기준'] : []),
    ]
    : undefined;
  const sourceId = conversation.context_from_conversation_id;
  let restoredNote: string | null = null;
  if (!isNew && sourceId && sourceId !== conversationId) {
    try {
      const source = await deps.store.getConversation(sourceId);
      if (!source) {
        restoredNote = restoredContextNote({ status: 'not_found' });
      } else {
        const view = normalizeProgressSummary(source.progress_summary);
        let foreignWork: WorkState | null = null;
        let workFailed = false;
        try {
          foreignWork = await deps.store.getWorkState(sourceId);
        } catch (e) {
          workFailed = true;
          console.error('[ai_think] restored work state failed:', e instanceof Error ? e.message : String(e));
        }
        const workText = foreignWork ? workStateNote(foreignWork) : null;
        if (workFailed && !view) restoredNote = restoredContextNote({ status: 'error', title: source.title });
        else if (!view && !workText && !workFailed) restoredNote = restoredContextNote({ status: 'empty', title: source.title });
        else {
          restoredNote = restoredContextNote({
            status: 'ok',
            title: source.title,
            purpose: view?.purpose,
            decided: view?.decided,
            workNote: workText,
            workFailed,
          });
        }
      }
    } catch (e) {
      console.error('[ai_think] restored context failed:', e instanceof Error ? e.message : String(e));
      restoredNote = restoredContextNote({ status: 'error' });
    }
  }
  const ctx = await buildThinkContext(deps.store, {
    conversationId: isNew ? null : conversationId,
    userMessage: input.message,
    attachments: input.attachments,
    scope: { type: conversation.scope_type, id: conversation.scope_id },
    workNote,
    restoredNote,
    featureNote: features && !relay
      ? featureStatusNote({
        splitState: features.conversation_split.state,
        rolesState: features.think_roles?.state,
        memoryState: features.memory_proposals?.state,
        departmentState: features.department_work?.state,
        organizeState: features.auto_organize?.state,
        courseMapState: features.course_map_actions?.state,
        conceptReviewState: features.concept_review?.state,
        conceptRelationState: features.concept_relation_change?.state,
        conceptSourceState: features.concept_source_pages?.state,
        conceptReviewJobState: features.concept_review_jobs?.state,
        conceptReviewBatchState: input.reviewJobRun ? undefined : features.concept_review_job_batch?.state,
        autoOrganize,
        organizeAsked: userAskedOrganize,
        organizeItems,
        pendingOrganize,
        isNew,
        suppressed: splitSuppressed,
        userAsked: userAskedSplit,
      })
      : null,
    splitSummary,
    progressSummary: progressView ? { view: progressView, excludedAfter } : null,
    access,
    thinkRole: currentRole,
    memoryProposalsReady: memoryAllowed,
    departmentWorkReady: departmentsAllowed,
    organizeReady: organizeTools,
    courseMapReady: courseMapAllowed,
    conceptReviewReady: conceptReviewAllowed,
    conceptRelationReady: conceptRelationAllowed,
    conceptSourceReady: conceptSourceAllowed,
    conceptReviewJobsReady: reviewJobsAllowed,
    conceptReviewBatchReady: reviewBatchAllowed,
    departmentCriteria: criteria,
    conceptReference: conceptRef?.note ?? null,
    criterionReference: criterionRef?.note ?? null,
    conceptDraftReference: draftRef?.note ?? null,
  });
  const instructions = relay ? `${ctx.instructions}\n\n${relayInstructions(relay.asker)}` : ctx.instructions;
  for (const m of ctx.deliveredMaterials) recordDelivered(m);
  const actionIds: string[] = [];

  const userMessageId = await deps.store.insertMessage({
    conversation_id: conversationId,
    role: 'user',
    content: input.message,
    status: 'complete',
    attachments: input.attachments,
    ...(relay ? { asked_by: relay.asker } : {}),
  });
  const softDeadline = input.startedAt + Math.floor(input.wallClockMs * 0.65);
  const toolCtx: ActionToolContext = {
    conversationId,
    memoryRefs: ctx.memoryRefs,
    split: splitAllowed ? { userMessageId, userRequested: userAskedSplit, proposed: false } : undefined,
    memory: memoryAllowed ? { proposed: false } : undefined,
    department: departmentsAllowed ? { currentRole, handoverProposed: false } : undefined,
    organize: organizeTools
      ? {
        userMessageId,
        criteriaDepartment: criteriaAllowed ? currentRole : null,
        userAskedExclusion: isExclusionRequest(input.message),
        userAskedImportance: isImportanceRequest(input.message),
        proposed: new Set<string>(),
      }
      : undefined,
    conceptDraft: draftTools
      ? { draftId: draftTools.meta.id, reviewSaved: draftTools.reviewSaved, criterionIds: draftTools.criterionIds, proposed: new Set<string>() }
      : undefined,
    courseMap: courseMapAllowed
      ? { proposed: new Map<string, number>(), review: conceptReviewAllowed, relations: conceptRelationAllowed }
      : undefined,
    conceptSources: conceptSourceAllowed
      ? { imagesLeft: SOURCE_IMAGE_LIMIT, adjacentLeft: SOURCE_ADJACENT_LIMIT, deadline: softDeadline }
      : undefined,
    reviewJobs: reviewJobsAllowed
      ? {
        holder: `think:${conversationId}:${crypto.randomUUID()}`,
        leases: new Map(input.reviewJobRun ? [[input.reviewJobRun.jobId, input.reviewJobRun.gen]] : []),
        cards: 0,
        itemsLeft: input.reviewJobRun ? input.reviewJobRun.maxItems : null,
        noTakeover: input.reviewJobRun != null,
      }
      : undefined,
    access: access ?? undefined,
    recordDelivered,
  };
  const consultState: ConsultState | undefined = departmentsAllowed ? { fromRole: currentRole, count: 0 } : undefined;
  const cacheKey = ctx.cacheKeySuffix ? `think:${conversationId}:${ctx.cacheKeySuffix}` : `think:${conversationId}`;
  const tools = thinkToolsFor({
    split: splitAllowed,
    memory: memoryAllowed,
    departments: departmentsAllowed,
    folder: proactive,
    handover: proactive,
    organize: organizeTools,
    criteria: criteriaAllowed,
    readOnly: relay !== null,
    conceptDraft: draftTools ? { change: draftTools.reviewSaved } : null,
    courseMap: courseMapAllowed,
    conceptReview: conceptReviewAllowed,
    conceptRelations: conceptRelationAllowed,
    conceptSources: conceptSourceAllowed,
    reviewJobs: reviewJobsAllowed,
    reviewBatch: reviewBatchAllowed,
  });
  const exposedTools = new Set(tools.map((t) => t.name));
  emit('conversation', {
    conversation_id: conversationId,
    user_message_id: userMessageId,
    title: conversation.title,
    created: isNew,
    model,
    features,
    relay: relay ? { asker: relay.asker } : null,
    think_role: access?.rolesFeatureReady
      ? {
        id: access.thinkRoleId,
        extra_ref_departments: access.extraRefDepartments,
        profile_version: ROLE_PROFILE_VERSION,
      }
      : null,
    split_suggestions: !splitSuppressed,
    auto_organize: organizeReady ? { enabled: autoOrganize === true, asked: userAskedOrganize, pending: pendingOrganize } : null,
    context: {
      identity: ctx.identityIds.length,
      principles: ctx.principleIds.length,
      decisions: ctx.decisionIds.length,
      relevant: ctx.relevantIds,
      history_used: ctx.historyUsed,
      history_dropped: ctx.historyDropped,
      split_summary: splitSummary !== null,
      progress_summary: ctx.progressSummaryUsed,
      criteria_version: ctx.criteriaVersion,
      // 키가 있으면 이 서버가 개념 참고를 안다. 본문·이름 없이 상태만.
      concept: conceptRef?.meta ?? null,
      criterion: criterionRef?.meta ?? null,
      draft: draftRef?.meta ?? null,
    },
  });

  const titleTask = isNew && !relayTitle && !draftId ? generateTitle(deps, input, conversationId) : Promise.resolve();

  // 3) 모델 호출과 도구 반복
  let usage: AiUsage = emptyUsage();
  let cost = 0;
  let costKnown = true;
  let webSearchCalls = 0;
  let toolCallCount = 0;
  let resolvedModel = model;
  const traces: ToolTrace[] = [];
  const finalParts: string[] = [];
  const commentary: string[] = [];
  const sources: AiSource[] = [];
  const streamed = new Map<string, { phase: string; text: string }>();
  let status: ChatOutcome['status'] = 'complete';
  let errorCode: string | undefined;
  let errorMessage: string | null = null;

  let turnInput: AiInputItem[] = ctx.input;

  // 엑셀이 붙은 요청에만 파이썬 실행 환경을 연다. 커서 질문에는 첨부가 없다.
  const sheets = relay ? [] : ctx.spreadsheets;
  let sandbox: AiSandboxSession | null = null;
  let sandboxOpenedAt = 0;
  let codeRuns = 0;
  const citedFiles: AiFileCitation[] = [];
  const answerFiles: AttachmentRef[] = [];
  if (sheets.length > 0) {
    const sandboxApi = deps.provider.sandbox;
    const readAttachment = deps.store.readAttachment?.bind(deps.store);
    emit('tool', { call_id: 'code_sandbox', name: 'code_sandbox', label: TOOL_LABELS.code_sandbox, status: 'running' });
    if (sandboxApi && readAttachment && deps.store.saveAnswerFile) {
      try {
        const files = [];
        for (const s of sheets) files.push({ name: s.name, mime: s.mime, bytes: await readAttachment(s.path) });
        sandboxOpenedAt = now();
        sandbox = await sandboxApi.open(files, input.signal);
      } catch (e) {
        console.error('[ai_think] sandbox open failed:', e instanceof Error ? e.message : String(e));
      }
    }
    const ready = sandbox !== null;
    emit('tool', {
      call_id: 'code_sandbox',
      name: 'code_sandbox',
      label: TOOL_LABELS.code_sandbox,
      status: 'done',
      ok: ready,
      detail: sheets.map((s) => s.name).join(', '),
    });
    traces.push({ name: 'code_sandbox', label: TOOL_LABELS.code_sandbox, detail: sheets.map((s) => s.name).join(', '), ok: ready });
    if (!ready) emit('notice', { code: 'spreadsheet_unavailable' });
    const note: AiInputItem = { kind: 'context', text: spreadsheetNote(sheets.map((s) => s.name), ready) };
    turnInput = [...turnInput.slice(0, -1), note, ...turnInput.slice(-1)];
  }

  try {
    for (let round = 0; round < MAX_TOOL_ROUNDS; round++) {
      const forceFinal = round === MAX_TOOL_ROUNDS - 1 || now() > softDeadline;
      let result: AiResult | null = null;
      streamed.clear();

      const stream = deps.provider.stream(
        {
          model,
          instructions,
          input: turnInput,
          tools,
          webSearch: input.webSearch ? { contextSize: 'medium' } : undefined,
          codeInterpreter: sandbox ? { containerId: sandbox.containerId } : undefined,
          toolChoice: forceFinal ? 'none' : 'auto',
          reasoningEffort: reasoningFor(tier, env),
          maxOutputTokens: maxOutputTokensFor(tier, env),
          cacheKey: rolesReady ? cacheKey : `think:${conversationId}`,
          safetyId: input.safetyId,
        },
        input.signal,
      );

      for await (const ev of stream) {
        switch (ev.type) {
          case 'message_start':
            streamed.set(ev.itemId, { phase: ev.phase, text: '' });
            emit('message_start', { item_id: ev.itemId, phase: ev.phase });
            break;
          case 'text_delta': {
            const s = streamed.get(ev.itemId) ?? { phase: 'final', text: '' };
            s.text += ev.delta;
            streamed.set(ev.itemId, s);
            emit('delta', { item_id: ev.itemId, text: ev.delta });
            break;
          }
          case 'message_done': {
            const s = streamed.get(ev.itemId);
            if (s) s.phase = ev.phase;
            emit('message_done', { item_id: ev.itemId, phase: ev.phase });
            break;
          }
          case 'function_call_start':
            emit('tool', { call_id: ev.callId, name: ev.name, label: TOOL_LABELS[ev.name] ?? ev.name, status: 'running' });
            break;
          case 'web_search':
            emit('tool', {
              call_id: ev.itemId,
              name: 'web_search',
              label: TOOL_LABELS.web_search,
              status: ev.status === 'searching' ? 'running' : 'done',
              ok: true,
              detail: ev.query ?? '',
            });
            break;
          case 'code_run':
            emit('tool', {
              call_id: ev.itemId,
              name: 'code_interpreter',
              label: TOOL_LABELS.code_interpreter,
              status: ev.status === 'running' ? 'running' : 'done',
              ok: ev.status !== 'failed',
            });
            break;
          case 'completed':
            result = ev.result;
            break;
        }
      }
      if (!result) throw new AiProviderError('no_result');

      streamed.clear();
      resolvedModel = result.model || model;
      usage = addUsage(usage, result.usage);
      const c = estimateCostUsd(resolvedModel, result.usage, result.webSearchCalls, env);
      if (c === null) costKnown = false;
      else cost += c;
      webSearchCalls += result.webSearchCalls;
      codeRuns += result.codeRuns ?? 0;
      for (const q of result.webSearchQueries) traces.push({ name: 'web_search', label: TOOL_LABELS.web_search, detail: q, ok: true });
      for (const m of result.messages) {
        citedFiles.push(...(m.files ?? []));
        if (m.phase === 'commentary') {
          if (m.text.trim()) commentary.push(m.text.trim());
        } else {
          if (m.text.trim()) finalParts.push(m.text.trim());
          sources.push(...m.sources);
        }
      }

      if (result.functionCalls.length === 0 || forceFinal) {
        if (result.status === 'incomplete' && finalParts.length === 0) {
          throw new AiProviderError(`incomplete: ${result.incompleteReason ?? 'unknown'}`, undefined, 'incomplete');
        }
        break;
      }

      turnInput = [...turnInput, result.replay];
      for (const fc of result.functionCalls) {
        toolCallCount += 1;
        const r = relay && ACTING_TOOL_NAMES.has(fc.name)
          ? { name: fc.name, ok: false, output: JSON.stringify({ error: 'not_available_for_cursor_questions' }), summary: '커서 질문에서는 쓸 수 없음' }
          : !exposedTools.has(fc.name)
          ? {
            name: fc.name,
            ok: false,
            output: JSON.stringify({ error: 'tool_not_available', next: '이번 요청에 주지 않은 도구다. 실행 환경 기능 상태 메모를 따른다.' }),
            summary: '이번 요청에서 쓸 수 없음',
          }
          : fc.name === BATCH_TOOL_NAME
          ? await runReviewBatch(
            {
              callId: fc.callId,
              rawArguments: fc.arguments,
              conversationId,
              userId: input.userId,
              safetyId: input.safetyId,
              signal: input.signal,
              deadline: input.startedAt + input.wallClockMs - REVIEW_BATCH_FINAL_RESERVE_MS,
              round: round + 1,
              startedAt: input.startedAt,
            },
            toolCtx.reviewJobs,
            { provider: deps.provider, store: deps.store, recordRun: deps.recordRun, env, now },
          )
          : fc.name === CONSULT_TOOL_NAME
          ? await runConsult(
            {
              callId: fc.callId,
              rawArguments: fc.arguments,
              conversationId,
              userId: input.userId,
              safetyId: input.safetyId,
              signal: input.signal,
              deadline: softDeadline,
            },
            consultState,
            { provider: deps.provider, store: deps.store, recordRun: deps.recordRun, emit, env, now },
          )
          : await runThinkTool(
            fc.name,
            fc.arguments,
            deps.store,
            fc.name === SOURCE_PAGE_TOOL_NAME
              ? SOURCE_PAGE_TOOL_TIMEOUT_MS
              : COURSE_MAP_TOOL_NAMES.has(fc.name) || CONCEPT_SOURCE_TOOL_NAMES.has(fc.name)
              ? 20000
              : 8000,
            toolCtx,
          );
        const label = TOOL_LABELS[fc.name] ?? fc.name;
        traces.push({ name: fc.name, label, detail: r.summary, ok: r.ok });
        emit('tool', { call_id: fc.callId, name: fc.name, label, status: 'done', ok: r.ok, detail: r.summary });
        for (const a of [...(r.action ? [r.action] : []), ...(r.actions ?? [])]) {
          actionIds.push(a.id);
          emit('action', { action: a });
        }
        const images = 'images' in r ? r.images : undefined;
        turnInput.push({ kind: 'tool_result', callId: fc.callId, output: r.output, ...(images?.length ? { images } : {}) });
      }
    }
  } catch (e) {
    if (input.signal.aborted) {
      const reason = abortReason(input.signal);
      status = reason === 'stopped' ? 'stopped' : 'error';
      errorCode = reason;
      errorMessage = reason === 'timeout' ? '응답 시간이 너무 길어 중단했습니다.' : null;
    } else {
      status = 'error';
      errorCode = e instanceof AiProviderError ? (e.code ?? 'provider_error') : 'internal_error';
      errorMessage = e instanceof Error ? e.message : String(e);
      console.error('[ai_think] chat failed:', errorMessage);
    }
    for (const s of streamed.values()) {
      if (s.phase !== 'commentary' && s.text.trim()) finalParts.push(s.text.trim());
    }
  }

  // 실행 환경은 20분 뒤 사라지므로 만든 파일을 답변 저장 전에 옮기고 바로 지운다. 사용자가 멈췄으면 옮기지 않는다.
  if (sandbox) {
    try {
      if (status !== 'stopped' && codeRuns > 0) {
        // 함수 강제 종료(한도는 AI_THINK_WALL_MS보다 길다) 전에 답변을 저장할 시간을 남긴다.
        const budget = Math.min(ANSWER_FILE_COLLECT_MS, input.startedAt + input.wallClockMs + 10000 - now());
        const outputs = await sandbox.collectOutputs(
          { exts: Object.keys(ANSWER_FILE_MIME), limit: MAX_ANSWER_FILES, maxBytes: MAX_ANSWER_FILE_BYTES, preferred: citedFiles },
          AbortSignal.timeout(Math.max(3000, budget)),
        );
        for (const f of outputs) {
          const mime = answerFileMime(f.name);
          if (!mime) continue;
          answerFiles.push(await deps.store.saveAnswerFile!(input.userId, f.name, mime, f.bytes));
        }
      }
    } catch (e) {
      console.error('[ai_think] answer files failed:', e instanceof Error ? e.message : String(e));
      emit('notice', { code: 'answer_files_failed' });
    }
    cost += codeSessionCostUsd(now() - sandboxOpenedAt);
    if (codeRuns > 0) {
      traces.push({ name: 'code_interpreter', label: TOOL_LABELS.code_interpreter, detail: `${codeRuns}회`, ok: true });
    }
  }

  // 4) 저장·기록
  let content = finalParts.join('\n\n').trim();
  let relayVerdict: RelayVerdict | null = null;
  if (relay) {
    const split = splitRelayBlock(content);
    content = split.text;
    if (status === 'complete') relayVerdict = await resolveRelayVerdict(split, relay.asker, (id) => deps.store.getMemory(id));
  }
  if (status === 'complete' && !content) {
    status = 'error';
    errorCode = 'empty_answer';
    errorMessage = '모델이 빈 답변을 돌려주었습니다.';
    relayVerdict = null;
  }

  const runId = await deps.recordRun({
    feature: relay ? 'think_relay' : 'think_chat',
    provider: deps.provider.name,
    model: resolvedModel,
    promptVersion: THINK_PROMPT_VERSION,
    roleProfileVersion: rolesReady ? ROLE_PROFILE_VERSION : null,
    status: status === 'complete' ? 'ok' : status === 'stopped' ? 'stopped' : 'error',
    error: errorMessage,
    usage,
    webSearchCalls,
    toolCalls: toolCallCount,
    costUsd: costKnown ? cost : null,
    latencyMs: now() - input.startedAt,
    conversationId,
    createdBy: input.userId || null,
    features: features
      ? {
        ...features,
        split_tool: splitAllowed,
        department_tools: departmentsAllowed,
        consults: consultState?.count ?? 0,
        organize_tools: organizeTools,
        course_map_tools: courseMapAllowed,
        concept_review_tools: conceptReviewAllowed,
        concept_relation_tools: conceptRelationAllowed,
        concept_source_tools: conceptSourceAllowed,
        concept_review_job_tools: reviewJobsAllowed,
        concept_review_batch_tool: reviewBatchAllowed,
        ...(input.reviewJobRun ? { review_job_run: input.reviewJobRun.jobId } : {}),
        auto_organize_enabled: autoOrganize,
        ...(conceptRef ? { concept_ref: conceptRef.meta } : {}),
        ...(criterionRef ? { criterion_ref: criterionRef.meta } : {}),
        ...(draftRef ? { concept_draft_ref: draftRef.meta } : {}),
        ...(sheets.length > 0
          ? { spreadsheets: { files: sheets.length, sandbox: sandbox !== null, code_runs: codeRuns, answer_files: answerFiles.length } }
          : {}),
      }
      : null,
  });

  let assistantMessageId: string | null = null;
  if (content || status !== 'stopped') {
    try {
      assistantMessageId = await deps.store.insertMessage({
        conversation_id: conversationId,
        role: 'assistant',
        content: content || (errorMessage ? `⚠️ ${clip(errorMessage, 300)}` : ''),
        status,
        ...(answerFiles.length > 0 ? { attachments: answerFiles } : {}),
        sources: dedupeSources(sources),
        tool_calls: traces,
        commentary: commentary.length > 0 ? commentary.join('\n\n') : null,
        model: resolvedModel,
        run_id: runId,
        ...(relayVerdict ? { relay: relayVerdict } : {}),
      });
    } catch (e) {
      console.error('[ai_think] assistant message insert failed:', e instanceof Error ? e.message : String(e));
    }
  }
  // 답변별 스냅샷은 역할 기능이 준비된 DB에만 남긴다. 없으면 앱은 '기록 없음'으로 표시한다.
  if (assistantMessageId && access?.rolesFeatureReady && deps.store.saveMessageContextSnapshot) {
    try {
      await deps.store.saveMessageContextSnapshot({
        messageId: assistantMessageId,
        runId,
        thinkRoleId: access.thinkRoleId,
        roleProfileVersion: ROLE_PROFILE_VERSION,
        access,
        materials: [...deliveredMap.values()].filter((m) => m.delivered),
      });
    } catch (e) {
      console.error('[ai_think] context snapshot failed:', e instanceof Error ? e.message : String(e));
    }
  }
  // 붙이지 못한 제안도 대화에는 남아 화면 끝에 카드로 보인다.
  if (assistantMessageId && actionIds.length > 0) {
    await deps.store.attachActions(actionIds, assistantMessageId).catch((e) => {
      console.error('[ai_think] attach actions failed:', e instanceof Error ? e.message : String(e));
    });
  }

  await titleTask.catch(() => {});

  if (status === 'complete' || status === 'stopped') {
    emit('done', {
      conversation_id: conversationId,
      assistant_message_id: assistantMessageId,
      run_id: runId,
      status,
      model: resolvedModel,
      usage: {
        input_tokens: usage.inputTokens,
        cached_input_tokens: usage.cachedInputTokens,
        output_tokens: usage.outputTokens,
        reasoning_tokens: usage.reasoningTokens,
      },
      web_search_calls: webSearchCalls,
      cost_usd: costKnown ? cost : null,
      sources: dedupeSources(sources),
      attachments: answerFiles,
      action_ids: actionIds,
      relay: relayVerdict,
    });
  } else {
    emit('error', {
      conversation_id: conversationId,
      assistant_message_id: assistantMessageId,
      code: errorCode ?? 'error',
      message: errorMessage ?? '답변을 만들지 못했습니다.',
      attachments: answerFiles,
      action_ids: actionIds,
    });
  }
  // 답변을 저장·알린 뒤에 지운다. 지우기가 늦어도 답변은 이미 남아 있다.
  await sandbox?.close();

  return {
    conversationId,
    userMessageId,
    assistantMessageId,
    runId,
    status,
    errorCode,
    errorMessage,
    content,
    relay: relayVerdict,
    costUsd: costKnown ? cost : null,
  };
}
