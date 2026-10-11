// 작업자의 순수 로직. SDK·네트워크 없이 시험한다(test/lib.test.mjs).
import { hostname } from 'node:os';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const PROMPT_VERSION = 'code_bridge.v7';
export const READ_ONLY_TOOLS = ['read', 'grep', 'glob', 'ls'];
/** 조사·조율에서 Think에게 물을 때. 'mcp'가 있어야 customTools가 보이고, 저장소 MCP 서버도 함께 켜지므로 .cursor/mcp.json이 있으면 쓰지 않는다. */
export const ASK_TOOLS = [...READ_ONLY_TOOLS, 'mcp'];
export const ASK_THINK_LIMIT = 3;
export const ASK_QUESTION_CHARS = 4000;
/** 수정 모드. 셸은 주지 않는다(빌드·테스트·git 실행 불가). 검사는 작업자가 정해진 명령만 돌린다(checks.mjs). */
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

/** Think 결정 255670bc(2026-10-10). 강도는 요청마다 request.effort로 오고, 없거나 모르면 high. */
export const DEFAULT_MODEL = 'grok-4.7';
export const CODE_EFFORTS = ['medium', 'high', 'xhigh'];
export const DEFAULT_EFFORT = 'high';
const EFFORT_ORDER = ['low', 'medium', 'high', 'xhigh'];
const EFFORT_PARAM_IDS = ['reasoning_effort', 'effort'];

export function requestEffort(job) {
  const raw = job?.request && typeof job.request === 'object' ? job.request.effort : null;
  return CODE_EFFORTS.includes(raw) ? raw : DEFAULT_EFFORT;
}

function closestEffort(wanted, supported) {
  if (supported.includes(wanted)) return wanted;
  const at = EFFORT_ORDER.indexOf(wanted);
  let best = null;
  let bestDistance = Infinity;
  for (const v of supported) {
    const i = EFFORT_ORDER.indexOf(v);
    if (i < 0) continue;
    const d = Math.abs(i - at);
    // 거리가 같으면 높은 쪽(덜 부족하게)
    if (d < bestDistance || (d === bestDistance && i > EFFORT_ORDER.indexOf(best))) {
      best = v;
      bestDistance = d;
    }
  }
  return best;
}

const sameParams = (a, b) => a.length === b.length && a.every((p) => b.some((q) => q.id === p.id && q.value === p.value));

/**
 * Cursor.models.list() 결과에서 모델과 강도 옵션을 고른다.
 * 강도 이외 옵션(context, fast 등)은 Cursor 기본 조합을 따른다. 목록에 없는 조합은 만들지 않는다.
 * catalog가 없거나 모델·강도 옵션을 못 찾으면 { id }만 넘기고 effort는 null(기록에 "강도 모름").
 */
export function resolveModelSelection(catalog, modelId, wanted) {
  const item = Array.isArray(catalog) ? catalog.find((m) => m?.id === modelId || (m?.aliases ?? []).includes(modelId)) : null;
  if (!item) return { selection: { id: modelId }, effort: null };
  const param = (item.parameters ?? []).find((p) => EFFORT_PARAM_IDS.includes(p.id));
  const picked = param ? closestEffort(wanted, (param.values ?? []).map((v) => v.value)) : null;
  if (!param || !picked) return { selection: { id: item.id }, effort: null };

  const variants = (item.variants ?? []).filter((v) => Array.isArray(v.params));
  const base = (variants.find((v) => v.isDefault) ?? variants[0])?.params ?? [];
  let params = [...base.filter((p) => p.id !== param.id), { id: param.id, value: picked }];
  if (variants.length > 0 && !variants.some((v) => sameParams(v.params, params))) {
    const candidates = variants.filter((v) => v.params.some((p) => p.id === param.id && p.value === picked));
    const score = (v) => v.params.filter((p) => base.some((q) => q.id === p.id && q.value === p.value)).length;
    const best = candidates.sort((a, b) => score(b) - score(a))[0];
    if (!best) return { selection: { id: item.id }, effort: null };
    params = best.params.map((p) => ({ id: p.id, value: p.value }));
  }
  return { selection: { id: item.id, params }, effort: picked };
}

