// 중등 개념원리 해설 PDF 전용 통합 판독.
//
// 중등판에는 별도 빠른 정답 PDF가 없다. 해설 지면 한 번의 판독으로 정답,
// 번호 좌표, 전체 풀이 좌표, 서술형 단계·배점을 함께 얻는다.

import {
  joinGeminiTextParts,
  parseTextbookVlmJson,
} from './vlm_json_parse.js';

const TRANSIENT_STATUSES = new Set([429, 499, 500, 502, 503, 504]);
const DEFAULT_MAX_RETRIES = 3;
const CATEGORIES = new Set([
  'middle_concept_check',
  'middle_core_problem',
  'middle_exam_problem',
  'middle_unit_review',
  'middle_descriptive',
  'middle_calculation',
]);

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function normalizeExpectedEntries(expectedEntries) {
  return (Array.isArray(expectedEntries) ? expectedEntries : [])
    .map((entry, index) => {
      const number = String(
        entry?.problem_number ?? entry?.number ?? '',
      ).trim();
      const itemRole = String(entry?.item_role ?? '').trim();
      return {
        index,
        number,
        category: String(entry?.category ?? entry?.corner ?? '').trim(),
        itemRole,
        printedNumber:
          itemRole === 'follow_up'
            ? String(/\d+/.exec(number)?.[0] || number)
            : number,
        title: String(entry?.title ?? '').trim(),
        bodyPage: Number.parseInt(String(entry?.page ?? ''), 10),
      };
    })
    .filter((entry) => entry.number);
}

function expectedEntryLines(entries) {
  return entries.map((entry) => {
    const details = [
      `category=${entry.category || '-'}`,
      entry.itemRole ? `role=${entry.itemRole}` : '',
      entry.printedNumber !== entry.number
        ? `해설인쇄번호=${entry.printedNumber}`
        : '',
      entry.title ? `소단원=${entry.title}` : '',
      Number.isFinite(entry.bodyPage) ? `본문쪽=${entry.bodyPage}` : '',
    ]
      .filter(Boolean)
      .join(', ');
    return `  [${entry.index}] ${entry.number} (${details})`;
  });
}

