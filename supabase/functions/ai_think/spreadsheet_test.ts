import { assert, assertEquals, assertExists } from 'jsr:@std/assert@1';
import { FakeAiProvider, FakeCodeSandbox } from '../_shared/ai/fake.ts';
import { buildResponsesBody, parseResponse } from '../_shared/ai/openai.ts';
import { OpenAiCodeSandbox } from '../_shared/ai/openai_sandbox.ts';
import type { AiRequest } from '../_shared/ai/types.ts';
import { runThinkChat, type ChatInput } from './chat.ts';
import { SPREADSHEET_MIME, type AttachmentRef } from './context.ts';
import { titleInstructions } from './prompts.ts';
import { EventLog, MemoryThinkStore, RunLog, testEnv } from './test_support.ts';
import { parseAttachments } from './validate.ts';

const sheet: AttachmentRef = { path: 'user-1/202610/a-scores.xlsx', name: '성적.xlsx', mime: SPREADSHEET_MIME, size: 1000 };
const pdf: AttachmentRef = { path: 'user-1/202610/b-plan.pdf', name: 'plan.pdf', mime: 'application/pdf', size: 1000 };

function chatInput(partial: Partial<ChatInput> = {}): ChatInput {
  return {
    userId: 'user-1',
    safetyId: 'hash',
    conversationId: null,
    message: '반별 평균을 알려줘',
    attachments: [],
    deep: false,
    webSearch: false,
    signal: new AbortController().signal,
    startedAt: Date.now(),
    wallClockMs: 140000,
    ...partial,
  };
}

const isTitle = (req: AiRequest) => req.instructions === titleInstructions();
const mainRequests = (p: FakeAiProvider) => p.requests.filter((r) => !isTitle(r));

function filePartUrls(req: AiRequest): string[] {
  return req.input.flatMap((i) => (i.kind === 'message' ? i.parts : [])).flatMap((p) => (p.type === 'file' ? [p.url] : []));
}

Deno.test('엑셀 첨부: 실행 환경에 올리고, 만든 파일을 답변에 붙이고, 실행 환경을 지운다', async () => {
  const store = new MemoryThinkStore();
  const sandbox = new FakeCodeSandbox({
    outputs: [
      { fileId: 'cfile_png', name: 'chart.png' },
      { fileId: 'cfile_xlsx', name: '반별평균.xlsx' },
      { fileId: 'cfile_py', name: 'work.py' },
    ],
  });
  const provider = new FakeAiProvider(
    (req) => (isTitle(req) ? { text: '제목' } : { text: '반별 평균을 계산했습니다.', codeRuns: 2, citedFileIds: ['cfile_xlsx'] }),
    { sandbox },
  );
  const runs = new RunLog();
  const events = new EventLog();

  const out = await runThinkChat(chatInput({ attachments: [sheet, pdf] }), {
    provider,
    store,
    recordRun: runs.record,
    emit: events.emit,
    env: testEnv,
  });

  assertEquals(out.status, 'complete');
  assertEquals(sandbox.opened.length, 1);
  assertEquals(sandbox.opened[0].files.map((f) => f.name), ['성적.xlsx']);
  assertEquals(store.readCalls, [sheet.path]);

  const main = mainRequests(provider)[0];
  assertEquals(main.codeInterpreter?.containerId, sandbox.opened[0].containerId);
  assertEquals(filePartUrls(main), [`https://signed.example/${pdf.path}`], '엑셀은 모델 입력 파일로 보내지 않는다');
  assertEquals(main.input.at(-1)!.kind, 'message');
  assertEquals(main.input.at(-2)!.kind, 'context');

  assertEquals(sandbox.collected[0].preferred.map((c) => c.fileId), ['cfile_xlsx']);
  assertEquals(store.answerFiles.map((f) => f.mime).sort(), ['image/png', SPREADSHEET_MIME].sort());
  const assistant = store.messages.find((m) => m.role === 'assistant')!;
  assertEquals(assistant.attachments.length, 2);
  assert(assistant.attachments.every((a) => a.path.startsWith('user-1/')));
  assertEquals(sandbox.closed, [sandbox.opened[0].containerId]);

  const done = events.of('done')[0];
  assertEquals((done.attachments as unknown[]).length, 2);
  assert(events.of('tool').some((t) => t.name === 'code_interpreter'));
  assert(assistant.extra!.tool_calls!.some((t) => t.name === 'code_interpreter'));

  const run = runs.runs.find((r) => r.feature === 'think_chat')!;
  const tokensOnly = new FakeAiProvider([{ text: 'x' }]);
  const plain = new RunLog();
  await runThinkChat(chatInput({ conversationId: (await store.createConversation('t')).id }), {
    provider: tokensOnly,
    store,
    recordRun: plain.record,
    emit: new EventLog().emit,
    env: testEnv,
  });
  assert(run.costUsd! - plain.runs[0].costUsd! >= 0.03 - 1e-9, '실행 환경 비용이 기록에 들어간다');
});