/** run.wait() 결과의 모델 선택에서 실제 강도. 없으면 고른 값을 그대로 쓴다. */
export function usedEffort(resultModel, fallback) {
  const p = (resultModel?.params ?? []).find((x) => EFFORT_PARAM_IDS.includes(x?.id));
  return EFFORT_ORDER.includes(p?.value) ? p.value : fallback;
}

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
    model: (env.CODE_BRIDGE_MODEL ?? DEFAULT_MODEL).trim() || DEFAULT_MODEL,
    repo: resolve(env.CODE_BRIDGE_REPO ?? REPO_ROOT),
    pollMs: positiveInt(env.CODE_BRIDGE_POLL_MS, 10_000, 3_000, 300_000),
    heartbeatMs: 30_000,
    roundTimeoutMs: positiveInt(env.CODE_BRIDGE_ROUND_TIMEOUT_MS, 15 * 60_000, 60_000, 60 * 60_000),
    changeTimeoutMs: positiveInt(env.CODE_BRIDGE_CHANGE_TIMEOUT_MS, 30 * 60_000, 60_000, 90 * 60_000),
    finishGraceMs: positiveInt(env.CODE_BRIDGE_FINISH_GRACE_MS, 60_000, 5_000, 10 * 60_000),
    checksTimeoutMs: positiveInt(env.CODE_BRIDGE_CHECKS_TIMEOUT_MS, 25 * 60_000, 60_000, 90 * 60_000),
    checkStepTimeoutMs: 10 * 60_000,
    progressLogMs: 60_000,
    askThink: (env.CODE_BRIDGE_ASK_THINK ?? '').trim().toLowerCase() !== 'off',
  };
}

/** 터미널에 보일 작업 이름. */
export function modeLabel(mode) {
  return mode === 'change' ? '수정' : mode === 'plan' ? '조율' : '조사';
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
  const plan = r.based_on_plan && typeof r.based_on_plan === 'object' ? r.based_on_plan : null;
  const disagreements = objects(r.disagreements).map((d) => `- ${text(d.point)} (Think: ${text(d.think)} / Cursor: ${text(d.cursor)})`);
  const planNote = plan
    ? `\n이 요청은 Think와 Cursor가 ${plan.rounds ?? '?'}회 조율해 확정한 조율본 "${text(plan.title)}"이다.
아래 단계를 그대로 따른다. 조율본과 다르게 해야 할 이유를 찾으면 그 부분은 고치지 말고 questions_for_think에 적는다.${
        disagreements.length ? `\n조율 때 의견이 갈린 점:\n${disagreements.join('\n')}` : ''
      }\n`
    : '';
  return `너는 Yggdrasill 저장소의 코드 수정 담당이다. 지금 폴더는 운영자 작업 폴더의 복사본이다. 여기서 요청대로 코드를 고친다.
- 읽기·검색·편집·삭제 도구만 있다. 명령을 실행할 수 없다(빌드·테스트·git 불가).
- 대신 수정이 끝나면 작업자가 이 복사본에서 자동 검사를 돌린다: 바뀐 앱의 flutter analyze·flutter test,
  바뀐 Edge Function의 deno check·deno test, tools/code_bridge의 node --test, AI 영역 DB 함수 파일(supabase/migrations/*_ai_*.sql)은
  일회용 시험 DB(tools/db_test, PGlite)에 처음부터 적용하고 tools/db_test/test 시험을 돌린다. 실패하면 Think가 다시 고치게 한다.
- 그러니 바꾼 동작은 시험으로 남긴다. 앱은 해당 앱의 test/, Edge Function은 *_test.ts, AI 영역 DB 함수는
  tools/db_test/test/*.test.mjs(harness.mjs의 openAiTestDb 사용)에 둔다. 시험이 실제로 확인하지 않는 것을 확인했다고 쓰지 않는다.
- DB 함수 파일은 이미 있는 파일을 고치지 않고 새 파일을 만든다. 번호(앞 14자리)는 폴더의 마지막 번호보다 커야 하고 겹치면 안 된다.
- 이 폴더 밖의 파일은 읽거나 쓰지 않는다. 비밀 파일(.env, env.local.json, 키 파일), .git, .cursor/hooks는 건드리지 않는다.
- 요청 범위만 고친다. 관련 없는 리팩터링, 포맷 변경, 파일 이동은 하지 않는다.
- 저장소 규칙(AGENTS.md, .cursor/rules, docs/architecture, UI면 docs/design-system.md)을 따른다.
- 커밋하지 않는다. 작업 폴더 적용과 운영 DB 반영은 운영자가 따로 승인한다.
- 판단 기준은 아래 "관련 결정·원칙"이다. 요청과 부딪히면 고치지 말고 questions_for_think에 적는다.
${fixSection(r)}${continueSection(job)}
## 요청
제목: ${text(job.title)}
목표: ${text(r.goal)}
${planNote}
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
  "checks": ["자동 검사로 확인되지 않아 사람이 봐야 할 점 (예: 화면 확인, 운영 DB 반영 전 확인)"],
  "questions_for_think": ["고치지 못했거나 판단이 필요한 점"]
}`;
}

