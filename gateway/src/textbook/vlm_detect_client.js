// 교재 페이지 이미지를 Gemini Vision 에 보내 "문항번호 bbox" 를 받아오는 클라이언트.
//
// 기존 `extract_engines/vlm/client.js` 는 PDF inline_data 전용이고 프롬프트도
// 문제은행 전용이라 재사용하지 않고 별도 모듈로 분리했다.
//
// Node >= 18 의 global fetch / AbortController 만 사용한다. 외부 의존성 없음.

import {
  buildDetectProblemsPrompt,
  buildRpmSetHeaderPrompt,
  buildWonriPageClassPrompt,
  VLM_DETECT_LABELS,
  WONRI_ITEM_CATEGORIES,
} from './vlm_detect_prompt.js';
import { parseTextbookVlmJson } from './vlm_json_parse.js';

const TRANSIENT_STATUSES = new Set([429, 500, 502, 503, 504]);
const DEFAULT_MAX_RETRIES = 3;
const ALLOWED_LABELS = new Set(VLM_DETECT_LABELS);

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isDailyQuotaExceededBody(input) {
  const text = String(input || '').toLowerCase();
  return (
    text.includes('resource_exhausted') &&
    (text.includes('generate_requests_per_model_per_day') ||
      text.includes('please retry in'))
  );
}

export async function detectProblemsOnPage({
  imageBase64,
  mimeType = 'image/png',
  rawPage,
  displayPage,
  pageOffset,
  model,
  apiKey,
  timeoutMs = 90000,
  includeContentGroups = true,
  expectedStartNumber = '',
  series = 'ssen',
  sectionHint = '',
  maxRetries = DEFAULT_MAX_RETRIES,
  promptOverride = '',
}) {
  const key = String(apiKey || '').trim();
  if (!key) throw new Error('vlm_detect_api_key_missing');
  const img = String(imageBase64 || '').trim();
  if (!img) throw new Error('vlm_detect_image_empty');

  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/` +
    `${encodeURIComponent(model)}:generateContent?key=` +
    `${encodeURIComponent(key)}`;

  const body = {
    contents: [
      {
        role: 'user',
        parts: [
          {
            inline_data: {
              mime_type: mimeType,
              data: img,
            },
          },
          {
            text:
              String(promptOverride || '').trim() ||
              buildDetectProblemsPrompt({
                rawPage,
                displayPage,
                pageOffset,
                includeContentGroups,
                expectedStartNumber,
                series,
                sectionHint,
              }),
          },
        ],
      },
    ],
    generationConfig: {
      temperature: 0.1,
      responseMimeType: 'application/json',
      maxOutputTokens: 8192,
      thinkingConfig: { thinkingLevel: 'low' },
    },
  };

  // Gemini 는 장시간 과부하 상태에서 간헐적으로 502/503/504 를 돌려주는 경우가 있다.
  // 사용자 경험을 위해 짧은 지수 백오프로 몇 번 재시도한다.
  let lastErr = null;
  let lastStatus = 0;
  let lastBody = '';
  const attempts = Math.max(1, Number(maxRetries) || 1);
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    const t0 = Date.now();
    let res;
    try {
      res = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
        signal: controller.signal,
      });
    } catch (err) {
      clearTimeout(timer);
      lastErr = err;
      if (attempt + 1 < attempts) {
        await sleep(800 * Math.pow(2, attempt));
        continue;
      }
      throw new Error(
        `vlm_detect_fetch_error: ${compactErrMsg(err)} (attempts=${attempt + 1})`,
      );
    } finally {
      clearTimeout(timer);
    }
    const elapsedMs = Date.now() - t0;
    const textBody = await res.text();
    if (!res.ok) {
      lastStatus = res.status;
      lastBody = textBody;
      if (
        TRANSIENT_STATUSES.has(res.status) &&
        !isDailyQuotaExceededBody(textBody) &&
        attempt + 1 < attempts
      ) {
        await sleep(800 * Math.pow(2, attempt));
        continue;
      }
      throw new Error(
        `vlm_detect_http_${res.status}: ${String(textBody).slice(0, 500)} (attempts=${attempt + 1})`,
      );
    }
    let payload;
    try {
      payload = JSON.parse(textBody);
    } catch (_) {
      throw new Error(
        `vlm_detect_non_json_response: ${String(textBody).slice(0, 500)}`,
      );
    }
    const candidate = (payload?.candidates || [])[0];
    const modelText = (candidate?.content?.parts || [])
      .map((p) => p?.text || '')
      .join('\n')
      .trim();
    let parsedJson = parseTextbookVlmJson(modelText);
    if (!parsedJson) {
      // 개념 페이지 폴백: 모델이 정상 종료했는데도 개념 설명 페이지에서 JSON을
      // 깨뜨리는 경우가 잦다(닫는 중괄호 누락/중복). 응답에 빈 items 배열이
      // 분명히 있으면(문항 없음) 파싱 실패로 502·재시도를 내지 말고 빈 개념
      // 페이지로 처리한다. (items 가 실제로 있으면 이 폴백은 발동하지 않는다.)
      if (/"items"\s*:\s*\[\s*\]/.test(modelText)) {
        const pageKind = /"page_kind"\s*:\s*"([^"]*)"/.exec(modelText);
        parsedJson = {
          section: 'unknown',
          page_kind: pageKind ? pageKind[1] : 'concept_page',
          page_layout: 'unknown',
          items: [],
          notes: 'recovered_empty_page_from_malformed_json',
        };
      }
    }
    if (!parsedJson) {
      throw new Error(
        `vlm_detect_parse_failed: finish=${candidate?.finishReason || '-'} text_head="${modelText.slice(
          0,
          180,
        )}"`,
      );
    }
    return {
      rawPayload: payload,
      parsedJson,
      elapsedMs,
      usageMetadata: payload?.usageMetadata || null,
      finishReason: candidate?.finishReason || '',
      attempts: attempt + 1,
    };
  }
  // Should never reach here but keep the compiler happy.
  throw new Error(
    `vlm_detect_exhausted: status=${lastStatus} lastErr=${compactErrMsg(lastErr)} body=${String(
      lastBody,
    ).slice(0, 300)}`,
  );
}

