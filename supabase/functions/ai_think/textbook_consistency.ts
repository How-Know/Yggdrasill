import { type AuthContext, errorResponse, jsonResponse } from '../_shared/ai/auth.ts';
import { orderedFigureAssets } from './textbook_problem_fix.ts';
import {
  cleanSolutionTranscribedText,
  commonStemFix,
  figureMarkerCount,
  sameRenderedMath,
  sanitizeProblemMarkup,
  stripGuidedSolution,
  withoutDependentSetCommonStem,
} from './textbook_problem_review.ts';
import { uuidOrNull } from './validate.ts';

type Rec = Record<string, unknown>;

/** 정합성 점검 지적의 check_key 앞머리. 문항·규칙마다 열린 지적은 하나다. */
export const CONSISTENCY_KEY_PREFIX = 'consistency:';

export type ConsistencyFixCode = 'common_stem_duplicate' | 'guide_residue' | 'markup' | 'solution_text';
export type ConsistencyIssueCode =
  | 'figure_slots'
  | 'common_figure_missing'
  | 'guide_with_figure'
  | 'guide_text'
  | 'math_delimiters'
  | 'answer_choice_range'
  | 'answer_conflict';

export interface ConsistencyFix {
  code: ConsistencyFixCode;
  title: string;
  fields: string[];
}

export interface ConsistencyIssue {
  code: ConsistencyIssueCode;
  axis: 'fidelity' | 'validity' | 'output';
  stage: 'load' | 'render' | 'compare';
  errorType: 'problem_transcription' | 'crop_leak' | 'render_item' | 'answer_link' | 'answer_mismatch';
  title: string;
  detail: string;
}

export interface ConsistencyResult {
  /** textbook_review_stage_changes 에 넘길 반영 대기 값 */
  patch: Rec;
  fixes: ConsistencyFix[];
  issues: ConsistencyIssue[];
}

export interface ConsistencyContext {
  /** 같은 세트에 공통 그림(세트 공통 그림 또는 본문 자리 없이 그림을 가진 문항)이 있다 */
  setHasCommonFigure: boolean;
}

const str = (v: unknown): string => (typeof v === 'string' ? v : v == null ? '' : String(v));
const squash = (s: string) => s.replace(/\s+|\[문단\]/g, '');

function choiceTexts(choices: unknown): string[] {
  return (Array.isArray(choices) ? choices : []).map((c) => (c && typeof c === 'object' ? str((c as Rec).text) : str(c)));
}

/** 사람이 고친 반영 대기 항목. 코드 점검도 덮어쓰지 않는다. */
function ownerKeys(it: Rec): Set<string> {
  const st = it.staged_changes && typeof it.staged_changes === 'object' ? (it.staged_changes as Rec) : {};
  const src = st.sources && typeof st.sources === 'object' ? (st.sources as Rec) : {};
  return new Set(Object.entries(src).filter(([, v]) => v === 'owner').map(([k]) => k));
}

const BOXED_BLANK = /\\(?:boxed|box)\s*\{\s*(?:\\phantom\s*\{[^}]*\}|~~|\s*)\s*\}/gi;

/** 렌더 엔진이 읽지 못하는 마크업이 있는가. `\boxed{\phantom{..}}` 는 엔진이 빈 네모로 그리므로 오류가 아니다. */
export function hasRenderBreakingMarkup(text: string): boolean {
  const pre = text.replace(BOXED_BLANK, 'box{~~}');
  return sanitizeProblemMarkup(pre) !== pre;
}

const count = (t: string, re: RegExp) => (t.match(re) ?? []).length;

/** 수식 구분자 짝이 맞지 않는 곳. */
export function mathDelimiterProblems(text: string): string[] {
  const t = String(text ?? '');
  if (!t.trim()) return [];
  const out: string[] = [];
  if (count(t, /(?<!\\)\$/g) % 2 === 1) out.push('$');
  if (count(t, /\\\(/g) !== count(t, /\\\)/g)) out.push('\\( \\)');
  if (count(t, /\\\[/g) !== count(t, /\\\]/g)) out.push('\\[ \\]');
  const bare = t.replace(/\\[{}]/g, '');
  if (count(bare, /\{/g) !== count(bare, /\}/g)) out.push('{ }');
  if (count(t, /\\left(?![a-zA-Z])/g) !== count(t, /\\right(?![a-zA-Z])/g)) out.push('\\left \\right');
  const envs = new Map<string, number>();
  for (const m of t.matchAll(/\\(begin|end)\{([a-zA-Z*]+)\}/g)) {
    envs.set(m[2], (envs.get(m[2]) ?? 0) + (m[1] === 'begin' ? 1 : -1));
  }
  if ([...envs.values()].some((v) => v !== 0)) out.push('\\begin \\end');
  return out;
}

