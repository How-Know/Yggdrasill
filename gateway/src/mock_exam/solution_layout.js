// 모의고사 해설지에서 한 문항의 풀이가 차지하는 영역을 정한다(좌표 계산만, DB·파일을 건드리지 않는다).
//
// 해설지는 여러 단으로 짜여 있고, 풀이는 단 아래에서 끊겨 다음 단(또는 다음 쪽) 위에서 이어진다.
// 추출 때 읽어 둔 것은 문항마다 번호 자리와 "번호부터 같은 단의 다음 번호 위(또는 단 끝)까지"뿐이라,
// 여기서 이어진 부분을 덧붙인다.
//
//   단          = 번호 왼쪽 끝이 모이는 자리(해설지 전체에서 같다)
//   칸          = 한 쪽의 한 단. 읽는 순서는 1쪽 1단 → 1쪽 2단 → … → 2쪽 1단
//   첫 영역     = 번호부터 같은 칸의 다음 번호 바로 위(없으면 단 끝)까지
//   이어진 영역 = 칸의 마지막 풀이면, 다음 칸들의 단 맨 위부터 그 칸 첫 번호 바로 위까지.
//                 번호가 없는 칸은 통째로 이어진 영역이고 그다음 칸으로 넘어간다. 빈 칸을 만나면 끝난다.
//   구간 머리   = 선택과목이 시작하는 줄("[확률과 통계]", "■ [선택: 미적분]"). 풀이는 그 줄 위에서 끝난다.
//
// 칸에 잉크가 있는지와 구간 머리 줄은 PDF 에서 읽은 evidence 로 판단한다(solution_evidence.js).
// evidence 가 없으면 좌표만으로 정하고 unchecked 로 알린다. 영역은 모두 [ymin, xmin, ymax, xmax] 0..1000.

const COLUMN_GAP = 80;
// 번호보다 왼쪽으로 나온 글자((ⅳ) 같은 갈래 표시)까지 들어오게 왼쪽을 조금 더 넓힌다.
const LEFT_PAD_X = 6;
const RIGHT_PAD_X = 4;
const TOP_PAD = 10;
const BOTTOM_PAD = 4;
const NUMBER_PAD = 2;
const BLOCK_GAP = 3;
const INK_PAD = 4;
const HEADER_GAP = 2;
const MIN_SEGMENT = 8;
const UNCHECKED_MIN = 25;
const MIN_TOP = 30;
const MAX_BOTTOM = 965;
// 단 맨 위는 가장 높은 번호보다 이만큼까지만 위로 본다(쪽 머리글이 섞이지 않게).
const MAX_TOP_ABOVE_NUMBER = 60;
const TOP_SUPPORT_TOL = 8;
export const MAX_SOLUTION_CONTINUATIONS = 8;

const ELECTIVE_NAMES = '확률과통계|미적분|기하';
const OPEN = '[\\[［【〔<〈《(（]';
const CLOSE = '[\\]］】〕>〉》)）]';
const HEADER_PATTERNS = [
  // ■ [선택: 확률과 통계] / [미적분]
  new RegExp(`^[^0-9A-Za-z가-힣]*${OPEN}(?:선택(?:과목)?[:：]?)?(?:${ELECTIVE_NAMES})${CLOSE}`),
  // 줄 전체가 구간 이름: "미적분 정답 및 해설", "선택과목 기하"
  new RegExp(`^[^0-9A-Za-z가-힣]*(?:선택(?:과목)?[:：]?)?${OPEN}?(?:${ELECTIVE_NAMES})${CLOSE}?(?:정답(?:및해설)?|해설)?$`),
];

/// 선택과목 구간이 시작하는 머리 줄인가(공백을 뺀 글자로 본다).
export function isSectionHeaderLine(text) {
  const compact = String(text ?? '').replace(/\s+/g, '');
  if (!compact) return false;
  return HEADER_PATTERNS.some((re) => re.test(compact));
}

export function solutionRegionOf(raw) {
  if (!Array.isArray(raw) || raw.length !== 4) return null;
  const v = raw.map((x) => Math.round(Number(x)));
  if (v.some((x) => !Number.isFinite(x) || x < 0 || x > 1000)) return null;
  if (v[2] <= v[0] || v[3] <= v[1]) return null;
  return v;
}

function clamp(value, lo, hi) {
  return Math.max(lo, Math.min(hi, value));
}

