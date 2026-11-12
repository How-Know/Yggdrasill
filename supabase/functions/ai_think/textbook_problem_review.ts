import { type AuthContext, errorResponse, jsonResponse, safetyIdentifier } from '../_shared/ai/auth.ts';
import { getBudgetStatus } from '../_shared/ai/budget.ts';
import { estimateCostUsd, modelFor, reasoningFor, thinkWallClockMs } from '../_shared/ai/config.ts';
import { createAiProvider } from '../_shared/ai/provider.ts';
import { type AiContentPart, addUsage, emptyUsage, finalText } from '../_shared/ai/types.ts';
import { recordAiRun } from '../_shared/ai/usage.ts';
import { uuidOrNull } from './validate.ts';

type Rec = Record<string, unknown>;

export const TEXTBOOK_REVIEW_PROMPT_VERSION = 'textbook-problem-review-2026-11-10';

/** 품질 이상의 원인 분류. data=문항 데이터(본문·선지) 오류, engine=조판 엔진 문제, figure=도형 자산 문제 */
export type IssueKind = 'none' | 'data' | 'engine' | 'figure';

export function normalizeIssueKind(v: unknown, hasIssue: boolean): IssueKind {
  if (!hasIssue) return 'none';
  return v === 'engine' || v === 'figure' || v === 'data' ? v : 'data';
}

/** 모델이 낸 선지 수정안을 {label,text}[] 로 정리한다. 형식이 맞지 않으면 null. */
export function normalizeProposedChoices(v: unknown): Array<{ label: string; text: string }> | null {
  if (!Array.isArray(v) || v.length === 0) return null;
  const out: Array<{ label: string; text: string }> = [];
  for (const c of v as unknown[]) {
    if (!c || typeof c !== 'object') return null;
    const r = c as Rec;
    const label = String(r.label ?? '').trim();
    const text = String(r.text ?? '').trim();
    if (!label) return null;
    out.push({ label, text });
  }
  return out;
}

/**
 * 매니저앱이 문항마다 함께 보내는 이미지. 해설 크롭·교재 원본(본문 PDF 문항 영역, 세트 머리 영역)은 앱이 PDF 좌표로
 * 잘라 base64로, V2 렌더는 서명 URL로 온다. 원본 크롭 PNG는 저장소에 없으므로 서버는 원본을 따로 찾지 않는다.
 */
export interface ReviewImageInput {
  solutionImageDataUrl: string | null;
  v2ProblemUrl: string | null;
  originalImageDataUrl: string | null;
  /** 원본 이미지 픽셀 크기(그림 크기 계산용). 앱이 함께 보낸다. */
  originalSize: { width: number; height: number } | null;
  /** 원본을 잘라낸 쪽 좌표 [ymin, xmin, ymax, xmax] 0..1000(여백 포함)과 쪽 번호. 그림을 원본에서 다시 잘라낼 때 쓴다. */
  originalRegion1k: number[] | null;
  originalRawPage: number | null;
  setHeaderImageDataUrl: string | null;
  /** 세트 머리 원본 픽셀 크기와 쪽 좌표(여백 포함). 공통 발문 그림을 세트 머리에서 잘라낼 때 쓴다. */
  setHeaderSize: { width: number; height: number } | null;
  setHeaderRegion1k: number[] | null;
  setHeaderRawPage: number | null;
  /** 해설 좌표 어긋남·미전사·답 불일치 때 보내는 해설 PDF 한 쪽 전체 이미지와 쪽 번호 */
  solutionPageImageDataUrl: string | null;
  solutionPageRawPage: number | null;
}

const MAX_SOLUTION_IMAGE_CHARS = 4_000_000; // base64 약 3MB

export function imageDataUrl(b64Raw: unknown, mimeRaw: unknown): string | null {
  const b64 = typeof b64Raw === 'string' ? b64Raw.trim() : '';
  const mime = typeof mimeRaw === 'string' && /^image\/(png|jpeg|webp)$/.test(mimeRaw) ? mimeRaw : 'image/png';
  return b64 && b64.length <= MAX_SOLUTION_IMAGE_CHARS && /^[A-Za-z0-9+/=]+$/.test(b64)
    ? `data:${mime};base64,${b64}`
    : null;
}

export function parseReviewImages(raw: unknown): Map<string, ReviewImageInput> {
  const out = new Map<string, ReviewImageInput>();
  if (!raw || typeof raw !== 'object') return out;
  for (const [cropId, v] of Object.entries(raw as Rec)) {
    if (!uuidOrNull(cropId) || !v || typeof v !== 'object') continue;
    const r = v as Rec;
    const url = typeof r.v2_problem_url === 'string' ? r.v2_problem_url.trim() : '';
    const original = imageDataUrl(r.original_image_base64, r.original_image_mime);
    const w = Number(r.original_width_px);
    const h = Number(r.original_height_px);
    const region1k = (v: unknown) =>
      Array.isArray(v) && v.length === 4 && v.every((x) => Number.isFinite(Number(x)))
        ? (v as unknown[]).map((x) => Math.round(Number(x)))
        : null;
    const region = region1k(r.original_region_1k);
    const page = Number(r.original_raw_page);
    const header = imageDataUrl(r.set_header_image_base64, r.set_header_image_mime);
    const hw = Number(r.set_header_width_px);
    const hh = Number(r.set_header_height_px);
    const hPage = Number(r.set_header_raw_page);
    const solPageImg = imageDataUrl(r.solution_page_image_base64, r.solution_page_image_mime);
    const solPage = Number(r.solution_page_raw_page);
    out.set(cropId, {
      solutionImageDataUrl: imageDataUrl(r.solution_image_base64, r.solution_image_mime),
      v2ProblemUrl: /^https:\/\//.test(url) ? url : null,
      originalImageDataUrl: original,
      originalSize: original && w > 0 && h > 0 ? { width: Math.round(w), height: Math.round(h) } : null,
      originalRegion1k: original ? region : null,
      originalRawPage: original && Number.isInteger(page) && page > 0 ? page : null,
      setHeaderImageDataUrl: header,
      setHeaderSize: header && hw > 0 && hh > 0 ? { width: Math.round(hw), height: Math.round(hh) } : null,
      setHeaderRegion1k: header ? region1k(r.set_header_region_1k) : null,
      setHeaderRawPage: header && Number.isInteger(hPage) && hPage > 0 ? hPage : null,
      solutionPageImageDataUrl: solPageImg,
      solutionPageRawPage: solPageImg && Number.isInteger(solPage) && solPage > 0 ? solPage : null,
    });
  }
  return out;
}

/** 본문 안 그림 마커 수([그림]·[도형]·[도표]·[[PB_FIG_id]]). 렌더러가 마커 순서대로 그림을 소비한다. */
export function figureMarkerCount(stem: unknown): number {
  return (String(stem ?? '').match(/\[\[PB_FIG_[^\]]+\]\]|\[(?:그림|도형|도표)\]/g) ?? []).length;
}

/** 세트 문항은 공통 지시문과 개별 문항을 합쳐 읽는다. */
export function combineStem(commonStem: unknown, stem: unknown): string {
  const c = String(commonStem ?? '').trim();
  const s = String(stem ?? '').trim();
  if (c && !s.includes(c)) return `[공통 지시문] ${c}\n[문항] ${s}`;
  return s;
}

/** 1)·2)·3) 소문항을 한 문항에 묶은 종속형 세트. 렌더러·학습앱은 이 문항의 본문(stem)만 그린다. */
export function isDependentSetItem(it: Record<string, unknown>): boolean {
  return String(it.set_type ?? '').trim() === 'dependent_set';
}

/**
 * 종속형 세트는 공통 발문을 따로 그리지 않으므로 검수·수정에 공통 발문을 넘기지 않는다
 * (넘기면 본문에서 지시문을 떼어 세트 정보로 옮기는 수정이 나와 학생 화면에서 지시문이 사라진다).
 */
export function withoutDependentSetCommonStem<T extends Record<string, unknown>>(it: T): T {
  if (!isDependentSetItem(it) || !String(it.common_stem ?? '').trim()) return it;
  return { ...it, common_stem: '' };
}

/** 종속형 세트에 나온 공통 지시문 제안을 본문 앞에 붙인 본문 제안으로 바꾼다(이미 본문 앞머리에 있으면 그대로). */
export function foldCommonStemIntoStem(commonStem: string, stem: string): string {
  const c = commonStem.trim();
  if (!c) return stem;
  return stripCommonStem(c, stem) !== null ? stem : `${c}\n[문단]\n${stem.trim()}`;
}

const GUIDED_SOLUTION_START = /^\[?해\]?\s+\S/;
const SUB_QUESTION_START = /^(?:\[소문항\d*\]|\(?\d+\)\s?)/;

/**
 * 교재가 문항 아래에 '해' 배지로 인쇄한 빈칸 풀이 안내(해설의 일부)를 본문에서 뺀다.
 * '해' 줄부터 다음 소문항(2), [소문항n]) 앞까지 지우고, 그 안내만 감싼 상자 표시도 함께 지운다.
 * 앞에 문제 글이 없는(그림·마크업뿐인) '해' 줄은 본문 자체로 보고 건드리지 않는다.
 */
export function stripGuidedSolution(stem: string): string {
  if (!/(?:^|\n|\])\s*\[?해\]?\s/.test(stem)) return stem.trim();
  const lines = stem.replace(/[ \t]*(\[(?:문단|박스시작|박스끝)\])[ \t]*/g, '\n$1\n').split('\n').filter((l) => l.trim());
  const out: string[] = [];
  const boxes: Array<'keep' | 'drop'> = [];
  let inGuide = false;
  let removed = false;
  const hasContent = () => out.some((l) => /[가-힣A-Za-z0-9]/.test(l.replace(/\[[^\]]*\]/g, '')));
  const nextContent = (from: number) =>
    lines.slice(from).map((l) => l.trim()).find((l) => l && l !== '[문단]') ?? '';
  for (let i = 0; i < lines.length; i++) {
    const t = lines[i].trim();
    if (inGuide && SUB_QUESTION_START.test(t)) inGuide = false;
    if (t === '[박스시작]') {
      const guideBox = inGuide || (hasContent() && GUIDED_SOLUTION_START.test(nextContent(i + 1)));
      boxes.push(guideBox ? 'drop' : 'keep');
      if (!guideBox) out.push(lines[i]);
      continue;
    }
    if (t === '[박스끝]') {
      const kind = boxes.pop() ?? 'keep';
      if (kind === 'drop') {
        if (!boxes.includes('drop')) inGuide = false;
        continue;
      }
      inGuide = false;
      out.push(lines[i]);
      continue;
    }
    if (inGuide) continue;
    if (GUIDED_SOLUTION_START.test(t) && hasContent()) {
      inGuide = true;
      removed = true;
      continue;
    }
    out.push(lines[i]);
  }
  const collapsed: string[] = [];
  for (const l of out) {
    const t = l.trim();
    const last = collapsed.length ? collapsed[collapsed.length - 1].trim() : '';
    if (t === '[문단]' && (!last || last === '[문단]' || last === '[박스시작]')) continue;
    if (t === '[박스끝]' && last === '[문단]') collapsed.pop();
    collapsed.push(l);
  }
  while (collapsed.length && collapsed[collapsed.length - 1].trim() === '[문단]') collapsed.pop();
  if (!removed) return stem.trim();
  const result = collapsed.join('\n').trim();
  return result || stem.trim();
}

/**
 * 공통 발문(common_stem)이 개별 발문(stem) 앞머리에 그대로 들어 있으면(공백·[문단] 차이는 무시)
 * 공통 부분을 떼어낸 개별 본문을 돌려준다. 중복이 없거나 떼어내면 본문이 비는 경우 null.
 * 학생 화면은 공통 발문 + 개별 발문을 이어 그리므로 이 중복은 지시문이 두 번 보이는 데이터 오류다.
 */
export function stripCommonStem(commonStem: unknown, stem: unknown): string | null {
  const c = String(commonStem ?? '').replace(/\s+/g, '');
  const s = String(stem ?? '');
  if (!c || !s.trim()) return null;
  const para = '[문단]';
  let i = 0;
  let j = 0;
  while (i < s.length && j < c.length) {
    const ch = s[i];
    if (/\s/.test(ch)) {
      i++;
      continue;
    }
    if (s.startsWith(para, i) && !c.startsWith(para, j)) {
      i += para.length;
      continue;
    }
    if (ch !== c[j]) break;
    i++;
    j++;
  }
  let rest: string | null = null;
  if (j >= c.length) {
    rest = s.slice(i);
  } else {
    // 앞머리가 아니면 정확히 같은 문자열이 들어 있는 경우만 제거한다.
    const exact = String(commonStem ?? '').trim();
    const at = exact ? s.indexOf(exact) : -1;
    if (at < 0) return null;
    rest = s.slice(0, at) + s.slice(at + exact.length);
  }
  rest = rest.replace(/^(\s|\[문단\])+/, '').replace(/(\s|\[문단\])+$/, '');
  const contentOnly = rest.replace(/\[(?:문단|박스시작|박스끝|보기시작|보기끝)\]/g, '').trim();
  return contentOnly ? rest : null;
}

export interface CommonStemFix {
  stem: string;
  /** 공통 발문도 바꿔야 할 때(공통 발문에 개별 본문이 통째로 들어간 경우) 새 값. 아니면 null. */
  commonStem: string | null;
}

const squash = (s: string) => s.replace(/\s+|\[문단\]/g, '');

const normAnsSimple = (s: string) =>
  s.replace(/\\left|\\right/g, '')
    .replace(/\\times|\\cdot|·|\*/g, '×')
    .replace(/\\leq|\\le\b/g, '≤')
    .replace(/\\geq|\\ge\b/g, '≥')
    .replace(/\\bigcirc|○|◯/g, 'o')
    .replace(/[\s${}\\]/g, '')
    .toLowerCase();

/**
 * 원본 해설 전사 텍스트에서 이중 추출된 '[해설]'/'[풀이]' 머리말과 '16 답 ×'·'[정답] ③' 같은 정답 줄을 제거한다.
 * 정답은 solution_answer 에 따로 저장하고 카드 렌더링 때 '정답 ... [해설]' 머리말을 붙이므로, 해설 본문에는 순수 풀이만 남긴다.
 */
