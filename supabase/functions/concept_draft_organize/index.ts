// concept_draft_organize: 개념책 소단원 전사(두 번 읽음) → 개념 초안·결과 요약(슈퍼관리자 전용).
//   POST { book_name, grade_label, unit_path[], pages: [{ raw_page, display_page?, a: blocks[], b?: blocks[] }],
//          criterion_ids?: uuid[], tier?, effort? }
//     → { ok, draft, checks, prepared, criteria, ... }   (시범 실행기: 블록을 보내고 저장하지 않음)
//   POST { task: 'create', academy_id, book_id, grade_label, unit_path[], pages: int[], criterion_ids?, effort? }
//     → { ok, draft_id, checks, ... }   (매니저앱: 저장된 전사를 서버가 읽고 concept_drafts 에 저장)
//   POST { task: 'folders', draft_id, effort? }
//     → { ok, folder_plan }   (초안 개념을 넣을 라이브러리 폴더 제안을 concept_drafts.folder_plan 에 저장.
//        같은 학원의 다른 열린 초안이 쓰기로 한 폴더·개념 이름도 서버가 읽어 함께 보여 준다. 겹침은 overlaps 로 알리기만 한다)
//   POST { task: 'rerun', action_id, effort? }
//     → { ok, draft_id, ... }   (승인한 다시 정리 카드: 같은 쪽으로 새 초안을 만들고 지금 초안을 'replaced'로 닫는다)
//   POST { task: 'anchors', folder_id, effort? }
//     → { ok, proposal: { summary, items[{concept_id, anchor_id, current_anchor_id, reason}], checks } }
//        (라이브러리 폴더 하나의 주제 묶음 제안. 개념은 서버가 읽고 저장하지 않는다. 운영자가 고른 줄만 concept_anchor_set)
//   POST { task: 'evidence_scope', concept_id, statement_id?(없으면 기본 서술), effort? }
//     → { ok, proposal: { summary, basis_md5, items[{source_id, scope, current_scope, reason, covered, missing}], checks } }
//        (서술 하나의 출처마다 근거 범위 제안. 서술 글·근거 블록은 concept_source_evidence 로 서버가 읽고 저장하지 않는다.
//         운영자가 받아들인 줄만 concept_source_set_evidence(origin 'ai', basis_md5))
//   POST { task: 'compare', draft_id, keys?: string[], effort? }
//     → { ok, proposal: { summary, items[{key, choice, concept_id, concept_name, statement_id, reason, differences, draft_exists}],
//          candidates, checks } }
//        (저장된 검토 항목마다 기존 후보 개념과 비교해 new·statement·source·revise·hold 를 제안. 항목·후보 글은 서버가 읽고
//         저장하지 않는다. 운영자가 고른 줄만 앱의 검토에 관계로 들어가고, 확정은 운영자가 한다)
//   create·rerun 에 background: true 를 붙이면 공급자 백그라운드 호출로 정리를 시작하고 바로 답한다.
//     → { ok, job_id, status: 'running', poll_after_ms }   (작업은 concept_draft_jobs 에 적는다)
//   POST { task: 'collect', job_id }
//     → 끝나기 전 { ok, status: 'running', elapsed_ms }. 끝나면 서버가 초안을 저장하고 create·rerun 과 같은 결과 + status: 'done'.
//        여러 번 물어도 초안은 한 번만 만든다. 결과를 받으면 공급자 쪽 응답은 지운다.
//   background 없는 create·rerun(옛 앱)은 200을 먼저 보내고 공백을 흘린 뒤 결과 JSON을 붙인다
//   (keepalive.ts, 원래 상태 코드는 http_status). 이 길은 함수 실행 한도(400초) 안에 끝나야 한다.
// 정리 기준은 id로 서버가 다시 읽는다(확정본·초안 구분). 개념 유형은 concept_types 에서 읽어 주고, AI는 맞는 유형이
// 없을 때만 새 유형을 제안한다(운영자가 확정 때 받아들일 때만 더해짐). 라이브러리에는 쓰지 않는다. 사용량은 ai_runs에 남는다.

import { corsHeaders } from '../_shared/cors.ts';
import {
  authenticate,
  type AuthContext,
  errorResponse,
  isSuperadmin,
  jsonResponse,
  safetyIdentifier,
} from '../_shared/ai/auth.ts';
import { getBudgetStatus } from '../_shared/ai/budget.ts';
import { estimateCostUsd, modelFor } from '../_shared/ai/config.ts';
import { createAiProvider } from '../_shared/ai/provider.ts';
import { type AiBackgroundPoll, type AiProvider, AiProviderError, type AiResult, emptyUsage } from '../_shared/ai/types.ts';
import { recordAiRun } from '../_shared/ai/usage.ts';
import { isUuid, operatorBook } from '../_shared/concept_book.ts';
import { CONCEPT_PAGE_PROMPT_VERSION } from '../concept_page_read/prompt.ts';
import {
  CONCEPT_FOLDER_PROMPT_VERSION,
  type LibraryCategory,
  libraryOutline,
  MAX_PENDING_DRAFTS,
  type PendingDraft,
  pendingDraftOf,
} from './folders.ts';
import {
  CONCEPT_DRAFT_PROMPT_VERSION,
  type ConceptTypeRef,
  conceptTypeRefs,
  criterionRefs,
  MAX_PAGES,
  type PreparedUnit,
  prepareUnit,
  readConceptDraftBody,
} from './organize.ts';
import { collectStep, jobAgeMs, jobOutcome, JOB_MAX_MS, type JobRow, MAX_ACTIVE_JOBS, POLL_AFTER_MS, pollStep } from './jobs.ts';
import { keepAliveJson } from './keepalive.ts';
import { rerunDraftId, rerunFinishCode, rerunPlan } from './rerun.ts';
import {
  type ConceptDraftOpts,
  type ConceptDraftOutcome,
  conceptDraftRequest,
  organizeConceptDraft,
  proposeConceptAnchors,
  proposeConceptFolders,
  proposeCompare,
  proposeEvidenceScopes,
} from './run.ts';
import { type AnchorConcept, CONCEPT_ANCHOR_PROMPT_VERSION, MAX_ANCHOR_CONCEPTS } from './anchors.ts';
import { CONCEPT_EVIDENCE_PROMPT_VERSION, evidenceInput, MAX_EVIDENCE_SOURCES } from './evidence.ts';
import {
  type CompareItem,
  type CompareTarget,
  compareTargetOf,
  CONCEPT_COMPARE_PROMPT_VERSION,
  evidenceText,
  MAX_COMPARE_CANDIDATES,
  MAX_COMPARE_ITEMS,
  overlapNames,
  reviewEntries,
} from './compare.ts';

