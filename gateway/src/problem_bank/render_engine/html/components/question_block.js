import { composeLineV1, composeLinesV1 } from '../line_composer.js';
import {
  renderChoiceItem,
  chooseLayout,
  renderChoiceContainer,
  isBlankChoiceQuestion,
  renderBlankChoiceContainer,
  isImageChoiceQuestion,
  renderImageChoiceContainer,
} from './choice_block.js';
import {
  escapeHtml,
  isFractionLatex,
  normalizeMathLatex,
  applyInlineAlignmentMarkers,
  splitByUnderlineMarkers,
} from '../../utils/text.js';
import { resolveFigureLayout } from '../../utils/figure_layout.js';

// TODO(html-table): HTML 렌더러는 `[표행]/[표셀]` (구조화 표) 및 `[표시작]/[표끝]` (raw
// tabular) 마커를 아직 처리하지 않는다. XeLaTeX 엔진에는 meta.table_scales /
// meta.table_scale_default 기반의 가로·세로 독립 스케일이 구현돼 있으며, HTML 렌더러도
// 동일한 기능을 붙여야 매니저 HTML 프리뷰에서 표 크기가 반영된다. 추후 턴에서
//   1) stem 세그먼트 파싱에 표 경계 감지 추가
//   2) 구조화 표는 <table> + style 로, raw tabular 는 대응 HTML 렌더 (혹은 KaTeX 의
//      \begin{array} 경로 활용) 로 변환
//   3) 스케일은 CSS transform: scale(Sw, Sh) 또는 width/height 비율로 적용
// 순서로 확장한다. 현재는 XeLaTeX 전용 기능.

// `[문단]` 및 속성부 변형(`[문단:가운데]` 등) 을 strip 대상으로 함께 인식.
// 속성부는 applyInlineAlignmentMarkers 가 stemLineAligns 로 옮긴 뒤
// plain `[문단]` 으로 정규화하지만, safety net 으로 여기서도 속성 변형을 매칭한다.
const STRUCTURAL_STRIP = /\[문단(?::[^\]]*)?\]/g;
const BOX_START = /\[박스시작\]/;
const BOX_END = /\[박스끝\]/;
const BOGI_RE = /<\s*보\s*기\s*>/;
const BOX_ALIGN_MARKER_RE = /^\s*\[(?:정렬|align)\s*:\s*(왼쪽|좌측|left|가운데|중앙|center|오른쪽|우측|right)\]\s*$/i;
// 본문 그림 마커 정규식.
//   - plain: [그림], [도형], [도표], [표]
//   - HWPX binaryItemIDRef 토큰: [[PB_FIG_<itemID>]]
//   capture group 1 값이 있으면 itemID. 없으면 plain 마커.
const FIGURE_MARKER_RE = /\[\[PB_FIG_([^\]]+)\]\]|\[(?:그림|도형|도표|표)\]/g;

function stripImageChoiceFigureMarkers(stem) {
  return String(stem || '')
    .replace(FIGURE_MARKER_RE, '')
    .replace(/^\s*\[문단(?::[^\]]*)?\]\s*$/gm, '')
    .replace(/[ \t]+\n/g, '\n')
    .replace(/\n{2,}/g, '\n')
    .trim();
}
const BOGI_ITEM_SPLIT_RE =
  /(?=(?:[ㄱ-ㅎ]\.\s|(?:\(|（)\s*[가나다라마바사아자차카타파하]\s*(?:\)|）)\s))/;
const BOGI_ITEM_RE =
  /^(?:([ㄱ-ㅎ])\.\s*|(?:\(|（)\s*([가나다라마바사아자차카타파하])\s*(?:\)|）)\s*)/;
const BULLET_LINE_RE = /^\s*\\bullet\b\s*/;
const PARAGRAPH_MARKER_LINE_RE = /^\s*\[문단(?::[^\]]*)?\]\s*$/;

function cleanLine(line) {
  return line
    .replace(STRUCTURAL_STRIP, ' ')
    .replace(BOX_START, '')
    .replace(BOX_END, '')
    .replace(FIGURE_MARKER_RE, '')
    .replace(/\s+/g, ' ')
    .trim();
}

/**
 * 본문 그림 마커를 {{FIG_N}} 플레이스홀더로 치환한다.
 *   - [[PB_FIG_<id>]] 토큰은 itemIdToFigIdx 룩업으로 직접 지정 인덱스를 쓴다.
 *   - plain [그림]/[도형]/... 는 positional: startIndex 부터 1씩 증가하며 consumed 를 피해 간다.
 *   - 같은 index 가 이미 consumed 에 있으면 (token 경로로 선점) positional 은 건너뛴다.
 * @returns { text, count, nextPosIdx } — count 는 이번 호출에서 치환된 마커 총 개수.
 */
