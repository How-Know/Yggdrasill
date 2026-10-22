import { finalText, type AiProvider, type AiRequest, type AiResult } from '../_shared/ai/types.ts';
import {
  buildConceptDraftPrompt,
  checkConceptDraft,
  CONCEPT_DRAFT_SCHEMA,
  parseConceptDraft,
  type ConceptDraftResult,
  type ConceptTypeRef,
  type CriterionRef,
  type DraftChecks,
  type PreparedUnit,
} from './organize.ts';
import {
  buildFolderPrompt,
  checkFolderPlan,
  CONCEPT_FOLDER_SCHEMA,
  parseFolderPlan,
  type DraftConceptBrief,
  type FolderPlan,
  type FolderPlanChecks,
  type LibraryOutline,
  type PendingDraft,
} from './folders.ts';
import {
  type AnchorConcept,
  type AnchorProposal,
  buildAnchorPrompt,
  CONCEPT_ANCHOR_SCHEMA,
  parseAnchorProposal,
} from './anchors.ts';
import {
  buildEvidencePrompt,
  CONCEPT_EVIDENCE_SCHEMA,
  type EvidenceProposal,
  type EvidenceSource,
  parseEvidenceProposal,
} from './evidence.ts';
import { buildComparePrompt, type CompareItem, type CompareProposal, CONCEPT_COMPARE_SCHEMA, parseCompareProposal } from './compare.ts';

export interface ConceptDraftOutcome {
  result: AiResult | null;
  draft: ConceptDraftResult | null;
  checks: DraftChecks | null;
  error: string | null;
}

export interface ConceptDraftOpts {
  model: string;
  reasoningEffort: string;
  bookName: string;
  gradeLabel: string;
  unitPath: string[];
  prepared: PreparedUnit;
  criteria: CriterionRef[];
  types: ConceptTypeRef[];
  safetyId?: string;
}

export function conceptDraftRequest(opts: ConceptDraftOpts): AiRequest {
  const prompt = buildConceptDraftPrompt(opts);
  return {
    model: opts.model,
    instructions: prompt.instructions,
    input: [{ kind: 'message', role: 'user', parts: [{ type: 'text', text: prompt.userText }] }],
    jsonSchema: { name: 'concept_draft', schema: CONCEPT_DRAFT_SCHEMA },
    reasoningEffort: opts.reasoningEffort,
    maxOutputTokens: prompt.maxOutputTokens,
    safetyId: opts.safetyId,
  };
}

/** 받은 결과를 초안으로 읽고 검사를 붙인다. 바로 부른 결과와 백그라운드 결과가 같은 길을 지난다. */
export function conceptDraftOutcome(
  result: AiResult,
  opts: { prepared: PreparedUnit; types: ConceptTypeRef[] },
): ConceptDraftOutcome {
  if (result.status !== 'completed') {
    return { result, draft: null, checks: null, error: `incomplete:${result.incompleteReason ?? 'unknown'}` };
  }
  const draft = parseConceptDraft(finalText(result), opts.types);
  if (!draft) return { result, draft: null, checks: null, error: 'invalid_output' };
  return { result, draft, checks: checkConceptDraft(draft, opts.prepared, opts.types), error: null };
}

export async function organizeConceptDraft(provider: AiProvider, opts: ConceptDraftOpts): Promise<ConceptDraftOutcome> {
  let result: AiResult;
  try {
    result = await provider.complete(conceptDraftRequest(opts));
  } catch (e) {
    return { result: null, draft: null, checks: null, error: e instanceof Error ? e.message : String(e) };
  }
  return conceptDraftOutcome(result, opts);
}

export interface FolderPlanOutcome {
  result: AiResult | null;
  plan: FolderPlan | null;
  checks: FolderPlanChecks | null;
  error: string | null;
}

export async function proposeConceptFolders(
  provider: AiProvider,
  opts: {
    model: string;
    reasoningEffort: string;
    outline: LibraryOutline;
    unitPath: string[];
    concepts: DraftConceptBrief[];
    pending?: PendingDraft[];
    safetyId?: string;
  },
): Promise<FolderPlanOutcome> {
  const prompt = buildFolderPrompt(opts);
  let result: AiResult | null = null;
  try {
    result = await provider.complete({
      model: opts.model,
      instructions: prompt.instructions,
      input: [{ kind: 'message', role: 'user', parts: [{ type: 'text', text: prompt.userText }] }],
      jsonSchema: { name: 'concept_folder_plan', schema: CONCEPT_FOLDER_SCHEMA },
      reasoningEffort: opts.reasoningEffort,
      maxOutputTokens: prompt.maxOutputTokens,
      safetyId: opts.safetyId,
    });
  } catch (e) {
    return { result: null, plan: null, checks: null, error: e instanceof Error ? e.message : String(e) };
  }
  if (result.status !== 'completed') {
    return { result, plan: null, checks: null, error: `incomplete:${result.incompleteReason ?? 'unknown'}` };
  }
  const parsed = parseFolderPlan(finalText(result));
  if (!parsed) return { result, plan: null, checks: null, error: 'invalid_output' };
  const plan = { ...parsed, overlaps: parsed.overlaps.filter((o) => o.concept < opts.concepts.length) };
  return { result, plan, checks: checkFolderPlan(plan, opts.outline, opts.concepts.length), error: null };
}

