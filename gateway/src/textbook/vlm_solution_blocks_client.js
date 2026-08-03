// 해설 PDF 한 지면에 **어느 소단원 블록이 실려 있는지**만 먼저 읽는 클라이언트.
//
// 수력충전 해설은 소단원 블록이 줄줄이 이어지고, 블록 머리("04 두 선분의 길이의
// 합의 최솟값 ▶p.16~17")는 블록이 시작될 때 한 번만 인쇄된다. 이어지는 지면은
// 배지 없이 번호부터 시작한다. 그래서 "이 블록의 01~09 를 찾아라" 하고 지면을
// 통째로 물으면, 모델은 그 지면에 실제로 있는 **다른 소단원**의 01~09 를 번호만
// 맞춰 돌려준다(같은 자리를 여러 문항이 가리키는 원인이었다).
//
// 문항을 묻기 전에 지면마다 이 호출을 한 번 돌려 블록 머리 목록을 받아 두면,
// 어느 블록을 어느 지면에서 물어야 하는지가 확정된다. 배지가 안 보이는 앞부분은
// 직전 지면의 마지막 블록이 이어진 것이므로 앱이 이어 붙인다.

import {
  joinGeminiTextParts,
  parseTextbookVlmJson,
} from './vlm_json_parse.js';

const TRANSIENT_STATUSES = new Set([429, 500, 502, 503, 504]);

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function buildSolutionBlockIndexPrompt({ rawPage }) {
  return [
    '당신은 한국 교재 **해설(풀이) PDF 한 지면**의 뼈대만 읽어내는 비전 AI 입니다.',
    '읽을 것은 두 가지뿐이다: (가) 소단원 블록 머리, (나) 문항 번호의 위치.',
    '어떤 번호가 어느 문항인지 **짝지으려 하지 마라**. 보이는 대로만 적으면 된다.',
    '반드시 아래 JSON 스키마만 출력하세요. 설명·마크다운·코드펜스 금지.',
    '',
    `이 이미지는 해설 PDF 의 한 지면 (PDF raw page ${rawPage}) 이다.`,
    '',
    '=== (가) 블록 머리 ===',
    '해설은 소단원 블록이 이어 붙어 있고, 블록이 시작될 때 머리글이 한 번 인쇄된다.',
    '예: "04 두 선분의 길이의 합의 최솟값  ▶p.16~17"',
    '    "단원 마무리 평가  ▶문제편 p.29~33"',
    '머리글에는 소단원 번호·이름과 **본문 페이지 배지**("▶p.16~17")가 함께 붙는다.',
    '',
    '[B1] 이 지면에 보이는 블록 머리를 모두 담아라.',
    '[B2] 배지의 시작 쪽과 끝 쪽을 숫자로 적어라("▶p.16~17" → 16, 17. "▶p.16" → 16, 16).',
    '[B3] 지면 첫머리(왼쪽 단 맨 위)가 블록 머리 없이 번호부터 시작하면, 그것은',
    '   앞 지면에서 넘어온 이어지는 블록이다. leading_continuation=true 로 적어라.',
    '   왼쪽 단 맨 위가 블록 머리로 시작하면 false 다.',
    '[B4] "풀이", "참고", "다른 풀이", "채점 기준", "수력 UP" 은 블록 머리가 아니다.',
    '[B5] 없는 블록을 지어내지 마라. 배지를 못 읽었으면 page_start=0 으로 두고',
    '   title 만 적어라.',
    '',
    '=== (나) 문항 번호 ===',
    '[P1] 풀이 한 덩어리의 맨 앞에 찍힌 **굵은 두 자리 번호**("01", "02", … "14")를',
    '   하나도 빠짐없이 담아라. 보통 번호 오른쪽에 "답" 표시와 정답이 이어진다.',
    '[P2] number_region 은 그 번호 글자만 감싸는 가장 작은 박스다. 옆의 "답" 표시나',
    '   정답은 포함하지 마라.',
    '[P3] 다음은 문항 번호가 아니다. 절대 담지 마라:',
    '   - 원문자 ①②③④⑤ 와 ㉠㉡, 그리고 정답으로 적힌 숫자',
    '   - 수식 안의 숫자, 분수, 좌표, 각주 번호',
    '   - 지면 아래쪽의 쪽 번호("31", "32 정답 및 해설")',
    '   - 블록 머리에 붙은 소단원 번호(그건 (가) 에 담는다)',
    '[P4] 번호는 보이는 대로 적어라. 앞의 0 도 그대로("01"). 지면에 있는 순서를',
    '   바꾸지 말고, 왼쪽 단을 위에서 아래로 다 읽은 뒤 다음 단으로 넘어가라.',
    '',
    '=== 출력 스키마 ===',
    '{',
    '  "leading_continuation": true | false,',
    '  "blocks": [',
    '    {',
    '      "title": "<블록 머리에 인쇄된 이름. 예: \\"04 두 선분의 길이의 합의 최솟값\\">",',
    '      "page_start": <배지 시작 쪽 숫자. 못 읽었으면 0>,',
    '      "page_end": <배지 끝 쪽 숫자. 못 읽었으면 0>,',
    '      "header_region": [<ymin>, <xmin>, <ymax>, <xmax>]',
    '    }',
    '  ],',
    '  "numbers": [',
    '    {',
    '      "text": "<인쇄된 번호 그대로. 예: \\"01\\">",',
    '      "number_region": [<ymin>, <xmin>, <ymax>, <xmax>]',
    '    }',
    '  ]',
    '}',
    '',
    '좌표계: 이미지 좌상단 (0,0), 우하단 (1000,1000). 순서는 [ymin, xmin, ymax, xmax].',
    '',
    '지금 첨부된 이미지를 분석해 위 스키마로만 출력하라.',
  ].join('\n');
}