function replaceMarkersWithPlaceholders(
  line,
  startIndex,
  itemIdToFigIdx = null,
  consumed = null,
) {
  let posIdx = startIndex;
  let count = 0;
  const consumedSet = consumed || new Set();
  const text = line.replace(FIGURE_MARKER_RE, (_m, capturedId) => {
    const trimmedId = capturedId ? String(capturedId).trim() : '';
    if (trimmedId && itemIdToFigIdx && itemIdToFigIdx.has(trimmedId)) {
      const i = itemIdToFigIdx.get(trimmedId);
      consumedSet.add(i);
      count += 1;
      return `{{FIG_${i}}}`;
    }
    while (consumedSet.has(posIdx)) posIdx += 1;
    const pos = posIdx;
    consumedSet.add(pos);
    posIdx += 1;
    count += 1;
    return `{{FIG_${pos}}}`;
  });
  return { text, count, nextPosIdx: posIdx };
}

function buildSingleFigureHtml(url, layoutItem) {
  if (!url) return '';
  const w = layoutItem?.widthEm;
  const anchor = layoutItem?.anchor || 'center';
  const position = layoutItem?.position || 'below-stem';
  const posClass = `figure-pos-${position}`;
  const anchorClass = `figure-anchor-${anchor}`;
  const widthStyle = w ? `width:${w}em;max-width:100%;` : 'max-width:100%;';
  return `<div class="figure-inline-block ${posClass} ${anchorClass}">`
    + `<img class="figure-img" src="${url}" style="${widthStyle}" />`
    + `</div>`;
}

function buildGroupFigureHtml(members, dataUrls, layoutItems, gapEm) {
  const innerHtml = members
    .map((idx) => {
      const url = dataUrls[idx];
      if (!url) return '';
      const item = layoutItems ? layoutItems[idx] : null;
      const w = item?.widthEm;
      const style = w ? `flex:0 0 ${w}em;max-width:${w}em;` : '';
      return `<div class="figure-layout-item" style="${style}">`
        + `<img class="figure-img" src="${url}" />`
        + `</div>`;
    })
    .join('');
  return `<div class="figure-inline-block figure-group-horizontal" style="gap:${gapEm}em;">${innerHtml}</div>`;
}

function replacePlaceholdersWithImages(html, dataUrls, layoutItems, figureLayout) {
  const groups = figureLayout?.groups || [];
  const indexToGroup = new Map();
  for (const group of groups) {
    if (group.type !== 'horizontal') continue;
    const memberIndices = [];
    for (const memberKey of group.members) {
      const idx = layoutItems.findIndex((it) => it.assetKey === memberKey);
      if (idx >= 0) memberIndices.push(idx);
    }
    if (memberIndices.length >= 2) {
      for (const idx of memberIndices) {
        indexToGroup.set(idx, { indices: memberIndices, gap: group.gap ?? 0.5 });
      }
    }
  }

  const rendered = new Set();
  const replaced = html.replace(/\{\{FIG_(\d+)\}\}/g, (_, numStr) => {
    const idx = parseInt(numStr, 10);
    if (rendered.has(idx)) return '';
    rendered.add(idx);

    const groupInfo = indexToGroup.get(idx);
    if (groupInfo && idx === groupInfo.indices[0]) {
      groupInfo.indices.forEach((i) => rendered.add(i));
      return buildGroupFigureHtml(groupInfo.indices, dataUrls, layoutItems, groupInfo.gap);
    }
    if (groupInfo) return '';

    const url = dataUrls[idx];
    if (!url) return '';
    const item = layoutItems ? layoutItems[idx] : null;
    return buildSingleFigureHtml(url, item);
  });

  // HTML 스펙상 <span>(inline) 안에 <div>(block)가 들어가면 브라우저가 파싱
  // 단계에서 <div>를 <span> 바깥으로 끌어올린다(tag hoisting). 그 결과
  // <div class="bogi-content"> 안의 `<span class="lc-line">...<div class="figure-inline-block">...</div>...</span>`
  // 구조가 풀리면서 figure가 박스(.bogi-box) 바깥으로 튀어나와 보이는 문제가 있다.
  // 사전에 "span 안에 단독 figure block만 있는 경우"를 감지해 span 래퍼를 벗겨내고,
  // 대신 `<div class="lc-figure-line">`로 감싸 박스 내부 블록으로 유지한다.
  return liftFigureOutOfInlineSpan(replaced);
}

