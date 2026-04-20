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
    const meta = q.meta && typeof q.meta === 'object' ? q.meta : {};
    const assets = Array.isArray(meta.figure_assets) ? meta.figure_assets : [];
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
        const filename = `fig-${qid}-${asset.figure_index || 0}.${ext}`;
        const filePath = path.join(workDir, filename);
        fs.writeFileSync(filePath, Buffer.from(await data.arrayBuffer()));
        ordinal += 1;
        const figIdx = Number.parseInt(String(asset?.figure_index ?? ''), 10);
        const assetKey = Number.isFinite(figIdx) && figIdx > 0
          ? `idx:${figIdx}`
          : (asset?.path ? `path:${asset.path}` : `ord:${ordinal}`);
        q.figure_local_paths.push(filePath);
        q.figure_local_infos.push({
          path: filePath,
          assetKey,
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
      includeAcademyLogo: includeAcademyLogo && !!academyLogoPath,
      academyLogoPath,
      includeCoverPage,
      coverPageTexts,
      includeQuestionScore,
      questionScoreByQuestionId,
      includeQuickAnswer,
      titlePageIndices,
      titlePageHeaders,
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
      columnLabelAnchors: [],
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
