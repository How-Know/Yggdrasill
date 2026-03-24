import 'dotenv/config';
import fs from 'node:fs';
import { createClient } from '@supabase/supabase-js';
import fontkit from '@pdf-lib/fontkit';
import { PDFDocument, StandardFonts, rgb } from 'pdf-lib';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const WORKER_INTERVAL_MS = Number.parseInt(
  process.env.PB_EXPORT_WORKER_INTERVAL_MS || '4000',
  10,
);
const BATCH_SIZE = Math.max(
  1,
  Number.parseInt(process.env.PB_EXPORT_WORKER_BATCH_SIZE || '2', 10),
);
const PROCESS_ONCE =
  process.argv.includes('--once') || process.env.PB_EXPORT_WORKER_ONCE === '1';
const WORKER_NAME =
  process.env.PB_EXPORT_WORKER_NAME || `pb-export-worker-${process.pid}`;
const FONT_PATH_REGULAR =
  process.env.PB_PDF_FONT_PATH || 'C:\\Windows\\Fonts\\malgun.ttf';
const FONT_PATH_BOLD =
  process.env.PB_PDF_FONT_BOLD_PATH || 'C:\\Windows\\Fonts\\malgunbd.ttf';

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  console.error(
    '[pb-export-worker] Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY',
  );
  process.exit(1);
}

const supa = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const PAPER_SIZE = {
  A4: { width: 595, height: 842 },
  B4: { width: 729, height: 1032 },
  '8절': { width: 774, height: 1118 },
};

const PROFILE_LAYOUT = {
  naesin: {
    title: '내신형 시험지',
    margin: 46,
    headerHeight: 38,
    stemSize: 11.3,
    choiceSize: 10.7,
    lineHeight: 15.4,
    questionGap: 12,
    choiceIndent: 20,
  },
  csat: {
    title: '수능형 시험지',
    margin: 44,
    headerHeight: 36,
    stemSize: 11.0,
    choiceSize: 10.4,
    lineHeight: 15.0,
    questionGap: 10,
    choiceIndent: 18,
  },
  mock: {
    title: '모의고사형 시험지',
    margin: 44,
    headerHeight: 36,
    stemSize: 11.0,
    choiceSize: 10.4,
    lineHeight: 15.0,
    questionGap: 10,
    choiceIndent: 18,
  },
};

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function compact(value, max = 220) {
  const s = String(value ?? '').replace(/\s+/g, ' ').trim();
  if (s.length <= max) return s;
  return `${s.slice(0, max)}...`;
}

function sanitizeText(value) {
  return String(value ?? '').replace(/\r/g, '').trim();
}

function normalizePaper(raw) {
  const key = String(raw || '').trim();
  return PAPER_SIZE[key] ? key : 'A4';
}

function normalizeProfile(raw) {
  const p = String(raw || '').trim().toLowerCase();
  if (p === 'csat' || p === 'mock' || p === 'naesin') return p;
  return 'naesin';
}

function toErrorCode(err) {
  const msg = String(err?.message || err || '');
  if (/not\s*found|404/i.test(msg)) return 'NOT_FOUND';
  if (/timeout/i.test(msg)) return 'TIMEOUT';
  if (/permission|401|403|forbidden/i.test(msg)) return 'PERMISSION_DENIED';
  if (/pdf|font|render/i.test(msg)) return 'RENDER_FAILED';
  return 'UNKNOWN';
}

async function lockQueuedJob(job) {
  const nowIso = new Date().toISOString();
  const { data, error } = await supa
    .from('pb_exports')
    .update({
      status: 'rendering',
      worker_name: WORKER_NAME,
      started_at: nowIso,
      finished_at: null,
      error_code: '',
      error_message: '',
      updated_at: nowIso,
    })
    .eq('id', job.id)
    .eq('status', 'queued')
    .select('*')
    .maybeSingle();
  if (error) throw new Error(`export_job_lock_failed:${error.message}`);
  return data;
}

