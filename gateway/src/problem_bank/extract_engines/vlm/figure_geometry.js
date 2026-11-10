// 교재 PDF 원본 좌표로 V2 그림 폭(em)과 위치를 정한다.
//
// V2 의 그림 폭 단위 em 은 본문 글자 크기다. 원본 쪽에서 본문 글자 1em 이 쪽 폭(1000) 기준으로
// 몇 단위인지(em1k)를 알면 widthEm = 그림 bbox 폭 ÷ em1k 로 원본과 같은 글자 대비 크기가 나온다.
// 스캔본 줄 높이 측정은 수식·분수 때문에 흔들려서, em1k 는 같은 교재에서 이미 검수된 그림 비율로 정한다.
import sharp from 'sharp';

// 교과서·문제집 본문(10~11pt, 쪽 폭 약 190~210mm) 기준값. 수력충전 1-1/1-2 검수 실측 중앙값 17.2~17.6.
export const DEFAULT_TEXT_EM_1K = 17.5;
const MIN_TEXT_EM_1K = 12;
const MAX_TEXT_EM_1K = 26;
const MIN_CALIBRATION_SAMPLES = 15;

const MIN_WIDTH_EM = 4;
// 교재 한 단 폭이 약 25em. 두 단에 걸친 큰 그림도 V2 카드 한 줄을 넘지 않게 묶는다.
const MAX_WIDTH_EM = 30;

function validBbox(b) {
  return Array.isArray(b) && b.length === 4 && b.every((v) => Number.isFinite(Number(v))) && Number(b[2]) > Number(b[0]) && Number(b[3]) > Number(b[1]);
}

