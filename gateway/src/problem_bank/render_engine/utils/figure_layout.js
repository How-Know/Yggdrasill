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
      position: normalizePosition(item.position),
      anchor: normalizeAnchor(item.anchor),
      offsetXEm: clampFinite(item.offsetXEm, -20, 20, 0),
      offsetYEm: clampFinite(item.offsetYEm, -20, 20, 0),
    });
  }
  if (items.length === 0) return null;
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
  return { version: Number(raw.version || 1), items, groups };
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
      groups.push({ type: 'horizontal', members: [a, b], gap: 0.5 });
    }
  }

  return { version: 1, items, groups };
}

function resolveFigureLayout(question, stemSizePt) {
  const explicit = parseFigureLayout(question);
  if (explicit) return explicit;
  return convertLegacyToFigureLayout(question, stemSizePt);
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
  const valid = ['below-stem', 'inline-right', 'inline-left', 'between-stem-choices', 'above-choices'];
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
  figureLayoutToWidthPt,
  scaleToWidthEm,
  widthEmToScale,
  figureScaleKeyForAsset,
  normalizePosition,
  normalizeAnchor,
  DEFAULT_STEM_SIZE_PT,
  DEFAULT_MAX_HEIGHT_PT,
};
