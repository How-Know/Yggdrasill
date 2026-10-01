import { assert, assertEquals } from 'jsr:@std/assert@1';
import { estimateCostUsd, modelFor, priceFor, reasoningFor } from './config.ts';
import { OpenAiResponsesProvider, buildResponsesBody } from './openai.ts';
import { extractSearchTerms } from './search_terms.ts';
import { readSse } from './sse.ts';
import type { AiStreamEvent } from './types.ts';

const env = (vars: Record<string, string>) => ({ get: (k: string) => vars[k] });

Deno.test('모델 이름과 추론 강도는 환경변수로 바꾼다', () => {
  assertEquals(modelFor('primary', env({})), 'gpt-6-sol');
  assertEquals(modelFor('deep', env({ AI_MODEL_REASONING: 'gpt-6-astra-x' })), 'gpt-6-astra-x');
  assertEquals(modelFor('fast', env({ AI_MODEL_FAST: 'my-model' })), 'my-model');
  assertEquals(reasoningFor('fast', env({})), 'none');
});

Deno.test('비용: 캐시·캐시 쓰기·출력·웹 검색을 나눠 계산한다', () => {
  const usage = { inputTokens: 200_000, cachedInputTokens: 80_000, cacheWriteTokens: 20_000, outputTokens: 20_000, reasoningTokens: 10_000 };
  // gpt-6-sol: (100k*2 + 80k*0.2 + 20k*2.5 + 20k*10) / 1M + 2*0.01
  assertEquals(estimateCostUsd('gpt-6-sol', usage, 2, env({})), 0.486);
  assertEquals(estimateCostUsd('unknown-model', usage, 0, env({})), null);
  assert(priceFor('gpt-6-sol-2026-08-01', env({})) !== null);
  const override = env({ AI_PRICING_JSON: JSON.stringify({ 'x-model': { input: 1, cachedInput: 0, cacheWrite: 0, output: 0 } }) });
  assertEquals(estimateCostUsd('x-model', { ...usage, cachedInputTokens: 0, cacheWriteTokens: 0 }, 0, override), 0.2);
});

Deno.test('비용: 272K 토큰을 넘는 요청은 장문 요금을 쓴다', () => {
  const usage = { inputTokens: 300_000, cachedInputTokens: 0, cacheWriteTokens: 0, outputTokens: 0, reasoningTokens: 0 };
  assertEquals(estimateCostUsd('gpt-6-sol', usage, 0, env({})), 1.2);
});

Deno.test('검색어 추출은 조사와 불용어를 뗀다', () => {
  assertEquals(extractSearchTerms('반복사고를 커리큘럼에 어떻게 반영할까?'), ['반복사고', '커리큘럼', '반영할까']);
  assertEquals(extractSearchTerms('?? !!'), []);
});

Deno.test('Responses 요청 본문: store:false, strict 도구, 지난 답변 phase, 참고 메시지', () => {
  const body = buildResponsesBody(
    {
      model: 'gpt-6-sol',
      instructions: 'sys',
      input: [
        { kind: 'message', role: 'user', parts: [{ type: 'text', text: 'q1' }, { type: 'file', url: 'https://f', filename: 'a.pdf' }] },
        { kind: 'message', role: 'assistant', parts: [{ type: 'text', text: 'a1' }] },
        { kind: 'context', text: 'memo' },
        { kind: 'tool_result', callId: 'c1', output: '{}' },
      ],
      tools: [{ name: 't', description: 'd', parameters: { type: 'object', properties: {}, required: [], additionalProperties: false } }],
      webSearch: {},
      toolChoice: 'auto',
      reasoningEffort: 'medium',
      maxOutputTokens: 100,
      cacheKey: 'k',
      safetyId: 's',
    },
    true,
  );
  assertEquals(body.store, false);
  assertEquals(body.stream, true);
  assertEquals(body.include, ['web_search_call.action.sources']);
  const tools = body.tools as Record<string, unknown>[];
  assertEquals(tools.map((t) => t.type), ['function', 'web_search']);
  assertEquals(tools[0].strict, true);
  const input = body.input as Record<string, unknown>[];
  assertEquals(input[0].role, 'user');
  assertEquals((input[0].content as Record<string, unknown>[])[1], { type: 'input_file', file_url: 'https://f', filename: 'a.pdf' });
  assertEquals(input[1], { type: 'message', role: 'assistant', phase: 'final_answer', content: 'a1' });
  assertEquals(input[2], { type: 'message', role: 'developer', content: 'memo' });
  assertEquals(input[3], { type: 'function_call_output', call_id: 'c1', output: '{}' });
  assertEquals(body.prompt_cache_key, 'k');
  assertEquals(body.safety_identifier, 's');
});

