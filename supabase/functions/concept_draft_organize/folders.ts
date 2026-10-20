// 개념 초안 → 라이브러리 폴더 제안. 교재 단원은 참고만 하고 수학 내용의 구조에 맞춰 넣을 자리를 고른다.
// 제안일 뿐이며 라이브러리에는 쓰지 않는다. 운영자가 검토 화면에서 고친 뒤 확정할 때만 폴더가 만들어진다.

export const CONCEPT_FOLDER_PROMPT_VERSION = 'concept_folder_plan.v2';

export const MAX_OUTLINE_FOLDERS = 400;
export const MAX_PENDING_DRAFTS = 30;
const MAX_PENDING_CONCEPTS = 240;
const MAX_OVERLAPS_PER_CONCEPT = 3;
const NAMES_PER_FOLDER = 6;
const MAX_SEGMENT = 80;
const MAX_DEPTH = 7;

export interface LibraryCategory {
  id: string;
  name: string;
  parent_id: string | null;
  code?: string | null;
}

export interface LibraryOutline {
  roots: string[];
  /** 영역 이름부터 시작하는 폴더 경로와 들어 있는 개념 이름(앞부분만). */
  folders: { path: string[]; count: number; names: string[] }[];
  truncated: boolean;
}

export interface DraftConceptBrief {
  index: number;
  title: string;
  concept_type: string;
  content: string;
}

/** 확정 전인 다른 초안이 쓰기로 한 자리. 라이브러리에는 아직 없다. */
export interface PendingDraft {
  unit: string;
  concepts: { title: string; path: string[] }[];
}

export interface FolderPlan {
  notes: string;
  folders: { path: string[]; reason: string }[];
  placements: { concept: number; path: string[]; reason: string }[];
  /** 라이브러리나 다른 초안과 겹칠 수 있는 개념. 알리기만 하고 초안은 그대로 둔다. */
  overlaps: { concept: number; other: string; reason: string }[];
}

export interface FolderPlanChecks {
  unknown_root: number[];
  unplaced: number[];
  duplicate: number[];
  /** 지금 라이브러리에 없어 확정하면 새로 만들어질 폴더 경로. */
  new_folders: string[][];
}

/** 폴더 표 → 경로 목록. 바로가기(SHORTCUT) 폴더는 뺀다. */
export function libraryOutline(
  categories: LibraryCategory[],
  concepts: { main_category_id: string; name: string }[],
): LibraryOutline {
  const byId = new Map(categories.map((c) => [c.id, c]));
  const pathOf = (id: string): string[] | null => {
    const out: string[] = [];
    let cur = byId.get(id);
    for (let i = 0; cur && i < 12; i += 1) {
      if (cur.code === 'SHORTCUT') return null;
      out.unshift(cur.name.trim());
      if (!cur.parent_id) return out;
      cur = byId.get(cur.parent_id);
    }
    return null;
  };
  const roots = categories.filter((c) => !c.parent_id && c.code !== 'SHORTCUT').map((c) => c.name.trim());
  const names = new Map<string, string[]>();
  for (const c of concepts) names.set(c.main_category_id, [...(names.get(c.main_category_id) ?? []), c.name]);
  const folders: LibraryOutline['folders'] = [];
  for (const c of categories) {
    if (!c.parent_id) continue;
    const path = pathOf(c.id);
    if (!path || path.length < 2) continue;
    const list = names.get(c.id) ?? [];
    folders.push({ path, count: list.length, names: list.slice(0, NAMES_PER_FOLDER) });
  }
  folders.sort((a, b) => a.path.join('\u0000').localeCompare(b.path.join('\u0000')));
  return {
    roots,
    folders: folders.slice(0, MAX_OUTLINE_FOLDERS),
    truncated: folders.length > MAX_OUTLINE_FOLDERS,
  };
}

function rec(v: unknown): Record<string, unknown> {
  return v && typeof v === 'object' && !Array.isArray(v) ? v as Record<string, unknown> : {};
}

/** 다른 열린 초안 한 줄 → 쓰기로 한 자리. 검토를 저장했으면 운영자가 정한 폴더, 아니면 AI 제안을 쓴다. */
export function pendingDraftOf(row: {
  unit_path?: unknown;
  review_saved_at?: unknown;
  draft_concepts?: unknown;
  placements?: unknown;
  review_concepts?: unknown;
}): PendingDraft | null {
  const unitPath = Array.isArray(row.unit_path) ? row.unit_path.map(String).filter(Boolean) : [];
  const concepts: PendingDraft['concepts'] = [];
  if (row.review_saved_at && Array.isArray(row.review_concepts)) {
    for (const raw of row.review_concepts) {
      const r = rec(raw);
      if (r.mark === 'drop') continue;
      const path = cleanPath(r.folder);
      const title = str(r.title).trim();
      if (title && path.length >= 2) concepts.push({ title, path });
    }
  } else {
    const titles = Array.isArray(row.draft_concepts) ? row.draft_concepts.map((c) => str(rec(c).title).trim()) : [];
    const seen = new Set<number>();
    for (const raw of Array.isArray(row.placements) ? row.placements : []) {
      const p = rec(raw);
      const i = Number(p.concept);
      if (!Number.isInteger(i) || seen.has(i) || !titles[i]) continue;
      seen.add(i);
      const path = cleanPath(p.path);
      if (path.length >= 2) concepts.push({ title: titles[i], path });
    }
  }
  if (concepts.length === 0) return null;
  return { unit: unitPath.at(-1) ?? '(단원 없음)', concepts };
}

