// 개념책 소단원 전사(두 번 읽은 결과) → 개념 초안(시범). 운영자가 결과 요약을 보고 직접 확정한다.
// 지시문·형식·검사를 Edge 함수와 로컬 실행기가 같이 쓰므로 다른 파일을 import 하지 않는다.
// 출처(쪽·위치)는 모델이 쓰지 않는다. 모델은 블록 id만 고르고, 쪽·위치는 전사 기록에서 붙인다.

export const CONCEPT_DRAFT_PROMPT_VERSION = 'concept_draft_organize.v3';

export const LEGACY_SUB_TYPES = ['정의', '연산', '정리'] as const;
export const MAX_TYPE_NAME = 40;
export const EXCLUDE_REASONS = [
  'problem_fragment',
  'section_label',
  'illustration',
  'answer_reference',
  'duplicate',
  'other',
] as const;

// DB 제약(concept_drafts_pages_check)·매니저 kConceptDraftMaxPages 와 같은 값.
export const MAX_PAGES = 20;
// 12쪽을 넘는 소단원은 개념이 많아 출력(추론 포함) 한도를 늘린다.
const OUTPUT_TOKENS = 24000;
const OUTPUT_TOKENS_LONG = 32000;
export const MAX_BLOCKS_PER_READ = 60;
export const MAX_BLOCK_CHARS = 4000;

export interface TranscriptBlock {
  kind: string;
  title: string;
  text: string;
  bbox_1k: number[] | null;
  figure_description: string;
  uncertain: boolean;
}

export interface TranscriptPage {
  raw_page: number;
  display_page: number | null;
  a: TranscriptBlock[];
  b: TranscriptBlock[];
}

export interface DraftBlock {
  id: string;
  raw_page: number;
  read: 'a' | 'b';
  kind: string;
  title: string;
  text: string;
  figure_description: string;
  bbox_1k: number[] | null;
  uncertain: boolean;
}

export interface Disagreement {
  id: string;
  raw_page: number;
  type: 'text_differs' | 'missing_in_b' | 'only_in_b';
  similarity: number | null;
  a_text: string;
  b_text: string;
}

export interface PreparedUnit {
  blocks: DraftBlock[];
  furniture: DraftBlock[];
  disagreements: Disagreement[];
}

export interface CriterionRef {
  id: string;
  title: string;
  body: string;
  version: number;
  state: 'confirmed' | 'draft';
}

/** 확정된 개념 유형(concept_types). */
export interface ConceptTypeRef {
  name: string;
  description: string;
  legacy_sub_type: (typeof LEGACY_SUB_TYPES)[number];
}

/** AI가 제안한 새 유형. 운영자가 검토에서 받아들일 때만 목록에 더해진다. */
export interface NewTypeProposal extends ConceptTypeRef {
  closest_existing: string;
  reason: string;
}

export interface ConceptDraft {
  title: string;
  /** 유형 이름: 확정된 유형 또는 new_types 에 제안한 유형. */
  concept_type: string;
  content: string;
  source_blocks: string[];
  criterion_notes: string;
  needs_check: string;
  /** 바로 앞에 알아야 하는 같은 결과 안 개념의 번호(0부터). 없으면 -1. 고리는 정리할 때 끊는다. */
  anchor: number;
}

export interface DraftExclusion {
  block_ids: string[];
  reason_type: (typeof EXCLUDE_REASONS)[number];
  reason: string;
}

export interface ConceptDraftResult {
  summary: string;
  concepts: ConceptDraft[];
  new_types: NewTypeProposal[];
  excluded: DraftExclusion[];
  questions: string[];
}

export interface DraftChecks {
  unknown_ids: string[];
  unaccounted: string[];
  formula_warnings: { concept: number; formula: string }[];
  concepts_without_source: number[];
  /** 유형이 목록에도 새 유형 제안에도 없는 개념. */
  unknown_types: number[];
}

// ───────── 두 번 읽은 결과 맞추기 ─────────

/** LaTeX로 썼는지 글자로 썼는지(\cdots/…, \times/×, \text{…})는 같게 본다. */
export function normText(s: string): string {
  return String(s ?? '')
    .replace(/\*\*/g, '')
    .replace(/\$/g, '')
    .replace(/\\text\{([^}]*)\}/g, '$1')
    .replace(/\\[cl]?dots|⋯|…/g, '…')
    .replace(/\\times/g, '×')
    .replace(/\\div/g, '÷')
    .replace(/\\left|\\right|\\[,;! ]|\\quad|\\qquad/g, '')
    .replace(/[{}]/g, '')
    .replace(/\s+/g, '');
}

