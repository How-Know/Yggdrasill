import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';
import fs from 'node:fs/promises';
import path from 'node:path';
import sharp from 'sharp';
import AdmZip from 'adm-zip';
import bmp from 'bmp-js';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  console.error('SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 가 .env 에 필요합니다.');
  process.exit(2);
}

const APPLY = process.argv.includes('--apply');
const VERIFY = process.argv.includes('--verify');
const SKIP_Q15 = process.argv.includes('--skip-q15');
const APPLY_Q19_ANSWER_FIGURES = process.argv.includes('--apply-q19-answer-figures');
const DIAGNOSE = process.argv.includes('--diagnose') || (!APPLY && !VERIFY);
const SOURCE_IMAGE = readArg('--q15-image') || 'C:\\Users\\harry\\OneDrive\\바탕 화면\\정화중2.png';
const SOURCE_HWPX = readArg('--source-hwpx')
  || 'C:\\Users\\harry\\OneDrive\\바탕 화면\\검수\\2025년 대구 수성구 정화중 중2공통 1학기중간 중등수학2상.hwpx';
const RIGHT_TAIL_SPACE = readArg('--right-tail-space') || '1.5';

const supa = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

function readArg(name) {
  const prefix = `${name}=`;
  const hit = process.argv.find((arg) => arg.startsWith(prefix));
  return hit ? hit.slice(prefix.length).trim() : '';
}

function summarizeQuestion(q) {
  const meta = q.meta && typeof q.meta === 'object' ? q.meta : {};
  const figureAssets = Array.isArray(meta.figure_assets) ? meta.figure_assets : [];
  const answerAssets = Array.isArray(meta.answer_figure_assets) ? meta.answer_figure_assets : [];
  return {
    id: q.id,
    question_uid: q.question_uid,
    number: q.question_number,
    figure_refs: Array.isArray(q.figure_refs) ? q.figure_refs.length : 0,
    figure_assets: figureAssets.length,
    answer_figure_assets: answerAssets.length,
    objective_answer_key: q.objective_answer_key,
    subjective_answer: q.subjective_answer,
    stem: q.stem,
    meta_keys: Object.keys(meta).sort(),
  };
}

async function answerSidecarForQuestion(q) {
  const questionUid = String(q?.question_uid || '').trim();
  if (!questionUid) return { crop: null, answer: null };
  const { data: crop, error: cropErr } = await supa
    .from('textbook_problem_crops')
    .select('id,problem_number,pb_question_uid,book_id,grade_label,sub_key,raw_page,display_page')
    .eq('pb_question_uid', questionUid)
    .maybeSingle();
  if (cropErr) throw new Error(`textbook_problem_crops select failed: ${cropErr.message}`);
  if (!crop) return { crop: null, answer: null };
  const { data: answer, error: answerErr } = await supa
    .from('textbook_problem_answers')
    .select('*')
    .eq('crop_id', crop.id)
    .maybeSingle();
  if (answerErr) throw new Error(`textbook_problem_answers select failed: ${answerErr.message}`);
  return { crop, answer };
}

async function findJeonghwa2Document() {
  const { data: docs, error: docErr } = await supa
    .from('pb_documents')
    .select('id,academy_id,source_filename,updated_at,status')
    .ilike('source_filename', '%정화%')
    .order('updated_at', { ascending: false })
    .limit(30);
  if (docErr) throw new Error(`pb_documents select failed: ${docErr.message}`);

  const candidates = [];
  for (const doc of docs || []) {
    const { data: questions, error: qErr } = await supa
      .from('pb_questions')
      .select('*')
      .eq('document_id', doc.id)
      .order('source_order', { ascending: true })
      .limit(250);
    if (qErr) throw new Error(`pb_questions select failed: ${qErr.message}`);
    const wanted = new Map();
    for (const q of questions || []) {
      const num = String(q.question_number ?? '').trim();
      if (['15', '16', '19'].includes(num)) wanted.set(num, q);
    }
    if (wanted.size > 0) candidates.push({ doc, questions, wanted });
  }

  const target = candidates.find(({ doc }) => /중2|중등수학2|2상/.test(doc.source_filename))
    || candidates[0];
  return { candidates, target };
}

function ensureFigureMarker(stem) {
  const s = String(stem || '').trim();
  if (/\[(?:그림|도형|도표|표)\]/.test(s) || /\[\[PB_FIG_[^\]]+\]\]/.test(s)) return s;
  return `${s}\n[그림]`.trim();
}