const CIRCLED = '①②③④⑤⑥⑦⑧⑨⑩';
const IMAGE_ANSWER = /^(\[?\s*image\s*\]?|\(\s*image\s*\)|\[그림\])$/i;

/** 정답에 든 수(부호·자릿수 쉼표 무시). 표기만 다른 답을 같게 보려고 수만 비교한다. */
export function answerNumbers(s: string): string[] {
  return (String(s ?? '').replace(/(\d),(\d{3})(?!\d)/g, '$1$2').match(/\d+(?:\.\d+)?/g) ?? [])
    .map((x) => x.replace(/^0+(?=\d)/, ''));
}

function containsAll(a: string[], b: string[]): boolean {
  const m = new Map<string, number>();
  for (const x of a) m.set(x, (m.get(x) ?? 0) + 1);
  for (const x of b) {
    const n = m.get(x) ?? 0;
    if (n <= 0) return false;
    m.set(x, n - 1);
  }
  return true;
}

const sameNumbers = (a: string[], b: string[]) => containsAll(a, b) && containsAll(b, a);

/**
 * 채점 정답과 해설 정답의 수 비교. 한쪽 수가 다른 쪽에 모두 들어 있으면 같은 답(빈칸 여러 개 중 마지막만 적은 해설 등)이다.
 * 다르면 AI 답이 둘 중 하나와 같을 때 'majority'(검수 흐름의 2:1 합의), 아니면 'conflict'.
 */
export function answerAgreement(answer: string, solutionAnswer: string, aiAnswer: string): 'agree' | 'majority' | 'conflict' {
  const na = answerNumbers(answer);
  const ns = answerNumbers(solutionAnswer);
  if (containsAll(na, ns) || containsAll(ns, na)) return 'agree';
  const ai = aiAnswer.trim();
  if (ai && ai !== '판단불가') {
    const nai = answerNumbers(ai);
    if (nai.length > 0 && (sameNumbers(nai, ns) || sameNumbers(nai, na))) return 'majority';
  }
  return 'conflict';
}

function setGroupKey(it: Rec): string | null {
  const common = str(it.common_stem).trim();
  if (!common || figureMarkerCount(common) === 0) return null;
  return [str(it.sub_key), str(it.sub_index), str(it.set_header_number), common.replace(/\s+/g, '')].join('|');
}

/**
 * 공통 발문에 그림 자리가 있는 세트마다 그릴 그림이 있는지(렌더러와 같은 규칙).
 * 세트 공통 그림이 있거나, 본문에 그림 자리 없이 그림을 가진 문항이 있으면 그 그림을 공통 그림으로 그린다.
 * [commonFigureCounts]: pb_question_id → 세트 공통 그림 수
 */
export function setCommonFigureMap(items: Rec[], commonFigureCounts: Map<string, number>): Map<string, boolean> {
  const groups = new Map<string, Rec[]>();
  for (const it of items) {
    const key = setGroupKey(it);
    if (!key) continue;
    const list = groups.get(key);
    if (list) list.push(it);
    else groups.set(key, [it]);
  }
  const out = new Map<string, boolean>();
  for (const members of groups.values()) {
    const has = members.some((m) =>
      (commonFigureCounts.get(str(m.pb_question_id)) ?? 0) > 0 ||
      (orderedFigureAssets(m.pb_figure_assets).length > 0 && figureMarkerCount(m.stem) === 0)
    );
    for (const m of members) out.set(str(m.crop_id), has);
  }
  return out;
}

/**
 * 한 문항의 코드 정합성 점검(AI 없음, 사양 5-2). [it] 은 overview 문항(반영 대기 값을 겹친 모습, 종속형 세트는 공통 발문 없음).
 * - 고칠 수 있는 것(공통 발문 중복, '해' 풀이 안내, 엔진이 못 읽는 마크업, 해설 칸의 정답 줄)은 patch 로 낸다.
 * - 나머지(그림 수·자리, 수식 구분자, 정답 불일치)는 지적으로 낸다. 사장님이 보거나 고친 뒤 다시 점검한다.
 */