function liftFigureOutOfInlineSpan(html) {
  // <span class="lc-line ..."> (figure 단독 또는 [공백/whitespace 포함]) </span>
  // 패턴에서 figure만 남기고 span 래퍼 제거 → 블록 컨테이너로 대체.
  // 다른 inline 컨텐츠(수식/텍스트)와 섞여 있으면 건드리지 않는다.
  const spanRe =
    /<span class="lc-line(?:\s[^"]*)?" data-lc-profile="[^"]*">([\s\S]*?)<\/span>/g;
  return html.replace(spanRe, (match, inner) => {
    const trimmed = String(inner || '').trim();
    if (!trimmed) return match;
    // figure block만 포함하고 다른 inline 텍스트가 없는지 검사
    const figureOnlyRe =
      /^(?:<div class="figure-(?:inline-block|container|group-horizontal)[\s\S]*?<\/div>)+$/;
    if (!figureOnlyRe.test(trimmed)) return match;
    return `<div class="lc-figure-line">${trimmed}</div>`;
  });
}

function augmentEquations(equations, texts, { includeVars = false, includeNumbers = false } = {}) {
  const base = Array.isArray(equations) ? equations : [];
  const seen = new Set(base.map((eq) => String(eq?.latex || '').trim()).filter(Boolean));
  const extra = [];
  const sources = Array.isArray(texts) ? texts : [texts];
  for (const text of sources) {
    const src = String(text || '');
    if (includeVars) {
      for (const m of src.matchAll(/\b[a-z]\b/g)) {
        if (!seen.has(m[0])) { seen.add(m[0]); extra.push({ raw: m[0], latex: m[0], mathml: '', confidence: 0.5 }); }
      }
    }
    if (includeNumbers) {
      for (const m of src.matchAll(/\b\d+(?:\.\d+)?\b/g)) {
        if (!seen.has(m[0])) { seen.add(m[0]); extra.push({ raw: m[0], latex: m[0], mathml: '', confidence: 0.5 }); }
      }
    }
  }
  return extra.length > 0 ? [...base, ...extra] : base;
}

function renderOneLine(text, mathRenderer, equations, opts) {
  if (!text) return null;
  if (looksNumericMathOnlyLine(text)) {
    const forced = renderForcedMathLine(text, mathRenderer, opts);
    if (forced) return forced;
  }
  if (String(text).includes('[밑줄]')) {
    const parts = splitByUnderlineMarkers(text);
    const renderedParts = [];
    let hasFraction = false;
    for (const part of parts) {
      const value = String(part.value || '');
      if (!value) continue;
      const augmented = augmentEquations(equations, value, { includeVars: true });
      const rendered = composeLineV1(value, mathRenderer, augmented, opts);
      if (rendered.hasFraction) hasFraction = true;
      if (part.type === 'underline') {
        renderedParts.push(`<span class="pb-underline">${rendered.html}</span>`);
      } else {
        renderedParts.push(rendered.html);
      }
    }
    return {
      html: renderedParts.join(''),
      hasFraction,
    };
  }
  const augmented = augmentEquations(equations, text, { includeVars: true });
  const rendered = composeLineV1(text, mathRenderer, augmented, opts);
  return {
    html: rendered.html,
    hasFraction: rendered.hasFraction,
  };
}

function normalizeLineAlign(value) {
  const raw = String(value || '').trim().toLowerCase();
  if (raw === 'force-left') return 'force-left';
  if (raw === 'center' || raw === 'right' || raw === 'justify') return raw;
  return 'left';
}

function normalizeStemLineAligns(rawAligns, lineCount) {
  const src = Array.isArray(rawAligns) ? rawAligns : [];
  const out = [];
  for (let i = 0; i < lineCount; i += 1) {
    out.push(normalizeLineAlign(src[i]));
  }
  return out;
}

function looksNumericMathOnlyLine(text) {
  const src = String(text || '').trim();
  if (!src) return false;
  if (/[가-힣]/.test(src)) return false;
  const withoutCommands = src.replace(/\\[A-Za-z]+/g, ' ');
  if (!/[0-9]/.test(withoutCommands)) return false;
  if (/[A-Za-z]/.test(withoutCommands)) return false;
  return /^[0-9\s+\-*/=<>(),.\\{}_^|[\]:A-Za-z]+$/.test(src);
}

function renderForcedMathLine(text, mathRenderer, opts) {
  const latex = normalizeMathLatex(text);
  if (!latex) return null;
  const rendered = mathRenderer.renderInline(latex);
  if (!rendered?.ok || !rendered?.svg) return null;
  const hasFraction = isFractionLatex(latex);
  const profile = hasFraction ? 'fraction' : 'normal';
  const klass = hasFraction ? 'math-inline fraction' : 'math-inline';
  const dot = opts?.debugDots ? '<span class="math-debug-dot dot-forced"></span>' : '';
  return {
    html: `<span class="lc-line lc-${profile}" data-lc-profile="${profile}"><span class="${klass}" data-latex="${escapeHtml(latex)}" data-render-path="forced">${rendered.svg}${dot}</span></span>`,
    hasFraction,
  };
}


function looksCenterAlignedMathOnlyLine(text) {
  const src = String(text || '').trim();
  if (!src) return false;
  if (/[가-힣]/.test(src)) return false;
  if (/^[\[\]<>]+$/.test(src)) return false;
  const hasMathLike =
    /\\(?:frac|dfrac|tfrac|sqrt|times|div|cdot|left|right|le|ge|ne)\b/.test(src)
    || /[\d+\-*/=<>(),.]/.test(src);
  if (!hasMathLike) return false;
  // 숫자/수식/콤마 나열형 줄은 보통 박스 중앙 정렬로 렌더링
  return /^[\d\s+\-*/=<>(),.\\{}_^|[\]]+$/.test(src);
}

function splitBogiItemsFromText(text) {
  const cleaned = text.replace(BOGI_RE, '').trim();
  if (!cleaned) return [];
  const parts = cleaned.split(BOGI_ITEM_SPLIT_RE).filter(Boolean);
  const items = [];
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i].trim();
    if (!part) continue;
    if (/^[ㄱ-ㅎ]$/.test(part) && i + 1 < parts.length) continue;
    if (/^[가나다라마바사아자차카타파하]$/.test(part) && i + 1 < parts.length) continue;
    items.push(part);
  }
  return items;
}

