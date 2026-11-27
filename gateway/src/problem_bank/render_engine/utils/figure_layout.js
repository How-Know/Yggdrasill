const DEFAULT_STEM_SIZE_PT = 11.0;
const DEFAULT_MAX_HEIGHT_PT = 170;
const SCALE_MIN = 0.3;
const SCALE_MAX = 2.2;

function parseFigureLayout(question) {
  const meta = question?.meta && typeof question.meta === 'object' ? question.meta : {};
  const raw = meta.figure_layout;
  if (!raw || typeof raw !== 'object') return null;
  if (!Array.isArray(raw.items) || raw.items.length === 0) return null;
  const items = [];
  for (const item of raw.items) {
    if (!item || typeof item !== 'object') continue;
    const assetKey = String(item.assetKey || '').trim();
    if (!assetKey) continue;
    items.push({
      assetKey,
      widthEm: clampFinite(item.widthEm, 2, 50, 20),
      // inline-text(글 중간) 배치에서 본문 줄 높이에 맞춰 크기를 지정하는 값(em).
      // 다른 배치에서는 무시된다.
      heightEm: clampFinite(item.heightEm, 0.35, 8, 1.6),
      position: normalizePosition(item.position),
      anchor: normalizeAnchor(item.anchor),
      ...clampedOffsets(item, normalizePosition(item.position)),
      ...placementBoxFields(item),
      // 가로 묶음(groups) 안에서 그림 밑에 둘 설명 글. 묶음 밖에서는 무시된다.
      ...(typeof item.caption === 'string' && item.caption.trim() ? { caption: item.caption.trim() } : {}),
    });
  }
  if (items.length === 0) return null;
  const overrides = parseLayoutOverrides(raw.overrides);
  const groups = [];
  if (Array.isArray(raw.groups)) {
    for (const g of raw.groups) {
      if (!g || typeof g !== 'object') continue;
      const type = String(g.type || 'horizontal').trim();
      const members = Array.isArray(g.members)
        ? g.members.map((m) => String(m || '').trim()).filter(Boolean)
        : [];
      if (members.length < 2) continue;
      groups.push({
        type: type === 'vertical' ? 'vertical' : 'horizontal',
        members,
        gap: clampFinite(g.gap, 0, 5, 0.5),
      });
    }
  }
  return {
    version: Number(raw.version || 1),
    items,
    groups,
    ...(overrides ? { overrides } : {}),
  };
}

// ── 배치 상자 ─────────────────────────────────────────────────────────────
// 그림 한 장의 자리를 정하는 값 묶음(figure_layout.items 의 한 항목)을 배치 상자로 쓴다.
// 길이는 모두 본문 글자 크기 기준(em)이라 글자 크기가 다른 지면에서도 같은 비율로 놓인다.
// 아래 값들은 적혀 있을 때만 쓰이고, 없으면 예전과 똑같이 조판된다.
//   - gapEm     : 본문 옆(inline-left/right) 배치에서 본문과 그림 사이 간격.
//   - wrapLines : 본문 옆 배치에서 그림 옆으로 좁혀 찍는 본문 줄 수. 없으면 그림 높이로 잰다.
//   - reserveEm : 자유 배치(free)에서 그림 자리에 비워 둘 세로 길이. 0 이면 본문이 그림과 무관하게 흐른다.
// 자유 배치(position: 'free')는 그림 자리(마커)의 본문 왼쪽 끝에서 offsetXEm 만큼 오른쪽,
// offsetYEm 만큼 아래에 그림의 왼쪽 위를 놓는다. 본문 줄바꿈과 쪽 나눔을 바꾸지 않는다.
// 자유 배치는 지면 어디에나 놓을 수 있어야 하므로 이동 한계가 넓다(A4 한 쪽 높이가 약 80em).
const FREE_OFFSET_LIMIT_EM = 80;
const FLOW_OFFSET_LIMIT_EM = 20;

function clampedOffsets(item, position) {
  const limit = position === 'free' ? FREE_OFFSET_LIMIT_EM : FLOW_OFFSET_LIMIT_EM;
  return {
    offsetXEm: clampFinite(item.offsetXEm, -limit, limit, 0),
    offsetYEm: clampFinite(item.offsetYEm, -limit, limit, 0),
  };
}