export function detectRpmSetHeadersOnPage(options) {
  return detectProblemsOnPage({
    ...options,
    series: 'rpm',
    sectionHint: 'basic_drill',
    includeContentGroups: false,
    promptOverride: buildRpmSetHeaderPrompt({
      rawPage: options?.rawPage,
      displayPage: options?.displayPage,
    }),
  });
}

export function classifyWonriPage(options) {
  return detectProblemsOnPage({
    ...options,
    series: 'wonri',
    includeContentGroups: false,
    promptOverride: buildWonriPageClassPrompt({
      rawPage: options?.rawPage,
      displayPage: options?.displayPage,
    }),
  });
}

function compactErrMsg(err) {
  if (!err) return '';
  const name = err?.name ? `${err.name}: ` : '';
  return `${name}${String(err?.message || err).slice(0, 300)}`;
}

export function normalizeDetectResult(parsedJson, opts = {}) {
  const out = {
    section: 'unknown',
    page_kind: 'unknown',
    concept_drill_header_visible: false,
    page_layout: 'unknown',
    items: [],
    notes: '',
  };
  if (!parsedJson || typeof parsedJson !== 'object') return out;

  const knownSections = [
    'basic_drill',
    'type_practice',
    'mastery',
    // 개념원리 전용 섹션 (sub_key A~E 슬롯 대응).
    'concept_drill',
    'type_example',
    'check',
    'exercise',
    'special_lecture',
  ];
  const section = String(parsedJson.section || '').trim();
  out.section = [...knownSections, 'unknown'].includes(section)
    ? section
    : 'unknown';
  const sectionHint = String(opts?.sectionHint || '').trim();
  if (knownSections.includes(sectionHint)) {
    out.section = sectionHint;
  }

  const layout = String(parsedJson.page_layout || '').trim();
  out.page_layout = ['two_column', 'one_column', 'unknown'].includes(layout)
    ? layout
    : 'unknown';
  out.notes = String(parsedJson.notes || '').trim();

  const pageKind = String(parsedJson.page_kind || '').trim();
  out.page_kind = ['problem_page', 'concept_page', 'mixed', 'unknown'].includes(
    pageKind,
  )
    ? pageKind
    : 'unknown';
  // 개념원리 일반 소단원의 개념→문항 경계 판정용. 모델이 정확한
  // "개념원리 익히기" 인쇄 문구를 확인했다고 명시한 경우에만 true.
  out.concept_drill_header_visible =
    parsedJson.concept_drill_header_visible === true;

  if (
    out.page_kind === 'concept_page' ||
    /\bconcept_page\b/i.test(out.notes)
  ) {
    // Concept-only A pages should be visible in the UI as analyzed pages, but
    // must never persist fake crop rows.
    out.page_kind = 'concept_page';
    out.items = [];
    return out;
  }

  const series = String(opts?.series || '').trim().toLowerCase();
  const rawItems = Array.isArray(parsedJson.items) ? parsedJson.items : [];
  let droppedLectureConceptNumbers = 0;
  for (const raw of rawItems) {
    if (!raw || typeof raw !== 'object') continue;
    const number = String(raw.number ?? '').trim();
    if (!number) continue;
    const label = normalizeDifficultyLabel(raw.label);
    const inferredSetRange = parseBasicDrillRange(number, series === 'rpm');
    const isSet = Boolean(raw.is_set_header) || Boolean(inferredSetRange);
    let setRange = null;
    if (raw.set_range && typeof raw.set_range === 'object') {
      const from = Number(raw.set_range.from);
      const to = Number(raw.set_range.to);
      if (Number.isFinite(from) && Number.isFinite(to)) {
        setRange = { from, to };
      }
    }
    if (!setRange && inferredSetRange) {
      setRange = inferredSetRange;
    }
    const colRaw = raw.column;
    const column =
      colRaw === 1 || colRaw === 2 ? colRaw : colRaw == null ? null : null;
    const bbox = parseBbox4(raw.bbox ?? raw.bounding_box ?? raw.number_bbox);
    const itemRegion = parseBbox4(
      raw.item_region ??
        raw.itemRegion ??
        raw.region ??
        raw.content_region ??
        raw.content_bbox,
    );
    // 개념원리 단일 패스: 문항마다 카테고리를 붙인다. 모델이 category 를
    // 빠뜨리면 라벨로 1차 보정하고, 나머지는 아래 majority 백필로 채운다.
    const category = normalizeWonriCategory(raw, label, series);
    // 특강 예제는 배지에 "특강 01" 처럼 2자리 번호가 인쇄된다. 특강 개념
    // 페이지의 사각 박스 개념 번호(1, 2 같은 한 자리 수)를 모델이 특강
    // 예제로 오인하면 존재하지 않는 문항이 저장되므로 여기서 걸러낸다.
    if (
      series === 'wonri' &&
      category === 'special_lecture' &&
      !/^\d{2,}$/.test(number)
    ) {
      droppedLectureConceptNumbers += 1;
      continue;
    }
    // 유형 그룹(content_group)은 문항 단위로 판단한다.
    // 개념원리는 B 필수유형(type_example)과 E 특강(special_lecture)만
    // "필수유형 01"/"특강 01" 그룹(제목 포함)을 갖는다.
    const groupDisallowed = category
      ? category !== 'type_example' && category !== 'special_lecture'
      : ['mastery', 'concept_drill', 'check', 'exercise'].includes(out.section);
    const group = groupDisallowed
      ? { kind: 'none', label: '', title: '', order: null }
      : normalizeContentGroup(raw.content_group);
    out.items.push({
      number,
      label,
      category,
      is_set_header: isSet,
      set_range: setRange,
      content_group: group,
      content_group_kind: group.kind,
      content_group_label: group.label,
      content_group_title: group.title,
      content_group_order: group.order,
      column,
      bbox,
      item_region: itemRegion,
    });
  }
  if (droppedLectureConceptNumbers > 0) {
    const suffix =
      `wonri_lecture_concept_numbers_dropped=${droppedLectureConceptNumbers}`;
    out.notes = out.notes ? `${out.notes}; ${suffix}` : suffix;
    // 걸러낸 개념 번호뿐이던 페이지는 개념 페이지로 되돌린다.
    if (out.items.length === 0 && out.page_kind === 'problem_page') {
      out.page_kind = 'concept_page';
    }
  }
  backfillWonriCategories(out, series);
  backfillMissingItemRegions(out);
  backfillBasicDrillItemRegions(out, series);
  backfillMissingBboxes(out);
  validateBasicDrillItems(out, series);
  annotateExpectedBasicDrillStart(out, opts?.expectedStartNumber);
  return out;
}

