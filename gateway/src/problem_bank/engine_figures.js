// 그림 엔진(packages/ygg_figure)으로 다시 그린 그림을 문항에 붙이는 약속.
//
// 문항의 원본 그림(meta.figure_assets)은 건드리지 않는다. 다시 그린 그림은 그 옆의
// meta.engine_figures 에 그림 번호(figure_index)별로 한 줄씩 적는다.
//
//   {
//     figure_index: 1,
//     status: 'draft' | 'approved',      // 승인된 것만 인쇄에 쓴다
//     original_path: '<다시 그린 원본 그림의 figure_assets[].path>',
//     bucket: 'problem-figures',
//     pdf_path, png_path, source_path,   // 인쇄용 벡터, 화면용 그림, 그림 파일(관계로 적은 JSON)
//     tikz_path,                         // 그리는 글(TikZ). 있으면 인쇄 문서가 직접 조판한다(아래 설명)
//     figure_id, engine, style, body_pt, // 무엇으로 그렸는지
//     kind, tags, elements, size_class,  // 그림 이름표(docs/architecture/figure-tags.md). 묶음에 있을 때만 적는다
//     width_mm, height_mm, width_em, height_em, width_px, height_px,
//     variants: [                        // 양식 × 자리마다 크기 표대로 다시 그린 그림(없으면 제 크기 그림을 쓴다)
//       { format: 'mock' | 'naesin' | 'assignment', position: 'below-stem' | 'below-choices' | 'inline-right',
//         pdf_path, tikz_path, width_em, height_em, scale, source: 'table' | 'figure', note, needs_check }
//     ],
//     content_hash, published_at, approved_at
//   }
//
// 크기 표(packages/ygg_figure/figures/size_table.json)는 양식 × 자리마다 그림 크기를 하나로 정한다.
// 엔진이 그 크기로 다시 그릴 때 도형만 커지거나 작아지고 글자·선 굵기는 그대로다. 표로 안 되는
// 그림은 그림 파일에 따로 적고(source: 'figure'), 그 이유가 note 에 남는다.
//
// 그림 속 글자는 어느 양식에 실어도 그 양식의 본문 글자와 같아야 한다(글꼴, 크기 비율).
// 미리 만든 PDF 는 글꼴이 굳어 있어서, 그리는 글(tikz_path)이 있으면 인쇄 문서 안에서 직접 조판한다.
// 그러면 글자는 그 문서의 본문 글꼴로, 크기는 본문 글자에 비례해 찍힌다. 없으면 PDF 를 쓴다.
//
// 원본 그림이 바뀌면(다시 잘랐거나 순서가 바뀌면) original_path 가 맞지 않게 되고,
// 그때는 다시 그린 그림을 쓰지 않는다. 엉뚱한 자리에 다른 그림이 찍히는 것보다 원본이 낫다.

export const ENGINE_FIGURE_BUCKET = 'problem-figures';

/** TeX 1pt = 1/72.27 inch. */
const MM_PER_PT = 25.4 / 72.27;

/** 그림판 길이(mm)를 본문 글자 크기 기준 길이(em)로 바꾼다. */
export function mmToEm(mm, bodyPt) {
  const size = Number(bodyPt);
  const value = Number(mm);
  if (!Number.isFinite(size) || size <= 0 || !Number.isFinite(value)) return 0;
  return value / (size * MM_PER_PT);
}

