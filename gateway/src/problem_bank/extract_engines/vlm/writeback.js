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

function isBlankFigureDescriptor(figure) {
  const text = [
    figure?.description,
    figure?.caption,
    figure?.label,
    figure?.text,
  ]
    .filter((v) => v !== undefined && v !== null)
    .map((v) => String(v))
    .join(' ');
  return /(?:빈\s*(?:칸|네모|네모칸|사각형|박스|상자)|네모\s*칸|빈칸|□|▢|\\square|box\{~~\}|empty\s*(?:box|square|blank)|blank\s*(?:box|square))/i.test(
    text,
  );
}

function looksLikeInlineBlankMarker(source, markerOffset) {
  const beforeText = source.slice(0, markerOffset);
  const afterText = source.slice(markerOffset + '[그림]'.length);
  const lineBefore = beforeText.slice(beforeText.lastIndexOf('\n') + 1).trimEnd();
  const nextNewline = afterText.indexOf('\n');
  const lineAfter = (nextNewline >= 0 ? afterText.slice(0, nextNewline) : afterText).trimStart();
  if (!lineBefore || !lineAfter) return false;
  const followsTerm = /(?:[0-9A-Za-z가-힣)}\]〉》」』]|[,，])$/.test(lineBefore);
  const startsParticle = /^(?:의|이\/가|이|가|은|는|을|를|와|과|로|에|에서|도|만)(?:\s|$)/.test(
    lineAfter,
  );
  return followsTerm && startsParticle;
}