async function markFailed(jobId, error) {
  const nowIso = new Date().toISOString();
  await supa
    .from('pb_exports')
    .update({
      status: 'failed',
      error_code: toErrorCode(error),
      error_message: compact(error?.message || error),
      finished_at: nowIso,
      updated_at: nowIso,
    })
    .eq('id', jobId);
}

async function loadFonts(pdfDoc) {
  pdfDoc.registerFontkit(fontkit);
  let regular = null;
  let bold = null;
  if (fs.existsSync(FONT_PATH_REGULAR)) {
    try {
      regular = await pdfDoc.embedFont(fs.readFileSync(FONT_PATH_REGULAR), {
        subset: true,
      });
    } catch (_) {
      regular = null;
    }
  }
  if (fs.existsSync(FONT_PATH_BOLD)) {
    try {
      bold = await pdfDoc.embedFont(fs.readFileSync(FONT_PATH_BOLD), {
        subset: true,
      });
    } catch (_) {
      bold = null;
    }
  }
  if (!regular) {
    regular = await pdfDoc.embedFont(StandardFonts.Helvetica);
  }
  if (!bold) {
    bold = await pdfDoc.embedFont(StandardFonts.HelveticaBold);
  }
  return { regular, bold };
}

function wrapTextByWidth(text, font, size, maxWidth) {
  const src = sanitizeText(text);
  if (!src) return [''];
  const paragraphs = src.split(/\n+/);
  const lines = [];
  for (const p of paragraphs) {
    if (!p.trim()) {
      lines.push('');
      continue;
    }
    let line = '';
    for (const ch of p) {
      const candidate = `${line}${ch}`;
      const w = font.widthOfTextAtSize(candidate, size);
      if (w <= maxWidth || line.length === 0) {
        line = candidate;
      } else {
        lines.push(line);
        line = ch;
      }
    }
    if (line) lines.push(line);
  }
  return lines;
}

function estimateQuestionHeight(question, fonts, layout, contentWidth) {
  let h = layout.lineHeight; // number line
  const stemLines = wrapTextByWidth(
    question.stem || '',
    fonts.regular,
    layout.stemSize,
    contentWidth,
  );
  h += stemLines.length * layout.lineHeight;
  if (question.figure_refs.length > 0) {
    h += layout.lineHeight + 40; // figure note + placeholder box
  }
  if (question.choices.length > 0) {
    for (const c of question.choices) {
      const row = `${c.label} ${c.text}`.trim();
      const choiceLines = wrapTextByWidth(
        row,
        fonts.regular,
        layout.choiceSize,
        contentWidth - layout.choiceIndent,
      );
      h += choiceLines.length * (layout.lineHeight - 1);
    }
  }
  return h + layout.questionGap;
}

function drawHeader({
  page,
  fonts,
  profile,
  layout,
  paperLabel,
  pageNumber,
}) {
  const size = page.getSize();
  const topY = size.height - layout.margin + 12;
  page.drawText(`${layout.title} · ${paperLabel}`, {
    x: layout.margin,
    y: topY,
    size: 11,
    font: fonts.bold,
    color: rgb(0.12, 0.12, 0.12),
  });
  page.drawText(`p.${pageNumber}`, {
    x: size.width - layout.margin - 30,
    y: topY,
    size: 10,
    font: fonts.regular,
    color: rgb(0.35, 0.35, 0.35),
  });
  if (profile === 'mock') {
    page.drawText('전국연합학력평가 양식 참고', {
      x: layout.margin,
      y: topY - 14,
      size: 9,
      font: fonts.regular,
      color: rgb(0.4, 0.4, 0.4),
    });
  } else if (profile === 'csat') {
    page.drawText('수능 스타일 레이아웃', {
      x: layout.margin,
      y: topY - 14,
      size: 9,
      font: fonts.regular,
      color: rgb(0.4, 0.4, 0.4),
    });
  } else {
    page.drawText('학교 내신형 레이아웃', {
      x: layout.margin,
      y: topY - 14,
      size: 9,
      font: fonts.regular,
      color: rgb(0.4, 0.4, 0.4),
    });
  }
}