function sectionLabelForBogiPart(part) {
  const text = String(part || '').trim();
  if (BULLET_LINE_RE.test(text)) {
    return { labelHtml: '&bull;', content: text.replace(BULLET_LINE_RE, '').trim() };
  }
  const match = text.match(BOGI_ITEM_RE);
  if (!match) return null;
  const consonantLabel = match[1] || '';
  const syllableLabel = match[2] || '';
  const label = consonantLabel || syllableLabel;
  const labelText = consonantLabel ? `${label}.` : `(${label})`;
  return {
    labelHtml: escapeHtml(labelText),
    content: text.slice(match[0].length).trim(),
  };
}

function renderBogiItems(lines, mathRenderer, equations, opts) {
  const allParts = [];
  let hasFraction = false;
  let forcedBoxAlign = '';
  for (const line of lines) {
    const lineText =
      typeof line === 'string' ? line : String(line?.text || '');
    const alignMarker = lineText.match(BOX_ALIGN_MARKER_RE);
    if (alignMarker) {
      const rawAlign = String(alignMarker[1] || '').trim().toLowerCase();
      forcedBoxAlign =
        rawAlign === '왼쪽' || rawAlign === '좌측' || rawAlign === 'left'
          ? 'force-left'
          : normalizeLineAlign(rawAlign);
      continue;
    }
    const lineAlign = forcedBoxAlign || normalizeLineAlign(line?.align);
    const items = splitBogiItemsFromText(lineText);
    if (items.length > 0) {
      allParts.push(
        ...items.map((text) => ({
          text,
          align: lineAlign,
        })),
      );
    } else {
      if (PARAGRAPH_MARKER_LINE_RE.test(lineText)) {
        allParts.push({ paragraph: true });
        continue;
      }
      const clean = lineText.replace(BOGI_RE, '').trim();
      if (clean) {
        allParts.push({
          text: clean,
          align: lineAlign,
        });
      }
    }
  }

  const result = [];
  let activeLabelHtml = '';
  for (const one of allParts) {
    if (one?.paragraph) {
      result.push('<div class="bogi-paragraph-gap"></div>');
      activeLabelHtml = '';
      continue;
    }
    const part = String(one?.text || '');
    const lineAlign = normalizeLineAlign(one?.align);
    const sectionLabel = sectionLabelForBogiPart(part);
    if (sectionLabel) {
      activeLabelHtml = sectionLabel.labelHtml;
      const text = sectionLabel.content;
      const bogiEqs = augmentEquations(equations, text, { includeVars: true, includeNumbers: true });
      const rendered = renderOneLine(text, mathRenderer, bogiEqs, opts);
      if (!rendered) continue;
      if (rendered.hasFraction) hasFraction = true;
      const alignClass =
        lineAlign === 'left' || lineAlign === 'force-left'
          ? ''
          : ` bogi-item-${lineAlign}`;
      result.push(
        `<div class="bogi-item${alignClass}"><span class="bogi-item-label">${activeLabelHtml}</span><span class="bogi-item-text">${rendered.html}</span></div>`,
      );
    } else {
      const bogiEqs = augmentEquations(equations, part, { includeVars: true, includeNumbers: true });
      const r = renderOneLine(part, mathRenderer, bogiEqs, opts);
      if (r) {
        if (r.hasFraction) hasFraction = true;
        const forceLeft = lineAlign === 'force-left';
        if (
          activeLabelHtml &&
          (lineAlign === 'left' || forceLeft) &&
          (forceLeft || !looksCenterAlignedMathOnlyLine(part))
        ) {
          result.push(
            `<div class="bogi-item bogi-item-continuation"><span class="bogi-item-label bogi-item-label-placeholder" aria-hidden="true">${activeLabelHtml}</span><span class="bogi-item-text">${r.html}</span></div>`,
          );
          continue;
        }
        let alignClass = '';
        if (forceLeft) {
          alignClass = '';
        } else if (lineAlign !== 'left') {
          alignClass = ` bogi-line-${lineAlign}`;
        } else if (looksCenterAlignedMathOnlyLine(part)) {
          alignClass = ' bogi-line-center';
        }
        result.push(`<div class="bogi-line${alignClass}">${r.html}</div>`);
      }
    }
  }
  return {
    html: result.join(''),
    hasFraction,
  };
}

