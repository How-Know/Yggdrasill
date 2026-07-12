// 교재 PDF 스캔본에서 **페이지 단위로 문항번호를 탐지**하는 Gemini Vision 프롬프트.
//
// 입력: 한 페이지를 래스터한 PNG 이미지
// 출력 규약: JSON only. 문항 번호, 난이도 라벨(없을 수도 있음), 정규화된 bounding box.
// bbox 좌표계는 이미지 좌상단 (0,0) 기준, **0~1000 정규화** [ymin, xmin, ymax, xmax] 로 통일
// (Gemini 공식 문서의 spatial understanding 권장 포맷).
//
// 이 프롬프트는 문제은행용 `extract_engines/vlm/prompt.js` 와 분리되어 있다.
// 거기 것은 "문항 본문 구조화 추출용", 여기는 "문항 번호 위치 탐지 전용" 이다.
// 섞지 말 것.
//
// 사용자 규약 (2026-04 기준):
//   - 페이지 스캔 레이아웃은 대부분 **2단 구조** 이다.
//   - 한 단원은 세 파트로 구성된다 (시리즈별 이름은 SERIES_CONFIGS 참고):
//       [A] basic_drill   — 4자리 번호 0001~, 라벨 없음,
//                           번호 **오른쪽**에 본문이 바로 시작하는 짧은 문항.
//                           개념 설명 블록과 섞여 있을 수 있음.
//       [B] type_practice — 일반 번호 + 난이도/특수 라벨.
//                           번호 아래로 본문/선택지가 길게 이어짐.
//       [C] mastery       — B 와 동일 구조, 후반부 "서술형" (RPM 은 서술형 주관식 / 실력 UP) 구간.
//   - 문항번호 오른쪽(또는 아래)에 라벨이 달릴 수 있다 (시리즈별 집합은 config.labels).

// 쎈 라벨 집합.
const SSEN_LABELS = Object.freeze([
  '상',
  '중',
  '하',
  '대표 문제',
  '창의문제',
  '서술형',
  '교육청기출',
]);

// RPM 라벨 집합. 난이도 5단계(상/상중/중/중하/하) + 중요 + 대표 문제 + 서술형 + 실력(실력 UP 구간).
const RPM_LABELS = Object.freeze([
  '상',
  '상중',
  '중',
  '중하',
  '하',
  '중요',
  '대표 문제',
  '서술형',
  '실력',
]);

// 개념원리 라벨 집합.
//   필수  — B 필수유형 예제 표시.
//   STEP1/STEP2/실력 — D 연습문제의 3단계 구간 라벨 (실력 = "실력 UP").
//   수능기출/평가원기출/교육청기출 — 연습문제 하단 기출 구간 라벨.
const WONRI_LABELS = Object.freeze([
  '필수',
  'STEP1',
  'STEP2',
  '실력',
  '수능기출',
  '평가원기출',
  '교육청기출',
]);

// 시리즈 전체 라벨 합집합. normalizeDetectResult 의 허용 집합으로 사용한다
// (쎈 페이지에 상중/중요가 인쇄될 일이 없으므로 합집합이어도 오탐 위험은 낮다).
export const VLM_DETECT_LABELS = Object.freeze([
  ...new Set([...SSEN_LABELS, ...RPM_LABELS, ...WONRI_LABELS]),
]);

