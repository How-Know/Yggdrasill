/**
 * XeLaTeX-based question renderer.
 *
 * Two entry points:
 *   renderQuestionWithXeLatex   — single question -> PNG
 *   renderPdfWithXeLatex        — full document   -> PDF buffer
 */

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import sharp from 'sharp';
import { checkXeLatexInstallation, getXeLatexBinary } from './check_installation.js';
import { buildTexSource, buildDocumentTexSource, buildAnswerTexSource } from './template.js';

/**
 * data:<mime>;base64,<...> 형태의 로고 이미지를 workDir 내 파일로 저장하고 경로를 돌려준다.
 * XeLaTeX 은 data URL 을 직접 \includegraphics 로 읽지 못하므로 로컬 파일이 필요.
 * 반환: 절대경로 (저장 성공 시) 또는 ''.
 */
function materializeDataUrlLogo(dataUrl, workDir) {
  if (typeof dataUrl !== 'string') return '';
  const m = dataUrl.match(/^data:image\/(png|jpeg|jpg|gif|webp);base64,([A-Za-z0-9+/=]+)$/);
  if (!m) return '';
  const ext = (m[1] === 'jpeg' ? 'jpg' : m[1]).toLowerCase();
  const bytes = Buffer.from(m[2], 'base64');
  if (!bytes || bytes.length === 0) return '';
  const outPath = path.join(workDir, `academy-logo.${ext}`);
  try {
    fs.writeFileSync(outPath, bytes);
    return outPath;
  } catch (err) {
    console.warn('[xelatex] academy logo materialize failed:', err?.message || err);
    return '';
  }
}

const XELATEX_TIMEOUT_MS = 30_000;

async function waitForFile(filePath, timeoutMs = 3000) {
  const started = Date.now();
  while (Date.now() - started <= timeoutMs) {
    if (fs.existsSync(filePath)) return true;
    await new Promise((resolve) => setTimeout(resolve, 80));
  }
  return fs.existsSync(filePath);
}

function runXeLatex(texPath, outDir) {
  const bin = getXeLatexBinary();
  const baseName = path.basename(texPath, '.tex');
  const logPath = path.join(outDir, `${baseName}.log`);
  return new Promise((resolve, reject) => {
    execFile(
      bin,
      [
        '-interaction=nonstopmode',
        '-halt-on-error',
        `-output-directory=${outDir}`,
        texPath,
      ],
      { timeout: XELATEX_TIMEOUT_MS, cwd: outDir },
      (err, stdout, stderr) => {
        if (err) {
          let logTail = '';
          if (fs.existsSync(logPath)) {
            logTail = fs.readFileSync(logPath, 'utf-8').slice(-4000);
          }
          const texSnippet = fs.existsSync(texPath)
            ? fs.readFileSync(texPath, 'utf-8').slice(0, 2000)
            : '';
          console.error('[xelatex] compilation failed\n--- .tex head ---\n' + texSnippet + '\n--- log tail ---\n' + logTail);
          reject(new Error(`xelatex failed: ${err.message}\n--- log tail ---\n${logTail}`));
        } else {
          resolve({ stdout, stderr });
        }
      },
    );
  });
}

function renderPdfPageWithPdftoppm(pdfPath, outDir, {
  dpi = 220,
  baseName = 'answer-page',
} = {}) {
  const pngBase = path.join(outDir, baseName);
  return new Promise((resolve, reject) => {
    execFile(
      'pdftoppm',
      ['-f', '1', '-singlefile', '-png', '-r', String(dpi), pdfPath, pngBase],
      { timeout: 120_000, cwd: outDir },
      (err) => {
        if (err) {
          reject(new Error(`pdftoppm failed: ${err.message}`));
          return;
        }
        const pngPath = `${pngBase}.png`;
        if (!fs.existsSync(pngPath)) {
          reject(new Error('pdftoppm produced no PNG output.'));
          return;
        }
        resolve(fs.readFileSync(pngPath));
      },
    );
  });
}

/**
 * Download figure assets from Supabase Storage into the XeLaTeX work
 * directory so that \includegraphics can reference them as local files.
 * Populates question.figure_local_paths = string[] on each question.
 */
