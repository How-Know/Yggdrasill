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
import { checkXeLatexInstallation, getXeLatexBinary } from './check_installation.js';
import { buildTexSource, buildDocumentTexSource } from './template.js';

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
    const meta = q.meta && typeof q.meta === 'object' ? q.meta : {};
    const assets = Array.isArray(meta.figure_assets) ? meta.figure_assets : [];
    if (assets.length === 0) continue;

    const seen = new Set();
    const deduped = [];
    for (const a of assets) {
      const key = `${a.figure_index || 0}`;
      if (seen.has(key)) continue;
      seen.add(key);
      deduped.push(a);
    }
    deduped.sort((a, b) => (a.figure_index || 0) - (b.figure_index || 0));

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
        const filename = `fig-${qid}-${asset.figure_index || 0}.${ext}`;
        const filePath = path.join(workDir, filename);
        fs.writeFileSync(filePath, Buffer.from(await data.arrayBuffer()));
        q.figure_local_paths.push(filePath);
        appliedCount += 1;
      } catch (_) {
        /* skip failed downloads */
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
    fs.rmSync(workDir, { recursive: true, force: true });
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

    const texSource = buildDocumentTexSource(questions || [], {
      paper: paper || 'B4',
      fontFamily,
      fontBold: fontBoldPath ? '' : `${fontFamily} Bold`,
      fontRegularPath: fontRegularPath || '',
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
    });

    fs.writeFileSync(texPath, texSource, 'utf-8');
    await runXeLatex(texPath, workDir);

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
      includeAnswerSheet: renderConfig?.includeAnswerSheet === true,
      includeExplanation: renderConfig?.includeExplanation === true,
      includeQuestionScore: false,
      questionScoreByQuestionId: {},
      includeCoverPage: false,
      includeAcademyLogo: false,
      coverPageTexts: {},
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
      columnLabelAnchors: [],
      titlePageIndices: [1],
      titlePageHeaders: [],
      pageColumnQuestionCounts: [],
      exportQuestions: questions || [],
      mathEngine: 'xelatex',
    };
  } finally {
    fs.rmSync(workDir, { recursive: true, force: true });
  }
}
