import { assert, assertEquals } from 'jsr:@std/assert@1';
import { EDGE_FEATURES, computeFeatures, isMissingFunctionError, isSplitRequest, parseClientFeatures } from './features.ts';
import { SupabaseThinkStore, type SupabaseLike } from './store.ts';

const app = { conversation_split: EDGE_FEATURES.conversation_split };

Deno.test('기능 상태: DB·앱·권한이 모두 맞아야 준비됨이고, 확인 실패는 사용 가능으로 보지 않는다', () => {
  const ready = computeFeatures({ ok: true, features: { conversation_split: 1 } }, app, true).conversation_split;
  assertEquals(ready.state, 'ready');
  assertEquals([ready.edge, ready.db, ready.app], [1, 1, 1]);

  assertEquals(computeFeatures({ ok: false, missing: true, error: 'x' }, app, true).conversation_split.state, 'db_required');
  assertEquals(computeFeatures({ ok: true, features: {} }, app, true).conversation_split.state, 'db_required');
  assertEquals(computeFeatures({ ok: true, features: { conversation_split: 1 } }, {}, true).conversation_split.state, 'app_update_required');

  const failed = computeFeatures({ ok: false, missing: false, error: 'timeout' }, app, true).conversation_split;
  assertEquals(failed.state, 'unknown');
  assertEquals(failed.db, null);
  assertEquals(computeFeatures({ ok: true, features: { conversation_split: 1 } }, app, false).conversation_split.state, 'unknown');
});

Deno.test('앱 지원 기능은 숫자만 받는다', () => {
  assertEquals(parseClientFeatures({ features: { conversation_split: 1, other: 'yes', bad: null } }), { conversation_split: 1 });
  assertEquals(parseClientFeatures(null), {});
  assertEquals(parseClientFeatures({ features: ['conversation_split'] }), {});
});

Deno.test('함수가 없다는 오류만 DB 반영 필요로 본다', () => {
  assert(isMissingFunctionError({ code: 'PGRST202', message: 'Could not find the function public.ai_think_db_features' }));
  assert(isMissingFunctionError({ code: '42883', message: 'function does not exist' }));
  assert(!isMissingFunctionError({ code: '42501', message: 'forbidden' }));
  assert(!isMissingFunctionError({ message: 'fetch failed' }));
  assert(!isMissingFunctionError(null));
});

Deno.test('사용자가 직접 나누자고 한 메시지만 명시 요청으로 본다', () => {
  for (const m of ['이 대화 나눠 줘', '주제가 바뀌었으니 대화를 분리하자', '새 대화로 옮겨서 이어가자', '새 대화에서 계속하자']) {
    assert(isSplitRequest(m), m);
  }
  for (const m of ['예시를 나눠서 설명해 줘', '분수 나눗셈 문제를 만들어 줘', '대화 주제가 뭐였지?', '새로운 원칙을 정하자']) {
    assert(!isSplitRequest(m), m);
  }
});

function rpcDb(result: () => Promise<{ data: unknown; error: { code?: string; message: string } | null }>): {
  db: SupabaseLike;
  calls: string[];
} {
  const calls: string[] = [];
  const db = {
    from: () => {
      throw new Error('기능 확인은 테이블을 읽지 않는다');
    },
    rpc: (fn: string) => {
      calls.push(fn);
      return result();
    },
    storage: { from: () => null },
  } as unknown as SupabaseLike;
  return { db, calls };
}

Deno.test('DB 기능 확인: 읽기 전용 함수 하나만 부르고 결과를 분류한다', async () => {
  const ok = rpcDb(() => Promise.resolve({ data: { conversation_split: 1 }, error: null }));
  assertEquals(await new SupabaseThinkStore(ok.db).dbFeatures(), { ok: true, features: { conversation_split: 1 } });
  assertEquals(ok.calls, ['ai_think_db_features']);

  const missing = rpcDb(() => Promise.resolve({ data: null, error: { code: 'PGRST202', message: 'Could not find the function' } }));
  const m = await new SupabaseThinkStore(missing.db).dbFeatures();
  assert(!m.ok && m.missing);

  const denied = rpcDb(() => Promise.resolve({ data: null, error: { code: '42501', message: 'forbidden' } }));
  const d = await new SupabaseThinkStore(denied.db).dbFeatures();
  assert(!d.ok && !d.missing);

  const thrown = rpcDb(() => Promise.reject(new Error('network down')));
  const t = await new SupabaseThinkStore(thrown.db).dbFeatures();
  assert(!t.ok && !t.missing);
});
