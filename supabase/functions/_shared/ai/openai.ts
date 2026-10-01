// OpenAI Responses API (POST /v1/responses) 공급자.
// - store:false 로 호출한다. 같은 턴의 도구 반복에서는 출력 항목(암호화된 추론 포함)을 그대로 되돌려 보낸다.
// - 지난 턴의 답변은 phase:"final_answer" 로 다시 넣는다.

import { readSse } from './sse.ts';
import {
  AiProviderError,
  emptyUsage,
  type AiContentPart,
  type AiFunctionCall,
  type AiInputItem,
  type AiMessageOut,
  type AiPhase,
  type AiProvider,
  type AiRequest,
  type AiResult,
  type AiSource,
  type AiStreamEvent,
  type AiUsage,
} from './types.ts';

export interface OpenAiProviderOptions {
  apiKey: string;
  baseUrl?: string;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
}

type Json = Record<string, unknown>;

function asObj(v: unknown): Json | null {
  return v && typeof v === 'object' && !Array.isArray(v) ? (v as Json) : null;
}

function asNum(v: unknown): number {
  const n = typeof v === 'number' ? v : Number(v);
  return Number.isFinite(n) ? n : 0;
}

function asStr(v: unknown): string {
  return typeof v === 'string' ? v : '';
}

function toOpenAiContent(parts: AiContentPart[]): unknown[] {
  return parts.map((p) => {
    if (p.type === 'text') return { type: 'input_text', text: p.text };
    if (p.type === 'image') return { type: 'input_image', image_url: p.url, detail: p.detail ?? 'auto' };
    return { type: 'input_file', file_url: p.url, filename: p.filename };
  });
}

export function toOpenAiInput(items: AiInputItem[]): unknown[] {
  const out: unknown[] = [];
  for (const it of items) {
    if (it.kind === 'message') {
      if (it.role === 'assistant') {
        const text = it.parts
          .filter((p): p is { type: 'text'; text: string } => p.type === 'text')
          .map((p) => p.text)
          .join('\n\n');
        out.push({ type: 'message', role: 'assistant', phase: 'final_answer', content: text });
      } else {
        out.push({ type: 'message', role: 'user', content: toOpenAiContent(it.parts) });
      }
    } else if (it.kind === 'context') {
      out.push({ type: 'message', role: 'developer', content: it.text });
    } else if (it.kind === 'provider_items') {
      out.push(...it.items);
    } else {
      out.push({ type: 'function_call_output', call_id: it.callId, output: it.output });
    }
  }
  return out;
}

export function buildResponsesBody(req: AiRequest, stream: boolean): Json {
  const body: Json = {
    model: req.model,
    input: toOpenAiInput(req.input),
    store: false,
    stream,
  };
  if (req.instructions) body.instructions = req.instructions;

  const tools: unknown[] = (req.tools ?? []).map((t) => ({
    type: 'function',
    name: t.name,
    description: t.description,
    parameters: t.parameters,
    strict: true,
  }));
  if (req.webSearch) {
    tools.push({ type: 'web_search', search_context_size: req.webSearch.contextSize ?? 'medium' });
    body.include = ['web_search_call.action.sources'];
  }
  if (tools.length > 0) {
    body.tools = tools;
    if (req.toolChoice) body.tool_choice = req.toolChoice;
  }
  if (req.jsonSchema) {
    body.text = {
      format: { type: 'json_schema', name: req.jsonSchema.name, schema: req.jsonSchema.schema, strict: true },
    };
  }
  if (req.reasoningEffort) body.reasoning = { effort: req.reasoningEffort };
  if (req.maxOutputTokens) body.max_output_tokens = req.maxOutputTokens;
  if (req.cacheKey) body.prompt_cache_key = req.cacheKey;
  if (req.safetyId) body.safety_identifier = req.safetyId;
  return body;
}

function phaseOf(item: Json): AiPhase {
  return item.phase === 'commentary' ? 'commentary' : 'final';
}

function parseMessage(item: Json): AiMessageOut {
  const content = Array.isArray(item.content) ? item.content : [];
  const texts: string[] = [];
  const sources: AiSource[] = [];
  for (const raw of content) {
    const part = asObj(raw);
    if (!part) continue;
    if (part.type === 'output_text') {
      texts.push(asStr(part.text));
      const annotations = Array.isArray(part.annotations) ? part.annotations : [];
      for (const a of annotations) {
        const ann = asObj(a);
        if (ann?.type === 'url_citation' && asStr(ann.url)) {
          sources.push({ url: asStr(ann.url), title: asStr(ann.title) || undefined });
        }
      }
    } else if (part.type === 'refusal') {
      texts.push(asStr(part.refusal));
    }
  }
  return { itemId: asStr(item.id), phase: phaseOf(item), text: texts.join(''), sources };
}

export function parseUsage(raw: unknown): AiUsage {
  const u = asObj(raw);
  if (!u) return emptyUsage();
  const inDetails = asObj(u.input_tokens_details);
  const outDetails = asObj(u.output_tokens_details);
  return {
    inputTokens: asNum(u.input_tokens),
    cachedInputTokens: asNum(inDetails?.cached_tokens),
    cacheWriteTokens: asNum(inDetails?.cache_write_tokens),
    outputTokens: asNum(u.output_tokens),
    reasoningTokens: asNum(outDetails?.reasoning_tokens),
  };
}

