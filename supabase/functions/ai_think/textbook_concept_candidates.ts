import type { AuthContext } from '../_shared/ai/auth.ts';

type Rec = Record<string, unknown>;

/** 모델에 보내는 개념 후보. ref 는 짧은 번호(k1, k2 …)다. UUID 를 그대로 보내면 모델이 비슷한 값을 지어내기 쉽다. */
export interface ConceptCandidate {
  ref: string;
  id: string;
  name: string;
}

export interface ConceptCandidates {
  list: ConceptCandidate[];
  byRef: Map<string, ConceptCandidate>;
  /** unit: 대·중단원 이름이 맞는 개념, grade: 맞는 단원이 없어 같은 학년 전체, none: 학년 개념이 없음 */
  scope: 'unit' | 'grade' | 'none';
}

/** 개념 후보 원천 한 줄: 개념서 개념 출처(단원 경로) 또는 교재 검수에서 만든 개념(만든 단원). */
export interface ConceptSourceRow {
  id: string;
  name: string;
  unitPath: string[];
  /** 교재 검수에서 만든 개념(만든 단원 이름이 교재·시험지 이름이다). 개념서 출처면 비운다. */
  created?: boolean;
}

/** 단원 이름 비교용. 앞 번호(Ⅰ. 1. (1))·뒤 번호((1))·공백·문장부호를 뺀다. */
export function normalizeUnitName(raw: unknown): string {
  let s = String(raw ?? '').normalize('NFC').trim();
  s = s.replace(/^(?:[ⅠⅡⅢⅣⅤⅥⅦⅧⅨⅩ]+|[IVX]+|[0-9]+)\s*[.)]\s*/, '');
  s = s.replace(/^\(\s*[0-9]+\s*\)\s*/, '');
  s = s.replace(/\(\s*[0-9]+\s*\)\s*$/, '');
  return s.replace(/[\s·.,:;'"()[\]{}<>~\-]/g, '');
}

function unitNameMatch(a: string, b: string): boolean {
  if (!a || !b) return false;
  if (a === b) return true;
  const [short, long] = a.length <= b.length ? [a, b] : [b, a];
  return short.length >= 3 && long.includes(short);
}

/** 개념 출처의 대·중단원(unit_path 앞 두 칸) 중 하나가 문항의 대단원이나 중단원 이름과 맞는가. */
export function unitMatches(unitPath: unknown, bigName: unknown, midName: unknown): boolean {
  const path = (Array.isArray(unitPath) ? unitPath : []).slice(0, 2).map(normalizeUnitName).filter(Boolean);
  const names = [normalizeUnitName(bigName), normalizeUnitName(midName)].filter(Boolean);
  return path.some((p) => names.some((n) => unitNameMatch(p, n)));
}

/**
 * 같은 학년 개념 중 문항 단원에 맞는 개념을 후보로 고른다. 맞는 개념이 없으면(종합 평가 단원 등) 학년 전체를 쓴다.
 * 단원이 맞는지는 개념서 단원으로만 판단한다. 검수에서 만든 개념은 만든 곳 이름(시험지는 학교·시험명)을 갖고 있어,
 * 그것만 맞으면 후보가 그 개념 하나로 줄어든다(2026-11-18: 같은 시험명의 다른 학교 시험지에서 만든 개념 1개만 후보가 됨).
 * 개념 테이블에서 임의로 채우지 않는다(사양 5-6).
 */
export function buildConceptCandidates(rows: ConceptSourceRow[], bigName: unknown, midName: unknown): ConceptCandidates {
  const all = new Map<string, { id: string; name: string; unit: boolean }>();
  let bookUnitHit = false;
  for (const r of rows) {
    if (!r.id || !r.name.trim()) continue;
    const hit = unitMatches(r.unitPath, bigName, midName);
    if (hit && r.created !== true) bookUnitHit = true;
    const prev = all.get(r.id);
    if (prev) {
      prev.unit = prev.unit || hit;
    } else {
      all.set(r.id, { id: r.id, name: r.name.trim(), unit: hit });
    }
  }
  const unit = bookUnitHit ? [...all.values()].filter((c) => c.unit) : [];
  const picked = unit.length > 0 ? unit : [...all.values()];
  const list = picked.map((c, i) => ({ ref: `k${i + 1}`, id: c.id, name: c.name }));
  return {
    list,
    byRef: new Map(list.map((c) => [c.ref, c])),
    scope: list.length === 0 ? 'none' : unit.length > 0 ? 'unit' : 'grade',
  };
}

/** 모델이 고른 ref 를 개념 id 로 바꾼다. 목록에 없는 ref 는 버린다. */
export function conceptIdsFromRefs(refs: unknown, candidates: ConceptCandidates, max = 4): string[] {
  const out: string[] = [];
  for (const raw of Array.isArray(refs) ? refs : []) {
    const c = candidates.byRef.get(String(raw ?? '').trim());
    if (c && !out.includes(c.id)) out.push(c.id);
    if (out.length >= max) break;
  }
  return out;
}

/** 같은 학년의 다른 학기 라벨(2-2 → 2-1). 학기 표기가 아닌 라벨(공통수학2 등)은 null. */
export function otherSemesterGrade(gradeLabel: string): string | null {
  const m = /^(\d+)-([12])$/.exec(gradeLabel.trim());
  return m ? `${m[1]}-${m[2] === '1' ? '2' : '1'}` : null;
}

/**
 * 검수 범위의 과정 라벨을 개념 과정들로 나눈다. 교재는 과정 하나(공통수학2)이고,
 * 모의고사 구간은 여러 과정을 '+' 로 이어 쓴다(고3 공통 = 대수+미적분1).
 */
export function conceptGradeLabels(gradeLabel: string): string[] {
  const out: string[] = [];
  for (const part of gradeLabel.split('+')) {
    const label = part.trim();
    if (label && !out.includes(label)) out.push(label);
  }
  return out;
}

const PAGE = 1000;

export async function loadConceptCandidates(
  admin: AuthContext['admin'],
  gradeLabel: string,
  bigName: unknown,
  midName: unknown,
): Promise<ConceptCandidates> {
  const labels = conceptGradeLabels(gradeLabel);
  const rows: ConceptSourceRow[] = [];
  for (const label of labels) {
    for (let from = 0; from < 10 * PAGE; from += PAGE) {
      const { data, error } = await admin
        .from('concept_sources')
        .select('concept_id,unit_path,concepts(id,name)')
        .eq('grade_label', label)
        .order('book_id')
        .order('raw_page')
        .range(from, from + PAGE - 1);
      if (error) throw new Error(`concept_sources: ${error.message}`);
      const page = (data ?? []) as Rec[];
      for (const r of page) {
        const c = (r.concepts ?? null) as Rec | null;
        if (c && typeof c.id === 'string' && typeof c.name === 'string') {
          rows.push({ id: c.id, name: c.name, unitPath: Array.isArray(r.unit_path) ? (r.unit_path as unknown[]).map(String) : [] });
        }
      }
      if (page.length < PAGE) break;
    }
  }
  // 검수에서 만든 개념: 이 범위의 라벨(여러 과정이면 이어 쓴 라벨)과 각 과정 라벨로 만든 것.
  const createdLabels = labels.length > 1 ? [gradeLabel.trim(), ...labels] : [gradeLabel];
  const createdQuery = admin.from('concepts').select('id,name,origin_detail').eq('origin', 'textbook_review');
  const { data: created } = await (createdLabels.length === 1
    ? createdQuery.eq('origin_detail->>grade_label', createdLabels[0])
    : createdQuery.in('origin_detail->>grade_label', createdLabels)
  ).limit(PAGE);
  for (const c of (created ?? []) as Rec[]) {
    const d = (c.origin_detail ?? {}) as Rec;
    if (typeof c.id === 'string' && typeof c.name === 'string') {
      rows.push({ id: c.id, name: c.name, unitPath: [String(d.big_name ?? ''), String(d.mid_name ?? '')], created: true });
    }
  }
  return buildConceptCandidates(rows, bigName, midName);
}

/** 검수 범위(교재·학년·대단원·중단원)의 대·중단원 이름. 크롭 한 장에서 읽는다. */
export async function loadScopeUnitNames(
  admin: AuthContext['admin'],
  scope: { bookId: string; gradeLabel: string; bigOrder: number; midOrder: number },
): Promise<{ bigName: string; midName: string }> {
  const { data } = await admin
    .from('textbook_problem_crops')
    .select('big_name,mid_name')
    .eq('book_id', scope.bookId)
    .eq('grade_label', scope.gradeLabel)
    .eq('big_order', scope.bigOrder)
    .eq('mid_order', scope.midOrder)
    .limit(1)
    .maybeSingle();
  const r = (data ?? {}) as Rec;
  return { bigName: String(r.big_name ?? ''), midName: String(r.mid_name ?? '') };
}