const CONTINUE_ERRORS = {
  not_found: '그 요청을 찾지 못했습니다',
  not_change: '코드 수정 요청이 아닙니다',
  not_final: '아직 끝나지 않았거나 끝나지 못한 요청입니다',
  no_patch: '저장된 패치가 없습니다',
  incomplete: '최종 회차가 형식 확인을 통과하지 못한 불완전한 패치입니다',
  superseded: '검사 실패 재수정으로 대체됐습니다',
  continue_from_invalid: '요청 id 형식이 맞지 않습니다',
  continue_from_self: '자기 자신을 이어받을 수 없습니다',
  patch_source_failed: '서버에서 패치를 찾다가 오류가 났습니다',
};

/**
 * 이어받기 요청이면 서버가 보낸 앞 수정 패치(job.base_patch)를 확인해 돌려준다. 이어받기가 아니면 null.
 * 패치를 못 받았거나 다른 요청 것이면 예외(작업은 실패로 보고되고 작업 폴더는 그대로다).
 */
export function continuePatch(job) {
  const r = job.request && typeof job.request === 'object' ? job.request : {};
  const from = r.continue_from && typeof r.continue_from === 'object' ? r.continue_from : null;
  if (!from || r.fix_of) return null;
  const id = text(from.request_id);
  const p = job.base_patch && typeof job.base_patch === 'object' ? job.base_patch : null;
  if (!p) throw new Error(`앞 수정 ${id}의 패치를 서버에서 받지 못했습니다(서버 함수가 예전 버전일 수 있습니다). 작업 폴더는 바뀌지 않았습니다.`);
  if (p.ok !== true) {
    const why = CONTINUE_ERRORS[p.error] ?? (text(p.error) || '알 수 없는 이유');
    const extra = [
      p.status ? `상태 ${text(p.status)}` : '',
      p.superseded_by ? `최종 요청은 ${text(p.superseded_by)}` : '',
    ].filter(Boolean).join(', ');
    throw new Error(`앞 수정 ${id}의 패치를 이어받지 못했습니다: ${why}${extra ? ` (${extra})` : ''}. 작업 폴더는 바뀌지 않았습니다.`);
  }
  if (text(p.request_id) !== id) throw new Error(`서버가 다른 요청(${text(p.request_id)})의 패치를 보내 쓰지 않았습니다.`);
  if (!/^[0-9a-f]{40}$/i.test(text(p.base_commit))) throw new Error(`앞 수정 ${id}의 기준 커밋 기록이 없어 쓰지 않았습니다.`);
  return p;
}

/**
 * 이어받기(request.continue_from)면 앞 수정 요청의 최종 패치가 이 복사본에 이미 얹혀 있다고 알린다.
 * 패치 본문은 넣지 않는다(Cursor는 폴더에서 직접 읽는다).
 */
export function continueSection(job) {
  const r = job.request && typeof job.request === 'object' ? job.request : {};
  const p = job.base_patch && typeof job.base_patch === 'object' && job.base_patch.ok === true ? job.base_patch : null;
  if (!r.continue_from || r.fix_of || !p) return '';
  const s = p.diff_stats && typeof p.diff_stats === 'object' ? p.diff_stats : {};
  const paths = [...new Set([...String(p.diff ?? '').matchAll(/^diff --git a\/.+? b\/(.+)$/gm)].map((m) => m[1]))];
  const shown = paths.slice(0, 30).map((x) => `- ${x}`).join('\n');
  const more = paths.length > 30 ? `\n- 외 ${paths.length - 30}개` : '';
  const tail = job.mode === 'change'
    ? '앞 수정을 처음부터 다시 만들지 말고 이 상태에서 이어 고친다. 네 결과(diff)에는 앞 수정도 함께 담긴다.'
    : '검토는 앞 수정이 들어간 이 상태를 기준으로 한다. 이 폴더에서는 아무것도 고치지 않는다.';
  const partial = p.partial === 'timeout';
  const warn = !partial
    ? ''
    : job.mode === 'change'
    ? '\n주의: 앞 작업은 시간 제한으로 중간에 멈췄고 검사된 적이 없다. 남은 일을 끝내고, 앞 변경도 요청에 맞는지·깨진 곳이 없는지 함께 검토해 고친다.' +
      '\n앞 변경이 맞다고 가정하지 않는다. 자동 검사는 앞 변경까지 포함한 최종 결과 전체에 돈다.'
    : '\n주의: 앞 작업은 시간 제한으로 중간에 멈췄고 검사된 적이 없다. 무엇이 끝났고 무엇이 남았는지, 앞 변경에 문제가 없는지 함께 본다.';
  return `
## 이어받은 앞 수정
이 폴더는 운영자 작업 폴더의 복사본이고, 앞 코드 수정 요청 "${text(p.title)}"(id ${text(p.request_id)}, ${p.round ?? '?'}회차 ${partial ? '미완성' : '최종'} 패치,
파일 ${s.files ?? '?'}개 +${s.additions ?? '?'} -${s.deletions ?? '?'})이 이미 얹혀 있다. 운영자 작업 폴더에는 아직 적용되지 않았을 수 있다.
${tail}${warn}
앞 수정에서 바뀐 파일:
${shown || '(없음)'}${more}
`;
}

