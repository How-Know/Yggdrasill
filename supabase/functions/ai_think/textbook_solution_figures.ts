import { type AuthContext, errorResponse, jsonResponse, safetyIdentifier } from '../_shared/ai/auth.ts';
import { getBudgetStatus } from '../_shared/ai/budget.ts';
import { estimateCostUsd, modelFor, thinkWallClockMs } from '../_shared/ai/config.ts';
import { createAiProvider } from '../_shared/ai/provider.ts';
import { type AiContentPart, finalText } from '../_shared/ai/types.ts';
import { recordAiRun } from '../_shared/ai/usage.ts';
import {
  imageDataUrl,
  parseProblems,
  solutionLinesToParagraphs,
  TEXTBOOK_REVIEW_PROMPT_VERSION,
} from './textbook_problem_review.ts';
import { uuidOrNull } from './validate.ts';

type Rec = Record<string, unknown>;

/** 해설 전사본의 그림 표시. 예전 전사본의 [그림: 설명] 도 같은 표시로 본다. */
export const SOLUTION_FIGURE_MARKER_RE = /\[그림(?:\s*:[^\]]*)?\]/g;
const MAX_ITEMS = 6;
// 한 문항 해설의 그림 수 상한. 경우마다 그래프를 그리는 해설(2022 9월 평가원 공통 22번: 10개)이 있어 12로 둔다.
const MAX_FIGURES = 12;
const MAX_PIECES = 8;
const MIN_BOX_1K = 20;

export function countSolutionFigureMarkers(text: unknown): number {
  return (String(text ?? '').match(SOLUTION_FIGURE_MARKER_RE) ?? []).length;
}

export type SolutionFigurePlacement = 'right' | 'below';

/**
 * 모델이 준 그림 상자([ymin, xmin, ymax, xmax], 이미지 기준 0..1000)를 정수로 묶고 너무 작거나 틀린 것은 버린다.
 * 원본에서 풀이 글 오른쪽에 나란히 있던 그림은 placement=right.
 */
export function normalizeFigures(
  raw: unknown,
  pieceCount = 1,
): Array<{ bbox: number[]; placement: SolutionFigurePlacement; piece: number }> {
  const out: Array<{ bbox: number[]; placement: SolutionFigurePlacement; piece: number }> = [];
  for (const f of Array.isArray(raw) ? raw : []) {
    const box = f && typeof f === 'object' ? (f as Rec).bbox_1k : null;
    if (!Array.isArray(box) || box.length !== 4) continue;
    const n = box.map((x) => Math.round(Math.max(0, Math.min(1000, Number(x)))));
    if (n.some((x) => !Number.isFinite(x))) continue;
    if (n[2] - n[0] < MIN_BOX_1K || n[3] - n[1] < MIN_BOX_1K) continue;
    // 조각을 따로 보낸 해설: 그림이 있는 조각 번호(1부터). 범위를 벗어난 번호의 그림은 자리를 알 수 없어 버린다.
    const piece = pieceCount > 1 ? Math.round(Number((f as Rec).piece)) : 1;
    if (!Number.isFinite(piece) || piece < 1 || piece > pieceCount) continue;
    out.push({ bbox: n, placement: (f as Rec).placement === 'right_of_text' ? 'right' : 'below', piece });
    if (out.length >= MAX_FIGURES) break;
  }
  return out;
}

export function normalizeFigureBoxes(raw: unknown): number[][] {
  return normalizeFigures(raw).map((f) => f.bbox);
}

const stripForCompare = (s: string) => s.replace(SOLUTION_FIGURE_MARKER_RE, '').replace(/\s+/g, '');

/**
 * 모델이 [그림] 표시를 끼운 전사본을 쓸 수 있는가. 표시를 뺀 글자가 원래 전사본과 같고 표시 수가 그림 수와 같을 때만
 * (설명형 [그림: …] 은 [그림] 으로 바꾼 채) 돌려준다. 아니면 null(원래 전사본 유지).
 */
export function markedSolutionText(original: string, proposed: unknown, figureCount: number): string | null {
  if (typeof proposed !== 'string' || figureCount <= 0) return null;
  const marked = proposed.replace(SOLUTION_FIGURE_MARKER_RE, '[그림]').trim();
  if (countSolutionFigureMarkers(marked) !== figureCount) return null;
  return stripForCompare(marked) === stripForCompare(original) ? marked : null;
}

