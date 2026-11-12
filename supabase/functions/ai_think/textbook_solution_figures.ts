import { type AuthContext, errorResponse, jsonResponse, safetyIdentifier } from '../_shared/ai/auth.ts';
import { getBudgetStatus } from '../_shared/ai/budget.ts';
import { estimateCostUsd, modelFor, thinkWallClockMs } from '../_shared/ai/config.ts';
import { createAiProvider } from '../_shared/ai/provider.ts';
import { type AiContentPart, finalText } from '../_shared/ai/types.ts';
import { recordAiRun } from '../_shared/ai/usage.ts';
import { imageDataUrl, parseProblems, TEXTBOOK_REVIEW_PROMPT_VERSION } from './textbook_problem_review.ts';
import { uuidOrNull } from './validate.ts';

type Rec = Record<string, unknown>;

/** 해설 전사본의 그림 표시. 예전 전사본의 [그림: 설명] 도 같은 표시로 본다. */
export const SOLUTION_FIGURE_MARKER_RE = /\[그림(?:\s*:[^\]]*)?\]/g;
const MAX_ITEMS = 6;
const MAX_FIGURES = 8;
const MIN_BOX_1K = 20;

export function countSolutionFigureMarkers(text: unknown): number {
  return (String(text ?? '').match(SOLUTION_FIGURE_MARKER_RE) ?? []).length;
}

export type SolutionFigurePlacement = 'right' | 'below';

/**
 * 모델이 준 그림 상자([ymin, xmin, ymax, xmax], 이미지 기준 0..1000)를 정수로 묶고 너무 작거나 틀린 것은 버린다.
 * 원본에서 풀이 글 오른쪽에 나란히 있던 그림은 placement=right.
 */
export function normalizeFigures(raw: unknown): Array<{ bbox: number[]; placement: SolutionFigurePlacement }> {
  const out: Array<{ bbox: number[]; placement: SolutionFigurePlacement }> = [];
  for (const f of Array.isArray(raw) ? raw : []) {
    const box = f && typeof f === 'object' ? (f as Rec).bbox_1k : null;
    if (!Array.isArray(box) || box.length !== 4) continue;
    const n = box.map((x) => Math.round(Math.max(0, Math.min(1000, Number(x)))));
    if (n.some((x) => !Number.isFinite(x))) continue;
    if (n[2] - n[0] < MIN_BOX_1K || n[3] - n[1] < MIN_BOX_1K) continue;
    out.push({ bbox: n, placement: (f as Rec).placement === 'right_of_text' ? 'right' : 'below' });
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
   - 글자로 된 표, 수식, 문항 번호·정답 줄, 요청 문항이 아닌 다른 문항의 그림은 넣지 마세요.
   - 그림이 없으면 figures=[] 입니다.
   - placement: 그림이 바로 앞 풀이 글줄들과 같은 높이에서 그 오른쪽에 나란히 인쇄돼 있으면 "right_of_text",
     풀이 글 아래(또는 위)에 따로 한 줄을 차지하면 "below_text".
   - 이미지가 회색 가로선으로 위아래 두 조각으로 나뉘어 있으면 아래 조각은 해설지 다음 단(또는 다음 쪽) 맨 위에서 이어진 풀이입니다. 상자가 회색 선을 넘지 않게 잡으세요.
2. solution_with_markers: 전사본을 한 글자도 바꾸지 말고 그대로 두되, figures 의 각 그림이 해설에서 놓인 자리에 [그림] 을 순서대로 끼워 넣으세요.
   [그림] 개수는 figures 개수와 같아야 합니다. 전사본에 이미 [그림] 이나 [그림: 설명] 표시가 있으면 그 자리를 [그림] 하나로 쓰세요.
   그림이 없으면 전사본을 그대로 돌려주세요.`;

export async function handleTextbookSolutionFigures(
  req: Request,
  auth: AuthContext,
  body: Rec,
): Promise<Response> {
  const academyId = uuidOrNull(body.academy_id);
  if (!academyId) return errorResponse(400, 'invalid_scope', '학원 정보가 필요합니다.');
  const items = (Array.isArray(body.items) ? body.items : [])
    .map((x) => (x ?? {}) as Rec)
    .map((r) => ({
      cropId: uuidOrNull(r.crop_id),
      imageUrl: imageDataUrl(r.solution_image_base64, r.solution_image_mime),
    }))
    .filter((x): x is { cropId: string; imageUrl: string } => !!x.cropId && !!x.imageUrl)
    .slice(0, MAX_ITEMS);
  if (items.length === 0) return jsonResponse({ ok: true, processed: 0, results: [] });

  const wallClockMs = thinkWallClockMs();
  const provider = createAiProvider({ timeoutMs: wallClockMs + 5000 });
  if (!provider) return errorResponse(503, 'ai_not_configured', 'OPENAI_API_KEY 비밀값이 설정되지 않았습니다.');
  const budget = await getBudgetStatus(auth.admin).catch(() => null);
  if (budget?.exceeded && budget.mode === 'block') {
    return errorResponse(429, 'budget_exceeded', '이번 달 AI 한도를 넘었습니다.');
  }

  const { data: analyses } = await auth.admin
    .from('textbook_problem_analyses')
    .select('crop_id,academy_id,solution_transcribed,solution_source,textbook_problem_crops(problem_number)')
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
    parts.push({ type: 'text', text: `[crop_id=${x.cropId} · 해설 영역 이미지]` });
    parts.push({ type: 'image', url: x.imageUrl, detail: 'high' });
  }

  const startedAt = Date.now();
  const model = modelFor('primary');
  const signal = AbortSignal.any([req.signal, AbortSignal.timeout(wallClockMs)]);
  const res = await provider.complete(
    {
      model,
      instructions: SOLUTION_FIGURES_INSTRUCTIONS,
      input: [{ kind: 'message', role: 'user', parts }],
      jsonSchema: { name: 'textbook_solution_figures', schema: SOLUTION_FIGURES_SCHEMA },
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
    features: { count: targets.length },
  });

  const results: Rec[] = [];
  for (const x of targets) {
    const r = byCrop.get(x.cropId);
    if (!r) continue;
    const a = analysisByCrop.get(x.cropId)!;
    const original = String(a.solution_transcribed ?? '');
    const found = normalizeFigures(r.figures);
    const figures = found.map((f) => f.bbox);
    let text = original;
    // 운영자가 고친 해설은 글자를 바꾸지 않는다(그림은 렌더할 때 표시가 모자라면 끝에 붙인다).
    if (a.solution_source !== 'manual') {
      const marked = markedSolutionText(original, r.solution_with_markers, figures.length);
      if (marked !== null && marked !== original) {
        const { error } = await auth.admin
          .from('textbook_problem_analyses')
          .update({ solution_transcribed: marked, updated_at: new Date().toISOString() })
          .eq('crop_id', x.cropId);
        if (!error) text = marked;
      }
    }
    results.push({ crop_id: x.cropId, figures, placements: found.map((f) => f.placement), solution_transcribed: text });
  }
  return jsonResponse({ ok: true, processed: results.length, results });
}
