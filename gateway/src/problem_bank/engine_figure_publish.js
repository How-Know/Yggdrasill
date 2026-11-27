// 엔진 그림 한 장을 실서비스에 싣는 계획을 세운다(올릴 파일의 자리 + 문항에 적을 한 줄).
//
// 여기서는 계획만 세운다. 저장소와 DB 에 쓰는 일은 scripts/publish_engine_figures.mjs 가 한다.
//
// 올리는 자리:  <학원>/<문항>/<그림 번호>/<내용 지문 앞 12자>/<파일 이름>
//   내용 지문은 묶음 파일 전체로 만든다. 그림을 고쳐 다시 실으면 새 자리에 올라가고 문항의 한 줄이 그 자리로
//   한 번에 바뀐다. 인쇄 도중에 파일이 바뀌는 일이 없고, 예전 파일이 남아 있어 되돌릴 수 있다.
import { createHash } from 'node:crypto';

import { ENGINE_FIGURE_BUCKET, buildEngineFigureRecord, isPrintableEngineTikz } from './engine_figures.js';

const CONTENT_TYPES = {
  '.pdf': 'application/pdf',
  '.png': 'image/png',
  '.json': 'application/json',
  '.tikz': 'text/plain',
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function contentTypeOf(name) {
  const dot = name.lastIndexOf('.');
  return CONTENT_TYPES[dot < 0 ? '' : name.slice(dot).toLowerCase()] || '';
}

/** 엔진 묶음(asset.json)이 가리키는 파일 이름들. 같은 파일을 여러 크기가 함께 쓰면 한 번만 적는다. */
export function bundleFileNames(bundle) {
  const names = new Set(['asset.json']);
  for (const key of ['pdf', 'png', 'source', 'tikz']) {
    const name = bundle?.files?.[key];
    if (name) names.add(String(name));
  }
  for (const one of Array.isArray(bundle?.variants) ? bundle.variants : []) {
    if (one?.pdf) names.add(String(one.pdf));
    if (one?.tikz) names.add(String(one.tikz));
  }
  return [...names].sort();
}

/** 파일별 sha256({ 이름: 지문 })에서 묶음 전체의 내용 지문을 만든다. */
export function bundleContentHash(fileHashes) {
  const lines = Object.keys(fileHashes).sort().map((name) => `${name}:${fileHashes[name]}`);
  return createHash('sha256').update(lines.join('\n')).digest('hex');
}

/**
 * 그림 한 장을 싣는 계획.
 *
 * [fileHashes] 는 묶음 폴더에 실제로 있는 파일의 sha256, [tikzTexts] 는 그리는 글의 내용이다({ 이름: 글 }).
 * 돌려주는 것: { base, contentHash, uploads: [{ name, path, contentType }], record, problems, warnings }.
 * problems 가 하나라도 있으면 싣지 않는다.
 */
export function planEngineFigurePublish({
  bundle,
  fileHashes = {},
  tikzTexts = {},
  academyId,
  questionId,
  figureIndex,
  originalPath,
  status = 'draft',
  now,
}) {
  const problems = [];
  const warnings = [];
  if (!bundle || bundle.format !== 'ygg-figure-asset/1') {
    return { base: '', contentHash: '', uploads: [], record: null, problems: ['엔진 묶음(asset.json)이 아닙니다'], warnings };
  }
  if (!UUID.test(String(academyId || ''))) problems.push('학원을 알 수 없습니다');
  if (!UUID.test(String(questionId || ''))) problems.push('문항을 알 수 없습니다');
  const index = Number.parseInt(String(figureIndex ?? ''), 10);
  if (!Number.isInteger(index) || index <= 0) problems.push('그림 번호가 없습니다');
  if (!String(originalPath || '').trim()) problems.push('바꿀 원본 그림의 자리를 알 수 없습니다');
  else if (!String(originalPath).startsWith(`${academyId}/`)) problems.push('원본 그림이 이 학원의 것이 아닙니다');

  const names = bundleFileNames(bundle);
  for (const name of names) {
    if (!/^[A-Za-z0-9@._-]+$/.test(name)) problems.push(`파일 이름에 쓸 수 없는 글자가 있습니다: ${name}`);
    else if (!contentTypeOf(name)) problems.push(`올릴 수 없는 종류의 파일입니다: ${name}`);
    else if (!fileHashes[name]) problems.push(`묶음에 파일이 없습니다: ${name}`);
  }
  if (!bundle.files?.pdf) problems.push('인쇄용 그림(pdf)이 없습니다');

  // 그리는 글은 인쇄 문서에 그대로 들어간다. 넣을 수 없는 글이면 그 크기는 PDF 로만 찍힌다(글자가 본문 글꼴과 달라진다).
  const usableTikz = (name) => Boolean(name) && isPrintableEngineTikz(tikzTexts[name]);
  for (const name of names.filter((one) => one.endsWith('.tikz'))) {
    if (!usableTikz(name)) warnings.push(`그리는 글을 인쇄 문서에 넣을 수 없어 PDF 로 찍힙니다: ${name}`);
  }
  // 과제형에서 글자가 선과 겹친다고 엔진이 알린 크기.
  for (const one of Array.isArray(bundle.variants) ? bundle.variants : []) {
    if (Array.isArray(one?.label_overlaps) && one.label_overlaps.length > 0) {
      warnings.push(`글자 겹침(${one.format}/${one.position}): ${one.label_overlaps.join(', ')}`);
    }
  }
  if (problems.length > 0) return { base: '', contentHash: '', uploads: [], record: null, problems, warnings };

  const contentHash = bundleContentHash(Object.fromEntries(names.map((name) => [name, fileHashes[name]])));
  const base = `${academyId}/${questionId}/${index}/${contentHash.slice(0, 12)}`;
  const at = (name) => `${base}/${name}`;
  const variantPdfPaths = {};
  const variantTikzPaths = {};
  for (const one of Array.isArray(bundle.variants) ? bundle.variants : []) {
    if (!one?.pdf) continue;
    const key = `${one.format}/${one.position}`;
    variantPdfPaths[key] = at(one.pdf);
    if (usableTikz(one.tikz)) variantTikzPaths[key] = at(one.tikz);
  }
  const record = buildEngineFigureRecord({
    bundle,
    figureIndex: index,
    originalPath,
    bucket: ENGINE_FIGURE_BUCKET,
    pdfPath: at(bundle.files.pdf),
    pngPath: bundle.files.png ? at(bundle.files.png) : '',
    sourcePath: bundle.files.source ? at(bundle.files.source) : '',
    tikzPath: usableTikz(bundle.files.tikz) ? at(bundle.files.tikz) : '',
    variantPdfPaths,
    variantTikzPaths,
    contentHash,
    status,
    ...(now ? { now } : {}),
  });
  return {
    base,
    contentHash,
    uploads: names.map((name) => ({ name, path: at(name), contentType: contentTypeOf(name) })),
    record,
    problems,
    warnings,
  };
}

/** 문항에 지금 붙어 있는 원본 그림 가운데 이 번호·이 자리의 그림이 있는지(다시 잘렸으면 없다). */
export function originalStillThere(figureAssets, figureIndex, originalPath) {
  return (Array.isArray(figureAssets) ? figureAssets : []).some(
    (one) => one && Number(one.figure_index) === Number(figureIndex) && String(one.path || '') === String(originalPath || ''),
  );
}
