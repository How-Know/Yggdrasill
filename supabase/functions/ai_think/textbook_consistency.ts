import { type AuthContext, errorResponse, jsonResponse } from '../_shared/ai/auth.ts';
import { attachParticles, collectNameSets, formatMockSolution, type NameSets, uprightNames } from './textbook_mock_format.ts';
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

export type ConsistencyFixCode =
  | 'common_stem_duplicate'
  | 'guide_residue'
  | 'markup'
  | 'solution_text'
  // 아래 넷은 모의고사 문항에만 건다(2026-11-20 사장님 결정).
  | 'point_names'
  | 'intent_mark'
  | 'figure_below_choices'
  | 'figure_marker_below_choices'
  | 'particle_spacing'
  // 표(tabular)의 줄 끝이 '\' 하나인 것을 '\\' 로 고친다(교재·모의고사 공통, 2026-11-23 사장님 결정).
  | 'table_row_end';
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
  /** 모의고사 구간의 문항일 때만 준다. 모의고사에만 거는 표기 규칙(점 이름·출제의도·선지 아래 그림)을 켠다. */
  mock?: MockItemContext;
}

export interface MockItemContext {
  /**
   * 시험지 쪽에서 읽은 선지 번호(①~⑤) 글자 영역 [ymin, xmin, ymax, xmax] (0..1000, mock_exam_items.choice_number_region_1k).
   * 읽지 못했거나 번호 글자가 없으면 null.
   */
  choiceNumberRegion: unknown;
}

const str = (v: unknown): string => (typeof v === 'string' ? v : v == null ? '' : String(v));
const squash = (s: string) => s.replace(/\s+|\[문단\]/g, '');

function choiceTexts(choices: unknown): string[] {
  return (Array.isArray(choices) ? choices : []).map((c) => (c && typeof c === 'object' ? str((c as Rec).text) : str(c)));
}

/** 선지 글마다 [fn] 을 건다. 바뀐 선지가 없으면 받은 목록을 그대로 돌려준다. */
function mapChoiceTexts(choices: unknown[], fn: (text: string) => string): unknown[] {
  let changed = false;
  const next = choices.map((c) => {
    const isRec = !!c && typeof c === 'object';
    const before = isRec ? str((c as Rec).text) : str(c);
    const after = fn(before);
    if (after === before) return c;
    changed = true;
    return isRec ? { ...(c as Rec), text: after } : after;
  });
  return changed ? next : choices;
}

/** 쪽 기준 영역 [ymin, xmin, ymax, xmax] (0..1000). 꼴이 다르면 null. */
function region1k(v: unknown): number[] | null {
  if (!Array.isArray(v) || v.length !== 4) return null;
  const n = v.map((x) => Number(x));
  if (n.some((x) => !Number.isFinite(x) || x < 0 || x > 1000)) return null;
  return n[2] > n[0] && n[3] > n[1] ? n : null;
}

/** 문항 영역과 글자 영역은 같은 글자 층에서 나오므로 거의 꼭 맞는다. 반올림 차이만 봐준다. */
const REGION_TOLERANCE = 3;

/**
 * 원본 시험지에서 선지 아래에 찍힌 그림을 조판에서도 선지 아래('below-choices')로 보낸 그림 배치. 바꿀 것이 없으면 null.
 * 근거는 시험지 PDF 에서 읽은 두 자리(선지 번호 글자 영역, 그림 영역)다: 그림의 위쪽 끝이 선지 번호 글자의 아래쪽 끝보다 아래에 있다.
 * 글 줄 안 그림과 가로로 묶인 그림은 옮기지 않는다. 이미 선지 아래인 그림을 되돌리지도 않는다.
 */
/**
 * 원본에서 선지 아래에 인쇄된 그림의 순서(orderedFigureAssets 기준, 0부터). 시험지 좌표(선지 번호 자리, 문항 영역,
 * 그림 영역)로만 판단한다. 좌표를 쓸 수 없으면 빈 집합이다.
 */
/**
 * tabular 표 안에서 줄 끝의 '\' 하나를 '\\' 로 고친다. 추출이 줄 끝 표시를 반만 적으면("0.5 & 0.1915 \")
 * 다음 줄의 \hline 이 "Misplaced \noalign" 으로 조판을 깨뜨린다.
 * 고치는 곳: 표 안에서 '\' 하나로 끝나는 줄(표의 마지막 줄 제외), 같은 줄에 이어 쓴 "\ \hline".
 */
