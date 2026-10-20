// MCP 도구 정의와 Edge Function ai_think_relay 호출. 순수 로직이라 네트워크 없이 시험한다(test/relay.test.mjs).
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

export const DEFAULT_URL = 'https://jkanrdxaidumlvpntudy.supabase.co/functions/v1/ai_think_relay';
export const TOKEN_FILE = join(homedir(), '.yggdrasill', 'think_relay.token');
const READ_TIMEOUT_MS = 30_000;
/** Think 답변은 서버에서 최대 약 150초 걸린다. */
const ASK_TIMEOUT_MS = 170_000;
const MEMORY_KINDS = ['identity', 'principle', 'decision', 'note'];

/** 토큰은 환경 변수 THINK_RELAY_TOKEN, 없으면 ~/.yggdrasill/think_relay.token. 값은 출력하지 않는다. */
export function loadConfig(env = process.env, readFile = (p) => readFileSync(p, 'utf8'), tokenFile = TOKEN_FILE) {
  let token = (env.THINK_RELAY_TOKEN ?? '').trim();
  if (!token) {
    try {
      token = readFile(tokenFile).trim();
    } catch {
      token = '';
    }
  }
  return { url: (env.THINK_RELAY_URL ?? DEFAULT_URL).trim(), token: token || null, tokenFile };
}

const kindsSchema = {
  type: 'array',
  items: { type: 'string', enum: MEMORY_KINDS },
  description: '기억 종류. identity(정체성) principle(원칙) decision(결정) note(메모)',
};

