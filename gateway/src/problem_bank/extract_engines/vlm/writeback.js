// VLM 결과를 pb_questions row payload 로 변환하는 로직.
//
// scripts/vlm_overwrite_document.mjs 의 normalizeMathDelimiters / normalizeVlmQuestion /
// normalizeObjectiveLabel / buildStemWithSubQuestions / deriveQuestionType / buildRowUpdate
// 를 운영 워커가 재사용할 수 있도록 ESM 모듈로 분리했다.
//
// 이 모듈은 "VLM 의 raw question" → "pb_questions 에 insert/upsert 가능한 row update payload"
// 로 변환하는 단계까지만 책임진다. 실제 DB 쓰기는 호출 측(runner.js) 이 담당한다.

// VLM 은 수식을 MathJax 스타일 \(...\) / \[...\] 로 내보낸다. 하지만 현재 렌더러
// (template.js:smartTexLine) 는 "한국어가 아닌 연속 구간" 을 자동으로 $...$ 로 감싸주므로
// delimiter 가 남아 있으면 이중 감싸기로 렌더 실패한다. 따라서 "구분자만 제거,
// 내부 LaTeX 명령은 보존" 이 원칙이다.
export function normalizeMathDelimiters(input) {
  if (typeof input !== 'string' || !input) return input;
  let s = input;
  s = s.replace(/\\\\\(/g, '\\(').replace(/\\\\\)/g, '\\)');
  s = s.replace(/\\\\\[/g, '\\[').replace(/\\\\\]/g, '\\]');
  s = s.replace(/\\\[([\s\S]*?)\\\]/g, (_, inner) => inner);
  s = s.replace(/\\\(([\s\S]*?)\\\)/g, (_, inner) => inner);
  s = s.replace(/\$\$([\s\S]*?)\$\$/g, (_, inner) => inner);
  s = s.replace(/\$([^$\n]+?)\$/g, (_, inner) => inner);
  return s;
}

export function normalizeVlmQuestion(vlmQ) {
  if (!vlmQ || typeof vlmQ !== 'object') return vlmQ;
  const out = { ...vlmQ };
  out.stem = normalizeMathDelimiters(out.stem);
  if (Array.isArray(out.choices)) {
    out.choices = out.choices.map((c) => ({
      ...c,
      text: normalizeMathDelimiters(c?.text),
    }));
  }
  if (Array.isArray(out.sub_questions)) {
    out.sub_questions = out.sub_questions.map((sq) => ({
      ...sq,
      text: normalizeMathDelimiters(sq?.text),
    }));
  }
  if (out.answer && typeof out.answer === 'object') {
    const a = { ...out.answer };
    if (typeof a.subjective === 'string')
      a.subjective = normalizeMathDelimiters(a.subjective);
    if (typeof a.objective_key === 'string')
      a.objective_key = normalizeMathDelimiters(a.objective_key);
    if (Array.isArray(a.parts)) {
      a.parts = a.parts.map((p) => ({
        ...p,
        value: normalizeMathDelimiters(p?.value),
      }));
    }
    out.answer = a;
  }
  return out;
}

const OBJ_LABELS = ['①', '②', '③', '④', '⑤', '⑥', '⑦', '⑧', '⑨', '⑩'];
export function normalizeObjectiveLabel(raw, index) {
  const s = String(raw || '').trim();
  if (!s) return OBJ_LABELS[index] || '';
  if (OBJ_LABELS.includes(s)) return s;
  const m = s.match(/[1-9]\d?/);
  if (m) {
    const n = Number.parseInt(m[0], 10);
    if (n >= 1 && n <= OBJ_LABELS.length) return OBJ_LABELS[n - 1];
  }
  return s;
}

// VLM 의 은닉 sub_questions 를 stem 본문에 마커와 함께 복원.
export function buildStemWithSubQuestions(vlmQ, existingFigureSlots) {
  const baseStem = String(vlmQ.stem || '').trim();
  const subs = Array.isArray(vlmQ.sub_questions) ? vlmQ.sub_questions : [];
  const pieces = [];
  if (baseStem) pieces.push(baseStem);

  for (let i = 0; i < subs.length; i += 1) {
    const label = String(subs[i]?.label || `(${i + 1})`).trim();
    const text = String(subs[i]?.text || '').trim();
    if (!text) continue;
    // [소문항N] 은 반드시 "단독 라인" 이어야 렌더러 SUBQ_MARKER_LINE_RE 가 마커로 소비한다.
    pieces.push('[문단]');
    pieces.push(`[소문항${i + 1}]`);
    pieces.push(`${label} ${text}`);
  }

  // 기존 문항이 그림을 가지고 있었다면 stem 끝에 [그림] 마커를 그 개수만큼 보존.
  if (existingFigureSlots > 0) {
    pieces.push('[문단]');
    pieces.push(
      Array.from({ length: existingFigureSlots }, () => '[그림]').join(' '),
    );
  }
  return pieces.join('\n');
}

export function deriveQuestionType(vlmQ) {
  const t = String(vlmQ.question_type || '').trim();
  if (vlmQ.is_set_question) return '주관식';
  if (t === '객관식' || t === '주관식' || t === '서술형') return t;
  const hasChoices = Array.isArray(vlmQ.choices) && vlmQ.choices.length > 0;
  return hasChoices ? '객관식' : '주관식';
}

