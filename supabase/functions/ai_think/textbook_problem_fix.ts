import { type AuthContext, errorResponse, jsonResponse, safetyIdentifier } from '../_shared/ai/auth.ts';
import { getBudgetStatus } from '../_shared/ai/budget.ts';
import { estimateCostUsd, modelFor, reasoningFor, thinkWallClockMs } from '../_shared/ai/config.ts';
import { createAiProvider } from '../_shared/ai/provider.ts';
import { type AiContentPart, finalText } from '../_shared/ai/types.ts';
import { recordAiRun } from '../_shared/ai/usage.ts';
import {
  cleanSolutionTranscribedText,
  figureMarkerCount,
  isFillInBlankProblem,
  normalizeProposedChoices,
  parseProblems,
  parseReviewImages,
  stripCommonStem,
  TEXTBOOK_REVIEW_PROMPT_VERSION,
} from './textbook_problem_review.ts';
import { uuidOrNull } from './validate.ts';

type Rec = Record<string, unknown>;

// ── 그림 배치 계산(순수 함수) ─────────────────────────────────────────────

/** V2 본문 줄 간격(em). 원본의 줄 간격도 비슷하다고 보고 본문 글줄 묶음 높이에서 글자 크기를 잰다. */
export const LINE_PITCH_EM = 1.7;
const GLYPH_EM = 1.0;
const MIN_WIDTH_EM = 4;
const MAX_WIDTH_EM = 40;

export type FigurePlacement = 'right_of_text' | 'left_of_text' | 'below_text' | 'inline';
export type FigureAlign = 'left' | 'center' | 'right';
export type FigureV2State = 'ok' | 'missing' | 'cut' | 'size' | 'position' | 'unknown';

export interface FigureMeasure {
  /** 원본 이미지 기준 [ymin, xmin, ymax, xmax] 0..1000 */
  bbox: [number, number, number, number];
  placement: FigurePlacement;
  align: FigureAlign;
  v2State: FigureV2State;
}

export function normalizeBox(v: unknown): [number, number, number, number] | null {
  if (!Array.isArray(v) || v.length !== 4) return null;
  const n = v.map((x) => Number(x));
  if (n.some((x) => !Number.isFinite(x))) return null;
  const [ymin, xmin, ymax, xmax] = n.map((x) => Math.max(0, Math.min(1000, Math.round(x))));
  if (ymax - ymin < 5 || xmax - xmin < 5) return null;
  return [ymin, xmin, ymax, xmax];
}

export function parseFigureMeasures(v: unknown): FigureMeasure[] {
  const out: FigureMeasure[] = [];
  for (const f of Array.isArray(v) ? v : []) {
    if (!f || typeof f !== 'object') continue;
    const r = f as Rec;
    const bbox = normalizeBox(r.bbox_1k);
    if (!bbox) continue;
    const placement = ['right_of_text', 'left_of_text', 'below_text', 'inline'].includes(String(r.placement))
      ? r.placement as FigurePlacement
      : 'below_text';
    const align = ['left', 'center', 'right'].includes(String(r.align)) ? r.align as FigureAlign : 'center';
    const v2State = ['ok', 'missing', 'cut', 'size', 'position'].includes(String(r.v2_state))
      ? r.v2_state as FigureV2State
      : 'unknown';
    out.push({ bbox, placement, align, v2State });
  }
  return out;
}

/**
 * 원본 이미지에서 본문 글자 1em 의 픽셀 크기. 연속한 본문 글줄 묶음(상자 높이, 줄 수)으로 잰다:
 * 높이 = (줄 수 - 1) × 줄 간격 + 글자 높이(1em).
 */
export function emPxFromTextSample(sample: unknown, imageHeightPx: number): number | null {
  if (!sample || typeof sample !== 'object' || !(imageHeightPx > 0)) return null;
  const r = sample as Rec;
  const box = normalizeBox(r.bbox_1k);
  const lines = Math.round(Number(r.lines));
  if (!box || !Number.isFinite(lines) || lines < 1 || lines > 30) return null;
  const hPx = ((box[2] - box[0]) / 1000) * imageHeightPx;
  const em = hPx / ((lines - 1) * LINE_PITCH_EM + GLYPH_EM);
  return em >= 4 ? em : null;
}

/** 원본 배치 → V2 figure_layout 항목(widthEm·position·anchor). 글자 크기를 못 쟀으면 기존 폭을 쓴다. */
export function figureLayoutItem(
  m: FigureMeasure,
  emPx: number | null,
  imageWidthPx: number,
  fallbackWidthEm: number,
): { widthEm: number; position: string; anchor: string; offsetXEm: number; offsetYEm: number } {
  const position = m.placement === 'right_of_text'
    ? 'inline-right'
    : m.placement === 'left_of_text'
    ? 'inline-left'
    : 'below-stem';
  const anchor = m.placement === 'right_of_text' ? 'right' : m.placement === 'left_of_text' ? 'left' : m.align;
  let widthEm = fallbackWidthEm;
  if (emPx && imageWidthPx > 0) {
    widthEm = (((m.bbox[3] - m.bbox[1]) / 1000) * imageWidthPx) / emPx;
  }
  widthEm = Math.round(Math.max(MIN_WIDTH_EM, Math.min(MAX_WIDTH_EM, widthEm)) * 2) / 2;
  return { widthEm, position, anchor, offsetXEm: 0, offsetYEm: 0 };
}