export function cleanSolutionTranscribedText(
  rawText: unknown,
  problemNumber?: unknown,
  solutionAnswer?: unknown,
): string {
  let s = String(rawText ?? '').replace(/\r\n/g, '\n').trim();
  if (!s) return '';
  const numDigits = String(problemNumber ?? '').replace(/[^0-9]/g, '').replace(/^0+/, '');
  const numEsc = numDigits ? `0*${numDigits}(?:\\s*번|\\.|\\))?` : '(?:0*\\d{1,3}(?:\\s*번|\\.|\\))?)';
  const ansNorm = normAnsSimple(String(solutionAnswer ?? ''));

  for (let pass = 0; pass < 6 && s.length > 0; pass++) {
    const prev = s;
    s = s.replace(/^(?:\s|\[문단\])+/, '');
    // 1) 앞머리 [해설], [풀이], <해설>, <풀이>, 해설:, 풀이: 제거
    s = s.replace(/^(?:\[\s*(?:해설|풀이|정답과\s*해설|정답\s*및\s*해설)\s*\]|<\s*(?:해설|풀이)\s*>|(?:해설|풀이)\s*[:：])\s*/i, '');
    s = s.replace(/^(?:해설|풀이)\s*(?:\n|\[문단\])+/, '');
    s = s.replace(/^(?:\s|\[문단\])+/, '');

    // 2) 첫 줄이 '(문항번호) 답/정답 ...' 또는 '[정답] ...' 인 경우 첫 줄 제거
    const firstLineBreak = s.search(/\n|\[문단\]/);
    const firstLine = (firstLineBreak >= 0 ? s.slice(0, firstLineBreak) : s).trim();
    const restAfterFirst = firstLineBreak >= 0 ? s.slice(firstLineBreak).replace(/^(?:\s|\[문단\])+/, '') : '';

    // '답 없음', '답은 ...', '답이 ...' 같은 서술 문장은 정답 줄이 아니다.
    const isProseDap = /^(?:답|정답)(?:[은는이가을를도만]|(?:\s*없음))/.test(firstLine);
    const bracketOrNumberedAnsRe = new RegExp(
      `^(?:${numEsc}\\s*(?:\\[\\s*(?:답|정답)\\s*\\]|(?:답|정답))(?![은는이가을를도만])(?:\\s*[:：]?\\s*\\S.*|$)|\\[\\s*(?:답|정답)\\s*\\]\\s*[:：]?\\s*\\S.*|(?:답|정답)\\s*[:：]\\s*\\S.*)`,
      'i',
    );
    const bareDapMatch = !isProseDap ? firstLine.match(/^(?:답|정답)\s+(\S.*)$/) : null;
    const isBareDapHeader = !!bareDapMatch && (
      restAfterFirst.length > 0 ||
      (ansNorm.length > 0 && normAnsSimple(bareDapMatch[1]) === ansNorm)
    );
    if (!isProseDap && (bracketOrNumberedAnsRe.test(firstLine) || isBareDapHeader)) {
      const inlineSol = firstLine.match(/(?:\[\s*(?:해설|풀이)\s*\]|(?:해설|풀이)\s*[:：])\s*(.+)$/);
      s = inlineSol ? `${inlineSol[1].trim()}${restAfterFirst ? '\n' + restAfterFirst : ''}` : restAfterFirst;
      continue;
    }

    // 3) 첫 줄이 '문항번호 + 정답값' 만으로 이루어진 경우 제거
    if (numDigits) {
      const numPrefixRe = new RegExp(`^0*${numDigits}(?:\\s*번|\\.|\\))?\\s+(.+)$`);
      const m = firstLine.match(numPrefixRe);
      if (m) {
        const tail = m[1].trim();
        if (ansNorm && normAnsSimple(tail) === ansNorm) {
          s = restAfterFirst;
          continue;
        }
      }
    }

    // 4) 첫 줄이 순수하게 정답값(solution_answer)과 완전히 같은 한 줄이고 뒤에 해설이 이어지는 경우
    if (ansNorm && firstLine && normAnsSimple(firstLine) === ansNorm && restAfterFirst) {
      s = restAfterFirst;
      continue;
    }

    if (s === prev) break;
  }

  // 본문 중간에 단독 줄로 들어간 [해설] / [풀이] 머리말도 정리한다.
  s = s
    .replace(/(?:^|\n|\[문단\])\s*\[\s*(?:해설|풀이)\s*\]\s*(?=\n|\[문단\]|$)/g, '\n')
    .replace(/^\s*\[\s*(?:해설|풀이)\s*\]\s*/g, '')
    .replace(/^(?:\s|\[문단\])+/, '')
    .replace(/(?:\s|\[문단\])+$/, '')
    .trim();

  return s;
}

/** 지시문 문장으로 볼 수 있는 표현(공통 발문을 첫 문단으로 줄일 때 지시문인지 확인한다). */
const INSTRUCTION_PATTERN =
  /(다음|아래|보기|위|오른쪽|왼쪽)|(구하|쓰|써넣|채우|고르|찾|연결|나타내|계산|비교|완성|판단|말하|답하|표시|그리|그려|풀어|인수분해|소인수분해|약분|통분|정리)(여라|시오|라|자|기|고)|\?/;

export function looksLikeInstruction(text: string): boolean {
  const t = text.trim();
  return t.length >= 4 && INSTRUCTION_PATTERN.test(t);
}

/** 공통 발문이 비어 있지 않은데 지시문이 아니라 숫자·수식 조각(예: '36', '36=2^2×3^2')만 들어 있는 손상 상태인가 */
export function isCorruptedCommonStem(commonStem: unknown): boolean {
  const c = String(commonStem ?? '').trim();
  if (!c) return false;
  const parts = c.split(/\[문단\]|\n/).map((p) => p.trim()).filter((p) => p.length > 0);
  return !parts.some((p) => looksLikeInstruction(p));
}

/** 문항에 그림·도형·그래프가 있는가(있으면 1회차에서 무조건 품질 문제로 취급해 원본 대조·크기·배치 수정안을 제시한다). */
export function itemHasFigures(it: Rec, b?: Rec): boolean {
  const assets = Array.isArray(it.pb_figure_assets) ? it.pb_figure_assets : [];
  if (assets.some((a) => a && typeof a === 'object' && Number((a as Rec).figure_index) > 0)) return true;
  if (figureMarkerCount(it.stem) > 0) return true;
  if (b && (b.figure_ok === false || b.issue_kind === 'figure')) return true;
  return false;
}

/** 공통 발문의 첫 지시문: 첫 [문단]/줄바꿈 앞, 없으면 첫 문장(. ? ! 로 끝남). 뒤에 이어지는 내용이 없거나 지시문이 아니면 null. */
export function leadingInstruction(common: string): string | null {
  const parts = common.split(/\[문단\]|\n/).map((p) => p.trim()).filter((p) => p.length > 0);
  if (parts.length >= 2) return looksLikeInstruction(parts[0]) ? parts[0] : null;
  const m = /^(.+?[.?!])\s*(\S[\s\S]*)$/.exec(common.trim());
  const first = m ? m[1].trim() : null;
  return first && looksLikeInstruction(first) ? first : null;
}

/** 서술형으로 봐야 하는 표현(발문에 있으면 무조건 서술형) */
export const ESSAY_PATTERN = /서술하(시오|여라)|과정을\s*(쓰|서술|설명)|풀이\s*과정|이유를\s*(쓰|설명|서술)|설명하(시오|여라)|증명하(시오|여라)/;

/** 빈칸형 문항 판별: 발문·공통발문·수식에 빈칸 채우기 지시나 네모(□, [[공백:n]], box{~~}, \square, \Box 등)가 있는 문항 */
export const FILL_IN_BLANK_PATTERN =
  /\[\[?\s*공백\s*:\s*\d+(?:\.\d+)?\s*\]\]?|\bbox\s*\{|\\(?:square|Box|boxed)\b|[□▢]|(?:빈칸|네모|\(\s*\)|\[\s*\])\s*(?:에|안에)|알맞은\s*(?:수|말|식|값|기호|것|숫자)를?\s*(?:써넣|쓰시오|써라|채우)/;

export function isFillInBlankProblem(commonStem: unknown, stem: unknown): boolean {
  const combined = `${String(commonStem ?? '')}\n${String(stem ?? '')}`;
  return FILL_IN_BLANK_PATTERN.test(combined);
}

/**
 * 빈칸형 문항에서 모델이 정상 조판된 네모(□)·빈칸 자체를 '불명확한 빈칸 추가'·'단독 빈칸'·'빈칸 노출'로 잘못 지적한 경우인지 판별한다.
 * 실제 대괄호 마크업 글자([[공백:1]] 등)가 그대로 노출됐다는 지적이 아니면 오판으로 보고 무시한다.
 */
export function isFalseBlankComplaint(isFillInBlank: boolean, title: unknown, detail: unknown): boolean {
  if (!isFillInBlank) return false;
  const text = `${String(title ?? '')} ${String(detail ?? '')}`.trim();
  if (!text) return false;
  if (/\[\[?\s*공백|박스시작|박스끝|표시작|표끝|PB_FIG/i.test(text)) return false;
  return /(?:용도가\s*불명확한\s*빈칸|단독\s*빈칸|빈칸이\s*(?:추가|하나\s*더|더\s*보|노출|있)|네모가\s*(?:추가|더\s*보|노출))/.test(text);
}

/**
 * V2 렌더러는 구분자 없는 LaTeX 도 수식으로 자동 인식해 `$...$` 와 같은 결과를 찍는다.
 * `$` 유무와 수식 기호 주변 공백만 다른 두 본문은 화면이 같으므로 같은 본문으로 본다.
 */
export function mathDelimiterInsensitive(text: string): string {
  return String(text ?? '')
    .replace(/(?<!\\)\$/g, '')
    .replace(/\s+/g, ' ')
    .replace(/\s*\\/g, '\\')
    .replace(/\s*([{}^_=+\-(),])\s*/g, '$1')
    .trim();
}

export function sameRenderedMath(a: string, b: string): boolean {
  return mathDelimiterInsensitive(a) === mathDelimiterInsensitive(b);
}

/**
 * 렌더 엔진 문법과 다르게 작성된 본문 마크업·LaTeX 를 표준 문법으로 정규화한다.
 * 1) '[ [[공백:3]] ]' 처럼 대괄호가 삼중으로 겹친 공백 마커 → '[[공백:3]]' (바깥 [] + 안쪽 [공백:3] = 단일 대괄호 빈칸)
 * 2) '\text{box{~~}}' 처럼 \text{} 안에 들어간 빈칸 마커 → 'box{~~}'
 * 3) 수식 블록(\begin{aligned|array|cases|gathered|split}) 안의 날한글 라벨 '(가)'~'(하)' 또는 화살표 뒤 날한글 → '\text{(가)}'
 */
export function sanitizeProblemMarkup(raw: unknown): string {
  let s = String(raw ?? '');
  if (!s) return s;
  s = s.replace(/\[\s*\[\s*\[공백\s*:\s*([0-9]+(?:\.[0-9]+)?)\s*\]\s*\]\s*\]/g, '[[공백:$1]]');
  s = s.replace(/\\text\s*\{\s*box\s*\{\s*(?:~~)?\s*\}\s*\}/gi, 'box{~~}');
  s = s.replace(/\\(?:boxed|box)\s*\{\s*(?:\\phantom\s*\{[^}]*\}|~~|\s*)\s*\}/gi, 'box{~~}');
  s = s.replace(
    /(\\begin\{(aligned|alignedat|gathered|split|array|cases)\})([\s\S]*?)(\\end\{\2\})/g,
    (_m, open: string, _env: string, body: string, close: string) => {
      const fixedBody = body
        .replace(/(?<!\\text\{)\(([가-힣]{1,4})\)/g, '\\text{($1)}')
        .replace(/(\\(?:left|right|leftrightarrow|Left|Right)arrow\s*)([가-힣]{1,6})(?![가-힣}])/g, '$1\\text{$2}');
      return `${open}${fixedBody}${close}`;
    },
  );
  return s;
}

/**
 * AI 가 'engine' 으로 잘못 분류하더라도 실제로는 본문·공통발문 데이터 수정으로 해결되는 증상인지 판별한다.
 * - 오타, 빠짐(참조 기호 (가)~(라) 누락, 지시문 누락 등), 중복, 렌더 엔진 문법 위반([ [[공백:N]] ], 수식 내 날한글 등)은 모두 data 오류다.
 */
export function isDataFixableSymptom(
  title: unknown,
  detail: unknown,
  symptom: unknown,
  stem?: unknown,
  commonStem?: unknown,
): boolean {
  if (stem !== undefined && sanitizeProblemMarkup(stem) !== String(stem ?? '')) return true;
  if (commonStem !== undefined && sanitizeProblemMarkup(commonStem) !== String(commonStem ?? '')) return true;
  const text = `${String(title ?? '')} ${String(detail ?? '')} ${String(symptom ?? '')}`.trim();
  if (!text) return false;
  return /(?:common_stem|공통\s*(?:지시문|발문)|저장된\s*개별\s*발문|첫\s*줄\s*수식.*표시되지|소문항\s*(?:정답|별)|정답\s*줄\s*(?:가로\s*넘침|오른쪽\s*잘림|넘침)|이중\s*대괄호|\[\[\s*\]\]|\[공백|참조\s*기호|한글\s*표지|\([가나다라마바사]\)|빈\s*괄호|자리표시자|\[image\]|계산식이?\s*두\s*번|중복\s*표시)/i
    .test(text);
}

/** 소문항 정답 사이 공백·줄바꿈(한 줄 가로 넘침 포함) 지적(검수 카드 렌더 포맷에서 [문단] 줄바꿈으로 해결됨)인지 판별한다. */
export function isSubAnswerSpacingComplaint(title: unknown, detail: unknown): boolean {
  const text = `${String(title ?? '')} ${String(detail ?? '')}`.trim();
  if (!text) return false;
  return /(?:소문항\s*(?:정답|별\s*정답).*(?:구분|이어짐|붙어)|앞\s*소문항의\s*답과\s*다음\s*번호가\s*붙어|정답\s*줄\s*(?:가로\s*넘침|오른쪽\s*잘림|넘침)|한\s*줄에\s*배치하여.*잘려)/.test(text);
}

export type QuestionKind = 'objective' | 'subjective' | 'essay';

/** 규칙 기준 문항 유형: 서술형 표현 → essay, 선지 2개 이상 → objective, 그 외 subjective */
export function expectedQuestionKind(fullStem: unknown, choices: unknown): QuestionKind {
  if (ESSAY_PATTERN.test(String(fullStem ?? ''))) return 'essay';
  return Array.isArray(choices) && choices.length >= 2 ? 'objective' : 'subjective';
}

/**
 * 공통 발문 중복의 두 형태를 모두 다룬다(Manager `computeCommonStemFix` 와 같은 규칙).
 * 1) 지시문이 개별 발문 앞머리에 다시 들어 있음 → 개별 발문에서 공통 부분만 뺀다(단, 공통 발문이 지시문이 아니라
 *    숫자·식 조각이면 떼어내지 않는다 — 예: common_stem='36' 인 손상 상태에서 stem='36\n480' 을 잘못 자르지 않게).
 * 2) 공통 발문에 개별 문항 본문까지 통째로 들어 있음(common_stem == stem 등) →
 *    (가) 첫 문단이 지시문이면 공통 발문은 첫 문단(지시문)만 남기고 개별 발문은 지시문을 뺀 나머지,
 *    (나) 첫 문단이 숫자·식이고 두 번째 문단이 지시문이면(예: "36=2^2×3^2\n다음 표의 빈칸에 알맞은 수를 써넣어라.\n...")
 *         공통 발문은 그 지시문 문단만 남기고, 개별 발문에서도 앞머리 중복 지시문을 뺀다.
 */
export function commonStemFix(commonStem: unknown, stem: unknown): CommonStemFix | null {
  const common = String(commonStem ?? '').trim();
  const s = String(stem ?? '');
  if (!common || !s.trim()) return null;
  if (looksLikeInstruction(common)) {
    const direct = stripCommonStem(common, s);
    if (direct !== null) return { stem: direct, commonStem: null };
  }
  const instr = leadingInstruction(common);
  if (instr) {
    const rest = stripCommonStem(instr, s);
    if (rest !== null) {
      const sqRest = squash(rest);
      if (sqRest && squash(common).endsWith(sqRest)) return { stem: rest, commonStem: instr };
    }
  }
  // 첫 문단이 숫자·식이고 뒤에 지시문 문단이 있는 오염된 공통 발문(예: "36=2^2×3^2\n다음 표의 빈칸에...")을 복구한다.
  const parts = common.split(/\[문단\]|\n/).map((p) => p.trim()).filter((p) => p.length > 0);
  if (parts.length >= 2 && !looksLikeInstruction(parts[0])) {
    const instrPart = parts.slice(1).find((p) => looksLikeInstruction(p));
    if (instrPart) {
      const strippedFromStem = stripCommonStem(instrPart, s) ?? stripCommonStem(`${parts[0]}\n${instrPart}`, s);
      const nextStem = strippedFromStem ?? s.trim();
      if (nextStem) return { stem: nextStem, commonStem: instrPart };
    }
  }
  // 공통 발문이 이미 숫자·식 조각('36=2^2×3^2', '36' 등)으로만 잘려 있고 개별 발문 첫 문단에 실제 공통 지시문이 남아 있는 경우 복구한다.
  if (isCorruptedCommonStem(common)) {
    const stemInstr = leadingInstruction(s);
    if (stemInstr) {
      const rest = stripCommonStem(stemInstr, s);
      if (rest) return { stem: rest, commonStem: stemInstr };
    }
  }
  return null;
}

const SOLUTION_TRANSCRIBE_SCHEMA: Rec = {
  type: 'object',
  additionalProperties: false,
  required: ['problems'],
  properties: {
    problems: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['crop_id', 'found', 'solution_transcribed', 'solution_answer', 'confidence', 'note'],
        properties: {
          crop_id: { type: 'string' },
          found: { type: 'boolean' },
          solution_transcribed: { type: 'string' },
          solution_answer: { type: ['string', 'null'] },
          confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
          note: { type: ['string', 'null'] },
        },
      },
    },
  },
};

const BLIND_SOLVE_SCHEMA: Rec = {
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
          'ai_solution',
          'ai_answer',
          'arithmetic_ops',
          'visual_tags',
          'judged_from_v2_image',
          'stem_ok',
          'choices_ok',
          'figure_ok',
          'figure_position_ok',
          'figure_size_ratio',
          'latex_v2_ok',
          'fidelity_ok',
          'quality_issue_title',
          'quality_issue_detail',
          'issue_kind',
          'proposed_stem',
          'proposed_common_stem',
          'proposed_choices',
          'fix_reason',
          'question_kind',
        ],
        properties: {
          crop_id: { type: 'string' },
          question_kind: { type: 'string', enum: ['objective', 'subjective', 'essay'] },
          ai_solution: { type: 'string' },
          ai_answer: { type: 'string' },
          arithmetic_ops: {
            type: 'array',
            items: {
              type: 'object',
              additionalProperties: false,
              required: ['code', 'count'],
              properties: {
                code: { type: 'string' },
                count: { type: 'integer' },
              },
            },
          },
          visual_tags: { type: 'array', items: { type: 'string' } },
          judged_from_v2_image: { type: 'boolean' },
          stem_ok: { type: 'boolean' },
          choices_ok: { type: 'boolean' },
          figure_ok: { type: 'boolean' },
          figure_position_ok: { type: 'boolean' },
          figure_size_ratio: { type: ['number', 'null'] },
          latex_v2_ok: { type: 'boolean' },
          fidelity_ok: { type: 'boolean' },
          quality_issue_title: { type: ['string', 'null'] },
          quality_issue_detail: { type: ['string', 'null'] },
          issue_kind: { type: 'string', enum: ['none', 'data', 'engine', 'figure'] },
          proposed_stem: { type: ['string', 'null'] },
          proposed_common_stem: { type: ['string', 'null'] },
          proposed_choices: {
            type: ['array', 'null'],
            items: {
              type: 'object',
              additionalProperties: false,
              required: ['label', 'text'],
              properties: { label: { type: 'string' }, text: { type: 'string' } },
            },
          },
          fix_reason: { type: ['string', 'null'] },
        },
      },
    },
  },
};