/// 번호 왼쪽 끝이 모이는 자리로 단을 나눈다. 반환: [{ left, right, min, max }] (왼쪽 단부터)
export function solutionColumns(items) {
  const xs = [...new Set(items.map((b) => b.number[1]))].sort((a, b) => a - b);
  const clusters = [];
  for (const x of xs) {
    const last = clusters[clusters.length - 1];
    if (last && x - last.max <= COLUMN_GAP) last.max = x;
    else clusters.push({ min: x, max: x });
  }
  const indexOf = (x) => clusters.findIndex((c) => x >= c.min && x <= c.max);
  const rights = clusters.map(() => 0);
  for (const b of items) {
    const i = indexOf(b.number[1]);
    if (i < 0 || !b.content) continue;
    const nextMin = clusters[i + 1]?.min ?? 1001;
    // 옆 단까지 넘어간 풀이 영역은 단 폭을 재는 데 쓰지 않는다.
    if (b.content[3] > b.number[1] + 40 && b.content[3] < nextMin) rights[i] = Math.max(rights[i], b.content[3]);
  }
  const widths = rights.map((r, i) => (r > 0 ? r - clusters[i].min : 0)).filter((w) => w > 0);
  const typicalWidth = widths.length > 0 ? Math.max(...widths) : 0;
  const leftOf = (c) => clamp(c.min - LEFT_PAD_X, 0, 1000);
  return clusters.map((c, i) => {
    const nextLeft = clusters[i + 1] ? leftOf(clusters[i + 1]) : null;
    const left = leftOf(c);
    let right;
    if (rights[i] > 0) right = rights[i] + RIGHT_PAD_X;
    else if (typicalWidth > 0) right = c.min + typicalWidth + RIGHT_PAD_X;
    else right = nextLeft != null ? nextLeft - 6 : 1000 - left;
    if (nextLeft != null) right = Math.min(right, nextLeft - 1);
    return { left, right: clamp(right, left + 20, 1000), min: c.min, max: c.max };
  });
}

/// 단 맨 위 높이. 칸마다 첫 잉크 높이를 읽어, 여러 칸이 함께 가리키는 가장 높은 자리를 쓴다
/// (1쪽 제목처럼 한두 칸에만 있는 것은 뺀다). 쪽을 읽지 못하면 가장 높은 번호 위 조금.
function columnTop({ items, columns, evidence, lastPage, bottom }) {
  const numberTops = items.map((b) => b.number[0]).filter((y) => y >= MIN_TOP);
  const highestNumber = numberTops.length > 0 ? Math.min(...numberTops) : MIN_TOP + TOP_PAD;
  let top = highestNumber - TOP_PAD;
  if (typeof evidence?.firstInk === 'function') {
    const firsts = [];
    for (let page = 1; page <= lastPage; page += 1) {
      for (const c of columns) {
        const y = evidence.firstInk(page, [MIN_TOP, c.left, bottom, c.right]);
        if (Number.isFinite(y)) firsts.push(y);
      }
    }
    firsts.sort((a, b) => a - b);
    const need = Math.max(2, Math.ceil(firsts.length * 0.15));
    const supported = firsts.find((y, i) => {
      let count = 0;
      for (let j = i; j < firsts.length && firsts[j] <= y + TOP_SUPPORT_TOL; j += 1) count += 1;
      return count >= need;
    });
    if (Number.isFinite(supported)) top = Math.min(top + TOP_PAD - NUMBER_PAD, supported - INK_PAD);
  }
  return clamp(top, Math.max(MIN_TOP, highestNumber - MAX_TOP_ABOVE_NUMBER), 1000);
}

function firstHeader(evidence, page, region) {
  if (evidence?.hasText !== true || typeof evidence.lines !== 'function') return null;
  if (region[2] - region[0] < 2) return null;
  const lines = evidence.lines(page, region);
  if (!Array.isArray(lines)) return null;
  return lines.find((line) => isSectionHeaderLine(line.text)) || null;
}

function inkOf(evidence, page, region) {
  if (!evidence || typeof evidence.inkBounds !== 'function') return null;
  if (region[2] - region[0] < 1 || region[3] - region[1] < 1) return [];
  const ink = evidence.inkBounds(page, region);
  return Array.isArray(ink) ? ink : null;
}