export function parseResponse(raw: unknown, provider: string): AiResult {
  const resp = asObj(raw) ?? {};
  const output = Array.isArray(resp.output) ? resp.output : [];
  const messages: AiMessageOut[] = [];
  const functionCalls: AiFunctionCall[] = [];
  const webSearchQueries: string[] = [];
  let webSearchCalls = 0;

  for (const rawItem of output) {
    const item = asObj(rawItem);
    if (!item) continue;
    if (item.type === 'message') {
      messages.push(parseMessage(item));
    } else if (item.type === 'function_call') {
      functionCalls.push({ callId: asStr(item.call_id), name: asStr(item.name), arguments: asStr(item.arguments) });
    } else if (item.type === 'web_search_call') {
      webSearchCalls += 1;
      const action = asObj(item.action);
      const query = asStr(action?.query);
      if (query) webSearchQueries.push(query);
    }
  }

  const incomplete = asObj(resp.incomplete_details);
  return {
    provider,
    model: asStr(resp.model),
    status: resp.status === 'incomplete' ? 'incomplete' : 'completed',
    incompleteReason: asStr(incomplete?.reason) || undefined,
    messages,
    functionCalls,
    webSearchCalls,
    webSearchQueries,
    usage: parseUsage(resp.usage),
    replay: { kind: 'provider_items', provider, items: output },
  };
}

function errorFromBody(status: number, text: string): AiProviderError {
  let message = text.slice(0, 500);
  let code: string | undefined;
  try {
    const parsed = asObj(JSON.parse(text));
    const err = asObj(parsed?.error);
    if (err) {
      message = asStr(err.message) || message;
      code = asStr(err.code) || asStr(err.type) || undefined;
    }
  } catch {
    // 본문이 JSON이 아니면 앞부분만 남긴다.
  }
  return new AiProviderError(message || `OpenAI HTTP ${status}`, status, code);
}

export class OpenAiResponsesProvider implements AiProvider {
  readonly name = 'openai';
  private readonly fetchImpl: typeof fetch;

  constructor(private readonly opts: OpenAiProviderOptions) {
    this.fetchImpl = opts.fetchImpl ?? fetch;
  }

  private async post(req: AiRequest, stream: boolean, signal?: AbortSignal): Promise<Response> {
    const signals: AbortSignal[] = [];
    if (signal) signals.push(signal);
    if (this.opts.timeoutMs) signals.push(AbortSignal.timeout(this.opts.timeoutMs));
    const combined = signals.length > 1 ? AbortSignal.any(signals) : signals[0];

    const res = await this.fetchImpl(`${this.opts.baseUrl ?? 'https://api.openai.com/v1'}/responses`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${this.opts.apiKey}`,
      },
      body: JSON.stringify(buildResponsesBody(req, stream)),
      signal: combined,
    });
    if (!res.ok) throw errorFromBody(res.status, await res.text());
    return res;
  }

  async complete(req: AiRequest, signal?: AbortSignal): Promise<AiResult> {
    const res = await this.post(req, false, signal);
    const json = await res.json();
    const obj = asObj(json);
    if (obj?.status === 'failed') {
      const err = asObj(obj.error);
      throw new AiProviderError(asStr(err?.message) || 'response failed', undefined, asStr(err?.code) || undefined);
    }
    return parseResponse(json, this.name);
  }

  async *stream(req: AiRequest, signal?: AbortSignal): AsyncGenerator<AiStreamEvent> {
    const res = await this.post(req, true, signal);
    if (!res.body) throw new AiProviderError('empty stream body');

    for await (const msg of readSse(res.body)) {
      if (msg.data === '[DONE]') break;
      let ev: Json | null = null;
      try {
        ev = asObj(JSON.parse(msg.data));
      } catch {
        continue;
      }
      if (!ev) continue;
      const type = asStr(ev.type) || msg.event || '';

      switch (type) {
        case 'response.output_item.added': {
          const item = asObj(ev.item);
          if (item?.type === 'message') {
            yield { type: 'message_start', itemId: asStr(item.id), phase: phaseOf(item) };
          } else if (item?.type === 'function_call') {
            yield { type: 'function_call_start', callId: asStr(item.call_id), name: asStr(item.name) };
          } else if (item?.type === 'web_search_call') {
            yield { type: 'web_search', itemId: asStr(item.id), status: 'searching' };
          }
          break;
        }
        case 'response.output_text.delta': {
          const delta = asStr(ev.delta);
          if (delta) yield { type: 'text_delta', itemId: asStr(ev.item_id), delta };
          break;
        }
        case 'response.output_item.done': {
          const item = asObj(ev.item);
          if (item?.type === 'message') {
            const m = parseMessage(item);
            yield { type: 'message_done', itemId: m.itemId, phase: m.phase, text: m.text };
          } else if (item?.type === 'web_search_call') {
            const action = asObj(item.action);
            yield {
              type: 'web_search',
              itemId: asStr(item.id),
              status: 'completed',
              query: asStr(action?.query) || undefined,
            };
          }
          break;
        }
        case 'response.completed':
        case 'response.incomplete': {
          yield { type: 'completed', result: parseResponse(ev.response, this.name) };
          return;
        }
        case 'response.failed': {
          const resp = asObj(ev.response);
          const err = asObj(resp?.error);
          throw new AiProviderError(asStr(err?.message) || 'response failed', undefined, asStr(err?.code) || undefined);
        }
        case 'error': {
          const err = asObj(ev.error) ?? ev;
          throw new AiProviderError(asStr(err.message) || 'stream error', undefined, asStr(err.code) || undefined);
        }
      }
    }
    throw new AiProviderError('stream ended before completion');
  }
}
