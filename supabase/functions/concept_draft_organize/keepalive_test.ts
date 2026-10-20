import { assert, assertEquals } from 'jsr:@std/assert@1';
import { keepAliveJson } from './keepalive.ts';

const json = (body: unknown, status: number) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

Deno.test('긴 응답: 200과 공백을 먼저 보내고, 결과에 원래 상태 코드를 붙인다', async () => {
  let release!: () => void;
  const gate = new Promise<void>((r) => (release = r));
  const res = keepAliveJson(async () => {
    await gate;
    return json({ ok: false, error: 'transcripts_missing', pages: [8] }, 409);
  }, { 'Access-Control-Allow-Origin': '*' }, 5);
  assertEquals(res.status, 200);
  assertEquals(res.headers.get('Content-Type'), 'application/json');
  assertEquals(res.headers.get('Access-Control-Allow-Origin'), '*');
  const reader = res.body!.getReader();
  const first = await reader.read();
  assertEquals(new TextDecoder().decode(first.value), ' ', '결과 전에 먼저 보낸다');
  await new Promise((r) => setTimeout(r, 20));
  release();
  let text = ' ';
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    text += new TextDecoder().decode(value);
  }
  assert(/^ +\{/.test(text), '앞은 공백뿐이다');
  assertEquals(JSON.parse(text), { ok: false, error: 'transcripts_missing', pages: [8], http_status: 409 });
});

Deno.test('긴 응답: 일이 던지거나 JSON이 아니면 실패 결과로 닫는다', async () => {
  const thrown = await keepAliveJson(() => Promise.reject(new Error('boom')), {}, 5).text();
  assertEquals(JSON.parse(thrown), { ok: false, error: 'internal_error', message: 'internal_error', http_status: 500 });
  const plain = await keepAliveJson(() => Promise.resolve(new Response('문장', { status: 502 })), {}, 5).text();
  assertEquals(JSON.parse(plain), { ok: false, error: 'invalid_response', http_status: 502 });
  const ok = await keepAliveJson(() => Promise.resolve(json({ ok: true, draft_id: 'd1' }, 200)), {}, 5).text();
  assertEquals(JSON.parse(ok), { ok: true, draft_id: 'd1', http_status: 200 });
});
