export interface SseMessage {
  event: string | null;
  data: string;
}

/** text/event-stream 바이트 스트림을 메시지 단위로 읽는다. */
export async function* readSse(body: ReadableStream<Uint8Array>): AsyncGenerator<SseMessage> {
  const reader = body.pipeThrough(new TextDecoderStream()).getReader();
  let buffer = '';
  let event: string | null = null;
  let dataLines: string[] = [];

  const flush = (): SseMessage | null => {
    const msg = dataLines.length > 0 ? { event, data: dataLines.join('\n') } : null;
    event = null;
    dataLines = [];
    return msg;
  };

  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      buffer += value;
      const lines = buffer.split('\n');
      buffer = lines.pop() ?? '';
      for (const raw of lines) {
        const line = raw.endsWith('\r') ? raw.slice(0, -1) : raw;
        if (line === '') {
          const msg = flush();
          if (msg) yield msg;
          continue;
        }
        if (line.startsWith(':')) continue;
        const colon = line.indexOf(':');
        const field = colon === -1 ? line : line.slice(0, colon);
        let value = colon === -1 ? '' : line.slice(colon + 1);
        if (value.startsWith(' ')) value = value.slice(1);
        if (field === 'event') event = value;
        else if (field === 'data') dataLines.push(value);
      }
    }
    if (buffer) {
      const line = buffer.endsWith('\r') ? buffer.slice(0, -1) : buffer;
      if (line.startsWith('data:')) dataLines.push(line.slice(5).trimStart());
    }
    const last = flush();
    if (last) yield last;
  } finally {
    try {
      await reader.cancel();
    } catch {
      // 이미 닫힌 스트림
    }
  }
}

const encoder = new TextEncoder();

export function sseEvent(event: string, data: unknown): Uint8Array {
  return encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
}

export function sseComment(text: string): Uint8Array {
  return encoder.encode(`: ${text}\n\n`);
}