const FEATURE = 'concept_draft_organize';
const RATE_LIMIT_PER_MINUTE = 6;
/** 유료 요금제 함수 실행 한도(400초) 안에서 앞뒤 DB 작업 몫을 남긴다. */
const LONG_AI_TIMEOUT_MS = 330_000;
const EFFORTS = new Set(['low', 'medium', 'high']);

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return errorResponse(405, 'method_not_allowed');

  const auth = await authenticate(req);
  if (!auth) return errorResponse(401, 'unauthorized');
  if (!(await isSuperadmin(auth))) return errorResponse(403, 'forbidden');

  let body: Record<string, unknown>;
  try {
    const parsed = await req.json();
    body = parsed && typeof parsed === 'object' ? parsed : {};
  } catch {
    return errorResponse(400, 'invalid_json');
  }
  const effortRaw = typeof body.effort === 'string' ? body.effort.trim() : '';
  const effort = EFFORTS.has(effortRaw) ? effortRaw : 'medium';
  const task = ['create', 'folders', 'rerun', 'anchors', 'evidence_scope', 'compare', 'collect'].includes(String(body.task))
    ? String(body.task)
    : 'blocks';

  const long = task === 'create' || task === 'rerun';
  const provider = createAiProvider({ timeoutMs: long ? LONG_AI_TIMEOUT_MS : 140000 });
  if (!provider) return errorResponse(503, 'ai_not_configured');
  if (task === 'collect') return await collect(auth, provider, body);
  const since = new Date(Date.now() - 60_000).toISOString();
  const { count } = await auth.admin
    .from('ai_runs')
    .select('id', { count: 'exact', head: true })
    .eq('created_by', auth.userId)
    .eq('feature', FEATURE)
    .gte('created_at', since);
  if ((count ?? 0) >= RATE_LIMIT_PER_MINUTE) return errorResponse(429, 'rate_limited');
  const budget = await getBudgetStatus(auth.admin).catch(() => null);
  if (budget?.exceeded && budget.mode === 'block') return errorResponse(429, 'budget_exceeded');

  if (task === 'folders') return await folders(auth, provider, body, effort);
  if (task === 'anchors') return await anchors(auth, provider, body, effort);
  if (task === 'evidence_scope') return await evidenceScope(auth, provider, body, effort);
  if (task === 'compare') return await compare(auth, provider, body, effort);
  const background = body.background === true && provider.background != null;
  if (task === 'rerun') {
    return background
      ? await rerun(auth, provider, body, effort, true)
      : keepAliveJson(() => rerun(auth, provider, body, effort, false), corsHeaders);
  }
  if (task === 'create') {
    return background
      ? await startOrganize(auth, provider, body, effort, null)
      : keepAliveJson(() => organize(auth, provider, body, effort, true), corsHeaders);
  }
  return await organize(auth, provider, body, effort, false);
});

/**
 * 승인한 "다시 정리" 카드: 지금 초안과 같은 책·학년·단원·쪽을 카드의 기준으로 다시 정리해 새 초안을 만들고,
 * 사용자 권한의 마무리 RPC로 지금 초안을 'replaced'로 닫으며 카드를 실행됨으로 바꾼다. 전사는 다시 읽지 않는다.
 */
async function rerun(
  auth: AuthContext,
  provider: AiProvider,
  body: Record<string, unknown>,
  effort: string,
  background: boolean,
): Promise<Response> {
  const actionId = body.action_id;
  if (!isUuid(actionId)) return errorResponse(400, 'invalid_action');
  const { data: act, error: actError } = await auth.admin
    .from('ai_actions')
    .select('id,kind,status,payload')
    .eq('id', actionId)
    .maybeSingle();
  if (actError) return errorResponse(502, 'action_read_failed');
  const action = (act ?? null) as Record<string, unknown> | null;
  const head = rerunDraftId(action);
  if (!head.ok) return errorResponse(head.status, head.error);
  const { data: row, error } = await auth.admin
    .from('concept_drafts')
    .select('id,academy_id,book_id,grade_label,unit_path,pages,status')
    .eq('id', head.draftId)
    .maybeSingle();
  if (error) return errorResponse(502, 'draft_read_failed');
  const plan = rerunPlan(action!, (row ?? null) as Record<string, unknown> | null);
  if (!plan.ok) return errorResponse(plan.status, plan.error);
  const rerunOf = { actionId: String(actionId), draftId: plan.draftId };
  if (background) return await startOrganize(auth, provider, plan.body, effort, rerunOf);
  return await organize(auth, provider, plan.body, effort, true, rerunOf);
}