export async function proposeConceptAnchors(
  provider: AiProvider,
  opts: {
    model: string;
    reasoningEffort: string;
    folderPath: string[];
    concepts: AnchorConcept[];
    typeOrder: string[];
    safetyId?: string;
  },
): Promise<{ result: AiResult | null; proposal: AnchorProposal | null; error: string | null }> {
  const prompt = buildAnchorPrompt(opts);
  let result: AiResult | null = null;
  try {
    result = await provider.complete({
      model: opts.model,
      instructions: prompt.instructions,
      input: [{ kind: 'message', role: 'user', parts: [{ type: 'text', text: prompt.userText }] }],
      jsonSchema: { name: 'concept_anchor_plan', schema: CONCEPT_ANCHOR_SCHEMA },
      reasoningEffort: opts.reasoningEffort,
      maxOutputTokens: prompt.maxOutputTokens,
      safetyId: opts.safetyId,
    });
  } catch (e) {
    return { result: null, proposal: null, error: e instanceof Error ? e.message : String(e) };
  }
  if (result.status !== 'completed') {
    return { result, proposal: null, error: `incomplete:${result.incompleteReason ?? 'unknown'}` };
  }
  const proposal = parseAnchorProposal(finalText(result), opts.concepts);
  if (!proposal) return { result, proposal: null, error: 'invalid_output' };
  return { result, proposal, error: null };
}

export async function proposeEvidenceScopes(
  provider: AiProvider,
  opts: {
    model: string;
    reasoningEffort: string;
    conceptName: string;
    basisKind: string;
    basis: string;
    basisMd5: string;
    sources: EvidenceSource[];
    noBlocks: string[];
    safetyId?: string;
  },
): Promise<{ result: AiResult | null; proposal: EvidenceProposal | null; error: string | null }> {
  const prompt = buildEvidencePrompt(opts);
  let result: AiResult | null = null;
  try {
    result = await provider.complete({
      model: opts.model,
      instructions: prompt.instructions,
      input: [{ kind: 'message', role: 'user', parts: [{ type: 'text', text: prompt.userText }] }],
      jsonSchema: { name: 'concept_source_scope', schema: CONCEPT_EVIDENCE_SCHEMA },
      reasoningEffort: opts.reasoningEffort,
      maxOutputTokens: prompt.maxOutputTokens,
      safetyId: opts.safetyId,
    });
  } catch (e) {
    return { result: null, proposal: null, error: e instanceof Error ? e.message : String(e) };
  }
  if (result.status !== 'completed') {
    return { result, proposal: null, error: `incomplete:${result.incompleteReason ?? 'unknown'}` };
  }
  const proposal = parseEvidenceProposal(finalText(result), opts.sources, opts.basisMd5, opts.noBlocks);
  if (!proposal) return { result, proposal: null, error: 'invalid_output' };
  return { result, proposal, error: null };
}

export async function proposeCompare(
  provider: AiProvider,
  opts: {
    model: string;
    reasoningEffort: string;
    unitPath: string[];
    bookName: string;
    items: CompareItem[];
    noCandidates: string[];
    overLimit: string[];
    safetyId?: string;
  },
): Promise<{ result: AiResult | null; proposal: CompareProposal | null; error: string | null }> {
  const prompt = buildComparePrompt(opts);
  let result: AiResult | null = null;
  try {
    result = await provider.complete({
      model: opts.model,
      instructions: prompt.instructions,
      input: [{ kind: 'message', role: 'user', parts: [{ type: 'text', text: prompt.userText }] }],
      jsonSchema: { name: 'concept_draft_compare', schema: CONCEPT_COMPARE_SCHEMA },
      reasoningEffort: opts.reasoningEffort,
      maxOutputTokens: prompt.maxOutputTokens,
      safetyId: opts.safetyId,
    });
  } catch (e) {
    return { result: null, proposal: null, error: e instanceof Error ? e.message : String(e) };
  }
  if (result.status !== 'completed') {
    return { result, proposal: null, error: `incomplete:${result.incompleteReason ?? 'unknown'}` };
  }
  const proposal = parseCompareProposal(finalText(result), opts.items, opts.noCandidates, opts.overLimit);
  if (!proposal) return { result, proposal: null, error: 'invalid_output' };
  return { result, proposal, error: null };
}