/**
 * 줄마다 문단으로 나눈 전사본(solutionLinesToParagraphs 양식)에 모델이 고른 [그림] 자리만 옮긴다.
 * 모델이 돌려준 글의 줄바꿈은 쓰지 않고(줄을 합쳐 돌려주기도 한다) 원래 전사본의 줄 구분을 지킨다.
 * 표시는 따로 한 문단이 되고, 모델이 표시 뒤 같은 줄에 글을 붙였으면 그 글이 표시와 같은 줄에 온다(그림 옆·아래 설명).
 * marked 는 markedSolutionText 를 통과한 글(표시를 뺀 글자가 original 과 같음)이어야 한다.
 */
export function transferFigureMarkers(original: string, marked: string): string {
  const nonSpace = (s: string) => s.replace(/\s+/g, '').length;
  // 표시마다: 그 앞까지의 글자 수(공백·표시 제외), 표시 뒤 같은 줄에 글이 있는지
  const marks: Array<{ at: number; sameLine: boolean }> = [];
  let seen = 0;
  let last = 0;
  for (const m of marked.matchAll(SOLUTION_FIGURE_MARKER_RE)) {
    const index = m.index ?? 0;
    seen += nonSpace(marked.slice(last, index));
    last = index + m[0].length;
    const lineEnd = marked.indexOf('\n', last);
    const rest = marked.slice(last, lineEnd < 0 ? marked.length : lineEnd);
    marks.push({ at: seen, sameLine: !/^\s*\[그림/.test(rest) && nonSpace(rest.replace(SOLUTION_FIGURE_MARKER_RE, '')) > 0 });
  }
  const base = original.replace(SOLUTION_FIGURE_MARKER_RE, '\n\n');
  let out = '';
  let count = 0;
  let next = 0;
  const flush = (all = false) => {
    while (next < marks.length && (all || marks[next].at <= count)) {
      out += `\n\n[그림]${marks[next].sameLine ? ' ' : '\n\n'}`;
      next += 1;
    }
  };
  // 글자 수는 marked 쪽과 같은 단위(UTF-16)로 센다.
  for (let i = 0; i < base.length; i += 1) {
    if (/\S/.test(base[i])) {
      flush();
      count += 1;
    }
    out += base[i];
  }
  flush(true);
  return solutionLinesToParagraphs(out);
}

/** 줄을 맞춰 볼 때 쓰는 글자: 공백과, 표기 통일(정합성 점검)이 넣는 수식 구분자·곧은 글자 묶음을 뺀다. */
const lineKey = (s: string) => s.replace(/\\mathrm|[\s${}]/g, '');

/**
 * 반영 대기 해설 글(AI 가 저장된 해설에서 만든 것: 표기 통일 등)의 [그림] 자리를 저장된 해설 글에 맞춘다.
 * 그림을 다시 찾으면 저장된 글의 표시만 바뀌어, 카드에 쓰이는 반영 대기 글에는 예전 표시가 남는다.
 * 줄 단위로 맞춘다: 저장된 글에서 표시 바로 뒤에 오는 줄을 반영 대기 글에서 찾아 그 앞에 표시를 놓는다.
 * 그 줄을 찾지 못하는 표시가 하나라도 있으면(줄 가운데에 놓인 표시, 글이 달라진 줄) 아무것도 바꾸지 않는다.
 * 반환: 바뀐 반영 대기 글. 바꿀 것이 없거나 맞출 수 없으면 null.
 */
export function syncStagedFigureMarkers(base: string, staged: string): string | null {
  // 저장된 글: 줄(표시 제외)과 표시마다 { 뒤에 오는 줄 번호, 표시 뒤 같은 줄에 글이 있는지 }
  const baseLines: string[] = [];
  const marks: Array<{ before: number; sameLine: boolean }> = [];
  for (const raw of base.replace(/\r\n?/g, '\n').split('\n')) {
    let last = 0;
    const pieces: string[] = [];
    for (const m of raw.matchAll(SOLUTION_FIGURE_MARKER_RE)) {
      pieces.push(raw.slice(last, m.index ?? 0));
      last = (m.index ?? 0) + m[0].length;
    }
    pieces.push(raw.slice(last));
    pieces.forEach((piece, k) => {
      const text = piece.trim();
      if (k > 0) marks.push({ before: baseLines.length, sameLine: text !== '' });
      if (text) baseLines.push(text);
    });
  }
  // 반영 대기 글: 표시를 뺀 글과 줄마다 시작 위치
  const plain = staged.replace(/\r\n?/g, '\n').replace(SOLUTION_FIGURE_MARKER_RE, '\n\n');
  const stagedLines: Array<{ key: string; at: number }> = [];
  for (const m of plain.matchAll(/[^\n]+/g)) {
    const lead = m[0].length - m[0].trimStart().length;
    if (m[0].trim()) stagedLines.push({ key: lineKey(m[0]), at: (m.index ?? 0) + lead });
  }
  // 두 글의 줄을 순서를 지켜 짝짓는다(가장 긴 공통 부분열).
  const a = baseLines.map(lineKey);
  const b = stagedLines.map((l) => l.key);
  const lcs: number[][] = Array.from({ length: a.length + 1 }, () => new Array<number>(b.length + 1).fill(0));
  for (let i = a.length - 1; i >= 0; i -= 1) {
    for (let j = b.length - 1; j >= 0; j -= 1) {
      lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
    }
  }
  const match = new Map<number, number>();
  for (let i = 0, j = 0; i < a.length && j < b.length;) {
    if (a[i] === b[j]) {
      match.set(i, j);
      i += 1;
      j += 1;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) i += 1;
    else j += 1;
  }
  // 표시를 놓을 자리(반영 대기 글의 글자 위치). 뒤에서부터 끼워 앞 위치가 밀리지 않게 한다.
  const inserts: Array<{ at: number; sameLine: boolean }> = [];
  for (const mark of marks) {
    if (mark.before >= baseLines.length) inserts.push({ at: plain.length, sameLine: false });
    else {
      const j = match.get(mark.before);
      if (j === undefined) return null;
      inserts.push({ at: stagedLines[j].at, sameLine: mark.sameLine });
    }
  }
  let out = plain;
  for (let k = inserts.length - 1; k >= 0; k -= 1) {
    const { at, sameLine } = inserts[k];
    out = `${out.slice(0, at)}\n\n[그림]${sameLine ? ' ' : '\n\n'}${out.slice(at)}`;
  }
  const paragraphs = solutionLinesToParagraphs(staged) === staged;
  out = paragraphs ? solutionLinesToParagraphs(out) : out.replace(/\n{3,}/g, '\n\n').trim();
  return out === staged ? null : out;
}

const SOLUTION_FIGURES_SCHEMA: Rec = {
  type: 'object',
  additionalProperties: false,
  required: ['problems'],
  properties: {
    problems: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['crop_id', 'figures', 'solution_with_markers'],
        properties: {
          crop_id: { type: 'string' },
          figures: {
            type: 'array',
            items: {
              type: 'object',
              additionalProperties: false,
              required: ['bbox_1k', 'kind', 'placement'],
              properties: {
                bbox_1k: { type: 'array', items: { type: 'integer' } },
                kind: { type: 'string', enum: ['graph', 'diagram', 'number_line', 'other'] },
                placement: { type: 'string', enum: ['right_of_text', 'below_text'] },
              },
            },
          },
          solution_with_markers: { type: 'string' },
        },
      },
    },
  },
};