async function record(
  auth: AuthContext,
  provider: AiProvider,
  opts: { model: string; promptVersion: string; result: AiResult | null; error: string | null; latencyMs: number; academyId: string | null },
) {
  const usage = opts.result?.usage ?? emptyUsage();
  const model = opts.result?.model || opts.model;
  const costUsd = opts.result ? estimateCostUsd(model, usage) : null;
  await recordAiRun(auth.admin, {
    feature: FEATURE,
    provider: provider.name,
    model,
    promptVersion: opts.promptVersion,
    status: opts.error ? 'error' : 'ok',
    error: opts.error,
    usage,
    costUsd,
    latencyMs: opts.latencyMs,
    academyId: opts.academyId,
    createdBy: auth.userId,
  });
  return { usage, model, costUsd };
}

/** 저장된 전사(같은 판 지시문)를 쪽마다 첫 번째·두 번째 읽기로 묶는다. 첫 번째 읽기가 없는 쪽은 missing. */
async function loadTranscripts(
  auth: AuthContext,
  academyId: string,
  bookId: string,
  gradeLabel: string,
  pages: number[],
): Promise<{ pages: Record<string, unknown>[]; meta: { raw_page: number; display_page: number | null }[]; missing: number[] } | null> {
  const { data, error } = await auth.admin
    .from('concept_page_transcripts')
    .select('raw_page,display_page,read_index,page')
    .eq('academy_id', academyId)
    .eq('book_id', bookId)
    .eq('grade_label', gradeLabel)
    .eq('prompt_version', CONCEPT_PAGE_PROMPT_VERSION)
    .in('raw_page', pages);
  if (error) return null;
  const rows = (data ?? []) as Record<string, unknown>[];
  const out: Record<string, unknown>[] = [];
  const meta: { raw_page: number; display_page: number | null }[] = [];
  const missing: number[] = [];
  for (const raw of pages) {
    const of = (i: number) => rows.find((r) => Number(r.raw_page) === raw && Number(r.read_index) === i);
    const a = of(1);
    if (!a) {
      missing.push(raw);
      continue;
    }
    const b = of(2);
    const blocks = (r: Record<string, unknown> | undefined) => {
      const page = r?.page as Record<string, unknown> | undefined;
      return Array.isArray(page?.blocks) ? page.blocks : [];
    };
    const display = Number(a.display_page);
    const displayPage = Number.isInteger(display) && display > 0 ? display : null;
    out.push({ raw_page: raw, display_page: displayPage, a: blocks(a), b: blocks(b) });
    meta.push({ raw_page: raw, display_page: displayPage });
  }
  return { pages: out, meta, missing };
}

type RerunOf = { actionId: string; draftId: string };

/** 정리 한 번의 입력. 백그라운드 작업은 이 값을 concept_draft_jobs 에 두고 결과를 받을 때 그대로 쓴다. */
interface OrganizeContext {
  store: boolean;
  academyId: string;
  bookId: string;
  gradeLabel: string;
  bookName: string;
  unitPath: string[];
  pageMeta: { raw_page: number; display_page: number | null }[];
  prepared: PreparedUnit;
  /** 정리에 쓴 기준(id·제목·판·확정/초안). 본문은 넣지 않는다. */
  criteriaShown: Record<string, unknown>[];
  types: ConceptTypeRef[];
  model: string;
  tier: string;
  effort: string;
}

async function organize(
  auth: AuthContext,
  provider: AiProvider,
  body: Record<string, unknown>,
  effort: string,
  store: boolean,
  rerunOf: RerunOf | null = null,
): Promise<Response> {
  const prep = await prepareOrganize(auth, body, effort, store);
  if (prep instanceof Response) return prep;
  const started = Date.now();
  const outcome = await organizeConceptDraft(provider, prep.opts);
  const done = await finishOrganize(auth, provider, prep.ctx, outcome, Date.now() - started, rerunOf);
  return jsonResponse(done.body, done.status);
}

/** 백그라운드로 정리를 시작한다. 결과는 collect 가 받아 초안으로 저장한다. */
async function startOrganize(
  auth: AuthContext,
  provider: AiProvider,
  body: Record<string, unknown>,
  effort: string,
  rerunOf: RerunOf | null,
): Promise<Response> {
  const bg = provider.background;
  if (!bg) return errorResponse(503, 'ai_not_configured');
  const prep = await prepareOrganize(auth, body, effort, true);
  if (prep instanceof Response) return prep;
  const { ctx, opts } = prep;

  const { count, error: countError } = await auth.admin
    .from('concept_draft_jobs')
    .select('id', { count: 'exact', head: true })
    .eq('created_by', auth.userId)
    .in('status', ['running', 'saving'])
    .gte('created_at', new Date(Date.now() - JOB_MAX_MS).toISOString());
  if (countError) return errorResponse(502, 'job_read_failed');
  if ((count ?? 0) >= MAX_ACTIVE_JOBS) return errorResponse(429, 'rate_limited');

  const started = Date.now();
  let responseId: string;
  try {
    responseId = (await bg.start(conceptDraftRequest(opts), {
      metadata: { feature: FEATURE, academy_id: ctx.academyId, book_id: ctx.bookId, grade_label: ctx.gradeLabel },
    })).id;
  } catch (e) {
    const error = e instanceof Error ? e.message : String(e);
    const done = await finishOrganize(auth, provider, ctx, { result: null, draft: null, checks: null, error }, Date.now() - started, rerunOf);
    return jsonResponse(done.body, done.status);
  }

  const { data, error } = await auth.admin
    .from('concept_draft_jobs')
    .insert({
      academy_id: ctx.academyId,
      book_id: ctx.bookId,
      grade_label: ctx.gradeLabel,
      book_name: ctx.bookName,
      unit_path: ctx.unitPath,
      pages: ctx.pageMeta.map((p) => p.raw_page),
      page_meta: ctx.pageMeta,
      criteria: ctx.criteriaShown,
      concept_types: ctx.types,
      prepared: ctx.prepared,
      model: ctx.model,
      prompt_version: CONCEPT_DRAFT_PROMPT_VERSION,
      effort: ctx.effort,
      provider: provider.name,
      response_id: responseId,
      rerun_action_id: rerunOf?.actionId ?? null,
      rerun_of: rerunOf?.draftId ?? null,
      created_by: auth.userId,
    })
    .select('id')
    .single();
  if (error || !data) {
    console.error(`[${FEATURE}] job save failed:`, error?.message);
    await bg.cancel(responseId).catch(() => {});
    await bg.remove(responseId).catch(() => {});
    return errorResponse(502, 'save_failed');
  }
  return jsonResponse({ ok: true, job_id: String((data as Record<string, unknown>).id), status: 'running', poll_after_ms: POLL_AFTER_MS });
}