export async function hydrateFiguresForXeLatex(questions, supabaseClient, workDir) {
  if (!supabaseClient || !workDir) return { appliedCount: 0 };
  let appliedCount = 0;
  for (const q of questions) {
    q.figure_local_paths = [];
    q.figure_local_infos = [];
    q.answer_figure_local_paths = [];
    q.answer_figure_local_infos = [];
    const meta = q.meta && typeof q.meta === 'object' ? q.meta : {};
    const assetSets = [
      {
        assets: Array.isArray(meta.figure_assets) ? meta.figure_assets : [],
        paths: q.figure_local_paths,
        infos: q.figure_local_infos,
        prefix: 'fig',
      },
      {
        assets: Array.isArray(meta.answer_figure_assets)
          ? meta.answer_figure_assets
          : [],
        paths: q.answer_figure_local_paths,
        infos: q.answer_figure_local_infos,
        prefix: 'answer-fig',
      },
    ];

    for (const set of assetSets) {
      const assets = set.assets;
      if (assets.length === 0) continue;

      // figure_index 기준 중복 제거 시 approved=true 를 우선, 동률이면 created_at 최신 우선.
      const byIdx = new Map();
      for (const a of assets) {
        const idx = Number.parseInt(String(a?.figure_index ?? ''), 10);
        if (!Number.isFinite(idx) || idx <= 0) continue;
        const prev = byIdx.get(idx);
        if (!prev) { byIdx.set(idx, a); continue; }
        const prevApproved = prev?.approved === true ? 1 : 0;
        const curApproved = a?.approved === true ? 1 : 0;
        if (curApproved > prevApproved) { byIdx.set(idx, a); continue; }
        if (curApproved < prevApproved) continue;
        const prevCreated = String(prev?.created_at || '');
        const curCreated = String(a?.created_at || '');
        if (curCreated.localeCompare(prevCreated) > 0) byIdx.set(idx, a);
      }
      const deduped = [...byIdx.values()].sort(
        (a, b) => (a.figure_index || 0) - (b.figure_index || 0),
      );

      let ordinal = 0;
      for (const asset of deduped) {
        const bucket = String(asset?.bucket || '').trim();
        const storagePath = String(asset?.path || '').trim();
        if (!bucket || !storagePath) continue;
        try {
          const { data, error } = await supabaseClient.storage
            .from(bucket)
            .download(storagePath);
          if (error || !data) continue;
          const ext = (asset.mime_type || 'image/png').split('/').pop() || 'png';
          const qid = q.id || q.question_uid || randomUUID();
          const filename = `${set.prefix}-${qid}-${asset.figure_index || 0}.${ext}`;
          const filePath = path.join(workDir, filename);
          fs.writeFileSync(filePath, Buffer.from(await data.arrayBuffer()));
          ordinal += 1;
          const figIdx = Number.parseInt(String(asset?.figure_index ?? ''), 10);
          const assetKey = Number.isFinite(figIdx) && figIdx > 0
            ? `idx:${figIdx}`
            : (asset?.path ? `path:${asset.path}` : `ord:${ordinal}`);
          set.paths.push(filePath);
          set.infos.push({
            path: filePath,
            assetKey,
            // HWPX binaryItemIDRef. 본문의 [[PB_FIG_<id>]] 토큰 치환 시 item_id 일치하는
            //   asset 을 직접 선택하는 용도. figure_worker 가 생성 시 보존하고, 이 값이
            //   존재하면 순서·개수 추측을 완전히 우회한다.
            itemId: String(asset?.item_id || '').trim(),
            figureIndex: Number.isFinite(figIdx) && figIdx > 0 ? figIdx : ordinal,
            ordinal,
            mimeType: asset.mime_type || 'image/png',
          });
          appliedCount += 1;
        } catch (_) {
          /* skip failed downloads */
        }
      }
    }
  }
  return { appliedCount };
}

function ensureInstalled() {
  return checkXeLatexInstallation().then((status) => {
    if (!status.installed) {
      throw new Error(
        'XeLaTeX이 설치되어 있지 않습니다. TeX Live를 설치해주세요.\n' +
        '다운로드: https://mirror.ctan.org/systems/texlive/tlnet/install-tl-windows.exe\n' +
        `상세: ${status.error || 'xelatex not found in PATH'}`,
      );
    }
    return status;
  });
}

function countPdfPages(pdfPath) {
  const buf = fs.readFileSync(pdfPath);
  const str = buf.toString('latin1');
  const matches = str.match(/\/Type\s*\/Page(?!s)/g);
  return matches ? matches.length : 1;
}