export function checkItemConsistency(it: Rec, ctx: ConsistencyContext): ConsistencyResult {
  const owner = ownerKeys(it);
  const patch: Rec = {};
  const fixes: ConsistencyFix[] = [];
  const issues: ConsistencyIssue[] = [];

  const origStem = str(it.stem);
  const origCommon = str(it.common_stem).trim();
  let stem = origStem;
  let common = origCommon;

  if (!owner.has('stem')) {
    const dup = commonStemFix(common, stem);
    // 공통 발문을 원래 공통 발문에 없던 글로 바꾸는 복구(손상된 공통 발문 추정)는 지시문 판별이 틀리면 본문을 옮겨 버리므로 자동으로 하지 않는다.
    const commonShrinks = dup?.commonStem == null || squash(origCommon).includes(squash(dup.commonStem));
    if (dup && commonShrinks && !(dup.commonStem !== null && owner.has('common_stem'))) {
      stem = dup.stem;
      if (dup.commonStem !== null) common = dup.commonStem;
      fixes.push({
        code: 'common_stem_duplicate',
        title: '공통 발문 중복 제거',
        fields: dup.commonStem !== null ? ['stem', 'common_stem'] : ['stem'],
      });
    }

    const unguided = stripGuidedSolution(stem, { afterCommonStem: common.trim().length > 0 });
    if (unguided !== stem.trim()) {
      if (figureMarkerCount(unguided) < figureMarkerCount(stem)) {
        issues.push({
          code: 'guide_with_figure',
          axis: 'fidelity',
          stage: 'load',
          errorType: 'crop_leak',
          title: "'해' 풀이 안내에 그림 자리가 섞임",
          detail: "본문에 '해' 풀이 안내가 남아 있는데 그 안에 그림 자리가 있어 자동으로 지우지 않았습니다. 원본을 보고 문제 그림인지 확인해 주세요.",
        });
      } else {
        stem = unguided;
        fixes.push({ code: 'guide_residue', title: "'해' 풀이 안내 제거", fields: ['stem'] });
      }
    }

    if (hasRenderBreakingMarkup(stem)) {
      stem = sanitizeProblemMarkup(stem);
      fixes.push({ code: 'markup', title: '수식 마크업 정리', fields: ['stem'] });
    }
  }
  if (!owner.has('common_stem') && common && hasRenderBreakingMarkup(common)) {
    common = sanitizeProblemMarkup(common);
    fixes.push({ code: 'markup', title: '수식 마크업 정리', fields: ['common_stem'] });
  }

  const rawChoices = Array.isArray(it.choices) ? (it.choices as unknown[]) : [];
  let choices = rawChoices;
  if (!owner.has('choices') && choiceTexts(rawChoices).some(hasRenderBreakingMarkup)) {
    choices = rawChoices.map((c) => {
      if (c && typeof c === 'object') {
        const r = c as Rec;
        const t = str(r.text);
        return hasRenderBreakingMarkup(t) ? { ...r, text: sanitizeProblemMarkup(t) } : r;
      }
      const t = str(c);
      return hasRenderBreakingMarkup(t) ? sanitizeProblemMarkup(t) : c;
    });
    patch.choices = choices;
    fixes.push({ code: 'markup', title: '수식 마크업 정리', fields: ['choices'] });
  }

  if (stem.trim() !== origStem.trim() && !sameRenderedMath(stem, origStem)) patch.stem = stem;
  if (common !== origCommon) patch.common_stem = common;

  const solution = str(it.solution_transcribed);
  const solutionAnswer = str(it.solution_answer).trim();
  if (solution.trim() && str(it.solution_source) !== 'manual' && !owner.has('solution_transcribed')) {
    const cleaned = cleanSolutionTranscribedText(solution, it.problem_number, solutionAnswer);
    if (cleaned !== solution.trim()) {
      patch.solution_transcribed = cleaned;
      fixes.push({
        code: 'solution_text',
        title: cleaned ? '해설 머리말·정답 줄 정리' : '해설 칸의 정답 줄 정리(풀이 없음)',
        fields: ['solution_transcribed'],
      });
    }
  }

  // 그림 수와 그림 자리(렌더러: 자리 순서대로 그림을 쓰고, 남은 그림은 본문 끝에 붙인다)
  const texts = choiceTexts(choices);
  const stemMarkers = figureMarkerCount(stem);
  const choiceMarkers = texts.reduce((n, t) => n + figureMarkerCount(t), 0);
  const commonMarkers = figureMarkerCount(common);
  const assets = orderedFigureAssets(it.pb_figure_assets).length;
  const imageChoices = texts.length >= 2 && texts.every((t) => !t.replace(/\[(?:그림|도형|도표)\]/g, '').trim()) &&
    assets === stemMarkers + texts.length;
  if (commonMarkers > 0 && stemMarkers === 0 && choiceMarkers === 0) {
    if (assets === 0 && !ctx.setHasCommonFigure) {
      issues.push({
        code: 'common_figure_missing',
        axis: 'fidelity',
        stage: 'render',
        errorType: 'problem_transcription',
        title: '공통 그림 없음',
        detail: '공통 발문에 그림 자리가 있는데 세트에 그릴 그림이 없습니다. 세트 머리의 그림을 잘라 붙여야 합니다.',
      });
    }
  } else if (stemMarkers + choiceMarkers !== assets && !imageChoices) {
    const markers = stemMarkers + choiceMarkers;
    issues.push({
      code: 'figure_slots',
      axis: 'fidelity',
      stage: 'render',
      errorType: 'problem_transcription',
      title: '그림 수와 그림 자리 불일치',
      detail: `그림 ${assets}개, 그림 자리 ${markers}개(본문 ${stemMarkers}${choiceMarkers ? ` · 선지 ${choiceMarkers}` : ''}). ` +
        (assets > markers
          ? '자리가 없는 그림은 본문 끝에 붙어 원본 위치와 다를 수 있습니다.'
          : '그림이 없는 자리는 비어 보입니다.'),
    });
  }

  if (/(?:^|\n|\]|\$)\s*\\text\s*\{\s*해(?:\s|\})/.test(stem)) {
    issues.push({
      code: 'guide_text',
      axis: 'fidelity',
      stage: 'load',
      errorType: 'crop_leak',
      title: "'해' 풀이 안내 잔여",
      detail: "수식 안에 '해' 풀이 안내(\\text{해 …})가 남아 있습니다. 원본을 보고 문제 글만 남겨 주세요.",
    });
  }

  const answer = str(it.existing_answer).trim();
  const fields: Array<[string, string]> = [
    ['본문', stem],
    ['공통 발문', common],
    ...texts.map((t, i): [string, string] => [`선지 ${i + 1}`, t]),
    ['해설', str(patch.solution_transcribed ?? solution)],
    ['정답', answer],
    ['해설 정답', solutionAnswer],
  ];
  const broken = fields
    .map(([name, t]) => [name, mathDelimiterProblems(t)] as const)
    .filter(([, p]) => p.length > 0);
  if (broken.length > 0) {
    issues.push({
      code: 'math_delimiters',
      axis: 'output',
      stage: 'render',
      errorType: 'render_item',
      title: '수식 구분자 오류',
      detail: broken.map(([name, p]) => `${name}: ${p.join(', ')} 짝이 맞지 않음`).join(' · '),
    });
  }

  const imageAnswer = str(it.answer_kind) === 'image' || IMAGE_ANSWER.test(answer);
  if (answer && !imageAnswer && texts.length >= 2) {
    const picked = [...answer].map((ch) => CIRCLED.indexOf(ch)).filter((i) => i >= 0);
    if (picked.length > 0 && Math.max(...picked) + 1 > texts.length) {
      issues.push({
        code: 'answer_choice_range',
        axis: 'validity',
        stage: 'compare',
        errorType: 'answer_link',
        title: '정답 번호가 선지 수보다 큼',
        detail: `정답 ${answer}, 선지 ${texts.length}개`,
      });
    }
  }
  const ownerAnswer = it.answer_manual === true || owner.has('answer');
  if (answer && !imageAnswer && !ownerAnswer && solutionAnswer && solutionAnswer !== '판단불가' && str(it.math_status) !== 'issue') {
    const ai = str(it.ai_answer).trim();
    if (answerAgreement(answer, solutionAnswer, ai) === 'conflict') {
      issues.push({
        code: 'answer_conflict',
        axis: 'validity',
        stage: 'compare',
        errorType: 'answer_mismatch',
        title: '정답 불일치',
        detail: `채점 정답 ${answer}, 해설 정답 ${solutionAnswer}${ai ? `, AI 답 ${ai}` : ''}. 셋 중 둘이 같은 답이 없습니다.`,
      });
    }
  }

  return { patch, fixes, issues };
}