/** 재수정이면 앞 수정이 이미 들어 있다고 알리고 실패한 검사를 붙인다. */
function fixSection(r) {
  const fix = r.fix_of && typeof r.fix_of === 'object' ? r.fix_of : null;
  if (!fix) return '';
  const failed = objects(fix.failed)
    .map((f) => `### ${text(f.label)}\n명령: ${text(f.command) || '(작업자 내부 검사)'}\n\`\`\`\n${text(f.output).slice(0, 4000)}\n\`\`\``)
    .join('\n\n');
  return `
## 이번은 재수정이다 (${fix.attempt ?? '?'}/${fix.max ?? 2}회째)
이 복사본에는 앞 수정이 이미 들어 있다(아래 요청을 한 번 고친 상태). 처음부터 다시 하지 말고, 자동 검사에서 실패한 아래 항목을 고친다.
실패 원인이 앞 수정이면 그 부분을 고치고, 시험 자체가 잘못됐으면 시험을 고친다. 검사를 통과시키려고 시험을 지우거나 약하게 만들지 않는다.
요청 범위 밖이라 고칠 수 없으면 고치지 말고 questions_for_think에 이유를 적는다.

${failed || '(실패 내용 없음)'}
`;
}

/** 조율: Think가 운영자와 정한 계획 초안을 실무자로서 실제 코드에 비춰 검토한다. 코드는 고치지 않는다. */
export function buildPlanPrompt(job) {
  const r = job.request && typeof job.request === 'object' ? job.request : {};
  const refs = Array.isArray(r.memory_refs) ? r.memory_refs : [];
  const refLines = refs
    .map((m) => (m && typeof m === 'object' ? `- [${text(m.kind) || '기억'}] ${text(m.title)} (v${m.version ?? '?'}): ${text(m.content)}` : ''))
    .filter((s) => s.trim() !== '-');
  const base = r.based_on && typeof r.based_on === 'object' ? r.based_on : null;
  return `너는 Yggdrasill 저장소의 실무 개발자다. 기획 담당 Think가 운영자와 대화해 만든 구현 계획 초안을 받았다.
아직 아무것도 고치지 않는다. 실제 코드를 읽고, 이 계획대로 구현하면 생길 문제를 찾아 Think와 조율한다.
파일을 만들거나 고치거나 명령을 실행하지 않는다. 비밀 파일(.env, env.local.json, 키 파일)은 읽지 않는다.
판단 기준은 아래 "관련 결정·원칙"과 저장소 규칙(AGENTS.md, .cursor/rules, docs/architecture, UI면 docs/design-system.md)이다.

## 볼 것
- 계획이 기존 구조·규칙과 맞는지, 이미 비슷한 구현이 있는지
- 영향 범위(같이 바뀌어야 할 파일, 마이그레이션, 시험), 빠진 단계
- 그대로 하면 생길 버그·데이터 위험·보안 문제, 더 단순하거나 안전한 방법
- 방향이나 우선순위처럼 코드로 정할 수 없는 것은 판단하지 말고 questions_for_owner에 넣는다
${continueSection(job)}
## 계획 초안
제목: ${text(job.title)}
목표: ${text(r.goal)}

단계:
${bullets(list(r.instructions))}

Think가 특히 확인받고 싶은 점:
${bullets(list(r.questions))}

배경 (Think 대화):
${text(r.background) || '(없음)'}
${base ? `\n근거가 된 조사 "${text(base.title)}"의 결론: ${text(base.summary) || '(없음)'}\n` : ''}
관련 폴더나 파일:
${bullets(list(r.focus_paths))}

제약:
${bullets(list(r.constraints))}

하지 말 것:
${bullets(list(r.do_not))}

관련 결정·원칙:
${refLines.length ? refLines.join('\n') : '(없음)'}

## 답변 형식
검토를 마치면 답변 끝에 아래 모양의 JSON을 \`\`\`json 코드 블록 하나로 낸다. 설명은 앞에 써도 된다.
{
  "summary": "한두 문장 결론 (이대로 가능한지, 무엇을 고쳐야 하는지)",
  "feasibility": "possible | possible_with_changes | not_recommended | unclear 중 하나",
  "findings": [{ "point": "코드에서 확인한 사실", "evidence": [{ "path": "저장소 기준 경로", "lines": "10-24" }] }],
  "issues": [{ "step": "문제가 있는 단계(없으면 전체)", "problem": "그대로 하면 생기는 문제", "suggestion": "바꾸자는 내용" }],
  "suggested_steps": ["네가 고친 구현 단계"],
  "risks": ["위험이나 부작용"],
  "questions_for_think": ["Think에게 되묻는 질문"],
  "questions_for_owner": ["운영자만 정할 수 있는 것"]
}
코드로 확인하지 못한 추측은 findings에 넣지 말고 questions_for_think에 넣는다.`;
}

