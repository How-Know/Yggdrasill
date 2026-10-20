// 긴 정리 응답. Supabase는 함수가 150초 안에 응답을 시작하지 않으면 끊으므로, 200과 머리를 먼저 보내고
// 공백을 흘리며 기다린 뒤 결과 JSON을 붙인다(앞 공백은 JSON으로 읽힌다). 원래 상태 코드는 http_status 에 둔다.
// 함수 전체 실행 시간 한도는 요금제를 따르며, 넘으면 응답이 중간에 끊긴다.

export const KEEPALIVE_INTERVAL_MS = 10_000;

async function settle(work: () => Promise<Response>): Promise<Record<string, unknown>> {
  try {
    const res = await work();
    const text = await res.text();
    let body: unknown = null;
    try {
      body = JSON.parse(text);
    } catch {
      body = null;
    }
    const obj = body && typeof body === 'object' && !Array.isArray(body)
      ? body as Record<string, unknown>
      : { ok: false, error: 'invalid_response' };
    return { ...obj, http_status: res.status };
  } catch (e) {
    console.error('[keepalive] work failed:', e instanceof Error ? e.message : String(e));
    return { ok: false, error: 'internal_error', message: 'internal_error', http_status: 500 };
  }
}

export function keepAliveJson(
  work: () => Promise<Response>,
  headers: Record<string, string>,
  intervalMs = KEEPALIVE_INTERVAL_MS,
): Response {
  const enc = new TextEncoder();
  let timer: ReturnType<typeof setInterval> | undefined;
  let closed = false;
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      const push = (s: string) => {
        if (closed) return;
        try {
          controller.enqueue(enc.encode(s));
        } catch {
          closed = true;
        }
      };
      push(' ');
      timer = setInterval(() => push(' '), intervalMs);
      void settle(work).then((out) => {
        clearInterval(timer);
        push(JSON.stringify(out));
        if (!closed) {
          closed = true;
          try {
            controller.close();
          } catch {
            // 받는 쪽이 먼저 끊었다.
          }
        }
      });
    },
    cancel() {
      closed = true;
      clearInterval(timer);
    },
  });
  return new Response(body, { status: 200, headers: { ...headers, 'Content-Type': 'application/json' } });
}