export function buildWonriMiddleQuickAnswerPrompt({
  rawPage,
  displayPage,
  expectedEntries = [],
}) {
  const pageLine =
    displayPage != null && Number.isFinite(displayPage)
      ? `이 이미지는 중등 개념원리 해설 PDF의 ${displayPage}페이지다(PDF raw page ${rawPage}).`
      : `이 이미지는 중등 개념원리 해설 PDF의 한 페이지(PDF raw page ${rawPage})다.`;
  const entries = normalizeExpectedEntries(expectedEntries);
  return [
    '중등 개념원리 해설 PDF에서 **빠른 정답 박스의 번호와 정답만** 읽는다.',
    '반드시 JSON만 출력한다. 박스 아래의 상세 풀이에서는 아무것도 추출하지 마라.',
    pageLine,
    '',
    '=== 기대 문항 목록 ===',
    ...expectedEntryLines(entries),
    '',
    '=== 지면 구성 ===',
    '- 해설은 소단원 차례대로 개념원리 확인하기 → 핵심문제 익히기 →',
    '  (가끔 계산력 강화하기) → 이런 문제가 시험에 나온다 순으로 이어지고,',
    '  중단원 끝에서만 중단원 마무리하기 → 서술형 대비 문제가 나온다.',
    '- 같은 코너 박스는 소단원마다 하나씩이고 번호는 1부터 오름차순이다.',
    '- 기대 목록은 그 박스 하나에 대응한다. 한 박스만 찾아 위에서부터 읽어라.',
    '',
    '=== 빠른 정답 박스 판별 ===',
    '- 초록색 테두리 안에 코너명과 "본문 N~M쪽"이 있고, 번호와 짧은 답이',
    '  여러 줄로 촘촘하게 나열된 영역만 빠른 정답 박스다.',
    '- category와 실제 박스 제목은 다음처럼 정확히 대응한다.',
    '  middle_concept_check="개념원리 확인하기",',
    '  middle_core_problem="핵심문제 익히기",',
    '  middle_exam_problem="이런 문제가 시험에 나온다"이며, 장식형 머리말에서',
    '  앞부분이 생략되어 "시험에 나온다" 또는 "시험"만 보여도 같은 코너다.',
    '  middle_unit_review="중단원 마무리하기",',
    '  middle_descriptive="서술형 대비 문제",',
    '  middle_calculation="계산력 강화하기".',
    '- 기대 category와 박스 제목이 다르면 번호가 같아도 절대 매칭하지 마라.',
    '- 기대 목록의 본문쪽이 박스의 "본문 N~M쪽" 범위에 들어가지 않으면',
    '  다른 소단원의 동명 코너이므로 절대 매칭하지 마라.',
    '- 박스 아래에서 번호 뒤에 여러 줄의 설명·계산·식·그림이 이어지는 영역은',
    '  상세 해설이다. 번호와 답이 같아도 이번 결과에 절대 넣지 마라.',
    '- 핵심문제 확인 N은 "핵심문제 익히기" 박스의 인쇄번호 N과 짝짓는다.',
    '- 서술형 유제 N은 "서술형 대비 문제" 박스의 인쇄번호 N과 짝짓는다.',
    '- 매칭되면 problem_number는 기대 목록의 "확인 N"/"유제 N" 표기를',
    '  그대로 반환하고 expected_index도 채운다.',
    '',
    '=== 출력 스키마 ===',
    '{',
    '  "box": {',
    '    "title": "<정답을 읽어 온 박스에 인쇄된 코너명 그대로>",',
    '    "body_page_from": <박스 "본문 N~M쪽" 배지의 N>,',
    '    "body_page_to": <배지의 M. "본문 12쪽"처럼 한 쪽이면 N과 같은 값>',
    '  },',
    '  "items": [',
    '    {',
    '      "problem_number": "<기대 목록 표기 그대로>",',
    '      "category": "<middle_* category>",',
    '      "expected_index": <기대 목록 인덱스>,',
    '      "item_role": "standard" | "follow_up",',
    '      "answer_kind": "objective" | "subjective",',
    '      "answer_text": "<빠른 정답 박스의 최종 답만>",',
    '      "answer_latex_2d": "<2D LaTeX 또는 빈 문자열>",',
    '      "solution_kind": "answer_only",',
    '      "answer_region": [<ymin>,<xmin>,<ymax>,<xmax>],',
    '      "number_region": [<ymin>,<xmin>,<ymax>,<xmax>],',
    '      "content_region": [<answer_region과 같은 좌표>],',
    '      "rubric_steps": [],',
    '      "total_points": null',
    '    }',
    '  ],',
    '  "notes": ""',
    '}',
    '',
    'box는 items를 실제로 읽어 온 박스 하나를 그대로 적는다. 배지 숫자를',
    '기대 목록에 맞춰 고치지 마라. 읽은 박스의 숫자를 있는 그대로 적어야',
    '어느 소단원 박스를 봤는지 검증할 수 있다. 박스가 없으면 box=null,',
    'items=[]로 둔다.',
    '',
    'answer_region은 답 글자만, number_region은 같은 빠른 정답 줄의 번호만',
    '타이트하게 감싼다. 좌표는 [ymin,xmin,ymax,xmax], 0..1000 기준이다.',
    '콜론 바로 뒤 첫 값도 답의 일부다. 예: "소수: 5, 13, 67"에서 5를',
    '빠뜨리거나 "소수, 13, 67"로 바꾸지 말고 행 전체를 문자 그대로 읽어라.',
    '원문자 ①~⑤(객관식 번호)와 맨 숫자 1~5(값)는 서로 다른 답이다. 인쇄된',
    '모양 그대로 옮겨라. 이웃 줄이 원문자라고 해서 맨 숫자를 원문자로 바꾸지 마라.',
    '원문자 ①~⑤(객관식 번호)와 맨 숫자 1~5(값)는 서로 다른 답이다. 인쇄된',
    '모양 그대로 옮겨라. 이웃 줄이 원문자라고 해서 맨 숫자를 원문자로 바꾸지 마라.',
    '"풀이 참조"도 정상 정답 문자열로 보존한다. 보이지 않는 답은 추측하지 마라.',
  ].join('\n');
}

