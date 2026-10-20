// OpenAI 파이썬 실행 환경(Code Interpreter 컨테이너).
// 한 답변 동안만 쓴다. 끝나면 올린 파일(OpenAI Files)과 실행 환경을 지운다. 실행 환경은 20분 동안 쓰지 않으면 사라진다.

import {
  AiProviderError,
  type AiCodeSandbox,
  type AiFileCitation,
  type AiSandboxInputFile,
  type AiSandboxOutputFile,
  type AiSandboxSession,
} from './types.ts';

export interface OpenAiSandboxOptions {
  apiKey: string;
  baseUrl?: string;
  fetchImpl?: typeof fetch;
}

type Json = Record<string, unknown>;

const CLEANUP_TIMEOUT_MS = 8000;

function asObj(v: unknown): Json | null {
  return v && typeof v === 'object' && !Array.isArray(v) ? (v as Json) : null;
}

function asStr(v: unknown): string {
  return typeof v === 'string' ? v : '';
}

export function baseName(path: string): string {
  return path.split('/').filter(Boolean).pop() ?? '';
}

function extOf(name: string): string {
  const i = name.lastIndexOf('.');
  return i >= 0 ? name.slice(i).toLowerCase() : '';
}

class OpenAiApi {
  private readonly fetchImpl: typeof fetch;

  constructor(private readonly opts: OpenAiSandboxOptions) {
    this.fetchImpl = opts.fetchImpl ?? fetch;
  }

  async call(path: string, init: RequestInit, signal?: AbortSignal): Promise<Response> {
    const res = await this.fetchImpl(`${this.opts.baseUrl ?? 'https://api.openai.com/v1'}${path}`, {
      ...init,
      headers: { ...(init.headers as Record<string, string> | undefined), Authorization: `Bearer ${this.opts.apiKey}` },
      signal,
    });
    if (!res.ok) {
      const text = await res.text().catch(() => '');
      let message = text.slice(0, 300);
      try {
        message = asStr(asObj(asObj(JSON.parse(text))?.error)?.message) || message;
      } catch {
        // 본문이 JSON이 아니면 앞부분만 남긴다.
      }
      throw new AiProviderError(`${init.method ?? 'GET'} ${path.split('?')[0]}: ${message || res.status}`, res.status, 'sandbox_error');
    }
    return res;
  }

  async remove(path: string): Promise<void> {
    try {
      const res = await this.call(path, { method: 'DELETE' }, AbortSignal.timeout(CLEANUP_TIMEOUT_MS));
      await res.body?.cancel();
    } catch (e) {
      if (e instanceof AiProviderError && e.status === 404) return;
      console.error('[ai sandbox] cleanup failed:', e instanceof Error ? e.message : String(e));
    }
  }
}

class OpenAiSandboxSession implements AiSandboxSession {
  private closed = false;

  constructor(
    private readonly api: OpenAiApi,
    readonly containerId: string,
    private readonly uploadedFileIds: string[],
  ) {}

  async collectOutputs(
    opts: { exts: string[]; limit: number; maxBytes: number; preferred: AiFileCitation[] },
    signal?: AbortSignal,
  ): Promise<AiSandboxOutputFile[]> {
    const res = await this.api.call(`/containers/${this.containerId}/files?limit=100&order=asc`, { method: 'GET' }, signal);
    const list = asObj(await res.json());
    const exts = new Set(opts.exts.map((e) => e.toLowerCase()));
    const candidates = (Array.isArray(list?.data) ? list.data : [])
      .map(asObj)
      .filter((f): f is Json => f != null && asStr(f.source) !== 'user')
      .map((f) => ({ id: asStr(f.id), name: baseName(asStr(f.path)), bytes: typeof f.bytes === 'number' ? f.bytes : null }))
      .filter((f) => f.id && f.name && exts.has(extOf(f.name)) && (f.bytes === null || f.bytes <= opts.maxBytes));
    const rank = new Map(opts.preferred.map((c, i) => [c.fileId, i]));
    candidates.sort((a, b) => (rank.get(a.id) ?? Infinity) - (rank.get(b.id) ?? Infinity));

    const out: AiSandboxOutputFile[] = [];
    for (const f of candidates) {
      if (out.length >= opts.limit) break;
      const content = await this.api.call(`/containers/${this.containerId}/files/${f.id}/content`, { method: 'GET' }, signal);
      const bytes = new Uint8Array(await content.arrayBuffer());
      if (bytes.byteLength > opts.maxBytes) continue;
      out.push({ fileId: f.id, name: f.name, bytes });
    }
    return out;
  }

  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    await Promise.all([
      this.api.remove(`/containers/${this.containerId}`),
      ...this.uploadedFileIds.map((id) => this.api.remove(`/files/${id}`)),
    ]);
  }
}

export class OpenAiCodeSandbox implements AiCodeSandbox {
  private readonly api: OpenAiApi;

  constructor(opts: OpenAiSandboxOptions) {
    this.api = new OpenAiApi(opts);
  }

  async open(files: AiSandboxInputFile[], signal?: AbortSignal): Promise<AiSandboxSession> {
    const uploaded: string[] = [];
    try {
      for (const f of files) {
        const form = new FormData();
        form.append('purpose', 'user_data');
        form.append('file', new Blob([f.bytes as BlobPart], { type: f.mime }), f.name);
        const res = await this.api.call('/files', { method: 'POST', body: form }, signal);
        const id = asStr(asObj(await res.json())?.id);
        if (!id) throw new AiProviderError('file upload returned no id', undefined, 'sandbox_error');
        uploaded.push(id);
      }
      const res = await this.api.call(
        '/containers',
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ name: 'think-answer', memory_limit: '1g', file_ids: uploaded }),
        },
        signal,
      );
      const containerId = asStr(asObj(await res.json())?.id);
      if (!containerId) throw new AiProviderError('container create returned no id', undefined, 'sandbox_error');
      return new OpenAiSandboxSession(this.api, containerId, uploaded);
    } catch (e) {
      await Promise.all(uploaded.map((id) => this.api.remove(`/files/${id}`)));
      throw e;
    }
  }
}
