import type { Db } from './db.ts';
import type { AiUsage } from './types.ts';

export interface AiRunRecord {
  feature: string;
  provider: string;
  model: string;
  promptVersion?: string | null;
  status: 'ok' | 'error' | 'stopped';
  error?: string | null;
  usage: AiUsage;
  webSearchCalls?: number;
  toolCalls?: number;
  costUsd: number | null;
  latencyMs?: number | null;
  conversationId?: string | null;
  academyId?: string | null;
  createdBy?: string | null;
}

export function aiRunRow(rec: AiRunRecord): Record<string, unknown> {
  return {
    feature: rec.feature,
    provider: rec.provider,
    model: rec.model,
    prompt_version: rec.promptVersion ?? null,
    status: rec.status,
    error: rec.error ? rec.error.slice(0, 1000) : null,
    input_tokens: rec.usage.inputTokens,
    cached_input_tokens: rec.usage.cachedInputTokens,
    cache_write_tokens: rec.usage.cacheWriteTokens,
    output_tokens: rec.usage.outputTokens,
    reasoning_tokens: rec.usage.reasoningTokens,
    web_search_calls: rec.webSearchCalls ?? 0,
    tool_calls: rec.toolCalls ?? 0,
    cost_usd: rec.costUsd,
    latency_ms: rec.latencyMs ?? null,
    conversation_id: rec.conversationId ?? null,
    academy_id: rec.academyId ?? null,
    created_by: rec.createdBy ?? null,
  };
}

/** 호출 기록은 기능을 막지 않는다. 실패하면 로그만 남기고 null. */
export async function recordAiRun(admin: Db, rec: AiRunRecord): Promise<string | null> {
  try {
    const { data, error } = await admin.from('ai_runs').insert(aiRunRow(rec)).select('id').single();
    if (error) {
      console.error('[ai_runs] insert failed:', error.message);
      return null;
    }
    return (data?.id as string | undefined) ?? null;
  } catch (e) {
    console.error('[ai_runs] insert threw:', e instanceof Error ? e.message : String(e));
    return null;
  }
}
