import { type AuthContext, errorResponse, jsonResponse, safetyIdentifier } from '../_shared/ai/auth.ts';
import { getBudgetStatus } from '../_shared/ai/budget.ts';
import { estimateCostUsd, modelFor, thinkWallClockMs } from '../_shared/ai/config.ts';
import { createAiProvider } from '../_shared/ai/provider.ts';
import { type AiContentPart, type AiProvider, type AiUsage, emptyUsage, finalText } from '../_shared/ai/types.ts';
import { recordAiRun } from '../_shared/ai/usage.ts';
import {
  type ConceptCandidates,
  conceptIdsFromRefs,
  loadConceptCandidates,
  loadScopeUnitNames,
} from './textbook_concept_candidates.ts';
import { orderedFigureAssets } from './textbook_problem_fix.ts';
import { combineStem, parseProblems, withoutDependentSetCommonStem } from './textbook_problem_review.ts';
import type { SupabaseLike } from './store.ts';
import { normalizeVisualTags, VISUAL_TAG_NONE, VISUAL_TAGS } from './textbook_visual_tags.ts';
import { uuidOrNull } from './validate.ts';

type Rec = Record<string, unknown>;

export const TEXTBOOK_META_PROMPT_VERSION = 'textbook-problem-meta-2026-11-13';

const MAX_CONCEPTS = 4;
const MAX_THINKINGS = 5;
const MAX_NEW_CONCEPTS = 2;
const MAX_FIGURE_IMAGES = 3;
const FIGURE_URL_SECONDS = 600;
const VISUAL_TAG_CHOICES = [...VISUAL_TAGS, VISUAL_TAG_NONE];

export interface ConceptProposal {
  name: string;
  type: string;
  content: string;
  near_concept_id: string;
  reason: string;
}

export interface MetaResult {
  conceptIds: string[];
  thinkingIds: string[];
  proposals: ConceptProposal[];
  /** 놓을 폴더(가장 가까운 기존 개념)를 고르지 못해 버린 새 개념 이름 */
  droppedProposals: string[];
  /** 표준 태그만 남긴 시각 태그. 시각 요소가 없으면 ['없음'] */
  visualTags: string[];
}

export interface MetaDictionary {
  candidates: ConceptCandidates;
  thinkByCode: Map<string, string>;
  typeNames: string[];
}

function metaSchema(typeNames: string[]): Rec {
  return {
    type: 'object',
    additionalProperties: false,
    required: ['problems'],
    properties: {
      problems: {
        type: 'array',
        items: {
          type: 'object',
          additionalProperties: false,
          required: ['crop_id', 'concept_refs', 'thinking_codes', 'new_concepts', 'visual_tags'],
          properties: {
            crop_id: { type: 'string' },
            concept_refs: { type: 'array', items: { type: 'string' } },
            thinking_codes: { type: 'array', items: { type: 'string' } },
            visual_tags: { type: 'array', items: { type: 'string', enum: VISUAL_TAG_CHOICES } },
            new_concepts: {
              type: 'array',
              items: {
                type: 'object',
                additionalProperties: false,
                required: ['name', 'type', 'content', 'near_ref', 'reason'],
                properties: {
                  name: { type: 'string' },
                  type: { type: 'string', enum: typeNames },
                  content: { type: 'string' },
                  near_ref: { type: ['string', 'null'] },
                  reason: { type: 'string' },
                },
              },
            },
          },
        },
      },
    },
  };
}

