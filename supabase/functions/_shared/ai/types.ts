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
  // images: 도구가 읽은 이미지. 결과 글과 함께 모델 입력에 들어간다.
  | { kind: 'tool_result'; callId: string; output: string; images?: AiToolImage[] };

export interface AiToolImage {
  /** data URL(base64) 또는 공급자가 받을 수 있는 주소 */
  url: string;
  detail?: 'low' | 'high' | 'auto';
}

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
  /** 파이썬 실행 도구. sandbox.open으로 연 실행 환경 id를 넘긴다. */
  codeInterpreter?: { containerId: string };
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
  /** 파이썬 실행 도구가 만든 파일 중 답변이 가리킨 것. */
  files?: AiFileCitation[];
}

export interface AiFileCitation {
  containerId: string;
  fileId: string;
  filename: string;
}

export interface AiSandboxInputFile {
  name: string;
  mime: string;
  bytes: Uint8Array;
}

export interface AiSandboxOutputFile {
  fileId: string;
  name: string;
  bytes: Uint8Array;
}

/** 한 답변 동안 쓰는 파이썬 실행 환경. close는 올린 파일과 실행 환경을 공급자 쪽에서 지운다. */
export interface AiSandboxSession {
  readonly containerId: string;
  /** 실행 환경이 만든 파일(올린 파일 제외)을 내려받는다. 이름 확장자가 exts에 있는 것만, 최대 limit개. */
  collectOutputs(
    opts: { exts: string[]; limit: number; maxBytes: number; preferred: AiFileCitation[] },
    signal?: AbortSignal,
  ): Promise<AiSandboxOutputFile[]>;
  close(): Promise<void>;
}

export interface AiCodeSandbox {
  open(files: AiSandboxInputFile[], signal?: AbortSignal): Promise<AiSandboxSession>;
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
  /** 파이썬 실행 횟수. */
  codeRuns?: number;
  usage: AiUsage;
  replay: AiInputItem;
}

export type AiStreamEvent =
  | { type: 'message_start'; itemId: string; phase: AiPhase }
  | { type: 'text_delta'; itemId: string; delta: string }
  | { type: 'message_done'; itemId: string; phase: AiPhase; text: string }
  | { type: 'function_call_start'; callId: string; name: string }
  | { type: 'web_search'; itemId: string; status: 'searching' | 'completed'; query?: string }
  | { type: 'code_run'; itemId: string; status: 'running' | 'completed' | 'failed' }
  | { type: 'completed'; result: AiResult };

export type AiBackgroundPoll =
  | { state: 'running'; status: string }
  /** completed·incomplete 둘 다. 판정은 result.status 로 한다. */
  | { state: 'done'; result: AiResult }
  | { state: 'failed'; error: string };

/**
 * 함수 실행 시간 한도를 넘는 긴 호출. 공급자 쪽에서 돌리고 id로 결과를 받는다.
 * 결과를 받기 전까지는 공급자 쪽에 요청·응답이 남으므로, 받은 뒤 remove 로 지운다.
 */
export interface AiBackground {
  start(req: AiRequest, opts?: { metadata?: Record<string, string> }): Promise<{ id: string }>;
  poll(id: string): Promise<AiBackgroundPoll>;
  cancel(id: string): Promise<void>;
  remove(id: string): Promise<void>;
}

export interface AiProvider {
  readonly name: string;
  /** 파이썬 실행 환경을 지원하는 공급자만 채운다. */
  readonly sandbox?: AiCodeSandbox;
  /** 백그라운드 호출을 지원하는 공급자만 채운다. */
  readonly background?: AiBackground;
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
