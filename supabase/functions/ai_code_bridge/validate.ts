import type { AiUsage } from '../_shared/ai/types.ts';

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const WORKER_ID_RE = /^[A-Za-z0-9._-]{1,64}$/;

export const LEASE_SECONDS = 120;
export const MAX_RESULT_TEXT = 200_000;
export const MAX_PROMPT = 60_000;
export const MAX_RESULT_JSON = 100_000;
/** 수정 모드 diff(result.diff). 넘으면 작업자가 올리기 전에 실패 처리한다. */
export const MAX_DIFF = 400_000;
export const MAX_APPLY_RESULT_JSON = 20_000;
export const MAX_ERROR = 2000;
export const FAIL_CODES = new Set(['startup', 'run_error', 'timeout', 'cancelled', 'parse', 'lost', 'internal']);

export type Parsed<T> = { ok: true; value: T } | { ok: false; error: string };

export interface RoundUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  reasoningTokens: number;
}

export interface RoundPayload {
  prompt: string | null;
  prompt_version: string | null;
  result_text: string | null;
  result: Record<string, unknown> | null;
  parse_ok: boolean;
  cursor_run_id: string | null;
  cursor_agent_id: string | null;
  model: string | null;
  duration_ms: number | null;
  usage: RoundUsage | null;
  tool_calls: { name: string; count: number }[];
  repo_state: { head: string | null; branch: string | null; dirty_files: number | null } | null;
}

export function uuidOrNull(v: unknown): string | null {
  return typeof v === 'string' && UUID_RE.test(v.trim()) ? v.trim() : null;
}

export function workerIdOrNull(v: unknown): string | null {
  return typeof v === 'string' && WORKER_ID_RE.test(v) ? v : null;
}

function shortString(v: unknown, max: number): string | null {
  if (typeof v !== 'string') return null;
  const s = v.trim();
  return s ? s.slice(0, max) : null;
}

function count(v: unknown, max: number): number | null {
  if (typeof v !== 'number' || !Number.isFinite(v) || v < 0) return null;
  return Math.min(Math.round(v), max);
}

/** 작업자 정보는 알려진 짧은 문자열만 남긴다. */
export function parseInfo(raw: unknown): Record<string, string> {
  const src = raw && typeof raw === 'object' ? (raw as Record<string, unknown>) : {};
  const out: Record<string, string> = {};
  for (const key of ['version', 'model', 'sdk', 'node', 'repo']) {
    const v = shortString(src[key], 100);
    if (v) out[key] = v;
  }
  return out;
}

function parseUsage(raw: unknown): RoundUsage | null {
  if (!raw || typeof raw !== 'object') return null;
  const u = raw as Record<string, unknown>;
  const n = (k: string) => count(u[k], 1_000_000_000) ?? 0;
  return {
    inputTokens: n('inputTokens'),
    outputTokens: n('outputTokens'),
    cacheReadTokens: n('cacheReadTokens'),
    cacheWriteTokens: n('cacheWriteTokens'),
    reasoningTokens: n('reasoningTokens'),
  };
}

export function parseRound(raw: unknown): Parsed<RoundPayload> {
  const src = raw == null ? {} : raw;
  if (typeof src !== 'object' || Array.isArray(src)) return { ok: false, error: 'round_invalid' };
  const r = src as Record<string, unknown>;

  const resultText = typeof r.result_text === 'string' ? r.result_text : null;
  if (resultText && resultText.length > MAX_RESULT_TEXT) return { ok: false, error: 'result_text_too_long' };
  const prompt = typeof r.prompt === 'string' ? r.prompt : null;
  if (prompt && prompt.length > MAX_PROMPT) return { ok: false, error: 'prompt_too_long' };

  let result: Record<string, unknown> | null = null;
  if (r.result != null) {
    if (typeof r.result !== 'object' || Array.isArray(r.result)) return { ok: false, error: 'result_invalid' };
    const { diff, ...rest } = r.result as Record<string, unknown>;
    if (diff != null && (typeof diff !== 'string' || diff.length > MAX_DIFF)) return { ok: false, error: 'diff_too_large' };
    if (JSON.stringify(rest).length > MAX_RESULT_JSON) return { ok: false, error: 'result_too_large' };
    result = r.result as Record<string, unknown>;
  }

  const toolCalls: { name: string; count: number }[] = [];
  if (r.tool_calls != null) {
    if (!Array.isArray(r.tool_calls) || r.tool_calls.length > 50) return { ok: false, error: 'tool_calls_invalid' };
    for (const item of r.tool_calls) {
      const t = item && typeof item === 'object' ? (item as Record<string, unknown>) : {};
      const name = shortString(t.name, 60);
      const c = count(t.count, 100_000);
      if (!name || c == null) return { ok: false, error: 'tool_calls_invalid' };
      toolCalls.push({ name, count: c });
    }
  }

  let repoState: RoundPayload['repo_state'] = null;
  if (r.repo_state && typeof r.repo_state === 'object') {
    const s = r.repo_state as Record<string, unknown>;
    repoState = {
      head: shortString(s.head, 64),
      branch: shortString(s.branch, 200),
      dirty_files: count(s.dirty_files, 1_000_000),
    };
  }

  return {
    ok: true,
    value: {
      prompt,
      prompt_version: shortString(r.prompt_version, 40),
      result_text: resultText,
      result,
      parse_ok: r.parse_ok === true,
      cursor_run_id: shortString(r.cursor_run_id, 200),
      cursor_agent_id: shortString(r.cursor_agent_id, 200),
      model: shortString(r.model, 100),
      duration_ms: count(r.duration_ms, 3_600_000),
      usage: parseUsage(r.usage),
      tool_calls: toolCalls,
      repo_state: repoState,
    },
  };
}

/** 적용·되돌리기 결과. 파일 목록·충돌·오류 같은 작은 객체만 받는다. */
export function parseApplyResult(raw: unknown): Parsed<Record<string, unknown>> {
  if (raw == null) return { ok: true, value: {} };
  if (typeof raw !== 'object' || Array.isArray(raw)) return { ok: false, error: 'result_invalid' };
  if (JSON.stringify(raw).length > MAX_APPLY_RESULT_JSON) return { ok: false, error: 'result_too_large' };
  return { ok: true, value: raw as Record<string, unknown> };
}

/** Cursor 토큰 수를 ai_runs 형식으로. 캐시 읽기 = 캐시된 입력. */
export function toAiUsage(u: RoundUsage | null): AiUsage {
  return {
    inputTokens: u?.inputTokens ?? 0,
    cachedInputTokens: u?.cacheReadTokens ?? 0,
    cacheWriteTokens: u?.cacheWriteTokens ?? 0,
    outputTokens: u?.outputTokens ?? 0,
    reasoningTokens: u?.reasoningTokens ?? 0,
  };
}

/** 길이가 같은 문자열을 끝까지 비교한다(토큰 해시 비교용). */
export function sameText(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
