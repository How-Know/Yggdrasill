import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { test } from 'node:test';

const HOOK = fileURLToPath(new URL('../../../.cursor/hooks/deny-secrets.mjs', import.meta.url));

function runHook(input, { bom = false, root = null } = {}) {
  const text = typeof input === 'string' ? input : JSON.stringify(input);
  const buf = Buffer.concat([bom ? Buffer.from([0xef, 0xbb, 0xbf]) : Buffer.alloc(0), Buffer.from(text, 'utf8')]);
  const env = { ...process.env };
  delete env.CODE_BRIDGE_WRITE_ROOT;
  if (root) env.CODE_BRIDGE_WRITE_ROOT = root;
  const res = spawnSync(process.execPath, [HOOK], { input: buf, encoding: 'utf8', env });
  const out = res.stdout ? JSON.parse(res.stdout) : null;
  return { code: res.status, permission: out?.permission };
}

const read = (path) => ({ hook_event_name: 'preToolUse', tool_name: 'Read', tool_input: { file_path: path } });

test('비밀 파일 읽기는 막는다 (Windows BOM 입력 포함)', () => {
  for (const path of [
    'C:\\repo\\.env',
    'C:\\repo\\apps\\x\\.env.local',
    '/repo/.env.production',
    'C:\\repo\\apps\\yggdrasill\\env.local.json',
    'C:\\repo\\certs\\server.key',
    'C:\\repo\\certs\\cert.pem',
    'C:\\repo\\supabase\\.temp\\cli-latest',
  ]) {
    assert.deepEqual(runHook(read(path), { bom: true }), { code: 2, permission: 'deny' }, path);
  }
});

test('일반 파일과 .env.example은 허용한다', () => {
  for (const path of ['C:\\repo\\src\\app.dart', 'C:\\repo\\.env.example', 'C:\\repo\\docs\\environment.md', 'C:\\repo\\lib\\keyboard.dart']) {
    assert.deepEqual(runHook(read(path), { bom: true }), { code: 0, permission: 'allow' }, path);
  }
});

test('검색은 경로만 본다: ".env" 글자 검색은 허용, 비밀 파일을 겨눈 검색은 막는다', () => {
  const grep = (toolInput) => ({ hook_event_name: 'preToolUse', tool_name: 'Grep', tool_input: toolInput });
  assert.equal(runHook(grep({ pattern: '\\.env', file_path: 'C:\\repo' })).permission, 'allow');
  assert.equal(runHook(grep({ pattern: 'KEY', file_path: 'C:\\repo\\.env' })).permission, 'deny');
  assert.equal(runHook(grep({ pattern: 'x', glob: '.env.local' })).permission, 'deny');
});

test('beforeReadFile 형식(file_path가 최상위)도 막는다', () => {
  assert.equal(runHook({ hook_event_name: 'beforeReadFile', file_path: 'C:\\repo\\.env', content: 'X=1' }).permission, 'deny');
});

test('입력을 해석하지 못하면 막는다', () => {
  assert.deepEqual(runHook('not json'), { code: 2, permission: 'deny' });
  assert.deepEqual(runHook(''), { code: 2, permission: 'deny' });
  assert.deepEqual(runHook('{"a":'), { code: 2, permission: 'deny' });
});

// 한국어 Windows에서 실제로 온 모양: 홀수 바이트 한글("전") 뒤의 닫는 따옴표가 사라진다.
test('따옴표가 먹힌 입력: 경로 칸만 보고 판단한다', () => {
  const broken = (pattern, path) =>
    `{"hook_event_name":"preToolUse","tool_name":"Grep","tool_input":{"pattern":"${pattern}\uFFFD,"path":"${path}"}}`;
  assert.deepEqual(runHook(broken('구현 전', 'C:\\\\repo\\\\docs'), { bom: true }), { code: 0, permission: 'allow' });
  assert.equal(runHook(broken('전', 'C:\\\\repo\\\\.env'), { bom: true }).permission, 'deny');
  assert.equal(runHook(broken('전', 'C:\\\\repo\\\\supabase\\\\.temp'), { bom: true }).permission, 'deny');
  assert.equal(runHook(broken('전', 'C:\\\\repo\\\\certs\\\\전\uFFFDpem'), { bom: true }).permission, 'deny');
  assert.equal(runHook(broken('전', 'C:\\\\repo\\\\.env.example'), { bom: true }).permission, 'allow');
});

const write = (path, tool = 'Write') => ({ hook_event_name: 'preToolUse', tool_name: tool, tool_input: { file_path: path, content: '.env KEY=1' } });
const ROOT = 'C:\\tmp\\ygg-code-bridge\\req';

