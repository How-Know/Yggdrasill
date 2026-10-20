// 라이브러리 폴더 하나의 주제 묶음 제안: 개념마다 바로 앞에 알아야 하는 같은 폴더 개념을 하나 고른다.
// 제안일 뿐이며 저장하지 않는다. 운영자가 고른 줄만 concept_anchor_set(origin 'proposal')으로 넣는다.

import { acyclicAnchors } from './organize.ts';

export const CONCEPT_ANCHOR_PROMPT_VERSION = 'concept_anchor_plan.v1';
export const MAX_ANCHOR_CONCEPTS = 120;
const CONTENT_CHARS = 200;

export interface AnchorConcept {
  id: string;
  name: string;
  type: string;
  content: string;
  anchor_id: string | null;
}

export interface AnchorProposalItem {
  concept_id: string;
  anchor_id: string | null;
  current_anchor_id: string | null;
  reason: string;
}

export interface AnchorProposal {
  summary: string;
  items: AnchorProposalItem[];
  /** AI가 답하지 않아 지금 연결을 그대로 둔 개념, 고리를 만들어 끊은 개념. */
  checks: { unanswered: string[]; broken: string[] };
}

export const CONCEPT_ANCHOR_SCHEMA: Record<string, unknown> = {
  type: 'object',
  additionalProperties: false,
  required: ['summary', 'links'],
  properties: {
    summary: { type: 'string' },
    links: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['concept', 'anchor', 'reason'],
        properties: {
          concept: { type: 'integer' },
          anchor: { type: 'integer' },
          reason: { type: 'string' },
        },
      },
    },
  },
};

const INSTRUCTIONS = `당신은 Yggdrasill의 Think입니다. 개념 라이브러리 폴더 하나의 개념들을 주제 묶음으로 잇는 안을 냅니다.
사장님이 줄마다 보고 고른 것만 저장됩니다. 당신은 저장하지 않습니다.

[묶음]
- 개념마다 anchor에 그 개념을 이해하려면 바로 앞에 알아야 하는, 이 폴더 안의 다른 개념 번호를 하나 적습니다. 없으면 -1입니다.
- 정의의 표현·주의·성질·방법은 그 정의를, 다른 정의를 써서 정하는 정의는 그 정의를, 성질을 써서 구하는 방법은 그 성질을 가리킵니다.
- 가장 직접 쓰는 개념 하나만 고릅니다. 여러 단계로 이어져도 됩니다(정의 → 그 정의를 쓰는 정의 → 그 성질).
- 서로 가리키는 고리를 만들지 마세요. 폴더의 첫 개념이나 혼자 서는 개념은 -1입니다.
- 지금 연결이 맞으면 그대로 두세요. 바꿀 때만 이유에 무엇이 달라지는지 적습니다.
- 개념의 이름·본문·유형은 바꾸지 않습니다.

[출력]
- links: 모든 개념(concept = 번호)을 한 번씩. anchor(-1 또는 번호)와 이유 한 줄.
- summary: 사장님이 먼저 읽을 2~3줄. 어떤 줄기로 묶었는지, 확인할 점.
출력은 정해진 JSON 형식만 씁니다.`;

export function buildAnchorPrompt(input: {
  folderPath: string[];
  concepts: AnchorConcept[];
  typeOrder: string[];
}): { instructions: string; userText: string; maxOutputTokens: number } {
  const index = new Map(input.concepts.map((c, i) => [c.id, i]));
  const lines = input.concepts.map((c, i) => {
    const current = c.anchor_id != null && index.has(c.anchor_id) ? ` · 지금 묶음: [${index.get(c.anchor_id)}]` : '';
    return `[${i}] ${c.name} (${c.type || '유형 없음'})${current}\n${c.content.replace(/\s+/g, ' ').slice(0, CONTENT_CHARS)}`;
  });
  const userText = [
    `폴더: ${input.folderPath.join(' > ') || '(이름 없음)'}`,
    `유형 순서(묶음 안에서 이 순서로 늘어놓습니다): ${input.typeOrder.join(' → ') || '(없음)'}`,
    '',
    `개념 ${input.concepts.length}개(지금 라이브러리 순서):`,
    lines.join('\n\n'),
  ].join('\n');
  return { instructions: INSTRUCTIONS, userText, maxOutputTokens: 6000 };
}

function str(v: unknown): string {
  return typeof v === 'string' ? v : '';
}

/** AI 답 → 개념 id 로 된 제안. 답이 없는 개념은 지금 연결을 두고, 고리는 앞에서부터 끊는다. */
export function parseAnchorProposal(text: string, concepts: AnchorConcept[]): AnchorProposal | null {
  let raw: unknown;
  try {
    raw = JSON.parse(text.trim().replace(/^```(?:json)?\s*|\s*```$/g, ''));
  } catch {
    return null;
  }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const o = raw as Record<string, unknown>;
  const index = new Map(concepts.map((c, i) => [c.id, i]));
  const current = concepts.map((c) => (c.anchor_id != null ? index.get(c.anchor_id) ?? -1 : -1));
  const answered = new Map<number, { anchor: number; reason: string }>();
  for (const v of Array.isArray(o.links) ? o.links : []) {
    if (!v || typeof v !== 'object') continue;
    const r = v as Record<string, unknown>;
    const concept = Number(r.concept);
    if (!Number.isInteger(concept) || concept < 0 || concept >= concepts.length || answered.has(concept)) continue;
    const anchor = Number(r.anchor);
    answered.set(concept, {
      anchor: Number.isInteger(anchor) ? anchor : -1,
      reason: str(r.reason).trim().slice(0, 300),
    });
  }
  const wanted = concepts.map((_, i) => answered.get(i)?.anchor ?? current[i]);
  const valid = wanted.map((a, i) => (a >= 0 && a < concepts.length && a !== i ? a : -1));
  const final = acyclicAnchors(valid);
  const broken: string[] = [];
  const unanswered: string[] = [];
  const items = concepts.map((c, i) => {
    if (!answered.has(i)) unanswered.push(c.id);
    else if (final[i] !== valid[i]) broken.push(c.id);
    return {
      concept_id: c.id,
      anchor_id: final[i] >= 0 ? concepts[final[i]].id : null,
      current_anchor_id: current[i] >= 0 ? concepts[current[i]].id : null,
      reason: answered.get(i)?.reason ?? '',
    };
  });
  return { summary: str(o.summary).trim(), items, checks: { unanswered, broken } };
}