const COMPARE_ANALYZE_SCHEMA: Rec = {
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
          'answer_matched',
          'mismatch_reason',
          'proposed_answer',
          'concept_ids',
          'thinking_codes',
          'draft_proposals',
        ],
        properties: {
          crop_id: { type: 'string' },
          answer_matched: { type: 'boolean' },
          mismatch_reason: { type: ['string', 'null'] },
          proposed_answer: { type: ['string', 'null'] },
          concept_ids: { type: 'array', items: { type: 'string' } },
          thinking_codes: { type: 'array', items: { type: 'string' } },
          draft_proposals: {
            type: 'array',
            items: {
              type: 'object',
              additionalProperties: false,
              required: [
                'code',
                'target',
                'thinking_kind',
                'category',
                'title',
                'criteria',
                'trigger_cond',
                'action_steps',
                'trap_note',
                'example_expr',
                'unit_score',
              ],
              properties: {
                code: { type: 'string' },
                target: { type: 'string', enum: ['thinking', 'arithmetic'] },
                thinking_kind: { type: 'string', enum: ['frame', 'algorithm'] },
                category: { type: 'string' },
                title: { type: 'string' },
                criteria: { type: 'string' },
                trigger_cond: { type: 'string' },
                action_steps: { type: 'string' },
                trap_note: { type: 'string' },
                example_expr: { type: 'string' },
                unit_score: { type: 'number' },
              },
            },
          },
        },
      },
    },
  },
};

const RENDER_CHECK_SCHEMA: Rec = {
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
          'problem_ok',
          'answer_ok',
          'solution_ok',
          'fidelity_ok',
          'figure_position_ok',
          'figure_size_ratio',
          'issue_title',
          'issue_detail',
          'issue_kind',
          'engine_symptom',
        ],
        properties: {
          crop_id: { type: 'string' },
          problem_ok: { type: 'boolean' },
          answer_ok: { type: 'boolean' },
          solution_ok: { type: 'boolean' },
          fidelity_ok: { type: 'boolean' },
          figure_position_ok: { type: 'boolean' },
          figure_size_ratio: { type: ['number', 'null'] },
          issue_title: { type: ['string', 'null'] },
          issue_detail: { type: ['string', 'null'] },
          issue_kind: { type: 'string', enum: ['none', 'data', 'engine', 'figure'] },
          engine_symptom: { type: ['string', 'null'] },
        },
      },
    },
  },
};

const SOLUTION_TRANSCRIBE_INSTRUCTIONS = `당신은 Yggdrasill 수학 문항 검수 엔진의 [1단계: 원본 해설 전사] 담당입니다.
각 문항마다 교재 해설지(또는 본문)에서 그 문항의 풀이가 인쇄된 영역을 잘라낸 이미지가 주어집니다. 이미지에 인쇄된 정답과 해설을 분리해 옮겨 적으세요.

[수행 원칙]
1. 정답(solution_answer)과 해설(solution_transcribed)을 반드시 분리합니다(이중 추출 금지):
   - solution_answer: 최종 답만 적습니다(객관식은 ①~⑤, 주관식·표·다중 빈칸은 값/식 그대로, 예: "$\\times$", "(1) 1, 3 (2) 5, 15"). 답이 명시되지 않았으면 풀이 마지막 결론 값을 적고 note에 "답 표기 없음, 결론 값 사용"이라고 적습니다.
   - solution_transcribed: 순수 풀이 과정(해설 본문)만 원본 그대로 한글+LaTeX($...$)로 적습니다. 문항 번호("16", "01." 등), 정답 줄("16 답 ×", "답 ③", "[정답] ..."), "[해설]"·"[풀이]" 같은 머리말은 절대 solution_transcribed 에 넣지 마세요(화면에서 '정답'과 '[해설]' 머리말을 따로 붙이므로 넣으면 두 번 나옵니다). 해설지에 풀이 과정 없이 정답만 인쇄된 문항이면 solution_transcribed 는 빈 문자열 "" 로 두고 solution_answer 에만 정답을 적으세요(found=true 유지).
   - 분수는 \\frac{a}{b}, 근호는 \\sqrt{}, 거듭제곱은 ^{}, 원문자 선지는 ①~⑤ 그대로 적고 줄바꿈은 \\n으로 구분합니다.
   - 해설 안에 글자로 옮길 수 없는 그림(좌표평면 그래프, 도형, 수직선, 벤다이어그램 등)이 인쇄돼 있으면 그 자리에 [그림] 만 적습니다. 그림 내용을 글로 설명하지 마세요(그림은 원본에서 잘라 그 자리에 넣습니다). 글자로 된 표는 그림이 아니므로 그대로 옮겨 적습니다.
2. 잘린 영역에 해당 문항 번호의 정답·풀이가 전혀 보이지 않거나(다른 문항만 보임 등) 읽을 수 없으면 found=false 로 두고 solution_transcribed는 "", solution_answer는 null, note에 원인을 적습니다.
3. 영역 안에 다른 문항의 풀이 일부가 함께 보이면 그 부분은 제외하고 요청된 문항 번호의 것만 전사합니다.
   - 이미지가 회색 가로선으로 위아래 두 조각으로 나뉘어 있으면, 아래 조각은 해설지 다음 단(또는 다음 쪽) 맨 위입니다. 위 조각 풀이가 단 끝에서 끊겨 아래 조각으로 이어지면 이어서 끝까지 옮기세요. 아래 조각의 단원 제목 띠·쪽 머리글·다른 문항 번호로 시작하는 풀이는 옮기지 않습니다.
4. confidence: 글자·수식이 선명하고 완결되면 high, 일부 흐리거나 잘려 추정이 섞이면 medium, 대부분 추정이면 low.`;