function drawQuestion({
  page,
  y,
  question,
  fonts,
  layout,
  contentWidth,
}) {
  let curY = y;
  const numberLabel = `${question.question_number || '?'}번`;
  page.drawText(numberLabel, {
    x: layout.margin,
    y: curY,
    size: layout.stemSize,
    font: fonts.bold,
    color: rgb(0.1, 0.1, 0.1),
  });
  curY -= layout.lineHeight;

  const stem = sanitizeText(question.stem);
  if (stem) {
    const lines = wrapTextByWidth(
      stem,
      fonts.regular,
      layout.stemSize,
      contentWidth,
    );
    for (const line of lines) {
      page.drawText(line, {
        x: layout.margin,
        y: curY,
        size: layout.stemSize,
        font: fonts.regular,
        color: rgb(0.12, 0.12, 0.12),
      });
      curY -= layout.lineHeight;
    }
  }

  if (question.figure_refs.length > 0) {
    page.drawText('[그림/자료 포함 문항]', {
      x: layout.margin,
      y: curY,
      size: 9.5,
      font: fonts.regular,
      color: rgb(0.28, 0.35, 0.58),
    });
    curY -= layout.lineHeight - 1;
    page.drawRectangle({
      x: layout.margin,
      y: curY - 38,
      width: contentWidth,
      height: 36,
      borderColor: rgb(0.72, 0.72, 0.72),
      borderWidth: 0.8,
      color: rgb(0.97, 0.97, 0.97),
    });
    curY -= 42;
  }

  if (question.choices.length > 0) {
    for (const c of question.choices) {
      const choiceText = `${c.label} ${c.text}`.trim();
      const lines = wrapTextByWidth(
        choiceText,
        fonts.regular,
        layout.choiceSize,
        contentWidth - layout.choiceIndent,
      );
      let first = true;
      for (const line of lines) {
        page.drawText(line, {
          x: layout.margin + (first ? 0 : layout.choiceIndent),
          y: curY,
          size: layout.choiceSize,
          font: fonts.regular,
          color: rgb(0.14, 0.14, 0.14),
        });
        curY -= layout.lineHeight - 1;
        first = false;
      }
    }
  }

  return curY - layout.questionGap;
}

function drawAnswerSheet({ pdfDoc, fonts, layout, questions, paperLabel }) {
  const page = pdfDoc.addPage([
    PAPER_SIZE[paperLabel].width,
    PAPER_SIZE[paperLabel].height,
  ]);
  drawHeader({
    page,
    fonts,
    profile: 'naesin',
    layout,
    paperLabel,
    pageNumber: pdfDoc.getPageCount(),
  });
  const size = page.getSize();
  const width = size.width - layout.margin * 2;
  let y = size.height - layout.margin - layout.headerHeight;
  page.drawText('정답지', {
    x: layout.margin,
    y,
    size: 15,
    font: fonts.bold,
    color: rgb(0.1, 0.1, 0.1),
  });
  y -= 22;
  const colCount = 3;
  const colWidth = width / colCount;
  const rowHeight = 18;
  for (let i = 0; i < questions.length; i++) {
    const row = Math.floor(i / colCount);
    const col = i % colCount;
    const x = layout.margin + col * colWidth;
    const yy = y - row * rowHeight;
    if (yy < layout.margin) break;
    const label = `${questions[i].question_number || '?'}번  (   )`;
    page.drawText(label, {
      x,
      y: yy,
      size: 10,
      font: fonts.regular,
      color: rgb(0.18, 0.18, 0.18),
    });
  }
}

