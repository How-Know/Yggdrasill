// ai_think_relay: 운영자 PC의 Cursor 작업창이 Think를 읽고 묻는 통로 (사용자 JWT가 아니라 전용 토큰).
//   POST { action: 'status' }
//   POST { action: 'list_memories', kinds?, limit? }            승인된 기억 목록
//   POST { action: 'search_memories', query, kinds?, limit? }   승인된 기억 검색
//   POST { action: 'get_memory', id }                           승인된 기억 하나
//   POST { action: 'list_conversations', query?, limit?, include_archived? }
//   POST { action: 'get_conversation', conversation_id, limit? } '답변에서 제외'한 문답은 빠진다
//   POST { action: 'list_code_requests', query?, limit? } / { action: 'get_code_request', id, section?, offset? }
//        section 없음: 짧은 구조화 요약. section(request|result|result_text|check_logs|diff) + offset: 원문 구간
//   POST { action: 'ask', question, conversation_id? }          Think에게 묻기(조회 도구만, 커서 대화에만 남음)
// 배포: supabase functions deploy ai_think_relay --no-verify-jwt --use-api
// 설계: docs/architecture/ai-think.md §12

import { getBudgetStatus } from '../_shared/ai/budget.ts';
import { thinkWallClockMs } from '../_shared/ai/config.ts';
import { safetyIdentifier } from '../_shared/ai/auth.ts';
import { createAiProvider } from '../_shared/ai/provider.ts';
import { recordAiRun } from '../_shared/ai/usage.ts';
import { sha256Hex } from '../_shared/hash.ts';
import { createAdminClient } from '../_shared/supabase.ts';
import { RELAY_DEFAULT_DAILY_LIMIT, runRelayAsk } from '../ai_think/relay.ts';
import { SupabaseThinkStore, type SupabaseLike } from '../ai_think/store.ts';
import { handleRelay } from './handler.ts';

function dailyLimit(): number {
  const n = Number.parseInt(Deno.env.get('THINK_RELAY_DAILY_LIMIT') ?? '', 10);
  return Number.isFinite(n) && n > 0 ? Math.min(n, 1000) : RELAY_DEFAULT_DAILY_LIMIT;
}

Deno.serve(async (req) => {
  const admin = createAdminClient();
  const store = new SupabaseThinkStore(admin as unknown as SupabaseLike);
  const limit = dailyLimit();
  const wallClockMs = thinkWallClockMs();
  return handleRelay(req, {
    tokenSha256: Deno.env.get('THINK_RELAY_TOKEN_SHA256') ?? null,
    hash: sha256Hex,
    store,
    dailyLimit: limit,
    ask: async ({ question, conversationId }) =>
      runRelayAsk(
        {
          provider: createAiProvider({ timeoutMs: wallClockMs + 5000 }),
          store,
          recordRun: (rec) => recordAiRun(admin, rec),
          budget: () => getBudgetStatus(admin),
          safetyId: await safetyIdentifier('cursor_ide'),
        },
        { asker: 'cursor_ide', question, conversationId, dailyLimit: limit, wallClockMs },
      ),
  });
});