export const CONCEPT_FOLDER_SCHEMA: Record<string, unknown> = {
  type: 'object',
  additionalProperties: false,
  required: ['notes', 'folders', 'placements', 'overlaps'],
  properties: {
    notes: { type: 'string' },
    overlaps: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['concept', 'other', 'reason'],
        properties: {
          concept: { type: 'integer' },
          other: { type: 'string' },
          reason: { type: 'string' },
        },
      },
    },
    folders: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['path', 'reason'],
        properties: {
          path: { type: 'array', items: { type: 'string' } },
          reason: { type: 'string' },
        },
      },
    },
    placements: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['concept', 'path', 'reason'],
        properties: {
          concept: { type: 'integer' },
          path: { type: 'array', items: { type: 'string' } },
          reason: { type: 'string' },
        },
      },
    },
  },
};

const INSTRUCTIONS = `당신은 Yggdrasill의 Think입니다. 개념 초안을 개념 라이브러리의 어느 폴더에 넣을지 제안합니다.
사장님이 검토 화면에서 고친 뒤 확정합니다. 당신은 폴더를 만들거나 옮기지 않습니다.

[원칙]
- 교재의 대단원·중단원·소단원 이름과 순서는 참고일 뿐입니다. 따르지 마세요.
  수학 내용의 실제 구조(어떤 대상을 다루는지, 어떤 개념이 어떤 개념의 하위인지, 같은 연산·성질끼리인지)에 맞춥니다.
- 경로는 반드시 영역(최상위 폴더) 이름 하나로 시작합니다. 영역 목록에 없는 이름으로 시작하지 마세요.
- 이미 있는 폴더가 맞으면 그 경로를 글자 그대로 씁니다. 맞는 폴더가 없을 때만 새 폴더를 제안합니다.
- 영역 아래는 1~4단계로 둡니다. 개념 하나만 들어갈 폴더를 여러 개 만들지 마세요.
- 폴더 이름은 짧은 수학 용어로 씁니다. 학년·교재 이름·단원 번호를 넣지 않습니다.
- "검토 중인 다른 초안"의 폴더는 아직 확정 전이지만 이미 있는 폴더처럼 봅니다.
  같은 내용을 담을 자리면 그 경로를 글자 그대로 쓰고, 비슷한 이름의 폴더를 따로 만들지 마세요.

[겹침]
- 이 초안의 개념이 지금 라이브러리의 개념이나 검토 중인 다른 초안의 개념과 같은 개념이면 overlaps에 적습니다.
- 개념을 빼거나 합치지 않습니다. 알리기만 하고 판단은 사장님이 합니다.
- 이름만 비슷하고 다루는 대상·조건이 다르면 적지 않습니다.

[출력]
- placements: 모든 개념(concept = 번호)을 한 번씩 넣을 경로와 짧은 이유.
- folders: 새로 만들 폴더만, 경로와 그 자리에 둔 이유 한 줄. 다른 초안이 이미 쓰는 폴더는 넣지 않습니다.
- overlaps: 겹칠 수 있는 개념 번호, other(겹치는 쪽. "라이브러리 대수 > … > 소수" 또는 "초안 소수와 합성수: 소수"), reason 한 줄. 없으면 빈 배열.
- notes: 사장님이 먼저 읽을 2~4줄. 어떤 구조로 나눴는지, 기존 폴더·다른 초안과 어떻게 맞췄는지, 확인할 점.
출력은 정해진 JSON 형식만 씁니다.`;

function pendingSection(outline: LibraryOutline, pending: PendingDraft[]): string[] {
  if (pending.length === 0) return [];
  const existing = new Set(outline.folders.map((f) => f.path.join('\u0000')));
  const fresh = new Map<string, string[]>();
  const lines: string[] = [];
  let left = MAX_PENDING_CONCEPTS;
  for (const d of pending) {
    if (left <= 0) break;
    const shown = d.concepts.slice(0, left);
    left -= shown.length;
    for (const c of shown) {
      for (let i = 2; i <= c.path.length; i += 1) {
        const key = c.path.slice(0, i).join('\u0000');
        if (!existing.has(key) && !fresh.has(key)) fresh.set(key, c.path.slice(0, i));
      }
    }
    lines.push(`- 초안 ${d.unit}: ${shown.map((c) => `${c.title} → ${c.path.join(' > ')}`).join('; ')}`);
  }
  return [
    '',
    '검토 중인 다른 초안(확정 전)이 쓰기로 한 자리:',
    ...lines,
    left <= 0 ? '(개념이 많아 일부만 보였습니다.)' : '',
    '',
    '그중 라이브러리에 아직 없는 폴더(이미 있는 폴더처럼 다시 쓰세요):',
    ...(fresh.size === 0 ? ['(없음)'] : [...fresh.values()].map((p) => `- ${p.join(' > ')}`)),
  ];
}