function placementBoxFields(item) {
  const out = {};
  if (item.gapEm != null && Number.isFinite(Number(item.gapEm))) {
    out.gapEm = clampFinite(item.gapEm, 0, 5, 0.9);
  }
  if (item.wrapLines != null && Number.isFinite(Number(item.wrapLines))) {
    out.wrapLines = Math.round(clampFinite(item.wrapLines, 2, 16, 2));
  }
  if (item.reserveEm != null && Number.isFinite(Number(item.reserveEm))) {
    out.reserveEm = clampFinite(item.reserveEm, 0, 60, 0);
  }
  return out;
}

// 지면별 덮어쓰기: { '<지면 열쇠>': { items: [{ assetKey, 바꿀 값만 }] } }.
//   지면 열쇠는 'cols:2'(단 수), 'mock'(프로필), 'mock/2'(프로필/단 수). 뒤로 갈수록 우선한다.
function parseLayoutOverrides(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const out = {};
  for (const key of Object.keys(raw)) {
    const k = String(key).trim();
    const list = raw[key]?.items;
    if (!k || !Array.isArray(list)) continue;
    const items = [];
    for (const item of list) {
      if (!item || typeof item !== 'object') continue;
      const assetKey = String(item.assetKey || '').trim();
      if (!assetKey) continue;
      const patch = { assetKey };
      if (item.widthEm != null) patch.widthEm = clampFinite(item.widthEm, 2, 50, 20);
      if (item.heightEm != null) patch.heightEm = clampFinite(item.heightEm, 0.35, 8, 1.6);
      if (item.position != null) patch.position = normalizePosition(item.position);
      if (item.anchor != null) patch.anchor = normalizeAnchor(item.anchor);
      // 이동 값의 한계는 자리 종류에 따라 다르므로, 바탕 값과 합친 뒤(applyLayoutOverrides)에 다시 맞춘다.
      if (item.offsetXEm != null) patch.offsetXEm = clampFinite(item.offsetXEm, -FREE_OFFSET_LIMIT_EM, FREE_OFFSET_LIMIT_EM, 0);
      if (item.offsetYEm != null) patch.offsetYEm = clampFinite(item.offsetYEm, -FREE_OFFSET_LIMIT_EM, FREE_OFFSET_LIMIT_EM, 0);
      Object.assign(patch, placementBoxFields(item));
      items.push(patch);
    }
    if (items.length > 0) out[k] = { items };
  }
  return Object.keys(out).length > 0 ? out : null;
}

// 지금 조판하는 지면. 렌더러가 문서를 만들 때 정한다(withFigureLayoutContext).
let layoutContext = null;

/** [fn] 을 도는 동안 그림 배치가 이 지면({ profile, columns })의 덮어쓰기를 쓰게 한다. */
function withFigureLayoutContext(context, fn) {
  const previous = layoutContext;
  layoutContext = context && typeof context === 'object' ? context : null;
  try {
    return fn();
  } finally {
    layoutContext = previous;
  }
}

function layoutOverrideKeys(context) {
  if (!context) return [];
  const profile = String(context.profile || '').trim();
  const columns = Number.parseInt(String(context.columns ?? ''), 10);
  const keys = [];
  if (Number.isInteger(columns) && columns > 0) keys.push(`cols:${columns}`);
  if (profile) keys.push(profile);
  if (profile && Number.isInteger(columns) && columns > 0) keys.push(`${profile}/${columns}`);
  return keys;
}

function applyLayoutOverrides(layout, context) {
  if (!layout?.overrides) return layout;
  let items = layout.items;
  for (const key of layoutOverrideKeys(context)) {
    const patches = layout.overrides[key]?.items;
    if (!Array.isArray(patches)) continue;
    items = items.map((item) => {
      const patch = patches.find((p) => p.assetKey === item.assetKey);
      if (!patch) return item;
      const merged = { ...item, ...patch };
      return { ...merged, ...clampedOffsets(merged, merged.position) };
    });
  }
  return items === layout.items ? layout : { ...layout, items };
}

