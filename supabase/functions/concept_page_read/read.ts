import { finalText, type AiProvider, type AiResult } from '../_shared/ai/types.ts';
import {
  buildConceptPagePrompt,
  CONCEPT_PAGE_SCHEMA,
  parseConceptPage,
  type ConceptPageInput,
  type ConceptPageResult,
} from './prompt.ts';

export interface ConceptPageReadOutcome {
  result: AiResult | null;
  page: ConceptPageResult | null;
  error: string | null;
}

export async function readConceptPage(
  provider: AiProvider,
  opts: {
    model: string;
    reasoningEffort: string;
    input: ConceptPageInput;
    imageBase64: string;
    mimeType: string;
    safetyId?: string;
  },
): Promise<ConceptPageReadOutcome> {
  const prompt = buildConceptPagePrompt(opts.input);
  let result: AiResult | null = null;
  try {
    result = await provider.complete({
      model: opts.model,
      instructions: prompt.instructions,
      input: [{
        kind: 'message',
        role: 'user',
        parts: [
          // auto는 원본 크기를 유지한다(OCR 권장). 실행기가 긴 변을 미리 줄여 보낸다.
          { type: 'image', url: `data:${opts.mimeType};base64,${opts.imageBase64}`, detail: 'auto' },
          { type: 'text', text: prompt.userText },
        ],
      }],
      jsonSchema: { name: 'concept_page', schema: CONCEPT_PAGE_SCHEMA },
      reasoningEffort: opts.reasoningEffort,
      maxOutputTokens: prompt.maxOutputTokens,
      safetyId: opts.safetyId,
    });
  } catch (e) {
    return { result: null, page: null, error: e instanceof Error ? e.message : String(e) };
  }
  if (result.status !== 'completed') {
    return { result, page: null, error: `incomplete:${result.incompleteReason ?? 'unknown'}` };
  }
  const page = parseConceptPage(finalText(result));
  return { result, page, error: page ? null : 'invalid_output' };
}