/** 렌더러(hydrateFiguresForXeLatex)와 같은 규칙: figure_index 별로 approved 우선 · 최신 우선 하나만, figure_index 순. */
export function orderedFigureAssets(assets: unknown): Rec[] {
  const byIdx = new Map<number, Rec>();
  for (const a of Array.isArray(assets) ? assets : []) {
    if (!a || typeof a !== 'object') continue;
    const r = a as Rec;
    const idx = Number.parseInt(String(r.figure_index ?? ''), 10);
    if (!Number.isFinite(idx) || idx <= 0) continue;
    const prev = byIdx.get(idx);
    if (!prev) {
      byIdx.set(idx, r);
      continue;
    }
    const pa = prev.approved === true ? 1 : 0;
    const ca = r.approved === true ? 1 : 0;
    if (ca > pa || (ca === pa && String(r.created_at ?? '') > String(prev.created_at ?? ''))) byIdx.set(idx, r);
  }
  return [...byIdx.entries()].sort((x, y) => x[0] - y[0]).map(([, r]) => r);
}

export interface FigureCropRequest {
  figure_index: number;
  /** 원본 이미지 기준 [ymin, xmin, ymax, xmax] 0..1000 */
  bbox_1k: number[];
  reason: 'missing' | 'cut';
}

export interface FigureProposal {
  layout: { version: number; items: Rec[]; groups: unknown[] };
  crops: FigureCropRequest[];
}

/**
 * 원본에서 잰 그림들(읽는 순서)을 문제은행 그림 자산(figure_index 순)에 차례로 짝지어 figure_layout 을 만든다.
 * 자산이 모자라면 새 figure_index 로, V2 에서 없거나 잘린 그림은 같은 figure_index 로 원본에서 다시 잘라 등록하도록 crops 에 남긴다.
 */
export function buildFigureProposal(args: {
  measures: FigureMeasure[];
  emPx: number | null;
  imageWidthPx: number;
  assets: unknown;
  currentLayout: unknown;
}): FigureProposal | null {
  const { measures, emPx, imageWidthPx } = args;
  const ordered = orderedFigureAssets(args.assets);
  if (measures.length === 0 && ordered.length === 0) return null;
  const maxIdx = ordered.reduce((m, a) => Math.max(m, Number.parseInt(String(a.figure_index), 10) || 0), 0);
  const cur = args.currentLayout && typeof args.currentLayout === 'object' ? args.currentLayout as Rec : {};
  const curItems = (Array.isArray(cur.items) ? cur.items : []).filter((x): x is Rec => !!x && typeof x === 'object');
  const curByKey = new Map(curItems.map((it) => [String(it.assetKey ?? ''), it]));
  const items: Rec[] = [];
  const crops: FigureCropRequest[] = [];
  const used = new Set<string>();
  let extra = 0;
  if (measures.length === 0) {
    ordered.forEach((asset, i) => {
      const idx = Number.parseInt(String(asset.figure_index), 10);
      const key = `idx:${idx}`;
      const prev = curByKey.get(key) ?? curByKey.get(`ord:${i + 1}`);
      const prevWidth = Number(prev?.widthEm);
      const prevHeight = Number(prev?.heightEm);
      items.push({
        assetKey: key,
        widthEm: Number.isFinite(prevWidth) && prevWidth > 0 ? prevWidth : 16,
        position: typeof prev?.position === 'string' && prev.position ? prev.position : 'below-stem',
        anchor: typeof prev?.anchor === 'string' && prev.anchor ? prev.anchor : 'center',
        offsetXEm: Number(prev?.offsetXEm) || 0,
        offsetYEm: Number(prev?.offsetYEm) || 0,
        heightEm: Number.isFinite(prevHeight) && prevHeight > 0 ? prevHeight : 1.6,
      });
      used.add(key);
    });
  } else {
    measures.forEach((m, i) => {
      const asset = ordered[i];
      const idx = asset ? Number.parseInt(String(asset.figure_index), 10) : maxIdx + (++extra);
      const key = `idx:${idx}`;
      const prev = curByKey.get(key) ?? curByKey.get(`ord:${i + 1}`);
      const prevWidth = Number(prev?.widthEm);
      const colFallback = Math.round(Math.max(MIN_WIDTH_EM, Math.min(MAX_WIDTH_EM, ((m.bbox[3] - m.bbox[1]) / 1000) * 26)) * 2) / 2;
      const item = figureLayoutItem(m, emPx, imageWidthPx, Number.isFinite(prevWidth) && prevWidth > 0 ? prevWidth : colFallback);
      const prevHeight = Number(prev?.heightEm);
      items.push({ assetKey: key, ...item, heightEm: Number.isFinite(prevHeight) && prevHeight > 0 ? prevHeight : 1.6 });
      used.add(key);
      if (!asset) crops.push({ figure_index: idx, bbox_1k: [...m.bbox], reason: 'missing' });
      else if (m.v2State === 'cut' || m.v2State === 'missing') crops.push({ figure_index: idx, bbox_1k: [...m.bbox], reason: 'cut' });
    });
  }
  for (const it of curItems) {
    const k = String(it.assetKey ?? '');
    if (k && !used.has(k)) items.push(it);
  }
  return {
    layout: { version: 1, items, groups: Array.isArray(cur.groups) ? cur.groups : [] },
    crops,
  };
}

export interface NormalizedTextFix {
  stem: string | null;
  commonStem: string | null;
  choices: Array<{ label: string; text: string }> | null;
  textSame: boolean;
}