const META_INSTRUCTIONS = `당신은 Yggdrasill 수학 문항 검수 엔진의 [문항 메타: 개념·사고·시각 태그] 담당입니다.
각 문항의 본문(stem)·선지(choices)·정답(answer)·풀이(solution)를 읽고, 이 문항을 푸는 데 쓰이는 개념과 사고, 문항의 시각 요소를 고르세요.

[수행 원칙]
1. 개념(concept_refs)
   - candidate_concepts 는 같은 학년 개념서에서 이 단원(unit)에 나오는 개념입니다. unit.candidate_scope 가 "grade" 이면 단원이 맞는 개념이 없어 학년 전체를 준 것입니다.
   - 이 문항을 푸는 데 직접 쓰인 개념의 ref 만 1~4개 고르세요. 목록에 없는 ref 를 지어내지 마세요.
   - 단원 이름이 비슷할 뿐 풀이에 쓰이지 않는 개념은 고르지 마세요.
2. 새 개념(new_concepts)
   - 풀이에 꼭 필요한 개념이 목록에 없을 때만 0~2개 제안합니다. 목록의 개념으로 충분하면 빈 배열 [] 입니다.
   - 이름만 다르고 뜻이 같은 개념이 목록에 있으면 새로 만들지 말고 그 ref 를 고르세요.
   - name: 개념 라이브러리 이름처럼 짧은 명사구.
   - type: concept_types 의 이름 중 하나.
   - content: 학생이 읽는 설명 한두 문장. 수식은 $...$ 로 씁니다.
   - near_ref: 이 개념과 같은 폴더에 둘 가장 가까운 목록 개념의 ref. 고를 수 없으면 null.
   - reason: 목록의 개념으로 부족한 이유 한 줄.
3. 사고(thinking_codes)
   - thinking_primitives(범용 사고틀 frame + 실전 알고리즘 algorithm)에서 이 문항 풀이에 쓰인 사고 code 를 1~5개 고르세요.
4. 시각 태그(visual_tags)
   - 문항에 도형·그래프·표 등 시각 요소가 있거나 언급되면 표준 태그 중 해당하는 것을 모두 고르세요.
   - figure_images 가 1 이상인 문항은 "[그림] crop_id=…" 뒤에 그 문항의 그림을 붙였습니다. 그림을 보고 고르세요.
   - 시각 요소가 없으면 ["${VISUAL_TAG_NONE}"] 하나만 고르세요. "${VISUAL_TAG_NONE}"을 다른 태그와 함께 쓰지 마세요.
5. 모든 문항에 대해 crop_id 를 그대로 돌려주세요.`;

/** 모델이 낸 문항 한 개의 메타를 개념·사고 id 와 새 개념 초안으로 바꾼다. */
export function metaFromModel(p: Rec, dict: MetaDictionary): MetaResult {
  const conceptIds = conceptIdsFromRefs(p.concept_refs, dict.candidates, MAX_CONCEPTS);
  const thinkingIds: string[] = [];
  for (const raw of Array.isArray(p.thinking_codes) ? p.thinking_codes : []) {
    const id = dict.thinkByCode.get(String(raw ?? '').trim());
    if (id && !thinkingIds.includes(id)) thinkingIds.push(id);
    if (thinkingIds.length >= MAX_THINKINGS) break;
  }

  const nameToId = new Map(dict.candidates.list.map((c) => [c.name.trim(), c.id]));
  const proposals: ConceptProposal[] = [];
  const droppedProposals: string[] = [];
  for (const raw of Array.isArray(p.new_concepts) ? p.new_concepts : []) {
    if (proposals.length >= MAX_NEW_CONCEPTS) break;
    const n = (raw ?? {}) as Rec;
    const name = String(n.name ?? '').trim().slice(0, 80);
    if (!name) continue;
    // 목록에 있는 개념을 새 개념으로 낸 경우는 그 개념을 고른 것으로 본다.
    const listed = nameToId.get(name);
    if (listed) {
      if (!conceptIds.includes(listed) && conceptIds.length < MAX_CONCEPTS) conceptIds.push(listed);
      continue;
    }
    if (proposals.some((x) => x.name === name)) continue;
    const near = dict.candidates.byRef.get(String(n.near_ref ?? '').trim());
    if (!near) {
      droppedProposals.push(name);
      continue;
    }
    const type = String(n.type ?? '').trim();
    proposals.push({
      name,
      type: dict.typeNames.includes(type) ? type : '성질',
      content: String(n.content ?? '').trim().slice(0, 600) || name,
      near_concept_id: near.id,
      reason: String(n.reason ?? '').trim().slice(0, 300),
    });
  }
  const visualTags = normalizeVisualTags(
    (Array.isArray(p.visual_tags) ? p.visual_tags : [])
      .map((t) => String(t ?? '').trim())
      .filter((t) => VISUAL_TAG_CHOICES.includes(t)),
  );
  return { conceptIds, thinkingIds, proposals, droppedProposals, visualTags };
}

/** 개념·사고를 아직 단원 기준 후보로 고르지 않았는가. 사람이 둘 다 고쳤으면 고르지 않는다. */
export function needsConceptMeta(it: Rec, force: boolean): boolean {
  const src = (it.meta_sources ?? {}) as Rec;
  if (src.concepts === 'owner' && src.thinkings === 'owner') return false;
  return force || !it.meta_checked_at;
}

