// Think 연결 MCP 서버(stdio). Cursor 사용자 설정(~/.cursor/mcp.json)에 등록해 운영자 작업창에서만 쓴다.
// 저장소 .cursor/mcp.json에는 넣지 않는다(작업자 Cursor가 settingSources ['project']로 불러오게 된다).
// 설계: docs/architecture/ai-think.md §12
import { readFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { createRelayClient, handleMessage, loadConfig } from './relay.mjs';

const VERSION = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')).version;
const cfg = loadConfig();
const ctx = { version: VERSION, call: createRelayClient(cfg) };

if (!cfg.token) console.error(`[think-relay] 토큰이 없습니다. THINK_RELAY_TOKEN이나 ${cfg.tokenFile}에 넣으세요.`);

const send = (msg) => process.stdout.write(`${JSON.stringify(msg)}\n`);
const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });

rl.on('line', (line) => {
  if (!line.trim()) return;
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } });
    return;
  }
  handleMessage(msg, ctx)
    .then((reply) => {
      if (reply) send(reply);
    })
    .catch((e) => {
      console.error('[think-relay]', e?.message ?? e);
      if (msg?.id != null) send({ jsonrpc: '2.0', id: msg.id, error: { code: -32603, message: 'Internal error' } });
    });
});