/**
 * 모델이 낸 본문·공통 발문·선지 수정안을 정리한다.
 * - 모델이 text_matches_original=true 를 찍었어도 실제 corrected_* 를 적었으면 그 값을 그대로 쓴다.
 * - 공통 발문이 비어 있던 세트 문항도 세트 머리에서 읽은 corrected_common_stem 을 받는다.
 * - 개별 발문에 공통 지시문이 또 들어갔으면 떼어 내고, 떼어낸 뒤에도 바뀌었을 때만 stem 을 남긴다.
 */
export function normalizeTextFix(args: {
  textMatchesOriginal: unknown;
  correctedStem: unknown;
  correctedCommonStem: unknown;
  correctedChoices: unknown;
  currentStem: unknown;
  currentCommonStem: unknown;
  currentChoices: unknown;
}): NormalizedTextFix {
  const curStem = String(args.currentStem ?? '');
  const curCommon = String(args.currentCommonStem ?? '').trim();
  const rawStem = typeof args.correctedStem === 'string' && args.correctedStem.trim() ? args.correctedStem.trim() : null;
  const rawCommon = typeof args.correctedCommonStem === 'string' && args.correctedCommonStem.trim()
    ? args.correctedCommonStem.trim()
    : null;
  let stem = rawStem && rawStem !== curStem.trim() ? rawStem : null;
  const commonStem = rawCommon && rawCommon !== curCommon ? rawCommon : null;
  const effectiveCommon = commonStem ?? curCommon;
  if (stem && effectiveCommon) {
    const stripped = stripCommonStem(effectiveCommon, stem);
    if (stripped !== null) stem = stripped.trim() !== curStem.trim() ? stripped : null;
  } else if (!stem && commonStem) {
    // 공통 발문이 새로 생기거나 바뀌면서 기존 stem 앞머리에 그 지시문이 중복돼 있던 경우 함께 떼어낸다.
    const stripped = stripCommonStem(commonStem, curStem);
    if (stripped !== null && stripped.trim() !== curStem.trim()) stem = stripped;
  }
  const proposedChoices = normalizeProposedChoices(args.correctedChoices);
  const choices = proposedChoices && JSON.stringify(proposedChoices) !== JSON.stringify(args.currentChoices ?? [])
    ? proposedChoices
    : null;
  const hasAny = !!(stem || commonStem || choices);
  return {
    stem,
    commonStem,
    choices,
    textSame: !hasAny && args.textMatchesOriginal === true,
  };
}

/** 그림 자리가 모자라면 본문 끝에 [그림] 마커를 붙인다(렌더러는 마커 순서대로 그림을 놓는다). */
export function ensureFigureMarkers(stem: string, figureCount: number): string {
  const missing = figureCount - figureMarkerCount(stem);
  if (missing <= 0) return stem;
  return `${stem.replace(/\s+$/, '')}${'\n[그림]'.repeat(missing)}`;
}

// ── 수정 단계(원본 대조 수정안) ───────────────────────────────────────────

const FIX_SCHEMA: Rec = {
  type: 'object',
  additionalProperties: false,
  required: ['problems'],
  properties: {
    problems: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: [
          'crop_id',
          'text_matches_original',
          'corrected_stem',
          'corrected_common_stem',
          'corrected_choices',
          'fix_reason',
          'engine_issue',
          'figures',
          'text_sample',
          'proposed_answer',
          'proposed_ai_answer',
          'proposed_ai_solution',
          'proposed_solution_answer',
          'proposed_solution_transcribed',
          'corrected_solution_bbox_1k',
          'math_reason',
        ],
        properties: {
          crop_id: { type: 'string' },
          text_matches_original: { type: 'boolean' },
          corrected_stem: { type: ['string', 'null'] },
          corrected_common_stem: { type: ['string', 'null'] },
          corrected_choices: {
            type: ['array', 'null'],
            items: {
              type: 'object',
              additionalProperties: false,
              required: ['label', 'text'],
              properties: { label: { type: 'string' }, text: { type: 'string' } },
            },
          },
          fix_reason: { type: ['string', 'null'] },
          engine_issue: { type: ['string', 'null'] },
          proposed_answer: { type: ['string', 'null'] },
          proposed_ai_answer: { type: ['string', 'null'] },
          proposed_ai_solution: { type: ['string', 'null'] },
          proposed_solution_answer: { type: ['string', 'null'] },
          proposed_solution_transcribed: { type: ['string', 'null'] },
          corrected_solution_bbox_1k: {
            type: ['array', 'null'],
            items: { type: 'integer' },
          },
          math_reason: { type: ['string', 'null'] },
          figures: {
            type: 'array',
            items: {
              type: 'object',
              additionalProperties: false,
              required: ['bbox_1k', 'placement', 'align', 'v2_state'],
              properties: {
                bbox_1k: { type: 'array', items: { type: 'integer' } },
                placement: { type: 'string', enum: ['right_of_text', 'left_of_text', 'below_text', 'inline'] },
                align: { type: 'string', enum: ['left', 'center', 'right'] },
                v2_state: { type: 'string', enum: ['ok', 'missing', 'cut', 'size', 'position', 'unknown'] },
              },
            },
          },
          text_sample: {
            type: 'object',
            additionalProperties: false,
            required: ['bbox_1k', 'lines'],
            properties: {
              bbox_1k: { type: 'array', items: { type: 'integer' } },
              lines: { type: 'integer' },
            },
          },
        },
      },
    },
  },
};

