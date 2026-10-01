// ai_memo_assist: 학습앱 메모 요약·일정/연락처/이름 추출 (학원 구성원 또는 슈퍼관리자).
//   POST { task: 'status' }                         → { ok, configured }
//   POST { task, text, max_chars?, academy_id? }     → { ok, value }   (value가 null이면 앱이 정규식으로 처리)
// OpenAI 키는 이 함수의 비밀값으로만 쓴다. 앱에는 키가 없다.

import { corsHeaders } from '../_shared/cors.ts';
import { authenticate, errorResponse, isSuperadmin, jsonResponse, resolveMemberAcademy, safetyIdentifier } from '../_shared/ai/auth.ts';
import { getBudgetStatus } from '../_shared/ai/budget.ts';
import { estimateCostUsd, modelFor, reasoningFor } from '../_shared/ai/config.ts';
import { createAiProvider, isAiConfigured } from '../_shared/ai/provider.ts';
import { emptyUsage, finalText, type AiResult } from '../_shared/ai/types.ts';
import { recordAiRun } from '../_shared/ai/usage.ts';
import { MEMO_PROMPT_VERSION, MEMO_TASKS, memoPrompt, parseMemoOutput, type MemoTask } from './tasks.ts';

const MAX_TEXT_CHARS = 4000;
const RATE_LIMIT_PER_MINUTE = 30;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return errorResponse(405, 'method_not_allowed');

  const auth = await authenticate(req);
  if (!auth) return errorResponse(401, 'unauthorized');

  let body: Record<string, unknown>;
  try {
    const parsed = await req.json();
    body = parsed && typeof parsed === 'object' ? parsed : {};
  } catch {
    return errorResponse(400, 'invalid_json');
  }

  const requestedAcademy = typeof body.academy_id === 'string' ? body.academy_id.trim() : null;
  const academyId = await resolveMemberAcademy(auth, requestedAcademy || null);
  if (!academyId && !(await isSuperadmin(auth))) return errorResponse(403, 'forbidden');

  const task = String(body.task ?? '');
  if (task === 'status') return jsonResponse({ ok: true, configured: isAiConfigured() });
  if (!MEMO_TASKS.has(task)) return errorResponse(400, 'unknown_task');

  const text = typeof body.text === 'string' ? body.text.trim() : '';
  if (!text) return jsonResponse({ ok: true, value: null });
  if (text.length > MAX_TEXT_CHARS) return errorResponse(400, 'text_too_long');
  const maxCharsRaw = Number(body.max_chars);
  const maxChars = Number.isFinite(maxCharsRaw) ? Math.max(10, Math.min(200, Math.floor(maxCharsRaw))) : 60;

  const provider = createAiProvider({ timeoutMs: 20000 });
  if (!provider) return errorResponse(503, 'ai_not_configured');

  const since = new Date(Date.now() - 60_000).toISOString();
  const { count } = await auth.admin
    .from('ai_runs')
    .select('id', { count: 'exact', head: true })
    .eq('created_by', auth.userId)
    .like('feature', 'memo_%')
    .gte('created_at', since);
  if ((count ?? 0) >= RATE_LIMIT_PER_MINUTE) return errorResponse(429, 'rate_limited');

  const budget = await getBudgetStatus(auth.admin).catch(() => null);
  if (budget?.exceeded && budget.mode === 'block') return errorResponse(429, 'budget_exceeded');

  const prompt = memoPrompt(task as MemoTask, text, { maxChars });
  const model = modelFor('fast');
  const started = Date.now();
  let result: AiResult | null = null;
  let error: string | null = null;
  try {
    result = await provider.complete({
      model,
      instructions: prompt.instructions,
      input: [{ kind: 'message', role: 'user', parts: [{ type: 'text', text: prompt.userText }] }],
      reasoningEffort: reasoningFor('fast'),
      maxOutputTokens: prompt.maxOutputTokens,
      safetyId: await safetyIdentifier(auth.userId),
    });
  } catch (e) {
    error = e instanceof Error ? e.message : String(e);
    console.error('[ai_memo_assist] provider failed:', error);
  }

  await recordAiRun(auth.admin, {
    feature: `memo_${task}`,
    provider: provider.name,
    model: result?.model || model,
    promptVersion: MEMO_PROMPT_VERSION,
    status: error ? 'error' : 'ok',
    error,
    usage: result?.usage ?? emptyUsage(),
    costUsd: result ? estimateCostUsd(result.model || model, result.usage) : null,
    latencyMs: Date.now() - started,
    academyId,
    createdBy: auth.userId,
  });

  if (!result) return errorResponse(502, 'ai_failed');
  return jsonResponse({ ok: true, value: parseMemoOutput(task as MemoTask, finalText(result)) });
});