function countFigureMarkers(stem) {
  const m = stem.match(FIGURE_MARKER_RE);
  return m ? m.length : 0;
}

function cleanLineKeepingPlaceholders(line) {
  return line
    .replace(STRUCTURAL_STRIP, ' ')
    .replace(BOX_START, '')
    .replace(BOX_END, '')
    .replace(/\s+/g, ' ')
    .trim();
}

function renderStemWithBoxes(stem, mathRenderer, equations, {
  dataUrls = [],
  layoutItems = [],
  figureLayout = null,
  stemLineAligns = [],
  figureItemIds = [],
  debugDots = false,
} = {}) {
  const opts = debugDots ? { debugDots: true } : undefined;
  const totalMarkers = countFigureMarkers(stem);
  const hasInlineFigures = totalMarkers > 0 && dataUrls.length > 0;

  const lines = String(stem || '')
    .replace(/\r/g, '')
    .split('\n');
  const lineAligns = normalizeStemLineAligns(stemLineAligns, lines.length);
  const blocks = [];
  let hasFraction = false;
  let inBox = false;
  let boxLines = [];
  let inlineBuffer = [];
  let figureCounter = 0;

  // HWPX binaryItemIDRef → dataUrls 인덱스 룩업.
  //   figureItemIds[i] 가 비어있지 않으면 해당 itemId 가 i 번 dataUrl 을 가리킨다.
  //   본문에 [[PB_FIG_<id>]] 토큰이 등장하면 이 맵으로 직접 {{FIG_i}} 플레이스홀더로 연결된다.
  const itemIdToFigIdx = new Map();
  if (Array.isArray(figureItemIds)) {
    for (let i = 0; i < figureItemIds.length; i += 1) {
      const id = String(figureItemIds[i] || '').trim();
      if (id && !itemIdToFigIdx.has(id)) itemIdToFigIdx.set(id, i);
    }
  }
  // 라인 간 공유되는 consumed 집합. token 경로가 선점한 인덱스를 positional 이 재사용하지 않도록.
  const consumedFigIdxs = new Set();

  const prepareLine = (rawLine) => {
    if (hasInlineFigures) {
      let line = rawLine
        .replace(STRUCTURAL_STRIP, ' ')
        .replace(BOX_START, '')
        .replace(BOX_END, '');
      const result = replaceMarkersWithPlaceholders(
        line,
        figureCounter,
        itemIdToFigIdx,
        consumedFigIdxs,
      );
      figureCounter = result.nextPosIdx;
      return result.text.replace(/\s+/g, ' ').trim();
    }
    return cleanLine(rawLine);
  };

  const flushInline = () => {
    if (inlineBuffer.length === 0) return;
    const htmlParts = [];
    let leftRun = [];
    const flushLeftRun = () => {
      if (leftRun.length === 0) return;
      const augmented = augmentEquations(equations, leftRun.map((e) => e.text), { includeVars: true });
      const composed = composeLinesV1(
        leftRun.map((entry) => entry.text),
        mathRenderer,
        augmented,
        opts,
      );
      if (composed.html) {
        if (composed.hasFraction) hasFraction = true;
        htmlParts.push(composed.html);
      }
      leftRun = [];
    };
    for (const entry of inlineBuffer) {
      const align = normalizeLineAlign(entry?.align);
      const text = String(entry?.text || '');
      if (align === 'left') {
        leftRun.push({ text });
        continue;
      }
      flushLeftRun();
      const one = renderOneLine(text, mathRenderer, equations, opts);
      if (!one?.html) continue;
      if (one.hasFraction) hasFraction = true;
      htmlParts.push(
        `<div class="stem-line stem-line-${align}">${one.html}</div>`,
      );
    }
    flushLeftRun();
    const html = htmlParts.join('');
    if (html) {
      blocks.push({ type: 'inline', html });
    }
    inlineBuffer = [];
  };

  const flushBox = () => {
    if (boxLines.length === 0) return;
    flushInline();
    const hasBogi = boxLines.some((line) => BOGI_RE.test(String(line?.text || '')));
    const boxSvg = '<svg class="bogi-box-border" viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true"><rect x="0.5" y="0.5" width="99" height="99" fill="none" stroke="#333" stroke-width="0.5" vector-effect="non-scaling-stroke" shape-rendering="geometricPrecision"/></svg>';
    const bogiSvgLeft = '<svg class="bogi-bracket" viewBox="0 0 7 14" width="0.55em" height="1.05em"><path d="M7 0 L0 7 L7 14" fill="none" stroke="#333" stroke-width="0.35"/></svg>';
    const bogiSvgRight = '<svg class="bogi-bracket" viewBox="0 0 7 14" width="0.55em" height="1.05em"><path d="M0 0 L7 7 L0 14" fill="none" stroke="#333" stroke-width="0.35"/></svg>';
    const title = hasBogi
      ? `<div class="bogi-title">${bogiSvgLeft}<span class="bogi-title-text">보 기</span>${bogiSvgRight}</div>`
      : '';
    const inner = renderBogiItems(boxLines, mathRenderer, equations, opts);
    if (inner.hasFraction) hasFraction = true;
    const innerHtml = inner.html;
    if (innerHtml) {
      blocks.push({
        type: 'block',
        html: `<div class="bogi-box">${boxSvg}${title}<div class="bogi-content">${innerHtml}</div></div>`,
      });
    }
    boxLines = [];
  };

  for (let lineIdx = 0; lineIdx < lines.length; lineIdx += 1) {
    const rawLine = lines[lineIdx];
    const lineAlign = lineAligns[lineIdx] || 'left';
    if (PARAGRAPH_MARKER_LINE_RE.test(rawLine)) {
      if (!inBox) {
        flushInline();
      } else {
        boxLines.push({ text: '[문단]', align: lineAlign });
      }
      continue;
    }
    const hasStart = BOX_START.test(rawLine);
    const hasEnd = BOX_END.test(rawLine);

    if (hasEnd && !inBox && !hasStart) {
      const clean = prepareLine(rawLine);
      if (!clean) continue;
      inlineBuffer.push({ text: clean, align: lineAlign });
      continue;
    }

    if (hasStart && !inBox) {
      inBox = true;
      const clean = prepareLine(rawLine);
      if (clean) boxLines.push({ text: clean, align: lineAlign });
      if (hasEnd) { inBox = false; flushBox(); }
      continue;
    }
    if (inBox) {
      const clean = prepareLine(rawLine);
      if (clean) boxLines.push({ text: clean, align: lineAlign });
      if (hasEnd) { inBox = false; flushBox(); }
      continue;
    }

    const clean = prepareLine(rawLine);
    if (!clean) continue;
    inlineBuffer.push({ text: clean, align: lineAlign });
  }
  flushBox();
  flushInline();

  let stemHtml = blocks.map((b) => b.html).join('');
  const inlineCount = hasInlineFigures ? Math.min(figureCounter, dataUrls.length) : 0;

  if (inlineCount > 0) {
    stemHtml = replacePlaceholdersWithImages(stemHtml, dataUrls, layoutItems, figureLayout);
  }

  return { stemHtml, hasFraction, inlineCount };
}

