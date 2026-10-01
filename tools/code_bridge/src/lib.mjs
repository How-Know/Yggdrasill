// 작업자의 순수 로직. SDK·네트워크 없이 시험한다(test/lib.test.mjs).
import { hostname } from 'node:os';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const PROMPT_VERSION = 'code_bridge.v2';
export const READ_ONLY_TOOLS = ['read', 'grep', 'glob', 'ls'];
/** 수정 모드. 셸은 주지 않는다(빌드·테스트·git 실행 불가). */
export const CHANGE_TOOLS = ['read', 'grep', 'glob', 'ls', 'edit', 'delete'];
export const MAX_DIFF_CHARS = 400_000;

const SECRET_NAME = /^(\.env(\.(?!example$)[^/]+)?|env\.local\.json|.+\.(pem|key))$/i;
/** 수정 결과에 들어가면 안 되는 경로(저장소 기준, / 구분). */
export function isSecretPath(path) {
  const p = String(path ?? '').replace(/\\/g, '/').replace(/^\.\//, '');
  const name = p.split('/').pop() ?? '';
  return SECRET_NAME.test(name) || /(^|\/)supabase\/\.temp(\/|$)/i.test(p);
}

/** 수정 모드에서 건드리면 안 되는 경로. 비밀 경로 + 차단 훅 자신. */
export function isProtectedPath(path) {
  const p = String(path ?? '').replace(/\\/g, '/').replace(/^\.\//, '');
  return isSecretPath(p) || /^\.cursor\/hooks(\.json$|\/)/i.test(p) || /(^|\/)\.git(\/|$)/.test(p);
}
export const FEASIBILITY = ['possible', 'possible_with_changes', 'not_recommended', 'unclear'];
export const RISK_LEVELS = ['low', 'medium', 'high'];

const DEFAULT_URL = 'https://jkanrdxaidumlvpntudy.supabase.co/functions/v1/ai_code_bridge';
const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

export class ConfigError extends Error {}

function positiveInt(raw, fallback, min, max) {
  const n = Number.parseInt(raw ?? '', 10);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(Math.max(n, min), max);
}

export function loadConfig(env) {
  const token = (env.CODE_BRIDGE_WORKER_TOKEN ?? '').trim();
  const apiKey = (env.CURSOR_API_KEY ?? '').trim();
  if (!token) throw new ConfigError('CODE_BRIDGE_WORKER_TOKEN 환경 변수가 없습니다.');
  if (!apiKey) throw new ConfigError('CURSOR_API_KEY 환경 변수가 없습니다.');
  const host = hostname().toLowerCase().replace(/[^a-z0-9._-]/g, '-').slice(0, 40) || 'pc';
  const workerId = (env.CODE_BRIDGE_WORKER_ID ?? `pc-${host}`).trim();
  if (!/^[A-Za-z0-9._-]{1,64}$/.test(workerId)) throw new ConfigError('CODE_BRIDGE_WORKER_ID 형식이 올바르지 않습니다.');
  return {
    url: (env.CODE_BRIDGE_URL ?? DEFAULT_URL).trim(),
    anonKey: (env.CODE_BRIDGE_ANON_KEY ?? '').trim() || null,
    token,
    apiKey,
    workerId,
    model: (env.CODE_BRIDGE_MODEL ?? 'composer-2.5').trim(),
    repo: resolve(env.CODE_BRIDGE_REPO ?? REPO_ROOT),
    pollMs: positiveInt(env.CODE_BRIDGE_POLL_MS, 10_000, 3_000, 300_000),
    heartbeatMs: 30_000,
    roundTimeoutMs: positiveInt(env.CODE_BRIDGE_ROUND_TIMEOUT_MS, 15 * 60_000, 60_000, 60 * 60_000),
  };
}

function list(value) {
  if (!Array.isArray(value)) return [];
  return value.map((v) => (typeof v === 'string' ? v.trim() : '')).filter(Boolean);
}

function text(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function bullets(items, empty = '(없음)') {
  return items.length ? items.map((s, i) => `${i + 1}. ${s}`).join('\n') : empty;
}

export function buildPrompt(job) {
  const r = job.request && typeof job.request === 'object' ? job.request : {};
  const refs = Array.isArray(r.memory_refs) ? r.memory_refs : [];
  const refLines = refs
    .map((m) => (m && typeof m === 'object' ? `- [${text(m.kind) || '기억'}] ${text(m.title)} (v${m.version ?? '?'}): ${text(m.content)}` : ''))
    .filter((s) => s.trim() !== '-');
  return `너는 Yggdrasill 저장소의 코드 조사 담당이다. 코드를 고치지 않고 읽고 조사만 한다.
파일을 만들거나 고치거나 명령을 실행하지 않는다. 비밀 파일(.env, env.local.json, 키 파일)은 읽지 않는다.
판단 기준은 아래 "관련 결정·원칙"과 저장소 규칙(AGENTS.md, .cursor/rules, docs/architecture)이다.
기준과 요청이 부딪히면 제안에서 그 점을 밝힌다. 네가 결정하지 않는다. 결정은 운영자가 한다.

## 요청
제목: ${text(job.title)}
목표: ${text(r.goal)}

배경 (요청이 나온 Think 대화):
${text(r.background) || '(없음)'}

확인할 질문:
${bullets(list(r.questions))}

우선 볼 폴더 (없으면 저장소 전체):
${bullets(list(r.focus_paths))}

제약:
${bullets(list(r.constraints))}

하지 말 것:
${bullets(list(r.do_not))}

관련 결정·원칙:
${refLines.length ? refLines.join('\n') : '(없음)'}

## 답변 형식
조사를 마치면 답변 끝에 아래 모양의 JSON을 \`\`\`json 코드 블록 하나로 낸다. 설명은 앞에 써도 된다.
{
  "summary": "한두 문장 결론",
  "feasibility": "possible | possible_with_changes | not_recommended | unclear 중 하나",
  "answers": [{ "question": "요청의 질문", "answer": "답" }],
  "findings": [{ "point": "코드에서 확인한 사실", "evidence": [{ "path": "저장소 기준 경로", "lines": "10-24" }] }],
  "proposals": [{ "title": "제안 이름", "change": "무엇을 어떻게 바꿀지(적용하지 않음)", "files": ["경로"], "risk": "low | medium | high" }],
  "risks": ["위험이나 부작용"],
  "questions_for_think": ["Think나 운영자에게 되묻는 질문"]
}
코드로 확인하지 못한 추측은 findings에 넣지 말고 questions_for_think에 넣는다.`;
}

/** 2회차: 작업자는 새 에이전트라 앞 회차를 모른다. 원래 요청 뒤에 서버가 만든 요약·추가 질문을 붙인다. */
export function buildFollowupPrompt(job) {
  return `${buildPrompt(job)}\n\n${text(job.followup_prompt)}`;
}

export function buildChangePrompt(job) {
  const r = job.request && typeof job.request === 'object' ? job.request : {};
  const refs = Array.isArray(r.memory_refs) ? r.memory_refs : [];
  const refLines = refs
    .map((m) => (m && typeof m === 'object' ? `- [${text(m.kind) || '기억'}] ${text(m.title)} (v${m.version ?? '?'}): ${text(m.content)}` : ''))
    .filter((s) => s.trim() !== '-');
  const base = r.based_on && typeof r.based_on === 'object' ? r.based_on : null;
  const baseLines = base
    ? [
        `조사 요청 "${text(base.title)}"의 결론: ${text(base.summary) || '(없음)'}`,
        ...objects(base.proposals).map((p) => `- 제안 "${text(p.title)}": ${text(p.change)}`),
      ].join('\n')
    : '(없음)';
  return `너는 Yggdrasill 저장소의 코드 수정 담당이다. 지금 폴더는 운영자 작업 폴더의 복사본이다. 여기서 요청대로 코드를 고친다.
- 읽기·검색·편집·삭제 도구만 있다. 명령을 실행할 수 없다(빌드·테스트·git 불가).
- 이 폴더 밖의 파일은 읽거나 쓰지 않는다. 비밀 파일(.env, env.local.json, 키 파일), .git, .cursor/hooks는 건드리지 않는다.
- 요청 범위만 고친다. 관련 없는 리팩터링, 포맷 변경, 파일 이동은 하지 않는다.
- 저장소 규칙(AGENTS.md, .cursor/rules, docs/architecture, UI면 docs/design-system.md)을 따른다.
- 커밋하지 않는다. 변경은 작업자가 diff로 모아 운영자에게 보여 주고, 적용은 운영자가 정한다.
- 판단 기준은 아래 "관련 결정·원칙"이다. 요청과 부딪히면 고치지 말고 questions_for_think에 적는다.

## 요청
제목: ${text(job.title)}
목표: ${text(r.goal)}

바꿀 내용:
${bullets(list(r.instructions))}

근거가 된 조사:
${baseLines}

고칠 폴더나 파일 (없으면 필요한 곳만):
${bullets(list(r.focus_paths))}

제약:
${bullets(list(r.constraints))}

하지 말 것:
${bullets(list(r.do_not))}

관련 결정·원칙:
${refLines.length ? refLines.join('\n') : '(없음)'}

## 답변 형식
수정을 마치면 답변 끝에 아래 모양의 JSON을 \`\`\`json 코드 블록 하나로 낸다.
{
  "summary": "무엇을 바꿨는지 한두 문장",
  "changes": [{ "path": "저장소 기준 경로", "what": "바꾼 내용" }],
  "risks": ["위험이나 확인할 점"],
  "checks": ["운영자가 적용 뒤 돌려 볼 검사 (예: flutter analyze 파일 경로)"],
  "questions_for_think": ["고치지 못했거나 판단이 필요한 점"]
}`;
}

/** 작업 종류에 맞는 프롬프트. */
export function promptFor(job) {
  if (job.mode === 'change') return buildChangePrompt(job);
  return job.followup_prompt ? buildFollowupPrompt(job) : buildPrompt(job);
}

function objects(value) {
  return Array.isArray(value) ? value.filter((v) => v && typeof v === 'object' && !Array.isArray(v)) : [];
}

/** 수정 결과의 JSON 블록. 요약이 없어도 diff는 쓸 수 있으므로 ok=false와 함께 빈 값을 돌려준다. */
export function parseChangeResult(raw) {
  const block = typeof raw === 'string' ? lastJsonBlock(raw) : null;
  let data = null;
  try {
    data = block ? JSON.parse(block) : null;
  } catch {
    data = null;
  }
  const d = data && typeof data === 'object' && !Array.isArray(data) ? data : {};
  const summary = text(d.summary);
  return {
    ok: Boolean(summary),
    value: {
      summary,
      changes: objects(d.changes).map((c) => ({ path: text(c.path), what: text(c.what) })).filter((c) => c.path || c.what),
      risks: list(d.risks),
      checks: list(d.checks),
      questions_for_think: list(d.questions_for_think),
    },
  };
}

/** `git diff --numstat -z` 출력 → 파일별 추가·삭제 줄 수. 바이너리는 -1. */
export function parseNumstat(raw) {
  const files = [];
  const parts = String(raw ?? '').split('\0');
  for (let i = 0; i < parts.length; i++) {
    const line = parts[i];
    if (!line) continue;
    const m = /^(-|\d+)\t(-|\d+)\t(.*)$/.exec(line);
    if (!m) continue;
    let path = m[3];
    if (path === '') {
      // 이름 바뀜: 다음 두 칸이 이전 경로, 새 경로
      const from = parts[++i] ?? '';
      path = parts[++i] ?? from;
    }
    files.push({ path, additions: m[1] === '-' ? -1 : Number(m[1]), deletions: m[2] === '-' ? -1 : Number(m[2]) });
  }
  const sum = (k) => files.reduce((n, f) => n + Math.max(0, f[k]), 0);
  return { files: files.length, additions: sum('additions'), deletions: sum('deletions'), list: files.slice(0, 200) };
}

/** 키처럼 보이는 문자열이 있으면 true. diff는 가리면 적용할 수 없으므로 올리지 않는다. */
export function looksSecret(value) {
  return typeof value === 'string' && redact(value) !== value;
}

function lastJsonBlock(raw) {
  const blocks = [...raw.matchAll(/```json\s*\n([\s\S]*?)```/gi)];
  if (blocks.length) return blocks[blocks.length - 1][1];
  const trimmed = raw.trim();
  return trimmed.startsWith('{') ? trimmed : null;
}

/** 답변 끝의 JSON 블록을 읽어 정해진 모양으로 맞춘다. 요약이 없으면 형식 불일치로 본다. */
export function parseResult(raw) {
  const block = typeof raw === 'string' ? lastJsonBlock(raw) : null;
  if (!block) return { ok: false, reason: 'no_json_block' };
  let data;
  try {
    data = JSON.parse(block);
  } catch {
    return { ok: false, reason: 'invalid_json' };
  }
  if (!data || typeof data !== 'object' || Array.isArray(data)) return { ok: false, reason: 'not_object' };
  const summary = text(data.summary);
  if (!summary) return { ok: false, reason: 'summary_missing' };
  return {
    ok: true,
    value: {
      summary,
      feasibility: FEASIBILITY.includes(data.feasibility) ? data.feasibility : 'unclear',
      answers: objects(data.answers).map((a) => ({ question: text(a.question), answer: text(a.answer) })).filter((a) => a.answer),
      findings: objects(data.findings)
        .map((f) => ({
          point: text(f.point),
          evidence: objects(f.evidence)
            .map((e) => ({ path: text(e.path), lines: typeof e.lines === 'number' ? String(e.lines) : text(e.lines) }))
            .filter((e) => e.path),
        }))
        .filter((f) => f.point),
      proposals: objects(data.proposals)
        .map((p) => ({
          title: text(p.title),
          change: text(p.change),
          files: list(p.files),
          risk: RISK_LEVELS.includes(p.risk) ? p.risk : 'medium',
        }))
        .filter((p) => p.title || p.change),
      risks: list(data.risks),
      questions_for_think: list(data.questions_for_think),
    },
  };
}

const REDACTIONS = [
  [/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/g, '[가림: 개인 키]'],
  [/\bsk-[A-Za-z0-9_-]{20,}/g, '[가림: 키]'],
  [/\bsb_(?:secret|publishable)_[A-Za-z0-9_-]{10,}/g, '[가림: 키]'],
  [/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/g, '[가림: 토큰]'],
  [/\b(ghp|gho|github_pat|xox[abp])_[A-Za-z0-9_]{20,}/g, '[가림: 토큰]'],
  [/((?:api[_-]?key|secret|token|password|passwd)["']?\s*[:=]\s*["']?)[^\s"'`,;]{12,}/gi, '$1[가림]'],
];

/** 결과를 DB에 올리기 전에 키처럼 보이는 문자열을 가린다. */
export function redact(value) {
  if (typeof value !== 'string' || !value) return value;
  return REDACTIONS.reduce((s, [re, rep]) => s.replace(re, rep), value);
}

export function redactDeep(value) {
  if (value == null) return value;
  return JSON.parse(redact(JSON.stringify(value)));
}

/** SDK 예외를 대기열의 실패 코드로 바꾼다. 재시도 여부는 SDK의 isRetryable을 따른다. */
export function classifyError(err) {
  const message = String(err?.message ?? err ?? 'unknown error').slice(0, 1500);
  if (err && typeof err.isRetryable === 'boolean') {
    return { code: 'startup', retryable: err.isRetryable, message: err.code ? `${err.code}: ${message}` : message };
  }
  const name = String(err?.name ?? '');
  if (/fetch|network|ECONN|ETIMEDOUT|ENOTFOUND/i.test(`${name} ${message}`)) {
    return { code: 'startup', retryable: true, message };
  }
  return { code: 'internal', retryable: false, message };
}

export class ToolCounter {
  #seen = new Set();
  #counts = new Map();

  add(event) {
    if (!event || event.type !== 'tool_call' || !event.call_id || this.#seen.has(event.call_id)) return;
    this.#seen.add(event.call_id);
    const name = String(event.name ?? 'unknown').slice(0, 60);
    this.#counts.set(name, (this.#counts.get(name) ?? 0) + 1);
  }

  list() {
    return [...this.#counts.entries()].map(([name, count]) => ({ name, count })).sort((a, b) => b.count - a.count);
  }
}

export function retryDelayMs(attempts) {
  return Math.min(30_000 * 2 ** Math.max(0, (attempts ?? 1) - 1), 5 * 60_000);
}