function normalizeHexColor(raw, fallback = 'EAF2F7') {
  const cleaned = String(raw || fallback).replace(/[^0-9A-Fa-f]/g, '').slice(0, 6);
  return cleaned.length === 6 ? cleaned.toUpperCase() : fallback;
}

async function makeWhiteBackgroundTransparent(pngBuffer, {
  textColor = 'EAF2F7',
  backgroundColor = '151C21',
  transparent = true,
  paddingPx = 12,
  topPaddingPx = 22,
  bottomPaddingPx = 14,
  alphaGamma = 0.68,
  cropAlphaThreshold = 3,
  topBleedPx = 0,
  strokePx = 0,
} = {}) {
  const color = normalizeHexColor(textColor);
  const rgb = [
    Number.parseInt(color.slice(0, 2), 16),
    Number.parseInt(color.slice(2, 4), 16),
    Number.parseInt(color.slice(4, 6), 16),
  ];
  const background = normalizeHexColor(backgroundColor, '151C21');
  const bgRgb = [
    Number.parseInt(background.slice(0, 2), 16),
    Number.parseInt(background.slice(2, 4), 16),
    Number.parseInt(background.slice(4, 6), 16),
  ];
  const { data, info } = await sharp(pngBuffer)
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const { width, height, channels } = info;
  const alphaData = new Uint8Array(width * height);
  let minX = width;
  let minY = height;
  let maxX = -1;
  let maxY = -1;
  const safeGamma = Number.isFinite(Number(alphaGamma))
    ? Math.max(0.35, Math.min(1.2, Number(alphaGamma)))
    : 0.68;

  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const idx = (y * width + x) * channels;
      const r = data[idx];
      const g = data[idx + 1];
      const b = data[idx + 2];
      const darkness = 255 - Math.min(r, g, b);
      const normalized = Math.max(0, Math.min(1, darkness / 255));
      const alpha = normalized <= 0
        ? 0
        : Math.max(0, Math.min(255, Math.round(255 * Math.pow(normalized, safeGamma))));
      alphaData[y * width + x] = alpha;
      if (alpha > cropAlphaThreshold) {
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;
      }
    }
  }

  const radius = Math.max(0, Math.min(2, Math.round(Number(strokePx) || 0)));
  const finalAlphaData = radius > 0 ? new Uint8Array(alphaData) : alphaData;
  if (radius > 0) {
    for (let y = 0; y < height; y += 1) {
      for (let x = 0; x < width; x += 1) {
        let maxAlpha = alphaData[y * width + x];
        for (let dy = -radius; dy <= radius; dy += 1) {
          const yy = y + dy;
          if (yy < 0 || yy >= height) continue;
          for (let dx = -radius; dx <= radius; dx += 1) {
            const xx = x + dx;
            if (xx < 0 || xx >= width) continue;
            const candidate = alphaData[yy * width + xx];
            if (candidate > maxAlpha) maxAlpha = candidate;
          }
        }
        finalAlphaData[y * width + x] = maxAlpha;
        if (maxAlpha > cropAlphaThreshold) {
          if (x < minX) minX = x;
          if (y < minY) minY = y;
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;
        }
      }
    }
  }

  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const idx = (y * width + x) * channels;
      const alpha = finalAlphaData[y * width + x];
      if (transparent) {
        data[idx] = rgb[0];
        data[idx + 1] = rgb[1];
        data[idx + 2] = rgb[2];
        data[idx + 3] = alpha;
      } else {
        const a = alpha / 255;
        data[idx] = Math.round((rgb[0] * a) + (bgRgb[0] * (1 - a)));
        data[idx + 1] = Math.round((rgb[1] * a) + (bgRgb[1] * (1 - a)));
        data[idx + 2] = Math.round((rgb[2] * a) + (bgRgb[2] * (1 - a)));
        data[idx + 3] = 255;
      }
    }
  }

  if (maxX < minX || maxY < minY) {
    const empty = await sharp({
      create: {
        width: 16,
        height: 16,
        channels: 4,
        background: transparent
          ? { r: 0, g: 0, b: 0, alpha: 0 }
          : { r: bgRgb[0], g: bgRgb[1], b: bgRgb[2], alpha: 1 },
      },
    }).png({ compressionLevel: 9 }).toBuffer();
    return { pngBuffer: empty, width: 16, height: 16 };
  }

  const safeTopBleedPx = Math.max(0, Math.min(8, Math.round(Number(topBleedPx) || 0)));
  const desiredTop = minY - topPaddingPx - safeTopBleedPx;
  const left = Math.max(0, minX - paddingPx);
  const top = Math.max(0, desiredTop);
  const right = Math.min(width - 1, maxX + paddingPx);
  const bottom = Math.min(height - 1, maxY + bottomPaddingPx);
  const cropWidth = Math.max(1, right - left + 1);
  const cropHeight = Math.max(1, bottom - top + 1);
  const extendTop = desiredTop < 0
    ? Math.min(safeTopBleedPx, Math.round(-desiredTop))
    : 0;
  const extendBackground = transparent
    ? { r: 0, g: 0, b: 0, alpha: 0 }
    : { r: bgRgb[0], g: bgRgb[1], b: bgRgb[2], alpha: 1 };
  let pipeline = sharp(data, { raw: { width, height, channels } })
    .extract({ left, top, width: cropWidth, height: cropHeight });
  if (extendTop > 0) {
    pipeline = pipeline.extend({
      top: extendTop,
      bottom: 0,
      left: 0,
      right: 0,
      background: extendBackground,
    });
  }
  const output = await pipeline
    .png({ compressionLevel: 9, adaptiveFiltering: true })
    .toBuffer();
  return { pngBuffer: output, width: cropWidth, height: cropHeight + extendTop };
}