function renderFigures(question, { stemSizePt = 11, skipCount = 0 } = {}) {
  const dataUrls = Array.isArray(question?.figure_data_urls) ? question.figure_data_urls : [];
  if (dataUrls.length === 0) return '';

  const remainingUrls = skipCount > 0 ? dataUrls.slice(skipCount) : dataUrls;
  if (remainingUrls.length === 0) return '';

  const layout = resolveFigureLayout(question, stemSizePt);
  if (!layout || layout.items.length === 0) {
    return remainingUrls
      .map((url) => `<div class="figure-container"><img class="figure-img" src="${url}" /></div>`)
      .join('');
  }

  const remainingItems = skipCount > 0 ? layout.items.slice(skipCount) : layout.items;

  const urlByKey = new Map();
  remainingItems.forEach((item, i) => {
    const url = remainingUrls[i];
    if (url) urlByKey.set(item.assetKey, { url, item });
  });

  const skippedKeys = new Set(layout.items.slice(0, skipCount).map((it) => it.assetKey));

  const grouped = new Set();
  const parts = [];

  for (const group of layout.groups) {
    if (group.type !== 'horizontal') continue;
    const memberEntries = group.members
      .filter((key) => !skippedKeys.has(key))
      .map((key) => urlByKey.get(key))
      .filter(Boolean);
    if (memberEntries.length < 2) continue;
    memberEntries.forEach((e) => grouped.add(e.item.assetKey));
    const gapEm = Number.isFinite(group.gap) ? group.gap : 0.5;
    const innerHtml = memberEntries
      .map((e) => {
        const w = e.item.widthEm;
        return `<div class="figure-layout-item" style="flex:0 0 ${w}em;max-width:${w}em;">`
          + `<img class="figure-img" src="${e.url}" />`
          + `</div>`;
      })
      .join('');
    parts.push(
      `<div class="figure-group-horizontal" style="gap:${gapEm}em;">${innerHtml}</div>`,
    );
  }

  for (const [key, entry] of urlByKey) {
    if (grouped.has(key)) continue;
    const { url, item } = entry;
    const posClass = `figure-pos-${item.position}`;
    const anchorClass = `figure-anchor-${item.anchor}`;
    const widthStyle = `width:${item.widthEm}em;max-width:100%;`;
    parts.push(
      `<div class="figure-container ${posClass} ${anchorClass}">`
      + `<img class="figure-img" src="${url}" style="${widthStyle}" />`
      + `</div>`,
    );
  }

  return parts.join('');
}

