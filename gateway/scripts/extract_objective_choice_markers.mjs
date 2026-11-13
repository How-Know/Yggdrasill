import 'dotenv/config';
import { execFile as execFileCb } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import { createClient } from '@supabase/supabase-js';
import sharp from 'sharp';
import {
  extractChoiceMarkersFromProblemCrop,
  mapCropChoicesToPage1k,
  validatePageChoiceMarkers,
} from '../src/textbook/vlm_choice_markers.js';

const execFileAsync = promisify(execFileCb);

function parseArg(name, fallback = '') {
  const prefix = `--${name}=`;
  const hit = process.argv.find((a) => a.startsWith(prefix));
  if (hit) return hit.slice(prefix.length);
  const idx = process.argv.indexOf(`--${name}`);
  if (idx >= 0 && idx + 1 < process.argv.length) return process.argv[idx + 1];
  return fallback;
}

const BOOK_ID = parseArg('book', 'c3ae29ad-4d99-4078-8381-00357074d151');
const GRADE_LABEL = parseArg('grade', '1-1');
const ONLY_PAGE = Number.parseInt(parseArg('page', '0'), 10) || 0;
const DRY_RUN = process.argv.includes('--dry-run');
const VIS = process.argv.includes('--vis');
const FORCE = process.argv.includes('--force');
const CONCURRENCY = Math.max(
  1,
  Number.parseInt(parseArg('concurrency', '6'), 10) || 6,
);

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  throw new Error('Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY');
}
const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

async function ensureBodyPdfCached() {
  const { data: link, error } = await sb
    .from('resource_file_links')
    .select('id,storage_bucket,storage_key,content_hash,file_size_bytes')
    .eq('file_id', BOOK_ID)
    .eq('grade', `${GRADE_LABEL}#body`)
    .not('storage_key', 'is', null)
    .order('created_at', { ascending: false })
    .limit(1)
    .single();
  if (error || !link) throw new Error(`body_link_missing:${error?.message}`);
  const dir =
    process.env.TEXTBOOK_PDF_CACHE_DIR ||
    path.join(os.tmpdir(), 'ygg-textbook-src');
  fs.mkdirSync(dir, { recursive: true });
  const shortHash =
    String(link.content_hash || '')
      .replace(/[^a-z0-9]/gi, '')
      .slice(0, 16) || 'nohash';
  const cachePath = path.join(dir, `${link.id}_${shortHash}.pdf`);
  if (fs.existsSync(cachePath)) {
    const st = fs.statSync(cachePath);
    if (!link.file_size_bytes || st.size === Number(link.file_size_bytes)) {
      return cachePath;
    }
  }
  const { data: signed, error: signErr } = await sb.storage
    .from(link.storage_bucket)
    .createSignedUrl(link.storage_key, 3600);
  if (signErr || !signed?.signedUrl) throw new Error('body_signed_url_failed');
  const resp = await fetch(signed.signedUrl);
  if (!resp.ok) throw new Error(`body_download_failed:${resp.status}`);
  fs.writeFileSync(cachePath, Buffer.from(await resp.arrayBuffer()));
  return cachePath;
}

