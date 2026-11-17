// 시험지 PDF 한 쪽에서 문항 영역을 찾는다(Gemini 이미지 입력).
//
// 지면에 인쇄된 번호로 맞추지 않는다. 서술형은 지면에 "서술형 1" 로 찍혀 있어도 문제은행 번호는 17 일 수 있다.
// 그래서 그 쪽에 실린 문항 목록(번호 + 본문 첫머리)을 주고, 받은 key 그대로 영역만 돌려받는다.
import { parseRegion } from '../../mock_exam/mock_pages.js';
import { mapLimit, renderPagePng } from './pdf_tools.js';

const REGION_PAD_1K = 4;

/// 본문 첫머리(구조 표시·수식 구분자 제거). 모델이 지면에서 문항을 찾는 단서다.
export function questionHint(stem, maxLen = 44) {
  const text = String(stem || '')
    .replace(/\[\[?[^\]\n]{1,24}\]\]?/g, ' ')
    .replace(/\$+/g, ' ')
    .replace(/\\(?:left|right|displaystyle|,|;|!|quad|qquad)\b/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  return text.length > maxLen ? `${text.slice(0, maxLen)}…` : text;
}

export function buildItemRegionPrompt(questions) {
  const list = (Array.isArray(questions) ? questions : [])
    .map((q, i) => {
      const kind = String(q?.kind || '').trim();
      const hint = String(q?.hint || '').trim();
      return `${i + 1}) key "${q.key}"${kind ? ` · ${kind}` : ''}${hint ? ` · 첫머리: ${hint}` : ''}`;
    })
    .join('\n');
  return [
    '학교 시험지 한 쪽의 이미지입니다. 아래 목록의 문항이 이 쪽에 실려 있습니다.',
    '목록은 지면 순서(왼쪽 단 위에서 아래, 그다음 오른쪽 단 위에서 아래)입니다.',
    '각 문항이 지면에서 차지하는 영역을 찾아 주세요.',
    '',
    '찾는 법',
    '- 목록의 "첫머리"는 그 문항 본문의 시작 부분입니다. 순서와 첫머리로 문항을 찾습니다.',
    '- 서술형·서답형 문항은 지면에 "서술형 1", "[서답형 2]" 처럼 따로 번호가 붙어 있을 수 있습니다. 그때도 목록의 key 로 답합니다.',
    '',
    '영역 규칙',
    '- 문항 번호(또는 "서술형 n" 표시)부터 그 문항의 마지막 내용까지 빠짐없이 감싸는 직사각형 하나입니다.',
    '  본문, 선지 ①~⑤, 그림, 표, <보기>, 조건 상자, 배점 표시를 모두 넣습니다.',
    '- 다른 문항의 글자나 그림, 머리말(학교명·과목명·쪽 번호), 단 구분선은 넣지 않습니다.',
    '- 문항 아래의 빈 풀이 공간이나 답을 쓰는 빈칸은 넣지 않습니다.',
    '- 좌표는 이미지 전체를 0~1000 으로 본 정수 [ymin, xmin, ymax, xmax] 입니다.',
    '- 이 쪽에서 찾지 못한 문항은 found 를 false 로 둡니다. 목록에 없는 문항은 답하지 않습니다.',
    '',
    '문항 목록',
    list,
    '',
    'JSON 만 출력합니다:',
    '{"items":[{"key":"1","found":true,"region":[ymin,xmin,ymax,xmax]}]}',
  ].join('\n');
}

function padRegion(region) {
  const [y1, x1, y2, x2] = region;
  return [
    Math.max(0, y1 - REGION_PAD_1K),
    Math.max(0, x1 - REGION_PAD_1K),
    Math.min(1000, y2 + REGION_PAD_1K),
    Math.min(1000, x2 + REGION_PAD_1K),
  ];
}