function numIndentEm(numStr) {
  const digits = numStr.replace(/\D/g, '').length;
  if (digits <= 1) return '0.70';
  return '1.10';
}

function resolveQuestionScore(question, scoreMapByQuestionId) {
  const questionUid = String(question?.question_uid || '').trim();
  const mapScoreByUid = Number.parseFloat(
    String(scoreMapByQuestionId?.[questionUid] ?? ''),
  );
  if (Number.isFinite(mapScoreByUid) && mapScoreByUid >= 0) {
    return Math.min(999, mapScoreByUid);
  }
  const questionId = String(question?.id || '').trim();
  const mapScore = Number.parseFloat(
    String(scoreMapByQuestionId?.[questionId] ?? ''),
  );
  if (Number.isFinite(mapScore) && mapScore >= 0) {
    return Math.min(999, mapScore);
  }
  const meta = question?.meta && typeof question.meta === 'object' ? question.meta : {};
  const metaScore = Number.parseFloat(
    String(meta.score_point ?? meta.scorePoint ?? ''),
  );
  if (Number.isFinite(metaScore) && metaScore >= 0) {
    return Math.min(999, metaScore);
  }
  return 3;
}

function formatQuestionScore(scoreValue) {
  if (!Number.isFinite(scoreValue)) return '3';
  if (Math.abs(scoreValue - Math.round(scoreValue)) < 0.0001) {
    return String(Math.round(scoreValue));
  }
  return scoreValue.toFixed(1).replace(/\.0$/, '');
}

function appendScoreToStemHtml(
  stemHtml,
  scoreHtml,
  { preferBeforeTrailingFigure = false } = {},
) {
  function findMatchingDivEnd(source, openIdx) {
    const tagRe = /<\/?div\b[^>]*>/gi;
    tagRe.lastIndex = openIdx;
    let depth = 0;
    let sawOpen = false;
    let match = tagRe.exec(source);
    while (match) {
      const token = String(match[0] || '');
      const isClose = /^<\//.test(token);
      if (isClose) {
        if (sawOpen) depth -= 1;
      } else {
        depth += 1;
        sawOpen = true;
      }
      if (sawOpen && depth === 0) return tagRe.lastIndex;
      match = tagRe.exec(source);
    }
    return -1;
  }

  function findTrailingDivContainerStart(source, marker) {
    const start = source.lastIndexOf(marker);
    if (start < 0) return -1;
    const end = findMatchingDivEnd(source, start);
    if (end < 0) return -1;
    if (source.slice(end).trim().length > 0) return -1;
    return start;
  }

  function findTrailingTableStart(source) {
    const start = source.lastIndexOf('<table');
    if (start < 0) return -1;
    const closeIdx = source.indexOf('</table>', start);
    if (closeIdx < 0) return -1;
    const end = closeIdx + '</table>'.length;
    if (source.slice(end).trim().length > 0) return -1;
    return start;
  }

  const base = String(stemHtml || '');
  const score = String(scoreHtml || '');
  if (!base.trim()) return score;
  if (preferBeforeTrailingFigure) {
    // 보기/박스가 포함된 문제는 점수를 박스 내부가 아니라 박스 앞에 붙인다.
    const lastBogiBoxStart = base.lastIndexOf('<div class="bogi-box');
    if (lastBogiBoxStart >= 0) {
      return `${base.slice(0, lastBogiBoxStart)}&nbsp;${score}${base.slice(lastBogiBoxStart)}`;
    }

    // Case 1) Stem ends with block-like containers such as 보기 박스/그림/표.
    // Score should be attached to statement text, so place it before these blocks.
    const trailingMarkers = [
      '<div class="figure-container',
      '<div class="figure-inline-block',
      '<div class="figure-group-horizontal',
    ];
    for (const marker of trailingMarkers) {
      const start = findTrailingDivContainerStart(base, marker);
      if (start >= 0) {
        return `${base.slice(0, start)}&nbsp;${score}${base.slice(start)}`;
      }
    }
    const tableStart = findTrailingTableStart(base);
    if (tableStart >= 0) {
      return `${base.slice(0, tableStart)}&nbsp;${score}${base.slice(tableStart)}`;
    }

    // Case 2) Inline line ends with figure block(s) inside `.lc-line`.
    // Insert score before the trailing figure block, not after it.
    const trailingInlineLineFigureRe =
      /(<span class="lc-line[^"]*"[^>]*>[\s\S]*?)(<div class="figure-inline-block[\s\S]*<\/div>)(\s*<\/span>\s*)$/;
    if (trailingInlineLineFigureRe.test(base)) {
      return base.replace(trailingInlineLineFigureRe, `$1&nbsp;${score}$2$3`);
    }
  }
  return `${base}&nbsp;${score}`;
}