/** AI 풀이를 거쳤는데 시각 태그가 비었는가. 풀이 전 문항은 2단계 풀이가 태그를 고른다. */
export function needsVisualTags(it: Rec): boolean {
  return String(it.ai_solution ?? '').trim().length > 0 && normalizeVisualTags(it.visual_tags).length === 0;
}

/** 메타 AI 대상: 문제은행 문항과 본문이 있고, 개념·사고를 다시 골라야 하거나 시각 태그가 빈 문항. */
export function isMetaTodo(it: Rec, force: boolean): boolean {
  if (!String(it.pb_question_id ?? '').trim()) return false;
  if (!String(it.stem ?? '').trim() && !String(it.common_stem ?? '').trim()) return false;
  return needsConceptMeta(it, force) || needsVisualTags(it);
}

/** 시각 태그를 고를 문항의 그림(문제은행 그림 자산)을 모델이 볼 수 있게 서명 URL 로 만든다. */
async function signFigureUrls(admin: SupabaseLike, items: Rec[]): Promise<Map<string, string[]>> {
  const out = new Map<string, string[]>();
  await Promise.all(items.map(async (it) => {
    const urls: string[] = [];
    for (const a of orderedFigureAssets(it.pb_figure_assets).slice(0, MAX_FIGURE_IMAGES)) {
      const bucket = String(a.bucket ?? '').trim();
      const path = String(a.path ?? '').trim();
      if (!bucket || !path) continue;
      const { data } = await admin.storage.from(bucket).createSignedUrl(path, FIGURE_URL_SECONDS);
      if (data?.signedUrl) urls.push(data.signedUrl);
    }
    if (urls.length > 0) out.set(String(it.crop_id), urls);
  }));
  return out;
}

export interface MetaBatchInput {
  unit: { gradeLabel: string; bigName: string; midName: string };
  dict: MetaDictionary;
  thinkList: Rec[];
  types: Rec[];
  items: Rec[];
  /** crop_id → 시각 태그를 고를 때 보여 줄 그림 URL */
  figureUrls?: Map<string, string[]>;
}

export interface MetaBatchDeps {
  provider: AiProvider;
  model: string;
  safetyId: string;
  signal: AbortSignal;
}

/** 한 묶음의 문항 메타를 모델에 한 번 묻는다. 결과를 저장하지는 않는다. */
export async function runMetaBatch(
  deps: MetaBatchDeps,
  input: MetaBatchInput,
): Promise<{ byCrop: Map<string, MetaResult>; usage: AiUsage }> {
  const { dict } = input;
  const figureUrls = input.figureUrls ?? new Map<string, string[]>();
  const payload = {
    unit: {
      grade_label: input.unit.gradeLabel,
      big_name: input.unit.bigName,
      mid_name: input.unit.midName,
      candidate_scope: dict.candidates.scope,
    },
    candidate_concepts: dict.candidates.list.map((c) => ({ ref: c.ref, name: c.name })),
    concept_types: input.types.map((t) => ({ name: t.name, description: t.description ?? '' })),
    thinking_primitives: input.thinkList.map((t) => ({ code: t.code, kind: t.kind, cat: t.category, title: t.title })),
    problems: input.items.map((it) => ({
      crop_id: String(it.crop_id),
      problem_number: it.problem_number ?? '',
      stem: combineStem(it.common_stem, it.stem).slice(0, 2200),
      choices: it.choices ?? [],
      answer: typeof it.existing_answer === 'string' && it.existing_answer.trim() ? it.existing_answer : null,
      solution: String(it.solution_transcribed ?? '').trim().slice(0, 2500) ||
        String(it.ai_solution ?? '').trim().slice(0, 2500) || null,
      figure_images: figureUrls.get(String(it.crop_id))?.length ?? 0,
    })),
  };
  const parts: AiContentPart[] = [{ type: 'text', text: JSON.stringify(payload) }];
  for (const it of input.items) {
    const urls = figureUrls.get(String(it.crop_id)) ?? [];
    if (urls.length === 0) continue;
    parts.push({ type: 'text', text: `[그림] crop_id=${String(it.crop_id)}` });
    for (const url of urls) parts.push({ type: 'image', url, detail: 'low' });
  }
  const res = await deps.provider.complete(
    {
      model: deps.model,
      instructions: META_INSTRUCTIONS,
      input: [{ kind: 'message', role: 'user', parts }],
      jsonSchema: { name: 'textbook_problem_meta', schema: metaSchema(dict.typeNames) },
      reasoningEffort: 'low',
      maxOutputTokens: 8000,
      safetyId: deps.safetyId,
    },
    deps.signal,
  );
  const parsed = parseProblems(finalText(res));
  const byCrop = new Map<string, MetaResult>();
  for (const it of input.items) {
    const p = parsed.get(String(it.crop_id));
    if (p) byCrop.set(String(it.crop_id), metaFromModel(p, dict));
  }
  return { byCrop, usage: res.usage };
}