function drawExplanationPage({ pdfDoc, fonts, layout, questions, paperLabel }) {
  const page = pdfDoc.addPage([
    PAPER_SIZE[paperLabel].width,
    PAPER_SIZE[paperLabel].height,
  ]);
  drawHeader({
    page,
    fonts,
    profile: 'naesin',
    layout,
    paperLabel,
    pageNumber: pdfDoc.getPageCount(),
  });
  const size = page.getSize();
  const contentWidth = size.width - layout.margin * 2;
  let y = size.height - layout.margin - layout.headerHeight;
  page.drawText('해설/검수 메모', {
    x: layout.margin,
    y,
    size: 15,
    font: fonts.bold,
    color: rgb(0.1, 0.1, 0.1),
  });
  y -= 22;
  for (const q of questions) {
    const note = sanitizeText(q.reviewer_notes || '');
    const merged = note.isEmpty ? '(검수 메모 없음)' : note;
    const lines = wrapTextByWidth(
      `${q.question_number || '?'}번: $merged`,
      fonts.regular,
      10.5,
      contentWidth,
    );
    const needed = lines.length * 14 + 8;
    if (y - needed < layout.margin) break;
    for (const line of lines) {
      page.drawText(line, {
        x: layout.margin,
        y,
        size: 10.5,
        font: fonts.regular,
        color: rgb(0.15, 0.15, 0.15),
      });
      y -= 14;
    }
    y -= 8;
  }
}

async function fetchQuestionsForJob(job) {
  const academyId = String(job.academy_id || '').trim();
  const documentId = String(job.document_id || '').trim();
  const selectedIds = Array.isArray(job.selected_question_ids)
    ? job.selected_question_ids.map((e) => String(e))
    : [];

  let query = supa
    .from('pb_questions')
    .select(
      'id,question_number,question_type,stem,choices,figure_refs,equations,confidence,flags,reviewer_notes,source_page,source_order',
    )
    .eq('academy_id', academyId)
    .eq('document_id', documentId);

  if (selectedIds.isNotEmpty) {
    query = query.in('id', selectedIds);
  } else {
    query = query.eq('is_checked', true);
  }

  const { data, error } = await query
    .order('source_page', { ascending: true })
    .order('source_order', { ascending: true });
  if (error) {
    throw new Error(`question_fetch_failed:${error.message}`);
  }
  return (data || []).map((row) => ({
        id: String(row.id || ''),
        question_number: String(row.question_number || ''),
        question_type: String(row.question_type || ''),
        stem: String(row.stem || ''),
        choices: Array.isArray(row.choices)
            ? row.choices
            : [],
        figure_refs: Array.isArray(row.figure_refs)
            ? row.figure_refs
            : [],
        equations: Array.isArray(row.equations)
            ? row.equations
            : [],
        confidence: Number(row.confidence || 0),
        flags: Array.isArray(row.flags) ? row.flags : [],
        reviewer_notes: String(row.reviewer_notes || ''),
        source_page: Number(row.source_page || 0),
        source_order: Number(row.source_order || 0),
      }));
}

async function renderPdf(job, questions) {
  const profile = normalizeProfile(job.template_profile);
  const paper = normalizePaper(job.paper_size);
  const layout = PROFILE_LAYOUT[profile] || PROFILE_LAYOUT.naesin;

  const pdfDoc = await PDFDocument.create();
  const fonts = await loadFonts(pdfDoc);
  const pageSize = PAPER_SIZE[paper];
  const contentWidth = pageSize.width - layout.margin * 2;
  const pageBottom = layout.margin;

  let page = pdfDoc.addPage([pageSize.width, pageSize.height]);
  let pageNum = 1;
  drawHeader({
    page,
    fonts,
    profile,
    layout,
    paperLabel: paper,
    pageNumber: pageNum,
  });
  let y = pageSize.height - layout.margin - layout.headerHeight;

  for (const q of questions) {
    const estimated = estimateQuestionHeight(q, fonts, layout, contentWidth);
    if (y - estimated < pageBottom) {
      page = pdfDoc.addPage([pageSize.width, pageSize.height]);
      pageNum += 1;
      drawHeader({
        page,
        fonts,
        profile,
        layout,
        paperLabel: paper,
        pageNumber: pageNum,
      });
      y = pageSize.height - layout.margin - layout.headerHeight;
    }
    y = drawQuestion({
      page,
      y,
      question: q,
      fonts,
      layout,
      contentWidth,
    });
  }

  if (job.include_answer_sheet === true) {
    drawAnswerSheet({
      pdfDoc,
      fonts,
      layout,
      questions,
      paperLabel: paper,
    });
  }
  if (job.include_explanation === true) {
    drawExplanationPage({
      pdfDoc,
      fonts,
      layout,
      questions,
      paperLabel: paper,
    });
  }

  const bytes = await pdfDoc.save();
  return {
    bytes,
    pageCount: pdfDoc.getPageCount(),
    profile,
    paper,
  };
}

