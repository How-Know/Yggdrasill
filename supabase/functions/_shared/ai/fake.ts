// 테스트와 로컬 확인용 가짜 AI. AI_PROVIDER=fake 이면 실제 API를 부르지 않는다.
// 테스트는 이 공급자가 돌려주는 문구가 아니라 흐름(도구 호출, 저장, 기록)을 검증한다.

import {
  AiProviderError,
  emptyUsage,
  type AiBackground,
  type AiBackgroundPoll,
  type AiCodeSandbox,
  type AiFileCitation,
  type AiFunctionCall,
  type AiSandboxInputFile,
  type AiSandboxSession,
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
  /** 파이썬 실행 횟수. 요청에 실행 환경이 없으면 무시한다. */
  codeRuns?: number;
  /** 답변이 가리키는 실행 환경 파일 id. */
  citedFileIds?: string[];
  /** 백그라운드 호출에서 끝났다고 알리기 전에 "아직 도는 중"으로 답할 횟수. */
  pendingPolls?: number;
  /** 공급자가 알린 종료. 없으면 completed. */
  status?: 'completed' | 'incomplete';
  /** status가 incomplete일 때 공급자가 준 사유. */
  incompleteReason?: string;
}

/** 테스트용 백그라운드 호출. 시작·취소·삭제 기록을 갖는다. */
export class FakeBackground implements AiBackground {
  readonly started: { id: string; req: AiRequest; metadata?: Record<string, string> }[] = [];
  readonly cancelled: string[] = [];
  readonly removed: string[] = [];
  private readonly jobs = new Map<string, { req: AiRequest; turn: FakeTurn; polls: number; cancelled: boolean }>();

  constructor(private readonly owner: FakeAiProvider) {}

  start(req: AiRequest, opts: { metadata?: Record<string, string> } = {}): Promise<{ id: string }> {
    const turn = this.owner.takeTurn(req);
    const id = `resp_fake_bg_${this.started.length + 1}`;
    this.started.push({ id, req, metadata: opts.metadata });
    this.jobs.set(id, { req, turn, polls: 0, cancelled: false });
    return Promise.resolve({ id });
  }

  poll(id: string): Promise<AiBackgroundPoll> {
    const job = this.jobs.get(id);
    if (!job || this.removed.includes(id)) return Promise.reject(new AiProviderError('not found', 404, 'not_found'));
    if (job.cancelled) return Promise.resolve({ state: 'failed', error: 'cancelled' });
    if (job.polls < (job.turn.pendingPolls ?? 0)) {
      job.polls += 1;
      return Promise.resolve({ state: 'running', status: 'in_progress' });
    }
    if (job.turn.error) return Promise.resolve({ state: 'failed', error: job.turn.error });
    return Promise.resolve({ state: 'done', result: this.owner.resultOf(job.req, job.turn) });
  }

  cancel(id: string): Promise<void> {
    const job = this.jobs.get(id);
    if (job) job.cancelled = true;
    this.cancelled.push(id);
    return Promise.resolve();
  }

  remove(id: string): Promise<void> {
    this.removed.push(id);
    return Promise.resolve();
  }
}

/** 테스트용 실행 환경. 열고 닫은 기록과 돌려줄 결과 파일을 갖는다. */
export class FakeCodeSandbox implements AiCodeSandbox {
  readonly opened: { containerId: string; files: AiSandboxInputFile[] }[] = [];
  readonly closed: string[] = [];
  readonly collected: { containerId: string; preferred: AiFileCitation[] }[] = [];

  constructor(
    private readonly opts: {
      outputs?: { fileId: string; name: string; bytes?: Uint8Array }[];
      openError?: string;
      collectError?: string;
    } = {},
  ) {}

  open(files: AiSandboxInputFile[]): Promise<AiSandboxSession> {
    if (this.opts.openError) return Promise.reject(new AiProviderError(this.opts.openError, 500, 'sandbox_error'));
    const containerId = `cntr_fake_${this.opened.length + 1}`;
    this.opened.push({ containerId, files });
    const outputs = this.opts.outputs ?? [];
    const collectError = this.opts.collectError;
    return Promise.resolve({
      containerId,
      collectOutputs: (o) => {
        this.collected.push({ containerId, preferred: o.preferred });
        if (collectError) return Promise.reject(new AiProviderError(collectError, 500, 'sandbox_error'));
        const exts = new Set(o.exts);
        return Promise.resolve(
          outputs
            .filter((f) => exts.has(f.name.slice(f.name.lastIndexOf('.')).toLowerCase()))
            .slice(0, o.limit)
            .map((f) => ({ fileId: f.fileId, name: f.name, bytes: f.bytes ?? new TextEncoder().encode(f.name) })),
        );
      },
      close: () => {
        this.closed.push(containerId);
        return Promise.resolve();
      },
    });
  }
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

  readonly sandbox?: FakeCodeSandbox;
  readonly background: FakeBackground;

  constructor(private readonly script?: FakeScript, opts: { sandbox?: FakeCodeSandbox } = {}) {
    this.sandbox = opts.sandbox;
    this.background = new FakeBackground(this);
  }

  /** FakeBackground 가 쓰는 다음 차례와 그 결과. */
  takeTurn(req: AiRequest): FakeTurn {
    return this.nextTurn(req);
  }

  resultOf(req: AiRequest, turn: FakeTurn): AiResult {
    return this.toResult(req, turn);
  }

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
    const containerId = req.codeInterpreter?.containerId;
    const codeRuns = containerId ? turn.codeRuns ?? 0 : 0;
    for (let i = 0; i < codeRuns; i++) {
      items.push({ type: 'code_interpreter_call', id: this.id('ci'), status: 'completed', container_id: containerId });
    }
    const files: AiFileCitation[] = containerId
      ? (turn.citedFileIds ?? []).map((fileId) => ({ containerId, fileId, filename: `${fileId}.xlsx` }))
      : [];
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
      messages.push({ itemId, phase: 'final', text, sources: turn.sources ?? [], ...(files.length > 0 ? { files } : {}) });
      items.push({ type: 'message', id: itemId, role: 'assistant', phase: 'final_answer', content: [{ type: 'output_text', text }] });
    }

    return {
      provider: this.name,
      model: req.model,
      status: turn.status ?? 'completed',
      ...(turn.incompleteReason ? { incompleteReason: turn.incompleteReason } : {}),
      messages,
      functionCalls,
      webSearchCalls: turn.webSearchQueries?.length ?? 0,
      webSearchQueries: turn.webSearchQueries ?? [],
      codeRuns,
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
    for (let i = 0; i < (result.codeRuns ?? 0); i++) {
      const itemId = this.id('ci');
      yield { type: 'code_run', itemId, status: 'running' };
      yield { type: 'code_run', itemId, status: 'completed' };
    }
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