const SOLUTION_FIGURES_INSTRUCTIONS = `당신은 Yggdrasill 교재 검수 엔진의 [원본 해설 그림 찾기] 담당입니다.
문항마다 교재 해설지에서 그 문항의 해설 영역을 잘라낸 이미지와, 그 해설을 글자로 옮긴 전사본(solution_transcribed)이 주어집니다.

[할 일]
1. figures: 해설 본문 안에 인쇄된 그림 중 글자로 옮길 수 없는 것(좌표평면 그래프, 도형, 수직선, 벤다이어그램, 수형도 등)을 모두 찾아
   읽는 순서(위→아래, 같은 높이면 왼쪽→오른쪽)로 bbox_1k=[ymin, xmin, ymax, xmax] 를 주세요. 좌표는 주어진 이미지 기준 0~1000 정수입니다.
   - 그림에 붙은 축 이름·눈금·점 이름·화살표 글자까지 상자에 넣고, 그림 밖 해설 문장은 넣지 마세요.
   - 그림 바로 아래(또는 위)에 그 그림의 번호·이름만 적은 캡션 줄("[그림 1]", "<그림 2>", "(그림 3)" 등)이 붙어 있으면
     캡션까지 상자에 넣으세요. 캡션은 그림의 일부입니다. "[그림 1]과 같이 …" 처럼 그림을 가리키는 풀이 문장은 캡션이 아닙니다.
   - 글자로 된 표, 수식, 문항 번호·정답 줄, 요청 문항이 아닌 다른 문항의 그림은 넣지 마세요.
   - 그림이 없으면 figures=[] 입니다.
   - placement: 그림이 바로 앞 풀이 글줄들과 같은 높이에서 그 오른쪽에 나란히 인쇄돼 있으면 "right_of_text",
     풀이 글 아래(또는 위)에 따로 한 줄을 차지하면 "below_text".
   - 이미지가 회색 가로선으로 위아래 두 조각으로 나뉘어 있으면 아래 조각은 해설지 다음 단(또는 다음 쪽) 맨 위에서 이어진 풀이입니다. 상자가 회색 선을 넘지 않게 잡으세요.
2. solution_with_markers: 전사본을 한 글자도 바꾸지 말고 그대로 두되, figures 의 각 그림이 해설에서 놓인 자리에 [그림] 을 순서대로 끼워 넣으세요.
   [그림] 개수는 figures 개수와 같아야 합니다. 전사본에 이미 [그림] 이나 [그림: 설명] 표시가 있으면 그 자리를 [그림] 하나로 쓰세요.
   전사본에 "[그림 2]" 처럼 번호가 붙은 캡션 줄이 따로 적혀 있으면 그것은 그림 자리 표시가 아니라 글입니다. 지우거나 바꾸지 말고 그대로 두세요.
   그림이 없으면 전사본을 그대로 돌려주세요.`;

