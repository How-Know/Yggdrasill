// 개념책 초안(concept_page_read·concept_draft_organize)이 같이 쓰는 교재 확인과 문항 가림 영역.
// 가림 영역은 저장된 문항 기록(textbook_problem_crops)에서만 만든다. 매니저앱도 같은 순서·이름으로 그린다
// (apps/yggdrasill_manager/lib/services/concept_draft_models.dart conceptPageMasks).

import type { AuthContext } from './ai/auth.ts';
import { resolveMemberAcademy } from './ai/auth.ts';

export interface PageMask {
  label: string;
  bbox_1k: number[];
  problem_number?: string;
}

export interface CropRow {
  raw_page?: unknown;
  display_page?: unknown;
  problem_number?: unknown;
  item_region_1k?: unknown;
  bbox_1k?: unknown;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(v: unknown): v is string {
  return typeof v === 'string' && UUID.test(v);
}

function box(v: unknown): number[] | null {
  if (!Array.isArray(v) || v.length !== 4) return null;
  const n = v.map((x) => Math.round(Number(x)));
  if (n.some((x) => !Number.isFinite(x))) return null;
  const [y0, x0, y1, x1] = n.map((x) => Math.max(0, Math.min(1000, x)));
  return y1 > y0 && x1 > x0 ? [y0, x0, y1, x1] : null;
}

/** 문항 영역(item_region_1k, 없으면 bbox_1k)을 왼쪽 단부터 위에서 아래로 M1, M2 … 로 붙인다. */
export function masksFromCrops(rows: CropRow[]): PageMask[] {
  const items = rows
    .map((r) => ({ bbox: box(r.item_region_1k) ?? box(r.bbox_1k), num: String(r.problem_number ?? '').trim().slice(0, 20) }))
    .filter((r): r is { bbox: number[]; num: string } => r.bbox !== null)
    .sort((a, b) => a.bbox[1] - b.bbox[1] || a.bbox[0] - b.bbox[0]);
  return items.map((r, i) => ({ label: `M${i + 1}`, bbox_1k: r.bbox, ...(r.num ? { problem_number: r.num } : {}) }));
}

/** 앱이 그린 가림 영역이 서버가 읽은 것과 같은지(이름·위치). */
export function sameMasks(a: PageMask[], b: PageMask[]): boolean {
  if (a.length !== b.length) return false;
  return a.every((m, i) => m.label === b[i].label && m.bbox_1k.every((v, j) => v === b[i].bbox_1k[j]));
}

export function displayPageOf(rows: CropRow[]): number | null {
  for (const r of rows) {
    const d = Number(r.display_page);
    if (Number.isInteger(d) && d > 0) return d;
  }
  return null;
}

/** 운영자가 소속된 학원의 교재일 때만 이름을 돌려준다(concept_sources 정책과 같은 기준). */
export async function operatorBook(
  auth: AuthContext,
  academyId: string,
  bookId: string,
): Promise<{ name: string } | null> {
  if (!isUuid(academyId) || !isUuid(bookId)) return null;
  if ((await resolveMemberAcademy(auth, academyId)) !== academyId) return null;
  const { data, error } = await auth.admin
    .from('resource_files')
    .select('name')
    .eq('id', bookId)
    .eq('academy_id', academyId)
    .maybeSingle();
  if (error || !data) return null;
  return { name: String((data as Record<string, unknown>).name ?? '').trim() };
}

export async function pageCrops(
  auth: AuthContext,
  academyId: string,
  bookId: string,
  gradeLabel: string,
  rawPage: number,
): Promise<CropRow[] | null> {
  const { data, error } = await auth.admin
    .from('textbook_problem_crops')
    .select('raw_page,display_page,problem_number,item_region_1k,bbox_1k')
    .eq('academy_id', academyId)
    .eq('book_id', bookId)
    .eq('grade_label', gradeLabel)
    .eq('raw_page', rawPage)
    .limit(200);
  if (error) return null;
  return (data ?? []) as CropRow[];
}