const BLIND_SOLVE_INSTRUCTIONS = `당신은 Yggdrasill 수학 문항 검수 엔진의 [2단계: 블라인드 독립 풀이 · 연산 측정 · 품질 검수(학생 시점 V2 렌더 기준)] 담당입니다.
각 문항마다 (가) 문항 데이터 텍스트(공통 발문 common_stem, 개별 발문 stem, 선지 choices, 수식 equations, 도형 figure_refs)와
(나) 학생이 실제로 보게 되는 화면인 "V2 렌더링 이미지"(우리 조판 엔진이 PDF로 찍어낸 카드), (다) 교재 본문 PDF에서 이 문항 영역을 잘라낸 "원본 이미지"(세트 문항은 공통 지시문이 인쇄된 "세트 머리 원본 이미지"가 따로 올 수 있음)가 주어질 수 있습니다.
기존 정답은 모르는 상태에서 직접 풀고, 품질은 반드시 V2 렌더링 이미지(학생 시점)를 기준으로 판정하세요.

[수행 원칙]
1. 세트형 문항 공통 발문 결합:
   - common_stem이 비어 있지 않으면 반드시 [공통 지시문(common_stem)] + [개별 문항(stem)]을 하나로 합쳐 읽고 푸세요.
   - common_stem이 "다음 수의 약수를 모두 구하여라."이고 stem이 "7"이면 "7의 약수를 모두 구하는 문제"입니다. 발문 누락이나 판단불가로 판정하지 마세요.
   - 발문 안의 예시 설명 상자([박스시작] ... [박스끝])가 있어도 본래 질문에 대한 답을 구하세요.
2. 블라인드 독립 풀이(ai_solution, ai_answer):
   - 처음부터 끝까지 스스로 풀어 LaTeX 수식($...$)을 포함한 단계별 풀이를 ai_solution에 작성하고, 최종 답을 ai_answer에 적으세요(객관식이고 선지가 있으면 선지 번호 ①~⑤, 주관식이면 기약분수/수식, 표 빈칸 채우기면 빈칸 값들).
   - 중요: 만약 텍스트 데이터(common_stem, stem)에 지시문이나 문장이 빠져 있거나 다른 문항 숫자('36' 등)가 잘못 들어 있더라도, 첨부된 "원본 이미지"와 "세트 머리 원본 이미지"에서 실제 문제와 공통 지시문을 직접 읽고 문제를 끝까지 풀어 정확한 ai_answer 를 구하세요! 원본 이미지에서 문제를 읽을 수 있는데 텍스트가 불완전하다는 이유로 ai_answer 를 "판단불가"로 적지 마세요(텍스트/V2 화면의 누락은 아래 4번 품질 검수에서 stem_ok=false, fidelity_ok=false 로 지적하고 proposed_stem / proposed_common_stem 으로 고치면 됩니다).
   - 텍스트와 원본 이미지를 모두 합쳐도 문제가 잘려 전혀 풀 수 없을 때만 ai_answer는 "판단불가"로 적으세요.
3. 연산 복잡도 카운트(arithmetic_ops):
   - 당신이 작성한 ai_solution의 각 계산 단계에서 실제로 수행한 세부 연산 코드(제공된 arithmetic_primitives 목록의 code)와 등장 횟수(count >= 1)를 정확히 세어 기록하세요.
4. 품질 검수 — 학생 시점(V2 렌더링 이미지) 기준:
   - judged_from_v2_image: V2 렌더 이미지를 실제로 보고 판정했으면 true, 이미지가 없어서 텍스트만으로 판정했으면 false.
   - stem_ok: 렌더 화면에서 발문이 온전하게 읽히는지(문장 절단, 글자 겹침, 변환되지 않은 마크업 문자열([[공백:1]], [박스시작] 등)이 글자 그대로 노출됨, 문단이 사라짐 등이 없는지). 독립형 세트에서 stem에 숫자/식만 있는 것은 정상입니다.
     - 중요(빈칸형 문항 · is_fill_in_blank = true): "□ 안에 알맞은 수를 써넣어라", "다음 표의 빈칸에 알맞은 수를 써넣어라" 같은 빈칸형 문항은 지시문 안, 결론 수식("⇒ 90 = 2 × □ × 5" 등), 수형도·표 안에 빈 네모 상자(□)가 하나 또는 여러 개 그려져 있는 것이 정상적인 문항 형식입니다. 지시문이나 수식에 네모(□)·빈칸이 있다고 해서 "용도가 불명확한 빈칸 추가"나 "단독 빈칸 노출"로 절대 판정하지 마세요(stem_ok = true, fidelity_ok = true).
   - choices_ok: 객관식 선지 ①~⑤ 또는 <보기> ㄱ,ㄴ,ㄷ 가 화면에 모두 보이고 순서·내용이 맞는지.
   - figure_ok: 도형/그래프/표가 필요한 문항에서 화면에 도형이 있고 잘림·겹침·크기 이상이 없는지. 도형이 필요 없는 문항은 true.
   - figure_position_ok: 원본 이미지와 V2 렌더 이미지 모두에 그림이 있을 때, V2 그림이 원본과 같은 자리(본문 오른쪽·왼쪽에 나란히, 본문 아래, 가로 정렬·왼쪽/가운데 정렬)에 있는가. 그림이 없거나 원본 이미지가 없으면 true.
   - figure_size_ratio: 원본과 V2 렌더 모두에 그림이 있을 때, "본문 글자 크기에 대한 그림 크기"가 V2에서 원본의 몇 배인지(같으면 1.0, V2 그림이 더 크면 1보다 큼, 예 1.4 · 0.7). 각 이미지 안에서 그림 폭을 본문 글자 한 자 크기와 비교해 추정하세요. 그림이 없거나 원본 이미지가 없으면 null.
     그림 크기·위치 차이는 issue_kind "figure" 로 분류하고 본문 수정 제안은 내지 마세요(크기는 이 비율로 자동 보정합니다).
     표·수식·선지 상자는 그림이 아닙니다. 표만 있는 문항은 figure_position_ok=true, figure_size_ratio=null 이고, 표 크기·간격 차이를 issue_kind "figure" 로 분류하지 마세요.
   - latex_v2_ok: 화면에서 수식이 수학 기호로 제대로 조판됐는지(\\frac, \\sqrt, ^, _ 같은 LaTeX 원문이 글자로 노출되거나, $ 기호가 보이거나, ?? 또는 깨진 글자가 보이면 false).
     저장 텍스트(stem_raw 등)에 $ 구분자 없이 "l \\parallel m", "\\angle x" 처럼 LaTeX 명령만 적혀 있는 것은 정상 규약입니다(V2 엔진이 자동으로 수식으로 찍음). 텍스트에 $ 가 없다는 이유만으로 이상·수정 제안을 내지 말고, 화면에서 실제로 깨져 보일 때만 판단하세요.
   - fidelity_ok: 원본 이미지가 주어졌을 때, V2 렌더(또는 텍스트)의 내용이 원본과 같은지(숫자·부호·조건·선지·그림이 바뀌거나 빠지지 않았는지). 원본 이미지가 없으면 true.
     세트 문항은 원본에서 공통 지시문이 세트 머리에 한 번만 인쇄되는 것이 정상입니다. V2 화면에 공통 지시문이 한 번 보이면 일치, 두 번 보이면 불일치입니다.
     원본에서 문항·소문항 아래 '해' 배지로 시작하는 빈칸 풀이 안내는 해설이라 본문에 넣지 않습니다. V2 화면에 그 안내가 없는 것은 정상이며 누락으로 지적하지 말고, proposed_stem 에도 넣지 마세요.
   - 이상이 하나라도 있으면 quality_issue_title과 quality_issue_detail에 학생 입장에서 무엇이 어떻게 보이는지(예: "②번 선지가 화면에 없음", "분수가 \\frac{1}{2} 글자로 노출됨")를 한글로 명확히 적고, 이상이 없으면 둘 다 null로 두세요.
4-1. 이상의 원인 분류(issue_kind) — 운영자가 어디를 고칠지 정하는 기준입니다:
   - "data": 본문·공통발문·선지·정답 텍스트를 수정하면 해결되는 모든 문제입니다!
     * 글자·숫자·수식·참조 기호((가)~(라) 등)·지시문·선지가 빠지거나 원본과 다름, 오타, 중복 표시.
     * 렌더 엔진 문법과 다르게 작성된 마크업·LaTeX:
       - 우리 엔진의 공백 마커는 단일 대괄호 [공백:n] 입니다(소괄호 빈칸은 ([공백:n]), 단일 대괄호 빈칸 [   ] 은 [[공백:n]], 네모 상자 빈칸은 box{~~} 또는 □). 만약 [ [[공백:n]] ] 처럼 대괄호를 겹쳐 써서 화면에 [[ ]] 로 보이거나, \\text{box{~~}} 처럼 잘못 감싸 마크업이 노출되면 무조건 "data" 입니다.
       - 수식 환경($...$, \\begin{aligned}...\\end{aligned} 등) 안에 한글((가), (나) 등)을 \\text{(가)} 로 감싸지 않고 날한글로 적어 화면에 빈 괄호 () 만 보이는 경우도 엔진 결함이 아니라 LaTeX 문법 작성 오류이므로 무조건 "data" 입니다.
   - "engine": 저장된 본문·공통발문·선지 텍스트와 LaTeX·마크업 문법이 100% 올바르고 원본과도 완전히 일치하는데, 본문을 어떻게 수정해도 해결할 수 없고 조판 엔진(템플릿) 자체를 고쳐야만 해결되는 순수 렌더링 결함(예: 정상 수식인데 분수·첨자가 겹침, 카드 폭 밖으로 잘림)일 때만 "engine"으로 분류합니다. 본문 수정으로 고칠 수 있으면 절대 "engine"으로 분류하지 마세요.
   - "figure": 도형·그래프 자산이 없거나 잘림(텍스트·LaTeX 문제가 아님).
   - 이상이 없으면 "none".
4-2. 데이터 수정 제안(proposed_stem, proposed_common_stem, proposed_choices, fix_reason) — issue_kind 가 "data"일 때만:
   - 화면에 같은 지시문이 두 번 보이면(공통 지시문이 stem_raw 에도 들어 있는 경우) issue_kind 는 "data" 이고, proposed_stem 은 stem_raw 에서 공통 지시문 부분을 뺀 개별 문항 본문만 적으세요.
   - 세트 문항의 공통 발문(common_stem)이 비어 있거나, 지시문 문장이 빠졌거나, 세트 첫 문항의 숫자·식(예: "36", "36=2^2×3^2")이 잘못 들어 있으면 세트 머리 원본 이미지(또는 문항 원본)에서 읽은 원래 공통 지시문 전체를 proposed_common_stem 에 적으세요. 고칠 것이 없거나 세트 문항이 아니면 null.
   - proposed_stem: stem_raw(개별 발문 원문, 공통 지시문 제외)를 최소한으로 고친 전체 본문. 마크업([문단], [박스시작]/[박스끝], [표시작]/[표끝], [공백:n], box{~~}, 수식은 $ 생략 가능)은 엔진 표준 문법을 따르고, $ 를 붙이거나 떼는 것만으로는 제안하지 말며, 수식 안의 한글 라벨은 \\text{(가)} 로 감싸며, 대괄호 빈칸은 [[공백:n]]([ [[공백:n]] ] 금지)으로 적으세요. 원본 이미지가 있으면 그것을 기준으로 맞추세요(빠진 글자는 원본에서 읽어 채우고, 원본에 없는 엉뚱한 숫자·문단은 뺍니다). 고칠 것이 없으면 null.
   - proposed_choices: 선지를 고쳐야 할 때만 전체 선지 배열 [{label:"①", text:"..."}, ...]을 적고, 아니면 null. label 은 원문 그대로(①~⑤ 또는 ㄱ,ㄴ,ㄷ).
   - fix_reason: 무엇을 왜 고쳤는지 한 줄. 제안이 없으면 null.
   - "engine"·"figure"·"none" 이면 proposed_stem, proposed_common_stem, proposed_choices, fix_reason 모두 null.
4-3. 문항 유형(question_kind): 원본·V2 화면 기준으로 학생이 답하는 방식.
   - "서술하시오", "과정을 쓰시오", "풀이 과정", "이유를 쓰시오", "설명하시오", "증명하시오" 같은 표현이 있으면 무조건 "essay".
   - 그 외 선지(①~⑤)를 골라 답하면 "objective", 답만 쓰면 "subjective".
5. 시각 요소 태그(visual_tags):
   - 문항에 도형·그래프·표 등 시각 요소가 있거나 언급되면 아래 표준 태그 중 해당하는 것을 모두 넣으세요(없으면 빈 배열 []):
     ["수직선", "좌표평면", "일차함수(직선)", "이차함수(포물선)", "삼차·사차함수", "유리·무리함수", "지수·로그함수", "삼각함수", "각·평행선", "삼각형", "직각삼각형", "이등변·정삼각형", "사각형", "다각형", "원·부채꼴·접선", "합동·닮음", "입체도형·회전체", "전개도·겨냥도", "표(Table)", "조건상자(보기)", "통계그래프(히스토그램·상자그림)", "수형도·경로망"]`;

const COMPARE_ANALYZE_INSTRUCTIONS = `당신은 Yggdrasill 수학 문항 검수 엔진의 [3단계: 정답 대조 · 개념/사고 3축 분석] 담당입니다.
각 문항의 [기존 추출 정답(existing_answer)], [1단계 원본 해설 전사(solution_transcribed)와 해설 정답(solution_answer)], [2단계 AI 독립 풀이(ai_solution, ai_answer)]를 대조하고, 사용된 개념과 사고를 태깅하세요.

[수행 원칙]
1. 정답 대조(answer_matched, mismatch_reason, proposed_answer):
   - 표기만 다른 동일 정답(예: "3" vs "③"에서 3번 선지 값이 같음, "1/2" vs "\\frac{1}{2}" vs "0.5", "x=4" vs "4", 순서만 다른 집합)은 일치입니다.
   - 해설 정답(solution_answer)이 있으면 3자 대조입니다: 기존 정답·해설 정답·AI 정답이 모두 실질적으로 같을 때만 answer_matched = true.
   - 해설 정답이 없으면(null) 2자 대조입니다: 기존 정답과 AI 정답이 같을 때 true.
   - 기존 정답이 비어 있거나 어느 하나라도 다르면 false 로 두고, mismatch_reason에 어느 쪽이 왜 다른지(기존 정답 오타 / 해설 전사 오류 / 문항 전사 오류로 인한 오답 / AI 풀이 재검토 결과 등)를 적고 가장 신뢰할 수 있는 정답을 proposed_answer에 적으세요. 해설 정답과 AI 정답이 같고 기존 정답만 다르면 그 값을 제안합니다.
   - 원본 해설 전사가 있으면 AI 풀이와 풀이 방향이 다른지도 살펴 mismatch_reason에 짧게 덧붙이세요(정답이 같으면 answer_matched는 true 유지).
2. 개념 태그(concept_ids):
   - 제공된 candidate_concepts 목록에서 이 문항을 푸는 데 직접 쓰인 개념 ID(UUID)만 1~4개 고르세요. 목록에 없는 UUID를 지어내지 마세요.
3. 사고 태그(thinking_codes) 및 새 초안 제안(draft_proposals):
   - 제공된 thinking_primitives(범용 사고틀 frame + 실전 알고리즘 algorithm)에서 이 문항 풀이에 쓰인 사고 code를 1~5개 고르세요.
   - 기존 사전에 꼭 필요한 실전 알고리즘이나 세부 연산이 빠져 있다면 draft_proposals에 최대 1~2개만 제안하세요(점수는 연산 0.10~1.50, 범용 사고틀 3.5~7.5, 실전 알고리즘 5.0~9.5). 충분하면 빈 배열 []로 두세요.`;

const RENDER_CHECK_INSTRUCTIONS = `당신은 Yggdrasill 수학 문항 검수 엔진의 [V2 렌더링 학생 시점 검수] 담당입니다.
각 문항마다 우리 조판 엔진(V2, XeLaTeX)이 실제로 찍어낸 카드 이미지가 주어집니다: (1) 문항 카드, (2) 정답+해설 카드(원본 해설 또는 AI 풀이).
(3) 교재 원본 이미지(본문 PDF에서 이 문항 영역을 잘라낸 것)와, 세트 문항이면 공통 지시문이 인쇄된 세트 머리 원본 이미지가 함께 올 수 있습니다.
학생이 이 화면을 보고 공부한다고 생각하고, 보이는 그대로 판단하세요. 수학적으로 맞는지는 여기서 판단하지 않습니다.

[판정 기준 — 하나라도 해당하면 해당 항목 false]
- 수식이 기호로 조판되지 않고 LaTeX 원문(\\frac, \\sqrt, ^, _, \\, $)이나 ??, 깨진 글자, 빈 네모(□ 외의 깨짐)로 보인다.
- 문장·수식·선지가 카드 가장자리에서 잘렸거나 겹쳐서 읽을 수 없다.
- 객관식 선지(①~⑤)나 <보기>(ㄱ,ㄴ,ㄷ)가 일부 빠져 있다.
- 도형·그래프·표가 있어야 할 자리에 없거나, 잘리거나, 너무 작아 읽을 수 없다.
- 줄바꿈이 엉켜 풀이 단계의 순서를 따라갈 수 없다.
- 정답 카드에 정답이 보이지 않는다(비어 있음), 또는 해설이 중간에서 끊긴다.
- 원문 마크업([문단], [박스시작], [표시작], [[공백:1]] 같은 대괄호 문자열)이 변환되지 않고 글자 그대로 노출된다.
  - 주의(빈칸형 문항 · is_fill_in_blank = true): "□ 안에 알맞은 수를 써넣어라", 표·수형도·결론 수식("⇒ 90 = 2 × □ × 5" 등)의 네모 상자(□)는 학생이 답을 채우는 정상적인 빈칸입니다. 네모(□)가 발문이나 식에 들어 있다는 이유로 problem_ok=false 나 fidelity_ok=false 로 판정하지 마세요.
  - has_solution_original_image = true 이면 원본 해설 이미지가 함께 옵니다(회색 가로선 아래 조각은 해설지 다음 단·다음 쪽에서 이어진 부분). 정답+해설 카드의 해설이 원본 해설보다 짧거나, 풀이 줄·단계 표시(㉠ 등)·소문항 풀이(3), 4) 등)·마지막 결론 문장이 빠졌으면 solution_ok=false, issue_kind "data" 입니다. 원본 해설 이미지 안의 단원 제목 띠·쪽 머리글·다른 문항 풀이와, 글꼴·줄바꿈·수식 표기 차이는 무시하세요.
  - 해설에서도 "$y=\\square x(\\square\\ne 0)$ 꼴"처럼 계수·값 자리를 일부러 비운 네모(□)는 원본에 있는 표현입니다. V2 카드는 네모를 모두 같은 크기의 정사각형으로 그리므로 크기·모양 차이도 무시하세요. 해설 원본을 볼 수 없으면 네모가 있다는 이유만으로 solution_ok=false 로 판정하지 말고, 같은 해설의 다른 줄에서 그 자리 글자가 분명히 드러나는데(예: "y=□x"가 아니라 "y=ax"여야 하는 문장) 네모만 보일 때만 이상입니다.

[출력]
- problem_ok: 문항 카드가 학생이 읽기에 온전한가.
- answer_ok: 정답 표기가 보이고 읽히는가(정답 카드가 없으면 true).
- solution_ok: 해설/풀이 카드가 끝까지 읽히는가(해설 카드가 없으면 true).
- fidelity_ok: 원본 이미지가 있을 때 문항 카드의 내용이 원본과 같은가(글자·숫자·부호·수식·조건·선지·그림이 빠지거나 바뀌거나 두 번 나오지 않음). 원본 이미지가 없으면 true.
  - 글꼴, 줄바꿈 위치, 단 배치, 원문자 모양 같은 조판 차이는 무시합니다.
  - 세트 문항: 원본은 공통 지시문을 세트 머리에 한 번 인쇄합니다. 카드에 공통 지시문이 한 번 보이면 일치, 두 번 보이면 불일치입니다.
  - 원본에서 문항·소문항 아래 '해' 배지로 시작하는 빈칸 풀이 안내는 해설이라 문항 카드에 넣지 않습니다. 문항 카드에 그 안내가 없는 것은 정상이며 누락으로 판정하지 마세요.
    반대로 그 안내 안의 그림(빈 네모가 달린 수직선 등)이 문항 카드에 들어 있으면 해설이 섞인 것이므로 fidelity_ok=false, issue_kind "figure" 입니다.
- figure_position_ok: 원본에 그림이 있을 때 카드의 그림이 원본과 같은 자리(본문 오른쪽·왼쪽에 나란히, 본문 아래, 가로 정렬)에 있는가. 원본에 그림이 없으면 true.
- figure_size_ratio: 원본과 카드 모두에 그림이 있을 때, "본문 글자 크기에 대한 그림 크기"가 카드에서 원본의 몇 배인지(같으면 1.0, 카드 그림이 더 크면 1보다 큼, 예 1.4 · 0.7). 각 이미지 안에서 그림 폭을 본문 글자 크기와 비교해 추정하세요. 그림이 없으면 null.
- 표·수식·선지 상자는 그림이 아닙니다. 그림 위치·크기 판정(figure_position_ok · figure_size_ratio)에 넣지 마세요. 입력에 has_figure=false 인 문항은 그림이 없는 문항이므로 figure_position_ok=true, figure_size_ratio=null 로 답하세요.
- 이상이 있으면 issue_title(한 줄)과 issue_detail(어느 카드의 어디가 어떻게 보이는지, 원본과 무엇이 다른지)을 한글로 적고, 없으면 둘 다 null.
- issue_kind: 이상의 원인 분류. 운영자가 어디를 고칠지 정하는 기준입니다.
  - "data": 본문·공통발문·선지·정답 데이터를 수정하면 해결되는 모든 문제 — 글자·수식·참조 기호((가)~(라) 등)·지시문·선지가 빠지거나 두 번 나옴, 오타, 원본과 내용이 다름, 정답이 비어 있거나 [image] 자리표시자임, 해설이 중간에서 끝남, 또는 렌더 엔진 문법과 다르게 작성됨(예: [ [[공백:n]] ] 처럼 대괄호를 겹쳐 써서 [[ ]] 로 노출됨, 수식 안에 \\text{(가)} 없이 한글을 써서 빈 괄호 () 로 보임, LaTeX/마크업 문법 오타).
  - "engine": 본문·공통발문·선지 데이터와 LaTeX·마크업 문법이 100% 올바르고 원본과도 완전히 일치하는데, 본문을 수정해서는 해결할 수 없고 렌더 엔진(템플릿) 자체를 수정해야만 하는 순수 조판 결함(예: 정상 수식인데 분수·첨자 겹침, 카드 가장자리 잘림, 간격 깨짐). 본문 텍스트나 마크업 문법을 고쳐 해결할 수 있으면 절대 "engine"으로 분류하지 마세요.
  - "figure": 도형·그래프가 없거나 잘림, 또는 원본과 크기·위치가 크게 다름.
  - "none": 이상 없음.
- engine_symptom: issue_kind 가 "engine"일 때 증상을 짧은 명사구로(예: "분수 세로 겹침", "루트 기호 누락", "표 테두리 미출력"). 같은 증상끼리 묶어 엔진 수정 목록을 만드는 데 씁니다. 아니면 null.`;