export function fixTabularRowEnds(text: string): string {
  return text.replace(/\\begin\{tabular\}[\s\S]*?\\end\{tabular\}/g, (table) => {
    const lines = table.split('\n');
    return lines
      .map((line, i) => {
        let out = line.replace(/([^\\])\\(\s+\\hline)/g, '$1\\\\$2');
        if (i < lines.length - 1 && /(^|[^\\])\\\s*$/.test(out)) out = out.replace(/\\\s*$/, '\\\\');
        return out;
      })
      .join('\n');
  });
}

export function figureOrdersBelowChoices(it: Rec, choiceNumberRegion: unknown): Set<number> {
  const out = new Set<number>();
  const choiceRegion = region1k(choiceNumberRegion);
  const itemRegion = region1k(it.item_region_1k);
  if (!choiceRegion || !itemRegion) return out;
  const within = choiceRegion[0] >= itemRegion[0] - REGION_TOLERANCE && choiceRegion[1] >= itemRegion[1] - REGION_TOLERANCE &&
    choiceRegion[2] <= itemRegion[2] + REGION_TOLERANCE && choiceRegion[3] <= itemRegion[3] + REGION_TOLERANCE;
  // 문항 영역을 다시 잡은 뒤 아직 다시 읽지 않은 선지 자리는 쓰지 않는다.
  if (!within) return out;
  const page = Number(it.raw_page);
  orderedFigureAssets(it.pb_figure_assets).forEach((asset, i) => {
    const box = region1k(asset.bbox_1k);
    if (!box || !Number.isFinite(page) || Number(asset.source_page) !== page) return;
    // 그림 영역은 여백을 두고 잡혀 문항 영역 밖으로 조금 나가기도 한다. 가운데가 문항 영역 안이면 이 문항의 그림이다.
    const cy = (box[0] + box[2]) / 2;
    const cx = (box[1] + box[3]) / 2;
    if (cy < itemRegion[0] || cy > itemRegion[2] || cx < itemRegion[1] || cx > itemRegion[3]) return;
    if (box[0] < choiceRegion[2] - 2) return;
    out.add(i);
  });
  return out;
}

