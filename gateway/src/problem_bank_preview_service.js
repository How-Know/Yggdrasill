import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import {
  renderQuestionPreview,
  buildQuestionPreviewHtml,
  buildDocumentPreviewHtml,
} from './problem_bank/render_engine/index.js';

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
const FONT_PATH_SUBJECT =
  process.env.PB_PDF_FONT_SUBJECT_PATH || '';

const PREVIEW_BUCKET = 'problem-previews';
const SIGNED_URL_EXPIRY_SECONDS = 3600;
const PREVIEW_VIEWPORT_WIDTH = 520;
const PREVIEW_DPR = 3;
const PREVIEW_STYLE_VERSION = 'pv43_size10_margin';
const DEBUG_MATH_DOTS = process.env.PB_DEBUG_MATH_DOTS === '1';

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
    subjectFontPath: pickExistingPath([
      FONT_PATH_SUBJECT,
      'C:\\Users\\harry\\Downloads\\apple\uC0B0\uB3CC\uACE0\uB515\uB124\uC6242\\apple\uC0B0\uB3CC\uACE0\uB515\uB124\uC6242\\AppleSDGothicNeoB.ttf',
      'C:\\Users\\harry\\Downloads\\apple\uC0B0\uB3CC\uACE0\uB515\uB124\uC6242\\apple\uC0B0\uB3CC\uACE0\uB515\uB124\uC6242\\AppleSDGothicNeoH.ttf',
      'C:\\Users\\harry\\Downloads\\apple\uC0B0\uB3CC\uACE0\uB515\uB124\uC6242\\apple\uC0B0\uB3CC\uACE0\uB515\uB124\uC6242\\AppleSDGothicNeoEB.ttf',
      'C:\\Users\\harry\\Downloads\\apple\uC0B0\uB3CC\uACE0\uB515\uB124\uC6242\\apple\uC0B0\uB3CC\uACE0\uB515\uB124\uC6242\\AppleSDGothicNeoL.ttf',
      FONT_PATH_BOLD,
      FONT_PATH_REGULAR,
    ]),
  };
}

function questionContentHash(question, mathEngine) {
  const meta = question?.meta && typeof question.meta === 'object' ? question.meta : {};
  const stemLineAligns = Array.isArray(meta.stem_line_aligns)
    ? meta.stem_line_aligns
    : Array.isArray(meta.stemLineAligns)
      ? meta.stemLineAligns
      : [];
  const payload = JSON.stringify({
    style_version: PREVIEW_STYLE_VERSION,
    math_engine: mathEngine || 'mathjax-svg',
    stem: question?.stem || '',
    choices: question?.choices || [],
    equations: question?.equations || [],
    figure_refs: question?.figure_refs || [],
    meta_stem_line_aligns: stemLineAligns,
    meta_figure_assets: meta.figure_assets || [],
    meta_figure_layout: meta.figure_layout || null,
    meta_figure_render_scales: meta.figure_render_scales || null,
    meta_figure_horizontal_pairs: meta.figure_horizontal_pairs || null,
    meta_figure_render_scale: meta.figure_render_scale ?? null,
    meta_table_scales: meta.table_scales || null,
    meta_table_scale_default: meta.table_scale_default || null,
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
  force = false,
  mathEngine,
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

    const hash = questionContentHash(question, mathEngine);
    const storagePath = `${academyId || 'global'}/q_${qId}_${hash}.png`;

    if (!force) {
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
        deviceScaleFactor: PREVIEW_DPR,
        debugDots: DEBUG_MATH_DOTS,
        mathEngine,
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

export async function getStoredPreviewUrls({
  questions,
  academyId,
  supabaseClient,
}) {
  if (!supabaseClient || !Array.isArray(questions) || questions.length === 0) return [];
  const results = [];
  for (const question of questions) {
    const qId = String(question?.id || question?.question_id || '');
    if (!qId) { results.push({ questionId: qId, imageUrl: null }); continue; }
    const hash = questionContentHash(question);
    const storagePath = `${academyId || 'global'}/q_${qId}_${hash}.png`;
    try {
      const { data } = await supabaseClient.storage
        .from(PREVIEW_BUCKET)
        .createSignedUrl(storagePath, SIGNED_URL_EXPIRY_SECONDS);
      results.push({ questionId: qId, imageUrl: data?.signedUrl || null, cached: true });
    } catch (_) {
      results.push({ questionId: qId, imageUrl: null });
    }
  }
  return results;
}

export async function buildPreviewHtmlBatch({
  questions,
  layout,
  supabaseClient,
}) {
  const fontPaths = getDefaultFontPaths();
  const results = [];
  for (const question of questions) {
    const qId = String(question?.id || question?.question_id || '');
    try {
      const html = await buildQuestionPreviewHtml({
        question,
        fontRegularPath: fontPaths.regularPath,
        boldPath: fontPaths.boldPath,
        qnumFontPath: fontPaths.qnumFontPath,
        layout: layout || {},
        supabaseClient,
      });
      results.push({ questionId: qId, html });
    } catch (err) {
      results.push({ questionId: qId, html: null, error: err.message });
    }
  }
  return results;
}

export async function buildDocumentHtmlForPreview({
  questions,
  renderConfig,
  profile,
  paper,
  baseLayout,
  maxQuestionsPerPage,
  supabaseClient,
}) {
  const fontPaths = getDefaultFontPaths();
  return buildDocumentPreviewHtml({
    questions,
    renderConfig,
    profile,
    paper,
    fontRegularPath: fontPaths.regularPath,
    fontBoldPath: fontPaths.boldPath,
    qnumFontPath: fontPaths.qnumFontPath,
    subjectFontPath: fontPaths.subjectFontPath,
    baseLayout,
    supabaseClient,
    maxQuestionsPerPage,
  });
}