/** 해설 조각을 한 장씩 따로 보낼 때의 스키마: 그림마다 조각 번호(piece)를 받는다. */
export function solutionFiguresSchema(withPieces: boolean): Rec {
  if (!withPieces) return SOLUTION_FIGURES_SCHEMA;
  const schema = structuredClone(SOLUTION_FIGURES_SCHEMA) as Rec;
  // deno-lint-ignore no-explicit-any
  const figure = (schema as any).properties.problems.items.properties.figures.items;
  figure.required = ['piece', ...figure.required];
  figure.properties = { piece: { type: 'integer' }, ...figure.properties };
  return schema;
}

/** 해설 조각을 한 장씩 따로 보낼 때의 지시문: 이어 붙인 한 장 대신 조각 번호와 그 조각 안의 좌표를 받는다. */
export function solutionFiguresInstructions(withPieces: boolean): string {
  if (!withPieces) return SOLUTION_FIGURES_INSTRUCTIONS;
  return SOLUTION_FIGURES_INSTRUCTIONS.replace(
    /   - 이미지가 회색 가로선으로[^\n]*\n/,
    `   - 한 문항의 해설 이미지가 여러 장이면 해설지의 단(또는 쪽)이 바뀌며 이어진 풀이를 순서대로 한 장씩 자른 것입니다.
     그림마다 piece 에 그 그림이 있는 이미지의 번호(1부터)를 주고, bbox_1k 는 그 이미지 한 장을 기준으로 잡으세요.
     이미지가 한 장이면 piece=1 입니다. 읽는 순서는 이미지 번호 순서입니다.
`,
  );
}

const TIGHTEN_SCHEMA: Rec = {
  type: 'object',
  additionalProperties: false,
  required: ['figures'],
  properties: {
    figures: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['index', 'found', 'bbox_1k'],
        properties: {
          index: { type: 'integer' },
          found: { type: 'boolean' },
          bbox_1k: { type: 'array', items: { type: 'integer' } },
        },
      },
    },
  },
};

