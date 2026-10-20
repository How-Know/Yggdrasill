// 코드 요청 결과 조회(get_code_request). 긴 요청 원문이 응답 앞을 차지해 결과가 잘리던 문제를 막는다.
// - 기본(section 없음): 항상 짧은 구조화 요약(brief)을 먼저 준다. 상태, 결과 요약, 바뀐 파일, 검사 결과, 막힌 이유, 적용에 필요한 행동.
// - 긴 요청 원문·결과 원문·검사 로그·diff는 section + offset으로 구간씩 읽는다. 잘렸으면 무엇이 빠졌고 어떻게 읽는지 알린다.
// - "검사 통과"는 작업자 실행 기록(result.verification)에서만 나온다. 모델 글은 근거가 아니다.
// Think 도구(ai_think actions)와 Cursor용 relay(ai_think_relay)가 같은 모양을 쓴다.
// 설계: docs/architecture/ai-think-actions.md §4.5

import { clip } from './prompts.ts';
import type { CodeRequestDetail } from './actions.ts';
import { STATUS_LABELS, verdictLabel, verificationOf, type Verification } from '../_shared/code_verification.ts';

export const CODE_SECTIONS = ['request', 'result', 'result_text', 'check_logs', 'diff'] as const;
export type CodeSection = (typeof CODE_SECTIONS)[number];
export const SECTION_CHARS = 7000;
const BRIEF_MAX_CHARS = 9000;

const REQUEST_STATUS_LABELS: Record<string, string> = {
  draft: '초안',
  queued: '대기',
  running: '작업 중',
  followup_queued: '추가 질문 대기',
  ready: '결과 도착',
  needs_review: '결과 형식 확인 필요',
  failed: '실패',
  cancelled: '취소됨',
  apply_queued: '작업 폴더 적용 대기',
  applying: '작업 폴더 적용 중',
  applied: '작업 폴더 적용 완료',
  apply_failed: '작업 폴더 적용 실패',
  revert_queued: '되돌리기 대기',
  reverting: '되돌리는 중',
  reverted: '되돌림',
  revert_failed: '되돌리기 실패',
  superseded: '재수정으로 대체됨',
};

const isObj = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);
const str = (v: unknown, max: number): string => (typeof v === 'string' ? v.trim().slice(0, max) : '');
const strList = (v: unknown, maxItems: number, maxChars = 300): string[] =>
  Array.isArray(v) ? v.map((x) => str(x, maxChars)).filter(Boolean).slice(0, maxItems) : [];

function changedFiles(result: Record<string, unknown> | null): { path: string; what?: string; additions?: number; deletions?: number }[] {
  const what = new Map<string, string>();
  for (const c of Array.isArray(result?.changes) ? result.changes.filter(isObj) : []) {
    const p = str(c.path, 300);
    if (p) what.set(p, str(c.what, 200));
  }
  const stats = isObj(result?.diff_stats) && Array.isArray(result.diff_stats.list) ? result.diff_stats.list.filter(isObj) : [];
  const out = stats.map((f) => {
    const path = str(f.path, 300);
    return {
      path,
      ...(what.get(path) ? { what: what.get(path) } : {}),
      ...(typeof f.additions === 'number' ? { additions: f.additions } : {}),
      ...(typeof f.deletions === 'number' ? { deletions: f.deletions } : {}),
    };
  });
  for (const [path, w] of what) if (!out.some((f) => f.path === path)) out.push({ path, ...(w ? { what: w } : {}) });
  return out.filter((f) => f.path);
}

function applyState(status: string, v: Verification | null): string {
  if (['apply_queued', 'applying'].includes(status)) return '적용 진행 중';
  if (status === 'applied') return '적용 완료';
  if (status === 'apply_failed') return '적용 실패';
  if (['revert_queued', 'reverting', 'reverted', 'revert_failed'].includes(status)) return REQUEST_STATUS_LABELS[status];
  if (status === 'ready') {
    return v?.verdict === 'passed' ? '적용 대기 (운영자 승인 필요)' : '적용 대기 (필수 검사 통과 아님, 운영자 판단 필요)';
  }
  return '적용할 수 없음';
}

