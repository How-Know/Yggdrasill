// 추출 AI 가 빠뜨린 해설 시작점을 채운다(좌표 계산만, DB·파일·AI 를 부르지 않는다).
//
// 해설 지면을 읽는 AI 가 한 단을 통째로 빠뜨리는 일이 있다(2026 고3 3월: 1쪽 셋째 단의 12·13·14번).
// 그대로 두면 그 문항은 해설 없이 검수되고, 앞 문항의 해설 영역이 그 단까지 늘어난다.
//
//   1) 글자 층  = 해설 PDF 의 낱말에서 "12. [출제의도]" 처럼 시작하는 해설 머리를 찾아 시작점으로 쓴다.
//   2) 다시 읽기 = 글자 층에서도 못 찾은 번호는, 앞뒤 번호가 있는 쪽만 AI 로 한 번 더 읽는다.
//
// 쪽 목록은 mock_exam_worker 의 `{ page, result }`(result 는 normalizeSolutionPage 결과)이고,
// 영역은 모두 [ymin, xmin, ymax, xmax] 0..1000 이다. 받은 쪽 목록은 바꾸지 않고 새 목록을 돌려준다.

import { ELECTIVES, expectedNumbers, isLegacyType } from './mock_pages.js';

// "12." 또는 "12.[출제의도]…" 낱말
const HEAD_WORD_RE = /^0*(\d{1,2})\.(.*)$/;
// 교육청 "[출제의도]", 평가원 "출제의도 :"
const INTENT_RE = /^[[［【]?출제의도/;
const MAX_NUMBER = 30;
// 번호 낱말과 그 뒤 "[출제의도]" 낱말 사이 간격
const HEAD_WORD_GAP = 25;
// 같은 번호가 이만큼 안에 있으면 AI 가 이미 찾은 시작점이다(AI 좌표는 글자 층과 5 안팎 어긋난다).
const SAME_SPOT_Y = 25;
const SAME_SPOT_X = 60;
// 번호 왼쪽 끝이 이만큼 안이면 같은 단이다.
const SAME_COLUMN_X = 40;
const DEFAULT_WIDTH = 250;
const DEFAULT_BOTTOM = 900;
export const MAX_REREAD_PAGES = 4;

/// 낱말 상자에서 해설 머리("12. [출제의도] …")를 찾는다. 반환: [{ number, region }] (region 은 번호 낱말)
export function solutionHeadsFromWords(words) {
  const out = [];
  const list = Array.isArray(words) ? words : [];
  for (const w of list) {
    const m = HEAD_WORD_RE.exec(String(w?.text ?? '').trim());
    if (!m) continue;
    const number = Number(m[1]);
    if (!(number >= 1 && number <= MAX_NUMBER)) continue;
    let isHead = INTENT_RE.test(m[2]);
    if (!isHead && m[2] === '') {
      // 같은 줄에서 바로 오른쪽에 오는 낱말
      const cy = (w.yMin + w.yMax) / 2;
      const next = list
        .filter((o) => o !== w && cy >= o.yMin && cy <= o.yMax && o.xMin >= w.xMax - 1 && o.xMin - w.xMax <= HEAD_WORD_GAP)
        .sort((a, b) => a.xMin - b.xMin)[0];
      isHead = !!next && INTENT_RE.test(String(next.text ?? '').trim());
    }
    if (!isHead) continue;
    out.push({
      number,
      region: [Math.floor(w.yMin), Math.floor(w.xMin), Math.ceil(w.yMax), Math.ceil(w.xMax)],
    });
  }
  return out.sort((a, b) => a.region[1] - b.region[1] || a.region[0] - b.region[0]);
}

const sameSpot = (a, b) => Math.abs(a[0] - b[0]) <= SAME_SPOT_Y && Math.abs(a[1] - b[1]) <= SAME_SPOT_X;
const sameColumn = (a, b) => Math.abs(a[1] - b[1]) <= SAME_COLUMN_X;

function median(values) {
  const v = values.filter((x) => Number.isFinite(x) && x > 0).sort((a, b) => a - b);
  return v.length === 0 ? 0 : v[Math.floor(v.length / 2)];
}

/// 한 쪽의 블록에 새 시작점을 끼운다. 영역이 없는 새 블록은 같은 단의 다음 번호 위(없으면 단 끝)까지로 잡고,
/// 같은 단 위쪽 블록이 새 번호를 넘어가 있으면 그 위에서 끊는다.
function insertBlocks(blocks, fresh, { width, bottom }) {
  const all = [...blocks.map((b) => ({ ...b })), ...fresh.map((b) => ({ ...b }))];
  const added = new Set(all.slice(blocks.length));
  for (const b of added) {
    const top = b.numberRegion[0];
    const below = all
      .filter((o) => o !== b && sameColumn(o.numberRegion, b.numberRegion) && o.numberRegion[0] > top)
      .sort((x, y) => x.numberRegion[0] - y.numberRegion[0])[0];
    if (!Array.isArray(b.contentRegion)) {
      const end = below ? below.numberRegion[0] - 1 : Math.max(bottom, b.numberRegion[2] + 1);
      b.contentRegion = [top, b.numberRegion[1], end, Math.min(1000, b.numberRegion[1] + width)];
    }
    for (const o of all) {
      if (o === b || added.has(o) || !Array.isArray(o.contentRegion)) continue;
      if (!sameColumn(o.numberRegion, b.numberRegion) || o.numberRegion[0] >= top) continue;
      if (o.contentRegion[2] > top - 1 && top - 1 > o.contentRegion[0]) {
        o.contentRegion = [o.contentRegion[0], o.contentRegion[1], top - 1, o.contentRegion[3]];
      }
    }
  }
  return all;
}

function layoutOf(pages) {
  const blocks = (pages || []).flatMap((p) => p?.result?.blocks || []).filter((b) => Array.isArray(b.contentRegion));
  return {
    width: median(blocks.map((b) => b.contentRegion[3] - b.contentRegion[1])) || DEFAULT_WIDTH,
    bottom: Math.max(0, ...blocks.map((b) => b.contentRegion[2])) || DEFAULT_BOTTOM,
  };
}

function mergeInto(pages, freshOf) {
  const layout = layoutOf(pages);
  const added = [];
  const out = (pages || []).map((entry) => {
    const blocks = entry?.result?.blocks || [];
    const fresh = [];
    for (const b of freshOf(entry) || []) {
      const taken = [...blocks, ...fresh].some((o) => o.number === b.number && sameSpot(o.numberRegion, b.numberRegion));
      if (!taken) fresh.push(b);
    }
    if (fresh.length === 0) return entry;
    const pageBottom = Math.max(0, ...blocks.filter((b) => Array.isArray(b.contentRegion)).map((b) => b.contentRegion[2]));
    for (const b of fresh) added.push({ page: entry.page, number: b.number });
    return {
      ...entry,
      result: { ...entry.result, blocks: insertBlocks(blocks, fresh, { width: layout.width, bottom: pageBottom || layout.bottom }) },
    };
  });
  return { pages: out, added };
}

/// 글자 층에서 찾은 해설 머리 가운데 [numbers] 번호이고 AI 가 찾지 못한 것을 블록으로 넣는다.
/// evidence 는 solution_evidence 의 근거(words(page)). 반환: { pages, added: [{ page, number }] }
export function addMissingSolutionBlocks({ pages, evidence, numbers }) {
  const want = numbers instanceof Set ? numbers : new Set(numbers || []);
  if (want.size === 0 || evidence?.hasText !== true || typeof evidence.words !== 'function') {
    return { pages: pages || [], added: [] };
  }
  return mergeInto(pages, (entry) =>
    solutionHeadsFromWords(evidence.words(entry.page))
      .filter((h) => want.has(h.number))
      .map((h) => ({ number: h.number, numberRegion: h.region, contentRegion: null })),
  );
}

/// 다시 읽은 쪽의 블록 가운데 [numbers] 번호이고 아직 없는 것을 넣는다. 반환: { pages, added }
export function mergeRereadBlocks({ pages, reread, numbers }) {
  const want = numbers instanceof Set ? numbers : new Set(numbers || []);
  const byPage = new Map((reread || []).map((r) => [r.page, r.result?.blocks || []]));
  return mergeInto(pages, (entry) => (byPage.get(entry.page) || []).filter((b) => want.has(b.number)));
}

/// 이 해설지가 맡는 구간. 고3: 첫 해설지는 공통, 그리고 그 해설지의 선택과목과 풀이가 하나라도 읽힌 선택과목.
export function solutionSectionsOfPaper({ grade, paperElective = '', fromFirstPage = true, only = null, found }) {
  let sections;
  if (Number(grade) !== 3) sections = ['common'];
  // 가형·나형 해설지는 그 유형 구간(1~30번) 하나만 맡는다.
  else if (isLegacyType(paperElective)) sections = [paperElective];
  else {
    sections = fromFirstPage ? ['common'] : [];
    for (const el of ELECTIVES) {
      const read = [...(found?.keys() || [])].some((key) => String(key).startsWith(`${el}|`));
      if (el === paperElective || read) sections.push(el);
    }
  }
  return only ? sections.filter((s) => only.has(s)) : sections;
}

/// 구간마다 있어야 할 번호 가운데 풀이 시작점이 없는 것. found·known 은 '구간|번호' 를 키로 하는 Map.
export function missingSolutionKeys({ grade, sections, found, known = null }) {
  const out = [];
  for (const section of sections || []) {
    for (const number of expectedNumbers(grade, section)) {
      const key = `${section}|${number}`;
      if (found?.has(key) || known?.has(key)) continue;
      out.push({ section, number });
    }
  }
  return out;
}

/// 빠진 번호를 찾으려고 다시 읽을 쪽: 같은 구간의 앞 번호가 있는 쪽부터 뒤 번호가 있는 쪽까지.
/// 앞뒤 번호를 하나도 못 찾은 구간(이 해설지에 없는 구간)은 다시 읽지 않는다.
export function pagesToReread({ missing, found, pageNumbers }) {
  const pages = [...new Set(pageNumbers || [])].sort((a, b) => a - b);
  const out = new Set();
  for (const { section, number } of missing || []) {
    let prev = null;
    let next = null;
    for (const [key, value] of found || []) {
      const [s, n] = String(key).split('|');
      if (s !== section) continue;
      const k = Number(n);
      if (k < number && (!prev || k > prev.number)) prev = { number: k, page: value.page };
      if (k > number && (!next || k < next.number)) next = { number: k, page: value.page };
    }
    if (!prev && !next) continue;
    const from = prev ? prev.page : next.page - 1;
    const to = next ? next.page : prev.page + 1;
    for (const p of pages) if (p >= from && p <= to) out.add(p);
  }
  return [...out].sort((a, b) => a - b).slice(0, MAX_REREAD_PAGES);
}

/// 해설지 한 부를 읽은 결과에서 빠진 해설 시작점을 채운다: 글자 층 → 그래도 없으면 그 쪽만 AI 로 한 번 더.
///
///   assign(pages)          → '구간|번호' 를 키로 하는 Map (assignSolutionSections 의 solutions)
///   loadEvidence()         → solution_evidence 의 근거. 빠진 번호가 있을 때만 부른다.
///   reread(pages, numbers) → 그 쪽들을 다시 읽은 `[{ page, result }]`. 한 번만 부른다.
///
/// 근거를 읽지 못하거나 다시 읽기가 실패해도 던지지 않는다: 못 채운 번호는 missing 으로 돌려준다.
/// 반환: { pages, textLayer: [{ page, number }], reread: [{ page, number }], rereadPages, missing, errors }
export async function fillMissingSolutionBlocks({
  grade,
  paperElective = '',
  fromFirstPage = true,
  only = null,
  pages,
  known = null,
  assign,
  loadEvidence,
  reread,
}) {
  const out = { pages: pages || [], textLayer: [], reread: [], rereadPages: [], missing: [], errors: [] };
  const missingOf = (found) =>
    missingSolutionKeys({
      grade,
      sections: solutionSectionsOfPaper({ grade, paperElective, fromFirstPage, only, found }),
      found,
      known,
    });
  let found = assign(out.pages);
  out.missing = missingOf(found);
  if (out.missing.length === 0) return out;

  let evidence = null;
  try {
    evidence = await loadEvidence();
  } catch (error) {
    out.errors.push(`evidence: ${String(error?.message || error)}`);
  }
  if (evidence) {
    const filled = addMissingSolutionBlocks({
      pages: out.pages,
      evidence,
      numbers: new Set(out.missing.map((m) => m.number)),
    });
    if (filled.added.length > 0) {
      const before = found;
      found = assign(filled.pages);
      // 끼운 블록 때문에 이미 찾은 번호를 잃으면(구간 판정이 바뀜) 끼우지 않는다.
      if ([...before.keys()].every((key) => found.has(key))) {
        out.pages = filled.pages;
        out.textLayer = filled.added;
        out.missing = missingOf(found);
      } else {
        out.errors.push('text_layer: 끼운 시작점이 구간 판정을 바꿔 쓰지 않았다');
        found = before;
      }
    }
  }
  if (out.missing.length === 0 || typeof reread !== 'function') return out;

  out.rereadPages = pagesToReread({ missing: out.missing, found, pageNumbers: out.pages.map((p) => p.page) });
  if (out.rereadPages.length === 0) return out;
  const numbers = new Set(out.missing.map((m) => m.number));
  let again = null;
  try {
    again = await reread(out.rereadPages, [...numbers].sort((a, b) => a - b));
  } catch (error) {
    out.errors.push(`reread: ${String(error?.message || error)}`);
  }
  if (!again) return out;
  const merged = mergeRereadBlocks({ pages: out.pages, reread: again, numbers });
  if (merged.added.length === 0) return out;
  const after = assign(merged.pages);
  if (![...found.keys()].every((key) => after.has(key))) {
    out.errors.push('reread: 끼운 시작점이 구간 판정을 바꿔 쓰지 않았다');
    return out;
  }
  out.pages = merged.pages;
  out.reread = merged.added;
  out.missing = missingOf(after);
  return out;
}