async function cropOpaqueBackground(pngBuffer, {
  backgroundColor = '151C21',
  paddingPx = 12,
  topPaddingPx = 22,
  bottomPaddingPx = 14,
  cropThreshold = 3,
} = {}) {
  const background = normalizeHexColor(backgroundColor, '151C21');
  const bgRgb = [
    Number.parseInt(background.slice(0, 2), 16),
    Number.parseInt(background.slice(2, 4), 16),
    Number.parseInt(background.slice(4, 6), 16),
  ];
  const { data, info } = await sharp(pngBuffer)
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const { width, height, channels } = info;
  let minX = width;
  let minY = height;
  let maxX = -1;
  let maxY = -1;
  const threshold = Math.max(0, Math.min(64, Number(cropThreshold) || 3));

  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const idx = (y * width + x) * channels;
      const diff = Math.max(
        Math.abs(data[idx] - bgRgb[0]),
        Math.abs(data[idx + 1] - bgRgb[1]),
        Math.abs(data[idx + 2] - bgRgb[2]),
      );
      data[idx + 3] = 255;
      if (diff > threshold) {
        if (x < minX) minX = x;
        if (y < minY) minY = y;
        if (x > maxX) maxX = x;
        if (y > maxY) maxY = y;
      }
    }
  }

  if (maxX < minX || maxY < minY) {
    const empty = await sharp({
      create: {
        width: 16,
        height: 16,
        channels: 4,
        background: { r: bgRgb[0], g: bgRgb[1], b: bgRgb[2], alpha: 1 },
      },
    }).png({ compressionLevel: 9 }).toBuffer();
    return { pngBuffer: empty, width: 16, height: 16 };
  }

  const left = Math.max(0, minX - paddingPx);
  const top = Math.max(0, minY - topPaddingPx);
  const right = Math.min(width - 1, maxX + paddingPx);
  const bottom = Math.min(height - 1, maxY + bottomPaddingPx);
  const cropWidth = Math.max(1, right - left + 1);
  const cropHeight = Math.max(1, bottom - top + 1);
  const output = await sharp(data, { raw: { width, height, channels } })
    .extract({ left, top, width: cropWidth, height: cropHeight })
    .png({ compressionLevel: 9, adaptiveFiltering: true })
    .toBuffer();
  return { pngBuffer: output, width: cropWidth, height: cropHeight };
}

// --- Single question -> PNG ---