/** 사장님이 "문제 없음"으로 닫은 지적을 같은 내용으로 다시 열지 않도록 지적과 문항 내용을 묶은 값. */
export function issueSignature(it: Rec, issue: ConsistencyIssue): string {
  const assets = orderedFigureAssets(it.pb_figure_assets).map((a) => str(a.id ?? a.path ?? a.figure_index));
  const text = JSON.stringify([
    issue.code,
    issue.detail,
    str(it.stem),
    str(it.common_stem),
    choiceTexts(it.choices),
    assets,
    str(it.existing_answer),
    str(it.solution_answer),
    str(it.ai_answer),
  ]);
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h.toString(16).padStart(8, '0');
}

const MAX_FIX_ROUNDS = 3;
const IN_CHUNK = 100;

function chunks<T>(list: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < list.length; i += size) out.push(list.slice(i, i + size));
  return out;
}

async function commonFigureCounts(auth: AuthContext, items: Rec[]): Promise<Map<string, number>> {
  const ids = [...new Set(
    items.filter((it) => figureMarkerCount(it.common_stem) > 0 && str(it.pb_question_id)).map((it) => str(it.pb_question_id)),
  )];
  const out = new Map<string, number>();
  for (const part of chunks(ids, IN_CHUNK)) {
    const { data, error } = await auth.admin
      .from('pb_questions')
      .select('id,common_figure_assets:meta->set_model->common_figure_assets')
      .in('id', part);
    if (error) throw new Error(`세트 공통 그림을 읽지 못했습니다: ${error.message}`);
    for (const r of (data ?? []) as Rec[]) out.set(str(r.id), orderedFigureAssets(r.common_figure_assets).length);
  }
  return out;
}