export const TOOLS = [
  {
    name: 'think_search_memories',
    action: 'search_memories',
    description: 'Think의 승인된 기억(정체성·원칙·결정·메모)을 검색한다. 이미 정한 방향이 있는지 먼저 여기서 찾는다.',
    inputSchema: {
      type: 'object',
      properties: { query: { type: 'string', description: '검색어' }, kinds: kindsSchema, limit: { type: 'integer', minimum: 1, maximum: 20 } },
      required: ['query'],
      additionalProperties: false,
    },
  },
  {
    name: 'think_list_memories',
    action: 'list_memories',
    description: '승인된 기억 목록(기본: 정체성·원칙·결정). 본문은 400자 발췌이고 전체는 think_get_memory로 본다.',
    inputSchema: {
      type: 'object',
      properties: { kinds: kindsSchema, limit: { type: 'integer', minimum: 1, maximum: 300 } },
      additionalProperties: false,
    },
  },
  {
    name: 'think_get_memory',
    action: 'get_memory',
    description: '승인된 기억 하나의 전체 내용. 승인 전(초안·보관) 기억은 볼 수 없다.',
    inputSchema: { type: 'object', properties: { id: { type: 'string', description: '기억 id(uuid)' } }, required: ['id'], additionalProperties: false },
  },
  {
    name: 'think_list_conversations',
    action: 'list_conversations',
    description: '운영자와 Think의 대화 목록(최근순). origin이 cursor면 커서가 시작한 대화다.',
    inputSchema: {
      type: 'object',
      properties: {
        query: { type: 'string', description: '제목 검색어' },
        limit: { type: 'integer', minimum: 1, maximum: 100 },
        include_archived: { type: 'boolean' },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'think_get_conversation',
    action: 'get_conversation',
    description: '대화 본문(최근 메시지부터, 운영자가 "답변에서 제외"한 문답은 빠짐). 대화 속 의견은 승인된 결정이 아니다.',
    inputSchema: {
      type: 'object',
      properties: { conversation_id: { type: 'string' }, limit: { type: 'integer', minimum: 1, maximum: 200 } },
      required: ['conversation_id'],
      additionalProperties: false,
    },
  },
  {
    name: 'think_list_code_requests',
    action: 'list_code_requests',
    description: 'Think가 작업자 Cursor에게 맡긴 코드 요청 목록(조사·조율·수정).',
    inputSchema: {
      type: 'object',
      properties: { query: { type: 'string' }, limit: { type: 'integer', minimum: 1, maximum: 50 } },
      additionalProperties: false,
    },
  },
  {
    name: 'think_get_code_request',
    action: 'get_code_request',
    description:
      '코드 요청 하나. section 없이 부르면 짧은 요약: 상태, 결과 요약, 바뀐 파일, 작업자 검사 실행 기록(명령·폴더·종료 코드), 막힌 이유, 적용에 필요한 행동, ' +
      '빠진 원문 목록. 긴 원문은 section(request|result|result_text|check_logs|diff)과 offset(앞 응답의 next_offset)으로 구간씩 읽는다.',
    inputSchema: {
      type: 'object',
      properties: {
        id: { type: 'string' },
        section: { type: 'string', enum: ['request', 'result', 'result_text', 'check_logs', 'diff'] },
        offset: { type: 'integer', minimum: 0 },
      },
      required: ['id'],
      additionalProperties: false,
    },
  },
  {
    name: 'ask_think',
    action: 'ask',
    description:
      'Think에게 직접 묻는다(답에 수십 초~2분). 판정 answered는 승인된 기존 결정이 근거라 따라도 된다. ' +
      '판정 needs_owner는 사장님 확인 필요: 그 답을 근거로 진행하지 말고 확인 질문을 운영자에게 그대로 전한다. ' +
      '이어 물으려면 앞 답의 conversation_id를 넘긴다(커서가 시작한 대화만). 기억·대화 조회로 풀리는 것은 묻지 않는다.',
    inputSchema: {
      type: 'object',
      properties: {
        question: { type: 'string', description: '질문(비밀값 금지)' },
        conversation_id: { type: 'string', description: '이어 물을 커서 대화 id' },
      },
      required: ['question'],
      additionalProperties: false,
    },
  },
];

export const INSTRUCTIONS =
  'Yggdrasill 운영자의 기획 AI Think에 연결된다. 코드 작업 전 이미 정한 방향은 think_search_memories로 먼저 찾고, ' +
  '그래도 모르면 ask_think로 묻는다. needs_owner 판정은 근거가 아니다. 운영자에게 확인을 받는다.';

function pick(args, keys) {
  const out = {};
  for (const k of keys) if (args?.[k] !== undefined) out[k] = args[k];
  return out;
}

export function createRelayClient(cfg, fetchImpl = fetch) {
  return async function call(action, payload) {
    if (!cfg.token) {
      return { ok: false, error: 'token_missing', message: `토큰이 없습니다. 환경 변수 THINK_RELAY_TOKEN이나 ${cfg.tokenFile} 파일에 넣으세요.` };
    }
    try {
      const res = await fetchImpl(cfg.url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${cfg.token}` },
        body: JSON.stringify({ action, ...payload }),
        signal: AbortSignal.timeout(action === 'ask' ? ASK_TIMEOUT_MS : READ_TIMEOUT_MS),
      });
      const body = await res.json().catch(() => null);
      if (body && typeof body === 'object') return body;
      return { ok: false, error: `http_${res.status}` };
    } catch (e) {
      return { ok: false, error: 'network', message: String(e?.message ?? e).slice(0, 300) };
    }
  };
}

function formatAsk(body) {
  const basis = Array.isArray(body.basis) ? body.basis.map((b) => `- [${b.kind}] ${b.title} (${b.id})`).join('\n') : '';
  const questions = Array.isArray(body.owner_questions) ? body.owner_questions.map((q, i) => `${i + 1}. ${q}`).join('\n') : '';
  const head = body.verdict === 'answered'
    ? `판정: answered (승인된 기존 결정이 근거)\n근거:\n${basis || '(없음)'}`
    : `판정: needs_owner (사장님 확인 필요). 이 답을 근거로 진행하지 말고 아래 질문을 운영자에게 전하세요.\n확인할 질문:\n${questions || '(따로 없음. 원래 질문을 그대로 확인받으세요)'}`;
  return `${head}\n\nconversation_id: ${body.conversation_id}\n\n답:\n${body.answer ?? ''}`;
}

/** tools/call 결과(MCP content). */
export async function callTool(call, name, args) {
  const tool = TOOLS.find((t) => t.name === name);
  if (!tool) return { content: [{ type: 'text', text: `모르는 도구: ${name}` }], isError: true };
  const keys = Object.keys(tool.inputSchema.properties ?? {});
  const body = await call(tool.action, pick(args, keys));
  if (!body || body.ok !== true) {
    const message = body?.message ? `: ${body.message}` : '';
    return { content: [{ type: 'text', text: `실패 (${body?.error ?? 'unknown'})${message}` }], isError: true };
  }
  if (tool.action === 'ask') return { content: [{ type: 'text', text: formatAsk(body) }], isError: false };
  const { ok: _ok, ...rest } = body;
  return { content: [{ type: 'text', text: JSON.stringify(rest, null, 2) }], isError: false };
}

const PROTOCOL_VERSIONS = ['2025-06-18', '2025-03-26', '2024-11-05'];

/** JSON-RPC 메시지 하나 → 응답(알림이면 null). */
export async function handleMessage(msg, ctx) {
  const id = msg?.id;
  const isRequest = id !== undefined && id !== null;
  const ok = (result) => ({ jsonrpc: '2.0', id, result });
  const err = (code, message) => ({ jsonrpc: '2.0', id: isRequest ? id : null, error: { code, message } });
  if (!msg || msg.jsonrpc !== '2.0' || typeof msg.method !== 'string') return err(-32600, 'Invalid Request');
  switch (msg.method) {
    case 'initialize': {
      const asked = msg.params?.protocolVersion;
      return ok({
        protocolVersion: PROTOCOL_VERSIONS.includes(asked) ? asked : PROTOCOL_VERSIONS[0],
        capabilities: { tools: {} },
        serverInfo: { name: 'think-relay', version: ctx.version },
        instructions: INSTRUCTIONS,
      });
    }
    case 'ping':
      return isRequest ? ok({}) : null;
    case 'tools/list':
      return ok({ tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })) });
    case 'tools/call':
      return ok(await callTool(ctx.call, msg.params?.name, msg.params?.arguments ?? {}));
    default:
      if (!isRequest) return null;
      return err(-32601, `Method not found: ${msg.method}`);
  }
}