export function buildWonriMiddleDetailedSolutionPrompt({
  rawPage,
  displayPage,
  expectedEntries = [],
}) {
  const pageLine =
    displayPage != null && Number.isFinite(displayPage)
      ? `이 이미지는 중등 개념원리 해설 PDF의 ${displayPage}페이지다(PDF raw page ${rawPage}).`
      : `이 이미지는 중등 개념원리 해설 PDF의 한 페이지(PDF raw page ${rawPage})다.`;
  const entries = normalizeExpectedEntries(expectedEntries);
  return [
    '중등 개념원리 해설 PDF에서 **상세 해설의 문항번호와 풀이 영역만** 찾는다.',
    '반드시 JSON만 출력한다. 빠른 정답 박스의 번호·답은 절대 선택하지 마라.',
    pageLine,
    '',
    '=== 기대 문항 목록 ===',
    ...expectedEntryLines(entries),
    '',
    '=== 상세 해설 판별 ===',
    '- 초록 테두리 안에 번호와 짧은 답만 촘촘히 모인 빠른 정답 박스는 제외한다.',
    '- 박스 아래에서 초록색 문항번호 뒤에 여러 줄의 설명·계산·식·그림이',
    '  이어지는 블록만 상세 해설이다.',
    '- 상세 해설이 다음 페이지로 이어져 코너 제목이 반복되지 않아도, 앞 페이지',
    '  번호 다음의 연속 번호와 같은 조판이면 기대 코너를 유지한다.',
    '- category와 코너 제목의 대응은 다음과 같다.',
    '  middle_concept_check="개념원리 확인하기",',
    '  middle_core_problem="핵심문제 익히기",',
    '  middle_exam_problem="이런 문제가 시험에 나온다"이며, 장식형 머리말에서',
    '  "시험에 나온다" 또는 "시험"만 보여도 같은 코너다.',
    '  middle_unit_review="중단원 마무리하기",',
    '  middle_descriptive="서술형 대비 문제",',
    '  middle_calculation="계산력 강화하기".',
    '- 해설은 소단원 차례대로 개념원리 확인하기 → 핵심문제 익히기 →',
    '  (가끔 계산력 강화하기) → 이런 문제가 시험에 나온다 순이고, 중단원',
    '  끝에서만 중단원 마무리하기 → 서술형 대비 문제가 나온다.',
    '- 기대 목록은 코너 하나에 대응하며 번호는 오름차순이다.',
    '- 현재 지면에 제목/빠른 정답 박스가 보이면 그 제목과 다른 category의',
    '  번호를 절대 반환하지 마라. 번호가 같다는 이유로 다른 코너 풀이를',
    '  기대 category로 바꾸는 것은 금지한다.',
    '- 제목 없는 연속 풀이는 페이지 맨 위에서 첫 새 코너 제목 이전에 이어지는',
    '  블록에만 허용한다. 지면 중간·아래의 다른 코너 번호를 연속으로 보지 마라.',
    '- "본문 N~M쪽" 배지가 보이면 기대 목록의 본문쪽이 그 범위에 포함되는',
    '  문항만 매칭한다.',
    '- 한 페이지 아래쪽에서 다음 소단원의 빠른 정답 박스가 시작되면 그 박스는',
    '  제외하고, 그 아래에 실제 상세 풀이가 시작된 문항만 반환한다.',
    '- 핵심문제 확인 N과 서술형 유제 N은 상세 해설에 N으로만 인쇄된다.',
    '  매칭 후 problem_number에는 기대 목록 표기를 그대로 반환한다.',
    '',
    '=== 출력 스키마 ===',
    '{',
    '  "box": {',
    '    "title": "<풀이가 딸린 코너 박스에 인쇄된 코너명 그대로>",',
    '    "body_page_from": <그 박스 "본문 N~M쪽" 배지의 N>,',
    '    "body_page_to": <배지의 M. 한 쪽이면 N과 같은 값>',
    '  },',
    '  "items": [',
    '    {',
    '      "problem_number": "<기대 목록 표기 그대로>",',
    '      "category": "<middle_* category>",',
    '      "expected_index": <기대 목록 인덱스>,',
    '      "item_role": "standard" | "follow_up",',
    '      "answer_kind": "subjective",',
    '      "answer_text": "",',
    '      "answer_latex_2d": "",',
    '      "solution_kind": "full",',
    '      "answer_region": null,',
    '      "number_region": [<상세 해설 번호의 ymin,xmin,ymax,xmax>],',
    '      "content_region": [<번호부터 풀이 마지막까지의 영역>],',
    '      "rubric_steps": [],',
    '      "total_points": null',
    '    }',
    '  ],',
    '  "notes": ""',
    '}',
    '',
    'number_region은 빠른 정답 박스 번호가 아니라 상세 풀이 시작 번호만 감싼다.',
    'content_region은 다음 상세 문항번호 직전까지다. 좌표는 0..1000 기준이다.',
    'box는 이 풀이들이 속한 코너 박스의 배지를 읽은 그대로 적는다. 기대 목록에',
    '맞춰 숫자를 고치지 마라. 앞 지면에서 이어진 풀이라 이 지면에 배지가 없으면',
    'box=null로 둔다.',
  ].join('\n');
}