interface ItemReport {
  crop_id: string;
  problem_number: string;
  page: number | null;
  sub_key: string;
}

function itemReport(it: Rec): ItemReport {
  const page = Number(it.display_page ?? it.raw_page);
  return {
    crop_id: str(it.crop_id),
    problem_number: str(it.problem_number),
    page: Number.isFinite(page) ? page : null,
    sub_key: str(it.sub_key),
  };
}

interface StoredFindings {
  /** crop_id|check_key → 열린(보류 포함) 지적 */
  active: Map<string, Rec>;
  /** crop_id|check_key → 사장님이 "문제 없음"으로 닫을 때의 지적 서명 */
  dismissed: Map<string, Set<string>>;
}

async function loadStoredFindings(auth: AuthContext, cropIds: string[]): Promise<StoredFindings> {
  const active = new Map<string, Rec>();
  const dismissed = new Map<string, Set<string>>();
  for (const part of chunks(cropIds, IN_CHUNK)) {
    const { data, error } = await auth.admin
      .from('textbook_review_findings')
      .select('id,crop_id,check_key,status,evidence')
      .in('crop_id', part)
      .like('check_key', `${CONSISTENCY_KEY_PREFIX}%`)
      .in('status', ['open', 'held', 'dismissed']);
    if (error) throw new Error(`정합성 지적을 읽지 못했습니다: ${error.message}`);
    for (const f of (data ?? []) as Rec[]) {
      const key = `${str(f.crop_id)}|${str(f.check_key)}`;
      if (f.status !== 'dismissed') {
        active.set(key, f);
        continue;
      }
      const sig = str(((f.evidence ?? {}) as Rec).signature);
      if (!sig) continue;
      const set = dismissed.get(key) ?? new Set<string>();
      set.add(sig);
      dismissed.set(key, set);
    }
  }
  return { active, dismissed };
}

interface OpenIssue {
  it: Rec;
  issue: ConsistencyIssue;
  key: string;
  signature: string;
}

/** 사장님이 같은 내용으로 이미 "문제 없음"이라고 닫은 지적을 뺀 지적. */
function openIssuesOf(items: Rec[], results: Map<string, ConsistencyResult>, stored: StoredFindings): OpenIssue[] {
  const out: OpenIssue[] = [];
  for (const it of items) {
    for (const issue of results.get(str(it.crop_id))?.issues ?? []) {
      const key = `${str(it.crop_id)}|${CONSISTENCY_KEY_PREFIX}${issue.code}`;
      const signature = issueSignature(it, issue);
      if (stored.dismissed.get(key)?.has(signature)) continue;
      out.push({ it, issue, key, signature });
    }
  }
  return out;
}