// `existingRow` 가 null 이면 "첫 추출" 케이스: 기존 figure_assets 보존 로직이 비활성화되고
// source_order / question_number 만 새로 채워진다.
export function buildRowUpdate(existingRow, vlmQ, opts = {}) {
  const existingMeta =
    existingRow?.meta && typeof existingRow.meta === 'object'
      ? existingRow.meta
      : {};
  const figureAssets = Array.isArray(existingMeta.figure_assets)
    ? existingMeta.figure_assets
    : [];
  const figureLayout = existingMeta.figure_layout || null;
  const existingFigureSlots =
    figureLayout && Array.isArray(figureLayout.items)
      ? figureLayout.items.length
      : figureAssets.length;

  const vlmType = deriveQuestionType(vlmQ);
  const existingType = String(existingRow?.question_type || '').trim();
  const isSet = vlmQ.is_set_question === true;
  const qType = isSet
    ? '주관식'
    : opts.keepTypeFromDb && existingType
      ? existingType
      : vlmType;
  const stem = buildStemWithSubQuestions(vlmQ, existingFigureSlots);

  const vlmChoices = Array.isArray(vlmQ.choices) ? vlmQ.choices : [];
  const objectiveChoices = vlmChoices.map((c, idx) => ({
    label: normalizeObjectiveLabel(c?.label, idx),
    text: String(c?.text || '').trim(),
  }));

  const objectiveAnswerKeyRaw = String(vlmQ?.answer?.objective_key || '').trim();
  const objectiveAnswerKey = objectiveAnswerKeyRaw
    ? normalizeObjectiveLabel(objectiveAnswerKeyRaw, -1)
    : '';
  const subjectiveAnswer = String(vlmQ?.answer?.subjective || '').trim();
  const answerParts = Array.isArray(vlmQ?.answer?.parts)
    ? vlmQ.answer.parts
    : [];

  const allowObjective = qType === '객관식' && objectiveChoices.length > 0;
  const allowSubjective = qType !== '객관식';

  const vlmFigures = Array.isArray(vlmQ.figures) ? vlmQ.figures : [];
  const vlmTables = Array.isArray(vlmQ.tables) ? vlmQ.tables : [];

  // figure_refs 재구축: 매니저 UI 는 figure_assets 가 비어 있을 때 figure_refs.length 로
  // "그림 개수" 를 대체 추정한다. 지저분한 기존 [표행]/[표셀] 마커가 섞여 있으면 쓰레기 카운트가
  // figure_layout 다이얼로그에 노출되므로 "stem 의 [그림] 마커 + 기존 figure_assets 수" 기준으로
  // 깨끗하게 재구성한다.
  const stemFigureMarkerCount = (String(stem).match(/\[그림\]/g) || []).length;
  const desiredRefCount = Math.max(stemFigureMarkerCount, figureAssets.length);
  const newFigureRefs = Array.from({ length: desiredRefCount }, () => '[그림]');

  // figure worker(problem_bank_figure_worker.js)는 inferQuestionFigureCount 에서
  // meta.figure_count 를 최우선으로 참조해 "이 문항이 HWPX BinData 몇 장을 소비할지"
  // 를 결정한다. stem 의 [그림] 마커 개수를 그대로 저장해 두면, HWPX+PDF 경로에서
  // VLM 이 시각적으로 판별한 그림 개수를 원본 HWPX 이미지에 정확히 나눠줄 수 있다.
  const figureCountForMapping = stemFigureMarkerCount;

  const newMeta = {
    ...existingMeta,
    is_set_question: isSet || existingMeta.is_set_question === true,
    answer_parts: isSet
      ? answerParts.map((p, i) => ({
          sub: String(p.sub ?? i + 1),
          value: String(p.value ?? ''),
        }))
      : [],
    answer_key: isSet ? subjectiveAnswer : existingMeta.answer_key || '',
    figure_count: figureCountForMapping,
    vlm: {
      model: opts.modelName || 'gemini-3.1-pro-preview',
      source_page: vlmQ.source_page ?? null,
      confidence: vlmQ?.uncertain_fields?.length ? 'medium' : 'high',
      uncertain_fields: Array.isArray(vlmQ.uncertain_fields)
        ? vlmQ.uncertain_fields
        : [],
      figures_described: vlmFigures,
      tables_described: vlmTables,
      flags: Array.isArray(vlmQ.flags) ? vlmQ.flags : [],
      overwritten_at: new Date().toISOString(),
    },
  };

  return {
    stem,
    question_type: qType,
    objective_choices: allowObjective ? objectiveChoices : [],
    objective_answer_key: allowObjective ? objectiveAnswerKey : '',
    subjective_answer: allowSubjective ? subjectiveAnswer : '',
    allow_objective: allowObjective,
    allow_subjective: allowSubjective || isSet,
    objective_generated: false,
    flags: Array.isArray(vlmQ.flags) ? vlmQ.flags : [],
    figure_refs: newFigureRefs,
    meta: newMeta,
  };
}