export function renderQuestionBlock(
  question,
  mathRenderer,
  {
    stemSizePt = 11,
    includeQuestionScore = false,
    questionScoreByQuestionId = {},
    showQuestionNumber = true,
    debugDots = false,
  } = {},
) {
  const number = String(question?.question_number || '?');
  const equations = Array.isArray(question?.equations) ? question.equations : [];
  const dataUrls = Array.isArray(question?.figure_data_urls) ? question.figure_data_urls : [];
  const isImageChoice = isImageChoiceQuestion(question);
  // hydrateFiguresForHtml 이 dataUrls 와 같은 인덱스에 HWPX binaryItemIDRef 를 채워둔다.
  //   본문 [[PB_FIG_<id>]] 토큰 해석에 사용 — 비어있으면 plain 마커처럼 positional 로 동작.
  const figureItemIds = Array.isArray(question?.figure_item_ids) ? question.figure_item_ids : [];
  const meta =
    question?.meta && typeof question.meta === 'object' ? question.meta : {};
  const rawStemLineAligns = Array.isArray(meta.stem_line_aligns)
    ? meta.stem_line_aligns
    : Array.isArray(meta.stemLineAligns)
      ? meta.stemLineAligns
      : [];

  // 사용자가 리뷰 UI 에서 `[문단:가운데]` 처럼 속성부 마커를 추가하면,
  // plain `[문단]` 으로 정규화한 뒤 속성값을 stemLineAligns 에 이식해
  // XeLaTeX / HTML 두 경로가 같은 "라인별 정렬" 인프라를 공유하도록 한다.
  const normalizedAlign = applyInlineAlignmentMarkers(
    isImageChoice ? stripImageChoiceFigureMarkers(question?.stem || '') : (question?.stem || ''),
    rawStemLineAligns,
  );
  const normalizedStem = normalizedAlign.stem;
  const stemLineAligns = normalizedAlign.stemLineAligns;

  const figureLayout = resolveFigureLayout(question, stemSizePt);
  const layoutItems = figureLayout ? figureLayout.items : [];

  const stem = renderStemWithBoxes(normalizedStem, mathRenderer, equations, {
    dataUrls,
    layoutItems,
    figureLayout,
    stemLineAligns,
    figureItemIds,
    debugDots,
  });

  const choices = Array.isArray(question?.choices) ? question.choices : [];
  let choiceHtml = '';
  if (choices.length > 0) {
    const choiceOpts = debugDots ? { debugDots: true } : undefined;
    if (isBlankChoiceQuestion(question) && choices.length === 5) {
      choiceHtml = renderBlankChoiceContainer(question, choices, mathRenderer, equations, choiceOpts);
    } else if (isImageChoice && choices.length === 5) {
      choiceHtml = renderImageChoiceContainer(question, choices, dataUrls);
    } else {
      const items = choices.map((ch) => renderChoiceItem(ch, mathRenderer, equations, choiceOpts));
      const layout = chooseLayout(items);
      choiceHtml = renderChoiceContainer(items, layout);
    }
  }

  const inlineCount = stem.inlineCount || 0;
  const figureHtml = isImageChoice
    ? ''
    : renderFigures(question, { stemSizePt, skipCount: inlineCount });

  const hasFraction = stem.hasFraction || choiceHtml.includes('has-fraction');
  const questionClass = hasFraction ? 'question has-fraction' : 'question';
  const indent = showQuestionNumber ? numIndentEm(number) : '0';
  const scoreSuffix = includeQuestionScore
    ? `<span class="q-score">[${escapeHtml(formatQuestionScore(
      resolveQuestionScore(question, questionScoreByQuestionId),
    ))}점]</span>`
    : '';
  const stemRawHtml = String(stem.stemHtml || '');
  const hasTrailingContainerLikeContent =
    /<div class="(?:bogi-box|figure-inline-block|figure-group-horizontal|figure-container)[^"]*"|<table[\s>]/.test(stemRawHtml);
  const hasFigureLikeContent =
    hasTrailingContainerLikeContent
    || inlineCount > 0
    || String(figureHtml || '').trim().length > 0;
  const stemHtml = scoreSuffix
    ? appendScoreToStemHtml(stemRawHtml, scoreSuffix, {
      preferBeforeTrailingFigure: hasFigureLikeContent,
    })
    : stemRawHtml;

  return `
    <article class="${questionClass}" style="padding-left:${indent}em;text-indent:-${indent}em;">
      <div class="q-stem">${showQuestionNumber ? `<span class="q-num">${escapeHtml(number)}.</span> ` : ''}${stemHtml}</div>
      ${figureHtml}
      ${choiceHtml}
    </article>
  `;
}