/** 열린 정합성 지적을 지금 점검 결과로 맞춘다(없어진 지적은 닫는다). 반환: 닫은 지적 수 */
async function writeIssueFindings(
  auth: AuthContext,
  academyId: string,
  open: OpenIssue[],
  stored: StoredFindings,
): Promise<number> {
  const inserts: Rec[] = [];
  const keep = new Set<string>();
  for (const { it, issue, key, signature } of open) {
    keep.add(key);
    const row = {
      stage: issue.stage,
      axis: issue.axis,
      error_type: issue.errorType,
      severity: 'blocker',
      title: issue.title,
      detail: issue.detail,
      evidence: { rule: issue.code, signature },
    };
    const existing = stored.active.get(key);
    if (existing) {
      const { error } = await auth.admin.from('textbook_review_findings').update(row).eq('id', str(existing.id));
      if (error) throw new Error(`정합성 지적을 고치지 못했습니다: ${error.message}`);
    } else {
      inserts.push({
        ...row,
        academy_id: academyId,
        crop_id: str(it.crop_id),
        source: 'system',
        check_key: `${CONSISTENCY_KEY_PREFIX}${issue.code}`,
        status: 'open',
      });
    }
  }
  for (const part of chunks(inserts, IN_CHUNK)) {
    const { error } = await auth.admin.from('textbook_review_findings').insert(part);
    if (error) throw new Error(`정합성 지적을 저장하지 못했습니다: ${error.message}`);
  }
  const stale = [...stored.active.entries()].filter(([key]) => !keep.has(key)).map(([, f]) => str(f.id));
  for (const part of chunks(stale, IN_CHUNK)) {
    const { error } = await auth.admin
      .from('textbook_review_findings')
      .update({ status: 'resolved', resolution: 'auto_cleared', resolved_at: new Date().toISOString() })
      .in('id', part);
    if (error) throw new Error(`정합성 지적을 닫지 못했습니다: ${error.message}`);
  }
  return stale.length;
}

/**
 * 코드 정합성 점검(AI 없음, 사양 5-2·구현 범위 6). 고칠 수 있는 것은 반영 대기 값으로 쌓고(소단원 확정 때 반영),
 * 나머지는 준비됨을 막는 지적(check_key consistency:*)으로 남긴다. 문제은행·정답 테이블은 쓰지 않는다.
 *   body: { academy_id, book_id, grade_label, big_order, mid_order, crop_ids?, dry_run? }
 */
