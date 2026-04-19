// VLM(PDF) 추출 엔진의 런타임 진입점.
//
// 운영 워커(problem_bank_extract_worker.js) 의 processOneJob 이 "문서에 PDF 가 붙어
// 있는 경우" 호출한다. 이 모듈은 다음 책임만 진다:
//
//   1. Supabase Storage 에서 PDF 버퍼 다운로드
//   2. Gemini(VLM) 호출 → JSON 파싱
//   3. 결과 questions[] 를 "기존 HWPX 파이프라인이 기대하는 buildQuestionWritePayload
//      호환 shape" 으로 변환 (stem 포맷·객관식/주관식 구분·allow_* 플래그 포함)
//
// DB write, 잡 상태 전이, figure-job 큐잉 같은 후처리는 호출 측(processOneJob) 이
// 이미 가진 공통 코드로 처리하도록 맡긴다. 즉 이 runner 는 "파서 교체 판" 역할만 함.

import { callGeminiWithPdf } from './client.js';
import { normalizeVlmQuestion, buildRowUpdate } from './writeback.js';

function compact(v) {
  return String(v || '').trim();
}

// 기존 pb_questions 행 리스트를 "question_number → row" 맵으로 구성.
// 같은 번호가 여러 개 있으면 첫 번째만 사용 (메타 보존 목적).
function indexExistingByQuestionNumber(rows) {
  const map = new Map();
  for (const r of rows || []) {
    const n = Number.parseInt(String(r?.question_number || '').trim(), 10);
    if (!Number.isFinite(n) || n <= 0) continue;
    const key = String(n);
    if (!map.has(key)) map.set(key, r);
  }
  return map;
}

// VLM question 하나를 "buildQuestionWritePayload" 가 먹을 수 있는 형태로 변환한다.
// existingRow 가 있으면 그쪽의 figure_assets / figure_layout / question_uid 등을 보존.
function toPayloadQuestion({
  vlmQ,
  existingRow,
  sourceOrder,
  modelName,
  reviewConfidenceThreshold,
}) {
  const normalized = normalizeVlmQuestion(vlmQ);
  const update = buildRowUpdate(existingRow || null, normalized, {
    modelName,
    keepTypeFromDb: false,
  });

  // VLM 은 "uncertain_fields" 길이가 0 이면 high, 아니면 medium 이라고 자체 보고한다.
  // 워커의 lowConfidenceCount 집계는 숫자 confidence 기준이므로 여기서도 숫자로 환산.
  //   high    → 0.9  (임계치 위)
  //   medium  → reviewConfidenceThreshold - 0.05  (임계치 바로 아래 → review_required 유도)
  //   low     → 0.4
  const uncertainCount = Array.isArray(normalized?.uncertain_fields)
    ? normalized.uncertain_fields.length
    : 0;
  const declaredConf = compact(normalized?.vlm_confidence || '');
  const confidence =
    declaredConf === 'low'
      ? 0.4
      : uncertainCount > 0 || declaredConf === 'medium'
        ? Math.max(0, Number(reviewConfidenceThreshold || 0.6) - 0.05)
        : 0.9;

  const flags = Array.isArray(normalized?.flags) ? normalized.flags : [];
  const sourcePage = Number.isFinite(Number(normalized?.source_page))
    ? Number(normalized.source_page)
    : null;

  return {
    question_number: String(normalized?.question_number ?? '').trim(),
    source_page: sourcePage,
    source_order: sourceOrder,
    question_type: update.question_type,
    stem: update.stem,
    choices: Array.isArray(normalized?.choices) ? normalized.choices : [],
    figure_refs: update.figure_refs,
    equations: [], // VLM 경로는 수식 token/raw 분리 안 함 (stem 안에 LaTeX 로 그대로 표기)
    source_anchors: [],
    confidence,
    flags,
    is_checked: false,
    reviewed_by: null,
    reviewed_at: null,
    reviewer_notes: '',
    allow_objective: update.allow_objective,
    allow_subjective: update.allow_subjective,
    objective_choices: update.objective_choices,
    objective_answer_key: update.objective_answer_key,
    subjective_answer: update.subjective_answer,
    objective_generated: update.objective_generated,
    meta: update.meta,
  };
}