// 개념원리 "특강 NN" 예제 판별. 모델이 배지 문구를 label 이나
// content_group(label/title)에 담아 보내는 어느 경우든 잡는다.
// 특강은 필수유형과 지면 구성이 같지만 번호가 01부터 새로 시작하므로,
// type_example 로 두면 같은 소단원 필수 번호와 unique key 충돌이 난다.
function isWonriSpecialLectureItem(raw) {
  const texts = [
    raw?.label,
    raw?.content_group?.label,
    raw?.content_group?.title,
  ];
  return texts.some((t) => String(t || '').replace(/\s+/g, '').includes('특강'));
}

// 개념원리 단일 패스 — 문항의 category 를 검증/보정한다.
// 우선순위: 특강 배지(카테고리 오분류 교정) → 모델이 준 category →
// 라벨 기반 추정(필수/STEP/실력).
function normalizeWonriCategory(raw, label, series) {
  if ((!series || series === 'wonri') && isWonriSpecialLectureItem(raw)) {
    return 'special_lecture';
  }
  const value = String(raw?.category ?? '').trim();
  if (WONRI_ITEM_CATEGORIES.includes(value)) return value;
  if (series && series !== 'wonri') return '';
  if (label === '필수') return 'type_example';
  if (
    label === 'STEP1' ||
    label === 'STEP2' ||
    label === '실력' ||
    label === '수능기출' ||
    label === '평가원기출' ||
    label === '교육청기출'
  ) {
    return 'exercise';
  }
  return '';
}