async function loadDictionaries(auth: AuthContext, bookId: string, gradeLabel: string) {
  const [arithRes, thinkRes, sourceConceptsRes] = await Promise.all([
    auth.admin
      .from('arithmetic_primitives')
      .select('code,category,title,unit_score')
      .eq('is_active', true)
      .order('sort_order')
      .limit(200),
    auth.admin
      .from('thinking_primitives')
      .select('id,code,kind,category,title,unit_score')
      .eq('is_active', true)
      .order('sort_order')
      .limit(200),
    auth.admin
      .from('concept_sources')
      .select('concept_id,concepts(id,name)')
      .eq('book_id', bookId)
      .eq('grade_label', gradeLabel)
      .limit(250),
  ]);

  const arithList = (arithRes.data ?? []) as Rec[];
  const thinkList = (thinkRes.data ?? []) as Rec[];
  const conceptMap = new Map<string, { id: string; name: string }>();
  for (const row of (sourceConceptsRes.data ?? []) as Rec[]) {
    const c = row.concepts as Rec | null;
    if (c && typeof c.id === 'string' && typeof c.name === 'string') {
      conceptMap.set(c.id, { id: c.id, name: c.name });
    }
  }
  if (conceptMap.size < 30) {
    const { data: fallbackConcepts } = await auth.admin.from('concepts').select('id,name').limit(80);
    for (const c of (fallbackConcepts ?? []) as Rec[]) {
      if (typeof c.id === 'string' && typeof c.name === 'string' && !conceptMap.has(c.id)) {
        conceptMap.set(c.id, { id: c.id, name: c.name });
      }
    }
  }
  return { arithList, thinkList, conceptMap };
}

/** 같은 crop_id·check_key 의 열린 항목이 있으면 갱신, 없으면 새로 만든다(부분 유니크 인덱스라 upsert 추론이 안 된다). */
export async function upsertOpenFinding(auth: AuthContext, row: Rec): Promise<void> {
  const cropId = String(row.crop_id);
  const checkKey = String(row.check_key ?? '');
  if (checkKey) {
    const { data } = await auth.admin
      .from('textbook_review_findings')
      .select('id')
      .eq('crop_id', cropId)
      .eq('check_key', checkKey)
      .in('status', ['open', 'held'])
      .limit(1);
    const existing = (data ?? [])[0] as Rec | undefined;
    if (existing?.id) {
      await auth.admin.from('textbook_review_findings').update({ ...row, status: row.status ?? 'open' }).eq('id', existing.id);
      return;
    }
  }
  await auth.admin.from('textbook_review_findings').insert(row);
}

async function resolveOpenFinding(auth: AuthContext, cropId: string, checkKey: string): Promise<void> {
  await auth.admin
    .from('textbook_review_findings')
    .update({ status: 'resolved', resolution: 'auto_cleared', resolved_at: new Date().toISOString() })
    .eq('crop_id', cropId)
    .eq('check_key', checkKey)
    .in('status', ['open', 'held']);
}

export function parseProblems(text: string): Map<string, Rec> {
  const out = new Map<string, Rec>();
  let parsed: { problems?: Rec[] } = {};
  try {
    parsed = JSON.parse(text || '{"problems":[]}');
  } catch {
    parsed = {};
  }
  for (const p of parsed.problems ?? []) {
    if (p && typeof p.crop_id === 'string') out.set(p.crop_id, p);
  }
  return out;
}