const TIGHTEN_INSTRUCTIONS = `당신은 Yggdrasill 교재 검수 엔진의 [해설 그림 상자 다듬기] 담당입니다.
이미지마다 해설지에서 그림 하나를 여유를 두고 잘라낸 것입니다. 이미지 가운데쯤에 대상 그림(그래프·도형·수직선·수형도 등)이 하나 있고,
둘레에 그림이 아닌 풀이 글줄·수식 줄이나 옆에 있는 다른 그림의 일부가 같이 들어 있을 수 있습니다.

이미지마다 index(주어진 번호)와 대상 그림 하나만 꼭 맞게 감싸는 bbox_1k=[ymin, xmin, ymax, xmax] 를 주세요. 좌표는 그 이미지 기준 0~1000 정수입니다.
- 그림에 붙은 축 이름·눈금·점 이름·곡선 이름·화살표 글자는 상자에 넣습니다.
- 그림 바로 아래(또는 위)에 그 그림의 번호·이름만 적은 캡션 줄("[그림 1]", "<그림 2>", "(그림 3)" 등)이 붙어 있으면 캡션까지 상자에 넣습니다. 캡션은 그림의 일부입니다.
- 캡션이 아닌 그림 위·아래·옆의 풀이 문장과 수식 줄은 한 줄도 넣지 않습니다("[그림 1]과 같이 …" 처럼 그림을 가리키는 문장도 풀이 문장입니다). 글줄과 그림(캡션이 있으면 캡션) 사이의 흰 띠에서 상자를 끊으세요.
- 옆에 나란히 있는 다른 그림은 넣지 않습니다. 대상은 이미지 가운데에 가장 가까운 그림 하나입니다.
- 그림이 이미지 가장자리에서 잘려 있으면 그 쪽 좌표는 가장자리(0 또는 1000)로 주세요.
- 이미지에 그림이 없으면 found=false, bbox_1k=[] 입니다.`;

/** 다듬기 응답에서 이미지 번호(1부터)별 상자. 없거나 틀린 것은 null(원래 상자를 쓴다). */
export function normalizeTightenBoxes(raw: unknown, count: number): Array<number[] | null> {
  const out: Array<number[] | null> = Array.from({ length: count }, () => null);
  const list = raw && typeof raw === 'object' ? (raw as Rec).figures : null;
  for (const f of Array.isArray(list) ? list : []) {
    const r = (f ?? {}) as Rec;
    const i = Math.round(Number(r.index)) - 1;
    if (!Number.isFinite(i) || i < 0 || i >= count || r.found !== true) continue;
    const box = normalizeFigures([{ bbox_1k: r.bbox_1k }])[0]?.bbox;
    if (box) out[i] = box;
  }
  return out;
}

/**
 * tighten: 처음 찾은 그림 상자를 여유를 두고 다시 자른 이미지들에서 그림만 꼭 맞게 감싸는 상자를 받는다.
 * 저장하는 것은 없다(AI 사용 기록만 남긴다).
 */
async function handleTighten(req: Request, auth: AuthContext, body: Rec): Promise<Response> {
  const images = (Array.isArray(body.figure_images_base64) ? body.figure_images_base64 : [])
    .slice(0, MAX_FIGURES)
    .map((b) => imageDataUrl(b, body.figure_image_mime));
  if (images.length === 0 || images.some((u) => !u)) return jsonResponse({ ok: true, boxes: [] });
  const wallClockMs = thinkWallClockMs();
  const provider = createAiProvider({ timeoutMs: wallClockMs + 5000 });
  if (!provider) return errorResponse(503, 'ai_not_configured', 'OPENAI_API_KEY 비밀값이 설정되지 않았습니다.');
  const budget = await getBudgetStatus(auth.admin).catch(() => null);
  if (budget?.exceeded && budget.mode === 'block') {
    return errorResponse(429, 'budget_exceeded', '이번 달 AI 한도를 넘었습니다.');
  }
  const parts: AiContentPart[] = [];
  images.forEach((url, k) => {
    parts.push({ type: 'text', text: `[index=${k + 1}]` });
    parts.push({ type: 'image', url: url as string, detail: 'high' });
  });
  const startedAt = Date.now();
  const model = modelFor('primary');
  const signal = AbortSignal.any([req.signal, AbortSignal.timeout(wallClockMs)]);
  const res = await provider.complete(
    {
      model,
      instructions: TIGHTEN_INSTRUCTIONS,
      input: [{ kind: 'message', role: 'user', parts }],
      jsonSchema: { name: 'textbook_solution_figure_tighten', schema: TIGHTEN_SCHEMA },
      reasoningEffort: 'low',
      maxOutputTokens: 4000,
      safetyId: await safetyIdentifier(auth.userId),
    },
    signal,
  );
  let parsed: unknown = null;
  try {
    parsed = JSON.parse(finalText(res));
  } catch (_) {
    parsed = null;
  }
  await recordAiRun(auth.admin, {
    feature: 'textbook_solution_figures',
    provider: provider.name,
    model,
    promptVersion: TEXTBOOK_REVIEW_PROMPT_VERSION,
    status: 'ok',
    error: null,
    usage: res.usage,
    webSearchCalls: 0,
    toolCalls: 0,
    costUsd: estimateCostUsd(model, res.usage, 0),
    latencyMs: Date.now() - startedAt,
    conversationId: null,
    createdBy: auth.userId,
    features: { count: images.length, tighten: true },
  });
  return jsonResponse({ ok: true, boxes: normalizeTightenBoxes(parsed, images.length) });
}

