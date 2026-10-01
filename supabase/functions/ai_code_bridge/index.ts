// ai_code_bridge: 운영자 PC의 코드 작업자 전용 (사용자 JWT가 아니라 작업자 토큰).
//   POST { action: 'claim', worker_id, info? }  → request.job: run(조사·수정) / apply / revert
//   POST { action: 'heartbeat', worker_id, request_id?, agent_id?, run_id? }
//   POST { action: 'complete', worker_id, request_id, round }  → 대화에서 온 요청이면 Think 자동 검토(백그라운드)
//   POST { action: 'fail', worker_id, request_id, code, error, retryable, round? }
//   POST { action: 'apply_done', worker_id, request_id, ok, result }
// DB는 ai_code_bridge_* RPC(service role 전용)로만 바꾼다.
// 설계: docs/architecture/ai-code-bridge.md, docs/architecture/ai-think-actions.md

import { safetyIdentifier } from '../_shared/ai/auth.ts';
import { getBudgetStatus } from '../_shared/ai/budget.ts';
import { createAiProvider } from '../_shared/ai/provider.ts';
import { recordAiRun } from '../_shared/ai/usage.ts';
import { sha256Hex } from '../_shared/hash.ts';
import { createAdminClient } from '../_shared/supabase.ts';
import type { SupabaseLike } from '../ai_think/store.ts';
import { runCodeReview } from './code_review.ts';
import { handleBridge } from './handler.ts';
import { SupabaseReviewStore } from './review_store.ts';

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

Deno.serve((req) => {
  const admin = createAdminClient();
  return handleBridge(req, {
    tokenSha256: Deno.env.get('CODE_BRIDGE_WORKER_TOKEN_SHA256') ?? null,
    hash: sha256Hex,
    rpc: async (fn, args) => {
      const { data, error } = await admin.rpc(fn, args);
      return { data, error: error ? { message: error.message } : null };
    },
    recordRun: (rec) => recordAiRun(admin, rec),
    review: (requestId) =>
      runCodeReview(
        {
          provider: createAiProvider({ timeoutMs: 120000 }),
          store: new SupabaseReviewStore(admin as unknown as SupabaseLike),
          recordRun: (rec) => recordAiRun(admin, rec),
          budget: () => getBudgetStatus(admin),
          safetyId: safetyIdentifier,
        },
        requestId,
      ),
    background: (task) => {
      if (typeof EdgeRuntime !== 'undefined' && EdgeRuntime?.waitUntil) EdgeRuntime.waitUntil(task);
    },
  });
});