function alignCdotTextTwo(stem) {
  const lines = String(stem || '').split(/\r?\n/);
  const targetRe = /^(.*\\cdots\s+)(\\cdots\s*\\text\s*\{\s*[①②]\s*\}.*)$/;
  const existingTailRe = /\[우측꼬리\](\\cdots\s*\\text\s*\{\s*[①②]\s*\})(?:\[공백:[^\]]+\])?/;
  const out = [];
  let changed = false;
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    if (line.includes('[우측꼬리]')) {
      const next = line.replace(
        existingTailRe,
        `[우측꼬리]$1[공백:${RIGHT_TAIL_SPACE}]`,
      );
      out.push(next);
      if (next !== line) changed = true;
      continue;
    }
    const match = line.match(targetRe);
    if (match) {
      out.push(
        `${match[1].trimEnd()} [우측꼬리]${match[2].trimStart()}[공백:${RIGHT_TAIL_SPACE}]`,
      );
      changed = true;
      continue;
    }
    out.push(line);
  }
  return { stem: out.join('\n'), changed };
}

function buildQ15Meta({ question, objectPath, sourceImage }) {
  const nowIso = new Date().toISOString();
  const prevMeta = question.meta && typeof question.meta === 'object' ? question.meta : {};
  const asset = {
    id: `manual-jeonghwa2-q15-${nowIso.replace(/[:.]/g, '-')}`,
    source: 'manual_upload',
    provider: 'user',
    model: 'user-provided-png',
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
    reference_entry: path.basename(sourceImage),
    requested_min_side_px: 1024,
    created_at: nowIso,
  };
  return {
    nowIso,
    meta: {
      ...prevMeta,
      figure_assets: [asset],
      figure_count: 1,
      figure_layout: {
        version: 1,
        items: [
          {
            assetKey: 'idx:1',
            widthEm: 20.0,
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
    },
  };
}

async function applyQ15({ doc, question }) {
  const sourcePath = path.resolve(SOURCE_IMAGE);
  const sourceBytes = await fs.readFile(sourcePath);
  const png = await sharp(sourceBytes).png().toBuffer();
  const outDir = path.resolve('tmp', 'manual_figures');
  await fs.mkdir(outDir, { recursive: true });
  const localPng = path.join(outDir, 'jeonghwa2_q15.png');
  await fs.writeFile(localPng, png);

  const objectPath = `${doc.academy_id}/${doc.id}/${question.id}/manual-jeonghwa2-q15.png`;
  const { meta, nowIso } = buildQ15Meta({ question, objectPath, sourceImage: sourcePath });
  const nextStem = ensureFigureMarker(question.stem);
  const nextFigureRefs = ['manual-jeonghwa2-q15'];

  if (!APPLY) {
    return {
      localPng,
      bytes: png.length,
      objectPath,
      nextStem,
      nextFigureRefs,
      meta,
    };
  }

  const { error: uploadErr } = await supa.storage
    .from('problem-previews')
    .upload(objectPath, png, { contentType: 'image/png', upsert: true });
  if (uploadErr) throw new Error(`q15 upload failed: ${uploadErr.message}`);

  const { error: updateErr } = await supa
    .from('pb_questions')
    .update({
      stem: nextStem,
      figure_refs: nextFigureRefs,
      meta,
      updated_at: nowIso,
    })
    .eq('id', question.id);
  if (updateErr) throw new Error(`q15 update failed: ${updateErr.message}`);

  return { localPng, bytes: png.length, objectPath, nextStem, nextFigureRefs, meta };
}

async function applyQ16({ question }) {
  const aligned = alignCdotTextTwo(question.stem);
  if (!APPLY || !aligned.changed) return aligned;
  const { error } = await supa
    .from('pb_questions')
    .update({
      stem: aligned.stem,
      updated_at: new Date().toISOString(),
    })
    .eq('id', question.id);
  if (error) throw new Error(`q16 update failed: ${error.message}`);
  return aligned;
}

function bmpToPngBuffer(bytes) {
  const decoded = bmp.decode(Buffer.isBuffer(bytes) ? bytes : Buffer.from(bytes));
  if (!decoded?.data || !decoded.width || !decoded.height) {
    throw new Error('bmp_decode_empty');
  }
  const src = decoded.data;
  let allAlphaZero = true;
  for (let i = 0; i < src.length; i += 4) {
    if (src[i] !== 0) {
      allAlphaZero = false;
      break;
    }
  }
  const dst = Buffer.alloc(src.length);
  for (let i = 0; i < src.length; i += 4) {
    dst[i + 0] = src[i + 3];
    dst[i + 1] = src[i + 2];
    dst[i + 2] = src[i + 1];
    dst[i + 3] = allAlphaZero ? 255 : src[i + 0];
  }
  return sharp(dst, {
    raw: { width: decoded.width, height: decoded.height, channels: 4 },
  }).png().toBuffer();
}

async function imageEntryToPng(entry) {
  const bytes = entry.getData();
  if (/\.bmp$/i.test(entry.entryName) || (bytes[0] === 0x42 && bytes[1] === 0x4d)) {
    return bmpToPngBuffer(bytes);
  }
  return sharp(bytes).png().toBuffer();
}

function findHwpxImageEntry(zip, itemId) {
  const wanted = String(itemId || '').trim();
  const hpf = zip.getEntry('Contents/content.hpf') || zip.getEntry('content.hpf');
  if (hpf) {
    const xml = hpf.getData().toString('utf8');
    const itemRe = /<(?:opf:)?(?:item|binItem)\b([^>]*?)\/?>/gi;
    let m;
    while ((m = itemRe.exec(xml)) !== null) {
      const attrs = m[1] || '';
      const idMatch = attrs.match(/\bid\s*=\s*"([^"]+)"/i)
        || attrs.match(/\bid\s*=\s*'([^']+)'/i);
      const hrefMatch = attrs.match(/\bhref\s*=\s*"([^"]+)"/i)
        || attrs.match(/\bhref\s*=\s*'([^']+)'/i);
      if (String(idMatch?.[1] || '').trim() !== wanted) continue;
      const href = String(hrefMatch?.[1] || '').trim();
      const entry = zip
        .getEntries()
        .find((e) => e.entryName.toLowerCase() === href.toLowerCase());
      if (entry) return entry;
    }
  }
  return zip
    .getEntries()
    .find((e) => new RegExp(`^BinData/${wanted}\\.(png|jpg|jpeg|bmp|webp)$`, 'i').test(e.entryName));
}

