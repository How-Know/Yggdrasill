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
//   - 한 단원은 세 파트로 구성된다:
//       [A] 기본다잡기 (basic_drill)  — 4자리 번호 0001~, 라벨 없음,
//                                       번호 **오른쪽**에 본문이 바로 시작하는 짧은 문항.
//                                       개념 설명 블록과 섞여 있을 수 있음.
//       [B] 유형뽀개기 (type_practice) — 일반 번호 + 상/중/하/대표문제/창의문제 라벨.
//                                       번호 아래로 본문/선택지가 길게 이어짐.
//       [C] 만점도전하기 (mastery)    — B 와 동일 구조, 중반 이후 "서술형" 라벨 구간.
//   - 문항번호 오른쪽(또는 아래)에 라벨이 달릴 수 있다:
//       없음 | 상 | 중 | 하 | 대표문제 | 창의문제 | 서술형.

export const VLM_DETECT_LABELS = Object.freeze([
  '상',
  '중',
  '하',
  '대표문제',
  '창의문제',
  '서술형',
]);

export const VLM_DETECT_SECTIONS = Object.freeze([
  'basic_drill',
  'type_practice',
  'mastery',
  'unknown',
]);

export const VLM_DETECT_PAGE_KINDS = Object.freeze([
  'problem_page',
  'concept_page',
  'mixed',
  'unknown',
]);