Deno.test('엑셀이 없으면 실행 환경을 열지 않고 파이썬 도구도 주지 않는다', async () => {
  const sandbox = new FakeCodeSandbox();
  const provider = new FakeAiProvider((req) => (isTitle(req) ? { text: '제목' } : { text: '답변' }), { sandbox });
  await runThinkChat(chatInput({ attachments: [pdf] }), {
    provider,
    store: new MemoryThinkStore(),
    recordRun: new RunLog().record,
    emit: new EventLog().emit,
    env: testEnv,
  });
  assertEquals(sandbox.opened.length, 0);
  assertEquals(mainRequests(provider)[0].codeInterpreter, undefined);
});

Deno.test('실행 환경을 열지 못하면 도구 없이 답하고 알린다', async () => {
  const sandbox = new FakeCodeSandbox({ openError: 'quota' });
  const provider = new FakeAiProvider((req) => (isTitle(req) ? { text: '제목' } : { text: '다시 보내 주세요' }), { sandbox });
  const events = new EventLog();
  const out = await runThinkChat(chatInput({ attachments: [sheet] }), {
    provider,
    store: new MemoryThinkStore(),
    recordRun: new RunLog().record,
    emit: events.emit,
    env: testEnv,
  });
  assertEquals(out.status, 'complete');
  const main = mainRequests(provider)[0];
  assertEquals(main.codeInterpreter, undefined);
  assertEquals(main.input.at(-2)!.kind, 'context');
  assert(events.of('notice').some((n) => n.code === 'spreadsheet_unavailable'));
});

Deno.test('결과 파일을 옮기지 못해도 답변은 저장되고 실행 환경은 지운다', async () => {
  const store = new MemoryThinkStore();
  const sandbox = new FakeCodeSandbox({ collectError: 'gone' });
  const provider = new FakeAiProvider((req) => (isTitle(req) ? { text: '제목' } : { text: '답', codeRuns: 1 }), { sandbox });
  const events = new EventLog();
  const out = await runThinkChat(chatInput({ attachments: [sheet] }), {
    provider,
    store,
    recordRun: new RunLog().record,
    emit: events.emit,
    env: testEnv,
  });
  assertEquals(out.status, 'complete');
  assert(events.of('notice').some((n) => n.code === 'answer_files_failed'));
  assertEquals(sandbox.closed.length, 1);
  assertEquals(store.messages.find((m) => m.role === 'assistant')!.attachments, []);
});

Deno.test('AI 호출이 실패해도 실행 환경을 지운다', async () => {
  const sandbox = new FakeCodeSandbox();
  const provider = new FakeAiProvider((req) => (isTitle(req) ? { text: '제목' } : { error: 'boom' }), { sandbox });
  const out = await runThinkChat(chatInput({ attachments: [sheet] }), {
    provider,
    store: new MemoryThinkStore(),
    recordRun: new RunLog().record,
    emit: new EventLog().emit,
    env: testEnv,
  });
  assertEquals(out.status, 'error');
  assertEquals(sandbox.closed.length, 1);
  assertEquals(sandbox.collected.length, 0);
});

Deno.test('최근 질문의 엑셀은 다시 올리고, 오래된 질문의 엑셀은 올리지 않는다', async () => {
  const store = new MemoryThinkStore();
  const conv = await store.createConversation('대화');
  const old: AttachmentRef = { ...sheet, path: 'user-1/202610/old.xlsx', name: 'old.xlsx' };
  await store.insertMessage({ conversation_id: conv.id, role: 'user', content: '옛 질문', status: 'complete', attachments: [old] });
  await store.insertMessage({ conversation_id: conv.id, role: 'assistant', content: '옛 답', status: 'complete' });
  await store.insertMessage({ conversation_id: conv.id, role: 'user', content: '최근 질문', status: 'complete', attachments: [sheet] });
  await store.insertMessage({ conversation_id: conv.id, role: 'assistant', content: '최근 답', status: 'complete' });
  const sandbox = new FakeCodeSandbox();
  const provider = new FakeAiProvider([{ text: '이어서 답' }], { sandbox });

  await runThinkChat(chatInput({ conversationId: conv.id, message: '그 표에서 3반만 다시' }), {
    provider,
    store,
    recordRun: new RunLog().record,
    emit: new EventLog().emit,
    env: testEnv,
  });
  assertEquals(sandbox.opened[0].files.map((f) => f.name), ['성적.xlsx']);
  assertExists(provider.requests[0].codeInterpreter);
});