function median(values) {
  if (values.length === 0) return NaN;
  const s = [...values].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

function bboxInside(inner, outer) {
  return validBbox(inner) && validBbox(outer) &&
    Number(inner[0]) >= Number(outer[0]) - 5 && Number(inner[2]) <= Number(outer[2]) + 5 &&
    Number(inner[1]) >= Number(outer[1]) - 5 && Number(inner[3]) <= Number(outer[3]) + 5;
}

/// 검수에서 잰 "V2 그림 크기 ÷ 원본 그림 크기"(figure_size_ratio)로 원래 맞았어야 할 em1k 를 역산한다.
/// samples: [{ bbox1k, widthEm, ratio, region1k }] — 그림 1개짜리 문항, 그림이 문항 영역 안에 있는 것만 쓴다.
export function calibrateTextEm1k(samples) {
  const values = [];
  for (const s of Array.isArray(samples) ? samples : []) {
    const r = Number(s?.ratio);
    const w = Number(s?.widthEm);
    if (!(r >= 0.5 && r <= 2.5) || !(w > 0) || !validBbox(s?.bbox1k)) continue;
    if (s.region1k && !bboxInside(s.bbox1k, s.region1k)) continue;
    const em1k = (Number(s.bbox1k[3]) - Number(s.bbox1k[1])) / (w / r);
    if (em1k >= MIN_TEXT_EM_1K && em1k <= MAX_TEXT_EM_1K) values.push(em1k);
  }
  if (values.length < MIN_CALIBRATION_SAMPLES) return null;
  return Math.round(median(values) * 100) / 100;
}

export function figureWidthEm(bbox1k, em1k = DEFAULT_TEXT_EM_1K) {
  if (!validBbox(bbox1k)) return null;
  const em = Number.isFinite(em1k) && em1k > 0 ? em1k : DEFAULT_TEXT_EM_1K;
  const w = (Number(bbox1k[3]) - Number(bbox1k[1])) / em;
  return Math.round(Math.max(MIN_WIDTH_EM, Math.min(MAX_WIDTH_EM, w)) * 10) / 10;
}

// 글자 줄 개수. rows[y] = { wide, segments }.
// 넓게 걸친 행(wide)이 minHeight~maxHeight 만큼 이어지고(더 높으면 그림 덩어리),
// 그 줄의 행들이 평균 minSegments 구간 이상으로 끊겨 있어야(글자 획) 한 줄로 센다. 도형 윤곽선은 2~4 구간이다.
export function countTextLines(rows, { minHeight = 3, maxHeight = Infinity, minSegments = 6 } = {}) {
  let lines = 0;
  let start = -1;
  let segSum = 0;
  for (let y = 0; y <= rows.length; y++) {
    const on = y < rows.length && rows[y].wide;
    if (on) {
      if (start < 0) {
        start = y;
        segSum = 0;
      }
      segSum += rows[y].segments;
    }
    if (!on && start >= 0) {
      const h = y - start;
      if (h >= minHeight && h <= maxHeight && segSum / h >= minSegments) lines++;
      start = -1;
    }
  }
  return lines;
}

/// 그림이 문항 영역 한쪽에 치우쳐 있으면 그림이 놓인 쪽('right'|'left'), 아니면 null.
export function figureSideCandidate(bbox1k, region1k) {
  if (!bboxInside(bbox1k, region1k)) return null;
  const [, fx1, , fx2] = bbox1k.map(Number);
  const [, rx1, , rx2] = region1k.map(Number);
  const rw = rx2 - rx1;
  if (rw <= 0 || (fx2 - fx1) / rw > 0.6) return null;
  const leftGap = (fx1 - rx1) / rw;
  const rightGap = (rx2 - fx2) / rw;
  if (leftGap >= 0.35 && leftGap > rightGap) return 'right';
  if (rightGap >= 0.35 && rightGap > leftGap) return 'left';
  return null;
}

/// 그림이 본문 아래에서 왼쪽에 붙어 있으면 'left', 오른쪽이면 'right', 아니면 'center'.
export function figureAnchor(bbox1k, region1k) {
  if (!bboxInside(bbox1k, region1k)) return 'center';
  const [, fx1, , fx2] = bbox1k.map(Number);
  const [, rx1, , rx2] = region1k.map(Number);
  const rw = rx2 - rx1;
  if (rw <= 0) return 'center';
  const leftGap = (fx1 - rx1) / rw;
  const rightGap = (rx2 - fx2) / rw;
  if (leftGap <= 0.2 && rightGap >= 0.3) return 'left';
  if (rightGap <= 0.2 && leftGap >= 0.3) return 'right';
  return 'center';
}

/// 그림 높이 구간에서 그림 반대편(본문이 흐를 자리)에 글자 줄이 있으면 inline-right/left, 아니면 below-stem.
/// 글자 줄은 잉크가 띠 폭의 30% 이상 걸치고 획이 여러 번 끊기는 낮은 행 묶음으로 센다(짧은 라벨·도형 윤곽 제외).
export async function detectFigurePosition(pagePng, bbox1k, region1k) {
  const side = figureSideCandidate(bbox1k, region1k);
  if (!side || !Buffer.isBuffer(pagePng)) return 'below-stem';
  const meta = await sharp(pagePng).metadata();
  const W = Number(meta.width || 0);
  const H = Number(meta.height || 0);
  if (!(W > 0 && H > 0)) return 'below-stem';
  const [fy1, fx1, fy2, fx2] = bbox1k.map(Number);
  const [, rx1, , rx2] = region1k.map(Number);
  const gap = 8; // 그림 테두리·라벨이 섞이지 않게 띄운다(0..1000)
  const sx1 = side === 'right' ? rx1 : fx2 + gap;
  const sx2 = side === 'right' ? fx1 - gap : rx2;
  const left = Math.max(0, Math.floor((sx1 / 1000) * W));
  const top = Math.max(0, Math.floor((fy1 / 1000) * H));
  const width = Math.min(W - left, Math.ceil(((sx2 - sx1) / 1000) * W));
  const height = Math.min(H - top, Math.ceil(((fy2 - fy1) / 1000) * H));
  if (width < 20 || height < 10) return 'below-stem';
  const { data, info } = await sharp(pagePng)
    .extract({ left, top, width, height })
    .greyscale()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const ch = info.channels || 1;
  const rows = [];
  for (let y = 0; y < info.height; y++) {
    let first = -1;
    let last = -1;
    let segments = 0;
    let prevInk = false;
    for (let x = 0; x < info.width; x++) {
      const ink = data[(y * info.width + x) * ch] < 140;
      if (ink && !prevInk) segments++;
      prevInk = ink;
      if (!ink) continue;
      if (first < 0) first = x;
      last = x;
    }
    rows.push({ wide: first >= 0 && last - first >= info.width * 0.3, segments });
  }
  // 본문 한 줄(분수 포함)은 쪽 높이의 3% 안쪽이다.
  if (countTextLines(rows, { maxHeight: Math.round(H * 0.03) }) < 1) return 'below-stem';
  return side === 'right' ? 'inline-right' : 'inline-left';
}

// 가로 2개 묶음 전체 폭 상한(em). V2 한 줄 폭을 넘으면 overfull 로 잘린다.
const MAX_GROUP_WIDTH_EM = 26;

const FIGURE_MARKER_RE = /\[그림\]|\[\[PB_FIG_[^\]]*\]\]/g;