export async function handleTextbookProblemReview(
  req: Request,
  auth: AuthContext,
  body: Rec,
): Promise<Response> {
  const academyId = uuidOrNull(body.academy_id);
  const bookId = uuidOrNull(body.book_id);
  const gradeLabel = typeof body.grade_label === 'string' ? body.grade_label.trim() : '';
  const bigOrder = Number(body.big_order);
  const midOrder = Number(body.mid_order);
  const chunkSize = Math.max(1, Math.min(10, Number(body.chunk_size) || 6));
  const forceRerun = body.force_rerun === true;
  // 수학만 다시 푼다(수학 오류 문항). 품질 판정·승인·수정안·V2 렌더 판정은 그대로 둔다.
  const mathOnly = body.math_only === true;
  const requestedCropIds = Array.isArray(body.crop_ids)
    ? (body.crop_ids as unknown[]).map((x) => uuidOrNull(x)).filter((x): x is string => !!x)
    : [];
  const images = parseReviewImages(body.images);

  if (!academyId || !bookId || !gradeLabel || !Number.isInteger(bigOrder) || !Number.isInteger(midOrder)) {
    return errorResponse(400, 'invalid_scope', '학원, 교재, 학년, 중단원 정보가 필요합니다.');
  }

  const wallClockMs = thinkWallClockMs();
  const provider = createAiProvider({ timeoutMs: wallClockMs + 5000 });
  if (!provider) return errorResponse(503, 'ai_not_configured', 'OPENAI_API_KEY 비밀값이 설정되지 않았습니다.');
  const budget = await getBudgetStatus(auth.admin).catch(() => null);
  if (budget?.exceeded && budget.mode === 'block') {
    return errorResponse(429, 'budget_exceeded', '이번 달 AI 한도를 넘었습니다.');
  }

  // 0단계: 시스템 적재 검사 갱신
  await auth.userClient.rpc('textbook_review_refresh_load_checks', {
    p_academy_id: academyId,
    p_book_id: bookId,
    p_grade_label: gradeLabel,
    p_big_order: bigOrder,
    p_mid_order: midOrder,
  });

  const overviewRes = await auth.userClient.rpc('textbook_review_unit_overview', {
    p_academy_id: academyId,
    p_book_id: bookId,
    p_grade_label: gradeLabel,
    p_big_order: bigOrder,
    p_mid_order: midOrder,
  });
  if (overviewRes.error) {
    return errorResponse(502, 'overview_failed', overviewRes.error.message);
  }
  const allItems = (((overviewRes.data as Rec | null)?.items ?? []) as unknown[])
    .map((x) => withoutDependentSetCommonStem((x ?? {}) as Rec));
  const todoItems = allItems.filter((it) => mathOnly ? isMathResolveTarget(it) : isReviewTodo(it, forceRerun));

  if (todoItems.length === 0) {
    return jsonResponse({ ok: true, processed: 0, remaining: 0, total: allItems.length, done: true });
  }

  // 매니저앱이 이미지와 함께 지정한 문항이 있으면 그 묶음을 우선한다(이미지는 그 문항들에 대해 준비돼 있다).
  const requested = new Set(requestedCropIds);
  const batchItems = requested.size > 0
    ? todoItems.filter((it) => requested.has(String(it.crop_id))).slice(0, chunkSize)
    : todoItems.slice(0, chunkSize);
  if (batchItems.length === 0) {
    return jsonResponse({ ok: true, processed: 0, remaining: todoItems.length, total: allItems.length, done: false });
  }

  const { arithList, thinkList, conceptMap } = await loadDictionaries(auth, bookId, gradeLabel);
  const arithCodes = new Set(arithList.map((a) => String(a.code)));
  const thinkByCode = new Map<string, string>();
  for (const t of thinkList) thinkByCode.set(String(t.code), String(t.id));
  const candidateConcepts = [...conceptMap.values()].slice(0, 120);

  const startedAt = Date.now();
  const model = modelFor('primary');
  const safetyId = await safetyIdentifier(auth.userId);
  const signal = AbortSignal.any([req.signal, AbortSignal.timeout(wallClockMs)]);
  let usage = emptyUsage();

  // ── 1단계: 원본 해설 전사(Vision). 해설 크롭 이미지가 온 문항만.
  const solutionTargets = batchItems.filter((it) => images.get(String(it.crop_id))?.solutionImageDataUrl);
  const solutionCall = solutionTargets.length === 0 ? Promise.resolve(null) : (() => {
    const parts: AiContentPart[] = [{
      type: 'text',
      text: JSON.stringify({
        problems: solutionTargets.map((it) => ({
          crop_id: it.crop_id,
          problem_number: it.problem_number,
          question_type: it.question_type,
          stem_preview: combineStem(it.common_stem, it.stem).slice(0, 400),
          source_kind: it.solution_source_kind ?? 'sol',
        })),
      }),
    }];
    for (const it of solutionTargets) {
      parts.push({ type: 'text', text: `[crop_id=${it.crop_id} · ${it.problem_number}번 해설 영역 이미지]` });
      parts.push({ type: 'image', url: images.get(String(it.crop_id))!.solutionImageDataUrl!, detail: 'high' });
    }
    return provider.complete(
      {
        model,
        instructions: SOLUTION_TRANSCRIBE_INSTRUCTIONS,
        input: [{ kind: 'message', role: 'user', parts }],
        jsonSchema: { name: 'textbook_solution_transcribe', schema: SOLUTION_TRANSCRIBE_SCHEMA },
        reasoningEffort: 'low',
        maxOutputTokens: 12000,
        safetyId,
      },
      signal,
    );
  })();

  // ── 2단계: 블라인드 독립 풀이 + 연산 카운트 + 학생 시점(V2 렌더) 품질 검사 + 원본 대조
  const blindParts: AiContentPart[] = [{
    type: 'text',
    text: JSON.stringify({
      arithmetic_primitives: arithList.map((a) => ({ code: a.code, cat: a.category, title: a.title })),
      problems: batchItems.map((it) => ({
        crop_id: it.crop_id,
        problem_number: it.problem_number,
        set_type: it.set_type ?? '',
        set_header_number: it.set_header_number ?? '',
        common_stem: String(it.common_stem ?? '').trim(),
        item_name: it.item_name,
        label: it.label,
        question_type: it.question_type,
        is_fill_in_blank: isFillInBlankProblem(it.common_stem, it.stem),
        stem: combineStem(it.common_stem, it.stem).slice(0, 2800),
        stem_raw: String(it.stem ?? '').slice(0, 2800),
        choices: it.choices,
        objective_choices: it.objective_choices,
        figure_refs: it.figure_refs,
        equations: it.equations,
        has_v2_image: !!images.get(String(it.crop_id))?.v2ProblemUrl,
        has_original_image: !!images.get(String(it.crop_id))?.originalImageDataUrl,
      })),
    }),
  }];
  for (const it of batchItems) {
    const cid = String(it.crop_id);
    const img = images.get(cid);
    if (img?.v2ProblemUrl) {
      blindParts.push({ type: 'text', text: `[crop_id=${cid} · ${it.problem_number}번 V2 렌더링 화면(학생이 보는 화면)]` });
      blindParts.push({ type: 'image', url: img.v2ProblemUrl, detail: 'high' });
    }
    if (img?.originalImageDataUrl) {
      blindParts.push({ type: 'text', text: `[crop_id=${cid} · ${it.problem_number}번 교재 원본 이미지(본문 PDF 문항 영역)]` });
      blindParts.push({ type: 'image', url: img.originalImageDataUrl, detail: 'high' });
    }
    if (img?.setHeaderImageDataUrl) {
      blindParts.push({ type: 'text', text: `[crop_id=${cid} · ${it.problem_number}번이 속한 세트의 머리(공통 지시문) 원본 이미지]` });
      blindParts.push({ type: 'image', url: img.setHeaderImageDataUrl, detail: 'auto' });
    }
  }
  const blindCall = provider.complete(
    {
      model,
      instructions: BLIND_SOLVE_INSTRUCTIONS,
      input: [{ kind: 'message', role: 'user', parts: blindParts }],
      jsonSchema: { name: 'textbook_problem_blind_solve', schema: BLIND_SOLVE_SCHEMA },
      reasoningEffort: reasoningFor('primary'),
      maxOutputTokens: 14000,
      safetyId,
    },
    signal,
  );

  const [solutionRes, blindRes] = await Promise.all([solutionCall, blindCall]);
  if (solutionRes) usage = addUsage(usage, solutionRes.usage);
  usage = addUsage(usage, blindRes.usage);
  const solutionByCrop = solutionRes ? parseProblems(finalText(solutionRes)) : new Map<string, Rec>();
  const blindByCrop = parseProblems(finalText(blindRes));

  // ── 3단계: 정답 대조(3자/2자) + 개념/사고 태깅 + 초안 제안
  const comparePayload = {
    candidate_concepts: candidateConcepts,
    thinking_primitives: thinkList.map((t) => ({ code: t.code, kind: t.kind, cat: t.category, title: t.title })),
    problems: batchItems.map((it) => {
      const cid = String(it.crop_id);
      const b = blindByCrop.get(cid) ?? {};
      const sol = effectiveSolution(it, solutionByCrop.get(cid));
      return {
        crop_id: it.crop_id,
        problem_number: it.problem_number,
        common_stem: String(it.common_stem ?? '').trim(),
        stem: combineStem(it.common_stem, it.stem).slice(0, 2200),
        choices: it.choices,
        existing_answer: it.existing_answer,
        solution_transcribed: sol ? sol.text.slice(0, 3000) : null,
        solution_answer: sol?.answer ?? null,
        ai_solution: b.ai_solution ?? '',
        ai_answer: b.ai_answer ?? '',
      };
    }),
  };

  const compareRes = await provider.complete(
    {
      model,
      instructions: COMPARE_ANALYZE_INSTRUCTIONS,
      input: [{ kind: 'message', role: 'user', parts: [{ type: 'text', text: JSON.stringify(comparePayload) }] }],
      jsonSchema: { name: 'textbook_problem_compare_analyze', schema: COMPARE_ANALYZE_SCHEMA },
      reasoningEffort: reasoningFor('primary'),
      maxOutputTokens: 12000,
      safetyId,
    },
    signal,
  );
  usage = addUsage(usage, compareRes.usage);
  const compareByCrop = parseProblems(finalText(compareRes));

  const costUsd = estimateCostUsd(model, usage, 0);
  const aiRunId = await recordAiRun(auth.admin, {
    feature: 'textbook_problem_review',
    provider: provider.name,
    model,
    promptVersion: TEXTBOOK_REVIEW_PROMPT_VERSION,
    status: 'ok',
    error: null,
    usage,
    webSearchCalls: 0,
    toolCalls: 0,
    costUsd,
    latencyMs: Date.now() - startedAt,
    conversationId: null,
    createdBy: auth.userId,
    features: {
      book_id: bookId,
      grade_label: gradeLabel,
      big_order: bigOrder,
      mid_order: midOrder,
      count: batchItems.length,
      math_only: mathOnly,
      solution_images: solutionTargets.length,
      v2_images: batchItems.filter((it) => images.get(String(it.crop_id))?.v2ProblemUrl).length,
      original_images: batchItems.filter((it) => images.get(String(it.crop_id))?.originalImageDataUrl).length,
    },
  });

  const nowIso = new Date().toISOString();
  let processed = 0;
  for (const it of batchItems) {
    const cropId = String(it.crop_id);
    const b = blindByCrop.get(cropId) ?? {};
    const c = compareByCrop.get(cropId) ?? {};
    const s = solutionByCrop.get(cropId);
    // 수학만 다시 풀 때 모델이 이 문항을 빠뜨렸으면 기존 풀이를 지우지 않는다.
    if (mathOnly && (typeof b.ai_answer !== 'string' || typeof c.answer_matched !== 'boolean')) continue;

    const arithCounts: Record<string, number> = {};
    for (const op of (Array.isArray(b.arithmetic_ops) ? b.arithmetic_ops : []) as Rec[]) {
      const code = String(op.code ?? '').trim();
      const cnt = Number(op.count) || 0;
      if (arithCodes.has(code) && cnt > 0) arithCounts[code] = (arithCounts[code] ?? 0) + cnt;
    }

    const validConceptIds = ((Array.isArray(c.concept_ids) ? c.concept_ids : []) as unknown[])
      .map((x) => String(x).trim())
      .filter((id) => conceptMap.has(id));
    const validThinkingIds = ((Array.isArray(c.thinking_codes) ? c.thinking_codes : []) as unknown[])
      .map((code) => thinkByCode.get(String(code).trim()))
      .filter((id): id is string => typeof id === 'string' && id.length > 0);
    const visualTags = ((Array.isArray(b.visual_tags) ? b.visual_tags : []) as unknown[])
      .map((x) => String(x).trim())
      .filter((x) => x.length > 0);

    // 공통 발문이 개별 발문에 그대로 들어 있으면 학생 화면에 지시문이 두 번 보인다. 모델 판정과 무관하게 데이터 오류로 잡는다.
    const dupFix = commonStemFix(it.common_stem, it.stem);
    const dupStripped = dupFix?.stem ?? null;
    const corruptedCommon = dupFix === null && isCorruptedCommonStem(it.common_stem);
    const isFillInBlank = isFillInBlankProblem(it.common_stem, it.stem);
    const falseBlank = isFalseBlankComplaint(isFillInBlank, b.quality_issue_title, b.quality_issue_detail);
    const hasFigures = itemHasFigures(it, b);
    const stemOk = (b.stem_ok !== false || falseBlank) && dupStripped === null && !corruptedCommon;
    const choicesOk = b.choices_ok !== false;
    const figureOk = b.figure_ok !== false;
    const latexOk = b.latex_v2_ok !== false;
    const fidelityOk = (b.fidelity_ok !== false || falseBlank) && !corruptedCommon;
    const img = images.get(cropId);
    const originalCompared = !!img?.originalImageDataUrl && !!img?.v2ProblemUrl;
    const figure = figureReviewVerdict({
      hasFigures,
      originalCompared,
      positionOk: b.figure_position_ok,
      sizeRatio: b.figure_size_ratio,
    });
    const issueTitle: string | null = !falseBlank && typeof b.quality_issue_title === 'string' && b.quality_issue_title.trim()
      ? b.quality_issue_title
      : dupStripped !== null
      ? '공통 발문 중복 표시 (개별 발문에 공통 지시문이 다시 들어 있음)'
      : corruptedCommon
      ? '공통 지시문 누락·오염 (공통 발문에 지시문 대신 수식·숫자만 들어 있음)'
      : figure.issueTitle;
    const issueDetail: string | null = !falseBlank && typeof b.quality_issue_detail === 'string' && b.quality_issue_detail.trim()
      ? b.quality_issue_detail
      : dupStripped !== null
      ? 'common_stem과 stem 에 같은 지시문이 들어 있어 학생 화면에 두 번 표시됩니다. 개별 발문에서 공통 부분을 제거하면 해결됩니다.'
      : corruptedCommon
      ? `공통 발문(common_stem="${String(it.common_stem ?? '')}")에 지시문 문장이 없어 원본 세트 머리 지시문으로 복원해야 합니다.`
      : figure.issueDetail;
    // 그림 문항은 원본과 직접 대조해 크기·위치가 맞다고 확인된 경우에만 통과다.
    const qualityOk = (!hasFigures || figure.verified) && stemOk && choicesOk && figureOk && latexOk && fidelityOk && !issueTitle;

    const cleanedVisionSol = s?.found === true
      ? cleanSolutionTranscribedText(s.solution_transcribed, it.problem_number, s.solution_answer)
      : '';
    const solutionAnswerFound = s?.found === true && typeof s?.solution_answer === 'string' && s.solution_answer.trim().length > 0;
    const solutionTextFound = s?.found === true && cleanedVisionSol.length > 0;
    const solutionFound = solutionTextFound || solutionAnswerFound;
    const sol = effectiveSolution(it, s);
    const existingAnsRaw = String(it.existing_answer ?? '').trim();
    const existingAnsMissingOrImage = !existingAnsRaw ||
      String(it.answer_kind ?? '') === 'image' ||
      /^(?:\[\s*image\s*\]|\(\s*image\s*\)|\[그림\])$/i.test(existingAnsRaw);
    const normExisting = normAnsSimple(existingAnsRaw);
    const normAi = normAnsSimple(String(b.ai_answer ?? ''));
    const normSol = normAnsSimple(String(sol?.answer ?? ''));
    const deterministicMatch = !existingAnsMissingOrImage &&
      normExisting.length > 0 &&
      normAi.length > 0 &&
      b.ai_answer !== '판단불가' &&
      normExisting === normAi &&
      (!normSol || normExisting === normSol);
    const answerMatched = !existingAnsMissingOrImage && (c.answer_matched === true || deterministicMatch);
    const matchMode = sol || it.has_solution_ref === true ? '3way' : '2way';
    const drafts = Array.isArray(c.draft_proposals) ? c.draft_proposals : [];

    const existing = await auth.admin
      .from('textbook_problem_analyses')
      .select('solution_transcribed,solution_answer,solution_source,render_checks,quality_status,fix_proposal,engine_held_at,engine_hold_note')
      .eq('crop_id', cropId)
      .maybeSingle();
    const prev = (existing.data ?? {}) as Rec;
    // 운영자가 직접 고친 원본 해설은 Vision 결과로 덮지 않는다.
    const keepManual = prev.solution_source === 'manual' && typeof prev.solution_transcribed === 'string';
    // 엔진 보류 중인 문항은 재검수해도 보류를 유지한다(엔진 목록에서 따로 관리).
    const keepHeld = prev.quality_status === 'held';

    const curStemStr = String(it.stem ?? '');
    const sanitizedCurStem = sanitizeProblemMarkup(curStemStr);
    const hasSyntaxFix = sanitizedCurStem !== curStemStr;
    const dataFixable = hasSyntaxFix || isDataFixableSymptom(issueTitle, issueDetail, null, curStemStr, it.common_stem);

    // 데이터 수정 제안: 원문과 실제로 다를 때만 남긴다. 이미 적용된 제안은 비운다.
    const rawIssueKind: IssueKind = dupStripped !== null || corruptedCommon || dataFixable
      ? 'data'
      : hasFigures && !qualityOk && b.issue_kind !== 'data'
      ? 'figure'
      : normalizeIssueKind(b.issue_kind, !qualityOk);
    const issueKind: IssueKind = rawIssueKind === 'engine' && (!fidelityOk || dataFixable) ? 'data' : rawIssueKind;
    // 렌더 엔진 문제(본문·원본 충실도 이상이 없고 도형 문항도 아니며 본문 수정으로 고칠 수 없는 순수 조판 결함)만 1회차에서 보류(held)로 넘긴다.
    const autoHoldEngine = !qualityOk && issueKind === 'engine' && dupStripped === null && !corruptedCommon &&
      !dataFixable && fidelityOk && !hasFigures;
    // 공통 발문 중복은 규칙으로 바로 고친 본문을 제안한다(모델 제안보다 우선).
    const aiProposedStem = typeof b.proposed_stem === 'string' && b.proposed_stem.trim()
      ? sanitizeProblemMarkup(b.proposed_stem.trim())
      : null;
    let proposedStem = dupStripped !== null
      ? sanitizeProblemMarkup(dupStripped)
      : (issueKind === 'data' || hasFigures) && aiProposedStem && !sameRenderedMath(aiProposedStem, curStemStr)
      ? aiProposedStem
      : hasSyntaxFix
      ? sanitizedCurStem
      : null;
    let proposedCommonStem = dupFix?.commonStem ?? (
      (issueKind === 'data' || corruptedCommon) && typeof b.proposed_common_stem === 'string' && b.proposed_common_stem.trim() &&
        !sameRenderedMath(b.proposed_common_stem, String(it.common_stem ?? ''))
        ? b.proposed_common_stem.trim()
        : null
    );
    if (proposedCommonStem && isDependentSetItem(it)) {
      const folded = foldCommonStemIntoStem(sanitizeProblemMarkup(proposedCommonStem), proposedStem ?? curStemStr);
      proposedStem = sameRenderedMath(folded, curStemStr) ? proposedStem : folded;
      proposedCommonStem = null;
    }
    if (proposedStem) {
      const unguided = stripGuidedSolution(proposedStem);
      proposedStem = sameRenderedMath(unguided, curStemStr) ? null : unguided;
    }
    const proposedChoices = issueKind === 'data' ? normalizeProposedChoices(b.proposed_choices) : null;
    const choiceTexts = (arr: unknown) =>
      JSON.stringify(
        (Array.isArray(arr) ? arr : []).map((c) =>
          mathDelimiterInsensitive(String(c && typeof c === 'object' ? (c as Record<string, unknown>).text ?? '' : c ?? ''))
        ),
      );
    const choicesDiffer = proposedChoices !== null && choiceTexts(proposedChoices) !== choiceTexts(it.choices);
    const proposedAns = !answerMatched
      ? (typeof c.proposed_answer === 'string' && c.proposed_answer.trim() && c.proposed_answer.trim() !== '판단불가'
        ? c.proposed_answer.trim()
        : (sol?.answer && sol.answer !== '판단불가'
          ? sol.answer
          : (typeof b.ai_answer === 'string' && b.ai_answer.trim() && b.ai_answer.trim() !== '판단불가'
            ? b.ai_answer.trim()
            : null)))
      : null;
    const fixReason = dupFix?.commonStem
      ? '공통 발문(common_stem)에 개별 문항 본문까지 들어 있어, 공통 발문은 지시문만 남기고 개별 발문에서 지시문을 뺐습니다.'
      : dupStripped !== null
      ? '공통 발문(common_stem)이 개별 발문에도 들어 있어 공통 부분을 제거했습니다.'
      : typeof b.fix_reason === 'string'
      ? b.fix_reason
      : null;
    const fixProposal: Rec = proposedStem || proposedCommonStem || choicesDiffer || proposedAns
      ? {
        kind: issueKind,
        stem: proposedStem,
        common_stem: proposedCommonStem,
        choices: choicesDiffer ? proposedChoices : null,
        proposed_answer: proposedAns,
        math_reason: !answerMatched && typeof c.mismatch_reason === 'string' ? c.mismatch_reason : null,
        reason: fixReason,
        reason_code: dupStripped !== null ? 'common_stem_duplicate' : null,
        source: dupStripped !== null ? 'system' : 'stage2',
        created_at: nowIso,
      }
      : {};

    // 1회차 검수에서 수학적 대조에 아무 이상이 없으면 바로 자동 승인(approved)하고 문제은행 정답도 동기화한다.
    const nextMathStatus = answerMatched ? 'approved' : 'issue';
    const mathFields = {
      ai_solution: typeof b.ai_solution === 'string' ? b.ai_solution : null,
      ai_answer: typeof b.ai_answer === 'string' ? b.ai_answer : null,
      arithmetic_counts: arithCounts,
      match_mode: matchMode,
      answer_matched: answerMatched,
      mismatch_reason: answerMatched ? null : (typeof c.mismatch_reason === 'string' ? c.mismatch_reason : null),
      concept_ids: [...new Set(validConceptIds)],
      thinking_ids: [...new Set(validThinkingIds)],
      draft_proposals: drafts,
      analyzed_at: nowIso,
      math_status: nextMathStatus,
      ...(answerMatched ? { math_approved_at: nowIso, math_approved_by: auth.userId } : {}),
      updated_at: nowIso,
    };

    if (mathOnly) {
      // solved_at 은 2단계 품질 판정의 시점이다(4단계가 그 뒤 수정 적용 여부를 본다). 수학만 다시 풀 때는 두고 analyzed_at 만 바꾼다.
      const prevFp = (prev.fix_proposal ?? {}) as Rec;
      await auth.admin.from('textbook_problem_analyses').update({
        ...mathFields,
        fix_proposal: proposedAns
          ? { ...prevFp, proposed_answer: proposedAns, math_reason: typeof c.mismatch_reason === 'string' ? c.mismatch_reason : null }
          : prevFp,
        ...(solutionFound && !keepManual
          ? {
            solution_transcribed: cleanedVisionSol || (prev.solution_transcribed ?? null),
            solution_answer: typeof s!.solution_answer === 'string' ? s!.solution_answer : (prev.solution_answer ?? null),
            solution_source: 'textbook_vision',
            solution_extracted_at: nowIso,
          }
          : {}),
      }).eq('crop_id', cropId);
    } else {
      const nextQualStatus = keepHeld || autoHoldEngine ? 'held' : (qualityOk ? 'clean' : 'issue');
      await auth.admin.from('textbook_problem_analyses').upsert({
        crop_id: cropId,
        academy_id: academyId,
        solution_transcribed: keepManual
          ? prev.solution_transcribed
          : solutionTextFound
          ? cleanedVisionSol
          : (prev.solution_source === 'textbook_vision'
            ? cleanSolutionTranscribedText(prev.solution_transcribed, it.problem_number, prev.solution_answer) || null
            : null),
        solution_answer: keepManual
          ? prev.solution_answer ?? null
          : solutionAnswerFound
          ? String(s!.solution_answer).trim()
          : (prev.solution_source === 'textbook_vision' ? prev.solution_answer ?? null : null),
        solution_source: keepManual ? 'manual' : solutionFound ? 'textbook_vision' : (prev.solution_source ?? null),
        solution_extracted_at: solutionFound ? nowIso : undefined,
        visual_tags: visualTags,
        quality_checks: {
          judged_from_v2_image: b.judged_from_v2_image === true,
          stem_ok: stemOk,
          choices_ok: choicesOk,
          figure_ok: figureOk,
          latex_v2_ok: latexOk,
          fidelity_ok: fidelityOk,
          has_figures: hasFigures,
          is_fill_in_blank: isFillInBlank,
          issue_title: issueTitle,
          issue_detail: issueDetail,
          issue_kind: issueKind,
          question_kind_ai: ['objective', 'subjective', 'essay'].includes(String(b.question_kind)) ? b.question_kind : null,
          solution_vision: s
            ? { found: s.found === true, confidence: s.confidence ?? null, note: s.note ?? null }
            : null,
        },
        fix_proposal: fixProposal,
        // 문항 본문이 다시 풀렸으니 이전 V2 렌더 판정은 비운다(해설·정답 카드가 바뀐다).
        // 이번 검수에서 원본과 직접 잰 그림 크기·위치는 남겨 앱이 비율대로 폭을 보정하게 한다.
        render_checks: originalCompared && hasFigures
          ? {
            original_compared: true,
            figure_position_ok: figure.positionOk,
            figure_size_ratio: figure.sizeRatio,
            source: 'review',
          }
          : {},
        render_checked_at: null,
        solved_at: nowIso,
        ...mathFields,
        quality_status: nextQualStatus,
        ...(autoHoldEngine && !keepHeld
          ? {
            engine_held_at: nowIso,
            engine_held_by: auth.userId,
            engine_hold_note: issueTitle ?? '렌더 엔진 조판 확인 필요',
          }
          : {}),
      });
    }

    await auth.userClient.rpc('textbook_problem_recalc_scores', { p_crop_id: cropId });

    if (!answerMatched) {
      await upsertOpenFinding(auth, {
        academy_id: academyId,
        crop_id: cropId,
        stage: 'compare',
        axis: 'validity',
        error_type: 'answer_mismatch',
        severity: 'blocker',
        source: 'ai',
        check_key: 'ai_answer_compare',
        title: `정답 불일치 (기존: ${it.existing_answer ?? '없음'} / 해설: ${sol?.answer ?? '없음'} / AI: ${b.ai_answer ?? '없음'})`,
        detail: String(c.mismatch_reason ?? '기존 정답과 AI 독립 풀이 정답이 일치하지 않습니다.'),
        evidence: {
          existing_answer: it.existing_answer,
          ai_answer: b.ai_answer,
          solution_answer: sol?.answer ?? null,
        },
        proposal: proposedAns
          ? {
            target: 'answer',
            after: { kind: 'text', value: proposedAns },
            reason: String(c.mismatch_reason ?? 'AI 독립 풀이 및 원본 해설 대조 결과'),
            keeps: '문항 본문과 해설 위치는 그대로 유지합니다.',
          }
          : null,
        status: 'open',
        ai_run_id: aiRunId,
      }).catch(() => null);
    } else {
      if (existingAnsRaw) {
        try {
          await auth.admin.rpc('textbook_review_sync_pb_answer', {
            p_crop_id: cropId,
            p_answer: existingAnsRaw,
          });
        } catch {
          // ignore sync failure during batch review
        }
      }
      await resolveOpenFinding(auth, cropId, 'ai_answer_compare').catch(() => null);
      await resolveOpenFinding(auth, cropId, 'load:answer_missing').catch(() => null);
      await resolveOpenFinding(auth, cropId, 'load:answer_mismatch').catch(() => null);
    }

    // 수학만 다시 풀 때는 품질 지적을 건드리지 않는다.
    if (!mathOnly && !qualityOk) {
      await upsertOpenFinding(auth, {
        academy_id: academyId,
        crop_id: cropId,
        stage: 'render',
        axis: !fidelityOk ? 'fidelity' : (!latexOk || !figureOk ? 'output' : 'fidelity'),
        error_type: !fidelityOk ? 'problem_transcription' : (!latexOk ? 'render_item' : 'problem_transcription'),
        severity: 'warning',
        source: 'ai',
        check_key: 'ai_quality_v2_student_view',
        title: issueTitle ?? '학생 시점 V2 렌더 품질 확인 필요',
        detail: issueDetail ?? 'V2 렌더링 화면에서 발문·선지·도형·수식 표시를 확인해야 합니다.',
        evidence: {
          judged_from_v2_image: b.judged_from_v2_image === true,
          stem_ok: stemOk,
          choices_ok: choicesOk,
          figure_ok: figureOk,
          latex_v2_ok: latexOk,
          fidelity_ok: fidelityOk,
          issue_kind: issueKind,
        },
        proposal: proposedStem || proposedCommonStem || choicesDiffer
          ? {
            target: 'problem',
            after: { stem: proposedStem, common_stem: proposedCommonStem, choices: choicesDiffer ? proposedChoices : null },
            reason: fixReason ?? '원본과 대조한 데이터 수정 제안',
            keeps: '정답·해설 위치는 그대로 유지합니다.',
          }
          : null,
        status: keepHeld || autoHoldEngine ? 'held' : 'open',
        ai_run_id: aiRunId,
      }).catch(() => null);
    } else if (!mathOnly) {
      await resolveOpenFinding(auth, cropId, 'ai_quality_v2_student_view').catch(() => null);
    }

    // 해설 좌표는 있는데 전사에 실패한 경우 알려 둔다(운영자가 좌표를 고치거나 직접 입력).
    if (it.has_solution_ref === true && images.get(cropId)?.solutionImageDataUrl && !solutionFound) {
      await upsertOpenFinding(auth, {
        academy_id: academyId,
        crop_id: cropId,
        stage: 'solution_text',
        axis: 'fidelity',
        error_type: 'solution_transcription',
        severity: 'warning',
        source: 'ai',
        check_key: 'ai_solution_vision',
        title: '원본 해설 전사 실패',
        detail: String(s?.note ?? '해설 좌표 영역 이미지에서 이 문항의 풀이를 읽지 못했습니다. 해설 좌표를 확인하거나 직접 입력하세요.'),
        evidence: { solution_raw_page: it.solution_raw_page, region_1k: it.solution_region_1k },
        status: 'open',
        ai_run_id: aiRunId,
      }).catch(() => null);
    } else if (solutionFound) {
      await resolveOpenFinding(auth, cropId, 'ai_solution_vision').catch(() => null);
    }

    processed += 1;
  }

  const remaining = Math.max(0, todoItems.length - processed);
  return jsonResponse({
    ok: true,
    processed,
    remaining,
    total: allItems.length,
    done: remaining === 0,
    cost_usd: costUsd,
  });
}