const FIX_INSTRUCTIONS = `당신은 Yggdrasill 수학 문항 검수 엔진의 [수정 단계: 교재 원본 대조 수정안] 담당입니다.
각 문항마다 (가) 문제은행에 저장된 데이터(common_stem 공통 발문, stem 개별 발문, choices 선지 — 마크업 포함), (나) 교재 본문 PDF에서
이 문항 영역을 잘라낸 "원본 이미지"(세트 문항이면 공통 지시문이 인쇄된 "세트 머리 원본 이미지"도), (다) 지금 학생에게 보이는 "V2 렌더 화면",
(라) 앞 단계에서 지적된 문제(issues)가 주어집니다. 목표는 저장 데이터를 원본과 똑같은 문항으로 고친 전체 본문을 쓰고, 그림의 자리와 크기를 재는 것입니다.

[1. 본문·선지 수정안 — 원본 이미지가 기준]
- 원본에 인쇄된 이 문항(세트 머리 제외)을 처음부터 끝까지 다시 적은 전체 개별 발문을 corrected_stem 에 적으세요. 저장된 stem 이 원본과 완전히 같을 때만 null.
- 마크업은 저장 형식을 그대로 따릅니다: 수식 $...$(LaTeX), 문단 구분 [문단], 상자 [박스시작]...[박스끝], 표 [표시작]...[표끝], 빈칸 [[공백:n]] 등
  저장 stem 에 쓰인 표기를 유지하고, 그림 자리에는 [그림] 마커를 둡니다(그림이 본문 옆이나 아래에 있으면 그 그림이 딸린 문단의 끝).
- 빈칸형 문항(is_fill_in_blank = true, 예: "□ 안에 알맞은 수를 써넣어라", 결론 수식 "⇒ 90 = 2 × □ × 5" 등): 지시문이나 결론 수식에 들어 있는 네모(□, [[공백:n]], \\square)는 원본 그대로 유지해야 하는 정상 빈칸입니다. 빈칸을 지우거나 오류로 취급하지 마세요.
- 세트 문항(common_stem 이 있거나 세트 머리 원본 이미지가 함께 온 문항):
  - 학생 화면은 common_stem(세트 머리 지시문) 다음에 stem(이 문항 본문)을 이어 그립니다. corrected_stem 에 공통 지시문을 넣지 마세요.
  - 세트 머리 원본 이미지(또는 문항 원본 위쪽에 보이는 세트 지시문, 앞 단계 issues 에 적힌 원래 공통 지시문)와 저장된 common_stem 이 다르면
    (예: common_stem 이 비어 있거나, 지시문 대신 '36'·'36=2^2×3^2' 같은 첫 문항 식이나 예시만 들어 있거나, 지시문 문장이 빠졌을 때)
    반드시 세트 전체가 공유할 원래 공통 지시문 전체를 corrected_common_stem 에 적으세요! 같을 때만 null.
  - 저장된 stem 이나 common_stem 에 다른 문항(예: 세트 첫 문항)의 숫자·식이 잘못 섞여 있으면 이 문항 원본에 인쇄된 내용만 남기세요.
- 선지: 원본의 선지(①~⑤ 또는 ㄱ,ㄴ,ㄷ)와 저장 choices 가 다르면 전체 선지 배열을 corrected_choices 에, 같거나 원본에 선지가 없으면 null.
- 원본에 없는 내용을 지어내지 마세요. 원본에서 읽을 수 없는 부분은 저장값을 그대로 둡니다.
- text_matches_original: 저장 데이터(공통 발문·발문·선지)가 원본과 내용상 완전히 같고 V2 카드에도 빠진 지시문·엉뚱한 숫자가 없을 때만 true(이때만 corrected_* 가 모두 null). 앞 단계 issues 에 지시문 누락·내용 불일치가 지적됐으면 반드시 원본을 보고 corrected_stem 또는 corrected_common_stem 을 채우고 text_matches_original 은 false 로 두세요.
- engine_issue: 데이터는 원본과 같은데 V2 화면만 잘못 그려졌을 때(겹침·잘림·간격·기호 누락·마크업 노출) 짧은 증상. 아니면 null.
- fix_reason: 무엇을 왜 고쳤는지 한두 문장. 고친 것이 없으면 null.

[2. 그림 측정 — 개별 문항 원본 이미지 기준(세트 머리 이미지는 제외)]
- 원본 이미지 안의 그림·그래프·도형(글자로 된 표·상자는 제외)을 읽는 순서대로 figures 에 넣습니다. 없으면 [].
- bbox_1k: 원본 이미지 전체를 0..1000 으로 본 [ymin, xmin, ymax, xmax]. 그림의 선·점·라벨까지 다 들어가고 본문 글자는 들어가지 않게.
- placement: 본문 글 오른쪽에 나란히 있으면 "right_of_text", 왼쪽이면 "left_of_text", 본문 아래(또는 위)에 따로 있으면 "below_text",
  글줄 안에 끼어 있는 작은 그림이면 "inline".
- align: 그림의 가로 위치(left / center / right).
- v2_state: V2 화면에서 그 그림의 상태 — 정상 "ok", 없음 "missing", 잘리거나 일부만 보임 "cut", 크기가 눈에 띄게 다름 "size",
  자리가 다름 "position", V2 화면이 없으면 "unknown".
- text_sample: 원본 이미지에서 그림·선지·수식 블록이 끼지 않은 연속된 본문 글줄(2~4줄이 좋고, 1줄뿐이면 1줄)을 감싼 bbox_1k 와 그 줄 수 lines.
  글자 크기를 재는 데 씁니다. 본문 글줄이 없으면 bbox_1k = [], lines = 0.

[3. 정답·해설·AI 풀이 수정안 — 본문 PDF 원본 + 정답/해설 PDF 원본(영역 크롭 및 전체 쪽) 대조]
- 정답이 이상한 경우(math_status 가 "issue", 기존 저장 정답 existing_answer 가 비어 있음, "[image]" 로만 되어 있음, 또는 해설 정답·AI 정답과 불일치):
  - 본문 PDF 원본 이미지(세트 머리 지시문·표 구조·빈칸 위치 포함)와 정답/해설 PDF 원본 이미지를 직접 읽고 대조해, 학생 채점과 문제은행에 바로 저장할 정확한 최종 정답을 proposed_answer 에 적으세요.
  - 특히 정답이 표 빈칸 채우기이거나 이미지/다중 빈칸인 경우: 본문 표의 빈칸 순서(위→아래, 왼쪽→오른쪽)나 번호((1), (2)...)에 맞춰 정답/해설 이미지(또는 직접 푼 결과)의 값들을 빠짐없이 텍스트/LaTeX로 적으세요(예: "1, 3, 5, 15" 또는 "(1) 2 (2) 3"). 절대로 "[image]"나 "판단불가"로 적지 마세요.
  - 원본 본문 이미지(세트 지시문 포함)를 보고 처음부터 다시 푼 풀이를 proposed_ai_solution 에, 그 답을 proposed_ai_answer 에 적으세요.
  - 정답/해설 이미지가 주어졌으면 거기서 읽은 최종 정답을 proposed_solution_answer 에, 문항 번호·"답 ..." 줄·"[해설]" 머리말을 모두 뺀 순수 해설 본문만 proposed_solution_transcribed 에 적으세요(풀이 과정 없이 정답만 인쇄된 문항이면 null).
  - math_reason 에는 왜 이 정답으로 확정했는지 한 줄로 적으세요.
- 해설 좌표 어긋남 복구("해설 PDF 전체 페이지 이미지"가 함께 주어진 경우):
  - 수력충전 등 연산 교재는 한 해설 페이지 안에서 번호가 01번부터 여러 번 새로 시작하므로 기존 해설 크롭 좌표가 엉뚱한 블록을 가리켜 solution_vision_found = false 이거나 다른 문항의 답이 읽혔을 수 있습니다.
  - "해설 PDF 전체 페이지 이미지"가 주어졌으면 페이지 안에서 (1) 본문 쪽수 배지(예: "p.<body_display_page>", "P.<body_display_page>", "<body_page>쪽") 또는 소단원 제목(sub_key / item_name), (2) 문항 번호(problem_number), (3) 본문 문제의 수식·내용과 정확히 대응하는 정답·해설 위치를 페이지 전체에서 찾으세요.
  - 찾은 위치에서 최종 정답은 proposed_solution_answer 에, 순수 해설 본문은 proposed_solution_transcribed 에(풀이 없이 답만 있으면 null), 그리고 전체 페이지 이미지(0..1000) 기준 해당 문항 정답·해설 블록의 영역 좌표 [ymin, xmin, ymax, xmax] 를 corrected_solution_bbox_1k 에 적으세요. 전체 페이지 이미지가 없거나 찾지 못했으면 corrected_solution_bbox_1k 는 null 로 두세요.
- 수학 정답이 이미 일치하고(math_status 가 "approved" 또는 "clean") 기존 정답도 정상이며 해설도 이미 확인된 경우(solution_vision_found !== false)에는 proposed_answer, proposed_ai_answer, proposed_ai_solution, proposed_solution_answer, proposed_solution_transcribed, corrected_solution_bbox_1k, math_reason 은 모두 null 로 두세요.`;

