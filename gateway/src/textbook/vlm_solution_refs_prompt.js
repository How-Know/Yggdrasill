// 해설(풀이) PDF 한 페이지에서 "문항번호 위치(bbox)" 만 뽑아내는 Gemini Vision 프롬프트.
//
// 목적은 학생앱에서 "문항 N 번 해설 바로가기" 를 구현할 때 쓸 좌표를 저장하는 것.
// 본문 내용까지는 추출하지 않는다. 번호와 (가능하면) 그 번호가 덮고 있는 해설 블록 영역만.
//
// 입력: 해설 PDF 의 한 페이지를 래스터한 PNG
// 출력 규약: JSON only. 0..1000 정규화 [ymin, xmin, ymax, xmax].

export function buildDetectSolutionRefsPrompt({
  rawPage,
  displayPage,
  pageOffset,
  expectedNumbers,
}) {
  const pageLine =
    displayPage != null && Number.isFinite(displayPage)
      ? `이 이미지는 해설 PDF 의 **책면 기준 ${displayPage}페이지** (PDF raw page ${rawPage}, page_offset=${pageOffset}) 이다.`
      : `이 이미지는 해설 PDF 의 한 페이지 (PDF raw page ${rawPage}) 이다.`;

  const expected = Array.isArray(expectedNumbers)
    ? expectedNumbers
        .map((n) => String(n || '').trim())
        .filter((n) => n.length > 0)
    : [];
  const expectedBlock = expected.length
    ? [
        '=== 기대 문항번호 ===',
        '이 해설 PDF 에서는 아래 번호들의 해설 위치를 찾고 싶다. ',
        '각 번호가 이 페이지에 있으면 number_region 을 반드시 채워라. ',
        '이 페이지에 없다면 items 에 포함시키지 마라 (다른 페이지에서 잡을 것이다).',
        '',
        `기대 번호 목록 (${expected.length}개): ${expected.join(', ')}`,
      ]
    : [
        '=== 기대 문항번호 ===',
        '이 페이지에 보이는 모든 해설 문항번호를 items 로 수집하라.',
      ];

  return [
    '당신은 한국 중·고등 교재의 **해설(풀이) PDF 한 페이지**에서 "문항번호 위치" 만 탐지하는 비전 AI 입니다.',
    '반드시 아래 JSON 스키마만 출력하세요. 설명·마크다운·주석·코드펜스 모두 금지.',
    '',
    pageLine,
    '',
    ...expectedBlock,
    '',
    '=== 출력 스키마 ===',
    '{',
    '  "items": [',
    '    {',
    '      "problem_number": "<원문 그대로. 예: \\"0001\\", \\"12\\", \\"48~52\\">",',
    '      "number_region": [<ymin>, <xmin>, <ymax>, <xmax>],',
    '      "content_region": [<ymin>, <xmin>, <ymax>, <xmax>] | null',
    '    }',
    '  ],',
    '  "notes": "<특이사항 간단히, 없으면 빈 문자열>"',
    '}',
    '',
    '=== 탐지 규칙 ===',
    '[R1] 해설 PDF 의 각 블록 상단에는 "0001 · 2 · ③" 또는 "12 답 ③" 같은 형태로 문항번호가 나타난다.',
    '     그 번호가 차지하는 가장 작은 박스를 number_region 으로 잡아라.',
    '     number_region 은 번호 문자열만 감싼다 (옆에 찍힌 정답 표기는 포함시키지 마라).',
    '',
    '[R2] content_region 은 그 번호의 해설 본문(풀이 설명, 수식, 그림) 이 차지하는 전체 영역이다.',
    '     확신이 낮으면 null 로 둬도 된다 (학생앱은 number_region 만으로도 점프할 수 있음).',
    '',
    '[R3] 같은 페이지에 번호가 중복으로 보이면 더 확실한 하나만 남겨라.',
    '',
    '[R4] "풀이", "참고", "보충", "별해" 같은 헤더는 문항번호가 아니다. items 에 넣지 마라.',
    '     "① ② ③ ④ ⑤" 원문자와 그 옆에 적힌 정답 표기도 문항번호가 아니다.',
    '',
    '[R5] 세트형 해설(예: "48~52") 은 하나의 item 으로 기록하라. problem_number="48~52".',
    '     48, 49, ... 각 번호가 개별 블록으로 또 나오면 각각 별도 item 으로도 추가한다.',
    '     단, 기대 번호 목록에 없는 범위 라벨(예: "007~009") 은 세트형 라벨이므로 item 에 넣지 마라.',
    '',
    '[R6] items 는 위→아래, 좌단→우단 순으로 정렬하라.',
    '',
    '좌표계: 이미지 좌상단 (0,0), 우하단 (1000,1000). 순서는 [ymin, xmin, ymax, xmax].',
    '',
    '=== 절대 금지 ===',
    '[N1] 해설 본문 텍스트, 수식, 풀이 설명을 출력에 복사하지 마라. 이 프롬프트는 "번호 위치 탐지 전용" 이다.',
    '[N2] 없는 번호를 추측해서 만들지 마라.',
    '[N3] 마크다운, 코드펜스, 설명 문장을 출력에 포함시키지 마라. JSON only.',
    '',
    '지금 첨부된 이미지를 분석해 위 스키마로만 출력하라.',
  ].join('\n');
}