export function similarity(a: string, b: string): number {
  if (!a && !b) return 1;
  if (!a || !b) return 0;
  const n = a.length;
  const m = b.length;
  let prev = new Uint32Array(m + 1);
  let cur = new Uint32Array(m + 1);
  for (let j = 0; j <= m; j += 1) prev[j] = j;
  for (let i = 1; i <= n; i += 1) {
    cur[0] = i;
    const ca = a.charCodeAt(i - 1);
    for (let j = 1; j <= m; j += 1) {
      cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca === b.charCodeAt(j - 1) ? 0 : 1));
    }
    [prev, cur] = [cur, prev];
  }
  return 1 - prev[m] / Math.max(n, m);
}

function iou(a: number[] | null, b: number[] | null): number {
  if (!a || !b) return 0;
  const y0 = Math.max(a[0], b[0]);
  const x0 = Math.max(a[1], b[1]);
  const y1 = Math.min(a[2], b[2]);
  const x1 = Math.min(a[3], b[3]);
  const inter = Math.max(0, y1 - y0) * Math.max(0, x1 - x0);
  const area = (r: number[]) => (r[2] - r[0]) * (r[3] - r[1]);
  const union = area(a) + area(b) - inter;
  return union > 0 ? inter / union : 0;
}

function blockText(b: { title: string; text: string; figure_description?: string }): string {
  return [b.title, b.text].filter(Boolean).join('\n');
}

const SAME_TEXT = 0.9;
const digits = (s: string) => s.replace(/[^0-9]/g, '');
const SAME_PLACE = 0.3;

/** 첫 번째 읽기(a)를 기본으로 두고, 두 번째 읽기(b)와 다른 곳을 찾는다. b에만 있는 블록도 고를 수 있게 남긴다. */
export function prepareUnit(pages: TranscriptPage[]): PreparedUnit {
  const blocks: DraftBlock[] = [];
  const furniture: DraftBlock[] = [];
  const disagreements: Disagreement[] = [];
  for (const page of pages) {
    const toDraft = (b: TranscriptBlock, read: 'a' | 'b', i: number): DraftBlock => ({
      id: `p${page.raw_page}-${read}${i}`,
      raw_page: page.raw_page,
      read,
      kind: b.kind,
      title: b.title,
      text: b.text,
      figure_description: b.figure_description,
      bbox_1k: b.bbox_1k,
      uncertain: b.uncertain,
    });
    const usedB = new Set<number>();
    page.a.forEach((a, i) => {
      const d = toDraft(a, 'a', i);
      if (a.kind === 'page_furniture') {
        furniture.push(d);
        return;
      }
      blocks.push(d);
      if (page.b.length === 0) return;
      let best = -1;
      let bestScore = 0;
      page.b.forEach((b, j) => {
        const place = iou(a.bbox_1k, b.bbox_1k);
        const text = similarity(normText(blockText(a)), normText(blockText(b)));
        const score = Math.max(place, text >= SAME_TEXT ? 1 : 0);
        if (score > bestScore) {
          best = j;
          bestScore = score;
        }
      });
      if (best < 0 || bestScore < SAME_PLACE) {
        disagreements.push({ id: d.id, raw_page: page.raw_page, type: 'missing_in_b', similarity: null, a_text: blockText(a), b_text: '' });
        return;
      }
      usedB.add(best);
      const na = normText(blockText(a));
      const nb = normText(blockText(page.b[best]));
      const sim = similarity(na, nb);
      // 수학에서는 숫자 하나가 결정적이라, 숫자 순서가 다르면 일치율과 상관없이 다르다고 본다.
      if (sim < SAME_TEXT || digits(na) !== digits(nb)) {
        disagreements.push({
          id: d.id,
          raw_page: page.raw_page,
          type: 'text_differs',
          similarity: Math.round(sim * 1000) / 1000,
          a_text: blockText(a),
          b_text: blockText(page.b[best]),
        });
      }
    });
    page.b.forEach((b, j) => {
      if (usedB.has(j) || b.kind === 'page_furniture') return;
      const coveredByA = page.a.some(
        (a) => iou(a.bbox_1k, b.bbox_1k) >= SAME_PLACE || similarity(normText(blockText(a)), normText(blockText(b))) >= SAME_TEXT,
      );
      if (coveredByA) return;
      const d = toDraft(b, 'b', j);
      blocks.push(d);
      disagreements.push({ id: d.id, raw_page: page.raw_page, type: 'only_in_b', similarity: null, a_text: '', b_text: blockText(b) });
    });
  }
  return { blocks, furniture, disagreements };
}