async function applyQ19AnswerFigures({ doc, question }) {
  const sourcePath = path.resolve(SOURCE_HWPX);
  const sourceBytes = await fs.readFile(sourcePath);
  const zip = new AdmZip(sourceBytes);
  const itemIds = ['image3', 'image4'];
  const nowIso = new Date().toISOString();
  const prevMeta = question.meta && typeof question.meta === 'object' ? question.meta : {};
  const assets = [];

  for (let i = 0; i < itemIds.length; i += 1) {
    const itemId = itemIds[i];
    const entry = findHwpxImageEntry(zip, itemId);
    if (!entry) throw new Error(`q19 answer image not found in HWPX: ${itemId}`);
    const png = await imageEntryToPng(entry);
    const objectPath =
      `${doc.academy_id}/${doc.id}/${question.id}/hwpx-jeonghwa2-q19-answer-${i + 1}.png`;
    if (APPLY) {
      const { error: uploadErr } = await supa.storage
        .from('problem-previews')
        .upload(objectPath, png, { contentType: 'image/png', upsert: true });
      if (uploadErr) throw new Error(`q19 answer image upload failed: ${uploadErr.message}`);
    }
    assets.push({
      id: `hwpx-jeonghwa2-q19-answer-${i + 1}`,
      source: 'hwpx_original_answer',
      provider: 'hwpx',
      model: 'source-hwpx-bindata',
      status: 'copied_from_source',
      approved: true,
      review_required: false,
      bucket: 'problem-previews',
      path: objectPath,
      mime_type: 'image/png',
      confidence: 1,
      figure_index: i + 1,
      item_id: itemId,
      reference_entry: entry.entryName,
      created_at: nowIso,
    });
  }

  const nextSubjectiveAnswer = String(question.subjective_answer || prevMeta.subjective_answer || '')
    .replace(/\[\[PB_ANSWER_FIG_[^\]]+\]\]/g, '[그림]')
    .replace(/\[\s*image\s*\]/gi, '[그림]');
  const nextMeta = {
    ...prevMeta,
    subjective_answer: nextSubjectiveAnswer,
    answer_figure_assets: assets,
    answer_figure_layout: {
      version: 1,
      verticalAlign: 'top',
      items: assets.map((asset, idx) => ({
        assetKey: `idx:${idx + 1}`,
        widthEm: 10,
        verticalAlign: 'top',
        topOffsetEm: 0.55,
      })),
    },
  };

  if (APPLY) {
    const { error } = await supa
      .from('pb_questions')
      .update({
        subjective_answer: nextSubjectiveAnswer,
        meta: nextMeta,
        updated_at: nowIso,
      })
      .eq('id', question.id);
    if (error) throw new Error(`q19 answer figure update failed: ${error.message}`);
  }

  return {
    sourcePath,
    uploaded: APPLY,
    answer: nextSubjectiveAnswer,
    assets: assets.map((asset) => ({
      item_id: asset.item_id,
      reference_entry: asset.reference_entry,
      path: asset.path,
    })),
  };
}