export async function handleTextbookProblemConsistency(_req: Request, auth: AuthContext, body: Rec): Promise<Response> {
  const academyId = uuidOrNull(body.academy_id);
  const bookId = uuidOrNull(body.book_id);
  const gradeLabel = typeof body.grade_label === 'string' ? body.grade_label.trim() : '';
  const bigOrder = Number(body.big_order);
  const midOrder = Number(body.mid_order);
  if (!academyId || !bookId || !gradeLabel || !Number.isInteger(bigOrder) || !Number.isInteger(midOrder)) {
    return errorResponse(400, 'invalid_scope', '학원, 교재, 학년, 중단원 정보가 필요합니다.');
  }
  const requested = new Set(
    (Array.isArray(body.crop_ids) ? (body.crop_ids as unknown[]) : [])
      .map((x) => uuidOrNull(x))
      .filter((x): x is string => !!x),
  );
  const dryRun = body.dry_run === true;

  const loadItems = async (): Promise<Rec[]> => {
    const res = await auth.userClient.rpc('textbook_review_unit_overview', {
      p_academy_id: academyId,
      p_book_id: bookId,
      p_grade_label: gradeLabel,
      p_big_order: bigOrder,
      p_mid_order: midOrder,
    });
    if (res.error) throw new Error(res.error.message);
    return (((res.data as Rec | null)?.items ?? []) as unknown[]).map((x) => withoutDependentSetCommonStem((x ?? {}) as Rec));
  };
  const isTarget = (it: Rec) => !!str(it.pb_question_id) && (requested.size === 0 || requested.has(str(it.crop_id)));

  const fixed = new Map<string, ItemReport & { fixes: string[] }>();
  const errors: string[] = [];
  let all: Rec[];
  try {
    all = await loadItems();
  } catch (e) {
    return errorResponse(502, 'overview_failed', e instanceof Error ? e.message : String(e));
  }

  const check = async (list: Rec[]) => {
    const setFigures = setCommonFigureMap(list, await commonFigureCounts(auth, list));
    return new Map(
      list.filter(isTarget).map((it) => [
        str(it.crop_id),
        checkItemConsistency(it, { setHasCommonFigure: setFigures.get(str(it.crop_id)) ?? false }),
      ]),
    );
  };

  let results: Map<string, ConsistencyResult>;
  try {
    results = await check(all);
  } catch (e) {
    return errorResponse(502, 'consistency_failed', e instanceof Error ? e.message : String(e));
  }
  // crop_id → 이미 쌓아 본 수정안. 같은 세트의 다른 문항을 고치면서 새 수정안이 생기면 그것만 다시 쌓는다.
  const tried = new Map<string, string>();
  const failed = new Set<string>();
  for (let round = 0; round < MAX_FIX_ROUNDS && !dryRun; round++) {
    const todo = all.filter((it) => {
      const r = results.get(str(it.crop_id));
      return r && Object.keys(r.patch).length > 0 && tried.get(str(it.crop_id)) !== JSON.stringify(r.patch);
    });
    if (todo.length === 0) break;
    for (const it of todo) {
      const cropId = str(it.crop_id);
      const r = results.get(cropId)!;
      tried.set(cropId, JSON.stringify(r.patch));
      const titles = [...new Set(r.fixes.map((f) => f.title))];
      const { data, error } = await auth.userClient.rpc('textbook_review_stage_changes', {
        p_crop_id: cropId,
        p_patch: r.patch,
        p_source: 'ai',
        p_note: `정합성 점검: ${titles.join(', ')}`,
      });
      if (error) {
        failed.add(cropId);
        errors.push(`${it.problem_number}번: ${error.message}`);
        continue;
      }
      const changed = Array.isArray((data as Rec | null)?.changed) ? ((data as Rec).changed as unknown[]) : [];
      if (changed.length > 0) {
        const prev = fixed.get(cropId);
        fixed.set(cropId, { ...itemReport(it), fixes: [...new Set([...(prev?.fixes ?? []), ...titles])] });
      }
    }
    try {
      all = await loadItems();
      results = await check(all);
    } catch (e) {
      errors.push(`다시 읽기: ${e instanceof Error ? e.message : String(e)}`);
      break;
    }
  }

  const targets = all.filter(isTarget);
  if (!dryRun) {
    for (const it of targets) {
      const cropId = str(it.crop_id);
      const left = Object.keys(results.get(cropId)?.patch ?? {});
      if (left.length > 0 && tried.has(cropId) && !failed.has(cropId)) {
        errors.push(`${it.problem_number}번: 정합성 수정이 반영 대기 값에 남지 않음(${left.join(', ')})`);
      }
    }
  }

  let open: OpenIssue[] = [];
  let resolved = 0;
  try {
    const stored = await loadStoredFindings(auth, targets.map((it) => str(it.crop_id)));
    open = openIssuesOf(targets, results, stored);
    if (!dryRun) resolved = await writeIssueFindings(auth, academyId, open, stored);
  } catch (e) {
    errors.push(e instanceof Error ? e.message : String(e));
  }

  const flaggedByCrop = new Map<string, ItemReport & { issues: Array<{ code: string; title: string; detail: string }> }>();
  for (const { it, issue } of open) {
    const cropId = str(it.crop_id);
    const row = flaggedByCrop.get(cropId) ?? { ...itemReport(it), issues: [] };
    row.issues.push({ code: issue.code, title: issue.title, detail: issue.detail });
    flaggedByCrop.set(cropId, row);
  }
  const flagged = [...flaggedByCrop.values()];
  const pending = dryRun
    ? targets
      .map((it) => ({ it, r: results.get(str(it.crop_id)) }))
      .filter(({ r }) => r && Object.keys(r.patch).length > 0)
      .map(({ it, r }) => ({ ...itemReport(it), fixes: [...new Set(r!.fixes.map((f) => f.title))], fields: Object.keys(r!.patch) }))
    : [];
  const byCode: Record<string, number> = {};
  for (const x of flagged) for (const i of x.issues) byCode[i.code] = (byCode[i.code] ?? 0) + 1;

  return jsonResponse({
    ok: true,
    dry_run: dryRun,
    checked: targets.length,
    fixed: dryRun ? pending : [...fixed.values()],
    flagged,
    by_code: byCode,
    resolved,
    errors,
  });
}