/// blocks: [{ key, section, page, numberRegion, contentRegion, manual }]
///   key 는 문항을 가리는 값, section 은 구간, manual 은 사람이 고친 풀이 영역(그대로 둔다).
/// evidence: { pageCount, hasText,
///             inkBounds(page, region) → [](빈 곳) | [ymin, ymax] | null(모름),
///             firstInk(page, region) → 첫 잉크 높이 | null,
///             lines(page, region) → [{ text, yMin, yMax }] | null }
/// 반환: { segments: Map(key → { rawPage, numberRegion, contentRegion, continuations, headerCut, unchecked }),
///         columns, top, bottom, unchecked: [key] }
export function planSolutionSegments({ blocks, evidence = null, pageCount = 0 } = {}) {
  const items = [];
  for (const raw of Array.isArray(blocks) ? blocks : []) {
    const number = solutionRegionOf(raw?.numberRegion);
    const page = Math.round(Number(raw?.page));
    if (!number || !(page > 0)) continue;
    items.push({
      key: raw.key,
      section: String(raw.section ?? ''),
      page,
      number,
      content: solutionRegionOf(raw.contentRegion),
      manual: raw.manual === true,
    });
  }
  const segments = new Map();
  if (items.length === 0) return { segments, columns: [], top: 0, bottom: 0, unchecked: [] };

  const columns = solutionColumns(items);
  const columnOf = (b) => Math.max(0, columns.findIndex((c) => b.number[1] >= c.min && b.number[1] <= c.max));
  const bottoms = [];
  for (const b of items) {
    bottoms.push(Math.min(b.number[2], MAX_BOTTOM));
    if (b.content && b.content[2] <= MAX_BOTTOM) bottoms.push(b.content[2]);
  }
  const bottom = clamp(Math.max(...bottoms) + BOTTOM_PAD, MIN_TOP + MIN_SEGMENT, MAX_BOTTOM + BOTTOM_PAD);
  const lastPage = Math.max(Number(evidence?.pageCount) || 0, Number(pageCount) || 0, ...items.map((b) => b.page));
  const top = Math.min(columnTop({ items, columns, evidence, lastPage, bottom }), bottom - MIN_SEGMENT);

  const nCols = columns.length;
  for (const b of items) {
    b.col = columnOf(b);
    b.slot = (b.page - 1) * nCols + b.col;
  }
  items.sort((a, b) => a.slot - b.slot || a.number[0] - b.number[0]);
  const bySlot = new Map();
  for (const b of items) {
    if (!bySlot.has(b.slot)) bySlot.set(b.slot, []);
    bySlot.get(b.slot).push(b);
  }
  const totalSlots = lastPage * nCols;
  const hasText = evidence?.hasText === true;
  const uncheckedKeys = [];

  for (let i = 0; i < items.length; i += 1) {
    const b = items[i];
    const col = columns[b.col];
    const next = items[i + 1] || null;
    const nextSame = next && next.slot === b.slot ? next : null;
    const lastOfSection = !next || next.section !== b.section;
    let headerCut = false;
    let unchecked = false;

    // 첫 영역
    let region;
    if (b.manual && b.content) {
      region = [...b.content];
    } else {
      const y0 = Math.max(0, b.number[0] - NUMBER_PAD);
      const limit = nextSame ? Math.max(b.number[2], nextSame.number[0] - BLOCK_GAP) : Math.max(bottom, b.number[2]);
      let y1 = limit;
      const header = firstHeader(evidence, b.page, [b.number[2], col.left, limit, col.right]);
      if (header) {
        y1 = clamp(header.yMin - HEADER_GAP, b.number[2], limit);
        headerCut = true;
      }
      const ink = inkOf(evidence, b.page, [b.number[2], col.left, y1, col.right]);
      if (ink) {
        y1 = ink.length === 2 ? Math.min(y1, ink[1] + INK_PAD) : Math.min(y1, b.number[2] + INK_PAD);
      } else if (b.content && !header) {
        // 쪽을 읽지 못했다: 추출 때 읽은 풀이 끝을 쓴다.
        y1 = clamp(b.content[2], b.number[2], limit);
      }
      region = [y0, col.left, Math.max(y1, b.number[2]), col.right];
    }

    // 이어진 영역
    const continuations = [];
    if (!nextSame && !headerCut) {
      for (let s = b.slot + 1; s < totalSlots && continuations.length < MAX_SOLUTION_CONTINUATIONS; s += 1) {
        const page = Math.floor(s / nCols) + 1;
        const c = columns[s % nCols];
        const first = bySlot.get(s)?.[0] || null;
        let y0 = top;
        let y1 = first ? first.number[0] - BLOCK_GAP : bottom;
        let stop = Boolean(first);
        // 다음 풀이가 단 맨 위에서 시작한다.
        if (y1 - y0 < MIN_SEGMENT) break;
        const header = firstHeader(evidence, page, [y0, c.left, y1, c.right]);
        if (header) {
          y1 = clamp(header.yMin - HEADER_GAP, y0, y1);
          stop = true;
          headerCut = true;
        }
        const ink = inkOf(evidence, page, [y0, c.left, y1, c.right]);
        if (ink) {
          // 빈 칸: 풀이는 앞에서 끝났다.
          if (ink.length === 0) break;
          y0 = Math.max(y0, ink[0] - INK_PAD);
          y1 = Math.min(y1, ink[1] + INK_PAD);
        } else {
          // 쪽을 읽지 못했다: 좁은 틈은 풀이인지 알 수 없어 붙이지 않는다.
          if (y1 - y0 < UNCHECKED_MIN) break;
          unchecked = true;
        }
        if (y1 - y0 >= MIN_SEGMENT) continuations.push({ rawPage: page, region1k: [y0, c.left, y1, c.right] });
        if (stop) break;
      }
    }
    // 구간의 마지막 풀이인데 머리 줄을 읽을 글자 층이 없으면, 다음 구간 머리·정답표가 섞였을 수 있다.
    if (lastOfSection && next && !hasText && !b.manual) unchecked = true;
    if (unchecked) uncheckedKeys.push(b.key);
    segments.set(b.key, {
      rawPage: b.page,
      numberRegion: b.number,
      contentRegion: region,
      continuations,
      headerCut,
      unchecked,
    });
  }
  return { segments, columns, top, bottom, unchecked: uncheckedKeys };
}