// category 를 못 받은 문항을 같은 페이지의 다수 카테고리(또는 페이지 section)
// 로 채운다. 개념원리가 아닌 시리즈에는 아무 것도 하지 않는다.
function backfillWonriCategories(result, series) {
  if (series !== 'wonri') return;
  if (!Array.isArray(result.items) || result.items.length === 0) return;
  const missing = result.items.filter((item) => !item.category);
  if (missing.length === 0) return;

  const counts = new Map();
  for (const item of result.items) {
    if (!item.category) continue;
    counts.set(item.category, (counts.get(item.category) || 0) + 1);
  }
  let fallback = '';
  if (counts.size > 0) {
    fallback = [...counts.entries()].sort((a, b) => b[1] - a[1])[0][0];
  } else if (WONRI_ITEM_CATEGORIES.includes(result.section)) {
    fallback = result.section;
  }
  if (!fallback) return;
  for (const item of missing) {
    item.category = fallback;
  }
  const suffix = `wonri_category_backfilled=${missing.length}`;
  result.notes = result.notes ? `${result.notes}; ${suffix}` : suffix;
}

function annotateExpectedBasicDrillStart(result, expectedStartNumber) {
  const expected = normalizeExpectedStartNumber(expectedStartNumber);
  if (
    !expected ||
    !result ||
    result.section !== 'basic_drill' ||
    result.page_kind === 'concept_page' ||
    !Array.isArray(result.items) ||
    result.items.length === 0
  ) {
    return;
  }

  const expectedValue = Number.parseInt(expected, 10);
  const values = [];
  for (const item of result.items) {
    const number = String(item?.number || '').trim();
    const range = parseBasicDrillRange(number);
    if (range) {
      for (let n = range.from; n <= range.to && n - range.from <= 60; n += 1) {
        values.push(n);
      }
      continue;
    }
    const n = Number.parseInt(number, 10);
    if (Number.isFinite(n)) values.push(n);
  }
  if (values.length === 0 || values.includes(expectedValue)) return;

  const minValue = Math.min(...values);
  const hasLater = values.some((v) => v > expectedValue);
  const suffix = hasLater
    ? `basic_drill_expected_start_missing=${expected}`
    : `basic_drill_expected_start_mismatch=${expected}; detected_start=${String(minValue).padStart(4, '0')}`;
  result.notes = result.notes ? `${result.notes}; ${suffix}` : suffix;
}