/// 모델 응답 → Map(key → [ymin, xmin, ymax, xmax]). 요청한 key 만, 영역이 온전한 것만 받는다.
/// 문항이 셋 이상인 쪽에서 한 문항이 쪽의 절반을 넘으면 잘못 잡은 것으로 보고 버린다.
export function normalizeItemRegions(parsedJson, keys) {
  const wanted = new Set((Array.isArray(keys) ? keys : []).map((k) => String(k)));
  const out = new Map();
  const items = Array.isArray(parsedJson?.items) ? parsedJson.items : [];
  for (const item of items) {
    const key = String(item?.key ?? '').trim();
    if (!wanted.has(key) || out.has(key) || item?.found === false) continue;
    const region = parseRegion(item?.region);
    if (!region) continue;
    const area = (region[2] - region[0]) * (region[3] - region[1]);
    if (wanted.size >= 3 && area > 500_000) continue;
    out.set(key, padRegion(region));
  }
  return out;
}

/// questions: [{ key, page, order, hint, kind }] → Map(key → { rawPage, region1k })
/// 찾지 못한 문항은 같은 쪽에서 한 번 더, 그래도 없으면 앞뒤 쪽에서 찾는다. 끝내 못 찾은 key 는 결과에 없다.
export async function detectExamItemRegions({
  pdfPath,
  dir,
  pageCount,
  questions,
  callImageJson,
  renderPage = renderPagePng,
  dpi = 130,
  concurrency = 3,
  log = null,
}) {
  const found = new Map();
  const list = (Array.isArray(questions) ? questions : [])
    .filter((q) => String(q?.key ?? '').trim())
    .map((q) => ({
      ...q,
      key: String(q.key).trim(),
      page: Math.min(Math.max(1, Number(q.page) || 1), Math.max(1, Number(pageCount) || 1)),
    }))
    .sort((a, b) => Number(a.order || 0) - Number(b.order || 0));
  if (list.length === 0) return found;

  const pngCache = new Map();
  const pagePng = async (page) => {
    if (!pngCache.has(page)) pngCache.set(page, renderPage(pdfPath, dir, page, dpi));
    return pngCache.get(page);
  };

  const askPage = async (page, targets) => {
    if (targets.length === 0) return 0;
    try {
      const imageBuffer = await pagePng(page);
      const parsed = await callImageJson({ imageBuffer, prompt: buildItemRegionPrompt(targets), page });
      const regions = normalizeItemRegions(parsed, targets.map((q) => q.key));
      for (const [key, region1k] of regions) {
        if (!found.has(key)) found.set(key, { rawPage: page, region1k });
      }
      return regions.size;
    } catch (err) {
      log?.('exam_item_regions_page_failed', { page, message: String(err?.message || err) });
      return 0;
    }
  };

  const byPage = new Map();
  for (const q of list) {
    if (!byPage.has(q.page)) byPage.set(q.page, []);
    byPage.get(q.page).push(q);
  }
  const pages = Array.from(byPage.keys()).sort((a, b) => a - b);
  await mapLimit(pages, concurrency, (page) => askPage(page, byPage.get(page)));

  // 같은 쪽에서 빠진 문항만 한 번 더 묻는다.
  const retryPages = pages.filter((page) => byPage.get(page).some((q) => !found.has(q.key)));
  await mapLimit(retryPages, concurrency, (page) =>
    askPage(page, byPage.get(page).filter((q) => !found.has(q.key))),
  );

  // 추출 때 적힌 쪽이 한 쪽 어긋난 문항: 앞뒤 쪽에서 찾는다.
  const neighbours = new Map();
  for (const q of list) {
    if (found.has(q.key)) continue;
    for (const page of [q.page + 1, q.page - 1]) {
      if (page < 1 || page > Number(pageCount || 0)) continue;
      if (!neighbours.has(page)) neighbours.set(page, []);
      neighbours.get(page).push(q);
    }
  }
  for (const page of Array.from(neighbours.keys()).sort((a, b) => a - b)) {
    await askPage(page, neighbours.get(page).filter((q) => !found.has(q.key)));
  }

  log?.('exam_item_regions_done', {
    questionCount: list.length,
    foundCount: found.size,
    missing: list.filter((q) => !found.has(q.key)).map((q) => q.key),
  });
  return found;
}
