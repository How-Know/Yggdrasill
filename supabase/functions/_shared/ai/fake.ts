// 테스트와 로컬 확인용 가짜 AI. AI_PROVIDER=fake 이면 실제 API를 부르지 않는다.
// 테스트는 이 공급자가 돌려주는 문구가 아니라 흐름(도구 호출, 저장, 기록)을 검증한다.

import {
  AiProviderError,
  emptyUsage,
  type AiFunctionCall,
  type AiMessageOut,
  type AiProvider,
  type AiRequest,
  type AiResult,
  type AiSource,
  type AiStreamEvent,
  type AiUsage,
} from './types.ts';

export interface FakeTurn {
  text?: string;
  commentary?: string;
  functionCalls?: { name: string; arguments: Record<string, unknown> }[];
  webSearchQueries?: string[];
  sources?: AiSource[];
  usage?: Partial<AiUsage>;
  error?: string;
  delayMs?: number;
}

export type FakeScript = FakeTurn[] | ((req: AiRequest, index: number) => FakeTurn);

type Json = Record<string, unknown>;

export function sampleFromSchema(schema: unknown): unknown {
  const s = schema && typeof schema === 'object' ? (schema as Json) : null;
  if (!s) return null;
  if (Array.isArray(s.enum) && s.enum.length > 0) return s.enum[0];
  const type = Array.isArray(s.type) ? s.type.find((t) => t !== 'null') : s.type;
  switch (type) {
    case 'object': {
      const props = s.properties && typeof s.properties === 'object' ? (s.properties as Json) : {};
      const out: Json = {};
      for (const [key, value] of Object.entries(props)) out[key] = sampleFromSchema(value);
      return out;
    }
    case 'array':
      return [];
    case 'string':
      return '가짜 값';
    case 'number':
    case 'integer':
      return 0;
    case 'boolean':
      return false;
    default:
      return null;
  }
}

function lastUserText(req: AiRequest): string {
  for (let i = req.input.length - 1; i >= 0; i--) {
    const it = req.input[i];
    if (it.kind === 'message' && it.role === 'user') {
      return it.parts
        .filter((p): p is { type: 'text'; text: string } => p.type === 'text')
        .map((p) => p.text)
        .join(' ');
    }
  }
  return '';
}

function defaultTurn(req: AiRequest): FakeTurn {
  if (req.jsonSchema) return { text: JSON.stringify(sampleFromSchema(req.jsonSchema.schema)) };
  return { text: `가짜 응답입니다. 받은 내용: ${lastUserText(req).slice(0, 80)}` };
}

function chunk(text: string, size: number): string[] {
  const chars = Array.from(text);
  const out: string[] = [];
  for (let i = 0; i < chars.length; i += size) out.push(chars.slice(i, i + size).join(''));
  return out;
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

export class FakeAiProvider implements AiProvider {
  readonly name = 'fake';
  readonly requests: AiRequest[] = [];
  private index = 0;
  private seq = 0;

  constructor(private readonly script?: FakeScript) {}

  private id(prefix: string): string {
    this.seq += 1;
    return `${prefix}_fake_${this.seq}`;
  }

  private nextTurn(req: AiRequest): FakeTurn {
    const i = this.index++;
    this.requests.push(req);
    if (!this.script) return defaultTurn(req);
    if (typeof this.script === 'function') return this.script(req, i);
    return this.script[Math.min(i, this.script.length - 1)] ?? defaultTurn(req);
  }

  private toResult(req: AiRequest, turn: FakeTurn): AiResult {
    if (turn.error) throw new AiProviderError(turn.error, 500, 'fake_error');
    const messages: AiMessageOut[] = [];
    const items: unknown[] = [];

    if (turn.commentary) {
      const itemId = this.id('msg');
      messages.push({ itemId, phase: 'commentary', text: turn.commentary, sources: [] });
      items.push({ type: 'message', id: itemId, role: 'assistant', phase: 'commentary', content: [{ type: 'output_text', text: turn.commentary }] });
    }
    for (const query of turn.webSearchQueries ?? []) {
      items.push({ type: 'web_search_call', id: this.id('ws'), status: 'completed', action: { type: 'search', query } });
    }
    const functionCalls: AiFunctionCall[] = (turn.functionCalls ?? []).map((fc) => {
      const callId = this.id('call');
      const args = JSON.stringify(fc.arguments);
      items.push({ type: 'function_call', id: this.id('fc'), call_id: callId, name: fc.name, arguments: args });
      return { callId, name: fc.name, arguments: args };
    });

    let text = turn.text;
    if (text === undefined && functionCalls.length === 0) text = defaultTurn(req).text;
    if (text !== undefined) {
      const itemId = this.id('msg');
      messages.push({ itemId, phase: 'final', text, sources: turn.sources ?? [] });
      items.push({ type: 'message', id: itemId, role: 'assistant', phase: 'final_answer', content: [{ type: 'output_text', text }] });
    }

    return {
      provider: this.name,
      model: req.model,
      status: 'completed',
      messages,
      functionCalls,
      webSearchCalls: turn.webSearchQueries?.length ?? 0,
      webSearchQueries: turn.webSearchQueries ?? [],
      usage: { ...emptyUsage(), inputTokens: 1000, outputTokens: 200, ...turn.usage },
      replay: { kind: 'provider_items', provider: this.name, items },
    };
  }

  async complete(req: AiRequest, signal?: AbortSignal): Promise<AiResult> {
    const turn = this.nextTurn(req);
    if (turn.delayMs) await sleep(turn.delayMs);
    if (signal?.aborted) throw new DOMException('aborted', 'AbortError');
    return this.toResult(req, turn);
  }

  async *stream(req: AiRequest, signal?: AbortSignal): AsyncGenerator<AiStreamEvent> {
    const turn = this.nextTurn(req);
    const result = this.toResult(req, turn);
    for (const m of result.messages) {
      yield { type: 'message_start', itemId: m.itemId, phase: m.phase };
      for (const piece of chunk(m.text, 6)) {
        if (turn.delayMs) await sleep(turn.delayMs);
        if (signal?.aborted) throw new DOMException('aborted', 'AbortError');
        yield { type: 'text_delta', itemId: m.itemId, delta: piece };
      }
      yield { type: 'message_done', itemId: m.itemId, phase: m.phase, text: m.text };
    }
    for (const query of result.webSearchQueries) {
      yield { type: 'web_search', itemId: this.id('ws'), status: 'completed', query };
    }
    for (const fc of result.functionCalls) {
      yield { type: 'function_call_start', callId: fc.callId, name: fc.name };
    }
    yield { type: 'completed', result };
  }
}