function codeState(d: CodeRequestDetail, result: Record<string, unknown> | null): string {
  if (['queued', 'running', 'followup_queued'].includes(d.status)) return '작성 중';
  if (!isObj(result?.diff_stats)) return '없음';
  const files = typeof result.diff_stats.files === 'number' ? result.diff_stats.files : 0;
  if (files === 0) return '바뀐 파일 없음';
  return result.partial === 'timeout' ? `일부만 작성 (시간 초과, 파일 ${files}개)` : `작성 완료 (파일 ${files}개)`;
}

function checksBrief(v: Verification | null, hasResult: boolean) {
  if (!v) return { verdict: hasResult ? 'no_record' : null, label: hasResult ? '검사 기록 없음 (통과 아님)' : '아직 없음', items: [] };
  return {
    verdict: v.verdict,
    label: verdictLabel(v),
    counts: { passed: v.summary.passed, failed: v.summary.failed, not_run: v.summary.skipped, preexisting: v.summary.preexisting },
    patch_sha256: v.patch_sha256,
    stopped: v.stopped,
    note: v.note,
    items: v.items.map((i) => ({
      label: i.label,
      status: STATUS_LABELS[i.status],
      scope: i.scope === 'followup' ? '후속 확인' : '필수',
      ...(i.source === 'request' ? { requested: true } : {}),
      ...(i.env ? { env_problem: true } : {}),
      command: i.command,
      cwd: i.cwd,
      exit_code: i.exit_code,
      duration_ms: i.duration_ms,
      ...(i.reason ? { reason: clip(i.reason, 300) } : {}),
    })),
  };
}

function blockedReason(d: CodeRequestDetail, v: Verification | null): string | null {
  if (d.last_error) return clip(d.last_error, 500);
  if (!v) return null;
  const required = v.items.filter((i) => i.scope === 'required');
  if (v.verdict === 'failed') return `이번 수정 때문에 실패한 필수 검사: ${required.filter((i) => i.status === 'failed').map((i) => i.label).join(', ')}`;
  if (v.verdict === 'not_run') {
    const notRun = required.filter((i) => i.status === 'skipped');
    return `실행하지 못한 필수 검사: ${notRun.map((i) => `${i.label}${i.reason ? ` (${clip(i.reason, 160)})` : ''}`).join('; ') || '중간에 멈춤'}`;
  }
  return null;
}

function nextAction(d: CodeRequestDetail, v: Verification | null, hasResult: boolean): string {
  if (['queued', 'running', 'followup_queued'].includes(d.status)) return '작업 중이다. 결과가 오면 같은 대화에 붙는다.';
  if (d.status === 'superseded') return '자동 검사 실패로 재수정 요청이 이어받았다. 최신 재수정 요청을 본다.';
  if (d.status === 'failed' || d.status === 'cancelled') return '끝나지 못했다. 막힌 이유를 보고 다시 요청할지 운영자가 정한다.';
  if (d.status === 'applied') return '작업 폴더에 적용됐다. 운영 반영(배포·운영 DB 반영)은 따로 승인받는다.';
  if (['apply_queued', 'applying', 'revert_queued', 'reverting'].includes(d.status)) return '작업자가 처리 중이다.';
  if (d.mode !== 'change') return '결과를 읽고 다음 단계를 정한다.';
  if (d.status === 'needs_review') return '결과 형식 확인이 필요해 적용할 수 없다. 같은 내용으로 다시 수정하거나 범위를 줄여 요청한다.';
  if (!hasResult || !v) return '자동 검사 기록이 없어 검증되지 않았다. 적용을 권하지 않는다.';
  if (v.verdict === 'failed') return '필수 검사에 실패했다. 자동 재수정 결과를 기다리거나, 재수정을 다 썼으면 적용하지 않는다.';
  if (v.verdict === 'not_run') {
    const env = v.items.filter((i) => i.scope === 'required' && i.status === 'skipped' && i.env);
    return env.length > 0
      ? `환경 조치가 필요하다: ${env.map((i) => clip(i.reason ?? i.label, 160)).join('; ')}. 조치 뒤 같은 내용으로 다시 수정하면 검사가 돈다. 그대로 적용할지는 운영자가 정한다.`
      : '돌리지 못한 필수 검사가 있다. 위험을 알리고 적용 여부는 운영자가 정한다.';
  }
  return '운영자가 작업 폴더 적용을 승인하면 작업자가 적용한다.';
}