// 시리즈별 파트 이름/라벨/추가 규칙. key 는 textbook_metadata.payload.series 와 동일.
const SERIES_CONFIGS = Object.freeze({
  ssen: {
    key: 'ssen',
    bookName: '쎈',
    partA: '기본다잡기',
    partB: '유형뽀개기',
    partC: '만점도전하기',
    labels: SSEN_LABELS,
    labelRules: [
      '  - 한 문항 번호 옆에 "상/중/하" 와 "서술형" 이 함께 보이면 label 은 반드시 "서술형" 으로 둔다.',
      '  - "서술형" 은 풀이 형식 라벨이므로 난이도("상/중/하")보다 우선한다.',
      '  - "사고의 기술" 은 문항 라벨이 아니라 코너/기획명이다. label 에 넣지 말고 "" 로 둔다.',
    ],
    partCExtra: ['    - 중반 이후 라벨이 "서술형" 으로 바뀌는 구간이 있다.'],
  },
  rpm: {
    key: 'rpm',
    bookName: 'RPM',
    partA: '교과서문제 정복하기',
    partB: '유형 익히기',
    partC: '시험에 꼭 나오는 문제',
    labels: RPM_LABELS,
    labelRules: [
      '  - 난이도 라벨은 5단계다: "상", "상중", "중", "중하", "하". "상중"/"중하" 를 "상"+"중" 두 라벨로 쪼개지 마라.',
      '  - 고등수학 RPM 은 "상중하" 세 글자를 나란히 인쇄하고 그중 한 글자(또는 두 글자)만 강조(굵게/하이라이트)하는 방식을 쓴다.',
      '    이 경우 강조된 글자만 읽어 label 로 삼는다. 예: "상중하" 에서 "중" 만 강조 → label="중",',
      '    "상중" 두 글자가 강조 → label="상중". 강조 없이 세 글자가 모두 같은 스타일이면 label="" 로 둔다.',
      '  - "중요" 는 난이도가 아니라 중요 문항 표시다. 한 문항에는 난이도 또는 "중요" 중 하나만 인쇄된다.',
      '  - "서술형 주관식" 구간(아래 [C] 참고)의 문항은 label="서술형" 으로 둔다.',
      '  - "실력 UP" 구간(아래 [C] 참고)의 문항은 label="실력" 으로 둔다.',
      '  - 한 문항에 "서술형" 표기와 난이도가 함께 보이면 label 은 반드시 "서술형" 으로 둔다.',
    ],
    partCExtra: [
      '    - 이 파트의 마지막 페이지는 두 구간으로 나뉜다:',
      '      · 왼쪽 단에 "서술형 주관식" 헤더 → 그 아래 문항들은 모두 label="서술형".',
      '      · 오른쪽 단에 "실력 UP" 헤더 → 그 아래 문항들은 모두 label="실력".',
      '      "서술형 주관식", "실력 UP" 헤더 문구 자체는 문항이 아니다. items 에 넣지 마라.',
      '    - 헤더가 페이지 중간에서 시작하면 헤더 아래쪽 문항부터 해당 구간 라벨을 적용한다.',
    ],
  },
  // 개념원리(개념서). 쎈/RPM 프롬프트 본문(A/B/C 문제집 구조)을 그대로 쓸 수
  // 없어서 buildDetectProblemsPrompt 가 전용 빌더로 분기한다.
  wonri: {
    key: 'wonri',
    bookName: '개념원리',
    partA: '개념원리 익히기',
    partB: '필수유형',
    partC: '확인 체크',
    partD: '연습문제',
    labels: WONRI_LABELS,
    labelRules: [],
    partCExtra: [],
  },
});

export function resolveDetectSeriesConfig(series) {
  const key = String(series || '').trim().toLowerCase();
  return SERIES_CONFIGS[key] || SERIES_CONFIGS.ssen;
}

export const VLM_DETECT_SECTIONS = Object.freeze([
  'basic_drill',
  'type_practice',
  'mastery',
  // 개념원리 전용 섹션. sub_key A/B/C/D 슬롯과 1:1 대응한다.
  'concept_drill', // A 개념원리 익히기
  'type_example', // B 필수유형
  'check', // C 확인 체크
  'exercise', // D 연습문제 (STEP1/STEP2/실력 UP)
  'unknown',
]);

// 개념원리 소단원 슬롯(sub_key) → 탐지 섹션 매핑. 매니저앱 _sectionForSubKey 와
// 동일하게 유지할 것.
export const WONRI_SECTION_BY_SUB_KEY = Object.freeze({
  A: 'concept_drill',
  B: 'type_example',
  C: 'check',
  D: 'exercise',
});

export const VLM_DETECT_PAGE_KINDS = Object.freeze([
  'problem_page',
  'concept_page',
  'mixed',
  'unknown',
]);