export function buildDetectProblemsPrompt({
  displayPage,
  rawPage,
  pageOffset,
  includeContentGroups = true,
}) {
  const pageLine =
    displayPage != null && Number.isFinite(displayPage)
      ? `이 이미지는 **책면 기준 ${displayPage}페이지** (PDF raw page ${rawPage}, page_offset=${pageOffset}) 이다.`
      : `이 이미지는 교재 스캔본의 한 페이지 (PDF raw page ${rawPage}) 이다.`;

  let lines = [
    '당신은 한국 중·고등 교재 스캔본에서 "문항 번호" 의 위치를 탐지하는 비전 AI 입니다.',
    '반드시 아래 JSON 스키마만 출력하세요. 설명·마크다운·주석·코드펜스 모두 금지.',
    '',
    pageLine,
    '',
    '=== 책 구조 (매우 중요) ===',
    '이 교재의 한 단원은 세 파트로 구성된다. 파트마다 문항 스타일이 달라서,',
    '세 스타일을 **모두** 탐지해야 한다. 특히 [A] 기본다잡기는 현재까지 자주 누락되는 케이스다.',
    '',
    '[A] 기본다잡기 (section="basic_drill")',
    '    - 번호 스타일: **4자리 굵은 오렌지/갈색 숫자** (예: 0001, 0002, 0123).',
    '    - 라벨이 **없다** (label="").',
    '    - 번호 **오른쪽에 본문이 바로 시작**한다. 문항 한 개의 세로 길이가 짧아',
    '      한 줄 ~ 몇 줄짜리가 보통이다. 세로로 쌓이는 게 아니라 "행" 처럼 보인다.',
    '    - 주변에 "개념", "핵심", "요약", "정리" 같은 개념 설명 박스가 섞여 있다.',
    '      설명 박스는 문항이 아니므로 items 에 넣지 마라.',
    '    - A 파트에는 문항이 전혀 없고 개념 설명만 있는 페이지도 있다.',
    '      이런 페이지는 반드시 page_kind="concept_page", items=[] 로 반환한다.',
    '      개념/예제/설명 박스를 문항처럼 억지로 감싸지 마라.',
    '    - A 안에는 "01-1 소수와 합성수", "01-2 소인수분해" 같은 소주제 라벨이 있다.',
    '      이 라벨은 문항을 묶는 기준이다. 문항마다 현재 속한 소주제 정보를 content_group_* 필드에 채워라.',
    '',
    '[B] 유형뽀개기 (section="type_practice")',
    '    - 번호 스타일: 일반 숫자 (예: 1, 12, 48). 보통 1자리~3자리.',
    '    - 번호 옆에 라벨이 자주 붙는다: "상", "중", "하", "대표문제", "창의문제".',
    '    - 번호 아래로 지문/보기/선택지(①~⑤) 가 세로로 길게 이어진다.',
    '    - B 안에는 "유형 01 소수와 합성수" 같은 유형명이 있다. 밑의 설명/예제 내용은 추출하지 말고,',
    '      문항마다 현재 속한 유형명만 content_group_* 필드에 채워라.',
    '',
    '[C] 만점도전하기 (section="mastery")',
    '    - 구조는 B 와 동일.',
    '    - 중반 이후 라벨이 "서술형" 으로 바뀌는 구간이 있다.',
    '',
    '페이지 상단에 "기본다잡기", "유형뽀개기", "만점도전하기" 같은 파트 제목이 보이면',
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
    VLM_DETECT_LABELS.map((l) => `  - "${l}"`).join('\n'),
    '  - 위 6개 중 어느 것도 아니거나 라벨이 아예 없으면 "" (빈 문자열)',
    '',
    '=== 탐지 규칙 ===',
    '[D0] [A]/[B]/[C] 세 스타일의 문항을 **모두** 수집하라.',
    '     - 4자리 번호(0001~) 는 기본다잡기 문항이다. 라벨이 없고 번호 옆에 본문이 바로 온다는 이유로 절대 제외하지 마라.',
    '     - number 에는 원문 그대로 써라. "0001" 은 "0001" 이지 "1" 이 아니다.',
    '     - 번호 글자 색은 검정, 오렌지, 갈색, 파랑 등 다양할 수 있다. 색만으로 필터링하지 마라.',
    '[D0-Concept] A 기본다잡기 중 **개념 설명만 있는 페이지**는 문항 페이지가 아니다.',
    '     - 4자리 문항번호(0001 등) 또는 B/C식 문항번호가 실제로 보이지 않으면 items=[] 로 둔다.',
    '     - page_kind="concept_page" 로 설정하고 notes 에 "concept_page" 를 포함한다.',
    '     - "개념", "핵심", "예제", "정리", 번호 없는 설명 박스, 페이지 장식, 표/그림만 있는 블록은 절대 item_region 으로 만들지 마라.',
    '     - 문항번호 없이 본문처럼 보이는 텍스트가 있어도 추측해서 문항을 만들지 마라.',
    '[D1] 본문 안의 "(1), (2)" 같은 소문항 레이블, "①~⑤" 같은 선택지 기호, "풀이/해설/정답" 같은 섹션 헤더는 문항 번호가 아니다. items 에 넣지 마라.',
    '[D1-Group] content_group 규칙:',
    '     - A 기본다잡기: 가장 최근 위쪽/같은 영역에 보이는 "01-1 제목" 라벨을 적용한다.',
    '       kind="basic_subtopic", label="01-1", title="소수와 합성수", order=1 처럼 채운다.',
    '     - B 유형뽀개기: 가장 최근 위쪽/같은 영역에 보이는 "유형 01 제목" 라벨을 적용한다.',
    '       kind="type", label="유형 01", title="소수와 합성수", order=1 처럼 채운다.',
    '     - C 만점도전하기 또는 라벨을 못 찾은 경우: kind="none", label="", title="", order=null.',
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
    '       - 라벨 아이콘/글자 ("상","중","하","대표문제","창의문제","서술형") → 번호 옆에 딸린 장식이므로 제외.',
    '       - 이웃 문항의 내용, 페이지 머리말·쪽번호·섹션 제목·개념 설명 박스·광고성 QR 등.',
    '     **경계 잡는 법**:',
    '       - [A 기본다잡기] (번호가 왼쪽, 본문이 오른쪽인 가로 띠 스타일):',
    '           · xmin 은 **번호(와 라벨)의 오른쪽 끝 직후**로 둔다. 번호 오른쪽의 빈 공백도 포함하지 마라.',
    '           · ymin/ymax 는 본문 첫 줄 위/마지막 줄 아래에 딱 맞춘다.',
    '       - [B 유형뽀개기] / [C 만점도전하기] (번호가 위, 본문이 아래로 이어지는 세로 스타일):',
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
      if (text.includes('C 만점도전하기 또는 라벨을 못 찾은 경우')) {
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