const ms = (a: string | null | undefined, b: string | null | undefined): number | null => {
  const x = a ? Date.parse(a) : NaN;
  const y = b ? Date.parse(b) : NaN;
  return Number.isFinite(x) && Number.isFinite(y) && y >= x ? y - x : null;
};

function timings(d: CodeRequestDetail): Record<string, number> | null {
  const l = d.latest;
  if (!l) return null;
  const t = isObj(l.result?.timings) ? l.result.timings : {};
  const out: Record<string, number> = {};
  const wait = l.round === 1 ? ms(d.created_at, l.started_at) : null;
  if (wait != null) out.queue_wait_ms = wait;
  for (const k of ['prepare_ms', 'agent_ms', 'checks_ms']) if (typeof t[k] === 'number') out[k] = t[k] as number;
  if (typeof l.duration_ms === 'number') out.worker_total_ms = l.duration_ms;
  return Object.keys(out).length > 0 ? out : null;
}

function sectionText(d: CodeRequestDetail, section: CodeSection, diff: string | null): string | null {
  const result = d.latest?.result ?? null;
  switch (section) {
    case 'request':
      return JSON.stringify({ ...d.request, memory_refs: undefined }, null, 1);
    case 'result': {
      if (!result) return null;
      const { verification: _v, ...rest } = result;
      return JSON.stringify(rest, null, 1);
    }
    case 'result_text':
      return d.latest?.result_text ?? null;
    case 'check_logs': {
      const v = verificationOf(result);
      if (!v || v.items.length === 0) return null;
      return v.items
        .map((i) => [
          `## [${STATUS_LABELS[i.status]}] ${i.label}`,
          `명령: ${i.command ?? '(없음)'} · 폴더: ${i.cwd ?? '-'} · 종료 코드: ${i.exit_code ?? '-'} · ${i.duration_ms ?? 0}ms`,
          i.reason ? `이유: ${i.reason}` : '',
          i.output ?? '',
        ].filter(Boolean).join('\n'))
        .join('\n\n');
    }
    case 'diff':
      return diff;
  }
}

export function sectionSizes(d: CodeRequestDetail): Record<string, number> {
  const out: Record<string, number> = {};
  for (const s of ['request', 'result', 'result_text', 'check_logs'] as const) {
    const t = sectionText(d, s, null);
    if (t) out[s] = t.length;
  }
  return out;
}