function normalizeExpectedStartNumber(input) {
  const raw = String(input || '').trim();
  if (!raw) return '';
  const match = raw.match(/\d+/);
  if (!match) return '';
  const n = Number.parseInt(match[0], 10);
  if (!Number.isFinite(n) || n <= 0 || n > 9999) return '';
  return String(n).padStart(4, '0');
}

function normalizeDifficultyLabel(input) {
  const raw = String(input || '').trim();
  if (!raw) return '';
  const compact = raw.replace(/\s+/g, '');
  if (!compact || compact === '사고의기술') return '';
  if (compact.includes('서술형') || compact.includes('논술')) return '서술형';
  if (compact === '대표문제') return '대표 문제';
  if (compact === '교육청기출') return '교육청기출';
  // 개념원리 연습문제 하단 기출 구간 라벨. "수능 기출"/"수능기출" 등 표기 변형 흡수.
  if (/^수능기출$/.test(compact)) return '수능기출';
  if (/^평가원기출$/.test(compact)) return '평가원기출';
  // RPM/개념원리: "실력 UP" 구간 라벨. 모델이 "실력UP"/"실력 up" 으로 내보내도 "실력" 으로 정규화.
  if (/^실력(up)?$/i.test(compact)) return '실력';
  // 개념원리 연습문제: STEP 1 / step1 등 표기 변형을 STEP1/STEP2 로 정규화.
  const stepMatch = compact.match(/^step0*([12])$/i);
  if (stepMatch) return `STEP${stepMatch[1]}`;
  // 개념원리 필수유형: "필수 유형"/"필수유형" 도 "필수" 로 정규화.
  if (/^필수(유형)?$/.test(compact)) return '필수';
  return ALLOWED_LABELS.has(compact) ? compact : '';
}

function backfillBasicDrillItemRegions(result, series = '') {
  if (
    !result ||
    result.page_kind === 'concept_page' ||
    result.section !== 'basic_drill' ||
    !Array.isArray(result.items) ||
    result.items.length === 0 ||
    result.items.every((item) => Array.isArray(item.item_region))
  ) {
    return;
  }

  const candidates = result.items.filter(
    (item) =>
      isBasicDrillNumber(
        String(item?.number || '').trim(),
        item?.is_set_header,
        series === 'rpm',
      ) &&
      Array.isArray(item?.bbox),
  );
  if (candidates.length === 0) return;

  const columns = new Map();
  for (const item of candidates) {
    const bbox = item.bbox;
    const key = item.column === 1 || item.column === 2 ? item.column : inferColumn(bbox);
    if (!columns.has(key)) columns.set(key, []);
    columns.get(key).push(item);
  }

  let filled = 0;
  for (const items of columns.values()) {
    items.sort((a, b) => {
      const dy = a.bbox[0] - b.bbox[0];
      return Math.abs(dy) > 12 ? dy : a.bbox[1] - b.bbox[1];
    });
    for (let i = 0; i < items.length; i += 1) {
      const item = items[i];
      if (Array.isArray(item.item_region)) continue;
      const bbox = item.bbox;
      const next = items[i + 1]?.bbox || null;
      const yMin = clamp01k(Math.max(0, bbox[0] - 4));
      const defaultBottom = clamp01k(Math.max(bbox[2] + 52, bbox[0] + 64));
      const yMax = clamp01k(
        next ? Math.max(yMin + 20, Math.min(next[0] - 6, defaultBottom)) : defaultBottom,
      );
      const xMin = clamp01k(bbox[3] + 8);
      const xMax = clamp01k(inferColumn(bbox) === 1 ? 486 : 930);
      if (xMax <= xMin + 20 || yMax <= yMin + 12) continue;
      item.item_region = [yMin, xMin, yMax, xMax];
      filled += 1;
    }
  }

  if (filled > 0) {
    const suffix = `basic_drill_synthesized_item_region=${filled}`;
    result.notes = result.notes ? `${result.notes}; ${suffix}` : suffix;
  }
}