test('IDE: 쓰기는 비밀 경로만 막는다 (내용에 .env 글자가 있어도 허용)', () => {
  assert.equal(runHook(write('C:\\repo\\lib\\a.dart')).permission, 'allow');
  assert.equal(runHook(write('C:\\repo\\.env')).permission, 'deny');
  assert.equal(runHook(write('C:\\repo\\supabase\\.temp\\x', 'Delete')).permission, 'deny');
  assert.equal(runHook(write('C:\\elsewhere\\a.dart')).permission, 'allow', '작업자 모드가 아니면 폴더 제한 없음');
});

test('IDE: 한글 때문에 깨진 쓰기 입력은 막지 않되, 비밀 경로면 막는다', () => {
  const broken = (path) =>
    `{"hook_event_name":"preToolUse","tool_name":"Write","tool_input":{"file_path":"${path}","content":"전\uFFFD}}`;
  assert.equal(runHook(broken('C:\\\\repo\\\\lib\\\\a.dart'), { bom: true }).permission, 'allow');
  assert.equal(runHook(broken('C:\\\\repo\\\\.env'), { bom: true }).permission, 'deny');
  assert.equal(runHook('{"hook_event_name":"preToolUse","tool_name":"Write","tool_input":{"content":"전\uFFFD}}', { bom: true }).permission, 'allow');
});

test('작업자 수정 모드: 복사본 밖은 읽기·쓰기 모두 막는다', () => {
  const opt = { root: ROOT };
  assert.equal(runHook(read(`${ROOT}\\lib\\a.dart`), opt).permission, 'allow');
  assert.equal(runHook(read('lib\\a.dart'), opt).permission, 'allow', '상대 경로는 복사본 기준');
  assert.equal(runHook(read('C:\\Users\\harry\\Yggdrasill\\lib\\a.dart'), opt).permission, 'deny');
  assert.equal(runHook(read(`${ROOT}\\..\\other\\a.dart`), opt).permission, 'deny');
  assert.equal(runHook(read('C:\\tmp\\ygg-code-bridge\\req2\\a.dart'), opt).permission, 'deny', '이름이 비슷한 옆 폴더');
  assert.equal(runHook(write('C:\\Users\\harry\\x.dart'), opt).permission, 'deny');
  const grep = (toolInput) => ({ hook_event_name: 'preToolUse', tool_name: 'Grep', tool_input: toolInput });
  assert.equal(runHook(grep({ pattern: 'x', glob: '**/*.dart' }), opt).permission, 'allow');
  assert.equal(runHook(grep({ pattern: 'x', glob: '../**/*.dart' }), opt).permission, 'deny');
  assert.equal(runHook(grep({ pattern: 'x', path: 'C:\\' }), opt).permission, 'deny');
  assert.equal(runHook({ hook_event_name: 'beforeReadFile', file_path: 'C:\\Windows\\win.ini', content: 'x' }, opt).permission, 'deny');
});

test('작업자 수정 모드: .git과 훅 파일은 고칠 수 없고, 깨진 입력은 막는다', () => {
  const opt = { root: ROOT };
  assert.equal(runHook(write(`${ROOT}\\.cursor\\hooks.json`), opt).permission, 'deny');
  assert.equal(runHook(write(`${ROOT}\\.cursor\\hooks\\deny-secrets.mjs`, 'Delete'), opt).permission, 'deny');
  assert.equal(runHook(write(`${ROOT}\\.git\\config`), opt).permission, 'deny');
  assert.equal(runHook(read(`${ROOT}\\.cursor\\hooks.json`), opt).permission, 'allow', '읽기는 된다');
  assert.equal(runHook(write(`${ROOT}\\.env`), opt).permission, 'deny');
  assert.equal(runHook('{"hook_event_name":"preToolUse","tool_name":"Write","tool_input":{"content":"전\uFFFD}}', { bom: true, root: ROOT }).permission, 'deny');
  const broken = `{"hook_event_name":"preToolUse","tool_name":"Read","tool_input":{"file_path":"C:\\\\Users\\\\harry\\\\a전\uFFFD}}`;
  assert.equal(runHook(broken, { bom: true, root: ROOT }).permission, 'deny');
});

test('따옴표가 먹힌 beforeReadFile: 파일 내용이 아니라 경로로 판단한다', () => {
  const broken = (path) =>
    `{"hook_event_name":"beforeReadFile","file_path":"${path}","content":"entry.key 전\uFFFD, x.pem"}`;
  assert.equal(runHook(broken('C:\\\\repo\\\\lib\\\\a.dart'), { bom: true }).permission, 'allow');
  assert.equal(runHook(broken('C:\\\\repo\\\\.env'), { bom: true }).permission, 'deny');
  assert.equal(runHook('{"hook_event_name":"beforeReadFile","content":"전\uFFFD}', { bom: true }).permission, 'deny');
});
