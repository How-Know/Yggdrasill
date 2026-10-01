// 비밀 파일(.env*, env.local.json, *.pem, *.key, supabase/.temp) 읽기·쓰기를 막는다.
// IDE 에이전트와 코드 작업자(Cursor SDK) 모두에 적용된다. 설계: docs/architecture/ai-code-bridge.md
// 작업자 수정 모드는 환경 변수 CODE_BRIDGE_WRITE_ROOT(복사본 폴더)를 준다. 그러면 그 밖의 경로는 읽기도 막고,
// .git과 이 훅 자신(.cursor/hooks*)은 고치지 못하게 한다.
// Windows는 입력 앞에 BOM을 붙인다. 한국어 Windows에서는 입력이 CP949로 한 번 잘못 읽혀
// 홀수 바이트 한글 바로 뒤의 따옴표가 사라지기도 한다. 그러면 JSON 대신 경로 칸만 골라 더 엄격하게 본다.
// 읽기에서 경로를 하나도 찾지 못하면 막는다(허용으로 처리하면 모두 통과된다).
import { readFileSync } from 'node:fs';
import { isAbsolute, relative, resolve } from 'node:path';

const SECRET_NAME = /^(\.env(\.(?!example$)[^\\/]+)?|env\.local\.json|.+\.(pem|key))$/i;
const SECRET_DIR = /(^|[\\/])supabase[\\/]\.temp([\\/]|$)/i;
const PATH_KEY = /path|file|dir|glob|target/i;
// 깨진 입력용. 이름 앞 글자가 먹혔을 수 있어 "한글 바로 뒤 env/pem/key"도 비밀로 본다.
const LOOSE_SECRET =
  /\.env(?![A-Za-z0-9_])(?!\.example(?![A-Za-z0-9_.-]))|env\.local\.json|\.(pem|key)(?![A-Za-z0-9_])|supabase[\\/]+\.temp|[^\x00-\x7f](env|pem|key)(?![A-Za-z0-9_])/i;
const WRITE_TOOL = /^(Write|Delete|Edit|StrReplace|MultiEdit)$/;
const ROOT = (process.env.CODE_BRIDGE_WRITE_ROOT ?? '').trim() ? resolve(process.env.CODE_BRIDGE_WRITE_ROOT.trim()) : null;

function deny(message) {
  process.stdout.write(JSON.stringify({
    permission: 'deny',
    user_message: message,
    agent_message: `${message} Do not try to do it another way.`,
  }));
  process.exit(2);
}

function allow() {
  process.stdout.write(JSON.stringify({ permission: 'allow' }));
  process.exit(0);
}

const clean = (value) => value.trim().replace(/^["']|["']$/g, '');

function isSecret(value) {
  const s = clean(value);
  if (!s) return false;
  const name = s.split(/[\\/]/).pop() ?? '';
  return SECRET_NAME.test(name) || SECRET_DIR.test(s);
}

/** 복사본 밖을 가리키면 true. 상대 경로는 복사본 기준. 상대 glob은 `..`이 있을 때만 밖으로 본다. */
function isOutside(value, key) {
  const s = clean(value);
  if (!s) return false;
  if (/glob/i.test(key) && !isAbsolute(s) && !/(^|[\\/])\.\.([\\/]|$)/.test(s)) return false;
  const rel = relative(ROOT, resolve(ROOT, s));
  return rel === '..' || rel.startsWith(`..\\`) || rel.startsWith('../') || isAbsolute(rel);
}

function isProtected(value) {
  const rel = relative(ROOT, resolve(ROOT, clean(value))).replace(/\\/g, '/');
  return /^\.cursor\/hooks(\.json$|\/)/i.test(rel) || /(^|\/)\.git(\/|$)/.test(rel);
}

function decode() {
  try {
    const raw = readFileSync(0);
    const text = raw.length >= 2 && raw[0] === 0xff && raw[1] === 0xfe ? raw.toString('utf16le') : raw.toString('utf8');
    return text.replace(/^\uFEFF/, '');
  } catch {
    return '';
  }
}

/** JSON으로 읽히지 않는 입력에서 경로 칸 [키, 값]만 모은다. 파일 내용이 없는 입력이면 전체도 함께 본다. */
function salvage(text) {
  const values = [];
  for (const m of text.matchAll(/(?<!\\)"([A-Za-z_]+)"\s*:\s*"((?:[^"\\]|\\.)*)/g)) {
    if (PATH_KEY.test(m[1])) values.push([m[1], m[2].replace(/\\\\/g, '\\')]);
  }
  if (values.length > 0 && !/(?<!\\)"content"\s*:/.test(text)) values.push(['', text]);
  return values;
}

function check(entries, isWrite, loose) {
  const secret = loose ? ([, v]) => LOOSE_SECRET.test(v) : ([, v]) => isSecret(v);
  if (entries.some(secret)) deny('Secret files (.env, env.local.json, keys) are blocked.');
  if (!ROOT) allow();
  const pathEntries = entries.filter(([k]) => k !== '');
  if (pathEntries.some(([k, v]) => isOutside(v, k))) deny('Only files inside the working copy can be used.');
  if (isWrite && pathEntries.some(([, v]) => isProtected(v))) deny('.git and .cursor/hooks cannot be changed.');
  allow();
}

const text = decode();
let input = null;
try {
  input = JSON.parse(text);
} catch {
  input = null;
}

if (input === null || typeof input !== 'object') {
  const isWrite = /"tool_name"\s*:\s*"(Write|Delete|Edit|StrReplace|MultiEdit)"/.test(text);
  const values = /^\s*\{/.test(text) ? salvage(text) : [];
  // IDE에서 파일을 쓰는 입력이 깨졌을 때는 비밀 경로만 본다(읽기처럼 전부 막으면 한글 편집이 멈춘다).
  if (values.length === 0 && !(isWrite && !ROOT)) deny('Hook could not read its input, so the action was blocked.');
  check(values, isWrite, true);
}

const entries = [];
if (typeof input.file_path === 'string') entries.push(['file_path', input.file_path]);
const toolInput = input.tool_input && typeof input.tool_input === 'object' ? input.tool_input : {};
for (const [key, value] of Object.entries(toolInput)) {
  if (!PATH_KEY.test(key)) continue;
  if (typeof value === 'string') entries.push([key, value]);
  else if (Array.isArray(value)) entries.push(...value.filter((v) => typeof v === 'string').map((v) => [key, v]));
}
check(entries, WRITE_TOOL.test(String(input.tool_name ?? '')), false);