function validateBasicDrillItems(result, series = '') {
  if (
    !result ||
    result.section !== 'basic_drill' ||
    result.page_kind === 'concept_page' ||
    !Array.isArray(result.items) ||
    result.items.length === 0
  ) {
    return;
  }

  const kept = [];
  let dropped = 0;
  const allowIndependentSetGeometry =
    series === 'rpm' || hasStrongBasicDrillPageEvidence(result.items);
  for (const item of result.items) {
    if (isValidBasicDrillItem(item, allowIndependentSetGeometry)) {
      kept.push(item);
    } else {
      dropped += 1;
    }
  }
  if (dropped > 0) {
    const suffix = `basic_drill_candidate_filtered=${dropped}`;
    result.notes = result.notes ? `${result.notes}; ${suffix}` : suffix;
  }
  result.items = kept;
  if (kept.length === 0) {
    result.page_kind = 'concept_page';
    const suffix = 'concept_page:auto_no_valid_basic_number';
    result.notes = result.notes ? `${result.notes}; ${suffix}` : suffix;
  }
}

function hasStrongBasicDrillPageEvidence(items) {
  const values = [];
  for (const item of items || []) {
    if (item?.is_set_header === true) continue;
    if (String(item?.label || '').trim()) continue;
    const number = String(item?.number || '').trim();
    if (!/^\d{4}$/.test(number)) continue;
    if (!isValidBasicDrillItem(item, true)) continue;
    const value = Number.parseInt(number, 10);
    if (Number.isFinite(value)) values.push(value);
  }
  const unique = [...new Set(values)].sort((a, b) => a - b);
  if (unique.length < 3) return false;
  return unique.some((value, index) =>
    index > 0 && value - unique[index - 1] >= 1 && value - unique[index - 1] <= 3
  );
}

function isValidBasicDrillItem(
  item,
  allowIndependentSetGeometry = false,
) {
  const number = String(item?.number || '').trim();
  if (
    !isBasicDrillNumber(
      number,
      item?.is_set_header,
      allowIndependentSetGeometry,
    )
  ) {
    return false;
  }

  if (!Array.isArray(item?.bbox) || !Array.isArray(item?.item_region)) {
    return false;
  }
  const [byMin, bxMin, byMax, bxMax] = item.bbox.map((v) => Number(v));
  const [ryMin, rxMin, ryMax, rxMax] = item.item_region.map((v) => Number(v));
  if (
    ![byMin, bxMin, byMax, bxMax, ryMin, rxMin, ryMax, rxMax].every((v) =>
      Number.isFinite(v),
    )
  ) {
    return false;
  }
  if (byMin >= byMax || bxMin >= bxMax || ryMin >= ryMax || rxMin >= rxMax) {
    return false;
  }

  // RPM A는 개념 페이지와 문제 페이지가 교대로 나오며, 문제 페이지 안에서도
  // 짧은 가로형·세로형·독립형 세트가 섞인다. 4자리 번호(또는 범위 번호)와
  // 유효 좌표가 확인된 RPM 문항을 쎈 전용 짧은 행 기하 검증으로 제거하지 않는다.
  if (allowIndependentSetGeometry) return true;

  if (String(item?.label || '').trim()) return false;

  // 일반 A 문항은 "번호 왼쪽 + 본문 오른쪽"의 짧은 행 구조다. 번호 bbox와
  // 본문 region이 이 관계를 전혀 만족하지 않으면 개념/예제 박스 오탐으로 본다.
  const regionHeight = ryMax - ryMin;
  const numberCenterY = (byMin + byMax) / 2;
  const rowYMin = ryMin - 80;
  const rowYMax = ryMax + 80;
  if (regionHeight > 380) return false;
  const regionStartsAfterNumber = bxMin < rxMin && bxMax <= rxMin + 60;
  const regionContainsNumber = rxMin <= bxMin + 8 && rxMax >= bxMax + 40;
  if (!regionStartsAfterNumber && !regionContainsNumber) return false;
  if (numberCenterY < rowYMin || numberCenterY > rowYMax) return false;
  return true;
}