// ───────── 지시문과 형식 ─────────

export const CONCEPT_DRAFT_SCHEMA: Record<string, unknown> = {
  type: 'object',
  additionalProperties: false,
  required: ['summary', 'concepts', 'new_types', 'excluded', 'questions'],
  properties: {
    summary: { type: 'string' },
    concepts: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['title', 'concept_type', 'content', 'source_blocks', 'criterion_notes', 'needs_check', 'anchor'],
        properties: {
          title: { type: 'string' },
          concept_type: { type: 'string' },
          content: { type: 'string' },
          source_blocks: { type: 'array', items: { type: 'string' } },
          criterion_notes: { type: 'string' },
          needs_check: { type: 'string' },
          anchor: { type: 'integer' },
        },
      },
    },
    new_types: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['name', 'description', 'legacy_sub_type', 'closest_existing', 'reason'],
        properties: {
          name: { type: 'string' },
          description: { type: 'string' },
          legacy_sub_type: { type: 'string', enum: [...LEGACY_SUB_TYPES] },
          closest_existing: { type: 'string' },
          reason: { type: 'string' },
        },
      },
    },
    excluded: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['block_ids', 'reason_type', 'reason'],
        properties: {
          block_ids: { type: 'array', items: { type: 'string' } },
          reason_type: { type: 'string', enum: [...EXCLUDE_REASONS] },
          reason: { type: 'string' },
        },
      },
    },
    questions: { type: 'array', items: { type: 'string' } },
  },
};