function positiveNumber(value) {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

export const FIGURE_FORMATS = ['assignment', 'naesin', 'mock'];
export const FIGURE_SIZE_POSITIONS = ['below-stem', 'below-choices', 'inline-right'];

/** 인쇄 양식(profile)이 크기 표의 어느 양식인지. 학교별 내신 양식은 모두 내신이다. */
export function figureFormatForProfile(profile) {
  const p = String(profile || '').trim().toLowerCase();
  if (p === 'mock' || p === 'csat') return 'mock';
  if (p === 'assignment') return 'assignment';
  return 'naesin';
}

/**
 * 그림 자리(figure_layout 의 position)가 크기 표의 어느 자리인지.
 * 글줄 안에 넣는 그림(inline-text)은 표에 없다(null → 제 크기).
 */
export function figureSizePosition(position) {
  const p = String(position || '').trim().toLowerCase();
  if (p === 'below-choices') return 'below-choices';
  if (p === 'inline-right' || p === 'inline-left') return 'inline-right';
  if (p === 'inline-text') return null;
  return 'below-stem';
}

/** 문항에 저장된 배치에서 이 그림의 자리를 읽는다. 저장된 배치가 없으면 본문 아래다. */
export function storedFigurePosition(meta, figureIndex, ordinal) {
  const items = meta && typeof meta === 'object' && Array.isArray(meta.figure_layout?.items)
    ? meta.figure_layout.items
    : [];
  const keys = [`idx:${figureIndex}`, `ord:${ordinal}`];
  for (const key of keys) {
    const item = items.find((one) => one && String(one.assetKey || '') === key);
    if (item) return String(item.position || 'below-stem');
  }
  return 'below-stem';
}

function parseVariants(raw) {
  if (!Array.isArray(raw)) return [];
  const out = [];
  for (const one of raw) {
    if (!one || typeof one !== 'object') continue;
    const format = String(one.format || '').trim();
    const position = String(one.position || '').trim();
    const pdfPath = String(one.pdf_path || '').trim();
    const tikzPath = String(one.tikz_path || '').trim();
    const widthEm = positiveNumber(one.width_em);
    const heightEm = positiveNumber(one.height_em);
    if (!FIGURE_FORMATS.includes(format) || !FIGURE_SIZE_POSITIONS.includes(position)) continue;
    if (!pdfPath || !widthEm || !heightEm) continue;
    out.push({
      format,
      position,
      pdfPath,
      tikzPath,
      widthEm,
      heightEm,
      scale: positiveNumber(one.scale) || 1,
      source: one.source === 'figure' ? 'figure' : 'table',
      note: String(one.note || ''),
      needsCheck: one.needs_check === true,
    });
  }
  return out;
}

/**
 * 이 양식 × 자리에 실을 그림. 크기 표대로 다시 그린 그림이 있으면 그것을, 없으면 제 크기 그림을 준다.
 * [position] 은 figure_layout 의 자리 이름 그대로 넘긴다.
 */
export function pickEngineFigureVariant(engineFigure, { format, position } = {}) {
  const base = {
    pdfPath: engineFigure.pdfPath,
    tikzPath: engineFigure.tikzPath || '',
    widthEm: engineFigure.widthEm,
    heightEm: engineFigure.heightEm,
    sized: false,
  };
  const sizePosition = figureSizePosition(position);
  if (!format || !sizePosition) return base;
  const found = (engineFigure.variants || []).find(
    (one) => one.format === format && one.position === sizePosition,
  );
  if (!found) return base;
  return {
    pdfPath: found.pdfPath,
    tikzPath: found.tikzPath || '',
    widthEm: found.widthEm,
    heightEm: found.heightEm,
    sized: true,
  };
}

// 그리는 글 안에 있으면 안 되는 명령. 그림은 선·칠·글자만 적으므로 파일을 읽고 쓰거나 명령을 새로 만드는
// 것은 쓸 일이 없다. 저장소에서 받은 글을 인쇄 문서에 그대로 넣기 전에 걸러 낸다.
const TIKZ_FORBIDDEN = /\\(?:input|include|includegraphics|openin|openout|read|write|immediate|csname|catcode|def|edef|gdef|xdef|let|futurelet|newcommand|renewcommand|providecommand|newenvironment|usepackage|RequirePackage|documentclass|special|directlua|expandafter|global|makeatletter|usetikzlibrary|pgfmathparse|verbatiminput)(?![A-Za-z])|\^\^|\\end\s*\{document\}/;

/**
 * 엔진이 낸 그리는 글(TikZ)인지, 인쇄 문서에 넣어도 되는지.
 * 엔진이 적는 모양(머리말 한 줄 + tikzpicture 하나) 그대로이고 금지된 명령이 없어야 한다.
 */
export function isPrintableEngineTikz(text) {
  const source = String(text || '');
  if (source.length === 0 || source.length > 2_000_000) return false;
  if (!source.startsWith('% ygg-figure engine=')) return false;
  if (source.split('\\begin{tikzpicture}').length !== 2) return false;
  if (source.split('\\end{tikzpicture}').length !== 2) return false;
  if (!/\\end\{tikzpicture\}%?\s*$/.test(source)) return false;
  if (TIKZ_FORBIDDEN.test(source)) return false;
  // 중괄호 짝이 맞아야 뒤따르는 본문이 깨지지 않는다(\{ 와 \} 는 글자다).
  let depth = 0;
  const bare = source.replace(/\\[{}\\]/g, '');
  for (const ch of bare) {
    if (ch === '{') depth += 1;
    else if (ch === '}') depth -= 1;
    if (depth < 0) return false;
  }
  return depth === 0;
}

/** meta.engine_figures 에서 쓸 수 있는 줄만 고른다(모양이 틀린 줄은 버린다). */
export function parseEngineFigures(meta) {
  const raw = meta && typeof meta === 'object' ? meta.engine_figures : null;
  if (!Array.isArray(raw)) return [];
  const out = [];
  for (const one of raw) {
    if (!one || typeof one !== 'object') continue;
    const figureIndex = Number.parseInt(String(one.figure_index ?? ''), 10);
    if (!Number.isInteger(figureIndex) || figureIndex <= 0) continue;
    const bucket = String(one.bucket || '').trim();
    const pdfPath = String(one.pdf_path || '').trim();
    const tikzPath = String(one.tikz_path || '').trim();
    const widthEm = positiveNumber(one.width_em) || mmToEm(one.width_mm, one.body_pt);
    const heightEm = positiveNumber(one.height_em) || mmToEm(one.height_mm, one.body_pt);
    if (!bucket || !pdfPath || widthEm <= 0 || heightEm <= 0) continue;
    out.push({
      figureIndex,
      status: String(one.status || '').trim().toLowerCase() === 'approved' ? 'approved' : 'draft',
      originalPath: String(one.original_path || '').trim(),
      bucket,
      pdfPath,
      tikzPath,
      pngPath: String(one.png_path || '').trim(),
      sourcePath: String(one.source_path || '').trim(),
      figureId: String(one.figure_id || '').trim(),
      widthEm,
      heightEm,
      widthPx: positiveNumber(one.width_px),
      heightPx: positiveNumber(one.height_px),
      variants: parseVariants(one.variants),
    });
  }
  return out;
}

/**
 * 이 원본 그림(asset) 자리에 인쇄할 승인된 엔진 그림. 없으면 null.
 * 같은 번호에 여러 줄이 있으면 뒤에 적힌 것(나중 것)을 쓴다.
 */
export function approvedEngineFigureFor(meta, asset) {
  const figureIndex = Number.parseInt(String(asset?.figure_index ?? ''), 10);
  if (!Number.isInteger(figureIndex) || figureIndex <= 0) return null;
  const assetPath = String(asset?.path || '').trim();
  let found = null;
  for (const one of parseEngineFigures(meta)) {
    if (one.figureIndex !== figureIndex || one.status !== 'approved') continue;
    if (one.originalPath && one.originalPath !== assetPath) continue;
    found = one;
  }
  return found;
}

/**
 * 엔진이 내보낸 묶음(asset.json)과 올린 자리로 meta.engine_figures 한 줄을 만든다.
 * [bundle] 은 `dart run ygg_figure export` 가 적은 asset.json 내용이다.
 */
export function buildEngineFigureRecord({
  bundle,
  figureIndex,
  originalPath,
  bucket = ENGINE_FIGURE_BUCKET,
  pdfPath,
  pngPath,
  sourcePath,
  contentHash,
  // 크기별 그림을 올린 자리: { 'mock/below-stem': '<pdf 경로>', ... }. 자리가 없는 크기는 적지 않는다.
  variantPdfPaths = {},
  // 그리는 글(TikZ)을 올린 자리. 제 크기 그림은 tikzPath, 크기별 그림은 variantPdfPaths 와 같은 열쇠로 적는다.
  tikzPath,
  variantTikzPaths = {},
  status = 'draft',
  now = new Date().toISOString(),
}) {
  const index = Number.parseInt(String(figureIndex ?? ''), 10);
  if (!Number.isInteger(index) || index <= 0) throw new Error('figureIndex 가 없습니다');
  if (!bundle || bundle.format !== 'ygg-figure-asset/1') throw new Error('엔진 묶음(asset.json)이 아닙니다');
  const widthMm = positiveNumber(bundle.width_mm);
  const heightMm = positiveNumber(bundle.height_mm);
  const bodyPt = positiveNumber(bundle.body_pt);
  if (!widthMm || !heightMm || !bodyPt) throw new Error('엔진 묶음에 그림 크기가 없습니다');
  if (!pdfPath) throw new Error('인쇄용 그림(pdf) 자리가 없습니다');
  const approved = status === 'approved';
  return {
    figure_index: index,
    status: approved ? 'approved' : 'draft',
    original_path: String(originalPath || ''),
    bucket,
    pdf_path: pdfPath,
    ...(tikzPath ? { tikz_path: String(tikzPath) } : {}),
    png_path: pngPath || '',
    source_path: sourcePath || '',
    figure_id: String(bundle.id || ''),
    engine: String(bundle.engine || ''),
    style: String(bundle.style || ''),
    ...(bundle.kind ? { kind: String(bundle.kind) } : {}),
    ...(Array.isArray(bundle.tags) && bundle.tags.length > 0 ? { tags: bundle.tags.map(String) } : {}),
    ...(Array.isArray(bundle.elements) && bundle.elements.length > 0 ? { elements: bundle.elements.map(String) } : {}),
    ...(bundle.size_class ? { size_class: String(bundle.size_class) } : {}),
    body_pt: bodyPt,
    width_mm: widthMm,
    height_mm: heightMm,
    width_em: Math.round(mmToEm(widthMm, bodyPt) * 1000) / 1000,
    height_em: Math.round(mmToEm(heightMm, bodyPt) * 1000) / 1000,
    width_px: positiveNumber(bundle.width_px),
    height_px: positiveNumber(bundle.height_px),
    variants: (Array.isArray(bundle.variants) ? bundle.variants : [])
      .filter((one) => one && variantPdfPaths[`${one.format}/${one.position}`])
      .map((one) => ({
        format: String(one.format),
        position: String(one.position),
        pdf_path: String(variantPdfPaths[`${one.format}/${one.position}`]),
        ...(variantTikzPaths[`${one.format}/${one.position}`]
          ? { tikz_path: String(variantTikzPaths[`${one.format}/${one.position}`]) }
          : {}),
        width_em: positiveNumber(one.width_em),
        height_em: positiveNumber(one.height_em),
        scale: positiveNumber(one.scale) || 1,
        source: one.source === 'figure' ? 'figure' : 'table',
        ...(one.note ? { note: String(one.note) } : {}),
        ...(one.needs_check === true ? { needs_check: true } : {}),
      })),
    content_hash: String(contentHash || ''),
    published_at: now,
    ...(approved ? { approved_at: now } : {}),
  };
}