function normalizeBlankFigureMarkers(stem, figures) {
  const source = String(stem || '');
  if (!source.includes('[그림]')) return source;
  let markerIndex = 0;
  return source.replace(/\[그림\]/g, (match, offset) => {
    const figure = Array.isArray(figures) ? figures[markerIndex] : null;
    markerIndex += 1;
    if (isBlankFigureDescriptor(figure) || looksLikeInlineBlankMarker(source, offset)) {
      return 'box{~~}';
    }
    return match;
  });
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

export function objectiveAnswerTokens(answerKey) {
  const raw = String(answerKey || '').replace(/\s+/g, ' ').trim();
  if (!raw) return [];

  const circled = raw.match(/[①②③④⑤⑥⑦⑧⑨⑩]/g);
  if (circled && circled.length > 0) {
    const leftover = raw
      .replace(/[①②③④⑤⑥⑦⑧⑨⑩]/g, '')
      .replace(/[,\s/，、ㆍ·()（）.]/g, '')
      .replace(/(?:번|와|과|및|그리고|또는|or|OR)/g, '');
    if (!leftover.trim()) return Array.from(new Set(circled));
  }

  const normalized = raw
    .replace(/[，、ㆍ·]/g, ',')
    .replace(/\s*(?:와|과|및|그리고|또는|or|OR)\s*/g, ',')
    .replace(/\s*\/\s*/g, ',')
    .trim();
  const parts = /,/.test(normalized)
    ? normalized.split(',')
    : /^\d{1,2}(?:\s+\d{1,2})+$/.test(normalized)
      ? normalized.split(/\s+/)
      : [normalized];

  const tokens = parts
    .map((token) => String(token || '').replace(/[()（）.]/g, '').replace(/번/g, '').trim())
    .filter(Boolean)
    .map((token) => {
      if (/^(10|[1-9])$/.test(token)) {
        const n = Number.parseInt(token, 10);
        return OBJ_LABELS[n - 1] || token;
      }
      return token;
    })
    .filter((token) => OBJ_LABELS.includes(token));
  return Array.from(new Set(tokens));
}

export function normalizeObjectiveAnswerKey(answerKey) {
  const raw = String(answerKey || '').replace(/\s+/g, ' ').trim();
  if (!raw) return '';
  const tokens = objectiveAnswerTokens(raw);
  return tokens.length > 0 ? tokens.join(', ') : raw;
}

export function expectedObjectiveAnswerCount(vlmQ) {
  const stem = String(vlmQ?.stem || '').replace(/\s+/g, ' ').trim();
  if (!stem) return 0;
  const digitCount = stem.match(/(?:정답|답|것|설명|보기|문장)?\s*(\d+)\s*개(?:를|을)?\s*(?:고르|찾|택|선택)/);
  if (digitCount) {
    const n = Number.parseInt(digitCount[1], 10);
    if (Number.isFinite(n) && n > 1) return n;
  }
  const koreanCounts = [
    ['두', 2],
    ['둘', 2],
    ['세', 3],
    ['셋', 3],
    ['네', 4],
    ['넷', 4],
  ];
  for (const [word, count] of koreanCounts) {
    const re = new RegExp(`${word}\\s*개(?:를|을)?\\s*(?:고르|찾|택|선택)`);
    if (re.test(stem)) return count;
  }
  if (/(?:모두|전부)\s*(?:고르|찾|택|선택)/.test(stem)) return 2;
  return 0;
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
  const rawVlmFigures = Array.isArray(vlmQ.figures) ? vlmQ.figures : [];
  const rawStemForFigureMarkers = [
    vlmQ?.stem,
    ...(Array.isArray(vlmQ?.sub_questions)
      ? vlmQ.sub_questions.map((sq) => sq?.text)
      : []),
  ].join('\n');
  const preserveExistingFigureSlots =
    rawVlmFigures.length > 0 || /\[그림\]|\[\[PB_FIG_[^\]]+\]\]/.test(rawStemForFigureMarkers)
      ? 0
      : existingFigureSlots;
  const stem = normalizeBlankFigureMarkers(
    buildStemWithSubQuestions(vlmQ, preserveExistingFigureSlots),
    rawVlmFigures,
  );

  const vlmChoices = Array.isArray(vlmQ.choices) ? vlmQ.choices : [];
  const objectiveChoices = vlmChoices.map((c, idx) => ({
    label: normalizeObjectiveLabel(c?.label, idx),
    text: String(c?.text || '').trim(),
  }));

  const objectiveAnswerKeyRaw = String(vlmQ?.answer?.objective_key || '').trim();
  const objectiveAnswerKey = objectiveAnswerKeyRaw
    ? normalizeObjectiveAnswerKey(objectiveAnswerKeyRaw)
    : '';
  const subjectiveAnswer = String(vlmQ?.answer?.subjective || '').trim();
  const answerParts = Array.isArray(vlmQ?.answer?.parts)
    ? vlmQ.answer.parts
    : [];

  const allowObjective = qType === '객관식' && objectiveChoices.length > 0;
  const allowSubjective = qType !== '객관식';
  const expectedAnswerCount = allowObjective ? expectedObjectiveAnswerCount(vlmQ) : 0;
  const actualAnswerCount = objectiveAnswerTokens(objectiveAnswerKey).length;
  const incompleteMultiAnswer =
    expectedAnswerCount > 1 && actualAnswerCount > 0 && actualAnswerCount < expectedAnswerCount;
  const stemFigureMarkerCount = (String(stem).match(/\[그림\]/g) || []).length;
  const vlmFigures = rawVlmFigures.filter((figure) => !isBlankFigureDescriptor(figure));
  const nextFlags = Array.from(
    new Set([
      ...(Array.isArray(vlmQ.flags) ? vlmQ.flags : []),
      ...(incompleteMultiAnswer ? ['objective_multi_answer_incomplete_suspected'] : []),
    ]),
  ).filter(
    (flag) =>
      flag !== 'contains_figure' || stemFigureMarkerCount > 0 || vlmFigures.length > 0,
  );
  const vlmTables = Array.isArray(vlmQ.tables) ? vlmQ.tables : [];

  // figure_refs 재구축: 매니저 UI 는 figure_assets 가 비어 있을 때 figure_refs.length 로
  // "그림 개수" 를 대체 추정한다. 지저분한 기존 [표행]/[표셀] 마커가 섞여 있으면 쓰레기 카운트가
  // figure_layout 다이얼로그에 노출되므로 "stem 의 [그림] 마커 + 기존 figure_assets 수" 기준으로
  // 깨끗하게 재구성한다.
  const desiredRefCount =
    stemFigureMarkerCount > 0 ? Math.max(stemFigureMarkerCount, figureAssets.length) : 0;
  const newFigureRefs = Array.from({ length: desiredRefCount }, () => '[그림]');

  // figure worker(problem_bank_figure_worker.js)는 inferQuestionFigureCount 에서
  // meta.figure_count 를 최우선으로 참조해 "이 문항이 HWPX BinData 몇 장을 소비할지"
  // 를 결정한다. stem 의 [그림] 마커 개수를 그대로 저장해 두면, HWPX+PDF 경로에서
  // VLM 이 시각적으로 판별한 그림 개수를 원본 HWPX 이미지에 정확히 나눠줄 수 있다.
  const figureCountForMapping = stemFigureMarkerCount;

  // VLM prompt [S10] 은 각 문항의 배점을 questions[i].score 에 실수 또는 null
  // 로 내려달라고 지시한다. 그런데 예전 구현에서는 이 값을 DB 에 연결해 두지
  // 않아, VLM 경로로 들어온 문서는 meta.score_point 가 전부 null 이 되었다.
  // (HWPX-only 경로는 problem_bank_extract_worker.js 3125 근처에서 이미
  // meta.score_point 를 채우므로 UI/렌더러 계약은 'meta.score_point') 여기서
  // VLM 의 score 를 같은 키에 주입한다.
  //
  // 안전 장치:
  //   - VLM 이 null/undefined 를 내려도 기존 row 의 meta.score_point 를 보존.
  //     (부분 재추출 시 배점이 0으로 덮이는 걸 막기 위함)
  //   - 숫자로 강제 변환 후 유한 값이 아니면 null 로 폴백.
  const rawVlmScore =
    vlmQ && Object.prototype.hasOwnProperty.call(vlmQ, 'score')
      ? vlmQ.score
      : undefined;
  let vlmTopScore = null;
  if (rawVlmScore !== undefined && rawVlmScore !== null && rawVlmScore !== '') {
    const n = Number(rawVlmScore);
    vlmTopScore = Number.isFinite(n) && n > 0 ? n : null;
  }

  // 세트형 소문항별 배점 (matching UI: meta.score_parts = [{sub:'1', value:N},...]).
  // prompt [S8] 은 sub_questions[i].score 에 실수 또는 null 을 내려주도록 지시한다.
  // - value <= 0 / NaN / 누락이면 그 소문항은 score_parts 에 넣지 않는다.
  //   (UI 의 scorePartsFromMetaRaw 와 같은 기준으로 필터링.)
  // - 하나라도 유효하면 meta.score_parts 를 구성하고, meta.score_point 는
  //   그 합으로 동기화 (매니저 UI 의 "세트형 총점 = score_parts 합" 계약과 일치).
  const subs = Array.isArray(vlmQ?.sub_questions) ? vlmQ.sub_questions : [];
  const rawScoreParts = [];
  if (isSet && subs.length > 0) {
    for (let i = 0; i < subs.length; i += 1) {
      const sq = subs[i] || {};
      const rawSub = sq.label || `(${i + 1})`;
      const subMatch = String(rawSub).match(/(\d+)/);
      const subKey = subMatch ? subMatch[1] : String(i + 1);
      const rawVal = sq.score;
      if (rawVal === undefined || rawVal === null || rawVal === '') continue;
      const n = Number(rawVal);
      if (!Number.isFinite(n) || n <= 0) continue;
      rawScoreParts.push({
        sub: subKey,
        value: n === Math.round(n) ? Math.round(n) : n,
      });
    }
  }

  const nextScorePartsRaw = rawScoreParts.length > 0 ? rawScoreParts : null;

  // score_point 결정 규칙:
  //   1) score_parts 가 있으면 그 합계가 우선 (UI 와 동기화)
  //   2) 없으면 VLM top-level score 사용
  //   3) 둘 다 없으면 기존 meta.score_point 보존 (재추출에서 0 으로 덮이는 사고 방지)
  let nextScorePoint = null;
  if (nextScorePartsRaw) {
    const sum = nextScorePartsRaw.reduce((acc, p) => acc + Number(p.value || 0), 0);
    nextScorePoint = Number.isFinite(sum) && sum > 0 ? sum : null;
  }
  if (nextScorePoint === null) nextScorePoint = vlmTopScore;
  if (nextScorePoint === null) {
    const prev = Number(existingMeta.score_point);
    if (Number.isFinite(prev) && prev > 0) nextScorePoint = prev;
  }

  // score_parts: 세트형이고 유효 값이 하나 이상이면 저장, 그 외에는 기존 값 보존
  // (재추출에서 실수로 날려먹지 않도록). 세트형이 해제(isSet=false) 되면 키 자체를
  // 지워 UI 가 "단일 배점" 모드로 돌아가게 한다.
  const existingParts = Array.isArray(existingMeta.score_parts)
    ? existingMeta.score_parts
    : null;
  const scorePartsMetaValue = !isSet
    ? undefined
    : nextScorePartsRaw || existingParts || undefined;

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
    objective_answer_key: allowObjective ? objectiveAnswerKey : '',
    allow_objective: allowObjective,
    allow_subjective: allowSubjective || isSet,
    ...(incompleteMultiAnswer
      ? {
          objective_answer_expected_count: expectedAnswerCount,
          objective_answer_key_count: actualAnswerCount,
        }
      : {}),
    score_point: nextScorePoint,
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
      flags: nextFlags,
      overwritten_at: new Date().toISOString(),
    },
  };

  // 세트형 소문항별 배점 반영: scorePartsMetaValue 가 undefined 면 키를 제거.
  // UI (problem_bank_models.dart:scorePartsFromMetaRaw) 는 배열이 아닐 때 null 로
  // 취급하므로, null 대신 키 자체를 없애는 편이 데이터가 깔끔하다.
  if (scorePartsMetaValue === undefined) {
    delete newMeta.score_parts;
  } else {
    newMeta.score_parts = scorePartsMetaValue;
  }

  return {
    stem,
    question_type: qType,
    objective_choices: allowObjective ? objectiveChoices : [],
    objective_answer_key: allowObjective ? objectiveAnswerKey : '',
    subjective_answer: allowSubjective ? subjectiveAnswer : '',
    allow_objective: allowObjective,
    allow_subjective: allowSubjective || isSet,
    objective_generated: false,
    flags: nextFlags,
    figure_refs: newFigureRefs,
    meta: newMeta,
  };
}