function convertLegacyToFigureLayout(question, stemSizePt) {
  const meta = question?.meta && typeof question.meta === 'object' ? question.meta : {};
  const size = Number.isFinite(stemSizePt) && stemSizePt > 0 ? stemSizePt : DEFAULT_STEM_SIZE_PT;

  const scalesRaw = meta.figure_render_scales;
  const scaleMap = {};
  if (scalesRaw && typeof scalesRaw === 'object') {
    for (const key of Object.keys(scalesRaw)) {
      const k = String(key).trim();
      if (!k) continue;
      const n = Number.parseFloat(String(scalesRaw[key]));
      if (Number.isFinite(n)) {
        scaleMap[k] = Math.max(SCALE_MIN, Math.min(SCALE_MAX, n));
      }
    }
  }

  const defaultScale = (() => {
    const n = Number.parseFloat(
      String(meta.figure_render_scale ?? meta.figureScale ?? meta.figure_scale ?? ''),
    );
    if (Number.isFinite(n)) return Math.max(SCALE_MIN, Math.min(SCALE_MAX, n));
    return 1.0;
  })();

  const figureAssets = Array.isArray(meta.figure_assets) ? meta.figure_assets : [];
  const byIndex = new Map();
  for (const asset of figureAssets) {
    const idx = asset?.figure_index ?? 0;
    const existing = byIndex.get(idx);
    if (!existing) {
      byIndex.set(idx, asset);
    } else {
      const ec = String(existing.created_at || '');
      const ac = String(asset.created_at || '');
      if (ac > ec) byIndex.set(idx, asset);
    }
  }
  const deduped = [...byIndex.values()].sort(
    (a, b) => (a.figure_index ?? 0) - (b.figure_index ?? 0),
  );

  if (deduped.length === 0) {
    const refCount = Array.isArray(question?.figure_refs) ? question.figure_refs.length : 0;
    if (refCount === 0) return null;
    const items = [];
    for (let i = 0; i < refCount; i++) {
      const key = `ord:${i + 1}`;
      const scale = scaleMap[key] ?? defaultScale;
      items.push({
        assetKey: key,
        widthEm: scaleToWidthEm(scale, size),
        position: 'below-stem',
        anchor: 'center',
        offsetXEm: 0,
        offsetYEm: 0,
      });
    }
    return { version: 1, items, groups: [] };
  }

  const items = [];
  for (let i = 0; i < deduped.length; i++) {
    const asset = deduped[i];
    const key = figureScaleKeyForAsset(asset, i + 1);
    const scale = scaleMap[key] ?? scaleMap[`idx:${asset.figure_index ?? (i + 1)}`] ?? defaultScale;
    items.push({
      assetKey: key,
      widthEm: scaleToWidthEm(scale, size),
      position: 'below-stem',
      anchor: 'center',
      offsetXEm: 0,
      offsetYEm: 0,
    });
  }

  const groups = [];
  const pairsRaw = Array.isArray(meta.figure_horizontal_pairs) ? meta.figure_horizontal_pairs : [];
  for (const pair of pairsRaw) {
    if (!pair || typeof pair !== 'object') continue;
    const a = String(pair.a ?? pair.left ?? '').trim();
    const b = String(pair.b ?? pair.right ?? '').trim();
    if (!a || !b || a === b) continue;
    const aExists = items.some((it) => it.assetKey === a);
    const bExists = items.some((it) => it.assetKey === b);
    if (aExists && bExists) {
      groups.push({ type: 'horizontal', members: [a, b], gap: clampFinite(pair.gap, 0, 5, 0.5) });
    }
  }

  return { version: 1, items, groups };
}

// 그림 엔진으로 그린 그림은 본문 글자 크기에 맞춰 선 굵기와 글자 크기가 정해져 있다.
// 늘이거나 줄이면 그림 속 글자가 본문과 달라지므로, 저장된 widthEm 대신 그림의 제 크기로 찍는다.
// (그림 자리·정렬·이동 값은 저장된 그대로 쓴다. 크기를 바꾸려면 그림 파일의 값을 고친다.)
//   렌더러가 엔진 그림을 받아 두면 question.figure_local_infos[i].engineFigure 에 제 크기가 적힌다.
function applyEngineFigureSizes(layout, question) {
  const infos = Array.isArray(question?.figure_local_infos) ? question.figure_local_infos : [];
  let items = null;
  for (let i = 0; i < infos.length; i += 1) {
    const info = infos[i];
    const widthEm = Number(info?.engineFigure?.widthEm);
    const heightEm = Number(info?.engineFigure?.heightEm);
    if (!Number.isFinite(widthEm) || widthEm <= 0) continue;
    if (!items) items = Array.isArray(layout?.items) ? [...layout.items] : [];
    const size = {
      widthEm: clampFinite(widthEm, 2, 50, 20),
      ...(Number.isFinite(heightEm) && heightEm > 0 ? { heightEm: clampFinite(heightEm, 0.35, 8, 1.6) } : {}),
    };
    // 그림과 배치 값을 잇는 순서는 렌더러(layoutForIndex)와 같다: assetKey → ord:N → idx:N.
    const keys = [
      String(info.assetKey || ''),
      `ord:${i + 1}`,
      info.figureIndex ? `idx:${info.figureIndex}` : '',
    ].filter(Boolean);
    let at = -1;
    for (const key of keys) {
      at = items.findIndex((item) => item.assetKey === key);
      if (at >= 0) break;
    }
    if (at >= 0) {
      items[at] = { ...items[at], ...size };
    } else {
      items.push({
        assetKey: keys[0],
        position: 'below-stem',
        anchor: 'center',
        offsetXEm: 0,
        offsetYEm: 0,
        ...size,
      });
    }
  }
  if (!items) return layout;
  return { version: 1, groups: [], ...(layout || {}), items };
}