/**
 * 재검수 대상: 미검수, 풀이 없음, 또는 해설 좌표가 있는데 원본 해설 전사를 아직 시도하지 않은 문항(승인된 것은 제외).
 * Vision 전사를 시도했다가 못 읽은 문항(quality_checks.solution_vision 기록 있음)은 다시 대상이 되지 않는다 — 운영자가 좌표를 고치거나 직접 입력한다.
 */
export function isReviewTodo(it: Rec, forceRerun: boolean): boolean {
  if (forceRerun) return true;
  const mathStatus = String(it.math_status ?? 'pending');
  if (mathStatus === 'pending' || !it.ai_solution) return true;
  if (mathStatus === 'approved') return false;
  const qc = (it.quality_checks ?? {}) as Rec;
  const visionTried = qc.solution_vision !== null && qc.solution_vision !== undefined;
  return it.has_solution_ref === true && !it.solution_transcribed && !it.solution_answer && !visionTried;
}

/** 수학만 다시 풀 대상(math_only): 수학 오류로 남은 문항. 본문을 고친 뒤 옛 본문으로 푼 AI 답을 새로 맞출 때 쓴다. */
export function isMathResolveTarget(it: Rec): boolean {
  return String(it.math_status ?? 'pending') === 'issue';
}

/**
 * 정답 대조에 쓸 원본 해설. 저장 규칙과 같은 해설로 대조한다: 운영자가 직접 고친 해설 → 이번 Vision 전사 →
 * 저장된 Vision 전사(이번에 해설 이미지를 안 보냈거나 못 읽은 경우) 순. 없으면 null.
 */
export function effectiveSolution(it: Rec, vision: Rec | undefined): { text: string; answer: string | null } | null {
  const answerOf = (v: unknown) => typeof v === 'string' && v.trim() ? v.trim() : null;
  const storedAns = answerOf(it.solution_answer);
  const storedText = typeof it.solution_transcribed === 'string'
    ? cleanSolutionTranscribedText(it.solution_transcribed, it.problem_number, storedAns)
    : '';
  if (it.solution_source === 'manual' && (storedText || storedAns)) return { text: storedText, answer: storedAns };
  const visionAns = vision?.found === true ? answerOf(vision.solution_answer) : null;
  const visionText = vision?.found === true && typeof vision.solution_transcribed === 'string'
    ? cleanSolutionTranscribedText(vision.solution_transcribed, it.problem_number, visionAns)
    : '';
  if (visionText || visionAns) return { text: visionText, answer: visionAns };
  if (it.solution_source === 'textbook_vision' && (storedText || storedAns)) return { text: storedText, answer: storedAns };
  return null;
}

/**
 * V2 렌더링 학생 시점 검수. 매니저앱이 문항 카드·정답+해설 카드를 V2로 찍어 서명 URL을 보내면
 * 모델이 학생 시점에서 읽히는지 판정하고 render_checks·quality_status·findings 에 반영한다.
 * 교재 원본 이미지(base64)가 같이 오면 원본과 같은지(내용·그림 위치·그림 크기)도 본다.
 *   body: { academy_id, items: [{ crop_id, problem_url?, answer_solution_url?, solution_kind?: 'textbook'|'ai',
 *           original_image_base64?, set_header_image_base64? }] }
 */
/** 그림 크기 비율(V2 ÷ 원본)이 이 범위 밖이면 크기를 다시 맞춘다(0.85~1.15, 목표 1.0배). */
export const FIGURE_SIZE_RATIO_MIN = 0.85;
export const FIGURE_SIZE_RATIO_MAX = 1.15;

export function figureSizeRatioOk(ratio: unknown): boolean {
  const r = Number(ratio);
  if (ratio === null || ratio === undefined || !Number.isFinite(r) || r <= 0) return true;
  return r >= FIGURE_SIZE_RATIO_MIN && r <= FIGURE_SIZE_RATIO_MAX;
}

export interface FigureReviewVerdict {
  /** 원본과 직접 대조해 크기(잰 비율이 허용 범위)·위치가 맞다고 확인됨 */
  verified: boolean;
  positionOk: boolean;
  sizeRatio: number | null;
  issueTitle: string | null;
  issueDetail: string | null;
}

/// 1차 검수(블라인드 풀이 호출)에서 받은 그림 크기·위치 판정. 그림 문항은 원본과 대조해 확인된 경우에만 통과시킨다.
export function figureReviewVerdict(
  { hasFigures, originalCompared, positionOk, sizeRatio }: {
    hasFigures: boolean;
    originalCompared: boolean;
    positionOk: unknown;
    sizeRatio: unknown;
  },
): FigureReviewVerdict {
  const ratio = originalCompared && typeof sizeRatio === 'number' && Number.isFinite(sizeRatio) && sizeRatio > 0
    ? Math.round(sizeRatio * 100) / 100
    : null;
  const posOk = !originalCompared || positionOk !== false;
  if (!hasFigures) return { verified: true, positionOk: true, sizeRatio: null, issueTitle: null, issueDetail: null };
  if (!originalCompared) {
    return {
      verified: false,
      positionOk: posOk,
      sizeRatio: null,
      issueTitle: '그림·도형 문항 원본 대조 필요',
      issueDetail: '교재 원본 이미지와 V2 카드를 함께 보지 못해 그림 크기·위치를 확인하지 못했습니다.',
    };
  }
  if (ratio !== null && !figureSizeRatioOk(ratio)) {
    return {
      verified: false,
      positionOk: posOk,
      sizeRatio: ratio,
      issueTitle: `그림 크기가 원본과 다름 (원본 대비 ${ratio}배)`,
      issueDetail: `본문 글자 대비 그림 크기가 원본의 ${ratio}배입니다. 이 비율로 그림 폭을 자동 보정합니다.`,
    };
  }
  if (!posOk) {
    return {
      verified: false,
      positionOk: false,
      sizeRatio: ratio,
      issueTitle: '그림 위치가 원본과 다름',
      issueDetail: 'V2 카드의 그림 자리(본문 옆·아래, 정렬)가 교재 원본과 다릅니다.',
    };
  }
  if (ratio === null) {
    return {
      verified: false,
      positionOk: true,
      sizeRatio: null,
      issueTitle: '그림 크기를 원본과 비교하지 못함',
      issueDetail: '원본 또는 V2 카드에서 그림 크기를 재지 못했습니다.',
    };
  }
  return { verified: true, positionOk: true, sizeRatio: ratio, issueTitle: null, issueDetail: null };
}

/** 문제은행 문항에 그림이 있는가(그림 자산 또는 발문·공통 발문의 [그림] 표시). */
export function pbQuestionHasFigures(q: Rec): boolean {
  const meta = (q.meta ?? {}) as Rec;
  return itemHasFigures({ pb_figure_assets: meta.figure_assets, stem: q.stem }) ||
    figureMarkerCount(meta.common_stem) > 0;
}

/** crop_id → 문제은행 문항 그림 유무. 문항을 찾지 못한 크롭은 넣지 않는다(판단 보류). */
async function loadPbHasFigures(admin: AuthContext['admin'], analyses: Rec[]): Promise<Map<string, boolean>> {
  const uidByCrop = new Map<string, string>();
  for (const a of analyses) {
    const uid = ((a.textbook_problem_crops ?? {}) as Rec).pb_question_uid;
    if (typeof uid === 'string' && uid) uidByCrop.set(String(a.crop_id), uid);
  }
  const out = new Map<string, boolean>();
  if (uidByCrop.size === 0) return out;
  const { data, error } = await admin
    .from('pb_questions')
    .select('question_uid,stem,meta')
    .in('question_uid', [...new Set(uidByCrop.values())]);
  if (error) return out;
  const byUid = new Map(((data ?? []) as Rec[]).map((q) => [String(q.question_uid), pbQuestionHasFigures(q)]));
  for (const [cropId, uid] of uidByCrop) {
    const has = byUid.get(uid);
    if (has !== undefined) out.set(cropId, has);
  }
  return out;
}

