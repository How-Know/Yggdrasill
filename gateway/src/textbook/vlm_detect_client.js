// 교재 페이지 이미지를 Gemini Vision 에 보내 "문항번호 bbox" 를 받아오는 클라이언트.
//
// 기존 `extract_engines/vlm/client.js` 는 PDF inline_data 전용이고 프롬프트도
// 문제은행 전용이라 재사용하지 않고 별도 모듈로 분리했다.
//
// Node >= 18 의 global fetch / AbortController 만 사용한다. 외부 의존성 없음.

import { buildDetectProblemsPrompt } from './vlm_detect_prompt.js';
import { repairLatexBackslashes } from '../problem_bank/extract_engines/vlm/client.js';

const TRANSIENT_STATUSES = new Set([429, 500, 502, 503, 504]);
const DEFAULT_MAX_RETRIES = 3;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
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
  maxRetries = DEFAULT_MAX_RETRIES,
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
            text: buildDetectProblemsPrompt({
              rawPage,
              displayPage,
              pageOffset,
              includeContentGroups,
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
      if (TRANSIENT_STATUSES.has(res.status) && attempt + 1 < attempts) {
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
    let parsedJson = null;
    try {
      parsedJson = JSON.parse(modelText);
    } catch (_) {
      const repaired = repairLatexBackslashes(modelText);
      try {
        parsedJson = JSON.parse(repaired);
      } catch (_) {
        const m = repaired.match(/\{[\s\S]*\}/);
        if (m) {
          try {
            parsedJson = JSON.parse(m[0]);
          } catch (_) {
            // leave null
          }
        }
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

function compactErrMsg(err) {
  if (!err) return '';
  const name = err?.name ? `${err.name}: ` : '';
  return `${name}${String(err?.message || err).slice(0, 300)}`;
}

export function normalizeDetectResult(parsedJson, opts = {}) {
  const out = {
    section: 'unknown',
    page_kind: 'unknown',
    page_layout: 'unknown',
    items: [],
    notes: '',
  };
  if (!parsedJson || typeof parsedJson !== 'object') return out;

  const section = String(parsedJson.section || '').trim();
  out.section = ['basic_drill', 'type_practice', 'mastery', 'unknown'].includes(
    section,
  )
    ? section
    : 'unknown';
  const sectionHint = String(opts?.sectionHint || '').trim();
  if (['basic_drill', 'type_practice', 'mastery'].includes(sectionHint)) {
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

  const rawItems = Array.isArray(parsedJson.items) ? parsedJson.items : [];
  for (const raw of rawItems) {
    if (!raw || typeof raw !== 'object') continue;
    const number = String(raw.number ?? '').trim();
    if (!number) continue;
    const label = String(raw.label ?? '').trim();
    const isSet = Boolean(raw.is_set_header);
    let setRange = null;
    if (raw.set_range && typeof raw.set_range === 'object') {
      const from = Number(raw.set_range.from);
      const to = Number(raw.set_range.to);
      if (Number.isFinite(from) && Number.isFinite(to)) {
        setRange = { from, to };
      }
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
    const group =
      out.section === 'mastery'
        ? { kind: 'none', label: '', title: '', order: null }
        : normalizeContentGroup(raw.content_group);
    out.items.push({
      number,
      label,
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
  backfillMissingItemRegions(out);
  backfillMissingBboxes(out);
  return out;
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
    (result.section === 'type_practice' || result.section === 'mastery');
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
    ['basic_drill', 'type_practice', 'mastery'].includes(result.section);
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
