// 개념책 한 쪽 전사(시범). Edge 함수(OpenAI)와 로컬 시험 실행기(Gemini)가 같은 지시문·형식을 쓴다.
// Node(타입 제거 실행)에서도 불러오므로 다른 파일을 import 하지 않고, 타입 표기 외의 TS 문법을 쓰지 않는다.

export const CONCEPT_PAGE_PROMPT_VERSION = 'concept_page_read.v1';

export const CONCEPT_BLOCK_KINDS = [
  'heading',
  'concept_box',
  'explanation',
  'example',
  'note',
  'figure',
  'table',
  'page_furniture',
  'other',
] as const;
export type ConceptBlockKind = (typeof CONCEPT_BLOCK_KINDS)[number];

export const CONCEPT_PAGE_KINDS = ['concept', 'mixed', 'problems_only', 'other'] as const;
export type ConceptPageKind = (typeof CONCEPT_PAGE_KINDS)[number];

export const MAX_MASKS = 40;
export const MAX_IMAGE_BASE64_CHARS = 8_000_000;

export interface ConceptPageMask {
  label: string;
  bbox_1k: number[];
  problem_number?: string;
}

export interface ConceptPageInput {
  bookName: string;
  gradeLabel: string;
  unitPath: string[];
  rawPage: number;
  displayPage?: number | null;
  masks: ConceptPageMask[];
}

export interface ConceptBlock {
  kind: ConceptBlockKind;
  title: string;
  text: string;
  bbox_1k: number[] | null;
  figure_description: string;
  continues_from_prev_page: boolean;
  continues_to_next_page: boolean;
  uncertain: boolean;
}

export interface ConceptPageResult {
  page_kind: ConceptPageKind;
  blocks: ConceptBlock[];
  notes: string;
}

// OpenAI strict json_schema 와 Gemini responseJsonSchema 양쪽에 맞도록 null 형식과 개수 제한을 쓰지 않는다.
export const CONCEPT_PAGE_SCHEMA: Record<string, unknown> = {
  type: 'object',
  additionalProperties: false,
  required: ['page_kind', 'blocks', 'notes'],
  properties: {
    page_kind: { type: 'string', enum: [...CONCEPT_PAGE_KINDS] },
    blocks: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: [
          'kind',
          'title',
          'text',
          'bbox_1k',
          'figure_description',
          'continues_from_prev_page',
          'continues_to_next_page',
          'uncertain',
        ],
        properties: {
          kind: { type: 'string', enum: [...CONCEPT_BLOCK_KINDS] },
          title: { type: 'string' },
          text: { type: 'string' },
          bbox_1k: { type: 'array', items: { type: 'integer' } },
          figure_description: { type: 'string' },
          continues_from_prev_page: { type: 'boolean' },
          continues_to_next_page: { type: 'boolean' },
          uncertain: { type: 'boolean' },
        },
      },
    },
    notes: { type: 'string' },
  },
};