Deno.test('첨부 검사: .xlsx는 받고 .xls·.xlsm·.csv는 받지 않는다', () => {
  const base = { path: 'user-1/202610/x', name: 'x', size: 10 };
  assert(Array.isArray(parseAttachments([{ ...base, mime: SPREADSHEET_MIME }], 'user-1')));
  for (const mime of ['application/vnd.ms-excel', 'application/vnd.ms-excel.sheet.macroenabled.12', 'text/csv']) {
    assertEquals(parseAttachments([{ ...base, mime }], 'user-1'), 'attachment_type_invalid');
  }
});

Deno.test('OpenAI 요청·응답: 파이썬 도구는 실행 환경 id로, 실행 횟수와 파일 인용을 읽는다', () => {
  const body = buildResponsesBody({ model: 'm', input: [], codeInterpreter: { containerId: 'cntr_1' } }, true);
  assertEquals(body.tools, [{ type: 'code_interpreter', container: 'cntr_1' }]);
  assertEquals(body.store, false);

  const result = parseResponse(
    {
      model: 'm',
      status: 'completed',
      output: [
        { type: 'code_interpreter_call', id: 'ci_1', status: 'completed', container_id: 'cntr_1' },
        {
          type: 'message',
          id: 'msg_1',
          content: [{
            type: 'output_text',
            text: '결과',
            annotations: [{ type: 'container_file_citation', container_id: 'cntr_1', file_id: 'cfile_1', filename: 'out.xlsx' }],
          }],
        },
      ],
    },
    'openai',
  );
  assertEquals(result.codeRuns, 1);
  assertEquals(result.messages[0].files, [{ containerId: 'cntr_1', fileId: 'cfile_1', filename: 'out.xlsx' }]);
});

Deno.test('OpenAI 실행 환경: 파일 업로드 → 1GB 실행 환경 → 만든 파일만 내려받기 → 모두 삭제', async () => {
  const calls: { method: string; url: string; body?: unknown }[] = [];
  const json = (v: unknown) => new Response(JSON.stringify(v), { status: 200, headers: { 'Content-Type': 'application/json' } });
  const fetchImpl = ((input: string | URL | Request, init?: RequestInit) => {
    const url = String(input).replace('https://api.openai.com/v1', '');
    const method = init?.method ?? 'GET';
    calls.push({ method, url, body: typeof init?.body === 'string' ? JSON.parse(init.body) : undefined });
    if (method === 'POST' && url === '/files') return Promise.resolve(json({ id: 'file_1' }));
    if (method === 'POST' && url === '/containers') return Promise.resolve(json({ id: 'cntr_1' }));
    if (method === 'GET' && url.startsWith('/containers/cntr_1/files?')) {
      return Promise.resolve(json({
        data: [
          { id: 'cfile_in', path: '/mnt/data/성적.xlsx', bytes: 10, source: 'user' },
          { id: 'cfile_out', path: '/mnt/data/결과.xlsx', bytes: 3, source: 'assistant' },
          { id: 'cfile_tmp', path: '/mnt/data/tmp.pkl', bytes: 3, source: 'assistant' },
        ],
      }));
    }
    if (method === 'GET' && url === '/containers/cntr_1/files/cfile_out/content') return Promise.resolve(new Response('abc'));
    if (method === 'DELETE') return Promise.resolve(json({ deleted: true }));
    return Promise.resolve(new Response('not found', { status: 404 }));
  }) as typeof fetch;

  const sb = new OpenAiCodeSandbox({ apiKey: 'k', fetchImpl });
  const session = await sb.open([{ name: '성적.xlsx', mime: SPREADSHEET_MIME, bytes: new Uint8Array([1, 2]) }]);
  assertEquals(session.containerId, 'cntr_1');
  const created = calls.find((c) => c.url === '/containers')!;
  assertEquals(created.body, { name: 'think-answer', memory_limit: '1g', file_ids: ['file_1'] });

  const outputs = await session.collectOutputs({ exts: ['.xlsx', '.csv', '.png'], limit: 6, maxBytes: 100, preferred: [] });
  assertEquals(outputs.map((o) => o.name), ['결과.xlsx']);
  assertEquals(new TextDecoder().decode(outputs[0].bytes), 'abc');

  await session.close();
  await session.close();
  const deletes = calls.filter((c) => c.method === 'DELETE').map((c) => c.url);
  assertEquals(deletes, ['/containers/cntr_1', '/files/file_1']);
});