export function buildFolderPrompt(input: {
  outline: LibraryOutline;
  unitPath: string[];
  concepts: DraftConceptBrief[];
  pending?: PendingDraft[];
}): { instructions: string; userText: string; maxOutputTokens: number } {
  const folderLines = input.outline.folders.length === 0
    ? '(영역 아래 폴더 없음)'
    : input.outline.folders
      .map((f) => `- ${f.path.join(' > ')}${f.count > 0 ? ` (개념 ${f.count}: ${f.names.join(', ')}${f.count > f.names.length ? ', …' : ''})` : ''}`)
      .join('\n');
  const conceptLines = input.concepts
    .map((c) => `[${c.index}] ${c.title} (${c.concept_type})\n${c.content.replace(/\s+/g, ' ').slice(0, 240)}`)
    .join('\n\n');
  const userText = [
    `영역(최상위 폴더): ${input.outline.roots.join(', ')}`,
    '',
    '지금 라이브러리 폴더:',
    folderLines,
    input.outline.truncated ? '(폴더가 많아 일부만 보였습니다.)' : '',
    ...pendingSection(input.outline, input.pending ?? []),
    '',
    `교재 단원(참고만): ${input.unitPath.filter(Boolean).join(' > ') || '(없음)'}`,
    '',
    `개념 초안 ${input.concepts.length}개:`,
    conceptLines,
  ].filter((l, i, all) => l !== '' || all[i - 1] !== '').join('\n');
  return { instructions: INSTRUCTIONS, userText, maxOutputTokens: 8000 };
}

function str(v: unknown): string {
  return typeof v === 'string' ? v : '';
}

function cleanPath(v: unknown): string[] {
  if (!Array.isArray(v)) return [];
  return v.map(str).map((s) => s.trim().slice(0, MAX_SEGMENT)).filter(Boolean).slice(0, MAX_DEPTH);
}

export function parseFolderPlan(text: string): FolderPlan | null {
  let raw: unknown;
  try {
    raw = JSON.parse(text.trim().replace(/^```(?:json)?\s*|\s*```$/g, ''));
  } catch {
    return null;
  }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const o = raw as Record<string, unknown>;
  const folders: FolderPlan['folders'] = [];
  for (const f of Array.isArray(o.folders) ? o.folders : []) {
    if (!f || typeof f !== 'object') continue;
    const r = f as Record<string, unknown>;
    const path = cleanPath(r.path);
    if (path.length >= 2) folders.push({ path, reason: str(r.reason).trim() });
  }
  const placements: FolderPlan['placements'] = [];
  for (const p of Array.isArray(o.placements) ? o.placements : []) {
    if (!p || typeof p !== 'object') continue;
    const r = p as Record<string, unknown>;
    const concept = Number(r.concept);
    if (!Number.isInteger(concept) || concept < 0) continue;
    placements.push({ concept, path: cleanPath(r.path), reason: str(r.reason).trim() });
  }
  const overlaps: FolderPlan['overlaps'] = [];
  const perConcept = new Map<number, Set<string>>();
  for (const v of Array.isArray(o.overlaps) ? o.overlaps : []) {
    const r = rec(v);
    const concept = Number(r.concept);
    const other = str(r.other).trim().slice(0, 200);
    if (!Number.isInteger(concept) || concept < 0 || !other) continue;
    const seen = perConcept.get(concept) ?? new Set<string>();
    if (seen.has(other) || seen.size >= MAX_OVERLAPS_PER_CONCEPT) continue;
    seen.add(other);
    perConcept.set(concept, seen);
    overlaps.push({ concept, other, reason: str(r.reason).trim().slice(0, 300) });
  }
  return { notes: str(o.notes).trim(), folders, placements, overlaps };
}

export function checkFolderPlan(plan: FolderPlan, outline: LibraryOutline, conceptCount: number): FolderPlanChecks {
  const roots = new Set(outline.roots);
  const existing = new Set(outline.folders.map((f) => f.path.join('\u0000')));
  const unknownRoot: number[] = [];
  const duplicate: number[] = [];
  const placed = new Set<number>();
  const fresh = new Map<string, string[]>();
  for (const p of plan.placements) {
    if (p.concept >= conceptCount) continue;
    if (placed.has(p.concept)) {
      duplicate.push(p.concept);
      continue;
    }
    if (p.path.length < 2 || !roots.has(p.path[0])) {
      unknownRoot.push(p.concept);
      continue;
    }
    placed.add(p.concept);
    for (let i = 2; i <= p.path.length; i += 1) {
      const key = p.path.slice(0, i).join('\u0000');
      if (!existing.has(key) && !fresh.has(key)) fresh.set(key, p.path.slice(0, i));
    }
  }
  const unplaced: number[] = [];
  for (let i = 0; i < conceptCount; i += 1) if (!placed.has(i)) unplaced.push(i);
  return { unknown_root: unknownRoot, unplaced, duplicate, new_folders: [...fresh.values()] };
}