function sseBody(events: Record<string, unknown>[], chunkSize = 7): ReadableStream<Uint8Array> {
  const text = events.map((e) => `event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`).join('');
  const bytes = new TextEncoder().encode(text);
  let offset = 0;
  return new ReadableStream({
    pull(controller) {
      if (offset >= bytes.length) return controller.close();
      controller.enqueue(bytes.slice(offset, offset + chunkSize));
      offset += chunkSize;
    },
  });
}

Deno.test('SSE 파서는 조각난 청크에서도 이벤트를 복원한다', async () => {
  const out: string[] = [];
  for await (const m of readSse(sseBody([{ type: 'a', v: '한글' }, { type: 'b', v: 2 }], 3))) out.push(m.event ?? '');
  assertEquals(out, ['a', 'b']);
});

Deno.test('OpenAI 스트림: 중간 설명, 도구 호출, 출처, 사용량을 해석한다', async () => {
  const output = [
    { type: 'reasoning', id: 'rs_1', encrypted_content: 'enc', summary: [] },
    { type: 'message', id: 'msg_1', role: 'assistant', phase: 'commentary', content: [{ type: 'output_text', text: '찾아볼게요', annotations: [] }] },
    { type: 'web_search_call', id: 'ws_1', status: 'completed', action: { type: 'search', query: '교육과정 개정' } },
    { type: 'function_call', id: 'fc_1', call_id: 'call_1', name: 'search_memories', arguments: '{"query":"x","kinds":null}' },
    {
      type: 'message',
      id: 'msg_2',
      role: 'assistant',
      phase: 'final_answer',
      content: [{ type: 'output_text', text: '답', annotations: [{ type: 'url_citation', url: 'https://ex.com', title: 'Ex' }] }],
    },
  ];
  const events = [
    { type: 'response.created', response: {} },
    { type: 'response.output_item.added', item: { type: 'message', id: 'msg_1', phase: 'commentary' } },
    { type: 'response.output_text.delta', item_id: 'msg_1', delta: '찾아' },
    { type: 'response.output_text.delta', item_id: 'msg_1', delta: '볼게요' },
    { type: 'response.output_item.done', item: output[1] },
    { type: 'response.output_item.added', item: { type: 'function_call', call_id: 'call_1', name: 'search_memories' } },
    {
      type: 'response.completed',
      response: {
        model: 'gpt-6-sol-2026-08-01',
        status: 'completed',
        output,
        usage: { input_tokens: 10, input_tokens_details: { cached_tokens: 4 }, output_tokens: 5, output_tokens_details: { reasoning_tokens: 2 } },
      },
    },
  ];
  let sentBody: Record<string, unknown> | null = null;
  const fetchImpl = ((_url: string, init?: RequestInit) => {
    sentBody = JSON.parse(String(init?.body));
    return Promise.resolve(new Response(sseBody(events), { status: 200, headers: { 'Content-Type': 'text/event-stream' } }));
  }) as typeof fetch;

  const provider = new OpenAiResponsesProvider({ apiKey: 'sk-test', fetchImpl });
  const seen: AiStreamEvent[] = [];
  for await (const ev of provider.stream({ model: 'gpt-6-sol', input: [] })) seen.push(ev);

  assertEquals(sentBody!['store'], false);
  assertEquals(seen.map((e) => e.type), ['message_start', 'text_delta', 'text_delta', 'message_done', 'function_call_start', 'completed']);
  const done = seen.at(-1)!;
  assert(done.type === 'completed');
  const r = done.result;
  assertEquals(r.messages.map((m) => m.phase), ['commentary', 'final']);
  assertEquals(r.functionCalls[0].callId, 'call_1');
  assertEquals(r.webSearchCalls, 1);
  assertEquals(r.messages[1].sources, [{ url: 'https://ex.com', title: 'Ex' }]);
  assertEquals(r.usage, { inputTokens: 10, cachedInputTokens: 4, cacheWriteTokens: 0, outputTokens: 5, reasoningTokens: 2 });
  assert(r.replay.kind === 'provider_items' && r.replay.items.length === output.length);
});

Deno.test('OpenAI 오류 응답은 메시지와 상태 코드를 담은 예외가 된다', async () => {
  const fetchImpl = (() =>
    Promise.resolve(new Response(JSON.stringify({ error: { message: 'bad model', code: 'model_not_found' } }), { status: 404 }))) as typeof fetch;
  const provider = new OpenAiResponsesProvider({ apiKey: 'sk-test', fetchImpl });
  try {
    await provider.complete({ model: 'nope', input: [] });
    throw new Error('should fail');
  } catch (e) {
    assertEquals((e as { status?: number }).status, 404);
    assertEquals((e as { code?: string }).code, 'model_not_found');
  }
});