const INSTRUCTIONS = `당신은 중학교 수학 교재의 한 쪽 이미지를 글자 그대로 옮겨 적는 전사 담당입니다.

[회색 상자]
- 이미지의 회색 상자(M1, M2 …)는 이미 따로 저장한 문항 영역입니다. 상자 안은 옮기지 마세요.
- 상자 가장자리에 걸쳐 잘린 글자도 문항의 일부로 보고 건너뜁니다.
- 회색 상자 밖의 글자는 하나도 빠뜨리지 말고 옮깁니다. 개념인지 아닌지는 판단하지 마세요. 고르는 일은 다음 단계에서 합니다.

[옮기는 방법]
- 보이는 순서대로 옮깁니다. 위에서 아래로, 단이 나뉘어 있으면 왼쪽 단을 먼저 옮깁니다.
- 요약하거나 말을 바꾸거나 고치지 마세요. 교재 내용이 틀려 보여도 보이는 그대로 적습니다.
- 수식은 LaTeX로 적습니다. 문장 속 수식은 $...$, 따로 떨어진 줄의 수식은 $$...$$ 입니다. 곱셈 기호는 \\times, 거듭제곱은 2^{3} 처럼 적습니다.
- 빈칸·네모 칸은 □ 로, 원문자·번호·글머리 기호(①, (1), •)는 그대로 둡니다.
- 문단 사이는 빈 줄로 나눕니다. 굵게 강조된 말은 **굵게** 로 표시합니다.
- 표는 마크다운 표로 적습니다.
- 그림·도식은 kind를 figure로 두고, 그림 안의 글자는 text에, 그림의 생김새는 figure_description에 한두 문장으로 적습니다. 그림을 해석해 새 내용을 보태지 마세요.
- 읽을 수 없는 글자는 [판독 불가] 로 적고, 짐작이 섞인 블록은 uncertain을 true로 둡니다.

[블록 나누기]
- 제목 하나, 개념 정리 상자 하나, 설명 문단 묶음 하나, 예 하나, 그림 하나, 표 하나를 각각 한 블록으로 둡니다.
- kind: heading(제목·소제목), concept_box(개념 정리 상자), explanation(설명 문단), example(본문 속 예와 그 풀이), note(참고·주의·덧붙임), figure, table, page_furniture(쪽 번호·머리말·꼬리말·단원 띠·장식 문구), other.
- title에는 블록에 붙은 이름표(예: "개념 1", "참고")를 적고, 없으면 빈 문자열입니다.
- bbox_1k는 블록이 차지하는 영역 [ymin, xmin, ymax, xmax] 이며 이미지 크기를 0~1000으로 둔 정수입니다.
- 블록이 앞쪽에서 이어지거나 다음 쪽으로 이어지면 continues_from_prev_page / continues_to_next_page를 true로 둡니다.

[쪽 종류] page_kind: concept(개념 설명이 대부분), mixed(개념과 문항이 섞임), problems_only(회색 상자 밖에 쪽 장식만 있음), other.
notes에는 전사하며 알아 둘 점을 짧게 적고, 없으면 빈 문자열로 둡니다.
출력은 정해진 JSON 형식만 씁니다.`;

export function buildConceptPagePrompt(input: ConceptPageInput): {
  instructions: string;
  userText: string;
  maxOutputTokens: number;
} {
  const page = input.displayPage && input.displayPage !== input.rawPage
    ? `PDF ${input.rawPage}쪽 (교재 표시 ${input.displayPage}쪽)`
    : `PDF ${input.rawPage}쪽`;
  const masks = input.masks.length === 0
    ? '이 쪽에는 회색 상자가 없습니다.'
    : input.masks
      .map((m) => `- ${m.label}${m.problem_number ? ` (문항 ${m.problem_number})` : ''}: [${m.bbox_1k.join(', ')}]`)
      .join('\n');
  const userText = [
    `교재: ${input.bookName} ${input.gradeLabel}`,
    `단원: ${input.unitPath.filter((s) => s.trim()).join(' > ') || '(알 수 없음)'}`,
    `쪽: ${page}`,
    `회색 상자(문항 영역, [ymin, xmin, ymax, xmax]):`,
    masks,
    '',
    '회색 상자 밖의 내용을 모두 옮겨 적어 주세요.',
  ].join('\n');
  return { instructions: INSTRUCTIONS, userText, maxOutputTokens: 16000 };
}

function clampInt(v: unknown, lo: number, hi: number): number | null {
  const n = typeof v === 'number' ? v : Number(v);
  if (!Number.isFinite(n)) return null;
  return Math.max(lo, Math.min(hi, Math.round(n)));
}

export function normalizeBbox(v: unknown): number[] | null {
  if (!Array.isArray(v) || v.length !== 4) return null;
  const nums = v.map((x) => clampInt(x, 0, 1000));
  if (nums.some((x) => x === null)) return null;
  const [y0, x0, y1, x1] = nums as number[];
  if (y1 <= y0 || x1 <= x0) return null;
  return [y0, x0, y1, x1];
}

function str(v: unknown): string {
  return typeof v === 'string' ? v : '';
}

function stripFence(text: string): string {
  const t = text.trim();
  const m = t.match(/^```(?:json)?\s*([\s\S]*?)\s*```$/);
  return m ? m[1] : t;
}