export function buildWonriMiddleSolutionPrompt({
  rawPage,
  displayPage,
  expectedEntries = [],
}) {
  const pageLine =
    displayPage != null && Number.isFinite(displayPage)
      ? `이 이미지는 중등 개념원리 해설 PDF의 ${displayPage}페이지다(PDF raw page ${rawPage}).`
      : `이 이미지는 중등 개념원리 해설 PDF의 한 페이지(PDF raw page ${rawPage})다.`;
  const entries = Array.isArray(expectedEntries)
    ? expectedEntries
        .map((entry, index) => ({
          index,
          number: String(entry?.problem_number ?? entry?.number ?? '').trim(),
          category: String(entry?.category ?? entry?.corner ?? '').trim(),
          itemRole: String(entry?.item_role ?? '').trim(),
          title: String(entry?.title ?? '').trim(),
          bodyPage: Number.parseInt(String(entry?.page ?? ''), 10),
        }))
        .filter((entry) => entry.number)
    : [];
  const entryLines = entries.map((entry) => {
    const printedNumber =
      entry.itemRole === 'follow_up'
        ? String(/\d+/.exec(entry.number)?.[0] || entry.number)
        : entry.number;
    const details = [
      `category=${entry.category || '-'}`,
      entry.itemRole ? `role=${entry.itemRole}` : '',
      printedNumber !== entry.number ? `해설인쇄번호=${printedNumber}` : '',
      entry.title ? `소단원=${entry.title}` : '',
      Number.isFinite(entry.bodyPage) ? `본문쪽=${entry.bodyPage}` : '',
    ]
      .filter(Boolean)
      .join(', ');
    return `  [${entry.index}] ${entry.number} (${details})`;
  });

  return [
    '당신은 한국 중등 수학 개념서 "개념원리"의 해설 PDF에서 정답과 풀이를',
    '동시에 추출하는 비전 AI다. 반드시 JSON만 출력하라.',
    '',
    pageLine,
    '',
    '=== 기대 문항 목록 ===',
    ...(entryLines.length > 0
      ? [
          ...entryLines,
          '목록은 매칭 후보일 뿐이다. 현재 지면에 번호/코너/소단원 근거가 실제로',
          '보이는 문항만 반환하라. 순서상 있을 법하다는 이유로 만들지 마라.',
        ]
      : ['현재 지면에 실제로 인쇄된 모든 해설 문항을 읽어라.']),
    '',
    '=== category 대응 ===',
    '- 개념원리 확인하기 → middle_concept_check',
    '- 핵심문제 익히기(대표 예제/확인) → middle_core_problem',
    '- 이런 문제가 시험에 나온다 → middle_exam_problem',
    '- 중단원 마무리하기 STEP 1~3 → middle_unit_review',
    '- 서술형 대비 문제 → middle_descriptive',
    '- 계산력 강화하기 → middle_calculation',
    '',
    '=== 출력 스키마 ===',
    '{',
    '  "items": [',
    '    {',
    '      "problem_number": "<해설에 인쇄된 문항번호>",',
    '      "category": "<위 middle_* category 또는 빈 문자열>",',
    '      "expected_index": <기대 목록의 대괄호 인덱스. 확정 못 하면 -1>,',
    '      "item_role": "standard" | "representative" | "follow_up" | "descriptive_example",',
    '      "answer_kind": "objective" | "subjective",',
    '      "answer_text": "<최종 정답만. 수식은 LaTeX>",',
    '      "answer_latex_2d": "<2D 렌더용 LaTeX. 불필요하면 빈 문자열>",',
    '      "solution_kind": "full" | "answer_only",',
    '      "answer_region": [<ymin>, <xmin>, <ymax>, <xmax>] | null,',
    '      "number_region": [<ymin>, <xmin>, <ymax>, <xmax>],',
    '      "content_region": [<ymin>, <xmin>, <ymax>, <xmax>],',
    '      "rubric_steps": [',
    '        {"step":<1부터>, "label":"<단계명>", "text":"<채점 기준/풀이>", "points":<배점 또는 null>}',
    '      ],',
    '      "total_points": <총 배점 또는 null>',
    '    }',
    '  ],',
    '  "notes": "<특이사항, 없으면 빈 문자열>"',
    '}',
    '',
    '=== 판독 규칙 ===',
    '[S1] number_region은 번호/코너 배지만 감싸는 최소 박스다.',
    '[S2] content_region은 해당 문항의 정답·풀이 전체를 감싼다. 다음 문항 번호',
    '     직전에서 끝내고 이웃 문항이나 머리말을 포함하지 마라.',
    '[S3] 풀이 없이 정답만 인쇄된 문항도 반드시 반환한다.',
    '     solution_kind="answer_only"로 두고 content_region은 answer_region과',
    '     같은 박스를 사용한다. 이것이 이 교재의 정상 fallback이다.',
    '[S4] 서술형의 예시 풀이, 단계별 풀이, 각 단계 배점은 rubric_steps에 보존한다.',
    '     배점이 인쇄되지 않은 단계의 points는 null이다. 총 배점은 보일 때만 적는다.',
    '[S5] (1)(2)는 한 문항의 하위문항이다. answer_text에 순서대로 함께 적고',
    '     별도 item으로 만들지 마라.',
    '[S6] 같은 번호가 여러 코너/소단원에 반복되면 category와 머리말을 함께',
    '     확인해 expected_index를 정한다. 근거가 약하면 -1로 둔다.',
    '[S7] role=follow_up인 "확인 N"은 "핵심문제 익히기" 해설의 N번,',
    '     "유제 N"은 "서술형 대비 문제" 해설의 N번이다. 해설에는 확인/유제',
    '     접두어가 생략된다. 매칭한 뒤 problem_number에는 기대 목록의 "확인 N"',
    '     또는 "유제 N" 표기를 그대로 반환한다.',
    '[S8] 대표 예제와 서술형 예시는 본문에서 처리한다. 기대 목록에 없으면 해설의',
    '     비슷한 번호를 대표 예제/예시 문항으로 억지 매칭하지 마라.',
    '[S9] 좌표계는 좌상단 (0,0), 우하단 (1000,1000),',
    '     [ymin, xmin, ymax, xmax] 순서다.',
    '[S10] 보이지 않는 문항·정답·배점을 추측하지 마라.',
    '',
    '지금 첨부된 이미지를 분석해 JSON만 출력하라.',
  ].join('\n');
}