export function buildDetectProblemsPrompt({
  displayPage,
  rawPage,
  includeContentGroups = true,
  expectedStartNumber = '',
  series = 'ssen',
  sectionHint = '',
}) {
  const cfg = resolveDetectSeriesConfig(series);
  if (cfg.key === 'wonri') {
    // 개념원리는 단일 패스: sectionHint 없이 페이지의 모든 카테고리 문항을
    // 한 번에 감지하고 문항마다 category 를 붙인다.
    return buildWonriDetectPrompt({ displayPage, rawPage });
  }
  const pageLine =
    displayPage != null && Number.isFinite(displayPage)
      ? `이 이미지는 교재(${cfg.bookName}) 스캔본의 ${displayPage}페이지이다. 이 값은 PDF raw page ${rawPage}와 동일한 입력 페이지 기준이다.`
      : `이 이미지는 교재(${cfg.bookName}) 스캔본의 한 페이지 (PDF raw page ${rawPage}) 이다.`;
  const expectedStart = normalizeExpectedStartNumber(expectedStartNumber);

  let lines = [
    '당신은 한국 중·고등 교재 스캔본에서 "문항 번호" 의 위치를 탐지하는 비전 AI 입니다.',
    '반드시 아래 JSON 스키마만 출력하세요. 설명·마크다운·주석·코드펜스 모두 금지.',
    '',
    pageLine,
    '',
    ...(expectedStart
      ? [
          '=== 번호 연속성 힌트 ===',
          `이전 단원/파트의 마지막 문항번호 정보에 따르면, 이번 A ${cfg.partA}에서 처음 보일 문항번호는 "${expectedStart}"일 가능성이 높다.`,
          `이 페이지가 이번 A ${cfg.partA}의 첫 문제 페이지라면 "${expectedStart}"부터 이어지는 4자리 번호를 특히 주의해서 찾아라.`,
          `다만 "${expectedStart}"가 실제로 보이지 않으면 절대 만들어내지 말고, 보이는 문항번호만 items에 넣은 뒤 notes에 "expected_start_missing:${expectedStart}"라고 적어라.`,
          '문항번호가 하나도 보이지 않는 개념/타이틀 페이지라면 기존 규칙대로 concept_page, items=[] 로 반환한다.',
          '',
        ]
      : []),
    '=== 책 구조 (매우 중요) ===',
    '이 교재의 한 단원은 세 파트로 구성된다. 파트마다 문항 스타일이 달라서,',
    `세 스타일을 **모두** 탐지해야 한다. 특히 [A] ${cfg.partA}는 현재까지 자주 누락되는 케이스다.`,
    '',
    `[A] ${cfg.partA} (section="basic_drill")`,
    '    - 번호 스타일: **4자리 굵은 오렌지/갈색 숫자** (예: 0001, 0002, 0123).',
    '    - 라벨이 **없다** (label="").',
    '    - 번호 **오른쪽에 본문이 바로 시작**한다. 문항 한 개의 세로 길이가 짧아',
    '      한 줄 ~ 몇 줄짜리가 보통이다. 세로로 쌓이는 게 아니라 "행" 처럼 보인다.',
    '    - 주변에 "개념", "핵심", "요약", "정리" 같은 개념 설명 박스가 섞여 있다.',
    '      설명 박스는 문항이 아니므로 items 에 넣지 마라.',
    '    - A 파트에는 문항이 전혀 없고 개념 설명만 있는 페이지도 있다.',
    '      이런 페이지는 반드시 page_kind="concept_page", items=[] 로 반환한다.',
    '      개념/예제/설명 박스를 문항처럼 억지로 감싸지 마라.',
    `    - "A ${cfg.partA}" 파트 제목만 있고 4자리 문항번호가 하나도 보이지 않는 시작/타이틀 페이지는`,
    '      반드시 concept_page 다. 파트 제목이나 장식 숫자를 보고 문항번호를 만들어내지 마라.',
    '    - A 파트의 문항번호는 반드시 연속된 4자리 숫자(예: 0905) 또는 4자리 범위(0905~0906)다.',
    '      "09-1", "개념 1", "예제 1", 축 눈금, 표 번호, 페이지 번호, 연도처럼 보이는 숫자는 문항번호가 아니다.',
    '    - A 안에는 "01-1 소수와 합성수", "01-2 소인수분해" 같은 소주제 라벨이 있다.',
    '      이 라벨은 문항을 묶는 기준이다. 문항마다 현재 속한 소주제 정보를 content_group_* 필드에 채워라.',
    '',
    `[B] ${cfg.partB} (section="type_practice")`,
    '    - 번호 스타일: 일반 숫자 (예: 1, 12, 48) 또는 A 파트에서 이어지는 4자리 연속 번호.',
    `    - 번호 옆에 라벨이 자주 붙는다: ${cfg.labels
      .filter((l) => l !== '서술형' && l !== '실력')
      .map((l) => `"${l}"`)
      .join(', ')}.`,
    '    - 번호 아래로 지문/보기/선택지(①~⑤) 가 세로로 길게 이어진다.',
    '    - B 안에는 "유형 01 소수와 합성수" 같은 유형명이 있다. 밑의 설명/예제 내용은 추출하지 말고,',
    '      문항마다 현재 속한 유형명만 content_group_* 필드에 채워라.',
    '',
    `[C] ${cfg.partC} (section="mastery")`,
    '    - 구조는 B 와 동일.',
    ...cfg.partCExtra,
    '',
    `페이지 상단에 "${cfg.partA}", "${cfg.partB}", "${cfg.partC}" 같은 파트 제목이 보이면`,
    'section 필드를 그에 맞게 설정하라. 한 페이지에 파트가 섞여 있으면',
    '다수 문항이 속한 파트를 section 으로 고르고, notes 에 "파트 전환 페이지" 라고 남겨라.',
    '',
    '=== 출력 스키마 ===',
    '{',
    '  "section": "basic_drill" | "type_practice" | "mastery" | "unknown",',
    '  "page_kind": "problem_page" | "concept_page" | "mixed" | "unknown",',
    '  "page_layout": "two_column" | "one_column" | "unknown",',
    '  "items": [',
    '    {',
    '      "number": "<문항번호 문자열. \\"0001\\" 같은 앞자리 0 포함 원문 그대로>",',
    '      "label": "<라벨, 아래 집합 중 하나. 없으면 빈 문자열 \\"\\">",',
    '      "is_set_header": <bool — 범위 표기(예: \\"48~52\\") 이면 true>,',
    '      "set_range": {"from": <int>, "to": <int>} | null,',
    '      "content_group": {',
    '        "kind": "basic_subtopic" | "type" | "none",',
    '        "label": "<예: \\"01-1\\" 또는 \\"유형 01\\", 없으면 빈 문자열>",',
    '        "title": "<예: \\"소수와 합성수\\", 없으면 빈 문자열>",',
    '        "order": <int> | null',
    '      },',
    '      "column": 1 | 2 | null,',
    '      "bbox": [<ymin>, <xmin>, <ymax>, <xmax>],',
    '      "item_region": [<ymin>, <xmin>, <ymax>, <xmax>]',
    '    }',
    '  ],',
    '  "notes": "<정확도에 영향을 주는 특이사항 간단히, 없으면 빈 문자열>"',
    '}',
    '',
    '=== 라벨 집합 ===',
    cfg.labels.map((l) => `  - "${l}"`).join('\n'),
    '  - 위 라벨 중 어느 것도 아니거나 라벨이 아예 없으면 "" (빈 문자열)',
    ...cfg.labelRules,
    '',
    '=== 탐지 규칙 ===',
    '[D0] [A]/[B]/[C] 세 스타일의 문항을 **모두** 수집하라.',
    `     - 라벨 없는 4자리 번호(0001~) 는 ${cfg.partA} 문항이다. 라벨이 없고 번호 옆에 본문이 바로 온다는 이유로 절대 제외하지 마라.`,
    '     - number 에는 원문 그대로 써라. "0001" 은 "0001" 이지 "1" 이 아니다.',
    '     - 번호 글자 색은 검정, 오렌지, 갈색, 파랑 등 다양할 수 있다. 색만으로 필터링하지 마라.',
    `[D0-Concept] A ${cfg.partA} 중 **개념 설명만 있는 페이지**는 문항 페이지가 아니다.`,
    '     - 4자리 문항번호(0001 등) 또는 B/C식 문항번호가 실제로 보이지 않으면 items=[] 로 둔다.',
    '     - page_kind="concept_page" 로 설정하고 notes 에 "concept_page" 를 포함한다.',
    '     - "개념", "핵심", "예제", "정리", 번호 없는 설명 박스, 페이지 장식, 표/그림만 있는 블록은 절대 item_region 으로 만들지 마라.',
    '     - 문항번호 없이 본문처럼 보이는 텍스트가 있어도 추측해서 문항을 만들지 마라.',
    '     - A 페이지에서 "09-1" 같은 소주제 번호만 있고 4자리 문항번호가 없다면 반드시 concept_page 다.',
    '[D1] 본문 안의 "(1), (2)" 같은 소문항 레이블, "①~⑤" 같은 선택지 기호, "풀이/해설/정답" 같은 섹션 헤더는 문항 번호가 아니다. items 에 넣지 마라.',
    '[D1-Group] content_group 규칙:',
    `     - A ${cfg.partA}: 가장 최근 위쪽/같은 영역에 보이는 "01-1 제목" 라벨을 적용한다.`,
    '       kind="basic_subtopic", label="01-1", title="소수와 합성수", order=1 처럼 채운다.',
    `     - B ${cfg.partB}: 가장 최근 위쪽/같은 영역에 보이는 "유형 01 제목" 라벨을 적용한다.`,
    '       kind="type", label="유형 01", title="소수와 합성수", order=1 처럼 채운다.',
    `     - C ${cfg.partC} 또는 라벨을 못 찾은 경우: kind="none", label="", title="", order=null.`,
    '     - 유형명/소주제명 아래의 설명 문장이나 예제 본문은 content_group_title 에 넣지 마라. 제목 한 줄만 사용한다.',
    '[D2] 페이지 번호(쪽 번호) 는 문항 번호가 아니다. 페이지 번호는 페이지 하단/상단에 단독으로 위치한다. 넣지 마라.',
    '     - 4자리여도 페이지 번호처럼 모서리에 혼자 있고 주변에 본문이 없으면 제외.',
    '[D3] 세트형 도입(예: "48~52 다음 물음에 답하시오") 은 하나의 item 으로 기록한다.',
    '     - number = "48~52" 같은 원문 문자열',
    '     - is_set_header = true',
    '     - set_range = {"from": 48, "to": 52}',
    '     - 이 세트에 속하는 48, 49, 50, 51, 52 번호가 개별적으로 인쇄돼 있으면 각각 별도 item 으로 추가한다 (is_set_header=false).',
    '[D4] 레이아웃이 2단이면 column 은 좌측단 = 1, 우측단 = 2. 1단이거나 판단 불가이면 null.',
    '[D5] bbox 는 "문항번호 숫자 및 바로 옆 라벨까지만" 감싸는 최소 박스. 해당 문항의 본문 전체를 감싸지 마라.',
    '     좌표계: 이미지 좌상단 (0,0), 우하단 (1000,1000). 순서는 [ymin, xmin, ymax, xmax].',
    '[D6] item_region 은 "이 문항의 **본문 영역만** 타이트하게 감싸는 박스" 다.',
    '     이 박스는 그대로 **크롭 이미지로 잘라 저장**되므로, 본문이 아닌 것은 어떤 것도 들어가서는 안 된다.',
    '     **포함 대상 (문항 본문 자체만)**:',
    '       - 지문(stem), <보기>/조건 박스, 그림·표, 선택지(①~⑤), 배점 표기, 소문항 "(1)/(2)..." 같은 서브 라벨.',
    '     **반드시 제외 (가장 중요, 이걸 어기면 크롭이 쓸모없어진다)**:',
    '       - 문항번호 그 자체 (예: "0077", "1", "48") → bbox 에만 담고 item_region 에는 담지 마라.',
    `       - 라벨 아이콘/글자 (${cfg.labels.map((l) => `"${l}"`).join(',')}) → 번호 옆에 딸린 장식이므로 제외.`,
    '       - 이웃 문항의 내용, 페이지 머리말·쪽번호·섹션 제목·개념 설명 박스·광고성 QR 등.',
    '     **경계 잡는 법**:',
    `       - [A ${cfg.partA}] (번호가 왼쪽, 본문이 오른쪽인 가로 띠 스타일):`,
    '           · xmin 은 **번호(와 라벨)의 오른쪽 끝 직후**로 둔다. 번호 오른쪽의 빈 공백도 포함하지 마라.',
    '           · ymin/ymax 는 본문 첫 줄 위/마지막 줄 아래에 딱 맞춘다.',
    `       - [B ${cfg.partB}] / [C ${cfg.partC}] (번호가 위, 본문이 아래로 이어지는 세로 스타일):`,
    '           · ymin 은 **번호(와 라벨)의 아래 끝 직후**로 둔다. 번호 블록을 위쪽에 품지 마라.',
    '           · xmin/xmax 는 본문이 차지하는 단(column) 의 좌우 끝.',
    '       - 하단/우측 경계는 본문 마지막 글자 또는 도형이 끝나는 바로 다음까지만. 다음 문항 직전까지의 빈 흰 공간은 포함하지 마라.',
    '     **여백**: 각 변마다 0..1000 스케일 기준 **6~12 정도의 아주 작은 여백**만 둔다. 글자·도형이 잘리지 않을 만큼만.',
    '     **겹침 금지**: 두 문항의 item_region 은 원칙적으로 서로 겹치지 않아야 한다.',
    '     **세트형**: is_set_header=true 의 item_region 은 "48~52 다음 물음에 답하시오" 본문 문구만 감싸는 작은 박스.',
    '     좌표계/순서는 bbox 와 동일 ([ymin, xmin, ymax, xmax], 0..1000).',
    '[D7] 문항번호가 잘려 있거나 흐릿해 판독이 불확실하면 그래도 items 에 포함하되, notes 에 짧게 "숫자 N 번 판독 불확실" 처럼 기록한다.',
    '[D8] 같은 번호가 중복되면 더 신뢰도 높은 것 하나만 남겨라.',
    '[D9] items 는 위→아래, 좌단→우단 순으로 정렬하라.',
    '[D10] page_kind 규칙:',
    '     - 문항만 있으면 "problem_page".',
    '     - 문항 없이 개념/설명만 있으면 "concept_page" + items=[].',
    '     - 개념 설명과 문항이 함께 있으면 "mixed" (items에는 문항만).',
    '',
    '=== 절대 금지 ===',
    '[N1] stem, choices, answer, figures 등 다른 필드를 만들지 마라. 이 프롬프트는 "번호 위치 탐지 전용" 이다.',
    '[N2] 없는 문항을 추측해서 만들지 마라. 보이는 것만 담는다.',
    '',
    '지금 첨부된 이미지를 분석해 위 스키마로만 출력하라.',
  ];
  if (!includeContentGroups) {
    let skippingContentGroupSchema = false;
    lines = lines.filter((line) => {
      const text = String(line || '');
      if (text.includes('"content_group": {')) {
        skippingContentGroupSchema = true;
        return false;
      }
      if (skippingContentGroupSchema) {
        if (text.trim() === '},') {
          skippingContentGroupSchema = false;
        }
        return false;
      }
      if (text.includes('content_group')) return false;
      if (text.includes('01-1 소수와 합성수')) return false;
      if (text.includes('유형 01 소수와 합성수')) return false;
      if (text.startsWith('[D1-Group]')) return false;
      if (text.includes('kind="basic_subtopic"')) return false;
      if (text.includes('kind="type"')) return false;
      if (text.includes('또는 라벨을 못 찾은 경우')) {
        return false;
      }
      if (text.includes('유형명/소주제명 아래의 설명')) return false;
      return true;
    });
    lines.splice(
      lines.indexOf('[D1] 본문 안의 "(1), (2)" 같은 소문항 레이블, "①~⑤" 같은 선택지 기호, "풀이/해설/정답" 같은 섹션 헤더는 문항 번호가 아니다. items 에 넣지 마라.') + 1,
      0,
      '[D1-Group] 문항 사이의 소주제/유형명은 이번 호출에서는 무시한다. 문항 번호와 item_region 정확도를 최우선으로 한다.',
    );
  }
  return lines.join('\n');
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

// ─────────────────────────────────────────────────────────────────────────
// 개념원리(wonri) 전용 프롬프트 — **단일 패스**.
//
// 쎈/RPM 은 파트(A/B/C)마다 페이지 범위가 분리돼 있어 호출을 파트별로 나누지만,
// 개념원리는 한 소단원 페이지 안에 개념/익히기/필수유형/확인체크(/연습문제)가
// 섞여서 순서대로 나온다. 그래서 같은 페이지를 카테고리별로 여러 번 읽지 않고
// **한 번의 호출로 페이지의 모든 문항을 감지하면서 문항마다 category 를 붙인다**.
//
// 카테고리 (sub_key A~D 슬롯과 1:1):
//   concept_drill — A 개념원리 익히기
//   type_example  — B 필수유형 (본문에 "풀이" 단락 포함, label="필수")
//   check         — C 확인 체크 (유형 페이지 하단, 특강 하단에도 등장)
//   exercise      — D 연습문제 (STEP1/STEP2/실력 UP)
//
// 문항 번호는 카테고리별로 1번부터 책 전체에 걸쳐 이어진다. 카테고리만
// 정확하면 정답/해설 매칭은 기존 쎈 흐름 그대로 동작한다.
// ─────────────────────────────────────────────────────────────────────────

export const WONRI_ITEM_CATEGORIES = Object.freeze([
  'concept_drill',
  'type_example',
  'check',
  'exercise',
]);

function buildWonriDetectPrompt({ displayPage, rawPage }) {
  const pageLine =
    displayPage != null && Number.isFinite(displayPage)
      ? `이 이미지는 교재(개념원리) 스캔본의 ${displayPage}페이지이다. 이 값은 PDF raw page ${rawPage}와 동일한 입력 페이지 기준이다.`
      : `이 이미지는 교재(개념원리) 스캔본의 한 페이지 (PDF raw page ${rawPage}) 이다.`;

  const lines = [
    '당신은 한국 중·고등 교재 스캔본에서 "문항 번호" 의 위치를 탐지하는 비전 AI 입니다.',
    '반드시 아래 JSON 스키마만 출력하세요. 설명·마크다운·주석·코드펜스 모두 금지.',
    '',
    pageLine,
    '',
    '=== 책 구조 (매우 중요) ===',
    '개념원리(개념서)의 페이지 유형은 다섯 가지다. 한 페이지에 여러 카테고리의',
    '문항이 섞여 있을 수 있으므로, 보이는 문항을 **모두** 수집하고 문항마다',
    'category 필드로 어느 카테고리인지 표시하라.',
    '',
    '  (1) 개념 페이지 — 왼쪽 상단에 "개념원리 이해" 라벨. 개념 설명만 있고 문항 없음.',
    '      → page_kind="concept_page", items=[].',
    '  (2) 개념원리 익히기 — 왼쪽 상단에 "개념원리 익히기" 라벨. 일반 숫자 번호',
    '      (예: 1, 12, 37 — 책 전체 연속 번호)가 붙은 연습 문항이 나열된다.',
    '      → 각 문항 category="concept_drill", label="".',
    '  (3) 유형 페이지 — 상단(또는 중간)에 "필수" 배지와 함께 "필수유형 01 …" 처럼',
    '      유형 번호·제목이 인쇄된 필수유형 예제가 있고, 그 아래 "풀이" 단락이 이어진다.',
    '      같은 페이지 하단에는 "확인 체크" 헤더와 함께 확인 체크 문항들이 있다.',
    '      → 필수유형: category="type_example", number=유형 번호 원문 그대로(예: "01"),',
    '        label="필수". **유형 번호 오른쪽 같은 줄에 유형명(예: "이차방정식의 활용")이',
    '        인쇄돼 있다.** 이 유형명을 반드시 content_group.title 에 담아라',
    '        (kind="type", label="필수유형 01", title="그 유형명"). "풀이"·본문·예제·',
    '        보기 문장은 title 에 넣지 말고, 번호 옆 한 줄짜리 유형명만 넣어라.',
    '      → 확인 체크: category="check", label="", content_group kind="none".',
    '  (4) 연습문제 — "STEP1", "STEP2", "실력 UP" (표기 변형: STEP 1, 실력UP) 구간과,',
    '      그 뒤에 "수능 기출", "평가원 기출", "교육청 기출" 기출 구간이 올 수 있다.',
    '      번호는 구간을 건너 이어진다 (예: STEP1 1~10, STEP2 11~20).',
    '      → category="exercise", 구간 헤더에 따라 label 을 다음 중 하나로 둔다:',
    '        "STEP1" | "STEP2" | "실력"(=실력 UP) | "수능기출" | "평가원기출" | "교육청기출".',
    '        헤더가 페이지 중간에서 시작하면 헤더 아래 문항부터 해당 라벨을 적용한다.',
    '        이전 페이지에서 이어져 헤더가 안 보이면 label="" 로 두고 notes 에',
    '        "step_header_not_visible" 이라고 적어라.',
    '  (5) 특강 — 가끔 등장하는 심화 코너. 하단에 확인 체크 문항이 있을 수 있다.',
    '      → 특강 하단 확인 체크도 category="check" 로 수집한다.',
    '',
    '=== 출력 스키마 ===',
    '{',
    '  "section": "concept_drill" | "type_example" | "check" | "exercise" | "unknown",',
    '  "page_kind": "problem_page" | "concept_page" | "mixed" | "unknown",',
    '  "page_layout": "two_column" | "one_column" | "unknown",',
    '  "items": [',
    '    {',
    '      "number": "<문항번호 문자열. 원문 그대로>",',
    '      "category": "concept_drill" | "type_example" | "check" | "exercise",',
    '      "label": "<라벨. 없으면 빈 문자열 \\"\\">",',
    '      "is_set_header": <bool>,',
    '      "set_range": {"from": <int>, "to": <int>} | null,',
    '      "content_group": {',
    '        "kind": "type" | "none",',
    '        "label": "<예: \\"필수유형 01\\", 없으면 빈 문자열>",',
    '        "title": "<유형 제목, 없으면 빈 문자열>",',
    '        "order": <int> | null',
    '      },',
    '      "column": 1 | 2 | null,',
    '      "bbox": [<ymin>, <xmin>, <ymax>, <xmax>],',
    '      "item_region": [<ymin>, <xmin>, <ymax>, <xmax>]',
    '    }',
    '  ],',
    '  "notes": "<정확도에 영향을 주는 특이사항 간단히, 없으면 빈 문자열>"',
    '}',
    '',
    'section 은 이 페이지에서 문항 수가 가장 많은 카테고리 하나를 적는다.',
    '문항이 없으면 "unknown".',
    '',
    '=== 탐지 규칙 ===',
    '[D0] 페이지에 보이는 문항을 카테고리 구분 없이 **모두** items 에 담아라.',
    '     같은 페이지에 필수유형과 확인 체크가 함께 있으면 둘 다 수집한다.',
    '[D0-Cat] category 판단 기준:',
    '     - "개념원리 익히기" 라벨 구간의 문항 → "concept_drill".',
    '     - "필수" 배지가 붙은 유형 예제 → "type_example".',
    '     - "확인 체크" 헤더 아래 문항 → "check".',
    '     - STEP1/STEP2/실력 UP/수능·평가원·교육청 기출 구간 문항 → "exercise".',
    '[D1] 본문 안의 "(1), (2)" 같은 소문항 레이블, "①~⑤" 같은 선택지 기호,',
    '     "풀이/해설/정답" 같은 섹션 헤더는 문항 번호가 아니다. items 에 넣지 마라.',
    '     개념 설명 박스, "예제", "보기", 요약 표 등도 문항이 아니다.',
    '[D2] 페이지 번호(쪽 번호)는 문항 번호가 아니다. 넣지 마라.',
    '[D3] 레이아웃이 2단이면 column 은 좌측단 = 1, 우측단 = 2. 1단이거나 판단 불가이면 null.',
    '[D4] bbox 는 "문항번호 숫자 및 바로 옆 라벨까지만" 감싸는 최소 박스.',
    '     좌표계: 이미지 좌상단 (0,0), 우하단 (1000,1000). 순서는 [ymin, xmin, ymax, xmax].',
    '[D5] item_region 은 이 문항의 본문 영역만 타이트하게 감싸는 박스다.',
    '     그대로 크롭 이미지로 잘라 저장되므로 본문이 아닌 것은 어떤 것도 들어가면 안 된다.',
    '     - 문항 번호 자체는 bbox 에만 담고 item_region 에서 제외한다.',
    '     - **필수유형(type_example)**: item_region 은 문제 본문만 감싼다. 유형 제목 줄과',
    '       "풀이" 단락은 반드시 제외한다. 아래 경계는 "풀이" 글자가 시작되기 직전이다.',
    '     - "확인 체크" 헤더 문구, STEP1/STEP2/실력 UP 구간 헤더 문구는 제외한다.',
    '     - 이웃 문항의 내용, 페이지 머리말·쪽번호·섹션 제목·개념 설명 박스는 제외.',
    '     - 각 변마다 0..1000 스케일 기준 6~12 정도의 아주 작은 여백만 둔다.',
    '     - 두 문항의 item_region 은 원칙적으로 서로 겹치지 않아야 한다.',
    '[D6] 문항번호가 잘려 있거나 흐릿해 판독이 불확실하면 그래도 items 에 포함하되,',
    '     notes 에 짧게 "숫자 N 번 판독 불확실" 처럼 기록한다.',
    '[D7] 같은 번호가 중복되면 카테고리가 다르면 둘 다 유지하고, 같은 카테고리에서',
    '     중복이면 더 신뢰도 높은 것 하나만 남겨라.',
    '[D8] items 는 위→아래, 좌단→우단 순으로 정렬하라.',
    '[D9] page_kind 규칙:',
    '     - 문항이 하나라도 있으면 "problem_page" (개념 설명이 섞여 있으면 "mixed").',
    '     - 문항이 하나도 없으면 "concept_page" + items=[].',
    '',
    '=== 절대 금지 ===',
    '[N1] stem, choices, answer, figures 등 다른 필드를 만들지 마라. 이 프롬프트는 "번호 위치 탐지 전용" 이다.',
    '[N2] 없는 문항을 추측해서 만들지 마라. 보이는 것만 담는다.',
    '',
    '지금 첨부된 이미지를 분석해 위 스키마로만 출력하라.',
  ];
  return lines.join('\n');
}