export async function handleTextbookProblemRenderCheck(
  req: Request,
  auth: AuthContext,
  body: Rec,
): Promise<Response> {
  const academyId = uuidOrNull(body.academy_id);
  if (!academyId) return errorResponse(400, 'invalid_scope', '학원 정보가 필요합니다.');
  const rawItems = Array.isArray(body.items) ? (body.items as unknown[]) : [];
  const items = rawItems
    .map((x) => (x ?? {}) as Rec)
    .map((r) => ({
      cropId: uuidOrNull(r.crop_id),
      problemUrl: typeof r.problem_url === 'string' && /^https:\/\//.test(r.problem_url) ? r.problem_url : null,
      answerSolutionUrl: typeof r.answer_solution_url === 'string' && /^https:\/\//.test(r.answer_solution_url)
        ? r.answer_solution_url
        : null,
      solutionKind: r.solution_kind === 'ai' ? 'ai' : 'textbook',
      originalUrl: imageDataUrl(r.original_image_base64, r.original_image_mime),
      setHeaderUrl: imageDataUrl(r.set_header_image_base64, r.set_header_image_mime),
      solutionOriginalUrl: r.solution_kind === 'ai'
        ? null
        : imageDataUrl(r.solution_original_image_base64, r.solution_original_image_mime),
      isFillInBlank: r.is_fill_in_blank === true,
    }))
    .filter((x): x is {
      cropId: string;
      problemUrl: string | null;
      answerSolutionUrl: string | null;
      solutionKind: string;
      originalUrl: string | null;
      setHeaderUrl: string | null;
      solutionOriginalUrl: string | null;
      isFillInBlank: boolean;
    } => !!x.cropId && (!!x.problemUrl || !!x.answerSolutionUrl))
    .slice(0, 8);
  if (items.length === 0) return jsonResponse({ ok: true, processed: 0 });

  const wallClockMs = thinkWallClockMs();
  const provider = createAiProvider({ timeoutMs: wallClockMs + 5000 });
  if (!provider) return errorResponse(503, 'ai_not_configured', 'OPENAI_API_KEY 비밀값이 설정되지 않았습니다.');
  const budget = await getBudgetStatus(auth.admin).catch(() => null);
  if (budget?.exceeded && budget.mode === 'block') {
    return errorResponse(429, 'budget_exceeded', '이번 달 AI 한도를 넘었습니다.');
  }

  const cropIds = items.map((x) => x.cropId);
  const { data: analyses } = await auth.admin
    .from('textbook_problem_analyses')
    .select(
      'crop_id,academy_id,quality_status,quality_checks,fix_proposal,solved_at,textbook_problem_crops(problem_number,label,pb_question_uid)',
    )
    .in('crop_id', cropIds);
  const analysisByCrop = new Map<string, Rec>();
  for (const a of (analyses ?? []) as Rec[]) {
    if (String(a.academy_id) === academyId) analysisByCrop.set(String(a.crop_id), a);
  }
  const targets = items.filter((x) => analysisByCrop.has(x.cropId));
  if (targets.length === 0) return jsonResponse({ ok: true, processed: 0 });
  const pbHasFiguresByCrop = await loadPbHasFigures(auth.admin, [...analysisByCrop.values()]);

  const startedAt = Date.now();
  const model = modelFor('primary');
  const safetyId = await safetyIdentifier(auth.userId);
  const signal = AbortSignal.any([req.signal, AbortSignal.timeout(wallClockMs)]);

  const parts: AiContentPart[] = [{
    type: 'text',
    text: JSON.stringify({
      problems: targets.map((x) => {
        const a = analysisByCrop.get(x.cropId)!;
        const crop = (a.textbook_problem_crops ?? {}) as Rec;
        const qc = (a.quality_checks ?? {}) as Rec;
        return {
          crop_id: x.cropId,
          problem_number: crop.problem_number ?? '',
          label: crop.label ?? '',
          is_fill_in_blank: x.isFillInBlank || qc.is_fill_in_blank === true,
          has_problem_card: !!x.problemUrl,
          has_answer_solution_card: !!x.answerSolutionUrl,
          has_original_image: !!x.originalUrl,
          has_solution_original_image: !!(x.solutionOriginalUrl && x.answerSolutionUrl),
          ...(pbHasFiguresByCrop.get(x.cropId) === false ? { has_figure: false } : {}),
          solution_kind: x.solutionKind,
        };
      }),
    }),
  }];
  for (const x of targets) {
    if (x.problemUrl) {
      parts.push({ type: 'text', text: `[crop_id=${x.cropId} · 문항 카드(V2)]` });
      parts.push({ type: 'image', url: x.problemUrl, detail: 'high' });
    }
    if (x.originalUrl) {
      parts.push({ type: 'text', text: `[crop_id=${x.cropId} · 교재 원본 이미지(본문 PDF 문항 영역)]` });
      parts.push({ type: 'image', url: x.originalUrl, detail: 'high' });
    }
    if (x.setHeaderUrl) {
      parts.push({ type: 'text', text: `[crop_id=${x.cropId} · 세트 머리(공통 지시문) 원본 이미지]` });
      parts.push({ type: 'image', url: x.setHeaderUrl, detail: 'auto' });
    }
    if (x.answerSolutionUrl) {
      parts.push({
        type: 'text',
        text: `[crop_id=${x.cropId} · 정답+해설 카드(V2 · ${x.solutionKind === 'ai' ? 'AI 풀이' : '원본 해설'})]`,
      });
      parts.push({ type: 'image', url: x.answerSolutionUrl, detail: 'high' });
      if (x.solutionOriginalUrl) {
        parts.push({ type: 'text', text: `[crop_id=${x.cropId} · 원본 해설 이미지(해설 PDF 풀이 영역)]` });
        parts.push({ type: 'image', url: x.solutionOriginalUrl, detail: 'high' });
      }
    }
  }

  const res = await provider.complete(
    {
      model,
      instructions: RENDER_CHECK_INSTRUCTIONS,
      input: [{ kind: 'message', role: 'user', parts }],
      jsonSchema: { name: 'textbook_problem_render_check', schema: RENDER_CHECK_SCHEMA },
      reasoningEffort: 'low',
      maxOutputTokens: 8000,
      safetyId,
    },
    signal,
  );
  const byCrop = parseProblems(finalText(res));
  const costUsd = estimateCostUsd(model, res.usage, 0);
  const aiRunId = await recordAiRun(auth.admin, {
    feature: 'textbook_problem_render_check',
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
    features: { count: targets.length, original_images: targets.filter((x) => x.originalUrl).length },
  });

  const nowIso = new Date().toISOString();
  let processed = 0;
  const results: Rec[] = [];
  for (const x of targets) {
    const r = byCrop.get(x.cropId);
    if (!r) continue;
    const a = analysisByCrop.get(x.cropId)!;
    const qc = (a.quality_checks ?? {}) as Rec;
    const isFillInBlank = x.isFillInBlank || qc.is_fill_in_blank === true;
    const falseBlank = isFalseBlankComplaint(isFillInBlank, r.issue_title, r.issue_detail);
    const falseSubAnsSpacing = isSubAnswerSpacingComplaint(r.issue_title, r.issue_detail);
    const originalCompared = !!x.originalUrl && !!x.problemUrl;
    const problemOk = r.problem_ok !== false || falseBlank;
    const answerOk = r.answer_ok !== false || falseSubAnsSpacing;
    const solutionOk = r.solution_ok !== false;
    const fidelityOk = !originalCompared || r.fidelity_ok !== false || falseBlank;
    // 문제은행 문항에 그림 자산도 [그림] 표시도 없으면 모델이 표·수식을 그림으로 잰 값이므로 그림 위치·크기 판정을 버린다.
    const noPbFigure = pbHasFiguresByCrop.get(x.cropId) === false;
    const figurePositionOk = noPbFigure || !originalCompared || r.figure_position_ok !== false;
    const sizeRatio = !noPbFigure && originalCompared && typeof r.figure_size_ratio === 'number' &&
        Number.isFinite(r.figure_size_ratio) && r.figure_size_ratio > 0
      ? Math.round(r.figure_size_ratio * 100) / 100
      : null;
    const figureSizeOk = figureSizeRatioOk(sizeRatio);
    const renderOk = problemOk && answerOk && solutionOk && fidelityOk && figurePositionOk && figureSizeOk;
    // 2단계 판정 뒤에 본문·선지·그림 수정이 적용됐거나 이번 검수가 원본과 직접 대조했으면 2단계 판정은 옛 화면 기준이다.
    // 이번 V2 렌더 판정만 본다.
    const fp = (a.fix_proposal ?? {}) as Rec;
    const fixAppliedAfterSolve = typeof fp.applied_at === 'string' &&
      Array.isArray(fp.applied_fields) && fp.applied_fields.length > 0 &&
      (!a.solved_at || Date.parse(String(fp.applied_at)) > Date.parse(String(a.solved_at)));
    const hasFigures = !noPbFigure && (qc.has_figures === true || qc.issue_kind === 'figure' || sizeRatio !== null ||
      (Array.isArray((fp.figure_measure as Rec | undefined)?.figures) &&
        ((fp.figure_measure as Rec).figures as unknown[]).length > 0));
    // 그림 문항은 수정안이 DB 에 적용됐거나, 이번 검수에서 원본과 직접 대조해 크기·위치가 맞다고 잰 경우에 통과로 본다.
    const figureVerifiedNow = originalCompared && figurePositionOk && sizeRatio !== null && figureSizeOk;
    const figureAppliedOrNone = !hasFigures || typeof fp.applied_at === 'string' || figureVerifiedNow;
    const stage2Ok = fixAppliedAfterSolve || (originalCompared && figureAppliedOrNone) ||
      (qc.stem_ok !== false && qc.choices_ok !== false && qc.figure_ok !== false &&
        qc.latex_v2_ok !== false && qc.fidelity_ok !== false && !qc.issue_title);
    const prevStatus = String(a.quality_status ?? 'pending');
    const figureOnly = problemOk && answerOk && solutionOk && fidelityOk && (!figurePositionOk || !figureSizeOk || (hasFigures && !figureAppliedOrNone));
    const dataSymptom = isDataFixableSymptom(r.issue_title, r.issue_detail, r.engine_symptom);
    const rawIssueKind = figureOnly ? 'figure' : normalizeIssueKind(r.issue_kind, !renderOk);
    const issueKind: IssueKind = rawIssueKind === 'engine' && (!fidelityOk || qc.fidelity_ok === false || dataSymptom)
      ? 'data'
      : rawIssueKind;
    const autoHoldEngine = prevStatus !== 'approved' && prevStatus !== 'held' && !renderOk &&
      issueKind === 'engine' && fidelityOk && qc.fidelity_ok !== false && !dataSymptom && !hasFigures;
    // 이전 보류(held) 문항이라도 이번 V2 렌더 검수에서 문항 카드가 정상(problemOk && fidelityOk)이고 엔진 문제가 아니면 보류를 해제한다.
    const unholdFromRender = prevStatus === 'held' && problemOk && fidelityOk && issueKind !== 'engine';
    const nextStatus = prevStatus === 'approved' || (prevStatus === 'held' && !unholdFromRender)
      ? prevStatus
      : autoHoldEngine
      ? 'held'
      : (renderOk && stage2Ok && figureAppliedOrNone ? 'approved' : 'issue');
    const issueTitle = !falseBlank && !falseSubAnsSpacing && typeof r.issue_title === 'string' && r.issue_title.trim()
      ? r.issue_title
      : !figureSizeOk
      ? `그림 크기가 원본과 다름 (원본 대비 ${sizeRatio}배)`
      : !figurePositionOk
      ? '그림 위치가 원본과 다름'
      : hasFigures && !figureAppliedOrNone
      ? '그림·도형 문항 원본 대조 수정안 확인 필요'
      : null;

    await auth.admin.from('textbook_problem_analyses').update({
      render_checks: {
        problem_ok: problemOk,
        answer_ok: answerOk,
        solution_ok: solutionOk,
        fidelity_ok: fidelityOk,
        figure_position_ok: figurePositionOk,
        figure_size_ratio: sizeRatio,
        original_compared: originalCompared,
        flagged_after_approval: prevStatus === 'approved' && !renderOk,
        issue_title: renderOk && figureAppliedOrNone ? null : issueTitle,
        issue_detail: renderOk && figureAppliedOrNone ? null : (r.issue_detail ?? null),
        issue_kind: issueKind,
        engine_symptom: issueKind === 'engine' && typeof r.engine_symptom === 'string' ? r.engine_symptom : null,
        solution_kind: x.solutionKind,
        checked_problem: !!x.problemUrl,
        checked_answer_solution: !!x.answerSolutionUrl,
        model,
      },
      render_checked_at: nowIso,
      quality_status: nextStatus,
      ...(nextStatus === 'approved' && prevStatus !== 'approved'
        ? { quality_approved_at: nowIso, quality_approved_by: auth.userId }
        : {}),
      ...(unholdFromRender
        ? {
          engine_held_at: null,
          engine_held_by: null,
          engine_hold_note: null,
          ...(nextStatus === 'approved' ? { engine_resolved_at: nowIso } : {}),
        }
        : {}),
      ...(autoHoldEngine
        ? {
          engine_held_at: nowIso,
          engine_held_by: auth.userId,
          engine_hold_note: issueTitle ?? (typeof r.engine_symptom === 'string' ? r.engine_symptom : '렌더 엔진 조판 확인 필요'),
        }
        : {}),
      updated_at: nowIso,
    }).eq('crop_id', x.cropId);

    if (!renderOk) {
      await upsertOpenFinding(auth, {
        academy_id: academyId,
        crop_id: x.cropId,
        stage: 'render',
        axis: fidelityOk ? 'output' : 'fidelity',
        error_type: fidelityOk ? 'render_item' : 'problem_transcription',
        severity: 'warning',
        source: 'ai',
        check_key: 'ai_v2_render_student_view',
        title: `${prevStatus === 'approved' ? '[승인 후 원본 대조] ' : ''}${issueTitle ?? 'V2 렌더 카드 읽기 문제'}`,
        detail: String(r.issue_detail ?? '학생 시점에서 문항·정답·해설 카드 중 읽히지 않거나 원본과 다른 부분이 있습니다.'),
        evidence: {
          problem_ok: problemOk,
          answer_ok: answerOk,
          solution_ok: solutionOk,
          fidelity_ok: fidelityOk,
          figure_position_ok: figurePositionOk,
          figure_size_ratio: sizeRatio,
          original_compared: originalCompared,
          solution_kind: x.solutionKind,
          issue_kind: issueKind,
          engine_symptom: issueKind === 'engine' ? r.engine_symptom ?? null : null,
        },
        status: prevStatus === 'held' || autoHoldEngine ? 'held' : 'open',
        ai_run_id: aiRunId,
      }).catch(() => null);
    } else {
      await resolveOpenFinding(auth, x.cropId, 'ai_v2_render_student_view').catch(() => null);
      // 원본과 직접 대조해 정상이면 2단계(문항 카드) 지적도 끝난 것으로 본다.
      if (originalCompared && figureAppliedOrNone) {
        await resolveOpenFinding(auth, x.cropId, 'ai_quality_v2_student_view').catch(() => null);
      }
    }
    results.push({
      crop_id: x.cropId,
      problem_ok: problemOk,
      answer_ok: answerOk,
      solution_ok: solutionOk,
      fidelity_ok: fidelityOk,
      figure_size_ratio: sizeRatio,
      issue_kind: issueKind,
    });
    processed += 1;
  }

  return jsonResponse({ ok: true, processed, results, cost_usd: costUsd });
}