async function processOneJob(job) {
  const questions = await fetchQuestionsForJob(job);
  if (!questions.length) {
    throw new Error('selected_questions_empty');
  }
  const rendered = await renderPdf(job, questions);
  const objectPath = `${job.academy_id}/${job.id}.pdf`;

  const { error: uploadErr } = await supa.storage
    .from('problem-exports')
    .upload(objectPath, rendered.bytes, {
      contentType: 'application/pdf',
      upsert: true,
    });
  if (uploadErr) {
    throw new Error(`export_upload_failed:${uploadErr.message}`);
  }

  const { data: signed } = await supa.storage
    .from('problem-exports')
    .createSignedUrl(objectPath, 60 * 60 * 24 * 7);
  const outputUrl = String(signed?.signedUrl || '');
  const nowIso = new Date().toISOString();

  const { error: updErr } = await supa
    .from('pb_exports')
    .update({
      status: 'completed',
      output_storage_bucket: 'problem-exports',
      output_storage_path: objectPath,
      output_url: outputUrl,
      page_count: rendered.pageCount,
      error_code: '',
      error_message: '',
      result_summary: {
        profile: rendered.profile,
        paper: rendered.paper,
        questionCount: questions.length,
      },
      finished_at: nowIso,
      updated_at: nowIso,
    })
    .eq('id', job.id);
  if (updErr) {
    throw new Error(`export_job_update_failed:${updErr.message}`);
  }

  return {
    pageCount: rendered.pageCount,
    questionCount: questions.length,
    outputPath: objectPath,
  };
}

async function processBatch() {
  const { data: queue, error } = await supa
    .from('pb_exports')
    .select('*')
    .eq('status', 'queued')
    .order('created_at', { ascending: true })
    .limit(BATCH_SIZE);
  if (error) {
    throw new Error(`export_queue_fetch_failed:${error.message}`);
  }
  if (!queue || queue.length === 0) {
    return { processed: 0, success: 0, failed: 0 };
  }

  const summary = { processed: 0, success: 0, failed: 0 };
  for (const row of queue) {
    summary.processed += 1;
    let locked = null;
    try {
      locked = await lockQueuedJob(row);
      if (!locked) continue;
      const result = await processOneJob(locked);
      summary.success += 1;
      console.log(
        '[pb-export-worker] done',
        JSON.stringify({
          jobId: locked.id,
          questions: result.questionCount,
          pages: result.pageCount,
          outputPath: result.outputPath,
        }),
      );
    } catch (err) {
      summary.failed += 1;
      console.error(
        '[pb-export-worker] fail',
        JSON.stringify({
          jobId: locked?.id || row.id,
          errorCode: toErrorCode(err),
          message: compact(err?.message || err),
        }),
      );
      await markFailed(locked?.id || row.id, err);
    }
  }
  return summary;
}

async function main() {
  console.log(
    '[pb-export-worker] start',
    JSON.stringify({
      worker: WORKER_NAME,
      intervalMs: WORKER_INTERVAL_MS,
      batchSize: BATCH_SIZE,
      once: PROCESS_ONCE,
    }),
  );
  while (true) {
    try {
      const summary = await processBatch();
      if (summary.processed > 0) {
        console.log('[pb-export-worker] batch', JSON.stringify(summary));
      }
      if (PROCESS_ONCE) break;
      await sleep(WORKER_INTERVAL_MS);
    } catch (err) {
      console.error(
        '[pb-export-worker] batch_error',
        compact(err?.message || err),
      );
      if (PROCESS_ONCE) break;
      await sleep(WORKER_INTERVAL_MS);
    }
  }
  console.log('[pb-export-worker] exit');
}

main().catch((err) => {
  console.error('[pb-export-worker] fatal', compact(err?.message || err));
  process.exit(1);
});
