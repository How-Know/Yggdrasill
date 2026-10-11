import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { DEFAULT_URL, TOOLS, callTool, createRelayClient, handleMessage, loadConfig } from '../src/relay.mjs';

test('설정: 환경 변수 토큰이 먼저고, 없으면 파일, 둘 다 없으면 null', () => {
  const noFile = () => {
    throw new Error('ENOENT');
  };
  assert.equal(loadConfig({ THINK_RELAY_TOKEN: ' env-token ' }, noFile).token, 'env-token');
  assert.equal(loadConfig({}, () => 'file-token\n').token, 'file-token');
  const none = loadConfig({}, noFile, 'C:/x/think_relay.token');
  assert.equal(none.token, null);
  assert.equal(none.url, DEFAULT_URL);
  assert.equal(loadConfig({ THINK_RELAY_URL: 'http://local/fn' }, noFile).url, 'http://local/fn');
});

test('도구: 읽기 7개와 ask_think 하나, 쓰기 도구는 없다', () => {
  assert.deepEqual(TOOLS.map((t) => t.action), [
    'search_memories',
    'list_memories',
    'get_memory',
    'list_conversations',
    'get_conversation',
    'list_code_requests',
    'get_code_request',
    'ask',
  ]);
  assert.match(TOOLS.find((t) => t.name === 'ask_think').description, /needs_owner/);
});

test('호출: 정의된 인자만 보내고, 토큰을 Bearer로 붙인다', async () => {
  const sent = [];
  const fetchImpl = (url, init) => {
    sent.push({ url, auth: init.headers.Authorization, body: JSON.parse(init.body) });
    return Promise.resolve(new Response(JSON.stringify({ ok: true, memories: [{ id: 'm1' }] })));
  };
  const call = createRelayClient({ url: 'http://relay', token: 'tok', tokenFile: 'f' }, fetchImpl);
  const out = await callTool(call, 'think_search_memories', { query: '정렬', limit: 5, action: 'ask', extra: 1 });
  assert.equal(out.isError, false);
  assert.deepEqual(JSON.parse(out.content[0].text), { memories: [{ id: 'm1' }] });
  assert.deepEqual(sent[0], { url: 'http://relay', auth: 'Bearer tok', body: { action: 'search_memories', query: '정렬', limit: 5 } });
});

test('ask_think: answered는 근거, needs_owner는 진행 금지와 확인 질문, 실패는 isError', async () => {
  const replies = [
    { ok: true, verdict: 'answered', conversation_id: 'c1', answer: '날짜순', basis: [{ id: 'm1', kind: 'decision', title: '날짜순 원칙' }], owner_questions: [] },
    { ok: true, verdict: 'needs_owner', conversation_id: 'c1', answer: '정한 적 없음', basis: [], owner_questions: ['과목별로 묶을까요?'] },
    { ok: false, error: 'relay_daily_limit', message: '오늘 한도' },
  ];
  const call = () => Promise.resolve(replies.shift());
  const a = await callTool(call, 'ask_think', { question: 'q' });
  assert.match(a.content[0].text, /answered[\s\S]*날짜순 원칙[\s\S]*conversation_id: c1/);
  const n = await callTool(call, 'ask_think', { question: 'q', conversation_id: 'c1' });
  assert.match(n.content[0].text, /진행하지 말고[\s\S]*과목별로 묶을까요/);
  const f = await callTool(call, 'ask_think', { question: 'q' });
  assert.equal(f.isError, true);
  assert.match(f.content[0].text, /relay_daily_limit\): 오늘 한도/);
  assert.equal((await callTool(call, 'drop_all', {})).isError, true);
});

test('토큰이 없으면 서버를 부르지 않고 설정 방법을 알려 준다', async () => {
  let called = false;
  const call = createRelayClient({ url: 'http://relay', token: null, tokenFile: 'C:/t' }, () => {
    called = true;
  });
  const out = await callTool(call, 'think_list_memories', {});
  assert.equal(called, false);
  assert.equal(out.isError, true);
  assert.match(out.content[0].text, /token_missing/);
});

test('JSON-RPC: initialize·ping·tools/list, 알림은 답하지 않고 모르는 메서드는 -32601', async () => {
  const ctx = { version: '1.0.0', call: () => Promise.resolve({ ok: true }) };
  const init = await handleMessage({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-03-26' } }, ctx);
  assert.equal(init.result.protocolVersion, '2025-03-26');
  assert.deepEqual(init.result.capabilities, { tools: {} });
  assert.equal((await handleMessage({ jsonrpc: '2.0', id: 2, method: 'initialize', params: { protocolVersion: '1999' } }, ctx)).result.protocolVersion, '2025-06-18');
  assert.equal(await handleMessage({ jsonrpc: '2.0', method: 'notifications/initialized' }, ctx), null);
  assert.deepEqual((await handleMessage({ jsonrpc: '2.0', id: 3, method: 'ping' }, ctx)).result, {});
  const list = await handleMessage({ jsonrpc: '2.0', id: 4, method: 'tools/list' }, ctx);
  assert.equal(list.result.tools.length, TOOLS.length);
  assert.ok(list.result.tools.every((t) => !('action' in t)));
  assert.equal((await handleMessage({ jsonrpc: '2.0', id: 5, method: 'resources/list' }, ctx)).error.code, -32601);
  assert.equal((await handleMessage({ id: 6, method: 'ping' }, ctx)).error.code, -32600);
});

test('stdio 서버: 한 줄씩 받아 한 줄씩 답한다', async () => {
  const home = mkdtempSync(join(tmpdir(), 'think-relay-'));
  try {
    const server = fileURLToPath(new URL('../src/server.mjs', import.meta.url));
    const child = spawn(process.execPath, [server], {
      env: { ...process.env, THINK_RELAY_TOKEN: '', HOME: home, USERPROFILE: home },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let out = '';
    child.stdout.on('data', (d) => (out += d));
    child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} })}\n`);
    child.stdin.write('not json\n');
    child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'think_get_memory', arguments: { id: 'x' } } })}\n`);
    child.stdin.end();
    await new Promise((resolve) => child.on('close', resolve));
    const lines = out.trim().split('\n').map((l) => JSON.parse(l));
    assert.equal(lines.find((l) => l.id === 1).result.serverInfo.name, 'think-relay');
    assert.equal(lines.find((l) => l.error?.code === -32700).id, null);
    const call = lines.find((l) => l.id === 2);
    assert.equal(call.result.isError, true);
    assert.match(call.result.content[0].text, /token_missing/);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
});