export async function renderQuestionWithXeLatex({
  question,
  viewportWidth = 400,
  deviceScaleFactor = 3,
  fontFamily,
  fontBold,
}) {
  await ensureInstalled();

  const workDir = path.join(os.tmpdir(), `pb-xelatex-${randomUUID()}`);
  fs.mkdirSync(workDir, { recursive: true });

  const texPath = path.join(workDir, 'question.tex');
  const pdfPath = path.join(workDir, 'question.pdf');

  try {
    const texSource = buildTexSource(question, { fontFamily, fontBold });
    fs.writeFileSync(texPath, texSource, 'utf-8');
    await runXeLatex(texPath, workDir);

    // \pageref{LastPage} (모의고사 페이지박스) 는 2-pass 가 필요하다.
    // - 1-pass 에서는 .aux 에 LastPage 라벨이 기록되지 않아 "??" 로 렌더.
    // - 2-pass 에서 .aux 로부터 참조 해석 → 정확한 총 페이지 수 출력.
    // 문서 내에 LastPage 참조가 포함된 경우에만 한번 더 돌려 비용을 줄인다.
    const needsSecondPass = /\\pageref\{LastPage\}/.test(texSource)
      || /\\usepackage\{lastpage\}/.test(texSource);
    if (needsSecondPass) {
      await runXeLatex(texPath, workDir);
    }

    if (!(await waitForFile(pdfPath))) {
      throw new Error('XeLaTeX produced no PDF output.');
    }

    const { renderHtmlToImageBuffer } = await import('../chrome/render_pdf.js');
    const pdfData = fs.readFileSync(pdfPath);
    const base64 = pdfData.toString('base64');
    const html = `<!DOCTYPE html><html><head>
<style>*{margin:0;padding:0}body{width:${viewportWidth}px;background:white}</style>
</head><body>
<embed src="data:application/pdf;base64,${base64}" type="application/pdf" width="100%">
</body></html>`;
    const pngBuffer = await renderHtmlToImageBuffer(html, viewportWidth, deviceScaleFactor);
    return { pngBuffer, texSource };
  } finally {
    // 디버그 모드: PB_XELATEX_KEEP_WORKDIR=1 이면 workDir 을 삭제하지 않고 보존.
    //   .tex / .log 파일을 직접 열어볼 수 있도록 (프로덕션에서는 환경변수 설정 안 함).
    // [임시 DEBUG] 원인 파악을 위해 항상 workDir 을 유지. 원인 확인 후 원복 예정.
    // if (!process.env.PB_XELATEX_KEEP_WORKDIR) {
    //   fs.rmSync(workDir, { recursive: true, force: true });
    // } else {
      console.log('[pb-xelatex-doc] workDir kept for debug:', workDir);
    // }
  }
}

// --- Answer fragment -> transparent PNG ---

export async function renderAnswerWithXeLatex({
  answer,
  viewportWidth = 640,
  deviceScaleFactor = 3,
  fontFamily,
  fontBold,
  fontRegularPath = '',
  fontSizePt = 19,
  maxWidthCm = 13.5,
  textColor = 'EAF2F7',
  backgroundColor = '151C21',
  transparent = true,
  transparentOptions = {},
}) {
  await ensureInstalled();

  const workDir = path.join(os.tmpdir(), `pb-xelatex-answer-${randomUUID()}`);
  fs.mkdirSync(workDir, { recursive: true });

  const texPath = path.join(workDir, 'answer.tex');
  const pdfPath = path.join(workDir, 'answer.pdf');

  try {
    const texSource = buildAnswerTexSource(answer, {
      fontFamily,
      fontBold,
      fontRegularPath,
      fontSizePt,
      maxWidthCm,
      // V10 path: render black on white first, then reuse the established
      // alpha/composite pass that looked better in the right sheet.
      textColor: '000000',
      backgroundColor: 'FFFFFF',
    });
    fs.writeFileSync(texPath, texSource, 'utf-8');
    await runXeLatex(texPath, workDir);

    if (!(await waitForFile(pdfPath))) {
      throw new Error('XeLaTeX produced no PDF output.');
    }

    const dpi = Math.max(160, Math.round(72 * Number(deviceScaleFactor || 3)));
    let whitePng;
    try {
      whitePng = await renderPdfPageWithPdftoppm(pdfPath, workDir, { dpi });
    } catch (err) {
      console.warn('[pb-xelatex-answer] pdftoppm failed, falling back to chrome:', err?.message || err);
      const { renderHtmlToImageBuffer } = await import('../chrome/render_pdf.js');
      const pdfData = fs.readFileSync(pdfPath);
      const base64 = pdfData.toString('base64');
      const html = `<!DOCTYPE html><html><head>
<style>*{margin:0;padding:0}html,body{width:${viewportWidth}px;background:white;overflow:hidden}</style>
</head><body>
<embed src="data:application/pdf;base64,${base64}" type="application/pdf" width="100%">
</body></html>`;
      whitePng = await renderHtmlToImageBuffer(html, viewportWidth, deviceScaleFactor);
    }
    const renderedPng = await makeWhiteBackgroundTransparent(whitePng, {
      textColor,
      backgroundColor,
      transparent,
      ...transparentOptions,
    });
    return {
      ...renderedPng,
      pixelRatio: Number(deviceScaleFactor || 3),
      texSource,
    };
  } finally {
    if (!process.env.PB_XELATEX_KEEP_WORKDIR) {
      fs.rmSync(workDir, { recursive: true, force: true });
    } else {
      console.log('[pb-xelatex-answer] workDir kept for debug:', workDir);
    }
  }
}

