import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { renderQuestionPreview } from './problem_bank/render_engine/index.js';

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(MODULE_DIR, '..', '..');

const FONT_PATH_REGULAR =
  process.env.PB_PDF_FONT_PATH || 'C:\\Windows\\Fonts\\malgun.ttf';
const FONT_PATH_BOLD =
  process.env.PB_PDF_FONT_BOLD_PATH || 'C:\\Windows\\Fonts\\malgunbd.ttf';
const FONT_PATH_KOPUB_BATANG_LIGHT =
  process.env.PB_PDF_FONT_KOPUB_BATANG_LIGHT_PATH || '';
const FONT_PATH_QNUM =
  process.env.PB_PDF_FONT_QNUM_PATH || '';

const PREVIEW_BUCKET = 'problem-previews';
const SIGNED_URL_EXPIRY_SECONDS = 3600;
const PREVIEW_VIEWPORT_WIDTH = 480;

function repoAssetPath(...segments) {
  return path.resolve(REPO_ROOT, ...segments);
}

function pickExistingPath(candidates) {
  for (const c of candidates) {
    const s = String(c || '').trim();
    if (s && fs.existsSync(s)) return s;
  }
  return '';
}

function getDefaultFontPaths() {
  const repoKopubLight = repoAssetPath(
    'apps', 'yggdrasill', 'assets', 'fonts', 'kopub',
    'KoPubWorldBatangProLight.otf',
  );
  const repoQnumFont = repoAssetPath(
    'apps', 'yggdrasill', 'assets', 'fonts', 'chosun', 'ChosunNm.ttf',
  );
  return {
    regularPath: pickExistingPath([FONT_PATH_KOPUB_BATANG_LIGHT, repoKopubLight, FONT_PATH_REGULAR]),
    boldPath: pickExistingPath([FONT_PATH_KOPUB_BATANG_LIGHT, repoKopubLight, FONT_PATH_BOLD]),
    qnumFontPath: pickExistingPath([FONT_PATH_QNUM, repoQnumFont]),
  };
}

function questionContentHash(question) {
  const payload = JSON.stringify({
    stem: question?.stem || '',
    choices: question?.choices || [],
    equations: question?.equations || [],
    figure_refs: question?.figure_refs || [],
    meta_figure_assets: question?.meta?.figure_assets || [],
  });
  return createHash('sha256').update(payload).digest('hex').slice(0, 16);
}

let bucketEnsured = false;
async function ensureBucketExists(supabaseClient) {
  if (bucketEnsured) return;
  try {
    const { error } = await supabaseClient.storage.createBucket(PREVIEW_BUCKET, {
      public: false,
      fileSizeLimit: 5 * 1024 * 1024,
    });
    if (error && !error.message?.includes('already exists')) {
      console.warn(`[preview] bucket create warning: ${error.message}`);
    }
  } catch (_) {}
  bucketEnsured = true;
}

export async function generateQuestionPreviews({
  questions,
  academyId,
  layout,
  supabaseClient,
}) {
  if (!supabaseClient) throw new Error('supabaseClient is required');
  if (!Array.isArray(questions) || questions.length === 0) return [];

  await ensureBucketExists(supabaseClient);

  const fontPaths = getDefaultFontPaths();
  const results = [];

  for (const question of questions) {
    const qId = String(question?.id || question?.question_id || '');
    if (!qId) {
      results.push({ questionId: qId, imageUrl: null, error: 'no question id' });
      continue;
    }

    const hash = questionContentHash(question);
    const storagePath = `${academyId || 'global'}/q_${qId}_${hash}.png`;

    try {
      const { data: existing } = await supabaseClient.storage
        .from(PREVIEW_BUCKET)
        .createSignedUrl(storagePath, SIGNED_URL_EXPIRY_SECONDS);

      if (existing?.signedUrl) {
        results.push({ questionId: qId, imageUrl: existing.signedUrl, cached: true });
        continue;
      }
    } catch (_) {
      // no cached version
    }

    try {
      const { pngBuffer } = await renderQuestionPreview({
        question,
        fontRegularPath: fontPaths.regularPath,
        boldPath: fontPaths.boldPath,
        qnumFontPath: fontPaths.qnumFontPath,
        layout: layout || {},
        supabaseClient,
        viewportWidth: PREVIEW_VIEWPORT_WIDTH,
      });

      const { error: uploadErr } = await supabaseClient.storage
        .from(PREVIEW_BUCKET)
        .upload(storagePath, pngBuffer, {
          contentType: 'image/png',
          upsert: true,
        });

      if (uploadErr) {
        console.error(`[preview] upload failed for q ${qId}:`, uploadErr.message);
        results.push({ questionId: qId, imageUrl: null, error: uploadErr.message });
        continue;
      }

      const { data: signed, error: signErr } = await supabaseClient.storage
        .from(PREVIEW_BUCKET)
        .createSignedUrl(storagePath, SIGNED_URL_EXPIRY_SECONDS);

      if (signErr || !signed?.signedUrl) {
        results.push({ questionId: qId, imageUrl: null, error: signErr?.message || 'sign failed' });
        continue;
      }

      results.push({ questionId: qId, imageUrl: signed.signedUrl, cached: false });
    } catch (err) {
      console.error(`[preview] render failed for q ${qId}:`, err.message);
      results.push({ questionId: qId, imageUrl: null, error: err.message });
    }
  }

  return results;
}