function stillRunning(elapsedMs: number): Response {
  return jsonResponse({ ok: true, status: 'running', elapsed_ms: elapsedMs, poll_after_ms: POLL_AFTER_MS });
}

/** 백그라운드 정리 결과를 받는다. 끝났으면 한 요청만 초안을 저장하고, 공급자 쪽 응답을 지운다. */
async function collect(auth: AuthContext, provider: AiProvider, body: Record<string, unknown>): Promise<Response> {
  const jobId = body.job_id;
  if (!isUuid(jobId)) return errorResponse(400, 'invalid_job');
  const bg = provider.background;
  if (!bg) return errorResponse(503, 'ai_not_configured');
  const { data, error } = await auth.admin.from('concept_draft_jobs').select('*').eq('id', jobId).maybeSingle();
  if (error) return errorResponse(502, 'job_read_failed');
  if (!data) return errorResponse(404, 'job_not_found');
  const job = data as JobRow;
  if (job.created_by !== auth.userId) return errorResponse(403, 'job_forbidden');

  const now = Date.now();
  const step = collectStep(job, now);
  if (step === 'done') return jsonResponse({ ok: true, status: 'done', draft_id: job.draft_id });
  if (step === 'failed') {
    const code = job.error ?? 'ai_failed';
    return jsonResponse({ ok: false, status: 'failed', error: code, message: code }, 502);
  }
  const ageMs = jobAgeMs(job, now);
  if (step === 'wait') return stillRunning(ageMs);

  let poll: AiBackgroundPoll;
  try {
    poll = await bg.poll(job.response_id);
  } catch (e) {
    if (!(e instanceof AiProviderError && e.status === 404)) {
      const message = e instanceof Error ? e.message : String(e);
      console.error(`[${FEATURE}] poll failed:`, message);
      return jsonResponse({ ok: false, error: 'ai_poll_failed', message, retryable: true }, 502);
    }
    poll = { state: 'failed', error: 'response_missing' };
  }
  const next = pollStep(poll, ageMs);
  if (next === 'running') return stillRunning(ageMs);
  if (next === 'timeout' || next === 'stalled') {
    const last = poll.state === 'running' ? poll.status : '';
    console.error(`[${FEATURE}] job ${job.id} ${next} after ${Math.round(ageMs / 1000)}s (provider status: ${last})`);
    await bg.cancel(job.response_id).catch((e) => console.error(`[${FEATURE}] cancel failed:`, String(e)));
    poll = { state: 'failed', error: next === 'stalled' ? 'ai_stalled' : 'ai_timeout' };
  }
  const finished = poll as Exclude<AiBackgroundPoll, { state: 'running' }>;

  const { data: claimed, error: claimError } = await auth.admin
    .from('concept_draft_jobs')
    .update({ status: 'saving' })
    .eq('id', job.id)
    .eq('status', job.status)
    .eq('updated_at', job.updated_at)
    .select('id');
  if (claimError) return errorResponse(502, 'job_save_failed');
  if (!claimed || claimed.length === 0) return stillRunning(ageMs);

  const ctx: OrganizeContext = {
    store: true,
    academyId: job.academy_id,
    bookId: job.book_id,
    gradeLabel: job.grade_label,
    bookName: job.book_name,
    unitPath: job.unit_path,
    pageMeta: job.page_meta,
    prepared: job.prepared,
    criteriaShown: job.criteria,
    types: job.concept_types,
    model: job.model,
    tier: 'primary',
    effort: job.effort,
  };
  const rerunOf = job.rerun_action_id && job.rerun_of ? { actionId: job.rerun_action_id, draftId: job.rerun_of } : null;
  const done = await finishOrganize(auth, provider, ctx, jobOutcome(finished, job), ageMs, rerunOf);
  const ok = done.body.ok === true;
  const close = {
    status: ok ? 'done' : 'failed',
    draft_id: ok ? String(done.body.draft_id) : null,
    error: ok ? null : String(done.body.error ?? 'ai_failed'),
    finished_at: new Date().toISOString(),
  };
  for (let i = 0; i < 2; i += 1) {
    const { error: closeError } = await auth.admin.from('concept_draft_jobs').update(close).eq('id', job.id);
    if (!closeError) break;
    console.error(`[${FEATURE}] job close failed:`, closeError.message);
  }
  await bg.remove(job.response_id).catch((e) => console.error(`[${FEATURE}] remove failed:`, String(e)));
  return jsonResponse({ ...done.body, status: close.status }, done.status);
}

