function toSafeInt(raw, fallback = 0) {
  const parsed = Number.parseInt(String(raw ?? ''), 10);
  if (!Number.isFinite(parsed)) return fallback;
  return parsed;
}

function normalizeLayoutMode(raw) {
  const mode = String(raw || '').trim().toLowerCase();
  if (mode === 'custom_columns' || mode === 'custom-columns' || mode === 'custom') {
    return 'custom_columns';
  }
  return 'legacy';
}

function normalizePairAlignMode(raw) {
  const mode = String(raw || '').trim().toLowerCase();
  if (mode === 'none') return 'none';
  return 'row';
}

function normalizeAnchorPage(raw) {
  const page = String(raw || '').trim().toLowerCase();
  if (!page || page === 'first' || page === '1') return 'first';
  if (page === 'all' || page === 'every') return 'all';
  const numeric = toSafeInt(page, 0);
  if (numeric >= 1) return numeric;
  return 'first';
}

function shouldApplyAnchorOnPage(anchorPage, pageIndex) {
  if (anchorPage === 'all') return true;
  if (anchorPage === 'first') return pageIndex === 0;
  if (Number.isFinite(anchorPage) && anchorPage >= 1) {
    return pageIndex + 1 === anchorPage;
  }
  return pageIndex === 0;
}

function normalizeColumnCounts(rawCounts, layoutColumns, perPage) {
  if (!Array.isArray(rawCounts)) return null;
  const columns = Math.max(1, toSafeInt(layoutColumns, 1));
  const counts = rawCounts
    .slice(0, columns)
    .map((one) => toSafeInt(one, 0));
  if (counts.length !== columns) return null;
  if (counts.some((one) => one < 0)) return null;
  if (counts.every((one) => one === 0)) return null;
  const total = counts.reduce((sum, one) => sum + one, 0);
  if (total !== perPage) return null;
  return counts;
}

function resolveLegacyColumnCounts(layoutColumns, perPage) {
  if (layoutColumns === 2 && perPage === 4) return [2, 2];
  return null;
}

function normalizeAnchors(rawAnchors, columns) {
  if (!Array.isArray(rawAnchors)) return [];
  const maxColumns = Math.max(1, toSafeInt(columns, 1));
  const anchors = [];
  for (const one of rawAnchors) {
    if (!one || typeof one !== 'object') continue;
    const columnIndex = toSafeInt(one.columnIndex, -1);
    if (columnIndex < 0 || columnIndex >= maxColumns) continue;
    const label = String(one.label || one.text || '').replace(/\s+/g, ' ').trim();
    if (!label) continue;
    const topPt = Number(one.topPt);
    const paddingTopPt = Number(one.paddingTopPt);
    anchors.push({
      columnIndex,
      label,
      page: normalizeAnchorPage(one.page),
      topPt: Number.isFinite(topPt) ? topPt : 9.2,
      paddingTopPt: Number.isFinite(paddingTopPt) ? paddingTopPt : 35.8,
    });
  }
  return anchors;
}

function defaultFirstPageAnchors({ profile, pageIndex, layoutColumns, perPage }) {
  const isMock = profile === 'mock' || profile === 'csat';
  if (!isMock || pageIndex !== 0) return [];
  if (layoutColumns !== 2 || perPage < 1) return [];
  return [
    {
      columnIndex: 0,
      label: '5지선다형',
      page: 'first',
      topPt: 16,
      paddingTopPt: 27,
    },
  ];
}

function resolveColumnQuestionCounts({
  layoutMode,
  layoutColumns,
  perPage,
  columnQuestionCounts,
}) {
  const normalizedMode = normalizeLayoutMode(layoutMode);
  if (normalizedMode === 'custom_columns') {
    const custom = normalizeColumnCounts(columnQuestionCounts, layoutColumns, perPage);
    if (custom) return custom;
  }
  return resolveLegacyColumnCounts(layoutColumns, perPage);
}

export function buildSlotPlan({
  layoutMode,
  layoutColumns,
  perPage,
  chunkLength,
  columnQuestionCounts,
  columnLabelAnchors,
  alignPolicy,
  profile,
  pageIndex = 0,
}) {
  const safeColumns = Math.max(1, toSafeInt(layoutColumns, 1));
  const safePerPage = Math.max(1, toSafeInt(perPage, 1));
  const safeChunkLength = Math.max(0, toSafeInt(chunkLength, 0));
  const resolvedCounts = resolveColumnQuestionCounts({
    layoutMode,
    layoutColumns: safeColumns,
    perPage: safePerPage,
    columnQuestionCounts,
  });
  if (!resolvedCounts) return null;

  const rowCount = Math.max(1, ...resolvedCounts);
  const normalizedAnchors = normalizeAnchors(columnLabelAnchors, safeColumns);
  const anchorsToUse = normalizedAnchors.length > 0
    ? normalizedAnchors
    : defaultFirstPageAnchors({
      profile,
      pageIndex,
      layoutColumns: safeColumns,
      perPage: safePerPage,
    });
  const anchorByKey = new Map();
  for (const anchor of anchorsToUse) {
    if (!shouldApplyAnchorOnPage(anchor.page, pageIndex)) continue;
    const columnIndex = anchor.columnIndex;
    if (!Number.isFinite(columnIndex) || columnIndex < 0 || columnIndex >= safeColumns) continue;
    if (resolvedCounts[columnIndex] <= 0) continue;
    // Current contract: label anchor is always attached to the top question slot of a column.
    const rowIndex = 0;
    const key = `${rowIndex}:${columnIndex}`;
    if (!anchorByKey.has(key)) anchorByKey.set(key, anchor);
  }

  const slotQuestionOrderByColumn = Array.from({ length: safeColumns }, () => []);
  let questionOrder = 0;
  for (let col = 0; col < safeColumns; col += 1) {
    for (let row = 0; row < resolvedCounts[col]; row += 1) {
      slotQuestionOrderByColumn[col][row] = questionOrder;
      questionOrder += 1;
    }
  }

  const rowHasAnchor = Array.from({ length: rowCount }, () => false);
  const slots = [];
  for (let row = 0; row < rowCount; row += 1) {
    for (let col = 0; col < safeColumns; col += 1) {
      const expectsQuestion = row < resolvedCounts[col];
      const slotQuestionOrder = expectsQuestion
        ? slotQuestionOrderByColumn[col][row]
        : null;
      const hasQuestion = expectsQuestion
        && Number.isFinite(slotQuestionOrder)
        && slotQuestionOrder < safeChunkLength;
      const anchor = anchorByKey.get(`${row}:${col}`) || null;
      if (anchor) rowHasAnchor[row] = true;
      slots.push({
        slotIndex: slots.length,
        row: row + 1,
        col: col + 1,
        columnIndex: col,
        rowIndex: row,
        expectsQuestion,
        hasQuestion,
        isHiddenPlaceholder: !expectsQuestion,
        questionOrder: Number.isFinite(slotQuestionOrder) ? slotQuestionOrder : null,
        anchorLabel: anchor?.label || '',
        anchorTopPt: anchor?.topPt ?? 9.2,
        anchorPaddingTopPt: anchor?.paddingTopPt ?? 35.8,
      });
    }
  }

  for (const slot of slots) {
    slot.rowHasAnchor = rowHasAnchor[slot.rowIndex] === true;
  }

  return {
    columns: safeColumns,
    rowCount,
    columnQuestionCounts: resolvedCounts,
    pairAlignMode: normalizePairAlignMode(alignPolicy?.pairAlignment),
    skipAnchorRows: alignPolicy?.skipAnchorRows !== false,
    slots,
  };
}