function resolveFigureLayout(question, stemSizePt) {
  const explicit = parseFigureLayout(question);
  const layout = explicit
    ? applyLayoutOverrides(explicit, layoutContext)
    : convertLegacyToFigureLayout(question, stemSizePt);
  return applyEngineFigureSizes(layout, question);
}

function figureLayoutToWidthPt(widthEm, stemSizePt) {
  const size = Number.isFinite(stemSizePt) && stemSizePt > 0 ? stemSizePt : DEFAULT_STEM_SIZE_PT;
  return clampFinite(widthEm, 2, 50, 20) * size;
}

function scaleToWidthEm(scale, stemSizePt) {
  const size = Number.isFinite(stemSizePt) && stemSizePt > 0 ? stemSizePt : DEFAULT_STEM_SIZE_PT;
  const safeScale = Math.max(SCALE_MIN, Math.min(SCALE_MAX, Number(scale) || 1));
  const maxHeightPt = DEFAULT_MAX_HEIGHT_PT * safeScale;
  return Math.round((maxHeightPt / size) * 100) / 100;
}

function widthEmToScale(widthEm, stemSizePt) {
  const size = Number.isFinite(stemSizePt) && stemSizePt > 0 ? stemSizePt : DEFAULT_STEM_SIZE_PT;
  const widthPt = clampFinite(widthEm, 2, 50, 20) * size;
  const scale = widthPt / DEFAULT_MAX_HEIGHT_PT;
  return Math.max(SCALE_MIN, Math.min(SCALE_MAX, Math.round(scale * 100) / 100));
}

function figureScaleKeyForAsset(asset, order = 1) {
  const idx = Number.parseInt(String(asset?.figure_index ?? ''), 10);
  if (Number.isFinite(idx) && idx > 0) return `idx:${idx}`;
  const p = String(asset?.path || '').trim();
  if (p) return `path:${p}`;
  return `ord:${Math.max(1, Number(order || 1))}`;
}

function clampFinite(value, min, max, fallback) {
  const n = Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(max, n));
}

function normalizePosition(pos) {
  const s = String(pos || '').trim().toLowerCase();
  // below-choices: 선지 아래 그림(원본이 "본문 → 선지 → 그림" 순서). V2 엔진만 선지 뒤에 찍고, 다른 엔진은 본문 아래 그림으로 찍는다.
  // free: 자유 배치. V2 엔진만 본문 흐름과 무관하게 놓고, 다른 엔진은 본문 아래 그림으로 찍는다.
  const valid = ['below-stem', 'inline-right', 'inline-left', 'inline-text', 'between-stem-choices', 'above-choices', 'below-choices', 'free'];
  return valid.includes(s) ? s : 'below-stem';
}

function normalizeAnchor(anchor) {
  const s = String(anchor || '').trim().toLowerCase();
  const valid = ['center', 'left', 'right', 'top'];
  return valid.includes(s) ? s : 'center';
}

export {
  parseFigureLayout,
  convertLegacyToFigureLayout,
  resolveFigureLayout,
  withFigureLayoutContext,
  applyLayoutOverrides,
  applyEngineFigureSizes,
  figureLayoutToWidthPt,
  scaleToWidthEm,
  widthEmToScale,
  figureScaleKeyForAsset,
  normalizePosition,
  normalizeAnchor,
  DEFAULT_STEM_SIZE_PT,
  DEFAULT_MAX_HEIGHT_PT,
};