/** 정리 입력을 읽고 맞춘다. 막히면 그대로 돌려줄 응답. */
async function prepareOrganize(
  auth: AuthContext,
  body: Record<string, unknown>,
  effort: string,
  store: boolean,
): Promise<{ ctx: OrganizeContext; opts: ConceptDraftOpts } | Response> {
  const academyId = String(body.academy_id ?? '');
  const bookId = String(body.book_id ?? '');
  let source = body;
  let pageMeta: { raw_page: number; display_page: number | null }[] = [];
  let bookName = '';
  if (store) {
    const book = await operatorBook(auth, academyId, bookId);
    if (!book) return errorResponse(403, 'book_forbidden');
    bookName = book.name;
    const gradeLabel = String(body.grade_label ?? '').trim();
    const raws = Array.isArray(body.pages) ? body.pages.map(Number) : [];
    if (!gradeLabel) return errorResponse(400, 'grade_required');
    if (raws.length === 0) return errorResponse(400, 'pages_required');
    if (raws.length > MAX_PAGES) return errorResponse(400, 'too_many_pages');
    if (raws.some((n) => !Number.isInteger(n) || n < 1) || new Set(raws).size !== raws.length) {
      return errorResponse(400, 'invalid_page');
    }
    const loaded = await loadTranscripts(auth, academyId, bookId, gradeLabel, [...raws].sort((x, y) => x - y));
    if (!loaded) return errorResponse(502, 'transcripts_read_failed');
    if (loaded.missing.length > 0) {
      return jsonResponse({ ok: false, error: 'transcripts_missing', message: 'transcripts_missing', pages: loaded.missing }, 409);
    }
    pageMeta = loaded.meta;
    source = { ...body, book_name: bookName, pages: loaded.pages };
  }
  const read = readConceptDraftBody(source);
  if (!read.ok) return errorResponse(400, read.error);
  const unitPath = store ? read.unitPath.slice(0, 3) : read.unitPath;
  const tier = !store && body.tier === 'deep' ? 'deep' : 'primary';

  let criteria: ReturnType<typeof criterionRefs> = [];
  if (read.criterionIds.length > 0) {
    const { data, error } = await auth.admin
      .from('concept_criteria')
      .select('id,title,body,version,draft_title,draft_body,draft_saved_at')
      .in('id', read.criterionIds);
    if (error) return errorResponse(502, 'criteria_read_failed');
    const rows = (data ?? []) as Record<string, unknown>[];
    if (rows.length !== read.criterionIds.length) return errorResponse(404, 'criterion_not_found');
    criteria = criterionRefs(rows);
  }
  const { data: typeRows, error: typeError } = await auth.admin
    .from('concept_types')
    .select('name,description,legacy_sub_type')
    .order('sort_order')
    .order('created_at')
    .limit(200);
  if (typeError) return errorResponse(502, 'types_read_failed');
  const types = conceptTypeRefs((typeRows ?? []) as Record<string, unknown>[]);

  const prepared = prepareUnit(read.pages);
  const model = modelFor(tier);
  return {
    ctx: {
      store,
      academyId,
      bookId,
      gradeLabel: read.gradeLabel,
      bookName,
      unitPath,
      pageMeta,
      prepared,
      criteriaShown: criteria.map((c) => ({ id: c.id, title: c.title, version: c.version, state: c.state })),
      types,
      model,
      tier,
      effort,
    },
    opts: {
      model,
      reasoningEffort: effort,
      bookName: read.bookName,
      gradeLabel: read.gradeLabel,
      unitPath,
      prepared,
      criteria,
      types,
      safetyId: await safetyIdentifier(auth.userId),
    },
  };
}

/** 정리 결과를 기록하고, 저장하는 길이면 초안을 만든다(다시 정리면 지금 초안을 닫는다). */
async function finishOrganize(
  auth: AuthContext,
  provider: AiProvider,
  ctx: OrganizeContext,
  outcome: ConceptDraftOutcome,
  latencyMs: number,
  rerunOf: RerunOf | null,
): Promise<{ status: number; body: Record<string, unknown> }> {
  if (outcome.error) console.error(`[${FEATURE}] failed:`, outcome.error);
  const { usage, model: usedModel, costUsd } = await record(auth, provider, {
    model: ctx.model,
    promptVersion: CONCEPT_DRAFT_PROMPT_VERSION,
    result: outcome.result,
    error: outcome.error,
    latencyMs,
    academyId: ctx.store ? ctx.academyId : null,
  });
  if (!outcome.draft) {
    return {
      status: 502,
      body: { ok: false, error: outcome.error ?? 'ai_failed', model: usedModel, usage, cost_usd: costUsd, latency_ms: latencyMs },
    };
  }

  let draftId: string | null = null;
  if (ctx.store) {
    const { data, error } = await auth.admin
      .from('concept_drafts')
      .insert({
        academy_id: ctx.academyId,
        book_id: ctx.bookId,
        grade_label: ctx.gradeLabel,
        book_name: ctx.bookName,
        unit_path: ctx.unitPath,
        pages: ctx.pageMeta.map((p) => p.raw_page),
        page_meta: ctx.pageMeta,
        model: usedModel,
        prompt_version: CONCEPT_DRAFT_PROMPT_VERSION,
        criteria: ctx.criteriaShown,
        concept_types: ctx.types,
        prepared: ctx.prepared,
        draft: outcome.draft,
        checks: outcome.checks ?? {},
        usage,
        cost_usd: costUsd,
        created_by: auth.userId,
        ...(rerunOf ? { rerun_of: rerunOf.draftId } : {}),
      })
      .select('id')
      .single();
    if (error || !data) {
      console.error(`[${FEATURE}] save failed:`, error?.message);
      return { status: 502, body: { ok: false, error: 'save_failed', message: 'save_failed' } };
    }
    draftId = String((data as Record<string, unknown>).id);
    if (rerunOf) {
      const { error: finishError } = await auth.userClient.rpc('concept_draft_rerun_finish', {
        p_action_id: rerunOf.actionId,
        p_new_id: draftId,
      });
      if (finishError) {
        // 그사이 카드가 처리됐거나 지금 초안이 닫혔다. 새 초안은 열어 두지 않는다.
        console.error(`[${FEATURE}] rerun finish failed:`, finishError.message);
        await auth.admin
          .from('concept_drafts')
          .update({ status: 'discarded', closed_at: new Date().toISOString() })
          .eq('id', draftId);
        const code = rerunFinishCode(finishError.message);
        return { status: 409, body: { ok: false, error: code, message: code } };
      }
    }
  }

  return {
    status: 200,
    body: {
      ok: true,
      ...(ctx.store ? { draft_id: draftId } : { draft: outcome.draft, prepared: ctx.prepared }),
      checks: outcome.checks,
      criteria: ctx.criteriaShown,
      concept_types: ctx.types,
      model: usedModel,
      tier: ctx.tier,
      effort: ctx.effort,
      usage,
      cost_usd: costUsd,
      latency_ms: latencyMs,
      prompt_version: CONCEPT_DRAFT_PROMPT_VERSION,
    },
  };
}