async function main() {
  const srcPdf = await ensureBodyPdfCached();
  console.log('[choice-extract] source PDF:', srcPdf);

  let crops = [];
  let from = 0;
  while (true) {
    let q = sb
      .from('textbook_problem_crops')
      .select('id,raw_page,problem_number,item_region_1k,choice_regions_1k')
      .eq('book_id', BOOK_ID)
      .eq('grade_label', GRADE_LABEL)
      .eq('is_set_header', false);
    if (ONLY_PAGE > 0) q = q.eq('raw_page', ONLY_PAGE);
    const { data, error } = await q.range(from, from + 999);
    if (error) throw error;
    if (!data || !data.length) break;
    crops.push(...data);
    if (data.length < 1000) break;
    from += 1000;
  }

  // Filter to objective crops
  const cropIds = crops.map((c) => c.id);
  const objIds = new Set();
  for (let i = 0; i < cropIds.length; i += 200) {
    const { data, error } = await sb
      .from('textbook_problem_answers')
      .select('crop_id,answer_kind')
      .in('crop_id', cropIds.slice(i, i + 200))
      .eq('answer_kind', 'objective');
    if (error) throw error;
    for (const r of data || []) objIds.add(r.crop_id);
  }

  const targets = crops.filter(
    (c) =>
      objIds.has(c.id) &&
      Array.isArray(c.item_region_1k) &&
      c.item_region_1k.length === 4 &&
      (FORCE || !c.choice_regions_1k),
  );
  console.log(
    `[choice-extract] total crops=${crops.length}, objective=${objIds.size}, pending=${targets.length}`,
  );
  if (targets.length === 0) return;

  const byPage = new Map();
  for (const c of targets) {
    const arr = byPage.get(c.raw_page) || [];
    arr.push(c);
    byPage.set(c.raw_page, arr);
  }
  const pages = [...byPage.keys()].sort((a, b) => a - b);

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'ygg-choice-'));
  let promptTokens = 0;
  let outputTokens = 0;
  let savedCount = 0;
  let noChoicesCount = 0;
  let invalidCount = 0;
  const startedAt = Date.now();

  try {
    for (const rawPage of pages) {
      const pageCrops = byPage.get(rawPage);
      const outPrefix = path.join(tmpDir, `p_${rawPage}`);
      await execFileAsync(
        'pdftoppm',
        ['-png', '-r', '180', '-f', String(rawPage), '-l', String(rawPage), srcPdf, outPrefix],
        { maxBuffer: 16 * 1024 * 1024, windowsHide: true },
      );
      const pngName = fs
        .readdirSync(tmpDir)
        .find((f) => f.startsWith(`p_${rawPage}-`) && f.endsWith('.png'));
      if (!pngName) throw new Error(`pdftoppm_missing_p${rawPage}`);
      const pagePath = path.join(tmpDir, pngName);
      const pageMeta = await sharp(pagePath).metadata();
      const pageW = pageMeta.width;
      const pageH = pageMeta.height;

      const visRects = [];
      for (let i = 0; i < pageCrops.length; i += CONCURRENCY) {
        const chunk = pageCrops.slice(i, i + CONCURRENCY);
        await Promise.all(
          chunk.map(async (crop) => {
            const r = crop.item_region_1k;
            const cropY = Math.max(0, Math.floor(((r[0] - 10) / 1000) * pageH));
            const cropX = Math.max(0, Math.floor(((r[1] - 14) / 1000) * pageW));
            const cropBottom = Math.min(
              pageH,
              Math.ceil(((r[2] + 18) / 1000) * pageH),
            );
            const cropRight = Math.min(
              pageW,
              Math.ceil(((r[3] + 14) / 1000) * pageW),
            );
            const cropW = cropRight - cropX;
            const cropH = cropBottom - cropY;
            if (cropW < 10 || cropH < 10) return;

            const cropBuf = await sharp(pagePath)
              .extract({ left: cropX, top: cropY, width: cropW, height: cropH })
              .png()
              .toBuffer();

            const result = await extractChoiceMarkersFromProblemCrop({
              imageBase64: cropBuf.toString('base64'),
            });
            promptTokens += Number(result.usageMetadata?.promptTokenCount || 0);
            outputTokens += Number(
              result.usageMetadata?.candidatesTokenCount || 0,
            );

            if (!result.hasChoices) {
              noChoicesCount += 1;
              if (!DRY_RUN) {
                await sb
                  .from('textbook_problem_crops')
                  .update({ choice_regions_1k: {} })
                  .eq('id', crop.id);
              }
              console.log(
                `  p.${rawPage} #${crop.problem_number}: no printed choices`,
              );
              return;
            }

            const mapped = mapCropChoicesToPage1k({
              choices: result.choices,
              cropX,
              cropY,
              cropW,
              cropH,
              pageW,
              pageH,
            });
            const check = validatePageChoiceMarkers(mapped, r);
            if (!check.ok) {
              invalidCount += 1;
              console.warn(
                `  p.${rawPage} #${crop.problem_number}: invalid (${check.reason})`,
                mapped,
              );
              return;
            }
            savedCount += 1;
            if (VIS) {
              for (const b of Object.values(mapped)) {
                visRects.push(b);
              }
            }
            if (!DRY_RUN) {
              const { error: upErr } = await sb
                .from('textbook_problem_crops')
                .update({ choice_regions_1k: mapped })
                .eq('id', crop.id);
              if (upErr) throw upErr;
            } else {
              console.log(`  p.${rawPage} #${crop.problem_number}:`, mapped);
            }
          }),
        );
      }

      if (VIS && visRects.length > 0) {
        const rectsSvg = visRects
          .map((b) => {
            const rx = (b[1] / 1000) * pageW;
            const ry = (b[0] / 1000) * pageH;
            const rw = Math.max(4, ((b[3] - b[1]) / 1000) * pageW);
            const rh = Math.max(4, ((b[2] - b[0]) / 1000) * pageH);
            return `<rect x="${rx}" y="${ry}" width="${rw}" height="${rh}" fill="none" stroke="#00aa55" stroke-width="3"/>`;
          })
          .join('');
        const svg = Buffer.from(
          `<svg width="${pageW}" height="${pageH}">${rectsSvg}</svg>`,
        );
        const visOut = path.join(os.tmpdir(), `choice_vis_p${rawPage}.png`);
        await sharp(pagePath)
          .composite([{ input: svg, top: 0, left: 0 }])
          .png()
          .toFile(visOut);
        console.log('[choice-extract] vis saved:', visOut);
      }
      fs.rmSync(pagePath, { force: true });
    }
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }

  console.log('[choice-extract] summary:', {
    elapsedSec: ((Date.now() - startedAt) / 1000).toFixed(1),
    pages: pages.length,
    savedCount,
    noChoicesCount,
    invalidCount,
    promptTokens,
    outputTokens,
  });
}

main().catch((err) => {
  console.error('[choice-extract] fatal:', err);
  process.exit(1);
});