const INSTRUCTIONS = `당신은 Yggdrasill의 Think입니다. 수학 개념서 한 소단원을 옮겨 적은 블록을 받아, 개념 라이브러리에 넣을 개념 초안을 만듭니다.
초안은 사장님이 결과 요약을 보고 직접 확정합니다. 당신은 확정하지 않습니다.

[받는 것]
- 블록: id, 쪽, 종류, 이름표, 내용. 쪽 번호·머리말 같은 쪽 장식은 이미 뺐습니다.
- 회색으로 가린 문항 영역은 이미 따로 저장한 문항이라 블록에 없습니다. 다만 문항 가장자리의 잘린 글자가 블록으로 남았을 수 있습니다.
- 두 번 읽은 결과가 다른 곳: 같은 쪽을 두 번 옮겨 적었을 때 글자가 다른 블록, 한쪽에만 있는 블록.
- 정리 기준: 사장님이 확정한 기준(확정 vN)과 아직 확정 전인 초안. 확정 기준을 따르고, 초안은 참고만 합니다.
- 개념 유형 목록: 사장님이 확정한 유형(이름·설명·기존 구분).

[할 일]
1. 블록마다 개념에 쓸지, 뺄지 정합니다. 모든 블록이 개념의 source_blocks나 excluded 중 한 곳에 들어가야 합니다.
2. 개념 하나는 정의 하나, 성질 하나, 방법 하나처럼 따로 찾아볼 만한 단위로 둡니다. 정리 기준에 단위 규칙이 있으면 그것을 따릅니다.
3. content는 원문 표현과 수식을 최대한 그대로 씁니다. 원문에 없는 사실, 예, 풀이를 보태지 마세요. 문장을 이어 붙이거나 순서를 정리하는 정도만 합니다.
   본문 속 예(예: 2, 3, 5, …)는 그 개념의 content에 "예:"로 붙입니다. 수식은 LaTeX($...$)로 씁니다.
4. source_blocks에는 그 개념의 근거가 된 블록 id를 모두 적습니다. 근거 없는 개념은 만들지 마세요.
5. 빼는 블록은 이유를 적습니다. problem_fragment(문항의 잘린 글자·문항 번호), section_label(필수 문제·개념 확인 같은 구역 이름), illustration(장식 그림·캐릭터 말풍선), answer_reference(정답과 해설 안내), duplicate(다른 블록과 같은 내용), other.
6. 두 번 읽은 결과가 다른 블록을 개념에 쓰면, 어느 쪽이 맞는지 판단할 수 없을 때 needs_check에 무엇이 다른지 적습니다. 판단할 수 있으면 맞는 쪽으로 쓰고 needs_check에 근거를 짧게 남깁니다.
7. criterion_notes에는 어떤 기준(이름·판)을 어떻게 적용했는지 한 줄로 적습니다. 확정 기준이 없으면 "확정 기준 없음"이라고 적습니다.
8. summary는 사장님이 먼저 읽을 결과 요약입니다. 개념 몇 개를 만들었는지, 무엇을 왜 뺐는지, 확인이 필요한 곳이 몇 군데인지 3~6줄로 씁니다.
9. 기준이 모자라 판단할 수 없는 것은 추측하지 말고 questions에 사장님께 물을 것으로 적습니다.

[개념 유형]
- concept_type에는 개념 유형 목록의 이름 하나를 그대로 씁니다. 목록에 있는 유형을 최대한 씁니다.
- 목록의 어느 유형에도 맞지 않는 개념이 있을 때만 new_types에 새 유형을 제안하고, 그 개념의 concept_type에 새 유형 이름을 씁니다.
  새 유형은 다른 단원에서도 다시 쓸 수 있는 짧고 일반적인 이름이어야 합니다(한 개념만을 위한 이름, 단원 이름, 목록 유형을 잘게 나눈 이름은 만들지 않습니다).
- new_types 항목: name(${MAX_TYPE_NAME}자 이하), description(어떤 개념이 이 유형인지 한두 문장), legacy_sub_type(기존 구분 정의·연산·정리 중 가장 가까운 것),
  closest_existing(사장님이 거절하면 대신 쓸 목록 유형 이름. 목록이 비었으면 빈 문자열), reason(왜 목록 유형으로는 안 되는지).
- 새 유형이 필요 없으면 new_types는 빈 배열입니다.

[주제 묶음]
- anchor에는 이 개념을 이해하려면 바로 앞에 알아야 하는, 이번 결과 안의 다른 개념 번호(concepts 배열 순서, 0부터)를 하나 적습니다.
  정의의 표현·주의·성질·방법은 그 정의를, 다른 정의를 써서 정하는 정의는 그 정의를, 성질을 써서 구하는 방법은 그 성질을 가리킵니다.
- 가장 직접 쓰는 개념 하나만 고릅니다. 기대는 개념이 이번 결과에 없거나 첫 개념이면 -1입니다. 서로 가리키는 고리를 만들지 마세요.
- 라이브러리에서는 이 묶음과 유형 순서로 개념을 늘어놓습니다. 사장님이 검토에서 바꿀 수 있습니다.

출력은 정해진 JSON 형식만 씁니다.`;

function blockLine(b: DraftBlock): string {
  const flags = [b.read === 'b' ? '두 번째 읽기에만 있음' : '', b.uncertain ? '전사 불확실' : ''].filter(Boolean).join(', ');
  const head = `[${b.id}] ${b.raw_page}쪽 · ${b.kind}${b.title ? ` · "${b.title}"` : ''}${flags ? ` · (${flags})` : ''}`;
  const fig = b.figure_description ? `\n(그림: ${b.figure_description})` : '';
  return `${head}\n${b.text}${fig}`;
}