/** 작업 종류에 맞는 프롬프트. askThink면 Think 묻기 규칙을 붙인다(조사·조율만). */
export function promptFor(job, opts = {}) {
  if (job.mode === 'change') return buildChangePrompt(job);
  const base = job.mode === 'plan'
    ? (job.followup_prompt ? `${buildPlanPrompt(job)}\n\n${text(job.followup_prompt)}` : buildPlanPrompt(job))
    : (job.followup_prompt ? buildFollowupPrompt(job) : buildPrompt(job));
  return opts.askThink ? `${base}\n\n${askThinkSection(job.mode)}` : base;
}

/** 조사·조율에서만. 수정 작업은 Think가 정한 범위를 그대로 따르므로 묻지 않는다. */
export function askThinkAllowed(cfg, job) {
  return Boolean(cfg.askThink) && job.job !== 'apply' && job.job !== 'revert' && (job.mode === 'investigate' || job.mode === 'plan');
}

export function askThinkSection(mode) {
  const ownerField = mode === 'plan' ? 'questions_for_owner' : 'questions_for_think';
  return `## Think에게 묻기 (ask_think 도구)
요청의 배경이나 이미 정한 결정이 코드만으로 분명하지 않을 때 ask_think 도구로 Think에게 물을 수 있다. 이 작업에서 최대 ${ASK_THINK_LIMIT}번.
- 코드에서 찾을 수 있는 것은 묻지 않는다. 먼저 읽고, 그래도 모르는 "이미 정한 방향·원칙"만 묻는다.
- 질문에 비밀값(키, 토큰, .env 내용)을 넣지 않는다. 질문 한 개는 ${ASK_QUESTION_CHARS}자 이하.
- 답의 판정이 answered면 승인된 기존 결정이 근거다. 근거로 써도 되고, findings에 근거 기억 제목을 밝힌다.
- 판정이 needs_owner면 사장님 확인 필요다. 그 답을 근거로 판단하거나 진행하지 말고, 함께 온 확인 질문을 ${ownerField}에 옮겨 적는다.
- 도구가 실패하거나 한도를 넘으면 묻지 말고 ${ownerField}에 적은 뒤 나머지 일을 계속한다.`;
}

function askBasisLines(basis) {
  return objects(basis).map((b) => `- [${text(b.kind) || '기억'}] ${text(b.title)}`).join('\n');
}

/** ai_code_bridge ask_think 응답 → 에이전트에게 보일 글. */
export function formatAskResult(body) {
  if (!body || typeof body !== 'object' || body.ok !== true) {
    const code = text(body?.error) || 'ask_failed';
    const message = text(body?.message);
    return { ok: false, text: `Think에게 묻지 못했습니다 (${code})${message ? `: ${message}` : ''}. 이 질문은 결과의 질문 칸에 적고 계속하세요.` };
  }
  const answer = text(body.answer) || '(빈 답)';
  const questions = list(body.owner_questions);
  if (body.verdict === 'answered') {
    return { ok: true, verdict: 'answered', text: `판정: answered (승인된 기존 결정이 근거)\n근거:\n${askBasisLines(body.basis) || '(없음)'}\n\n답:\n${answer}` };
  }
  return {
    ok: true,
    verdict: 'needs_owner',
    text: `판정: needs_owner (사장님 확인 필요). 이 답을 근거로 진행하지 마세요.\n확인할 질문:\n${bullets(questions, '(Think가 질문을 따로 적지 않음. 원래 질문을 그대로 옮겨 적으세요)')}\n\n참고 답:\n${answer}`,
  };
}

