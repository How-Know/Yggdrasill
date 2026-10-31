// 해설 PDF 페이지 이미지를 Gemini Vision 에 보내 "문항번호 bbox" 를 받아오는 클라이언트.
// `vlm_detect_client.js` 와 뼈대는 같지만, 프롬프트와 결과 정규화 규칙이 다르다.

import { buildDetectSolutionRefsPrompt } from './vlm_solution_refs_prompt.js';
import {
  joinGeminiTextParts,
  parseTextbookVlmJson,
} from './vlm_json_parse.js';
import {
  buildExpectedIndex,
  canonicalCorner,
  createSequentialState,
  expandBadgeRange,
  footerEchoPages,
  resolveExpectedBox,
  resolveSequentialBox,
  stripFooterEchoBadge,
  stripNextBoxBadge,
} from './vlm_corner_guard.js';
import {
  normalizeProblemNumberKey,
  parseProblemNumberRange,
  parseSingleProblemNumber,
} from './problem_number_key.js';

const SOLREF_TRANSIENT_STATUSES = new Set([429, 499, 500, 502, 503, 504]);
const SOLREF_DEFAULT_MAX_RETRIES = 3;

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

export async function detectSolutionRefsOnPage({
  imageBase64,
  mimeType = 'image/png',
  rawPage,
  displayPage,
  pageOffset,
  expectedNumbers,
  expectedEntries,
  skipBadges,
  series,
  model,
  apiKey,
  timeoutMs = 90000,
  maxRetries = SOLREF_DEFAULT_MAX_RETRIES,
}) {
  const key = String(apiKey || '').trim();
  if (!key) throw new Error('vlm_solref_api_key_missing');
  const img = String(imageBase64 || '').trim();
  if (!img) throw new Error('vlm_solref_image_empty');

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
            inline_data: { mime_type: mimeType, data: img },
          },
          {
            text: buildDetectSolutionRefsPrompt({
              rawPage,
              displayPage,
              pageOffset,
              expectedNumbers,
              expectedEntries,
              skipBadges,
              series,
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

  let lastStatus = 0;
  let lastBody = '';
  let lastErr = null;
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
        `vlm_solref_fetch_error: ${compactErrMsg(err)} (attempts=${attempt + 1})`,
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
        SOLREF_TRANSIENT_STATUSES.has(res.status) &&
        !isDailyQuotaExceededBody(textBody) &&
        attempt + 1 < attempts
      ) {
        await sleep(800 * Math.pow(2, attempt));
        continue;
      }
      throw new Error(
        `vlm_solref_http_${res.status}: ${String(textBody).slice(0, 500)} (attempts=${attempt + 1})`,
      );
    }
    let payload;
    try {
      payload = JSON.parse(textBody);
    } catch (_) {
      throw new Error(
        `vlm_solref_non_json_response: ${String(textBody).slice(0, 500)}`,
      );
    }
    const candidate = (payload?.candidates || [])[0];
    const modelText = joinGeminiTextParts(candidate?.content?.parts);
    const parsedJson = parseTextbookVlmJson(modelText);
    if (!parsedJson) {
      throw new Error(
        `vlm_solref_parse_failed: finish=${candidate?.finishReason || '-'} text_head="${modelText.slice(
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
  throw new Error(
    `vlm_solref_exhausted: status=${lastStatus} lastErr=${compactErrMsg(lastErr)} body=${String(
      lastBody,
    ).slice(0, 300)}`,
  );
}

function compactErrMsg(err) {
  if (!err) return '';
  const name = err?.name ? `${err.name}: ` : '';
  return `${name}${String(err?.message || err).slice(0, 300)}`;
}

export function normalizeSolutionRefsResult(parsedJson, opts = {}) {
  const out = { items: [], notes: '' };
  if (!parsedJson || typeof parsedJson !== 'object') return out;
  out.notes = String(parsedJson.notes || '').trim();
  const expectedNumbers = Array.isArray(opts?.expectedNumbers)
    ? opts.expectedNumbers.map((n) => String(n || '').trim()).filter(Boolean)
    : [];
  const expectedIndex = buildExpectedIndex(
    opts?.expectedEntries,
    normalizeProblemNumberKey,
  );
  const series = String(opts?.series || '').trim();
  const isGojaengi = series === 'gojaengi';
  const isGaeyuHigh = series === 'gaeyu_high';
  const stripsFooterEcho = isGojaengi || isGaeyuHigh;
  const footerPages = footerEchoPages(opts);
  const sequential = createSequentialState();
  const rawItems = Array.isArray(parsedJson.items) ? parsedJson.items : [];
  const seen = new Set();
  for (const rawItem of rawItems) {
    if (!rawItem || typeof rawItem !== 'object') continue;
    let raw = stripsFooterEcho
      ? stripFooterEchoBadge(rawItem, footerPages)
      : rawItem;
    const problemNumber = String(raw.problem_number ?? '').trim();
    if (!problemNumber) continue;
    let resolved =
      (isGaeyuHigh
        ? resolveSequentialBox(
            raw,
            problemNumber,
            expectedIndex,
            normalizeProblemNumberKey,
            sequential,
            parseBbox4(raw.number_region)
              ? JSON.stringify(parseBbox4(raw.number_region))
              : '',
          )
        : null) ??
      resolveExpectedBox(
        raw,
        problemNumber,
        expectedIndex,
        normalizeProblemNumberKey,
      );
    // 같은 지면 아래쪽에서 다음 묶음 머리가 시작하면, 그 위의 마지막 풀이에도
    // 모델이 새 배지 쪽을 붙인다. 현재 기대 후보가 번호상 하나뿐이고 보고 쪽이
    // 딱 한 쪽 차이면 페이지 단서만 버려 다시 대조한다. 요약 상자는 아래의
    // content-region/격자 필터가 별도로 제거한다.
    if ((isGojaengi || isGaeyuHigh) && resolved.reject) {
      const softened = isGojaengi
        ? stripAdjacentBlockBadge(raw, problemNumber, expectedIndex)
        : stripNextBoxBadge(
            raw,
            problemNumber,
            expectedIndex,
            normalizeProblemNumberKey,
          );
      if (softened !== raw) {
        raw = softened;
        resolved = resolveExpectedBox(
          raw,
          problemNumber,
          expectedIndex,
          normalizeProblemNumberKey,
        );
      }
    }
    if (resolved.reject) continue;
    const badgeCorner = canonicalCorner(raw.source_corner ?? raw.sourceCorner);
    const numberRegion = parseBbox4(raw.number_region);
    if (!numberRegion) continue;
    const contentRegion = parseBbox4(raw.content_region);
    const base = {
      problem_number: problemNumber,
      number_region: numberRegion,
      content_region: contentRegion,
    };
    if (resolved.matched) {
      base.expected_index = resolved.matched.index;
      base.problem_number = resolved.matched.number;
    }
    pushUniqueSolutionRef(out.items, seen, base, badgeCorner);
    // 기대 문항 하나로 특정된 번호는 범위 배지가 아니다. "01-3" 같은 하이픈
    // 번호를 1~3 범위로 펼치면 같은 지면 다른 코너의 1·2·3 에 번진다.
    if (resolved.matched) continue;
    for (const expanded of expandSolutionRefRange(
      problemNumber,
      expectedNumbers,
      expectedIndex,
      raw,
    )) {
      pushUniqueSolutionRef(
        out.items,
        seen,
        {
          ...base,
          problem_number: expanded.number,
          ...(expanded.index >= 0 ? { expected_index: expanded.index } : {}),
        },
        badgeCorner,
      );
    }
  }
  if (isGojaengi) {
    out.items = dropGojaengiSummaryCells(out.items);
    out.items = dropGojaengiSummaryGrid(out.items);
  }
  return out;
}

// 본교재 번호는 책 전체에서 이어지는 세 자리라 뒤 묶음에 같은 번호가 다시
// 나오지 않는다. 그래서 다음 묶음 배지가 개념 쪽 몇 장 건너 뒤에 있어도
// 받아들인다(1-1 해설 18쪽: 본문 34쪽 122번 풀이에 오른쪽 단 새 묶음
// "본교재 037~040쪽"을 붙임). 워크북·TEST는 묶음마다 01부터 다시 시작하므로
// 한 쪽 차이만 허용한다.
const BODY_BOOK_NEXT_BLOCK_MAX_GAP = 8;

function stripAdjacentBlockBadge(raw, problemNumber, expectedIndex) {
  const key = normalizeProblemNumberKey(problemNumber);
  const candidates = expectedIndex?.byKey?.get(key);
  if (!Array.isArray(candidates) || candidates.length !== 1) return raw;
  const candidate = candidates[0];
  const from = Number.parseInt(
    String(raw.source_page ?? raw.sourcePage ?? ''),
    10,
  );
  if (!Number.isFinite(from) || !candidate.page) return raw;
  const reportedCorner = canonicalCorner(
    raw.source_corner ?? raw.sourceCorner,
  );
  const gap = from - candidate.page;
  const bodyBookNextBlock =
    candidate.corner === 'body_book' &&
    (!reportedCorner || reportedCorner === 'body_book') &&
    gap > 1 &&
    gap <= BODY_BOOK_NEXT_BLOCK_MAX_GAP;
  if (Math.abs(gap) !== 1 && !bodyBookNextBlock) return raw;
  if (
    reportedCorner &&
    candidate.corner &&
    reportedCorner !== candidate.corner
  ) {
    return raw;
  }
  const out = { ...raw };
  delete out.source_page;
  delete out.sourcePage;
  delete out.source_page_end;
  delete out.sourcePageEnd;
  return out;
}

// 요약 상자 칸은 번호 옆에 답만 붙은 한 줄이라 풀이 영역이 없다. 실측하면 모델도
// content_region 을 아예 비워 보내거나 자기 칸 크기만 적어 보낸다. 격자
// 판정([SUMMARY_ROW_MIN_BOXES])은 한 줄에 번호칸이 셋 이상 와야 걸리므로, 요약
// 상자의 마지막 줄에서 한두 칸만 돌아오거나 문항을 하나씩 물어볼 때는 못 잡는다.
// 풀이 영역 자체를 조건으로 걸어야 그 구멍이 막힌다.
//
// 크기는 폭과 높이를 함께 본다. 실제 풀이는 단(칼럼) 폭을 꽉 채우고(실측 409~480),
// 요약 상자 칸은 자기 칸만 덮는다(실측 60). 높이만 보면 지면 맨 아래에서 시작해
// 다음 장으로 넘어가는 풀이(105쪽 542번, 높이 52)가 위태롭게 걸린다.
//
// 두 줄짜리 짧은 풀이도 글자 폭에 맞춰 잡히면 폭·높이가 상자 칸만큼 작다
// (1-2 해설 5쪽 023번: "③ …", "④ …" 두 줄, 높이 55). 상자 칸은 번호 줄
// 하나뿐이라 풀이 영역이 번호 아래로 내려가지 않는다는 점으로 가른다.
const SUMMARY_CELL_MAX_WIDTH = 200; // 좌표계 0~1000
const SUMMARY_CELL_MAX_HEIGHT = 60;
const SUMMARY_CELL_MAX_TAIL = 20; // 번호 칸 아래로 더 내려간 높이

function dropGojaengiSummaryCells(items) {
  return items.filter((item) => {
    const region = item.content_region;
    if (!Array.isArray(region) || region.length !== 4) return false;
    const height = region[2] - region[0];
    const width = region[3] - region[1];
    const number = item.number_region;
    const tail = Array.isArray(number) ? region[2] - number[2] : height;
    // 모두 작을 때만 상자 칸으로 단정한다. 하나라도 크면 풀이로 본다.
    return !(
      width < SUMMARY_CELL_MAX_WIDTH &&
      height < SUMMARY_CELL_MAX_HEIGHT &&
      tail < SUMMARY_CELL_MAX_TAIL
    );
  });
}

// 고쟁이 해설은 묶음 머리 바로 아래에 "그 묶음 정답만 모아 둔 요약 상자" 를 두고
// 번호를 격자로 늘어놓는다("106 10  107 15°  108 150° …"). 모델이 이 상자를 풀이로
// 착각하면 풀이가 뒤 지면에 있는 번호까지 한 지면에서 다 채워 버려서, 채움 수는
// 멀쩡한데 좌표는 전부 요약 상자를 가리킨다. 실제 풀이 번호는 단 왼쪽에 혼자
// 서므로 같은 가로 띠에 번호칸이 여럿 몰려 있으면 격자로 보고 버린다.
const SUMMARY_ROW_BAND = 12; // 같은 줄로 볼 y 오차 (좌표계 0~1000)
const SUMMARY_LANE_TOLERANCE = 30; // 같은 세로 칸으로 볼 x 오차
const SUMMARY_ROW_GAP = 60; // 상자 안 다음 줄로 이어 볼 최대 간격
const SUMMARY_ROW_MIN_BOXES = 3; // 격자로 단정할 한 줄 번호칸 수

function dropGojaengiSummaryGrid(items) {
  const bands = groupItemsIntoRows(items);
  if (!bands.some((band) => band.boxes.length >= SUMMARY_ROW_MIN_BOXES)) {
    return items;
  }
  const lanes = [];
  for (const band of bands) {
    if (band.boxes.length < SUMMARY_ROW_MIN_BOXES) continue;
    for (const box of band.boxes) lanes.push(box.xc);
  }
  const firstGrid = bands.findIndex(
    (band) => band.boxes.length >= SUMMARY_ROW_MIN_BOXES,
  );
  const drop = new Set();
  let prev = null;
  for (let i = firstGrid; i < bands.length; i += 1) {
    const band = bands[i];
    if (prev && band.top - prev.bottom > SUMMARY_ROW_GAP) break;
    const aligned = band.boxes.every((box) =>
      lanes.some((lane) => Math.abs(lane - box.xc) <= SUMMARY_LANE_TOLERANCE),
    );
    if (!aligned) break;
    for (const box of band.boxes) {
      for (const index of box.indexes) drop.add(index);
    }
    prev = band;
  }
  if (drop.size === 0) return items;
  return items.filter((_, index) => !drop.has(index));
}

/// 같은 좌표를 공유하는 item(세트형 범위를 펼친 것들) 은 한 칸으로 센다.
function groupItemsIntoRows(items) {
  const byBox = new Map();
  for (let index = 0; index < items.length; index += 1) {
    const region = items[index].number_region;
    if (!Array.isArray(region) || region.length !== 4) continue;
    const key = region.join(',');
    let box = byBox.get(key);
    if (!box) {
      box = {
        yc: (region[0] + region[2]) / 2,
        xc: (region[1] + region[3]) / 2,
        top: region[0],
        bottom: region[2],
        indexes: [],
      };
      byBox.set(key, box);
    }
    box.indexes.push(index);
  }
  const boxes = [...byBox.values()].sort((a, b) => a.yc - b.yc);
  const bands = [];
  for (const box of boxes) {
    const band = bands[bands.length - 1];
    if (band && box.yc - band.boxes[0].yc <= SUMMARY_ROW_BAND) {
      band.boxes.push(box);
      band.top = Math.min(band.top, box.top);
      band.bottom = Math.max(band.bottom, box.bottom);
      continue;
    }
    bands.push({ top: box.top, bottom: box.bottom, boxes: [box] });
  }
  return bands;
}

function pushUniqueSolutionRef(items, seen, item, badgeCorner = '') {
  const key = solutionRefDedupKey(item, badgeCorner);
  if (!key || seen.has(key)) return;
  seen.add(key);
  items.push(item);
}

/// 정답 쪽 `answerDedupKey` 와 같은 이유로 코너를 함께 묶는다. 해설 지면에도
/// 코너 블록이 나란히 서고 번호가 겹친다.
function solutionRefDedupKey(item, badgeCorner) {
  if (Number.isInteger(item.expected_index) && item.expected_index >= 0) {
    return `#${item.expected_index}`;
  }
  const numberKey = normalizeProblemNumberKey(item.problem_number);
  if (!numberKey) return '';
  return badgeCorner ? `${numberKey}|${badgeCorner}` : numberKey;
}

function expandSolutionRefRange(
  problemNumber,
  expectedNumbers,
  expectedIndex,
  raw,
) {
  const range = parseProblemNumberRange(problemNumber);
  if (!range) return [];
  if (expectedIndex && expectedIndex.all.length > 0) {
    return expandBadgeRange(range, expectedIndex, raw).map((candidate) => ({
      number: candidate.number,
      index: candidate.index,
    }));
  }
  if (expectedNumbers.length === 0) return [];
  const out = [];
  for (const expected of expectedNumbers) {
    const n = parseSingleProblemNumber(expected);
    if (n == null || n < range.from || n > range.to) continue;
    out.push({ number: expected, index: -1 });
  }
  return out;
}

function parseBbox4(arr) {
  if (!Array.isArray(arr) || arr.length !== 4) return null;
  const [ymin, xmin, ymax, xmax] = arr.map((v) => Number(v));
  if (![ymin, xmin, ymax, xmax].every((v) => Number.isFinite(v))) return null;
  return [clamp01k(ymin), clamp01k(xmin), clamp01k(ymax), clamp01k(xmax)];
}

function clamp01k(v) {
  if (!Number.isFinite(v)) return 0;
  if (v < 0) return 0;
  if (v > 1000) return 1000;
  return Math.round(v);
}