/**
 * 메타 전용 AI 실행(사양 3번, 5-3번, 5-6번). 본문·풀이를 읽어 개념·사고 태그와 새 개념 초안을 제안하고,
 * AI 풀이 뒤에도 비어 있는 시각 태그를 고른다(그림이 있으면 그림도 본다).
 * 제안은 검수 쪽(textbook_problem_analyses)에만 쓰고, 문제은행 반영과 새 개념 생성은 소단원 확정 때 한다.
 *   body: { academy_id, book_id, grade_label, big_order, mid_order, crop_ids?, chunk_size?, force_rerun? }
 */
export async function handleTextbookProblemMeta(req: Request, auth: AuthContext, body: Rec): Promise<Response> {
  const academyId = uuidOrNull(body.academy_id);
  const bookId = uuidOrNull(body.book_id);
  const gradeLabel = typeof body.grade_label === 'string' ? body.grade_label.trim() : '';
  const bigOrder = Number(body.big_order);
  const midOrder = Number(body.mid_order);
  const chunkSize = Math.max(1, Math.min(12, Number(body.chunk_size) || 8));
  const force = body.force_rerun === true;
  const requested = new Set(
    (Array.isArray(body.crop_ids) ? (body.crop_ids as unknown[]) : [])
      .map((x) => uuidOrNull(x))
      .filter((x): x is string => !!x),
  );
  if (!academyId || !bookId || !gradeLabel || !Number.isInteger(bigOrder) || !Number.isInteger(midOrder)) {
    return errorResponse(400, 'invalid_scope', '학원, 교재, 학년, 중단원 정보가 필요합니다.');
  }

  const wallClockMs = thinkWallClockMs();
  const provider = createAiProvider({ timeoutMs: wallClockMs + 5000 });
  if (!provider) return errorResponse(503, 'ai_not_configured', 'OPENAI_API_KEY 비밀값이 설정되지 않았습니다.');
  const budget = await getBudgetStatus(auth.admin).catch(() => null);
  if (budget?.exceeded && budget.mode === 'block') {
    return errorResponse(429, 'budget_exceeded', '이번 달 AI 한도를 넘었습니다.');
  }

  const overviewRes = await auth.userClient.rpc('textbook_review_unit_overview', {
    p_academy_id: academyId,
    p_book_id: bookId,
    p_grade_label: gradeLabel,
    p_big_order: bigOrder,
    p_mid_order: midOrder,
  });
  if (overviewRes.error) return errorResponse(502, 'overview_failed', overviewRes.error.message);
  const allItems = (((overviewRes.data as Rec | null)?.items ?? []) as unknown[])
    .map((x) => withoutDependentSetCommonStem((x ?? {}) as Rec));
  const todo = allItems.filter((it) => isMetaTodo(it, force) && (requested.size === 0 || requested.has(String(it.crop_id))));
  const batch = todo.slice(0, chunkSize);
  if (batch.length === 0) {
    return jsonResponse({ ok: true, processed: 0, remaining: 0, total: allItems.length, done: true });
  }

  const unit = await loadScopeUnitNames(auth.admin, { bookId, gradeLabel, bigOrder, midOrder });
  const [candidates, thinkRes, typeRes] = await Promise.all([
    loadConceptCandidates(auth.admin, gradeLabel, unit.bigName, unit.midName),
    auth.admin
      .from('thinking_primitives')
      .select('id,code,kind,category,title')
      .eq('is_active', true)
      .order('sort_order')
      .limit(300),
    auth.admin.from('concept_types').select('name,description').order('sort_order').limit(40),
  ]);
  const thinkList = (thinkRes.data ?? []) as Rec[];
  const types = (typeRes.data ?? []) as Rec[];
  const dict: MetaDictionary = {
    candidates,
    thinkByCode: new Map(thinkList.map((t) => [String(t.code), String(t.id)])),
    typeNames: types.map((t) => String(t.name)).filter(Boolean),
  };
  if (dict.typeNames.length === 0) dict.typeNames = ['성질'];
  const figureUrls = await signFigureUrls(
    auth.admin as unknown as SupabaseLike,
    batch.filter((it) => needsVisualTags(it)),
  );

  const startedAt = Date.now();
  const model = modelFor('primary');
  const safetyId = await safetyIdentifier(auth.userId);
  const signal = AbortSignal.any([req.signal, AbortSignal.timeout(wallClockMs)]);
  let byCrop: Map<string, MetaResult>;
  let usage: AiUsage;
  try {
    ({ byCrop, usage } = await runMetaBatch(
      { provider, model, safetyId, signal },
      { unit: { gradeLabel, ...unit }, dict, thinkList, types, items: batch, figureUrls },
    ));
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    await recordAiRun(auth.admin, {
      feature: 'textbook_problem_meta',
      provider: provider.name,
      model,
      promptVersion: TEXTBOOK_META_PROMPT_VERSION,
      status: 'error',
      error: message,
      usage: emptyUsage(),
      costUsd: 0,
      latencyMs: Date.now() - startedAt,
      createdBy: auth.userId,
      features: { book_id: bookId, grade_label: gradeLabel, big_order: bigOrder, mid_order: midOrder, count: batch.length },
    });
    return errorResponse(502, 'meta_failed', message);
  }

  const costUsd = estimateCostUsd(model, usage, 0);
  let processed = 0;
  const skippedOwner: string[] = [];
  const dropped: Array<{ crop_id: string; names: string[] }> = [];
  for (const it of batch) {
    const cropId = String(it.crop_id);
    const m = byCrop.get(cropId);
    if (!m) continue;
    const concepts = needsConceptMeta(it, force);
    const visual = needsVisualTags(it);
    if (visual && m.visualTags.length === 0 && !concepts) continue;
    const { data, error } = await auth.admin.rpc('textbook_review_set_meta', {
      p_crop_id: cropId,
      p_concept_ids: concepts ? m.conceptIds : null,
      p_thinking_ids: concepts ? m.thinkingIds : null,
      p_concept_proposals: concepts ? m.proposals : null,
      p_visual_tags: visual && m.visualTags.length > 0 ? m.visualTags : null,
      p_source: 'ai',
    });
    if (error) continue;
    processed += 1;
    if (((data as Rec | null)?.skipped_owner as unknown[] | undefined)?.length) skippedOwner.push(cropId);
    if (m.droppedProposals.length > 0) dropped.push({ crop_id: cropId, names: m.droppedProposals });
  }

  await recordAiRun(auth.admin, {
    feature: 'textbook_problem_meta',
    provider: provider.name,
    model,
    promptVersion: TEXTBOOK_META_PROMPT_VERSION,
    status: 'ok',
    error: null,
    usage,
    costUsd,
    latencyMs: Date.now() - startedAt,
    createdBy: auth.userId,
    features: {
      book_id: bookId,
      grade_label: gradeLabel,
      big_order: bigOrder,
      mid_order: midOrder,
      count: batch.length,
      processed,
      candidate_scope: candidates.scope,
      candidate_count: candidates.list.length,
      proposals: [...byCrop.values()].reduce((n, m) => n + m.proposals.length, 0),
      visual_tag_items: batch.filter((it) => needsVisualTags(it)).length,
      figure_images: [...figureUrls.values()].reduce((n, urls) => n + urls.length, 0),
    },
  });

  // 모델이 빠뜨렸거나 저장하지 못한 문항은 다음 호출에서 다시 대상이 된다.
  const remaining = Math.max(0, todo.length - processed);
  return jsonResponse({
    ok: true,
    processed,
    remaining,
    total: allItems.length,
    done: remaining === 0,
    candidate_scope: candidates.scope,
    skipped_owner: skippedOwner,
    dropped_proposals: dropped,
    cost_usd: costUsd,
  });
}
