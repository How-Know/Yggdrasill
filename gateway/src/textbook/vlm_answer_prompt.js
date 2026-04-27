// 답지 PDF 한 페이지에서 "문항별 정답" 만 뽑아내는 Gemini Vision 프롬프트.
//
// 입력: 답지 PDF 의 한 페이지를 래스터한 PNG
// 출력 규약: JSON only. 객관식은 원문자(①~⑤), 주관식은 LaTeX 한 줄.
// bbox 는 0..1000 정규화 [ymin, xmin, ymax, xmax].
//
// 이 프롬프트는 `vlm_detect_prompt.js` (문항번호 위치 탐지) 와 별개로 분리돼 있다.
// 답지는 "번호 + 정답값" 만 잔뜩 쌓인 콤팩트한 레이아웃이라 본문 탐지용 프롬프트를
// 그대로 쓰면 false-positive 가 많아진다. 그래서 전용 프롬프트로 분리.

export function buildExtractAnswersPrompt({
  rawPage,
  displayPage,
  pageOffset,
  expectedNumbers,
}) {
  const pageLine =
    displayPage != null && Number.isFinite(displayPage)
      ? `이 이미지는 답지(정답지) PDF 의 **책면 기준 ${displayPage}페이지** (PDF raw page ${rawPage}, page_offset=${pageOffset}) 이다.`
      : `이 이미지는 답지(정답지) PDF 의 한 페이지 (PDF raw page ${rawPage}) 이다.`;

  const expected = Array.isArray(expectedNumbers)
    ? expectedNumbers
        .map((n) => String(n || '').trim())
        .filter((n) => n.length > 0)
    : [];
  const expectedBlock = expected.length
    ? [
        '=== 기대 문항번호 (매우 중요) ===',
        '이 답지에서는 아래 문항번호들의 정답을 찾고 싶다. ',
        '단, 이 페이지 이미지에서 실제로 보이는 번호와 정답만 items 에 담아라. ',
        '이 페이지에 보이지 않는 기대 번호는 빈 item 으로 만들지 말고 완전히 생략하라.',
        '',
        `기대 번호 목록 (${expected.length}개): ${expected.join(', ')}`,
      ]
    : [
        '=== 기대 문항번호 ===',
        '이 페이지에서 보이는 모든 문항번호의 정답을 찾아 items 에 담아라.',
      ];

  return [
    '당신은 한국 중·고등 교재의 **답지 PDF 한 페이지**에서 "문항별 정답" 만 정확히 추출하는 비전 AI 입니다.',
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
    '      "kind": "objective" | "subjective" | "image",',
    '      "answer_text": "<객관식이면 ①~⑤ 중 하나. 주관식이면 사람이 읽는 정답 원문+수식 LaTeX. 그림 정답이면 \\"[image]\\". 찾지 못하면 빈 문자열>",',
    '      "answer_latex_2d": "<주관식일 때 2D 렌더에 쓸 LaTeX. 단순한 경우 answer_text 와 동일. 객관식/그림이면 빈 문자열>",',
    '      "bbox": [<ymin>, <xmin>, <ymax>, <xmax>] | null,',
    '      "answer_assets": [ { "marker": "[image]", "asset_type": "image" | "table" | "grid" | "graph", "bbox": [<ymin>, <xmin>, <ymax>, <xmax>] } ]',
    '    }',
    '  ],',
    '  "notes": "<특이사항 간단히, 없으면 빈 문자열>"',
    '}',
    '',
    '=== 추출 규칙 ===',
    '[R1] 객관식 정답 (kind="objective")',
    '   - 답지에 ①②③④⑤ 원문자 또는 1,2,3,4,5 같은 숫자·괄호 표기가 있으면 해당하는 원문자로 표준화한다.',
    '   - 표준화 매핑: 1/(1)/⑴ → "①", 2 → "②", 3 → "③", 4 → "④", 5 → "⑤".',
    '   - answer_text 는 **원문자 한 글자만** 담아라 (예: "③"). 답이 2개 이상이면 "③/④" 처럼 슬래시로 이어라.',
    '   - answer_latex_2d 는 "" (빈 문자열).',
    '',
    '[R2] 주관식 정답 (kind="subjective")',
    '   - 수식 그대로를 LaTeX 로 변환해 answer_text 에 담아라.',
    '     예: 분수 "3/4" → "\\\\frac{3}{4}", 루트 "√2" → "\\\\sqrt{2}", 지수 "a^2" → "a^{2}".',
    '   - 텍스트 답 ("해당없음", "풀이 참조", "밑", "지수" 등) 은 절대 \\\\text{...}, \\\\mathrm{...} 로 감싸지 말고 한글 원문 그대로 담아라.',
    '     예: "밑: 1/8, 지수: 3" → "밑: \\\\frac{1}{8}, 지수: 3". "\\\\text{밑: } \\\\frac{1}{8}" 같은 출력은 금지.',
    '   - 분수 명령은 반드시 중괄호 2개를 모두 써라. "\\\\frac18", "\\\\dfrac18", "\\\\frac1{8}" 같은 축약 문법은 금지.',
    '   - answer_latex_2d 에도 한글을 \\\\text{...} 로 감싸지 마라. 단순한 경우는 answer_text 와 동일하게 둔다.',
    '',
    '[R2-Image] 그림 정답 (kind="image")',
    '   - 정답이 텍스트/수식이 아니라 도형, 그래프, 그림, 표기 이미지 자체로 제시되면 kind="image" 로 둔다.',
    '   - 정답 일부에만 그림/표/격자/그래프가 포함되어도 반드시 kind="image" 로 둔다. 텍스트가 같이 보여도 subjective 로 낮추지 마라.',
    '     예: "(1)[image] (2) 34", "41 [image] 5개", "42 [image] 이므로 12".',
    '   - 표 정답은 절대 LaTeX tabular 로 재구성하지 말고 [image] 로 표시한 뒤 answer_assets 에 bbox 를 넣어라.',
    '   - answer_text 에는 텍스트 부분을 보존하되 그림 자리에는 "[image]" 를 넣는다.',
    '   - answer_latex_2d="" 로 둔다.',
    '   - bbox 는 첫 번째 [image] 에 해당하는 그림/표/격자 정답 전체를 타이트하게 감싼다. 텍스트와 그림이 한 덩어리이면 둘 다 포함해도 된다.',
    '   - answer_assets 는 각 [image] 자리마다 하나씩 만들고, bbox 는 해당 이미지 영역만 감싼다.',
    '',
    '[R3] 문항번호 매칭',
    '   - problem_number 는 답지에 찍혀 있는 원문 문자열을 그대로 써라. 앞자리 0 유지.',
    '   - 대표 문항번호 바로 뒤에 "(1)", "(2)" 같은 세트형 소문항 번호가 붙어 보이면 problem_number 에는 대표 번호만 넣고, 소문항 번호는 answer_text 로 옮겨라.',
    '     예: "0006 (1) [격자그림] (2) 34" → problem_number="0006", answer_text="(1) [image] (2) 34", kind="image".',
    '   - 답지의 "C 만점 도전하기", "C 만점마무리", "만점마무리", "만점", "서술형", "도전" 구간 정답도 반드시 포함한다.',
    '   - 기대 번호가 "0013" 처럼 0으로 시작해도 답지에 "13" 으로 보이면 같은 문항으로 보고 problem_number 는 기대 번호 형식에 최대한 맞춘다.',
    '   - 유형뽀개기 구간이 끝났다고 판단해도 뒤쪽의 고난도/만점 도전 문항 정답을 누락하지 마라.',
    '   - 세트형 공통문항(48~52 같은 범위 번호)은 기대 번호 목록에 없으면 절대 추가하지 마라.',
    '   - 기대 번호 목록이 주어졌다면, 그 목록의 번호 순서대로 items 를 정렬하라.',
    '     목록에 없는 번호가 답지에 추가로 보이면 그건 items 의 끝에 덧붙여라.',
    '',
    '[R4] 인식 불가',
    '   - 이미지가 번져 읽을 수 없지만 번호 위치는 보이면 answer_text="" 로 둬라.',
    '   - 해당 번호의 정답이 이 페이지에 없다고 판단되면 item 자체를 만들지 마라.',
    '   - notes 에 "문항 12 판독 불가" 처럼 짧게 남겨라.',
    '',
    '[R5] bbox',
    '   - 해당 정답 표기(원문자 또는 LaTeX 텍스트)가 차지하는 가장 작은 상자. 없으면 null.',
    '   - 좌표계: 이미지 좌상단 (0,0), 우하단 (1000,1000). [ymin, xmin, ymax, xmax] 순서.',
    '',
    '=== 절대 금지 ===',
    '[N1] 문항 본문, 풀이, 해설을 답처럼 복사해서 넣지 마라. 오직 "정답" 만 추출한다.',
    '[N2] 없는 답을 추측해서 만들지 마라. 보이지 않으면 answer_text="" 로 둔다.',
    '[N3] 마크다운, 코드펜스, 설명 문장을 출력에 포함시키지 마라. JSON only.',
    '',
    '지금 첨부된 이미지를 분석해 위 스키마로만 출력하라.',
  ].join('\n');
}