// processOneJob 이 호출하는 메인 엔트리.
// 반환 shape 은 HWPX 경로의 buildQuestionRows 결과 + parsed.hints 를 흉내 낸다.
export async function runVlmExtraction({
  job,
  doc,
  supa,
  apiKey,
  model,
  reviewConfidenceThreshold = 0.6,
  timeoutMs = 180000,
  log = null,
}) {
  const pdfBucket = compact(
    doc.source_pdf_storage_bucket || doc.source_storage_bucket || 'problem-documents',
  );
  const pdfPath = compact(doc.source_pdf_storage_path);
  if (!pdfPath) {
    throw new Error('vlm_pdf_path_empty');
  }

  const { data: fileData, error: dlErr } = await supa.storage
    .from(pdfBucket)
    .download(pdfPath);
  if (dlErr || !fileData) {
    throw new Error(`vlm_pdf_download_failed:${dlErr?.message || 'no_data'}`);
  }
  const pdfArrayBuf = await fileData.arrayBuffer();
  const pdfBuffer = Buffer.from(pdfArrayBuf);
  if (!pdfBuffer.length) {
    throw new Error('vlm_pdf_buffer_empty');
  }

  if (typeof log === 'function') {
    log('vlm_call_start', {
      jobId: job.id,
      documentId: job.document_id,
      pdfBytes: pdfBuffer.length,
      model,
    });
  }

  const geminiResult = await callGeminiWithPdf({
    pdfBuffer,
    model,
    apiKey,
    timeoutMs,
  });

  const parsedJson = geminiResult?.parsedJson;
  const vlmQuestions = Array.isArray(parsedJson?.questions)
    ? parsedJson.questions
    : [];
  if (vlmQuestions.length === 0) {
    throw new Error('vlm_no_questions_in_response');
  }

  // 기존 pb_questions 를 한 번 조회해 figure_assets / figure_layout / question_uid 보존.
  // 첫 추출 케이스에서는 rows=[] 라 단순히 새 문항을 insert 하게 된다.
  const { data: existingRows, error: existingErr } = await supa
    .from('pb_questions')
    .select('id,question_number,question_uid,meta,question_type')
    .eq('academy_id', job.academy_id)
    .eq('document_id', job.document_id);
  if (existingErr) {
    throw new Error(`vlm_existing_fetch_failed:${existingErr.message}`);
  }
  const existingByNum = indexExistingByQuestionNumber(existingRows || []);

  // 문항 번호 기준 오름차순으로 source_order 부여. 번호가 비어있는 케이스는 맨 뒤로 밀어낸다.
  const ordered = vlmQuestions.slice().sort((a, b) => {
    const na = Number.parseInt(String(a?.question_number || '').trim(), 10);
    const nb = Number.parseInt(String(b?.question_number || '').trim(), 10);
    if (!Number.isFinite(na) && !Number.isFinite(nb)) return 0;
    if (!Number.isFinite(na)) return 1;
    if (!Number.isFinite(nb)) return -1;
    return na - nb;
  });

  let lowConfidenceCount = 0;
  const payloadQuestions = ordered.map((vlmQ, idx) => {
    const qKey = String(
      Number.parseInt(String(vlmQ?.question_number || '').trim(), 10) || '',
    );
    const existingRow = qKey ? existingByNum.get(qKey) || null : null;
    const payload = toPayloadQuestion({
      vlmQ,
      existingRow,
      sourceOrder: idx + 1,
      modelName: model,
      reviewConfidenceThreshold,
    });
    if (Number(payload.confidence || 0) < Number(reviewConfidenceThreshold || 0.6)) {
      lowConfidenceCount += 1;
    }
    return payload;
  });

  const stats = {
    circledChoices: payloadQuestions.filter(
      (q) => q.question_type === '객관식' && (q.objective_choices || []).length > 0,
    ).length,
    viewBlocks: payloadQuestions.filter((q) =>
      /\[보기시작\]/.test(String(q.stem || '')),
    ).length,
    figureLines: payloadQuestions.reduce(
      (acc, q) =>
        acc + (String(q.stem || '').match(/\[그림\]/g) || []).length,
      0,
    ),
    mockMarkers: 0,
    csatMarkers: 0,
    equationRefs: 0,
    questionCount: payloadQuestions.length,
    sourceLineCount: 0,
    segmentedLineCount: 0,
    answerHintCount: 0,
    lowConfidenceCount,
    examProfile: '',
  };

  return {
    built: { questions: payloadQuestions, stats },
    parsed: { hints: { scoreHeaderCount: 0, previewLineCount: 0 } },
    meta: {
      engine: 'vlm',
      model,
      documentMeta: parsedJson?.document_meta || null,
      usage: geminiResult?.usageMetadata || null,
      elapsedMs: geminiResult?.elapsedMs || 0,
      finishReason: geminiResult?.finishReason || '',
    },
  };
}