export function buildConceptDraftPrompt(input: {
  bookName: string;
  gradeLabel: string;
  unitPath: string[];
  prepared: PreparedUnit;
  criteria: CriterionRef[];
  types: ConceptTypeRef[];
}): { instructions: string; userText: string; maxOutputTokens: number } {
  const confirmed = input.criteria.filter((c) => c.state === 'confirmed');
  const drafts = input.criteria.filter((c) => c.state === 'draft');
  const criteriaText = [
    confirmed.length === 0
      ? '확정 기준: 없음'
      : `확정 기준:\n${confirmed.map((c) => `## ${c.title} (확정 v${c.version})\n${c.body}`).join('\n\n')}`,
    drafts.length === 0 ? '' : `확정 전 초안(참고만):\n${drafts.map((c) => `## ${c.title} (초안)\n${c.body}`).join('\n\n')}`,
  ].filter(Boolean).join('\n\n');
  const dis = input.prepared.disagreements.length === 0
    ? '없음'
    : input.prepared.disagreements
      .map((d) => {
        if (d.type === 'missing_in_b') return `- [${d.id}] 두 번째 읽기에는 없음`;
        if (d.type === 'only_in_b') return `- [${d.id}] 첫 번째 읽기에는 없음`;
        return `- [${d.id}] 글자가 다름(일치 ${Math.round((d.similarity ?? 0) * 100)}%)\n  두 번째 읽기: ${d.b_text.replace(/\n/g, ' / ')}`;
      })
      .join('\n');
  const userText = [
    `교재: ${input.bookName} ${input.gradeLabel}`,
    `단원: ${input.unitPath.filter(Boolean).join(' > ')}`,
    '',
    criteriaText,
    '',
    input.types.length === 0
      ? '개념 유형 목록: 없음(필요한 유형을 모두 new_types로 제안)'
      : `개념 유형 목록:\n${input.types.map((t) => `- ${t.name} (기존 구분 ${t.legacy_sub_type}): ${t.description}`).join('\n')}`,
    '',
    `블록 ${input.prepared.blocks.length}개:`,
    input.prepared.blocks.map(blockLine).join('\n\n'),
    '',
    '두 번 읽은 결과가 다른 곳:',
    dis,
  ].join('\n');
  const pages = new Set(input.prepared.blocks.map((b) => b.raw_page)).size;
  return { instructions: INSTRUCTIONS, userText, maxOutputTokens: pages > 12 ? OUTPUT_TOKENS_LONG : OUTPUT_TOKENS };
}

// ───────── 출력 정리와 검사 ─────────

function str(v: unknown): string {
  return typeof v === 'string' ? v : '';
}
function strList(v: unknown): string[] {
  return Array.isArray(v) ? v.map(str).map((s) => s.trim()).filter(Boolean) : [];
}

/** 유형 이름 비교(앞뒤·연속 공백, 대소문자 무시). DB의 lower(btrim(name)) 과 맞춘다. */
export function typeKey(name: string): string {
  return name.trim().replace(/\s+/g, ' ').toLowerCase();
}

function parseNewTypes(v: unknown, known: Map<string, string>): NewTypeProposal[] {
  const legacy = LEGACY_SUB_TYPES as readonly string[];
  const out: NewTypeProposal[] = [];
  const seen = new Set<string>();
  for (const t of Array.isArray(v) ? v : []) {
    if (!t || typeof t !== 'object') continue;
    const r = t as Record<string, unknown>;
    const name = str(r.name).trim().replace(/\s+/g, ' ');
    const key = typeKey(name);
    if (!name || name.length > MAX_TYPE_NAME || known.has(key) || seen.has(key)) continue;
    seen.add(key);
    const sub = str(r.legacy_sub_type);
    out.push({
      name,
      description: str(r.description).trim().slice(0, 500),
      legacy_sub_type: (legacy.includes(sub) ? sub : '정리') as NewTypeProposal['legacy_sub_type'],
      closest_existing: known.get(typeKey(str(r.closest_existing))) ?? '',
      reason: str(r.reason).trim().slice(0, 500),
    });
  }
  return out;
}