async function readAll<T>(fetchPage: (from: number, to: number) => PromiseLike<{ data: unknown; error: unknown }>, maxRows: number) {
  const out: T[] = [];
  for (let from = 0; from < maxRows; from += 1000) {
    const { data, error } = await fetchPage(from, from + 999);
    if (error) return null;
    const rows = (data ?? []) as T[];
    out.push(...rows);
    if (rows.length < 1000) break;
  }
  return out;
}

async function folders(auth: AuthContext, provider: AiProvider, body: Record<string, unknown>, effort: string): Promise<Response> {
  const draftId = body.draft_id;
  if (!isUuid(draftId)) return errorResponse(400, 'invalid_draft');
  const { data: row, error } = await auth.admin
    .from('concept_drafts')
    .select('id,academy_id,book_id,status,unit_path,draft')
    .eq('id', draftId)
    .maybeSingle();
  if (error) return errorResponse(502, 'draft_read_failed');
  if (!row) return errorResponse(404, 'draft_not_found');
  const draftRow = row as Record<string, unknown>;
  if (draftRow.status !== 'open') return errorResponse(409, 'draft_closed');
  const academyId = String(draftRow.academy_id);
  if (!(await operatorBook(auth, academyId, String(draftRow.book_id)))) return errorResponse(403, 'book_forbidden');

  const categories = await readAll<LibraryCategory>(
    (from, to) => auth.admin.from('concept_categories').select('id,name,parent_id,code').order('id').range(from, to),
    5000,
  );
  const concepts = await readAll<{ main_category_id: string; name: string }>(
    (from, to) => auth.admin.from('concepts').select('main_category_id,name').order('id').range(from, to),
    10000,
  );
  if (!categories || !concepts) return errorResponse(502, 'library_read_failed');
  const outline = libraryOutline(categories, concepts);
  if (outline.roots.length === 0) return errorResponse(409, 'no_roots');

  const { data: others, error: othersError } = await auth.admin
    .from('concept_drafts')
    .select('unit_path,review_saved_at,draft_concepts:draft->concepts,placements:folder_plan->placements,review_concepts:review->concepts')
    .eq('academy_id', academyId)
    .eq('status', 'open')
    .neq('id', draftId)
    .order('created_at', { ascending: false })
    .limit(MAX_PENDING_DRAFTS);
  if (othersError) return errorResponse(502, 'draft_read_failed');
  const pending = ((others ?? []) as Record<string, unknown>[])
    .reverse()
    .map(pendingDraftOf)
    .filter((d): d is PendingDraft => d != null);

  const draft = (draftRow.draft ?? {}) as Record<string, unknown>;
  const briefs = (Array.isArray(draft.concepts) ? draft.concepts : []).map((c, index) => {
    const r = (c ?? {}) as Record<string, unknown>;
    return { index, title: String(r.title ?? ''), concept_type: String(r.concept_type ?? ''), content: String(r.content ?? '') };
  });
  if (briefs.length === 0) return errorResponse(409, 'no_concepts');
  const unitPath = Array.isArray(draftRow.unit_path) ? draftRow.unit_path.map(String) : [];

  const model = modelFor('primary');
  const started = Date.now();
  const outcome = await proposeConceptFolders(provider, {
    model,
    reasoningEffort: effort,
    outline,
    unitPath,
    concepts: briefs,
    pending,
    safetyId: await safetyIdentifier(auth.userId),
  });
  const latencyMs = Date.now() - started;
  if (outcome.error) console.error(`[${FEATURE}] folders failed:`, outcome.error);
  const { usage, model: usedModel, costUsd } = await record(auth, provider, {
    model,
    promptVersion: CONCEPT_FOLDER_PROMPT_VERSION,
    result: outcome.result,
    error: outcome.error,
    latencyMs,
    academyId,
  });
  if (!outcome.plan) {
    return jsonResponse(
      { ok: false, error: outcome.error ?? 'ai_failed', model: usedModel, usage, cost_usd: costUsd, latency_ms: latencyMs },
      502,
    );
  }
  const folderPlan = {
    ...outcome.plan,
    checks: outcome.checks,
    roots: outline.roots,
    pending_drafts: pending.length,
    model: usedModel,
    prompt_version: CONCEPT_FOLDER_PROMPT_VERSION,
    cost_usd: costUsd,
    created_at: new Date().toISOString(),
  };
  const { error: saveError } = await auth.admin
    .from('concept_drafts')
    .update({ folder_plan: folderPlan })
    .eq('id', draftId)
    .eq('status', 'open');
  if (saveError) {
    console.error(`[${FEATURE}] folder save failed:`, saveError.message);
    return errorResponse(502, 'save_failed');
  }
  return jsonResponse({ ok: true, folder_plan: folderPlan, usage, cost_usd: costUsd, latency_ms: latencyMs });
}