export async function handleTextbookSolutionFigures(
  req: Request,
  auth: AuthContext,
  body: Rec,
): Promise<Response> {
  const academyId = uuidOrNull(body.academy_id);
  if (!academyId) return errorResponse(400, 'invalid_scope', '학원 정보가 필요합니다.');
  if (body.tighten === true) return await handleTighten(req, auth, body);
  const items = (Array.isArray(body.items) ? body.items : [])
    .map((x) => (x ?? {}) as Rec)
    .map((r) => {
      // solution_images_base64: 이어진 해설 조각을 한 장씩(순서대로). 없으면 한 장(solution_image_base64).
      const pieces = (Array.isArray(r.solution_images_base64) ? r.solution_images_base64 : [])
        .slice(0, MAX_PIECES)
        .map((b) => imageDataUrl(b, r.solution_image_mime));
      const single = imageDataUrl(r.solution_image_base64, r.solution_image_mime);
      const imageUrls = pieces.length > 0 && pieces.every((u) => !!u) ? (pieces as string[]) : single ? [single] : [];
      return { cropId: uuidOrNull(r.crop_id), imageUrls };
    })
    .filter((x): x is { cropId: string; imageUrls: string[] } => !!x.cropId && x.imageUrls.length > 0)
    .slice(0, MAX_ITEMS);
  if (items.length === 0) return jsonResponse({ ok: true, processed: 0, results: [] });
  const withPieces = items.some((x) => x.imageUrls.length > 1);
  // dry_run: 그림 자리만 돌려주고 전사본의 [그림] 자리는 저장하지 않는다(시험용).
  const dryRun = body.dry_run === true;

  const wallClockMs = thinkWallClockMs();
  const provider = createAiProvider({ timeoutMs: wallClockMs + 5000 });
  if (!provider) return errorResponse(503, 'ai_not_configured', 'OPENAI_API_KEY 비밀값이 설정되지 않았습니다.');
  const budget = await getBudgetStatus(auth.admin).catch(() => null);
  if (budget?.exceeded && budget.mode === 'block') {
    return errorResponse(429, 'budget_exceeded', '이번 달 AI 한도를 넘었습니다.');
  }

  const { data: analyses } = await auth.admin
    .from('textbook_problem_analyses')
    .select('crop_id,academy_id,solution_transcribed,solution_source,staged_changes,textbook_problem_crops(problem_number)')
    .in('crop_id', items.map((x) => x.cropId));
  const analysisByCrop = new Map<string, Rec>();
  for (const a of (analyses ?? []) as Rec[]) {
    if (String(a.academy_id) === academyId) analysisByCrop.set(String(a.crop_id), a);
  }
  const targets = items.filter((x) => analysisByCrop.has(x.cropId));
  if (targets.length === 0) return jsonResponse({ ok: true, processed: 0, results: [] });

  const parts: AiContentPart[] = [{
    type: 'text',
    text: JSON.stringify({
      problems: targets.map((x) => {
        const a = analysisByCrop.get(x.cropId)!;
        return {
          crop_id: x.cropId,
          problem_number: ((a.textbook_problem_crops ?? {}) as Rec).problem_number ?? '',
          solution_transcribed: String(a.solution_transcribed ?? ''),
        };
      }),
    }),
  }];
  for (const x of targets) {
    x.imageUrls.forEach((url, k) => {
      const label = x.imageUrls.length > 1 ? `해설 영역 이미지 ${k + 1}/${x.imageUrls.length}` : '해설 영역 이미지';
      parts.push({ type: 'text', text: `[crop_id=${x.cropId} · ${label}]` });
      parts.push({ type: 'image', url, detail: 'high' });
    });
  }

  const startedAt = Date.now();
  const model = modelFor('primary');
  const signal = AbortSignal.any([req.signal, AbortSignal.timeout(wallClockMs)]);
  const res = await provider.complete(
    {
      model,
      instructions: solutionFiguresInstructions(withPieces),
      input: [{ kind: 'message', role: 'user', parts }],
      jsonSchema: { name: 'textbook_solution_figures', schema: solutionFiguresSchema(withPieces) },
      reasoningEffort: 'low',
      maxOutputTokens: 12000,
      safetyId: await safetyIdentifier(auth.userId),
    },
    signal,
  );
  const byCrop = parseProblems(finalText(res));
  await recordAiRun(auth.admin, {
    feature: 'textbook_solution_figures',
    provider: provider.name,
    model,
    promptVersion: TEXTBOOK_REVIEW_PROMPT_VERSION,
    status: 'ok',
    error: null,
    usage: res.usage,
    webSearchCalls: 0,
    toolCalls: 0,
    costUsd: estimateCostUsd(model, res.usage, 0),
    latencyMs: Date.now() - startedAt,
    conversationId: null,
    createdBy: auth.userId,
    features: { count: targets.length, ...(withPieces ? { pieces: true } : {}), ...(dryRun ? { dry_run: true } : {}) },
  });

  const results: Rec[] = [];
  for (const x of targets) {
    const r = byCrop.get(x.cropId);
    if (!r) continue;
    const a = analysisByCrop.get(x.cropId)!;
    const original = String(a.solution_transcribed ?? '');
    const found = normalizeFigures(r.figures, withPieces ? x.imageUrls.length : 1);
    const figures = found.map((f) => f.bbox);
    let text = original;
    let stagedSync: string | null = null;
    // 운영자가 고친 해설은 글자를 바꾸지 않는다(그림은 렌더할 때 표시가 모자라면 끝에 붙인다).
    if (a.solution_source !== 'manual' && !dryRun) {
      const accepted = markedSolutionText(original, r.solution_with_markers, figures.length);
      // 줄마다 문단으로 나눈 전사본은 모델이 돌려준 줄바꿈 대신 원래 줄 구분을 지킨다(그 전 양식의 전사본은 하던 대로).
      const marked = accepted !== null && solutionLinesToParagraphs(original) === original
        ? transferFigureMarkers(original, accepted)
        : accepted;
      if (marked !== null && marked !== original) {
        const { error } = await auth.admin
          .from('textbook_problem_analyses')
          .update({ solution_transcribed: marked, updated_at: new Date().toISOString() })
          .eq('crop_id', x.cropId);
        if (!error) text = marked;
      }
      // 카드는 반영 대기 해설 글을 쓴다. AI 가 만든 반영 대기 글이면 그림 자리를 저장된 글에 맞춘다(사람이 고친 글은 그대로).
      const staged = (a.staged_changes ?? {}) as Rec;
      const stagedText = typeof staged.solution_transcribed === 'string' ? staged.solution_transcribed : '';
      if (stagedText && ((staged.sources ?? {}) as Rec).solution_transcribed !== 'owner') {
        const synced = syncStagedFigureMarkers(text, stagedText);
        if (synced !== null) {
          const { error } = await auth.userClient.rpc('textbook_review_stage_changes', {
            p_crop_id: x.cropId,
            p_patch: { solution_transcribed: synced },
            p_source: 'ai',
            p_note: '해설 그림 자리를 저장된 해설 글에 맞춤',
          });
          stagedSync = error ? `failed: ${error.message}` : 'synced';
        }
      }
    }
    results.push({
      crop_id: x.cropId,
      figures,
      placements: found.map((f) => f.placement),
      // 조각을 따로 보낸 경우에만: 그림마다 그 그림이 있는 조각 번호(1부터). figures 의 좌표는 그 조각 기준이다.
      ...(withPieces ? { pieces: found.map((f) => f.piece) } : {}),
      solution_transcribed: text,
      // 반영 대기 해설 글의 그림 자리를 맞췄으면 'synced', 저장하지 못했으면 'failed: …'
      ...(stagedSync ? { staged_sync: stagedSync } : {}),
    });
  }
  return jsonResponse({ ok: true, processed: results.length, results });
}