/** 항상 먼저 주는 짧은 구조화 요약. 크기가 넘치면 목록부터 줄이고 줄였다고 적는다. */
export function codeRequestBrief(d: CodeRequestDetail): Record<string, unknown> {
  const result = d.latest?.result ?? null;
  const change = d.mode === 'change';
  const v = change ? verificationOf(result) : null;
  const hasResult = !!result;
  const files = change ? changedFiles(result) : [];
  const needsCheck = change
    ? [
      ...strList(result?.checks, 10),
      ...(v?.items.filter((i) => i.scope === 'followup').map((i) => `${i.label}${i.reason ? `: ${clip(i.reason, 200)}` : ''}`) ?? []),
    ]
    : [];
  const questions = strList(result?.questions_for_think, 8);
  const fc = isObj(d.request?.final_check) ? d.request.final_check : null;
  const brief: Record<string, unknown> = {
    id: d.id,
    title: d.title,
    mode: d.mode,
    status: d.status,
    status_label: change && d.status === 'ready' ? '코드 작성 완료' : REQUEST_STATUS_LABELS[d.status] ?? d.status,
    round: `${d.round}/${d.max_rounds}`,
    ...(change
      ? {
        state: {
          code: codeState(d, result),
          checks: checksBrief(v, hasResult).label,
          needs_owner_check: needsCheck.length + questions.length,
          apply: applyState(d.status, v),
        },
      }
      : {}),
    summary: clip(str(result?.summary, 2000), 1200) || null,
    ...(change ? { changed_files: files.slice(0, 30), changed_files_total: files.length } : {}),
    ...(change ? { checks: checksBrief(v, hasResult) } : {}),
    ...(needsCheck.length ? { needs_check: needsCheck.slice(0, 10) } : {}),
    ...(questions.length ? { questions_for_think: questions } : {}),
    ...(result && !change ? { result_fields: Object.keys(result) } : {}),
    blocked_reason: change ? blockedReason(d, v) : d.last_error ? clip(d.last_error, 500) : null,
    next_action: nextAction(d, v, hasResult),
    ...(fc ? { final_instruction_check: { flagged: strList(fc.flagged, 6), retried: fc.retried === true, remaining: strList(fc.remaining, 6) } } : {}),
    ...(timings(d) ? { timings_ms: timings(d) } : {}),
    request_digest: {
      goal: clip(str(d.request?.goal, 600), 300),
      instructions: strList(d.request?.instructions, 30).length,
      required_checks: Array.isArray(d.request?.checks) ? d.request.checks.filter(isObj).map((c) => `${str(c.command, 200)} (${str(c.cwd, 100) || '.'})`) : [],
      ...(isObj(d.request?.based_on_plan) ? { based_on_plan: str(d.request.based_on_plan.id, 64) } : {}),
      ...(isObj(d.request?.fix_of) ? { fix_of: str(d.request.fix_of.request_id, 64), fix_attempt: d.request.fix_of.attempt ?? null } : {}),
    },
  };
  const sizes = sectionSizes(d);
  const stats = isObj(result?.diff_stats) ? result.diff_stats : null;
  const omitted = Object.entries(sizes).map(([section, chars]) => ({ section, chars, read: `section="${section}", offset=0` }));
  if (change && stats && typeof stats.files === 'number' && stats.files > 0) {
    omitted.push({ section: 'diff', chars: -1, read: 'section="diff", offset=0' });
  }
  brief.not_included = {
    note: '요약에 다 넣지 않은 원문이다. 같은 도구에 id와 section, offset(앞 응답의 next_offset)을 주면 구간씩 읽는다.',
    sections: omitted,
  };
  return fitBrief(brief);
}

function fitBrief(brief: Record<string, unknown>): Record<string, unknown> {
  const size = () => JSON.stringify(brief).length;
  if (size() <= BRIEF_MAX_CHARS) return brief;
  const trimmed: string[] = [];
  const checks = brief.checks as { items?: unknown[] } | undefined;
  if (Array.isArray(brief.changed_files) && brief.changed_files.length > 10) {
    brief.changed_files = brief.changed_files.slice(0, 10);
    trimmed.push('changed_files(앞 10개만)');
  }
  if (size() > BRIEF_MAX_CHARS && checks?.items && checks.items.length > 8) {
    checks.items = checks.items.slice(0, 8);
    trimmed.push('checks.items(앞 8개만, 전체는 section="check_logs")');
  }
  if (size() > BRIEF_MAX_CHARS && typeof brief.summary === 'string') {
    brief.summary = clip(brief.summary, 400);
    trimmed.push('summary(앞 400자, 전체는 section="result")');
  }
  if (trimmed.length) brief.trimmed = trimmed;
  return brief;
}

/** section 하나를 offset부터 SECTION_CHARS만큼. 끝이 아니면 next_offset을 준다. */
export function codeRequestSection(d: CodeRequestDetail, section: CodeSection, offset: number, diff: string | null = null): Record<string, unknown> {
  const text = sectionText(d, section, diff);
  if (text == null) return { id: d.id, section, available: false, note: '이 요청에는 이 구간이 없다.' };
  const start = Math.max(0, Math.min(offset, text.length));
  const end = Math.min(text.length, start + SECTION_CHARS);
  return {
    id: d.id,
    section,
    offset: start,
    total_chars: text.length,
    text: text.slice(start, end),
    next_offset: end < text.length ? end : null,
    ...(end < text.length ? { remaining_chars: text.length - end } : {}),
  };
}

export function parseSection(v: unknown): CodeSection | null {
  return typeof v === 'string' && (CODE_SECTIONS as readonly string[]).includes(v) ? (v as CodeSection) : null;
}