/// 본문의 그림 표시 두 개 사이에 글(소문항 번호·문장 등)이 없어 한 줄에 나란히 둘 수 있는가.
/// 본문을 모르면 true(기존 동작). (나) 같은 짧은 그림 이름만 있으면 나란히 둔다.
/// 1) 아래 그림, 2) 아래 그림처럼 소문항 번호나 문장이 끼어 있으면 false.
export function figureMarkersSideBySide(stem) {
  if (typeof stem !== 'string' || !stem) return true;
  const parts = stem.split(FIGURE_MARKER_RE);
  if (parts.length !== 3) return true;
  const between = parts[1].replace(/\[문단\]|\\\\|\s/g, '');
  if (!between) return true;
  if (/\d+\)|[①-⑳]/.test(between)) return false;
  return between.length <= 4;
}

/// assets[].bbox_1k 와 교재 em1k 로 widthEm 을 정하고, 그림 1개면 positions[0]·문항 영역 기준 정렬을 쓴다.
/// 그림 3개 이상(그림 선지 등)은 렌더러가 widthEm 을 선지 배율로 해석하므로 기존 기본값을 유지한다.
export function buildPdfFigureLayout(assets, { em1k = null, positions = [], region1k = null, stem = null } = {}) {
  const rows = Array.isArray(assets) ? assets : [];
  const fromSource = rows.length <= 2;
  const widths = rows.map((asset) => (fromSource ? figureWidthEm(asset?.bbox_1k, em1k ?? DEFAULT_TEXT_EM_1K) : null));
  const sideBySide = rows.length === 2 && figureMarkersSideBySide(stem);
  if (sideBySide && widths.every((w) => w != null)) {
    const total = widths[0] + widths[1] + 0.5;
    if (total > MAX_GROUP_WIDTH_EM) {
      const s = (MAX_GROUP_WIDTH_EM - 0.5) / (widths[0] + widths[1]);
      for (let i = 0; i < 2; i++) widths[i] = Math.round(widths[i] * s * 10) / 10;
    }
  }
  const items = rows.map((asset, idx) => {
    const figureIndex = Number.isFinite(Number(asset?.figure_index)) && Number(asset.figure_index) > 0
      ? Number(asset.figure_index)
      : idx + 1;
    const widthEm = widths[idx] ?? (rows.length >= 2 ? 12.0 : 20.0);
    const position = rows.length === 1 && positions[idx] ? positions[idx] : 'below-stem';
    const anchor = position === 'inline-right'
      ? 'right'
      : position === 'inline-left'
        ? 'left'
        : rows.length === 1
        ? figureAnchor(asset?.bbox_1k, region1k)
        : 'center';
    return {
      assetKey: `idx:${figureIndex}`,
      widthEm,
      position,
      anchor,
      offsetXEm: 0,
      offsetYEm: 0,
    };
  });
  const groups = sideBySide
    ? [{ type: 'horizontal', members: items.map((item) => item.assetKey), gap: 0.5 }]
    : [];
  return { version: 1, items, groups };
}