/** types: 확정된 유형 목록. 같은 이름은 목록의 표기로 맞추고, 목록에 이미 있는 새 유형 제안은 뺀다. */
export function parseConceptDraft(text: string, types: ConceptTypeRef[] = []): ConceptDraftResult | null {
  let raw: unknown;
  try {
    raw = JSON.parse(text.trim().replace(/^```(?:json)?\s*|\s*```$/g, ''));
  } catch {
    return null;
  }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const o = raw as Record<string, unknown>;
  const known = new Map(types.map((t) => [typeKey(t.name), t.name]));
  const newTypes = parseNewTypes(o.new_types, known);
  const proposed = new Map(newTypes.map((t) => [typeKey(t.name), t.name]));
  const reasons = EXCLUDE_REASONS as readonly string[];
  const concepts: ConceptDraft[] = [];
  const rawAnchors: unknown[] = [];
  const kept = new Map<number, number>();
  (Array.isArray(o.concepts) ? o.concepts : []).forEach((c: unknown, i: number) => {
    if (!c || typeof c !== 'object') return;
    const r = c as Record<string, unknown>;
    const title = str(r.title).trim();
    const content = str(r.content).trim();
    if (!title && !content) return;
    const type = str(r.concept_type).trim().replace(/\s+/g, ' ');
    kept.set(i, concepts.length);
    rawAnchors.push(r.anchor);
    concepts.push({
      title,
      concept_type: known.get(typeKey(type)) ?? proposed.get(typeKey(type)) ?? type.slice(0, MAX_TYPE_NAME),
      content,
      source_blocks: strList(r.source_blocks),
      criterion_notes: str(r.criterion_notes).trim(),
      needs_check: str(r.needs_check).trim(),
      anchor: -1,
    });
  });
  const anchors = acyclicAnchors(rawAnchors.map((a) => (Number.isInteger(a) ? kept.get(a as number) ?? -1 : -1)));
  anchors.forEach((a, i) => (concepts[i].anchor = a));
  const excluded: DraftExclusion[] = [];
  for (const e of Array.isArray(o.excluded) ? o.excluded : []) {
    if (!e || typeof e !== 'object') continue;
    const r = e as Record<string, unknown>;
    const ids = strList(r.block_ids);
    if (ids.length === 0) continue;
    excluded.push({
      block_ids: ids,
      reason_type: (reasons.includes(str(r.reason_type)) ? str(r.reason_type) : 'other') as DraftExclusion['reason_type'],
      reason: str(r.reason).trim(),
    });
  }
  return { summary: str(o.summary).trim(), concepts, new_types: newTypes, excluded, questions: strList(o.questions) };
}

/** 번호 목록의 anchor(없으면 -1)에서 범위 밖·자기 자신·고리를 만드는 것을 앞에서부터 -1로 바꾼다. */
export function acyclicAnchors(raw: number[]): number[] {
  const out = raw.map(() => -1);
  raw.forEach((a, i) => {
    if (!Number.isInteger(a) || a < 0 || a >= raw.length || a === i) return;
    let cur = a;
    for (let steps = 0; cur >= 0 && steps <= raw.length; steps += 1) {
      if (cur === i) return;
      cur = out[cur];
    }
    out[i] = a;
  });
  return out;
}

/** 수식 조각($...$)을 꺼낸다. 한 글자짜리 숫자·문자는 원문 대조에서 뺀다. */
export function formulas(content: string): string[] {
  const out: string[] = [];
  const re = /\$\$([\s\S]+?)\$\$|\$([^$]+?)\$/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(content)) !== null) {
    const f = (m[1] ?? m[2] ?? '').trim();
    if (normText(f).length >= 3) out.push(f);
  }
  return out;
}

export function checkConceptDraft(draft: ConceptDraftResult, prepared: PreparedUnit, types: ConceptTypeRef[] = []): DraftChecks {
  const typeKeys = new Set([...types, ...draft.new_types].map((t) => typeKey(t.name)));
  const byId = new Map(prepared.blocks.map((b) => [b.id, b]));
  const known = new Set(byId.keys());
  const unknown = new Set<string>();
  const used = new Set<string>();
  const formulaWarnings: DraftChecks['formula_warnings'] = [];
  const withoutSource: number[] = [];
  draft.concepts.forEach((c, i) => {
    const cited = c.source_blocks.filter((id) => {
      if (known.has(id)) return true;
      unknown.add(id);
      return false;
    });
    cited.forEach((id) => used.add(id));
    if (cited.length === 0) withoutSource.push(i);
    const sourceText = normText(cited.map((id) => {
      const b = byId.get(id);
      return b ? `${b.title}${b.text}${b.figure_description}` : '';
    }).join(''));
    for (const f of formulas(c.content)) {
      if (!sourceText.includes(normText(f))) formulaWarnings.push({ concept: i, formula: f });
    }
  });
  for (const e of draft.excluded) {
    for (const id of e.block_ids) {
      if (known.has(id)) used.add(id);
      else unknown.add(id);
    }
  }
  return {
    unknown_ids: [...unknown],
    unaccounted: prepared.blocks.filter((b) => !used.has(b.id)).map((b) => b.id),
    formula_warnings: formulaWarnings,
    concepts_without_source: withoutSource,
    unknown_types: draft.concepts.flatMap((c, i) => (typeKeys.has(typeKey(c.concept_type)) ? [] : [i])),
  };
}