// --- Full document -> PDF buffer ---

export async function renderPdfWithXeLatex({
  questions,
  renderConfig,
  profile,
  paper,
  modeByQuestionId,
  questionMode,
  layoutColumns,
  maxQuestionsPerPage,
  renderConfigVersion,
  fontFamilyRequested,
  fontFamilyResolved,
  fontRegularPath,
  fontBoldPath,
  subjectFontPath,
  fontSize,
  supabaseClient,
}) {
  await ensureInstalled();

  const workDir = path.join(os.tmpdir(), `pb-xelatex-doc-${randomUUID()}`);
  fs.mkdirSync(workDir, { recursive: true });

  const texPath = path.join(workDir, 'document.tex');
  const pdfPath = path.join(workDir, 'document.pdf');

  const subjectTitle = renderConfig?.subjectTitleText || '수학 영역';
  const titlePageTopText = renderConfig?.titlePageTopText || '';
  const hidePreviewHeader = renderConfig?.hidePreviewHeader === true
    || renderConfig?.hideDocumentHeader === true;
  const hideQuestionNumber = renderConfig?.hideQuestionNumber === true;
  const geometryOverride = String(renderConfig?.geometryOverride || '').trim();
  const fontFamily = fontFamilyResolved || fontFamilyRequested || 'Malgun Gothic';
  const isMockProfile = profile === 'mock' || profile === 'csat';
  const cols = (Number(layoutColumns || 1) >= 2 || isMockProfile) ? 2 : 1;

  try {
    await hydrateFiguresForXeLatex(questions || [], supabaseClient, workDir);

    const includeAcademyLogo = renderConfig?.includeAcademyLogo === true;
    const includeCoverPage = renderConfig?.includeCoverPage === true;
    const coverPageTexts = (renderConfig?.coverPageTexts && typeof renderConfig.coverPageTexts === 'object')
      ? renderConfig.coverPageTexts
      : {};
    const academyLogoDataUrl = includeAcademyLogo
      ? String(renderConfig?.academyLogoDataUrl || '').trim()
      : '';
    const academyLogoPath = academyLogoDataUrl
      ? materializeDataUrlLogo(academyLogoDataUrl, workDir)
      : '';
    const includeQuestionScore = renderConfig?.includeQuestionScore === true;
    const questionScoreByQuestionId = (renderConfig?.questionScoreByQuestionId
      && typeof renderConfig.questionScoreByQuestionId === 'object')
      ? renderConfig.questionScoreByQuestionId
      : {};
    const includeQuickAnswer = renderConfig?.includeAnswerSheet === true;
    // 제목 페이지 옵션 — MathJax HTML 경로와 동일 계약으로 renderConfig 에서 수용.
    // titlePageIndices : number[]  (1-based). 빈 배열이면 template 이 [1] 로 기본값.
    // titlePageHeaders : [{ page, title, subtitle }]  (페이지별 override).
    const titlePageIndices = Array.isArray(renderConfig?.titlePageIndices)
      ? renderConfig.titlePageIndices
      : [];
    const titlePageHeaders = Array.isArray(renderConfig?.titlePageHeaders)
      ? renderConfig.titlePageHeaders
      : [];

    const layoutMeta = {};
    const texSource = buildDocumentTexSource(questions || [], {
      paper: paper || 'B4',
      fontFamily,
      fontBold: fontBoldPath ? '' : `${fontFamily} Bold`,
      fontRegularPath: fontRegularPath || '',
      // 사용자 요청 7차: MathJax HTML 엔진의 YggSubject 폰트(기본 AppleSDGothicNeoB.ttf) 를
      //   XeLaTeX 에도 등록 → 제목페이지 타이틀/제목페이지타이틀/홀수형박스/라벨박스가
      //   HTML 쪽과 동일한 고딕 제목 폰트로 렌더되도록 한다.
      subjectFontPath: subjectFontPath || '',
      fontSize: fontSize || 11,
      columns: cols,
      subjectTitle,
      titlePageTopText,
      profile: profile || '',
      maxQuestionsPerPage: maxQuestionsPerPage || 0,
      hidePreviewHeader,
      hideQuestionNumber,
      geometryOverride,
      pageColumnQuestionCounts: renderConfig?.pageColumnQuestionCounts || null,
      includeAcademyLogo: includeAcademyLogo && !!academyLogoPath,
      academyLogoPath,
      includeCoverPage,
      coverPageTexts,
      includeQuestionScore,
      questionScoreByQuestionId,
      includeQuickAnswer,
      titlePageIndices,
      titlePageHeaders,
      columnLabelAnchors: Array.isArray(renderConfig?.columnLabelAnchors)
        ? renderConfig.columnLabelAnchors
        : [],
      // 새로고침/PDF 생성 경로에서 auto 라벨 생성을 전면 중단.
      disableAutoLabels: renderConfig?.disableAutoLabels === true,
      layoutMeta,
    });

    fs.writeFileSync(texPath, texSource, 'utf-8');
    await runXeLatex(texPath, workDir);

    // \pageref{LastPage} (모의고사 페이지박스) 는 2-pass 가 필요하다.
    // - 1-pass 에서는 .aux 에 LastPage 라벨이 기록되지 않아 "??" 로 렌더.
    // - 2-pass 에서 .aux 로부터 참조 해석 → 정확한 총 페이지 수 출력.
    // 문서 내에 LastPage 참조가 포함된 경우에만 한번 더 돌려 비용을 줄인다.
    const needsSecondPass = /\\pageref\{LastPage\}/.test(texSource)
      || /\\usepackage\{lastpage\}/.test(texSource);
    if (needsSecondPass) {
      await runXeLatex(texPath, workDir);
    }

    if (!(await waitForFile(pdfPath))) {
      throw new Error('XeLaTeX produced no PDF output.');
    }

    const bytes = fs.readFileSync(pdfPath);
    const pageCount = countPdfPages(pdfPath);

    return {
      bytes,
      pageCount,
      profile,
      paper,
      questionMode,
      modeByQuestionId: modeByQuestionId || {},
      layoutColumns,
      maxQuestionsPerPage,
      includeAnswerSheet: includeQuickAnswer,
      includeExplanation: renderConfig?.includeExplanation === true,
      includeQuestionScore,
      questionScoreByQuestionId,
      includeCoverPage,
      includeAcademyLogo: includeAcademyLogo && !!academyLogoPath,
      coverPageTexts,
      renderConfigVersion,
      fontFamily,
      fontFamilyRequested: fontFamilyRequested || '',
      fontRegularPath: fontRegularPath || '',
      fontBoldPath: fontBoldPath || '',
      fontSize: Number(fontSize || 0),
      mathRequestedCount: 0,
      mathRenderedCount: 0,
      mathFailedCount: 0,
      mathCacheHitCount: 0,
      figureHydration: {
        appliedCount: 0,
        degradedCount: 0,
        resampledCount: 0,
        regenerationQueuedCount: 0,
        effectiveDpiByQuestionId: {},
      },
      columnLabelAnchors: Array.isArray(layoutMeta.columnLabelAnchors)
        ? layoutMeta.columnLabelAnchors
        : (Array.isArray(renderConfig?.columnLabelAnchors) ? renderConfig.columnLabelAnchors : []),
      titlePageIndices: titlePageIndices.length > 0 ? titlePageIndices : [1],
      titlePageHeaders,
      pageColumnQuestionCounts: [],
      exportQuestions: questions || [],
      mathEngine: 'xelatex',
    };
  } finally {
    // 디버그 모드: PB_XELATEX_KEEP_WORKDIR=1 이면 workDir 을 삭제하지 않고 보존.
    //   .tex / .log 파일을 직접 열어볼 수 있도록 (프로덕션에서는 환경변수 설정 안 함).
    // [임시 DEBUG] 원인 파악을 위해 항상 workDir 을 유지. 원인 확인 후 원복 예정.
    // if (!process.env.PB_XELATEX_KEEP_WORKDIR) {
    //   fs.rmSync(workDir, { recursive: true, force: true });
    // } else {
      console.log('[pb-xelatex-doc] workDir kept for debug:', workDir);
    // }
  }
}