/**
 * Cursor SDK customTools용 ask_think. ask(question) → ai_code_bridge 응답 본문.
 * 한도·비밀값·길이는 여기서 먼저 막고, 서버도 같은 한도를 다시 센다.
 */
export function createAskThinkTool({ ask, limit = ASK_THINK_LIMIT, onAsk = () => {} }) {
  let used = 0;
  const reply = (s, isError = false) => ({ content: [{ type: 'text', text: s }], isError });
  return {
    description: `기획 담당 Think에게 이 요청의 배경·이미 정한 결정을 묻는다. 코드로 찾을 수 있는 것은 묻지 않는다. 이 작업에서 최대 ${limit}번.`,
    inputSchema: {
      type: 'object',
      properties: { question: { type: 'string', description: `Think에게 물을 질문 (${ASK_QUESTION_CHARS}자 이하, 비밀값 금지)` } },
      required: ['question'],
      additionalProperties: false,
    },
    annotations: { title: 'Think에게 묻기', readOnlyHint: true, openWorldHint: true },
    async execute(args) {
      const question = text(args?.question);
      if (!question) return reply('질문이 비어 있습니다.', true);
      if (question.length > ASK_QUESTION_CHARS) return reply(`질문이 ${ASK_QUESTION_CHARS}자를 넘습니다. 줄여서 다시 물으세요.`, true);
      if (looksSecret(question)) return reply('질문에 키나 토큰처럼 보이는 값이 있어 보내지 않았습니다.', true);
      if (used >= limit) return reply(`이 작업에서 Think에게 묻는 한도(${limit}번)를 다 썼습니다. 남은 질문은 결과의 질문 칸에 적으세요.`, true);
      used += 1;
      let body;
      try {
        body = await ask(question);
      } catch (e) {
        body = { ok: false, error: 'network', message: String(e?.message ?? e).slice(0, 300) };
      }
      const out = formatAskResult(body);
      onAsk({ n: used, limit, verdict: out.verdict ?? null, error: out.ok ? null : text(body?.error) || 'ask_failed' });
      return reply(out.text, !out.ok);
    },
  };
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

/** 조율 결과: 조사 결과 칸 + 계획 검토 칸(issues, suggested_steps, questions_for_owner). */
export function parsePlanResult(raw) {
  const base = parseResult(raw);
  if (!base.ok) return base;
  const data = JSON.parse(lastJsonBlock(raw));
  return {
    ok: true,
    value: {
      ...base.value,
      issues: objects(data.issues)
        .map((i) => ({ step: text(i.step), problem: text(i.problem), suggestion: text(i.suggestion) }))
        .filter((i) => i.problem || i.suggestion),
      suggested_steps: list(data.suggested_steps),
      questions_for_owner: list(data.questions_for_owner),
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

/**
 * 턴 종료(`usage` 이벤트)와 마지막 답변 글을 따라간다. SDK가 턴을 끝내고도 실행을 "끝남"으로 바꾸지 못하고
 * 멈출 때가 있어, 작업자는 이것으로 받아 둔 답을 결과로 쓴다.
 */
export class TurnTracker {
  #text = '';
  ended = false;

  add(event) {
    if (!event || typeof event !== 'object') return;
    if (event.type === 'usage') {
      this.ended = true;
      return;
    }
    if (event.type === 'tool_call') {
      this.#text = '';
      this.ended = false;
    } else if (event.type === 'assistant') {
      const parts = Array.isArray(event.message?.content) ? event.message.content : [];
      for (const p of parts) if (p?.type === 'text' && typeof p.text === 'string') this.#text += p.text;
      this.ended = false;
    } else if (event.type === 'thinking') {
      this.ended = false;
    }
  }

  /** 마지막 도구 호출 뒤에 쓴 답변. */
  get text() {
    return this.#text;
  }
}

export function retryDelayMs(attempts) {
  return Math.min(30_000 * 2 ** Math.max(0, (attempts ?? 1) - 1), 5 * 60_000);
}