/** concept_types 행 → 유형 목록(이름·설명·기존 구분). */
export function conceptTypeRefs(rows: Record<string, unknown>[]): ConceptTypeRef[] {
  const legacy = LEGACY_SUB_TYPES as readonly string[];
  return rows
    .map((r) => ({
      name: str(r.name).trim(),
      description: str(r.description).trim(),
      legacy_sub_type: str(r.legacy_sub_type) as ConceptTypeRef['legacy_sub_type'],
    }))
    .filter((t) => t.name && legacy.includes(t.legacy_sub_type));
}

// ───────── 요청 본문 ─────────

function readBlocks(v: unknown): TranscriptBlock[] | null {
  if (!Array.isArray(v) || v.length > MAX_BLOCKS_PER_READ) return null;
  const out: TranscriptBlock[] = [];
  for (const b of v) {
    if (!b || typeof b !== 'object') return null;
    const r = b as Record<string, unknown>;
    const bbox = Array.isArray(r.bbox_1k) && r.bbox_1k.length === 4 && r.bbox_1k.every((n) => Number.isFinite(Number(n)))
      ? r.bbox_1k.map((n) => Math.max(0, Math.min(1000, Math.round(Number(n)))))
      : null;
    out.push({
      kind: str(r.kind).slice(0, 30) || 'other',
      title: str(r.title).slice(0, 200),
      text: str(r.text).slice(0, MAX_BLOCK_CHARS),
      bbox_1k: bbox,
      figure_description: str(r.figure_description).slice(0, 1000),
      uncertain: r.uncertain === true,
    });
  }
  return out;
}

export function readConceptDraftBody(body: Record<string, unknown>):
  | { ok: true; pages: TranscriptPage[]; criterionIds: string[]; bookName: string; gradeLabel: string; unitPath: string[] }
  | { ok: false; error: 'pages_required' | 'too_many_pages' | 'invalid_page' | 'invalid_criteria' } {
  const rawPages = Array.isArray(body.pages) ? body.pages : [];
  if (rawPages.length === 0) return { ok: false, error: 'pages_required' };
  if (rawPages.length > MAX_PAGES) return { ok: false, error: 'too_many_pages' };
  const pages: TranscriptPage[] = [];
  for (const p of rawPages) {
    if (!p || typeof p !== 'object') return { ok: false, error: 'invalid_page' };
    const r = p as Record<string, unknown>;
    const raw = Number(r.raw_page);
    const a = readBlocks(r.a);
    const b = readBlocks(r.b ?? []);
    if (!Number.isInteger(raw) || raw < 1 || !a || !b) return { ok: false, error: 'invalid_page' };
    const display = Number(r.display_page);
    pages.push({ raw_page: raw, display_page: Number.isInteger(display) ? display : null, a, b });
  }
  const ids = Array.isArray(body.criterion_ids) ? body.criterion_ids.map(str).map((s) => s.trim()).filter(Boolean) : [];
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (ids.length > 10 || ids.some((id) => !uuid.test(id))) return { ok: false, error: 'invalid_criteria' };
  return {
    ok: true,
    pages,
    criterionIds: [...new Set(ids)],
    bookName: str(body.book_name).trim().slice(0, 80),
    gradeLabel: str(body.grade_label).trim().slice(0, 20),
    unitPath: (Array.isArray(body.unit_path) ? body.unit_path : []).map(str).map((s) => s.trim().slice(0, 80)).filter(Boolean).slice(0, 6),
  };
}

/** 기준 행 → 참고 기준. 확정본이 있으면 확정본, 저장된 초안이 있으면 초안을 따로 둔다. */
export function criterionRefs(rows: Record<string, unknown>[], maxChars = 6000): CriterionRef[] {
  const out: CriterionRef[] = [];
  for (const r of rows) {
    const id = str(r.id);
    const version = Number(r.version) || 0;
    if (version > 0 && str(r.body).trim()) {
      out.push({ id, title: str(r.title).trim(), body: str(r.body).slice(0, maxChars), version, state: 'confirmed' });
    }
    if (str(r.draft_body).trim() && r.draft_saved_at) {
      out.push({ id, title: str(r.draft_title).trim() || str(r.title).trim(), body: str(r.draft_body).slice(0, maxChars), version, state: 'draft' });
    }
  }
  return out;
}