function isBasicDrillNumber(number, isSetHeader, allowShortSetRange = false) {
  if (isSetHeader) {
    return Boolean(parseBasicDrillRange(number, allowShortSetRange));
  }
  return /^\d{4}$/.test(number);
}

function parseBasicDrillRange(number, allowShort = false) {
  const digitPattern = allowShort ? '\\d{1,4}' : '\\d{4}';
  const match = String(number || '')
    .trim()
    .match(
      new RegExp(
        `^(${digitPattern})\\s*[~\\-\\u2013\\u2014\\u301c]\\s*(${digitPattern})$`,
      ),
    );
  if (!match) return null;
  const from = Number(match[1]);
  const to = Number(match[2]);
  if (!Number.isFinite(from) || !Number.isFinite(to) || from > to) return null;
  return { from, to };
}

function normalizeContentGroup(raw) {
  const src = raw && typeof raw === 'object' ? raw : {};
  const kindRaw = String(src.kind || src.type || '').trim();
  const kind = ['basic_subtopic', 'type', 'none'].includes(kindRaw)
    ? kindRaw
    : 'none';
  const orderRaw = Number(src.order);
  return {
    kind,
    label: kind === 'none' ? '' : String(src.label || '').trim(),
    title: kind === 'none' ? '' : String(src.title || src.name || '').trim(),
    order: Number.isFinite(orderRaw) && orderRaw > 0 ? Math.round(orderRaw) : null,
  };
}

function parseBbox4(arr) {
  // Gemini occasionally wraps coordinates once: [[ymin, xmin, ymax, xmax]].
  // Treat that as the same bbox instead of dropping the whole page silently.
  const value =
    Array.isArray(arr) &&
    arr.length === 1 &&
    Array.isArray(arr[0]) &&
    arr[0].length === 4
      ? arr[0]
      : arr;
  if (!Array.isArray(value) || value.length !== 4) return null;
  const [ymin, xmin, ymax, xmax] = value.map((v) => Number(v));
  if (![ymin, xmin, ymax, xmax].every((v) => Number.isFinite(v))) return null;
  return [clamp01k(ymin), clamp01k(xmin), clamp01k(ymax), clamp01k(xmax)];
}

