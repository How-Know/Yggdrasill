// OpenAI Responses API (POST /v1/responses) 공급자.
// - store:false 로 호출한다(백그라운드 호출만 store:true, 결과를 받은 뒤 지운다).
//   같은 턴의 도구 반복에서는 출력 항목(암호화된 추론 포함)을 그대로 되돌려 보낸다.
// - 지난 턴의 답변은 phase:"final_answer" 로 다시 넣는다.

import { OpenAiCodeSandbox } from './openai_sandbox.ts';
import { readSse } from './sse.ts';
import {
  AiProviderError,
  emptyUsage,
  type AiBackground,
  type AiBackgroundPoll,
  type AiCodeSandbox,
  type AiContentPart,
  type AiFileCitation,
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
  if (req.codeInterpreter) {
    tools.push({ type: 'code_interpreter', container: req.codeInterpreter.containerId });
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
  const files: AiFileCitation[] = [];
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
        } else if (ann?.type === 'container_file_citation' && asStr(ann.file_id) && asStr(ann.container_id)) {
          files.push({ containerId: asStr(ann.container_id), fileId: asStr(ann.file_id), filename: asStr(ann.filename) });
        }
      }
    } else if (part.type === 'refusal') {
      texts.push(asStr(part.refusal));
    }
  }
  return { itemId: asStr(item.id), phase: phaseOf(item), text: texts.join(''), sources, ...(files.length > 0 ? { files } : {}) };
}

function codeRunStatus(item: Json): 'running' | 'completed' | 'failed' {
  const s = asStr(item.status);
  return s === 'completed' ? 'completed' : s === 'failed' || s === 'incomplete' ? 'failed' : 'running';
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
  let codeRuns = 0;

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
    } else if (item.type === 'code_interpreter_call') {
      codeRuns += 1;
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
    codeRuns,
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
  readonly sandbox: AiCodeSandbox;
  readonly background: AiBackground;
  private readonly fetchImpl: typeof fetch;

  constructor(private readonly opts: OpenAiProviderOptions) {
    this.fetchImpl = opts.fetchImpl ?? fetch;
    this.sandbox = new OpenAiCodeSandbox({ apiKey: opts.apiKey, baseUrl: opts.baseUrl, fetchImpl: this.fetchImpl });
    this.background = new OpenAiBackground(opts, this.fetchImpl, this.name);
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
          } else if (item?.type === 'code_interpreter_call') {
            yield { type: 'code_run', itemId: asStr(item.id), status: 'running' };
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
          } else if (item?.type === 'code_interpreter_call') {
            const status = codeRunStatus(item);
            yield { type: 'code_run', itemId: asStr(item.id), status: status === 'running' ? 'completed' : status };
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

const BACKGROUND_CALL_TIMEOUT_MS = 20_000;

export function buildBackgroundBody(req: AiRequest, metadata?: Record<string, string>): Json {
  const body = buildResponsesBody(req, false);
  body.background = true;
  body.store = true;
  if (metadata && Object.keys(metadata).length > 0) body.metadata = metadata;
  return body;
}

export function backgroundPollOf(raw: unknown, provider: string): AiBackgroundPoll {
  const resp = asObj(raw) ?? {};
  const status = asStr(resp.status);
  if (status === 'queued' || status === 'in_progress') return { state: 'running', status };
  if (status === 'completed' || status === 'incomplete') return { state: 'done', result: parseResponse(resp, provider) };
  if (status === 'cancelled') return { state: 'failed', error: 'cancelled' };
  const err = asObj(resp.error);
  return { state: 'failed', error: asStr(err?.message) || asStr(err?.code) || `response ${status || 'failed'}` };
}

/** OpenAI 백그라운드 모드(background:true). 응답을 OpenAI에 저장해야 해서 store:true 로 부르고, 결과를 받으면 지운다. */
export class OpenAiBackground implements AiBackground {
  constructor(
    private readonly opts: OpenAiProviderOptions,
    private readonly fetchImpl: typeof fetch,
    private readonly provider: string,
  ) {}

  private async call(path: string, init: RequestInit): Promise<Response> {
    const res = await this.fetchImpl(`${this.opts.baseUrl ?? 'https://api.openai.com/v1'}${path}`, {
      ...init,
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${this.opts.apiKey}` },
      signal: AbortSignal.timeout(BACKGROUND_CALL_TIMEOUT_MS),
    });
    if (!res.ok) throw errorFromBody(res.status, await res.text());
    return res;
  }

  async start(req: AiRequest, opts: { metadata?: Record<string, string> } = {}): Promise<{ id: string }> {
    const res = await this.call('/responses', { method: 'POST', body: JSON.stringify(buildBackgroundBody(req, opts.metadata)) });
    const id = asStr(asObj(await res.json())?.id);
    if (!id) throw new AiProviderError('background response without id');
    return { id };
  }

  async poll(id: string): Promise<AiBackgroundPoll> {
    const res = await this.call(`/responses/${encodeURIComponent(id)}`, { method: 'GET' });
    return backgroundPollOf(await res.json(), this.provider);
  }

  async cancel(id: string): Promise<void> {
    const res = await this.call(`/responses/${encodeURIComponent(id)}/cancel`, { method: 'POST' });
    await res.body?.cancel();
  }

  async remove(id: string): Promise<void> {
    const res = await this.call(`/responses/${encodeURIComponent(id)}`, { method: 'DELETE' });
    await res.body?.cancel();
  }
}
