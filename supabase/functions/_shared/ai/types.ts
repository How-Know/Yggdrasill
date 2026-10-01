// 공급자(OpenAI 등)와 무관한 AI 호출 타입. 기능 코드는 이 타입만 사용한다.

export type AiRole = 'user' | 'assistant';

export type AiContentPart =
  | { type: 'text'; text: string }
  | { type: 'image'; url: string; detail?: 'low' | 'high' | 'auto' }
  | { type: 'file'; url: string; filename: string };

export type AiInputItem =
  | { kind: 'message'; role: AiRole; parts: AiContentPart[] }
  // 사용자 발화가 아닌 참고 자료(검색된 기억 등). 지시문보다 우선순위가 낮다.
  | { kind: 'context'; text: string }
  // 같은 턴 안에서 공급자에게 그대로 되돌려 줘야 하는 출력 항목(추론, 도구 호출 등)
  | { kind: 'provider_items'; provider: string; items: unknown[] }
  | { kind: 'tool_result'; callId: string; output: string };

export interface AiFunctionTool {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
}

export interface AiRequest {
  model: string;
  instructions?: string;
  input: AiInputItem[];
  tools?: AiFunctionTool[];
  webSearch?: { contextSize?: 'low' | 'medium' | 'high' };
  toolChoice?: 'auto' | 'none';
  jsonSchema?: { name: string; schema: Record<string, unknown> };
  reasoningEffort?: string;
  maxOutputTokens?: number;
  cacheKey?: string;
  safetyId?: string;
}

export interface AiUsage {
  inputTokens: number;
  cachedInputTokens: number;
  cacheWriteTokens: number;
  outputTokens: number;
  reasoningTokens: number;
}

export interface AiSource {
  url: string;
  title?: string;
}

export interface AiFunctionCall {
  callId: string;
  name: string;
  arguments: string;
}

export type AiPhase = 'commentary' | 'final';

export interface AiMessageOut {
  itemId: string;
  phase: AiPhase;
  text: string;
  sources: AiSource[];
}

export interface AiResult {
  provider: string;
  model: string;
  status: 'completed' | 'incomplete';
  incompleteReason?: string;
  messages: AiMessageOut[];
  functionCalls: AiFunctionCall[];
  webSearchCalls: number;
  webSearchQueries: string[];
  usage: AiUsage;
  replay: AiInputItem;
}

export type AiStreamEvent =
  | { type: 'message_start'; itemId: string; phase: AiPhase }
  | { type: 'text_delta'; itemId: string; delta: string }
  | { type: 'message_done'; itemId: string; phase: AiPhase; text: string }
  | { type: 'function_call_start'; callId: string; name: string }
  | { type: 'web_search'; itemId: string; status: 'searching' | 'completed'; query?: string }
  | { type: 'completed'; result: AiResult };

export interface AiProvider {
  readonly name: string;
  stream(req: AiRequest, signal?: AbortSignal): AsyncGenerator<AiStreamEvent>;
  complete(req: AiRequest, signal?: AbortSignal): Promise<AiResult>;
}

export class AiProviderError extends Error {
  constructor(
    message: string,
    readonly status?: number,
    readonly code?: string,
  ) {
    super(message);
    this.name = 'AiProviderError';
  }
}

export function emptyUsage(): AiUsage {
  return { inputTokens: 0, cachedInputTokens: 0, cacheWriteTokens: 0, outputTokens: 0, reasoningTokens: 0 };
}

export function addUsage(a: AiUsage, b: AiUsage): AiUsage {
  return {
    inputTokens: a.inputTokens + b.inputTokens,
    cachedInputTokens: a.cachedInputTokens + b.cachedInputTokens,
    cacheWriteTokens: a.cacheWriteTokens + b.cacheWriteTokens,
    outputTokens: a.outputTokens + b.outputTokens,
    reasoningTokens: a.reasoningTokens + b.reasoningTokens,
  };
}

export function finalText(result: AiResult): string {
  return result.messages
    .filter((m) => m.phase === 'final')
    .map((m) => m.text)
    .join('\n\n')
    .trim();
}

export function collectSources(result: AiResult): AiSource[] {
  const seen = new Set<string>();
  const out: AiSource[] = [];
  for (const m of result.messages) {
    for (const s of m.sources) {
      if (!s.url || seen.has(s.url)) continue;
      seen.add(s.url);
      out.push(s);
    }
  }
  return out;
}