function backfillMissingItemRegions(result) {
  if (!result || !Array.isArray(result.items) || result.items.length === 0) return;
  if (result.items.every((item) => Array.isArray(item.item_region))) return;
  const canUseVerticalFallback =
    result.page_kind !== 'concept_page' &&
    (['type_practice', 'mastery', 'type_example', 'check', 'exercise'].includes(
      result.section,
    ) ||
      // 개념원리 단일 패스: 페이지 section 과 무관하게 문항 category 로 판단.
      result.items.some((item) => Boolean(item.category)));
  if (!canUseVerticalFallback) return;

  const itemsWithBbox = result.items.filter((item) => Array.isArray(item.bbox));
  if (itemsWithBbox.length === 0) return;
  const columns = new Map();
  for (const item of itemsWithBbox) {
    const bbox = item.bbox;
    const key = item.column === 1 || item.column === 2 ? item.column : inferColumn(bbox);
    if (!columns.has(key)) columns.set(key, []);
    columns.get(key).push(item);
  }
  const columnMins = Array.from(columns.entries())
    .map(([column, items]) => ({
      column,
      minX: Math.min(...items.map((item) => item.bbox[1])),
    }))
    .sort((a, b) => a.minX - b.minX);

  for (const [column, items] of columns.entries()) {
    items.sort((a, b) => a.bbox[0] - b.bbox[0]);
    const xMin = Math.max(0, Math.min(...items.map((item) => item.bbox[1])) - 2);
    const nextColumn = columnMins.find((entry) => entry.minX > xMin + 40);
    const xMax = clamp01k(
      nextColumn
        ? nextColumn.minX - 8
        : Math.max(...items.map((item) => item.bbox[3]), xMin + 403),
    );
    for (let i = 0; i < items.length; i += 1) {
      const item = items[i];
      if (Array.isArray(item.item_region)) continue;
      const bbox = item.bbox;
      const next = items[i + 1]?.bbox || null;
      const yMin = clamp01k(bbox[2] + 7);
      const yMax = clamp01k(next ? Math.max(yMin + 20, next[0] - 8) : 980);
      item.item_region = [yMin, xMin, yMax, clamp01k(Math.max(xMax, xMin + 40))];
    }
  }
}

function backfillMissingBboxes(result) {
  if (!result || !Array.isArray(result.items) || result.items.length === 0) return;
  const canUseFallback =
    result.page_kind !== 'concept_page' &&
    (['type_practice', 'mastery', 'type_example', 'check', 'exercise'].includes(
      result.section,
    ) ||
      result.items.some((item) => Boolean(item.category)));
  if (!canUseFallback) return;

  let filled = 0;
  for (const item of result.items) {
    if (Array.isArray(item.bbox)) continue;
    if (!Array.isArray(item.item_region) || item.item_region.length !== 4) continue;
    const synthesized = synthesizeNumberBboxFromItemRegion(item, result.section);
    if (!synthesized) continue;
    item.bbox = synthesized;
    filled += 1;
  }
  if (filled > 0) {
    const suffix = `synthesized_bbox=${filled}`;
    result.notes = result.notes ? `${result.notes}; ${suffix}` : suffix;
  }
}

function synthesizeNumberBboxFromItemRegion(item, section) {
  const region = item.item_region;
  if (!Array.isArray(region) || region.length !== 4) return null;
  const [yMin, xMin, yMax, xMax] = region.map((v) => Number(v));
  if (![yMin, xMin, yMax, xMax].every((v) => Number.isFinite(v))) return null;

  const label = String(item.label || '').trim();
  const number = String(item.number || '').trim();
  const labelExtra = label ? Math.min(80, label.length * 15) : 0;
  const numberExtra = Math.min(70, Math.max(40, number.length * 12));
  const width = Math.max(82, Math.min(170, numberExtra + labelExtra + 24));

  if (section === 'basic_drill') {
    const right = clamp01k(xMin - 8);
    const left = clamp01k(right - width);
    const top = clamp01k(yMin);
    const bottom = clamp01k(Math.min(yMax, yMin + 22));
    if (left >= right || top >= bottom) return null;
    return [top, left, bottom, right];
  }

  const top = clamp01k(yMin - 28);
  const bottom = clamp01k(yMin - 7);
  const left = clamp01k(xMin);
  const right = clamp01k(Math.min(xMax, xMin + width));
  if (left >= right || top >= bottom) return null;
  return [top, left, bottom, right];
}

function inferColumn(bbox) {
  const centerX = (bbox[1] + bbox[3]) / 2;
  return centerX >= 500 ? 2 : 1;
}

function clamp01k(v) {
  if (!Number.isFinite(v)) return 0;
  if (v < 0) return 0;
  if (v > 1000) return 1000;
  return Math.round(v);
}