async function verifyQuestion(qid) {
  const { data: q, error } = await supa
    .from('pb_questions')
    .select('*')
    .eq('id', qid)
    .single();
  if (error) throw new Error(`verify select failed: ${error.message}`);
  const meta = q.meta && typeof q.meta === 'object' ? q.meta : {};
  const asset = Array.isArray(meta.figure_assets) ? meta.figure_assets[0] : null;
  const answerAssets = Array.isArray(meta.answer_figure_assets) ? meta.answer_figure_assets : [];
  const result = {
    id: q.id,
    number: q.question_number,
    stem: q.stem,
    figure_refs: Array.isArray(q.figure_refs) ? q.figure_refs.length : 0,
    figure_asset: asset ? {
      source: asset.source,
      provider: asset.provider,
      reference_entry: asset.reference_entry,
      bucket: asset.bucket,
      path: asset.path,
      mime_type: asset.mime_type,
    } : null,
    figure_layout: meta.figure_layout || null,
    answer_figure_assets: answerAssets.length,
    answer_figure_asset_details: answerAssets.map((answerAsset) => ({
      source: answerAsset.source,
      provider: answerAsset.provider,
      model: answerAsset.model,
      item_id: answerAsset.item_id,
      reference_entry: answerAsset.reference_entry,
      bucket: answerAsset.bucket,
      path: answerAsset.path,
      mime_type: answerAsset.mime_type,
    })),
    objective_answer_key: q.objective_answer_key,
    subjective_answer: q.subjective_answer,
    explanation: q.explanation,
  };
  if (asset?.bucket && asset?.path) {
    const { data, error: downErr } = await supa.storage.from(asset.bucket).download(asset.path);
    if (downErr) throw new Error(`verify download failed: ${downErr.message}`);
    result.download_bytes = Buffer.from(await data.arrayBuffer()).length;
  }
  result.answer_figure_download_bytes = [];
  for (const answerAsset of answerAssets) {
    if (!answerAsset?.bucket || !answerAsset?.path) continue;
    const { data, error: downErr } = await supa.storage
      .from(answerAsset.bucket)
      .download(answerAsset.path);
    if (downErr) throw new Error(`verify answer image download failed: ${downErr.message}`);
    result.answer_figure_download_bytes.push(Buffer.from(await data.arrayBuffer()).length);
  }
  return result;
}

async function main() {
  const { candidates, target } = await findJeonghwa2Document();
  if (!target) {
    console.error('정화중 문서 후보를 찾지 못했습니다.');
    process.exit(1);
  }

  console.log('정화중 후보:');
  candidates.forEach(({ doc, wanted }, idx) => {
    console.log(`${idx + 1}. ${doc.source_filename} (${doc.id}) q=${[...wanted.keys()].join(',')}`);
  });
  console.log(`대상 문서: ${target.doc.source_filename}`);

  const q15 = target.wanted.get('15');
  const q16 = target.wanted.get('16');
  const q19 = target.wanted.get('19');
  if (!q15 || !q16 || !q19) {
    throw new Error(`필수 문항 누락: q15=${Boolean(q15)} q16=${Boolean(q16)} q19=${Boolean(q19)}`);
  }

  if (DIAGNOSE) {
    console.log('--- q15 ---');
    console.log(JSON.stringify(summarizeQuestion(q15), null, 2));
    console.log('--- q16 ---');
    console.log(JSON.stringify(summarizeQuestion(q16), null, 2));
    console.log('q16 align preview:', JSON.stringify(alignCdotTextTwo(q16.stem), null, 2));
    console.log('--- q19 ---');
    console.log(JSON.stringify(summarizeQuestion(q19), null, 2));
    console.log('q19 answer sidecar:', JSON.stringify(await answerSidecarForQuestion(q19), null, 2));
    return;
  }

  if (VERIFY) {
    console.log('--- verify q15 ---');
    console.log(JSON.stringify(await verifyQuestion(q15.id), null, 2));
    console.log('--- verify q16 ---');
    console.log(JSON.stringify(await verifyQuestion(q16.id), null, 2));
    console.log('--- verify q19 ---');
    console.log(JSON.stringify(await verifyQuestion(q19.id), null, 2));
    console.log('q19 answer sidecar:', JSON.stringify(await answerSidecarForQuestion(q19), null, 2));
    return;
  }

  const q15Result = SKIP_Q15
    ? null
    : await applyQ15({ doc: target.doc, question: q15 });
  const q16Result = await applyQ16({ question: q16 });
  const q19Result = APPLY_Q19_ANSWER_FIGURES
    ? await applyQ19AnswerFigures({ doc: target.doc, question: q19 })
    : null;
  if (q15Result != null) {
    console.log('q15 적용:', JSON.stringify({
      bytes: q15Result.bytes,
      objectPath: q15Result.objectPath,
      hasFigureMarker: /\[(?:그림|도형|도표|표)\]/.test(q15Result.nextStem),
    }, null, 2));
  } else {
    console.log('q15 적용: skip');
  }
  console.log('q16 적용:', JSON.stringify(q16Result, null, 2));
  if (q19Result != null) {
    console.log('q19 정답 그림 적용:', JSON.stringify(q19Result, null, 2));
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