export async function extractWonriMiddleSolutionsOnPage({
  imageBase64,
  mimeType = 'image/png',
  rawPage,
  displayPage,
  expectedEntries = [],
  mode = 'combined',
  model,
  apiKey,
  timeoutMs = 120000,
  maxRetries = DEFAULT_MAX_RETRIES,
}) {
  const key = String(apiKey || '').trim();
  if (!key) throw new Error('vlm_wonri_middle_solution_api_key_missing');
  const image = String(imageBase64 || '').trim();
  if (!image) throw new Error('vlm_wonri_middle_solution_image_empty');
  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/` +
    `${encodeURIComponent(model)}:generateContent?key=${encodeURIComponent(key)}`;
  const requestBody = {
    contents: [
      {
        role: 'user',
        parts: [
          { inline_data: { mime_type: mimeType, data: image } },
          {
            text:
              mode === 'answers'
                ? buildWonriMiddleQuickAnswerPrompt({
                    rawPage,
                    displayPage,
                    expectedEntries,
                  })
                : mode === 'solution_refs'
                  ? buildWonriMiddleDetailedSolutionPrompt({
                      rawPage,
                      displayPage,
                      expectedEntries,
                    })
                  : buildWonriMiddleSolutionPrompt({
                      rawPage,
                      displayPage,
                      expectedEntries,
                    }),
          },
        ],
      },
    ],
    generationConfig: {
      temperature: 0.1,
      responseMimeType: 'application/json',
      maxOutputTokens: 12288,
      thinkingConfig: { thinkingLevel: 'low' },
    },
  };

  const attempts = Math.max(1, Number(maxRetries) || 1);
  let lastErr = null;
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    const startedAt = Date.now();
    let response;
    try {
      response = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(requestBody),
        signal: controller.signal,
      });
    } catch (err) {
      lastErr = err;
      if (attempt + 1 < attempts) {
        await sleep(800 * Math.pow(2, attempt));
        continue;
      }
      throw new Error(
        `vlm_wonri_middle_solution_fetch_error: ${String(err?.message || err).slice(0, 300)}`,
      );
    } finally {
      clearTimeout(timer);
    }
    const elapsedMs = Date.now() - startedAt;
    const textBody = await response.text();
    if (!response.ok) {
      if (
        TRANSIENT_STATUSES.has(response.status) &&
        attempt + 1 < attempts
      ) {
        await sleep(800 * Math.pow(2, attempt));
        continue;
      }
      throw new Error(
        `vlm_wonri_middle_solution_http_${response.status}: ${textBody.slice(0, 500)}`,
      );
    }
    let payload;
    try {
      payload = JSON.parse(textBody);
    } catch (_) {
      throw new Error(
        `vlm_wonri_middle_solution_non_json_response: ${textBody.slice(0, 500)}`,
      );
    }
    const candidate = (payload?.candidates || [])[0];
    const modelText = joinGeminiTextParts(candidate?.content?.parts);
    const parsedJson = parseTextbookVlmJson(modelText);
    if (!parsedJson) {
      throw new Error(
        `vlm_wonri_middle_solution_parse_failed: finish=${candidate?.finishReason || '-'} text_head="${modelText.slice(0, 180)}"`,
      );
    }
    return {
      parsedJson,
      elapsedMs,
      usageMetadata: payload?.usageMetadata || null,
      finishReason: candidate?.finishReason || '',
      attempts: attempt + 1,
    };
  }
  throw new Error(
    `vlm_wonri_middle_solution_exhausted: lastErr=${String(lastErr?.message || lastErr).slice(0, 300)}`,
  );
}

function normalizeBox(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const from = Number.parseInt(
    String(raw.body_page_from ?? raw.from ?? ''),
    10,
  );
  const to = Number.parseInt(String(raw.body_page_to ?? raw.to ?? ''), 10);
  const title = String(raw.title || '').trim();
  const hasFrom = Number.isFinite(from) && from > 0;
  const hasTo = Number.isFinite(to) && to > 0;
  if (!hasFrom && !hasTo && !title) return null;
  return {
    title,
    body_page_from: hasFrom ? from : hasTo ? to : null,
    body_page_to: hasTo ? to : hasFrom ? from : null,
  };
}

/// 모델은 "기대 본문쪽과 다른 박스는 읽지 마라"는 조건을 지키지 않는다.
/// 소단원마다 같은 코너 박스가 같은 번호로 반복되므로, 다른 소단원 박스를
/// 그대로 읽어 남의 정답을 돌려주는 사고가 난다. 모델에게는 "어느 박스를
/// 읽었는지"만 받아 적게 하고, 그 박스가 기대 문항의 본문쪽을 덮는지는
/// 여기서 판정한다.
export function filterWonriMiddleItemsByBox({ items, box, expectedEntries }) {
  const list = Array.isArray(items) ? items : [];
  const from = box?.body_page_from;
  const to = box?.body_page_to;
  if (!Number.isFinite(from) || !Number.isFinite(to)) {
    return { items: list, dropped: 0, reason: '' };
  }
  const entries = normalizeExpectedEntries(expectedEntries);
  const expectedPages = entries
    .map((entry) => entry.bodyPage)
    .filter((page) => Number.isFinite(page));
  if (expectedPages.length === 0) {
    return { items: list, dropped: 0, reason: '' };
  }
  const inRange = (page) => page >= from && page <= to;
  if (!expectedPages.some(inRange)) {
    return {
      items: [],
      dropped: list.length,
      reason: `box_out_of_scope: 읽은 박스=본문 ${from}~${to}쪽, 기대=본문 ${Math.min(...expectedPages)}~${Math.max(...expectedPages)}쪽`,
    };
  }
  const kept = [];
  let dropped = 0;
  for (const item of list) {
    const entry = matchExpectedEntry(entries, item);
    if (entry && Number.isFinite(entry.bodyPage) && !inRange(entry.bodyPage)) {
      dropped += 1;
      continue;
    }
    kept.push(item);
  }
  return {
    items: kept,
    dropped,
    reason: dropped > 0 ? `item_out_of_box: 박스=본문 ${from}~${to}쪽` : '',
  };
}

function matchExpectedEntry(entries, item) {
  const index = Number.parseInt(String(item?.expected_index ?? '-1'), 10);
  if (Number.isFinite(index) && index >= 0 && index < entries.length) {
    return entries[index];
  }
  const key = String(/\d+/.exec(String(item?.problem_number || ''))?.[0] || '');
  if (!key) return null;
  const matched = entries.filter(
    (entry) => String(/\d+/.exec(entry.printedNumber)?.[0] || '') === key,
  );
  return matched.length === 1 ? matched[0] : null;
}

export function normalizeWonriMiddleSolutionResult(parsedJson) {
  const out = { items: [], notes: '', box: null };
  if (!parsedJson || typeof parsedJson !== 'object') return out;
  out.notes = String(parsedJson.notes || '').trim();
  out.box = normalizeBox(parsedJson.box);
  for (const raw of Array.isArray(parsedJson.items) ? parsedJson.items : []) {
    if (!raw || typeof raw !== 'object') continue;
    const problemNumber = String(
      raw.problem_number ?? raw.number ?? '',
    ).trim();
    if (!problemNumber) continue;
    const expectedIndex = Number.parseInt(
      String(raw.expected_index ?? '-1'),
      10,
    );
    const categoryRaw = String(raw.category || '').trim();
    const solutionKind =
      String(raw.solution_kind || '').trim() === 'answer_only'
        ? 'answer_only'
        : 'full';
    const answerRegion = parseBbox4(
      raw.answer_region ?? raw.answer_bbox ?? raw.answer_box,
    );
    const numberRegion = parseBbox4(
      raw.number_region ?? raw.number_bbox,
    );
    let contentRegion = parseBbox4(
      raw.content_region ?? raw.content_bbox,
    );
    if (!contentRegion && solutionKind === 'answer_only') {
      contentRegion = answerRegion || numberRegion;
    }
    if (!numberRegion || !contentRegion) continue;
    const rubricSteps = [];
    for (const [index, rawStep] of (
      Array.isArray(raw.rubric_steps) ? raw.rubric_steps : []
    ).entries()) {
      if (!rawStep || typeof rawStep !== 'object') continue;
      const stepParsed = Number.parseInt(String(rawStep.step ?? ''), 10);
      const pointsParsed = optionalFiniteNumber(rawStep.points);
      rubricSteps.push({
        step:
          Number.isFinite(stepParsed) && stepParsed > 0
            ? stepParsed
            : index + 1,
        label: String(rawStep.label || '').trim().slice(0, 300),
        text: String(rawStep.text || '').trim().slice(0, 4000),
        points: pointsParsed,
      });
    }
    const totalPoints = optionalFiniteNumber(raw.total_points);
    const answerKindRaw = String(raw.answer_kind || '').trim();
    const itemRoleRaw = String(raw.item_role || '').trim();
    out.items.push({
      problem_number: problemNumber,
      category: CATEGORIES.has(categoryRaw) ? categoryRaw : '',
      expected_index:
        Number.isFinite(expectedIndex) && expectedIndex >= 0
          ? expectedIndex
          : -1,
      item_role: [
        'standard',
        'representative',
        'follow_up',
        'descriptive_example',
      ].includes(itemRoleRaw)
        ? itemRoleRaw
        : 'standard',
      answer_kind: ['objective', 'subjective'].includes(answerKindRaw)
        ? answerKindRaw
        : 'subjective',
      answer_text: String(raw.answer_text || '').trim(),
      answer_latex_2d: String(raw.answer_latex_2d || '').trim(),
      solution_kind: solutionKind,
      answer_region: answerRegion,
      number_region: numberRegion,
      content_region: contentRegion,
      rubric_steps: rubricSteps,
      total_points: totalPoints,
    });
  }
  return out;
}

function optionalFiniteNumber(value) {
  if (value == null || String(value).trim() === '') return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function parseBbox4(value) {
  const raw =
    Array.isArray(value) &&
    value.length === 1 &&
    Array.isArray(value[0]) &&
    value[0].length === 4
      ? value[0]
      : value;
  if (!Array.isArray(raw) || raw.length !== 4) return null;
  const numbers = raw.map(Number);
  if (!numbers.every(Number.isFinite)) return null;
  const box = numbers.map((number) =>
    Math.max(0, Math.min(1000, Math.round(number))),
  );
  if (box[2] <= box[0] || box[3] <= box[1]) return null;
  return box;
}
