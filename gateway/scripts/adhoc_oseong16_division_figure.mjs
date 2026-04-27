import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';
import fs from 'node:fs/promises';
import path from 'node:path';
import sharp from 'sharp';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  console.error('SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 가 .env 에 필요합니다.');
  process.exit(2);
}

const APPLY = process.argv.includes('--apply');
const VERIFY = process.argv.includes('--verify');
const SOURCE_IMAGE = readArg('--source');
const supa = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

function readArg(name) {
  const prefix = `${name}=`;
  const hit = process.argv.find((arg) => arg.startsWith(prefix));
  return hit ? hit.slice(prefix.length).trim() : '';
}

function escapeXml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
}

function text(x, y, value, { size = 48, anchor = 'start', weight = 400 } = {}) {
  return `<text x="${x}" y="${y}" text-anchor="${anchor}" font-size="${size}" font-weight="${weight}">${escapeXml(value)}</text>`;
}

function hline(y, { x1 = 160, x2 = 578, width = 2.2 } = {}) {
  return `<line x1="${x1}" y1="${y}" x2="${x2}" y2="${y}" stroke="#000" stroke-width="${width}" />`;
}

function buildDivisionSvg() {
  // 숫자는 오성중 16번 원본 스크린샷 기준으로 고정한다.
  const rows = [
    text(292, 84, '12345', { anchor: 'middle', size: 47 }),
    hline(104),
    text(50, 158, '1665', { size: 47 }),
    text(178, 158, ')', { size: 58 }),
    text(210, 158, '2057', { size: 47 }),
    text(190, 234, '1665', { size: 47 }),
    text(190, 310, '3920', { size: 47 }),
    text(190, 386, '3330', { size: 47, weight: 700 }),
    hline(406),
    text(190, 461, '5900', { size: 47 }),
    text(190, 536, '4995', { size: 47 }),
    hline(557),
    text(190, 611, '9050', { size: 47 }),
    text(190, 687, '8325', { size: 47 }),
    hline(707),
    text(190, 762, '7250', { size: 47 }),
    text(190, 837, '6660', { size: 47 }),
    hline(858),
    text(190, 912, '590', { size: 47 }),
  ];

  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="620" height="950" viewBox="0 0 620 950">
  <style>
    text {
      font-family: "Times New Roman", "Nimbus Roman", "Liberation Serif", serif;
      fill: #000;
      dominant-baseline: alphabetic;
    }
    line {
      shape-rendering: crispEdges;
    }
  </style>
  <rect x="0" y="0" width="620" height="950" fill="#fff" />
  ${rows.join('\n  ')}
</svg>
`;
}

async function findOseongQuestion16() {
  const { data: docs, error: docErr } = await supa
    .from('pb_documents')
    .select('id,academy_id,source_filename,updated_at,status')
    .ilike('source_filename', '%오성%')
    .order('updated_at', { ascending: false })
    .limit(20);
  if (docErr) throw new Error(`pb_documents select failed: ${docErr.message}`);

  const candidates = [];
  for (const doc of docs || []) {
    const { data: questions, error: qErr } = await supa
      .from('pb_questions')
      .select('id,document_id,question_number,stem,figure_refs,meta,source_page,source_order,updated_at')
      .eq('document_id', doc.id)
      .order('source_order', { ascending: true })
      .limit(200);
    if (qErr) throw new Error(`pb_questions select failed: ${qErr.message}`);
    for (const q of questions || []) {
      if (String(q.question_number ?? '').trim() !== '16') continue;
      candidates.push({ doc, question: q });
    }
  }
  return candidates;
}

function nextMetaFor({ doc, question, objectPath, sourceImage }) {
  const nowIso = new Date().toISOString();
  const prevMeta = question.meta && typeof question.meta === 'object' ? question.meta : {};
  const asset = {
    id: `manual-oseong16-division-${nowIso.replace(/[:.]/g, '-')}`,
    source: sourceImage ? 'manual_upload' : 'manual_svg',
    provider: sourceImage ? 'user' : 'cursor',
    model: sourceImage ? 'user-provided-png' : 'code-generated',
    status: 'manual_replacement',
    approved: true,
    review_required: false,
    bucket: 'problem-previews',
    path: objectPath,
    mime_type: 'image/png',
    confidence: 1,
    figure_index: 1,
    item_id: '',
    reference_count: 0,
    reference_entry: sourceImage ? path.basename(sourceImage) : '',
    requested_min_side_px: 950,
    created_at: nowIso,
  };
  const nextMeta = {
    ...prevMeta,
    figure_assets: [asset],
    figure_layout: {
      version: 1,
      items: [
        {
          assetKey: 'idx:1',
          widthEm: 13.8,
          position: 'below-stem',
          anchor: 'center',
          offsetXEm: 0,
          offsetYEm: 0,
        },
      ],
      groups: [],
    },
    figure_review_required: false,
    figure_last_generated_at: nowIso,
  };
  return { nextMeta, asset, nowIso };
}

async function main() {
  const candidates = await findOseongQuestion16();
  if (candidates.length === 0) {
    console.error('오성중 16번 후보를 찾지 못했습니다.');
    process.exit(1);
  }

  console.log('오성중 16번 후보:');
  candidates.forEach(({ doc, question }, idx) => {
    const assets = Array.isArray(question.meta?.figure_assets) ? question.meta.figure_assets : [];
    console.log(
      `${idx + 1}. doc=${doc.source_filename} (${doc.id}) q=${question.id} figures=${assets.length} updated=${question.updated_at}`,
    );
  });

  const target = candidates[0];
  if (VERIFY) {
    const meta = target.question.meta && typeof target.question.meta === 'object'
      ? target.question.meta
      : {};
    const asset = Array.isArray(meta.figure_assets) ? meta.figure_assets[0] : null;
    console.log(JSON.stringify({
      question_id: target.question.id,
      source: asset?.source || '',
      provider: asset?.provider || '',
      model: asset?.model || '',
      reference_entry: asset?.reference_entry || '',
      bucket: asset?.bucket || '',
      path: asset?.path || '',
      mime_type: asset?.mime_type || '',
      figure_layout: meta.figure_layout || null,
    }, null, 2));
    if (asset?.bucket && asset?.path) {
      const { data, error } = await supa.storage.from(asset.bucket).download(asset.path);
      if (error) throw new Error(`storage download failed: ${error.message}`);
      const buf = Buffer.from(await data.arrayBuffer());
      console.log(`download_bytes=${buf.length}`);
    }
    return;
  }

  const outDir = path.resolve('tmp', 'manual_figures');
  await fs.mkdir(outDir, { recursive: true });
  const pngPath = path.join(outDir, 'oseong_q16_long_division.png');
  let png;
  if (SOURCE_IMAGE) {
    const sourcePath = path.resolve(SOURCE_IMAGE);
    const sourceBytes = await fs.readFile(sourcePath);
    png = await sharp(sourceBytes).png().toBuffer();
    await fs.writeFile(pngPath, png);
    console.log(`소스: ${sourcePath}`);
  } else {
    const svg = buildDivisionSvg();
    const svgPath = path.join(outDir, 'oseong_q16_long_division.svg');
    await fs.writeFile(svgPath, svg, 'utf8');
    png = await sharp(Buffer.from(svg)).png().toBuffer();
    await fs.writeFile(pngPath, png);
    console.log(`생성: ${svgPath}`);
  }

  console.log(`PNG 준비: ${pngPath} (${png.length} bytes)`);

  const objectPath = `${target.doc.academy_id}/${target.doc.id}/${target.question.id}/manual-oseong16-long-division.png`;
  const { nextMeta } = nextMetaFor({
    ...target,
    objectPath,
    sourceImage: SOURCE_IMAGE,
  });

  const nextStem = String(target.question.stem || '').includes('[그림]')
    ? target.question.stem
    : `${String(target.question.stem || '').trim()}\n[그림]`.trim();
  const nextFigureRefs = Array.isArray(target.question.figure_refs) && target.question.figure_refs.length > 0
    ? target.question.figure_refs
    : ['manual-oseong16-long-division'];

  console.log(`대상 문서: ${target.doc.source_filename}`);
  console.log(`대상 문항: ${target.question.id}`);
  console.log(`업로드 경로: problem-previews/${objectPath}`);
  console.log(`stem [그림] 포함: ${String(nextStem).includes('[그림]')}`);

  if (!APPLY) {
    console.log('dry-run 입니다. 적용하려면 --apply 를 붙여 다시 실행하세요.');
    return;
  }

  const { error: uploadErr } = await supa.storage
    .from('problem-previews')
    .upload(objectPath, png, {
      contentType: 'image/png',
      upsert: true,
    });
  if (uploadErr) throw new Error(`storage upload failed: ${uploadErr.message}`);

  const { error: updateErr } = await supa
    .from('pb_questions')
    .update({
      stem: nextStem,
      figure_refs: nextFigureRefs,
      meta: nextMeta,
      updated_at: new Date().toISOString(),
    })
    .eq('id', target.question.id);
  if (updateErr) throw new Error(`pb_questions update failed: ${updateErr.message}`);

  console.log('적용 완료');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