const MAX_FIX_CHUNK = 4;

/**
 * 품질 이상 문항·그림 문항의 수정 단계. 매니저앱이 원본 이미지(본문 PDF 좌표 렌더)와 V2 문항 카드를 보내면
 * 원본과 같아지도록 고친 전체 본문·선지·공통 발문과 그림 배치(figure_layout)·다시 잘라낼 그림을 fix_proposal 에 쓴다.
 * 문제은행(pb_questions)은 건드리지 않는다. 적용은 운영자 승인 또는 품질 일괄 처리가 한다.
 *   body: { academy_id, book_id, grade_label, big_order, mid_order, crop_ids: [...], images: { [crop_id]: {...} } }
 */
export async function handleTextbookProblemFix(req: Request, auth: AuthContext, body: Rec): Promise<Response> {
  const academyId = uuidOrNull(body.academy_id);
  const bookId = uuidOrNull(body.book_id);
  const gradeLabel = typeof body.grade_label === 'string' ? body.grade_label.trim() : '';
  const bigOrder = Number(body.big_order);
  const midOrder = Number(body.mid_order);
  if (!academyId || !bookId || !gradeLabel || !Number.isInteger(bigOrder) || !Number.isInteger(midOrder)) {
    return errorResponse(400, 'invalid_scope', '학원, 교재, 학년, 중단원 정보가 필요합니다.');
  }
  const cropIds = (Array.isArray(body.crop_ids) ? body.crop_ids as unknown[] : [])
    .map((x) => uuidOrNull(x))
    .filter((x): x is string => !!x)
    .slice(0, MAX_FIX_CHUNK);
  const images = parseReviewImages(body.images);
  if (cropIds.length === 0) return jsonResponse({ ok: true, processed: 0, results: [] });

  const wallClockMs = thinkWallClockMs();
  const provider = createAiProvider({ timeoutMs: wallClockMs + 5000 });
  if (!provider) return errorResponse(503, 'ai_not_configured', 'OPENAI_API_KEY 비밀값이 설정되지 않았습니다.');
  const budget = await getBudgetStatus(auth.admin).catch(() => null);
  if (budget?.exceeded && budget.mode === 'block') {
    return errorResponse(429, 'budget_exceeded', '이번 달 AI 한도를 넘었습니다.');
  }

  const overviewRes = await auth.userClient.rpc('textbook_review_unit_overview', {
    p_academy_id: academyId,
    p_book_id: bookId,
    p_grade_label: gradeLabel,
    p_big_order: bigOrder,
    p_mid_order: midOrder,
  });
  if (overviewRes.error) return errorResponse(502, 'overview_failed', overviewRes.error.message);
  const wanted = new Set(cropIds);
  const targets = (((overviewRes.data as Rec | null)?.items ?? []) as unknown[])
    .map((x) => (x ?? {}) as Rec)
    .filter((it) => wanted.has(String(it.crop_id)) && !!images.get(String(it.crop_id))?.originalImageDataUrl);
  if (targets.length === 0) {
    return jsonResponse({ ok: true, processed: 0, skipped: cropIds.length, results: [] });
  }

  const startedAt = Date.now();
  const model = modelFor('primary');
  const safetyId = await safetyIdentifier(auth.userId);
  const signal = AbortSignal.any([req.signal, AbortSignal.timeout(wallClockMs)]);

  const parts: AiContentPart[] = [{
    type: 'text',
    text: JSON.stringify({
      problems: targets.map((it) => {
        const qc = (it.quality_checks ?? {}) as Rec;
        const rc = (it.render_checks ?? {}) as Rec;
        const sv = (qc.solution_vision ?? {}) as Rec;
        return {
          crop_id: it.crop_id,
          problem_number: it.problem_number,
          body_page: it.raw_page ?? null,
          body_display_page: it.display_page ?? it.raw_page ?? null,
          sub_key: String(it.sub_key ?? '').trim(),
          sub_index: it.sub_index ?? 0,
          item_name: String(it.item_name ?? '').trim(),
          question_type: it.question_type,
          is_fill_in_blank: isFillInBlankProblem(it.common_stem, it.stem),
          is_set_question: String(it.common_stem ?? '').trim().length > 0 ||
            String(it.set_type ?? '').trim().length > 0 ||
            String(it.set_header_number ?? '').trim().length > 0 ||
            !!images.get(String(it.crop_id))?.setHeaderImageDataUrl,
          set_header_number: String(it.set_header_number ?? '').trim(),
          common_stem: String(it.common_stem ?? '').trim(),
          stem: String(it.stem ?? '').slice(0, 4000),
          choices: it.choices,
          existing_answer: it.existing_answer ?? null,
          answer_kind: it.answer_kind ?? null,
          pb_objective_answer_key: it.pb_objective_answer_key ?? '',
          pb_subjective_answer: it.pb_subjective_answer ?? '',
          solution_answer: it.solution_answer ?? null,
          solution_transcribed: typeof it.solution_transcribed === 'string' ? it.solution_transcribed.slice(0, 2000) : null,
          solution_vision_found: typeof sv.found === 'boolean' ? sv.found : null,
          ai_answer: it.ai_answer ?? null,
          math_status: it.math_status ?? 'pending',
          quality_status: it.quality_status ?? 'pending',
          figure_asset_count: orderedFigureAssets(it.pb_figure_assets).length,
          stem_figure_markers: figureMarkerCount(it.stem),
          issues: {
            math_mismatch: it.math_status === 'issue' ? (it.mismatch_reason ?? '기존 정답·해설 정답·AI 정답 불일치 또는 미저장') : null,
            solution_missing: sv.found === false ? (sv.note ?? '기존 해설 좌표 영역에서 해당 문항의 정답·해설을 찾지 못함') : null,
            problem_card: qc.issue_title ? `${qc.issue_title}: ${qc.issue_detail ?? ''}` : null,
            render_check: rc.issue_title ? `${rc.issue_title}: ${rc.issue_detail ?? ''}` : null,
          },
        };
      }),
    }),
  }];
  for (const it of targets) {
    const cid = String(it.crop_id);
    const img = images.get(cid)!;
    parts.push({ type: 'text', text: `[crop_id=${cid} · ${it.problem_number}번 교재 원본 이미지(본문 PDF ${it.raw_page ?? '-'}쪽 문항 영역)]` });
    parts.push({ type: 'image', url: img.originalImageDataUrl!, detail: 'high' });
    if (img.setHeaderImageDataUrl) {
      parts.push({ type: 'text', text: `[crop_id=${cid} · ${it.problem_number}번이 속한 세트 머리(공통 지시문) 원본 이미지]` });
      parts.push({ type: 'image', url: img.setHeaderImageDataUrl, detail: 'auto' });
    }
    if (img.solutionImageDataUrl) {
      parts.push({ type: 'text', text: `[crop_id=${cid} · ${it.problem_number}번 정답/해설 PDF 영역 크롭 이미지]` });
      parts.push({ type: 'image', url: img.solutionImageDataUrl, detail: 'high' });
    }
    if (img.solutionPageImageDataUrl) {
      parts.push({
        type: 'text',
        text:
          `[crop_id=${cid} · ${it.problem_number}번 해설 PDF ${img.solutionPageRawPage ?? it.solution_raw_page ?? '-'}쪽 전체 페이지 이미지 (본문 표시쪽 ${it.display_page ?? it.raw_page ?? '-'}쪽 · 소단원 "${it.sub_key ?? ''}" · 문항 내용과 대조해 해당 문항 블록 탐색)]`,
      });
      parts.push({ type: 'image', url: img.solutionPageImageDataUrl, detail: 'high' });
    }
    if (img.v2ProblemUrl) {
      parts.push({ type: 'text', text: `[crop_id=${cid} · ${it.problem_number}번 V2 렌더 화면(지금 학생이 보는 화면)]` });
      parts.push({ type: 'image', url: img.v2ProblemUrl, detail: 'high' });
    }
  }

  const res = await provider.complete(
    {
      model,
      instructions: FIX_INSTRUCTIONS,
      input: [{ kind: 'message', role: 'user', parts }],
      jsonSchema: { name: 'textbook_problem_fix', schema: FIX_SCHEMA },
      reasoningEffort: reasoningFor('primary'),
      maxOutputTokens: 14000,
      safetyId,
    },
    signal,
  );
  const byCrop = parseProblems(finalText(res));
  const costUsd = estimateCostUsd(model, res.usage, 0);
  await recordAiRun(auth.admin, {
    feature: 'textbook_problem_fix',
    provider: provider.name,
    model,
    promptVersion: TEXTBOOK_REVIEW_PROMPT_VERSION,
    status: 'ok',
    error: null,
    usage: res.usage,
    webSearchCalls: 0,
    toolCalls: 0,
    costUsd,
    latencyMs: Date.now() - startedAt,
    conversationId: null,
    createdBy: auth.userId,
    features: { book_id: bookId, grade_label: gradeLabel, big_order: bigOrder, mid_order: midOrder, count: targets.length },
  });

  const nowIso = new Date().toISOString();
  const results: Rec[] = [];
  for (const it of targets) {
    const cid = String(it.crop_id);
    const r = byCrop.get(cid);
    if (!r) continue;
    const img = images.get(cid)!;
    const prev = (it.fix_proposal ?? {}) as Rec;
    const curStem = String(it.stem ?? '');
    const curCommon = String(it.common_stem ?? '').trim();

    // 규칙(공통 발문 중복) 제안이 아직 적용 전이면 본문 제안은 그대로 두고 그림만 더한다.
    const keepRuleText = prev.reason_code === 'common_stem_duplicate' && !prev.applied_at;
    const textFix = normalizeTextFix({
      textMatchesOriginal: r.text_matches_original,
      correctedStem: r.corrected_stem,
      correctedCommonStem: r.corrected_common_stem,
      correctedChoices: r.corrected_choices,
      currentStem: curStem,
      currentCommonStem: curCommon,
      currentChoices: it.choices,
    });
    let stem = textFix.stem;
    const common = textFix.commonStem;
    const choices = textFix.choices;
    const textSame = textFix.textSame;

    const measures = parseFigureMeasures(r.figures);
    const size = img.originalSize;
    const sampleLines = r.text_sample && typeof r.text_sample === 'object' ? Math.round(Number((r.text_sample as Rec).lines)) : 0;
    const rawEmPx = size ? emPxFromTextSample(r.text_sample, size.height) : null;
    // 1줄짜리 발문(예: "90을 소인수분해 하는 과정이다. □ 안에 알맞은 수를 써넣어라.")은 글자 상자 높이가 좁게 잡혀
    // 1em 이 과소 추정되고 그림 폭(widthEm)이 1.3배 이상 커질 수 있다. 2단 교재 1단 폭(약 26~27em)을 하한으로 쓴다.
    const emPx = rawEmPx && size && size.width > 0 && sampleLines <= 1
      ? Math.max(rawEmPx, size.width / 27)
      : (rawEmPx ?? (size && size.width > 0 ? size.width / 26 : null));
    const figure = buildFigureProposal({
      measures,
      emPx,
      imageWidthPx: size?.width ?? 0,
      assets: it.pb_figure_assets,
      currentLayout: it.pb_figure_layout,
    });
    // 새로 등록할 그림이 있는데 본문에 그림 자리가 모자라면 마커를 붙인다.
    if (figure && figure.crops.some((c) => c.reason === 'missing')) {
      const base = keepRuleText && typeof prev.stem === 'string' ? prev.stem : (stem ?? curStem);
      const withMarkers = ensureFigureMarkers(base, measures.length);
      if (withMarkers !== base) stem = withMarkers;
    }

    const trimOrNull = (v: unknown) => typeof v === 'string' && v.trim() && v.trim() !== '판단불가' ? v.trim() : null;
    const proposedAnswer = trimOrNull(r.proposed_answer) ??
      (it.math_status === 'issue'
        ? (trimOrNull(r.proposed_solution_answer) ?? trimOrNull(r.proposed_ai_answer) ??
          trimOrNull(prev.proposed_answer) ?? trimOrNull(it.solution_answer) ?? trimOrNull(it.ai_answer))
        : trimOrNull(prev.proposed_answer));
    const proposedAiAnswer = trimOrNull(r.proposed_ai_answer);
    const proposedAiSolution = trimOrNull(r.proposed_ai_solution);
    const proposedSolAnswer = trimOrNull(r.proposed_solution_answer);
    const cleanedSolText = typeof r.proposed_solution_transcribed === 'string' && r.proposed_solution_transcribed.trim()
      ? cleanSolutionTranscribedText(r.proposed_solution_transcribed, it.problem_number, proposedSolAnswer ?? proposedAnswer ?? it.solution_answer)
      : '';
    const proposedSolTranscribed = cleanedSolText || null;
    const correctedSolBox = normalizeBox(r.corrected_solution_bbox_1k);
    const mathReason = trimOrNull(r.math_reason) ?? trimOrNull(prev.math_reason);

    const hasText = !!(stem || common || choices);
    const engineSymptom = typeof r.engine_issue === 'string' && r.engine_issue.trim() ? r.engine_issue.trim() : null;
    const fixProposal: Rec = {
      kind: hasText ? 'data' : figure ? 'figure' : engineSymptom ? 'engine' : 'none',
      stem,
      common_stem: common,
      choices,
      proposed_answer: proposedAnswer,
      proposed_ai_answer: proposedAiAnswer,
      proposed_ai_solution: proposedAiSolution,
      proposed_solution_answer: proposedSolAnswer,
      proposed_solution_transcribed: proposedSolTranscribed,
      corrected_solution_bbox_1k: correctedSolBox,
      math_reason: mathReason,
      reason: typeof r.fix_reason === 'string' && r.fix_reason.trim() ? r.fix_reason.trim() : null,
      reason_code: null,
      source: 'fix_pass',
      text_matches_original: textSame,
      engine_issue: engineSymptom,
      figure_layout: figure?.layout ?? null,
      figure_crops: figure?.crops ?? [],
      figure_measure: {
        figures: measures.map((m) => ({ bbox_1k: m.bbox, placement: m.placement, align: m.align, v2_state: m.v2State })),
        text_sample: r.text_sample ?? null,
        em_px: emPx === null ? null : Math.round(emPx * 10) / 10,
        image_px: size ? [size.width, size.height] : null,
        region_1k: img.originalRegion1k,
        raw_page: img.originalRawPage,
      },
      fix_pass_at: nowIso,
      created_at: nowIso,
    };
    if (keepRuleText) {
      for (const k of ['kind', 'stem', 'common_stem', 'choices', 'reason', 'reason_code', 'source']) fixProposal[k] = prev[k] ?? null;
      if (stem && figure?.crops.some((c) => c.reason === 'missing')) fixProposal.stem = stem;
    }

    // 본문·그림 수정이 전혀 필요 없고 조판 엔진 문제만 있는 문항은 바로 보류(held)로 전환한다.
    const autoHoldEngine = !hasText && !figure && !!engineSymptom &&
      it.quality_status !== 'approved' && it.quality_status !== 'held';
    const keepManualSol = it.solution_source === 'manual' && typeof it.solution_transcribed === 'string' && it.solution_transcribed.trim();
    const curQc = (it.quality_checks ?? {}) as Rec;
    const curSv = (curQc.solution_vision ?? {}) as Rec;
    const recoveredSol = !keepManualSol && !!(proposedSolAnswer || proposedSolTranscribed);
    const updatePatch: Rec = {
      fix_proposal: fixProposal,
      updated_at: nowIso,
      ...(proposedAiAnswer && (!it.ai_answer || it.ai_answer === '판단불가' || it.math_status === 'issue')
        ? {
          ai_answer: proposedAiAnswer,
          ...(proposedAiSolution ? { ai_solution: proposedAiSolution } : {}),
        }
        : {}),
      ...(recoveredSol
        ? {
          ...(proposedSolAnswer && (!it.solution_answer || curSv.found === false || it.math_status === 'issue')
            ? { solution_answer: proposedSolAnswer }
            : {}),
          ...(proposedSolTranscribed && (!it.solution_transcribed || curSv.found === false)
            ? { solution_transcribed: proposedSolTranscribed }
            : {}),
          solution_source: it.solution_source ?? 'textbook_vision',
          solution_extracted_at: nowIso,
          quality_checks: {
            ...curQc,
            solution_vision: {
              found: true,
              confidence: 'high',
              note: img.solutionPageImageDataUrl
                ? '해설 PDF 전체 페이지에서 블록·문항 대조로 탐색 완료'
                : (curSv.note ?? null),
            },
          },
        }
        : {}),
      ...(autoHoldEngine
        ? {
          quality_status: 'held',
          engine_held_at: nowIso,
          engine_held_by: auth.userId,
          engine_hold_note: engineSymptom,
        }
        : {}),
    };

    await auth.admin.from('textbook_problem_analyses').update(updatePatch).eq('crop_id', cid);
    if (recoveredSol) {
      await auth.admin
        .from('textbook_review_findings')
        .update({ status: 'resolved', resolution: 'auto_cleared', resolved_at: nowIso })
        .eq('crop_id', cid)
        .eq('check_key', 'ai_solution_vision')
        .in('status', ['open', 'held']);
    }
    const solPage = img.solutionPageRawPage ?? (Number(it.solution_raw_page) || 0);
    if (correctedSolBox && solPage > 0) {
      await auth.admin
        .from('textbook_problem_solution_refs')
        .update({
          raw_page: solPage,
          content_region_1k: correctedSolBox,
          updated_at: nowIso,
        })
        .eq('crop_id', cid)
        .is('edited_at', null);
    }
    if (autoHoldEngine) {
      await auth.admin
        .from('textbook_review_findings')
        .update({ status: 'held' })
        .eq('crop_id', cid)
        .in('axis', ['fidelity', 'output'])
        .eq('status', 'open');
    }
    results.push({
      crop_id: cid,
      has_text_fix: !!(fixProposal.stem || fixProposal.common_stem || fixProposal.choices),
      has_math_fix: !!proposedAnswer,
      figures: measures.length,
      figure_crops: figure?.crops.length ?? 0,
      text_matches_original: textSame,
      held_engine: autoHoldEngine,
    });
  }

  return jsonResponse({ ok: true, processed: results.length, results, cost_usd: costUsd });
}