async function anchors(auth: AuthContext, provider: AiProvider, body: Record<string, unknown>, effort: string): Promise<Response> {
  const folderId = body.folder_id;
  if (!isUuid(folderId)) return errorResponse(400, 'invalid_folder');
  const folderPath: string[] = [];
  let cur: string | null = String(folderId);
  for (let i = 0; cur && i < 12; i += 1) {
    const { data, error } = await auth.admin.from('concept_categories').select('id,name,parent_id').eq('id', cur).maybeSingle();
    if (error) return errorResponse(502, 'library_read_failed');
    if (!data) {
      if (i === 0) return errorResponse(404, 'folder_not_found');
      break;
    }
    const r = data as Record<string, unknown>;
    folderPath.unshift(String(r.name ?? '').trim());
    cur = r.parent_id ? String(r.parent_id) : null;
  }

  const { data: rows, error } = await auth.admin
    .from('concepts')
    .select('id,name,content')
    .eq('main_category_id', folderId)
    .order('sort_order')
    .order('created_at')
    .limit(MAX_ANCHOR_CONCEPTS + 1);
  if (error) return errorResponse(502, 'library_read_failed');
  const list = (rows ?? []) as Record<string, unknown>[];
  if (list.length < 2) return errorResponse(409, 'too_few_concepts');
  if (list.length > MAX_ANCHOR_CONCEPTS) return errorResponse(409, 'too_many_concepts');
  const ids = list.map((r) => String(r.id));

  const [typeRows, typeLinks, anchorLinks] = await Promise.all([
    auth.admin.from('concept_types').select('id,name').order('sort_order').order('created_at').limit(200),
    auth.admin.from('concept_type_links').select('concept_id,type_id').in('concept_id', ids),
    auth.admin.from('concept_anchor_links').select('concept_id,anchor_id').in('concept_id', ids),
  ]);
  if (typeRows.error || typeLinks.error || anchorLinks.error) return errorResponse(502, 'library_read_failed');
  const typeName = new Map(((typeRows.data ?? []) as Record<string, unknown>[]).map((t) => [String(t.id), String(t.name)]));
  const typeOf = new Map(((typeLinks.data ?? []) as Record<string, unknown>[]).map((l) => [String(l.concept_id), typeName.get(String(l.type_id)) ?? '']));
  const anchorOf = new Map(((anchorLinks.data ?? []) as Record<string, unknown>[]).map((l) => [String(l.concept_id), String(l.anchor_id)]));
  const concepts: AnchorConcept[] = list.map((r) => ({
    id: String(r.id),
    name: String(r.name ?? ''),
    type: typeOf.get(String(r.id)) ?? '',
    content: String(r.content ?? ''),
    anchor_id: anchorOf.get(String(r.id)) ?? null,
  }));

  const model = modelFor('primary');
  const started = Date.now();
  const outcome = await proposeConceptAnchors(provider, {
    model,
    reasoningEffort: effort,
    folderPath,
    concepts,
    typeOrder: [...typeName.values()],
    safetyId: await safetyIdentifier(auth.userId),
  });
  const latencyMs = Date.now() - started;
  if (outcome.error) console.error(`[${FEATURE}] anchors failed:`, outcome.error);
  const { usage, model: usedModel, costUsd } = await record(auth, provider, {
    model,
    promptVersion: CONCEPT_ANCHOR_PROMPT_VERSION,
    result: outcome.result,
    error: outcome.error,
    latencyMs,
    academyId: null,
  });
  if (!outcome.proposal) {
    return jsonResponse(
      { ok: false, error: outcome.error ?? 'ai_failed', model: usedModel, usage, cost_usd: costUsd, latency_ms: latencyMs },
      502,
    );
  }
  return jsonResponse({
    ok: true,
    proposal: outcome.proposal,
    model: usedModel,
    usage,
    cost_usd: costUsd,
    latency_ms: latencyMs,
    prompt_version: CONCEPT_ANCHOR_PROMPT_VERSION,
  });
}

async function evidenceScope(auth: AuthContext, provider: AiProvider, body: Record<string, unknown>, effort: string): Promise<Response> {
  const conceptId = body.concept_id;
  if (!isUuid(conceptId)) return errorResponse(400, 'invalid_concept');
  const statementRaw = body.statement_id ?? null;
  if (statementRaw !== null && !isUuid(statementRaw)) return errorResponse(400, 'invalid_statement');
  const statementId = statementRaw === null ? null : String(statementRaw);

  const { data, error } = await auth.userClient.rpc('concept_source_evidence', { p_concept_id: conceptId });
  if (error) {
    const m = error.message ?? '';
    if (m.includes('concept_source_concept_not_found')) return errorResponse(404, 'concept_not_found');
    if (/concept_source_evidence|schema cache|does not exist/.test(m)) return errorResponse(409, 'evidence_not_ready');
    console.error(`[${FEATURE}] evidence read failed:`, m);
    return errorResponse(502, 'library_read_failed');
  }
  const input = evidenceInput(data, statementId);
  if (!input) return errorResponse(404, 'statement_not_found');
  if (input.sources.length === 0) return errorResponse(409, 'no_evidence_blocks');
  if (input.sources.length > MAX_EVIDENCE_SOURCES) return errorResponse(409, 'too_many_sources');
  const { data: concept } = await auth.admin.from('concepts').select('name').eq('id', conceptId).maybeSingle();

  const model = modelFor('primary');
  const started = Date.now();
  const outcome = await proposeEvidenceScopes(provider, {
    model,
    reasoningEffort: effort,
    conceptName: String((concept as Record<string, unknown> | null)?.name ?? ''),
    ...input,
    safetyId: await safetyIdentifier(auth.userId),
  });
  const latencyMs = Date.now() - started;
  if (outcome.error) console.error(`[${FEATURE}] evidence scope failed:`, outcome.error);
  const { usage, model: usedModel, costUsd } = await record(auth, provider, {
    model,
    promptVersion: CONCEPT_EVIDENCE_PROMPT_VERSION,
    result: outcome.result,
    error: outcome.error,
    latencyMs,
    academyId: null,
  });
  if (!outcome.proposal) {
    return jsonResponse(
      { ok: false, error: outcome.error ?? 'ai_failed', model: usedModel, usage, cost_usd: costUsd, latency_ms: latencyMs },
      502,
    );
  }
  return jsonResponse({
    ok: true,
    proposal: outcome.proposal,
    model: usedModel,
    usage,
    cost_usd: costUsd,
    latency_ms: latencyMs,
    prompt_version: CONCEPT_EVIDENCE_PROMPT_VERSION,
  });
}