export function figureLayoutBelowChoices(it: Rec, choiceNumberRegion: unknown): Rec | null {
  const layout = it.pb_figure_layout && typeof it.pb_figure_layout === 'object' ? (it.pb_figure_layout as Rec) : null;
  if (!layout) return null;
  const below = figureOrdersBelowChoices(it, choiceNumberRegion);
  if (below.size === 0) return null;
  const items = (Array.isArray(layout.items) ? layout.items : []).filter((x): x is Rec => !!x && typeof x === 'object');
  if (items.length === 0) return null;
  const grouped = new Set<string>();
  for (const g of Array.isArray(layout.groups) ? layout.groups : []) {
    if (!g || typeof g !== 'object') continue;
    for (const k of Array.isArray((g as Rec).members) ? ((g as Rec).members as unknown[]) : []) grouped.add(str(k));
  }
  const move = new Set<Rec>();
  orderedFigureAssets(it.pb_figure_assets).forEach((asset, i) => {
    if (!below.has(i)) return;
    const idx = Number.parseInt(str(asset.figure_index), 10);
    const item = items.find((x) => str(x.assetKey) === `idx:${idx}`) ?? items.find((x) => str(x.assetKey) === `ord:${i + 1}`);
    if (!item || grouped.has(str(item.assetKey))) return;
    const position = str(item.position);
    if (position === 'below-choices' || position === 'inline-text') return;
    move.add(item);
  });
  if (move.size === 0) return null;
  return {
    ...layout,
    items: (layout.items as unknown[]).map((x) => (move.has(x as Rec) ? { ...(x as Rec), position: 'below-choices' } : x)),
  };
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
  // 줄바꿈 명령(\\)은 먼저 뺀다. 둘째 역슬래시가 뒤 글자와 붙어 \( · \[ · \{ 로 읽히면
  // cases 의 `(x\geq0)\\(k+x)` 같은 멀쩡한 식이 짝이 안 맞는 것으로 잡힌다.
  const t = String(text ?? '').replace(/\\\\/g, ' ');
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
 * - 모의고사 문항([ctx].mock)은 표기도 맞춘다: 점 이름 곧은 글자, '[출제의도]' 머리, 선지 아래 그림(docs/architecture/mock-exam.md).
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

  // 모의고사: 점 이름·이름표를 원본처럼 곧은 글자로 감싼다. 이름 글자는 본문·공통 발문·선지를 통틀어 모은다.
  let problemNames: NameSets | null = null;
  if (ctx.mock) {
    problemNames = collectNameSets([stem, common, ...choiceTexts(choices)]);
    const names = problemNames;
    const fields: string[] = [];
    if (!owner.has('stem')) {
      const named = uprightNames(stem, names, 'problem');
      if (named !== stem) {
        stem = named;
        fields.push('stem');
      }
    }
    if (!owner.has('common_stem') && common) {
      const named = uprightNames(common, names, 'problem');
      if (named !== common) {
        common = named;
        fields.push('common_stem');
      }
    }
    if (!owner.has('choices')) {
      const named = mapChoiceTexts(choices, (t) => uprightNames(t, names, 'problem'));
      if (named !== choices) {
        choices = named;
        patch.choices = choices;
        fields.push('choices');
      }
    }
    if (fields.length > 0) fixes.push({ code: 'point_names', title: '점 이름 곧은 글자', fields });
  }

  // 모의고사: 수식 뒤에 띄어 쓴 조사를 붙인다('16 명' → '16명'). 이름을 감싼 뒤에 해야 '\text{A} 와' 도 걸린다.
  let stemSpacingChanged = false;
  if (ctx.mock) {
    const fields: string[] = [];
    if (!owner.has('stem')) {
      const attached = attachParticles(stem, 'problem');
      if (attached !== stem) {
        stem = attached;
        stemSpacingChanged = true;
        fields.push('stem');
      }
    }
    if (!owner.has('common_stem') && common) {
      const attached = attachParticles(common, 'problem');
      if (attached !== common) {
        common = attached;
        fields.push('common_stem');
      }
    }
    if (!owner.has('choices')) {
      const attached = mapChoiceTexts(choices, (t) => attachParticles(t, 'problem'));
      if (attached !== choices) {
        choices = attached;
        patch.choices = choices;
        fields.push('choices');
      }
    }
    if (fields.length > 0) fixes.push({ code: 'particle_spacing', title: '수식 뒤 조사 붙여 쓰기', fields });
  }

  // 표의 줄 끝이 '\' 하나로 추출되면 문항 카드가 조판되지 않는다(2026 고3 9월 확통 27). '\\' 로 고친다.
  let tableRowsChanged = false;
  if (!owner.has('stem')) {
    const fixedRows = fixTabularRowEnds(stem);
    if (fixedRows !== stem) {
      stem = fixedRows;
      tableRowsChanged = true;
      fixes.push({ code: 'table_row_end', title: '표 줄 끝 표기 고치기', fields: ['stem'] });
    }
  }

  // sameRenderedMath 는 수식 기호 옆 띄어쓰기를 무시한다. 조사를 붙인 본문은 찍히는 모양이 다르므로 그대로 쓴다.
  if (stem.trim() !== origStem.trim() && (stemSpacingChanged || tableRowsChanged || !sameRenderedMath(stem, origStem))) patch.stem = stem;
  if (common !== origCommon) patch.common_stem = common;

  const solution = str(it.solution_transcribed);
  const solutionAnswer = str(it.solution_answer).trim();
  if (solution.trim() && str(it.solution_source) !== 'manual' && !owner.has('solution_transcribed')) {
    let next = cleanSolutionTranscribedText(solution, it.problem_number, solutionAnswer);
    if (next !== solution.trim()) {
      fixes.push({
        code: 'solution_text',
        title: next ? '해설 머리말·정답 줄 정리' : '해설 칸의 정답 줄 정리(풀이 없음)',
        fields: ['solution_transcribed'],
      });
    }
    if (problemNames && next) {
      const formatted = formatMockSolution(next, problemNames);
      if (formatted.intentChanged) fixes.push({ code: 'intent_mark', title: '출제의도 표기 통일', fields: ['solution_transcribed'] });
      if (formatted.namesChanged) fixes.push({ code: 'point_names', title: '점 이름 곧은 글자', fields: ['solution_transcribed'] });
      if (formatted.spacingChanged) {
        fixes.push({ code: 'particle_spacing', title: '수식 뒤 조사 붙여 쓰기', fields: ['solution_transcribed'] });
      }
      next = formatted.text;
    }
    if (next !== solution.trim()) patch.solution_transcribed = next;
  }

  // 그림 수와 그림 자리(렌더러: 자리 순서대로 그림을 쓰고, 남은 그림은 본문 끝에 붙인다)
  const texts = choiceTexts(choices);
  let stemMarkers = figureMarkerCount(stem);
  const choiceMarkers = texts.reduce((n, t) => n + figureMarkerCount(t), 0);
  const commonMarkers = figureMarkerCount(common);
  const orderedAssets = orderedFigureAssets(it.pb_figure_assets);
  const assets = orderedAssets.length;
  const imageChoices = texts.length >= 2 && texts.every((t) => !t.replace(/\[(?:그림|도형|도표)\]/g, '').trim()) &&
    assets === stemMarkers + texts.length;

  // 모의고사: 원본에서 선지 아래에 찍힌 그림은 조판에서도 선지 아래로 보낸다(엔진은 글 선지일 때만 그렇게 찍는다).
  const textChoices = texts.length >= 2 && choiceMarkers === 0 && !imageChoices;
  let belowLayout: Rec | null = null;
  if (ctx.mock && !owner.has('figure_layout') && textChoices) {
    belowLayout = figureLayoutBelowChoices(it, ctx.mock.choiceNumberRegion);
    if (belowLayout) {
      patch.figure_layout = belowLayout;
      fixes.push({ code: 'figure_below_choices', title: '그림을 선지 아래로', fields: ['figure_layout'] });
    }
  }

  // 모의고사: 그림이 선지 아래에 있으면 추출이 본문에 그림 자리를 적지 않기도 한다(2026 고3 6월 기하 27).
  // 자리가 없는 그림(렌더러는 자리 순서대로 그림을 쓰므로 뒤쪽 그림들)이 모두 원본에서 선지 아래에 있고 배치도
  // 선지 아래이면 본문 끝에 자리를 넣는다. 찍히는 모양은 그대로다(2026-11-23 사장님 결정).
  if (ctx.mock && !owner.has('stem') && textChoices && commonMarkers === 0 && assets > stemMarkers) {
    const below = figureOrdersBelowChoices(it, ctx.mock.choiceNumberRegion);
    const layoutNow = belowLayout ?? (it.pb_figure_layout && typeof it.pb_figure_layout === 'object' ? (it.pb_figure_layout as Rec) : null);
    const layoutItems = (Array.isArray(layoutNow?.items) ? (layoutNow!.items as unknown[]) : [])
      .filter((x): x is Rec => !!x && typeof x === 'object');
    const placedBelow = (i: number) => {
      const idx = Number.parseInt(str(orderedAssets[i].figure_index), 10);
      const item = layoutItems.find((x) => str(x.assetKey) === `idx:${idx}`) ??
        layoutItems.find((x) => str(x.assetKey) === `ord:${i + 1}`);
      return str(item?.position) === 'below-choices';
    };
    let allBelow = true;
    for (let i = stemMarkers; i < assets; i += 1) if (!below.has(i) || !placedBelow(i)) allBelow = false;
    if (allBelow) {
      stem = `${stem.trimEnd()}${'\n[그림]'.repeat(assets - stemMarkers)}`;
      patch.stem = stem;
      stemMarkers = assets;
      fixes.push({ code: 'figure_marker_below_choices', title: '선지 아래 그림의 자리 표시 넣기', fields: ['stem'] });
    }
  }

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

const numberKey = (v: unknown): string => {
  const n = Number.parseInt(str(v).replace(/[^0-9]/g, ''), 10);
  return Number.isFinite(n) ? String(n) : '';
};

/**
 * 검수 범위가 모의고사 구간 문서이면 문항 번호 → 선지 번호 자리(없으면 null)를, 아니면 null 을 돌려준다.
 * 모의고사 구간 문서는 mock_exam_sections.pb_document_id 로 안다(게이트웨이 mock_exam/review_staging.js 가 잇는다).
 */
async function mockChoiceRegions(auth: AuthContext, academyId: string, bookId: string): Promise<Map<string, unknown> | null> {
  const { data: section, error } = await auth.admin
    .from('mock_exam_sections')
    .select('exam_id,section')
    .eq('academy_id', academyId)
    .eq('pb_document_id', bookId)
    .maybeSingle();
  if (error) throw new Error(`모의고사 구간을 읽지 못했습니다: ${error.message}`);
  if (!section) return null;
  const { data, error: itemsError } = await auth.admin
    .from('mock_exam_items')
    .select('problem_number,choice_number_region_1k')
    .eq('exam_id', str((section as Rec).exam_id))
    .eq('section', str((section as Rec).section));
  if (itemsError) throw new Error(`모의고사 문항의 선지 자리를 읽지 못했습니다: ${itemsError.message}`);
  return new Map(((data ?? []) as Rec[]).map((r) => [numberKey(r.problem_number), r.choice_number_region_1k ?? null]));
}

/** AI 가 낸 해설 교정본(지적 ai_solution_logic 의 수정안) 가운데 아직 사장님이 고르지 않은 것 */
const SOLUTION_FIX_CHECK_KEY = 'ai_solution_logic';

/**
 * 모의고사: 사장님이 아직 고르지 않은 해설 교정본도 해설과 같은 표기('[출제의도]' 머리, 점 이름 곧은 글자)로 맞춘다.
 * 교정본은 고르는 순간 사람이 정한 값이 되어 그 뒤로는 코드가 고치지 않기 때문이다. 반환: 고친 교정본 수
 */
async function formatSolutionFixProposals(auth: AuthContext, items: Rec[]): Promise<number> {
  const byCrop = new Map(items.map((it) => [str(it.crop_id), it]));
  let changed = 0;
  for (const part of chunks([...byCrop.keys()], IN_CHUNK)) {
    const { data, error } = await auth.admin
      .from('textbook_review_findings')
      .select('id,crop_id,proposal')
      .in('crop_id', part)
      .eq('check_key', SOLUTION_FIX_CHECK_KEY)
      .in('status', ['open', 'held']);
    if (error) throw new Error(`해설 교정본을 읽지 못했습니다: ${error.message}`);
    for (const f of (data ?? []) as Rec[]) {
      const it = byCrop.get(str(f.crop_id));
      const proposal = f.proposal && typeof f.proposal === 'object' ? (f.proposal as Rec) : null;
      const after = proposal?.after && typeof proposal.after === 'object' ? (proposal.after as Rec) : null;
      const text = typeof after?.solution_transcribed === 'string' ? after.solution_transcribed : '';
      if (!it || !proposal || !after || !text.trim()) continue;
      const names = collectNameSets([str(it.stem), str(it.common_stem), ...choiceTexts(it.choices)]);
      const formatted = formatMockSolution(text, names).text;
      if (formatted === text) continue;
      const { error: updateError } = await auth.admin
        .from('textbook_review_findings')
        .update({ proposal: { ...proposal, after: { ...after, solution_transcribed: formatted } } })
        .eq('id', str(f.id));
      if (updateError) throw new Error(`해설 교정본을 고치지 못했습니다: ${updateError.message}`);
      changed += 1;
    }
  }
  return changed;
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
  // 모의고사 구간 문서일 때만 값이 있다(문항 번호 → 선지 번호 자리).
  let mockRegions: Map<string, unknown> | null;
  try {
    all = await loadItems();
    mockRegions = await mockChoiceRegions(auth, academyId, bookId);
  } catch (e) {
    return errorResponse(502, 'overview_failed', e instanceof Error ? e.message : String(e));
  }

  const check = async (list: Rec[]) => {
    const setFigures = setCommonFigureMap(list, await commonFigureCounts(auth, list));
    return new Map(
      list.filter(isTarget).map((it) => [
        str(it.crop_id),
        checkItemConsistency(it, {
          setHasCommonFigure: setFigures.get(str(it.crop_id)) ?? false,
          ...(mockRegions ? { mock: { choiceNumberRegion: mockRegions.get(numberKey(it.problem_number)) ?? null } } : {}),
        }),
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

  let proposalsFormatted = 0;
  if (mockRegions && !dryRun) {
    try {
      proposalsFormatted = await formatSolutionFixProposals(auth, targets);
    } catch (e) {
      errors.push(e instanceof Error ? e.message : String(e));
    }
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
    // 모의고사: 표기를 맞춘 해설 교정본 수(사장님이 아직 고르지 않은 것)
    proposals_formatted: proposalsFormatted,
    errors,
  });
}
