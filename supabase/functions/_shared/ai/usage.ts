import type { Db } from './db.ts';
import type { AiUsage } from './types.ts';

export interface AiRunRecord {
  feature: string;
  provider: string;
  model: string;
  promptVersion?: string | null;
  roleProfileVersion?: string | null;
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
  /** 이 호출에서 서버가 계산한 기능 상태(ai_runs.features). 없으면 열을 보내지 않는다. */
  features?: Record<string, unknown> | null;
}

export function aiRunRow(rec: AiRunRecord): Record<string, unknown> {
  const row: Record<string, unknown> = {
    feature: rec.feature,
    provider: rec.provider,
    model: rec.model,
    prompt_version: rec.promptVersion ?? null,
    role_profile_version: rec.roleProfileVersion ?? null,
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
  if (rec.features) row.features = rec.features;
  return row;
}

/** ai_runs.features 열이 아직 없는 DB(마이그레이션 전)에서 난 오류. */
function missingFeaturesColumn(error: { code?: string; message?: string }): boolean {
  return /features/.test(error.message ?? '') && (error.code === 'PGRST204' || error.code === '42703' || /column/i.test(error.message ?? ''));
}

/** 호출 기록은 기능을 막지 않는다. 실패하면 로그만 남기고 null. */
export async function recordAiRun(admin: Db, rec: AiRunRecord): Promise<string | null> {
  try {
    let { data, error } = await admin.from('ai_runs').insert(aiRunRow(rec)).select('id').single();
    if (error && rec.features && missingFeaturesColumn(error)) {
      ({ data, error } = await admin.from('ai_runs').insert(aiRunRow({ ...rec, features: null })).select('id').single());
    }
    if (error && rec.roleProfileVersion && /role_profile_version/.test(error.message ?? '')) {
      ({ data, error } = await admin.from('ai_runs').insert(aiRunRow({ ...rec, roleProfileVersion: null })).select('id').single());
    }
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