async function compare(auth: AuthContext, provider: AiProvider, body: Record<string, unknown>, effort: string): Promise<Response> {
  const draftId = body.draft_id;
  if (!isUuid(draftId)) return errorResponse(400, 'invalid_draft');
  const keys = Array.isArray(body.keys) ? new Set(body.keys.map(String)) : null;
  const { data: row, error } = await auth.admin
    .from('concept_drafts')
    .select('id,academy_id,book_id,status,book_name,unit_path,review,draft,prepared,folder_plan')
    .eq('id', draftId)
    .maybeSingle();
  if (error) return errorResponse(502, 'draft_read_failed');
  if (!row) return errorResponse(404, 'draft_not_found');
  const draftRow = row as Record<string, unknown>;
  if (draftRow.status !== 'open') return errorResponse(409, 'draft_closed');
  if (!(await operatorBook(auth, String(draftRow.academy_id), String(draftRow.book_id)))) {
    return errorResponse(403, 'book_forbidden');
  }

  const entries = reviewEntries(draftRow).filter((e) => !keys || keys.has(e.key));
  if (entries.length === 0) return errorResponse(409, 'no_concepts');
  const overlaps = overlapNames(draftRow.folder_plan);
  const names = new Set<string>();
  for (const e of entries) {
    if (e.title) names.add(e.title);
    for (const n of overlaps.get(e.index) ?? []) names.add(n);
  }
  const byName = new Map<string, string[]>();
  if (names.size > 0) {
    const { data: named, error: namedError } = await auth.admin
      .from('concepts')
      .select('id,name')
      .in('name', [...names])
      .order('created_at')
      .limit(500);
    if (namedError) return errorResponse(502, 'library_read_failed');
    for (const r of (named ?? []) as Record<string, unknown>[]) {
      const k = String(r.name ?? '').trim();
      byName.set(k, [...(byName.get(k) ?? []), String(r.id)]);
    }
  }
  const idsOf = new Map<string, string[]>();
  for (const e of entries) {
    const ids = [
      ...(e.target ? [e.target] : []),
      ...(byName.get(e.title) ?? []),
      ...(overlaps.get(e.index) ?? []).flatMap((n) => byName.get(n) ?? []),
    ];
    idsOf.set(e.key, [...new Set(ids)].slice(0, MAX_COMPARE_CANDIDATES));
  }
  const noCandidates = entries.filter((e) => idsOf.get(e.key)!.length === 0).map((e) => e.key);
  const withCandidates = entries.filter((e) => idsOf.get(e.key)!.length > 0);
  if (withCandidates.length === 0) return errorResponse(409, 'no_candidates');
  const picked = withCandidates.slice(0, MAX_COMPARE_ITEMS);
  const overLimit = withCandidates.slice(MAX_COMPARE_ITEMS).map((e) => e.key);

  const allIds = [...new Set(picked.flatMap((e) => idsOf.get(e.key)!))];
  const { data: targetRows, error: targetError } = await auth.userClient.rpc('concept_compare_targets', { p_ids: allIds });
  if (targetError) {
    const m = targetError.message ?? '';
    if (/concept_compare_targets|schema cache|does not exist/.test(m)) return errorResponse(409, 'compare_not_ready');
    console.error(`[${FEATURE}] compare read failed:`, m);
    return errorResponse(502, 'library_read_failed');
  }
  const targets = new Map<string, CompareTarget>();
  for (const v of Array.isArray(targetRows) ? targetRows : []) {
    const t = compareTargetOf(v);
    if (t) targets.set(t.id, t);
  }
  const items: CompareItem[] = picked
    .map((e) => ({
      key: e.key,
      title: e.title,
      content: e.content,
      evidence: evidenceText(draftRow.prepared, e.blocks),
      candidates: idsOf.get(e.key)!.map((id) => targets.get(id)).filter((t): t is CompareTarget => t != null),
    }))
    .filter((it) => it.candidates.length > 0);
  if (items.length === 0) return errorResponse(409, 'no_candidates');

  const model = modelFor('primary');
  const started = Date.now();
  const outcome = await proposeCompare(provider, {
    model,
    reasoningEffort: effort,
    unitPath: Array.isArray(draftRow.unit_path) ? draftRow.unit_path.map(String) : [],
    bookName: String(draftRow.book_name ?? ''),
    items,
    noCandidates,
    overLimit,
    safetyId: await safetyIdentifier(auth.userId),
  });
  const latencyMs = Date.now() - started;
  if (outcome.error) console.error(`[${FEATURE}] compare failed:`, outcome.error);
  const { usage, model: usedModel, costUsd } = await record(auth, provider, {
    model,
    promptVersion: CONCEPT_COMPARE_PROMPT_VERSION,
    result: outcome.result,
    error: outcome.error,
    latencyMs,
    academyId: null,
  });
  if (!outcome.proposal) {
    return jsonResponse(
      { ok: false, error: outcome.error ?? 'ai_failed', model: usedModel, usage, cost_usd: costUsd, latency_ms: latencyMs },
      502,
    );
  }
  return jsonResponse({
    ok: true,
    proposal: outcome.proposal,
    model: usedModel,
    usage,
    cost_usd: costUsd,
    latency_ms: latencyMs,
    prompt_version: CONCEPT_COMPARE_PROMPT_VERSION,
  });
}