/** 모델 출력(JSON 문자열)을 정해진 형식으로 맞춘다. JSON이 아니면 null. */
export function parseConceptPage(text: string): ConceptPageResult | null {
  let raw: unknown;
  try {
    raw = JSON.parse(stripFence(text));
  } catch {
    return null;
  }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const o = raw as Record<string, unknown>;
  const kinds = CONCEPT_BLOCK_KINDS as readonly string[];
  const pageKinds = CONCEPT_PAGE_KINDS as readonly string[];
  const blocks: ConceptBlock[] = [];
  for (const b of Array.isArray(o.blocks) ? o.blocks : []) {
    if (!b || typeof b !== 'object') continue;
    const r = b as Record<string, unknown>;
    const kind = kinds.includes(str(r.kind)) ? (str(r.kind) as ConceptBlockKind) : 'other';
    const block: ConceptBlock = {
      kind,
      title: str(r.title).trim(),
      text: str(r.text),
      bbox_1k: normalizeBbox(r.bbox_1k),
      figure_description: str(r.figure_description).trim(),
      continues_from_prev_page: r.continues_from_prev_page === true,
      continues_to_next_page: r.continues_to_next_page === true,
      uncertain: r.uncertain === true,
    };
    if (!block.text.trim() && !block.title && !block.figure_description) continue;
    blocks.push(block);
  }
  return {
    page_kind: pageKinds.includes(str(o.page_kind)) ? (str(o.page_kind) as ConceptPageKind) : 'other',
    blocks,
    notes: str(o.notes).trim(),
  };
}

export type ConceptPageInputError =
  | 'image_required'
  | 'image_too_large'
  | 'unsupported_mime'
  | 'invalid_page'
  | 'invalid_masks';

/** Edge 함수 요청 본문 검사. 이미지는 base64(PNG/JPEG)만 받는다. */
export function readConceptPageBody(body: Record<string, unknown>):
  | { ok: true; input: ConceptPageInput; imageBase64: string; mimeType: string }
  | { ok: false; error: ConceptPageInputError } {
  const imageBase64 = typeof body.image_base64 === 'string' ? body.image_base64.trim() : '';
  if (!imageBase64) return { ok: false, error: 'image_required' };
  if (imageBase64.length > MAX_IMAGE_BASE64_CHARS) return { ok: false, error: 'image_too_large' };
  const mimeType = str(body.mime_type).trim() || 'image/png';
  if (mimeType !== 'image/png' && mimeType !== 'image/jpeg') return { ok: false, error: 'unsupported_mime' };
  const rawPage = clampInt(body.raw_page, 1, 5000);
  if (rawPage === null || Number(body.raw_page) !== rawPage) return { ok: false, error: 'invalid_page' };
  const displayPage = body.display_page === undefined || body.display_page === null
    ? null
    : clampInt(body.display_page, 0, 5000);
  const rawMasks = Array.isArray(body.masks) ? body.masks : [];
  if (rawMasks.length > MAX_MASKS) return { ok: false, error: 'invalid_masks' };
  const masks: ConceptPageMask[] = [];
  for (const m of rawMasks) {
    if (!m || typeof m !== 'object') return { ok: false, error: 'invalid_masks' };
    const r = m as Record<string, unknown>;
    const bbox = normalizeBbox(r.bbox_1k);
    const label = str(r.label).trim().slice(0, 12);
    if (!bbox || !label) return { ok: false, error: 'invalid_masks' };
    const num = str(r.problem_number).trim().slice(0, 20);
    masks.push({ label, bbox_1k: bbox, ...(num ? { problem_number: num } : {}) });
  }
  const unitPath = (Array.isArray(body.unit_path) ? body.unit_path : [])
    .map((s) => str(s).trim().slice(0, 80))
    .filter(Boolean)
    .slice(0, 6);
  return {
    ok: true,
    imageBase64,
    mimeType,
    input: {
      bookName: str(body.book_name).trim().slice(0, 80),
      gradeLabel: str(body.grade_label).trim().slice(0, 20),
      unitPath,
      rawPage,
      displayPage,
      masks,
    },
  };
}