export function buildSolutionNumberOnlyPrompt({ rawPage }) {
  return [
    '한국 수학 교재 해설 PDF에서 **문항 시작 번호 위치만** 찾으세요.',
    `이 이미지는 해설 PDF raw page ${rawPage} 입니다.`,
    '',
    '초록색 굵은 두 자리 문항번호를 위에서 아래로 빠짐없이 찾으세요.',
    '예: 10, 11, 12, ... 26. 페이지에 소단원 머리가 없어도 번호는 반드시 찾습니다.',
    '번호 오른쪽의 파란 "답" 아이콘, 정답, 수식 속 숫자, 원문자, 쪽 번호는 제외합니다.',
    'number_region은 초록색 번호 글자만 감싸는 0..1000 좌표입니다.',
    '',
    'JSON만 출력:',
    '{',
    '  "leading_continuation": true,',
    '  "blocks": [],',
    '  "numbers": [',
    '    {"text":"15","number_region":[ymin,xmin,ymax,xmax]}',
    '  ]',
    '}',
  ].join('\n');
}

export async function detectSolutionBlocksOnPage({
  imageBase64,
  mimeType = 'image/png',
  rawPage,
  model,
  apiKey,
  timeoutMs = 60000,
  maxRetries = 3,
  numbersOnly = false,
}) {
  const key = String(apiKey || '').trim();
  if (!key) throw new Error('vlm_solblocks_api_key_missing');
  const img = String(imageBase64 || '').trim();
  if (!img) throw new Error('vlm_solblocks_image_empty');

  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/` +
    `${encodeURIComponent(model)}:generateContent?key=` +
    `${encodeURIComponent(key)}`;

  const body = {
    contents: [
      {
        role: 'user',
        parts: [
          { inline_data: { mime_type: mimeType, data: img } },
          {
            text: numbersOnly
              ? buildSolutionNumberOnlyPrompt({ rawPage })
              : buildSolutionBlockIndexPrompt({ rawPage }),
          },
        ],
      },
    ],
    generationConfig: {
      temperature: 0,
      responseMimeType: 'application/json',
      maxOutputTokens: 2048,
      thinkingConfig: { thinkingLevel: 'low' },
    },
  };

  const attempts = Math.max(1, Number(maxRetries) || 1);
  let lastStatus = 0;
  let lastBody = '';
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
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
      if (attempt + 1 < attempts) {
        await sleep(800 * Math.pow(2, attempt));
        continue;
      }
      throw new Error(`vlm_solblocks_fetch_error: ${String(err?.message || err).slice(0, 200)}`);
    } finally {
      clearTimeout(timer);
    }
    const textBody = await res.text();
    if (!res.ok) {
      lastStatus = res.status;
      lastBody = textBody;
      if (TRANSIENT_STATUSES.has(res.status) && attempt + 1 < attempts) {
        await sleep(800 * Math.pow(2, attempt));
        continue;
      }
      throw new Error(
        `vlm_solblocks_http_${res.status}: ${String(textBody).slice(0, 300)}`,
      );
    }
    let payload;
    try {
      payload = JSON.parse(textBody);
    } catch (_) {
      throw new Error(`vlm_solblocks_non_json: ${String(textBody).slice(0, 300)}`);
    }
    const candidate = (payload?.candidates || [])[0];
    const parsedJson = parseTextbookVlmJson(
      joinGeminiTextParts(candidate?.content?.parts),
    );
    if (!parsedJson) throw new Error('vlm_solblocks_parse_failed');
    return { parsedJson, usageMetadata: payload?.usageMetadata || null };
  }
  throw new Error(
    `vlm_solblocks_exhausted: status=${lastStatus} body=${String(lastBody).slice(0, 200)}`,
  );
}

function parseBbox4(value) {
  if (!Array.isArray(value) || value.length !== 4) return null;
  const nums = value.map((v) => Number(v));
  if (nums.some((n) => !Number.isFinite(n))) return null;
  const [ymin, xmin, ymax, xmax] = nums.map((n) =>
    Math.max(0, Math.min(1000, Math.round(n))),
  );
  if (ymax <= ymin || xmax <= xmin) return null;
  return [ymin, xmin, ymax, xmax];
}

/// 지면 요소를 단(column) 별로 묶는다.
///
/// 해설은 2~3단 편집이고 번호는 각 단 왼쪽에 세로로 줄을 맞춰 찍힌다. 그래서
/// 왼쪽 x 좌표가 비슷한 것끼리 묶으면 단이 갈린다. 읽는 차례는 "단 왼쪽부터,
/// 단 안에서는 위에서 아래로" 이므로 이 묶음이 곧 차례가 된다.
function assignColumns(entries) {
  // 수력충전 해설은 항상 좌/우 2단이다. 소단원 첫 지면에는 왼쪽 단 안에서
  // 빠른 정답표가 2개의 작은 열로 놓이기도 한다. 작은 열을 별도 단으로
  // 취급하면 01,03,05... 뒤에 02,04,06...이 와서 중간 소단원 머리를
  // 잘못 통과한다. 페이지 중앙(500)을 기준으로 큰 2단만 나눈다.
  const leftXs = entries
    .map((e) => e.region[1])
    .filter((x) => x < 500);
  const left = leftXs.length ? Math.min(...leftXs) : 0;
  const bounds = [left, 500];
  for (const entry of entries) {
    entry.column = entry.region[1] < 500 ? 0 : 1;
  }
  return bounds;
}

export function normalizeSolutionBlocksResult(parsedJson) {
  const out = {
    leading_continuation: false,
    blocks: [],
    numbers: [],
    sequence: [],
  };
  if (!parsedJson || typeof parsedJson !== 'object') return out;
  out.leading_continuation = parsedJson.leading_continuation === true;

  const entries = [];
  const rawBlocks = Array.isArray(parsedJson.blocks) ? parsedJson.blocks : [];
  for (const one of rawBlocks) {
    if (!one || typeof one !== 'object') continue;
    const title = String(one.title ?? '').trim();
    const start = Number.parseInt(String(one.page_start ?? ''), 10);
    const end = Number.parseInt(String(one.page_end ?? ''), 10);
    if (!title && !Number.isFinite(start)) continue;
    const block = {
      title,
      page_start: Number.isFinite(start) && start > 0 ? start : 0,
      page_end: Number.isFinite(end) && end > 0 ? end : 0,
      header_region: parseBbox4(one.header_region),
    };
    out.blocks.push(block);
    if (block.header_region) {
      entries.push({ kind: 'header', block, region: block.header_region });
    }
  }

  const rawNumbers = Array.isArray(parsedJson.numbers) ? parsedJson.numbers : [];
  for (const one of rawNumbers) {
    if (!one || typeof one !== 'object') continue;
    const text = String(one.text ?? one.problem_number ?? '').trim();
    const region = parseBbox4(one.number_region);
    if (!text || !region) continue;
    const number = { text, number_region: region, content_region: null };
    out.numbers.push(number);
    entries.push({ kind: 'number', number, region });
  }

  if (!entries.length) {
    if (!out.blocks.length) out.leading_continuation = true;
    return out;
  }

  const bounds = assignColumns(entries);
  entries.sort((a, b) => a.column - b.column || a.region[0] - b.region[0]);

  // 풀이 영역은 그 번호부터 같은 단의 다음 요소 바로 위까지다. 모델에게 묻지
  // 않고 좌표로 자른다 — 번호 위치만 정확하면 영역은 계산으로 정해진다.
  for (let i = 0; i < entries.length; i += 1) {
    const entry = entries[i];
    if (entry.kind !== 'number') continue;
    const next = entries[i + 1];
    const sameColumn = next && next.column === entry.column;
    const bottom = sameColumn ? Math.max(entry.region[2], next.region[0] - 2) : 990;
    const left = Math.max(0, bounds[entry.column] - 5);
    const right =
      entry.column + 1 < bounds.length
        ? Math.max(left + 10, bounds[entry.column + 1] - 8)
        : 995;
    entry.number.content_region = [entry.region[0], left, bottom, right];
  }

  out.sequence = entries.map((entry) =>
    entry.kind === 'header'
      ? {
          kind: 'header',
          column: entry.column,
          title: entry.block.title,
          page_start: entry.block.page_start,
          page_end: entry.block.page_end,
          header_region: entry.block.header_region,
        }
      : {
          kind: 'number',
          column: entry.column,
          text: entry.number.text,
          number_region: entry.number.number_region,
          content_region: entry.number.content_region,
        },
  );

  // 지면에 머리가 하나도 없으면 통째로 이어지는 블록이다.
  if (!out.blocks.length) out.leading_continuation = true;
  return out;
}
