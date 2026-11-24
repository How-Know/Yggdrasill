import test from 'node:test';
import assert from 'node:assert/strict';

import { choiceNumberRegion, regionInside, validChoiceRegion } from '../src/mock_exam/choice_layout.js';
import { mockCurriculumCode, mockExamTitle, mockReviewCourseLabel } from '../src/mock_exam/mock_courses.js';
import { isSectionHeaderLine, planSolutionSegments } from '../src/mock_exam/solution_layout.js';
import { parsePgm, solutionEvidenceFrom } from '../src/mock_exam/solution_evidence.js';
import { mockReviewPending, syncMockExamPresetsForExam } from '../src/mock_exam/mock_preset.js';
import {
  mockExpectedSections,
  mockSectionPaper,
  mockSectionScope,
  prepareMockReview,
  prepareMockReviewIdentity,
  previewMockSolutionRefs,
  publishMockReview,
} from '../src/mock_exam/review_staging.js';

// ── 회차에서 정해지는 값 ───────────────────────────────────────────────────

test('mockReviewCourseLabel follows the course table', () => {
  const label = (grade, examMonth, section) => mockReviewCourseLabel({ grade, examMonth, section });
  assert.equal(label(3, 10, 'common'), '대수+미적분1');
  assert.equal(label(3, 10, 'probstats'), '확률과 통계');
  assert.equal(label(3, 6, 'calculus'), '미적분2');
  assert.equal(label(3, 6, 'geometry'), '기하');
  assert.equal(label(2, 3, 'common'), '공통수학1+공통수학2');
  assert.equal(label(2, 9, 'common'), '대수+미적분1');
  assert.equal(label(1, 3, 'common'), '1-1+1-2+2-1+2-2+3-1+3-2');
  assert.equal(label(1, 11, 'common'), '공통수학1+공통수학2');
  assert.equal(label(1, 6, 'calculus'), '');
  // 가형·나형은 시행 연도의 시험 범위를 따른다.
  const legacy = (examYear, section) => mockReviewCourseLabel({ grade: 3, examMonth: 11, section, examYear });
  assert.equal(legacy(2016, 'ga'), '대수+미적분1+미적분2+확률과 통계+기하');
  assert.equal(legacy(2019, 'na'), '공통수학2+대수+미적분1+미적분2+확률과 통계');
  assert.equal(legacy(2020, 'ga'), '대수+미적분1+미적분2+확률과 통계');
  assert.equal(legacy(2020, 'na'), '대수+미적분1+확률과 통계');
  assert.equal(legacy(undefined, 'ga'), '');
  assert.equal(mockReviewCourseLabel({ grade: 2, examMonth: 6, section: 'ga', examYear: 2019 }), '');
});

test('mockCurriculumCode switches by grade and year', () => {
  assert.equal(mockCurriculumCode(1, 2024), 'rev_2015');
  assert.equal(mockCurriculumCode(1, 2025), 'rev_2022');
  assert.equal(mockCurriculumCode(2, 2025), 'rev_2015');
  assert.equal(mockCurriculumCode(2, 2026), 'rev_2022');
  assert.equal(mockCurriculumCode(3, 2026), 'rev_2015');
  assert.equal(mockExamTitle({ exam_year: 2025, grade: 3, exam_month: 10, org: 'edu' }), '2025 고3 10월 교육청');
});

// ── 풀이 영역 ─────────────────────────────────────────────────────────────

test('isSectionHeaderLine finds elective headers only', () => {
  assert.equal(isSectionHeaderLine('[확률과 통계]'), true);
  assert.equal(isSectionHeaderLine('■ [선택: 미적분] 23. ④ 24. ③'), true);
  assert.equal(isSectionHeaderLine('【기하】'), true);
  assert.equal(isSectionHeaderLine('미적분 정답 및 해설'), true);
  assert.equal(isSectionHeaderLine('기하적으로 생각하면 두 점 사이의 거리는'), false);
  assert.equal(isSectionHeaderLine('미적분의 기본 정리에 의하여'), false);
  assert.equal(isSectionHeaderLine('23. [출제의도] 확률과 통계'), false);
  assert.equal(isSectionHeaderLine(''), false);
});

// ink: [{ page, region }] 잉크가 있는 상자, lines: [{ page, y, x, text }] 글자 줄
function fakeEvidence({ pageCount, ink = [], lines = [], hasText = true }) {
  const inkBounds = (page, region) => {
    let lo = Infinity;
    let hi = -Infinity;
    for (const b of ink) {
      if (b.page !== page) continue;
      const y0 = Math.max(b.region[0], region[0]);
      const y1 = Math.min(b.region[2], region[2]);
      if (Math.min(b.region[3], region[3]) <= Math.max(b.region[1], region[1]) || y1 <= y0) continue;
      lo = Math.min(lo, y0);
      hi = Math.max(hi, y1);
    }
    return Number.isFinite(lo) ? [lo, hi] : [];
  };
  return {
    pageCount,
    hasText,
    inkBounds,
    firstInk: (page, region) => inkBounds(page, region)[0] ?? null,
    lines: (page, region) =>
      lines
        .filter((l) => l.page === page && l.y >= region[0] && l.y <= region[2] && l.x >= region[1] && l.x <= region[3])
        .map((l) => ({ text: l.text, yMin: l.y, yMax: l.y + 8 })),
  };
}

// 두 단짜리 해설지: 왼쪽 단 번호 x=100, 오른쪽 단 번호 x=520
const block = (key, section, page, x, y, yEnd) => ({
  key,
  section,
  page,
  numberRegion: [y, x, y + 12, x + 14],
  contentRegion: [y, x, yEnd, x + 360],
});

const TWO_COLUMN_BLOCKS = [
  block('c1', 'common', 1, 100, 120, 590),
  block('c2', 'common', 1, 100, 600, 900),
  block('c3', 'common', 1, 520, 400, 900),
  block('e23', 'probstats', 2, 100, 500, 690),
  block('e24', 'probstats', 2, 100, 700, 820),
];
const TWO_COLUMN_EVIDENCE = () =>
  fakeEvidence({
    pageCount: 2,
    ink: [
      { page: 1, region: [120, 100, 590, 460] },
      { page: 1, region: [600, 100, 900, 460] },
      { page: 1, region: [115, 520, 380, 880] },
      { page: 1, region: [400, 520, 900, 880] },
      { page: 2, region: [112, 100, 280, 460] },
      { page: 2, region: [300, 100, 340, 460] },
      { page: 2, region: [500, 100, 690, 460] },
      { page: 2, region: [700, 100, 820, 460] },
    ],
    lines: [{ page: 2, y: 300, x: 110, text: '[확률과 통계]' }],
  });

test('planSolutionSegments continues a solution into the next column and stops at a section header', () => {
  const plan = planSolutionSegments({ blocks: TWO_COLUMN_BLOCKS, evidence: TWO_COLUMN_EVIDENCE() });
  assert.deepEqual(
    plan.columns.map((c) => [c.left, c.right]),
    [
      [94, 464],
      [514, 884],
    ],
  );
  assert.equal(plan.top, 108);
  assert.equal(plan.bottom, 904);
  const seg = (key) => plan.segments.get(key);
  // 같은 칸에 다음 번호가 있으면 그 위에서 끝난다.
  assert.deepEqual(seg('c1').contentRegion, [118, 94, 594, 464]);
  assert.deepEqual(seg('c1').continuations, []);
  // 칸의 마지막 풀이는 다음 칸 맨 위부터 그 칸 첫 번호 위까지 이어진다.
  assert.deepEqual(seg('c2').contentRegion, [598, 94, 904, 464]);
  assert.deepEqual(seg('c2').continuations, [{ rawPage: 1, region1k: [111, 514, 384, 884] }]);
  // 구간의 마지막 풀이는 다음 구간 머리 줄 위에서 끝난다.
  assert.deepEqual(seg('c3').continuations, [{ rawPage: 2, region1k: [108, 94, 284, 464] }]);
  assert.equal(seg('c3').headerCut, true);
  assert.deepEqual(seg('e23').contentRegion, [498, 94, 694, 464]);
  // 다음 칸이 비어 있으면 풀이는 거기서 끝난 것이다.
  assert.deepEqual(seg('e24').contentRegion, [698, 94, 824, 464]);
  assert.deepEqual(seg('e24').continuations, []);
  assert.deepEqual(plan.unchecked, []);
});

test('planSolutionSegments crosses a column that has no number', () => {
  const plan = planSolutionSegments({
    blocks: [
      block('a', 'common', 1, 100, 700, 900),
      block('b', 'common', 2, 100, 300, 900),
      block('c', 'common', 2, 520, 150, 900),
    ],
    evidence: fakeEvidence({
      pageCount: 2,
      ink: [
        { page: 1, region: [700, 100, 900, 460] },
        { page: 1, region: [144, 520, 900, 880] },
        { page: 2, region: [144, 100, 250, 460] },
        { page: 2, region: [300, 100, 900, 460] },
        { page: 2, region: [150, 520, 900, 880] },
      ],
    }),
  });
  assert.equal(plan.top, 140);
  assert.deepEqual(plan.segments.get('a').continuations, [
    { rawPage: 1, region1k: [140, 514, 904, 884] },
    { rawPage: 2, region1k: [140, 94, 254, 464] },
  ]);
  // 다음 칸 첫 번호가 단 맨 위에 있으면 이어진 부분이 없다.
  assert.deepEqual(plan.segments.get('b').continuations, []);
});

test('planSolutionSegments fills a column where no number starts between two known columns', () => {
  // 3단 해설지(2025 7월 미적분): 번호는 1단(x=105)과 3단(x=645)에서만 시작하고, 28번 풀이가 가운데 단을 통째로 지난다.
  const b = (key, page, x, y, yEnd) => ({
    key,
    section: 'calculus',
    page,
    numberRegion: [y, x, y + 12, x + 14],
    contentRegion: [y, x, yEnd, x + 247],
  });
  const plan = planSolutionSegments({
    blocks: [b('26', 1, 105, 100, 380), b('27', 1, 105, 388, 622), b('28', 1, 105, 633, 900), b('29', 1, 645, 718, 900)],
    evidence: fakeEvidence({
      pageCount: 1,
      ink: [
        { page: 1, region: [100, 105, 380, 352] },
        { page: 1, region: [388, 105, 622, 352] },
        { page: 1, region: [633, 105, 900, 352] },
        { page: 1, region: [100, 375, 900, 622] },
        { page: 1, region: [100, 645, 705, 892] },
        { page: 1, region: [718, 645, 900, 892] },
      ],
    }),
  });
  assert.deepEqual(
    plan.columns.map((c) => [c.left, c.right, c.inferred === true]),
    [
      [99, 356, false],
      [369, 626, true],
      [639, 896, false],
    ],
  );
  assert.deepEqual(plan.segments.get('28').continuations, [
    { rawPage: 1, region1k: [96, 369, 904, 626] },
    { rawPage: 1, region1k: [96, 639, 709, 896] },
  ]);
  // 두 단짜리 해설지(단 사이가 단 폭의 1.2배)는 채우지 않는다.
  assert.equal(planSolutionSegments({ blocks: TWO_COLUMN_BLOCKS, evidence: TWO_COLUMN_EVIDENCE() }).columns.length, 2);
});

test('planSolutionSegments adds an edge column where no number starts', () => {
  const b = (key, page, x, y, yEnd) => ({
    key,
    section: 'geometry',
    page,
    numberRegion: [y, x, y + 8, x + 16],
    contentRegion: [y, x, yEnd, x + 256],
  });
  // 3단 해설지(2026 10월 기하): 번호는 2단(x=372)과 3단(x=640)에서만 시작하고, 30번 풀이는 다음 쪽 1단에서 이어진다.
  const left = planSolutionSegments({
    blocks: [b('27', 3, 372, 643, 896), b('28', 3, 640, 175, 407), b('29', 3, 640, 415, 861), b('30', 3, 640, 869, 889)],
    evidence: fakeEvidence({
      pageCount: 4,
      ink: [
        { page: 3, region: [140, 104, 890, 360] },
        { page: 3, region: [643, 372, 896, 628] },
        { page: 3, region: [140, 640, 168, 896] },
        { page: 3, region: [175, 640, 407, 896] },
        { page: 3, region: [415, 640, 861, 896] },
        { page: 3, region: [869, 640, 889, 896] },
        { page: 4, region: [140, 104, 520, 360] },
      ],
    }),
  });
  assert.deepEqual(
    left.columns.map((c) => [c.left, c.right, c.inferred === true]),
    [
      [98, 364, true],
      [366, 632, false],
      [634, 900, false],
    ],
  );
  assert.deepEqual(left.segments.get('30').continuations, [{ rawPage: 4, region1k: [136, 98, 524, 364] }]);
  // 27번은 같은 쪽 3단 맨 위(28번 위)에서 이어진다: 전과 같다.
  assert.deepEqual(left.segments.get('27').continuations, [{ rawPage: 3, region1k: [136, 634, 172, 900] }]);

  // 3단 해설지(2026 7월 기하): 번호는 1단(x=104)과 2단(x=374)에서만 시작하고, 28번 풀이가 3단을 지나 다음 쪽으로 간다.
  const right = planSolutionSegments({
    blocks: [b('27', 5, 104, 773, 895), b('28', 5, 374, 525, 905), b('29', 6, 104, 514, 905), b('30', 6, 374, 347, 905)],
    evidence: fakeEvidence({
      pageCount: 6,
      ink: [
        { page: 5, region: [140, 104, 760, 360] },
        { page: 5, region: [773, 104, 895, 360] },
        { page: 5, region: [140, 374, 510, 630] },
        { page: 5, region: [525, 374, 905, 630] },
        { page: 5, region: [140, 644, 905, 900] },
        { page: 6, region: [140, 104, 500, 360] },
        { page: 6, region: [514, 104, 905, 360] },
        { page: 6, region: [140, 374, 333, 630] },
        { page: 6, region: [347, 374, 905, 630] },
        { page: 6, region: [140, 644, 420, 900] },
      ],
    }),
  });
  assert.deepEqual(
    right.columns.map((c) => [c.left, c.inferred === true]),
    [
      [98, false],
      [368, false],
      [638, true],
    ],
  );
  assert.deepEqual(
    right.segments.get('28').continuations.map((c) => [c.rawPage, c.region1k[1]]),
    [
      [5, 638],
      [6, 98],
    ],
  );
  assert.deepEqual(
    right.segments.get('30').continuations.map((c) => [c.rawPage, c.region1k[1], c.region1k[2]]),
    [[6, 638, 424]],
  );
});

test('planSolutionSegments without page evidence keeps stored regions and reports what it could not check', () => {
  const plan = planSolutionSegments({ blocks: TWO_COLUMN_BLOCKS, pageCount: 2 });
  const seg = (key) => plan.segments.get(key);
  assert.deepEqual(seg('c1').contentRegion, [118, 94, 590, 464]);
  // 잉크를 볼 수 없으면 넓은 틈만 이어 붙이고 확인하지 못했다고 알린다.
  assert.deepEqual(seg('c2').continuations, [{ rawPage: 1, region1k: [110, 514, 397, 884] }]);
  assert.equal(seg('c2').unchecked, true);
  // 구간 머리를 읽지 못해 다음 구간 머리가 섞였을 수 있다.
  assert.equal(seg('c3').unchecked, true);
  assert.deepEqual(plan.unchecked, ['c2', 'c3', 'e24']);
});

test('planSolutionSegments keeps a region a person fixed', () => {
  const blocks = TWO_COLUMN_BLOCKS.map((b) => (b.key === 'c1' ? { ...b, contentRegion: [118, 90, 500, 470], manual: true } : b));
  const plan = planSolutionSegments({ blocks, evidence: TWO_COLUMN_EVIDENCE() });
  assert.deepEqual(plan.segments.get('c1').contentRegion, [118, 90, 500, 470]);
});

// 선택과목 풀이만 읽는 해설지: 번호는 모두 단 중간에서 시작하고, 단 맨 위에는 앞 풀이의 이어진 줄만 있다.
const ELECTIVE_ONLY_BLOCKS = [
  block('g23', 'geometry', 1, 100, 300, 500),
  block('g24', 'geometry', 1, 100, 520, 900),
  block('g25', 'geometry', 1, 520, 400, 900),
  block('g26', 'geometry', 2, 100, 350, 900),
  block('g27', 'geometry', 3, 100, 500, 700),
];

test('planSolutionSegments takes the column top from text lines when no number starts a column', () => {
  const plan = planSolutionSegments({
    blocks: ELECTIVE_ONLY_BLOCKS,
    evidence: fakeEvidence({
      pageCount: 3,
      ink: [
        { page: 1, region: [130, 100, 260, 460] },
        { page: 1, region: [300, 100, 500, 460] },
        { page: 1, region: [520, 100, 900, 460] },
        { page: 1, region: [115, 520, 380, 880] },
        { page: 1, region: [400, 520, 900, 880] },
        { page: 2, region: [115, 100, 330, 460] },
        { page: 2, region: [350, 100, 900, 460] },
        { page: 2, region: [115, 520, 900, 880] },
        { page: 3, region: [115, 100, 480, 460] },
        { page: 3, region: [500, 100, 700, 460] },
      ],
      lines: [
        { page: 1, y: 132, x: 110, text: '23. ③ 24. ④ 25. ③' },
        { page: 1, y: 116, x: 530, text: '가 같으므로' },
        { page: 2, y: 116, x: 110, text: '또, 선분 AB를' },
        { page: 2, y: 117, x: 530, text: '이므로 AM' },
        { page: 3, y: 116, x: 110, text: '따라서' },
      ],
    }),
  });
  // 가장 높은 번호(300)보다 한참 위지만, 여러 칸의 첫 글줄이 가리키는 자리가 단 맨 위다.
  assert.equal(plan.top, 111);
  const seg = (key) => plan.segments.get(key);
  assert.deepEqual(seg('g24').continuations, [{ rawPage: 1, region1k: [111, 514, 384, 884] }]);
  assert.deepEqual(seg('g25').continuations, [{ rawPage: 2, region1k: [111, 94, 334, 464] }]);
  assert.deepEqual(seg('g26').continuations, [
    { rawPage: 2, region1k: [111, 514, 904, 884] },
    { rawPage: 3, region1k: [111, 94, 484, 464] },
  ]);
});

test('planSolutionSegments leaves a running head out of the column top', () => {
  const pages = [1, 2, 3];
  const plan = planSolutionSegments({
    blocks: [
      block('a', 'common', 1, 100, 300, 900),
      block('b', 'common', 1, 520, 500, 900),
      block('c', 'common', 2, 100, 600, 900),
      block('d', 'common', 2, 520, 400, 900),
      block('e', 'common', 3, 100, 700, 900),
    ],
    evidence: fakeEvidence({
      pageCount: 3,
      ink: [
        // 쪽마다 같은 자리의 쪽 머리글
        ...pages.flatMap((page) => [
          { page, region: [46, 100, 62, 460] },
          { page, region: [46, 600, 62, 880] },
        ]),
        { page: 1, region: [115, 100, 280, 460] },
        { page: 1, region: [300, 100, 900, 460] },
        { page: 1, region: [115, 520, 480, 880] },
        { page: 1, region: [500, 520, 900, 880] },
        { page: 2, region: [115, 100, 580, 460] },
        { page: 2, region: [600, 100, 900, 460] },
        { page: 2, region: [115, 520, 380, 880] },
        { page: 2, region: [400, 520, 900, 880] },
        { page: 3, region: [115, 100, 680, 460] },
        { page: 3, region: [700, 100, 900, 460] },
        { page: 3, region: [115, 520, 300, 880] },
      ],
      lines: [
        ...pages.flatMap((page) => [
          { page, y: 50, x: 110, text: `수능 해설 ${page}` },
          { page, y: 50, x: 700, text: '수학 영역' },
        ]),
        { page: 1, y: 116, x: 110, text: '정답표' },
        { page: 1, y: 116, x: 530, text: '이므로' },
        { page: 2, y: 116, x: 110, text: '따라서 구하는 값은' },
        { page: 2, y: 117, x: 530, text: '한편' },
        { page: 3, y: 116, x: 110, text: '즉,' },
        { page: 3, y: 116, x: 530, text: '그러므로' },
      ],
    }),
  });
  // 첫 잉크(46)는 쪽 머리글이다. 쪽마다 되풀이되는 글줄을 뺀 첫 글줄(116) 위를 단 맨 위로 본다.
  assert.equal(plan.top, 112);
  assert.deepEqual(plan.segments.get('a').continuations, [{ rawPage: 1, region1k: [112, 514, 484, 884] }]);
  assert.deepEqual(plan.segments.get('e').continuations, [{ rawPage: 3, region1k: [112, 514, 304, 884] }]);
});

test('planSolutionSegments keeps the column top near the highest number when the PDF has no text layer', () => {
  const plan = planSolutionSegments({
    blocks: ELECTIVE_ONLY_BLOCKS,
    evidence: fakeEvidence({
      pageCount: 3,
      hasText: false,
      ink: [
        { page: 1, region: [46, 100, 62, 460] },
        { page: 1, region: [300, 100, 900, 460] },
        { page: 1, region: [46, 520, 62, 880] },
        { page: 1, region: [400, 520, 900, 880] },
        { page: 2, region: [46, 100, 62, 460] },
        { page: 2, region: [350, 100, 900, 460] },
        { page: 3, region: [46, 100, 62, 460] },
        { page: 3, region: [500, 100, 700, 460] },
      ],
    }),
  });
  // 글줄을 읽지 못하면 첫 잉크(46)가 쪽 머리글인지 풀이인지 가릴 수 없다. 가장 높은 번호(300)보다 60 위까지만 본다.
  assert.equal(plan.top, 240);
});

// ── PDF 근거 ──────────────────────────────────────────────────────────────

function image(width, height, paint) {
  const data = Buffer.alloc(width * height, 255);
  paint((x, y) => {
    data[y * width + x] = 0;
  });
  return { width, height, data };
}

test('parsePgm reads a binary gray image', () => {
  const pgm = Buffer.concat([Buffer.from('P5\n# made by test\n2 3\n255\n', 'latin1'), Buffer.from([0, 255, 10, 20, 30, 40])]);
  const img = parsePgm(pgm);
  assert.equal(img.width, 2);
  assert.equal(img.height, 3);
  assert.deepEqual([...img.data], [0, 255, 10, 20, 30, 40]);
  assert.throws(() => parsePgm(Buffer.from('P6\n1 1\n255\n\0')), /pgm_format_unsupported/);
});

test('solutionEvidenceFrom ignores rules and specks when it looks for ink', () => {
  const img = image(100, 200, (dot) => {
    // 가로선(폭 전체) 한 줄
    for (let x = 0; x < 100; x += 1) dot(x, 20);
    // 글자: 40~49 줄, x 10~39
    for (let y = 40; y < 50; y += 1) for (let x = 10; x < 40; x += 1) dot(x, y);
    // 상자 세로 테두리(줄마다 점 두 개)
    for (let y = 100; y < 120; y += 1) {
      dot(2, y);
      dot(97, y);
    }
  });
  const evidence = solutionEvidenceFrom({ images: [img] });
  assert.equal(evidence.pageCount, 1);
  assert.equal(evidence.hasText, false);
  assert.deepEqual(evidence.inkBounds(1, [0, 0, 1000, 1000]), [200, 250]);
  assert.equal(evidence.firstInk(1, [0, 0, 1000, 1000]), 200);
  // 가로선과 세로 테두리뿐인 곳은 빈 곳이다.
  assert.deepEqual(evidence.inkBounds(1, [0, 0, 150, 1000]), []);
  assert.deepEqual(evidence.inkBounds(1, [450, 0, 1000, 1000]), []);
  assert.equal(evidence.inkBounds(2, [0, 0, 1000, 1000]), null);
  assert.equal(evidence.lines(1, [0, 0, 1000, 1000]), null);
});

test('solutionEvidenceFrom groups words into lines inside a region', () => {
  const filler = Array.from({ length: 20 }, (_, i) => ({ text: `w${i}`, xMin: 60, xMax: 70, yMin: 150 + i, yMax: 151 + i }));
  const wordPages = [
    {
      page: 1,
      width: 100,
      height: 200,
      words: [
        { text: '통계]', xMin: 32, yMin: 40, xMax: 45, yMax: 48 },
        { text: '[확률과', xMin: 10, yMin: 41, xMax: 30, yMax: 48 },
        { text: '23.', xMin: 10, yMin: 60, xMax: 16, yMax: 68 },
        ...filler,
      ],
    },
  ];
  const evidence = solutionEvidenceFrom({ wordPages });
  assert.equal(evidence.hasText, true);
  const lines = evidence.lines(1, [0, 0, 400, 500]);
  assert.deepEqual(
    lines.map((l) => l.text),
    ['[확률과 통계]', '23.'],
  );
  assert.equal(lines[0].yMin, 200);
  assert.equal(isSectionHeaderLine(lines[0].text), true);
});

// ── 검수 준비 ─────────────────────────────────────────────────────────────

// 요청마다 실제 클라이언트처럼 await 할 때 실행한다.
function fakeSupa(tables) {
  let seq = 0;
  const table = (name) => {
    if (!tables[name]) tables[name] = [];
    return tables[name];
  };
  class Query {
    constructor(name) {
      this.name = name;
      this.filters = [];
      this.op = 'select';
    }
    select() {
      if (this.op !== 'select') this.returning = true;
      return this;
    }
    eq(col, value) {
      this.filters.push((r) => String(r[col]) === String(value));
      return this;
    }
    neq(col, value) {
      this.filters.push((r) => String(r[col]) !== String(value));
      return this;
    }
    in(col, values) {
      const set = new Set(values);
      this.filters.push((r) => set.has(r[col]));
      return this;
    }
    // .not(col, 'is', null) 만 쓴다.
    not(col, op, value) {
      assert.equal(op, 'is');
      assert.equal(value, null);
      this.filters.push((r) => r[col] !== null && r[col] !== undefined);
      return this;
    }
    order() {
      return this;
    }
    limit(n) {
      this.max = n;
      return this;
    }
    maybeSingle() {
      this.one = true;
      return this;
    }
    single() {
      this.one = true;
      return this;
    }
    insert(rows) {
      this.op = 'insert';
      this.rows = [].concat(rows);
      return this;
    }
    upsert(rows, opts) {
      this.op = 'upsert';
      this.rows = [].concat(rows);
      this.conflict = String(opts?.onConflict || 'id').split(',');
      this.ignoreDuplicates = opts?.ignoreDuplicates === true;
      return this;
    }
    update(values) {
      this.op = 'update';
      this.values = values;
      return this;
    }
    delete() {
      this.op = 'delete';
      return this;
    }
    then(resolve, reject) {
      try {
        resolve({ data: this.run(), error: null });
      } catch (err) {
        reject(err);
      }
    }
    run() {
      const rows = table(this.name);
      const match = (r) => this.filters.every((f) => f(r));
      if (this.op === 'select') {
        const hit = rows.filter(match).slice(0, this.max ?? undefined);
        return this.one ? hit[0] || null : hit;
      }
      if (this.op === 'insert') {
        const added = this.rows.map((r) => ({ id: r.id || `${this.name}-${(seq += 1)}`, ...r }));
        rows.push(...added);
        if (!this.returning) return null;
        return this.one ? added[0] : added;
      }
      if (this.op === 'upsert') {
        for (const r of this.rows) {
          const cur = rows.find((x) => this.conflict.every((c) => String(x[c]) === String(r[c])));
          if (!cur) rows.push({ id: r.id || `${this.name}-${(seq += 1)}`, ...r });
          else if (!this.ignoreDuplicates) Object.assign(cur, r);
        }
        return null;
      }
      if (this.op === 'update') {
        for (const r of rows.filter(match)) Object.assign(r, this.values);
        return null;
      }
      const keep = rows.filter((r) => !match(r));
      rows.length = 0;
      rows.push(...keep);
      return null;
    }
  }
  return { from: (name) => new Query(name) };
}

const ACADEMY = 'a0000000-0000-4000-8000-000000000001';
const EXAM = 'e0000000-0000-4000-8000-000000000001';
const DOC_COMMON = 'd0000000-0000-4000-8000-000000000001';
const DOC_PROB = 'd0000000-0000-4000-8000-000000000002';
const PAPER_PROBLEM = 'p-problem';
const PAPER_SOLUTION = 'p-solution';

function question(documentId, number, answer) {
  const objective = /[①-⑤]/.test(answer);
  return {
    id: `q-${documentId.slice(-1)}-${number}`,
    academy_id: ACADEMY,
    document_id: documentId,
    question_uid: `uid-${documentId.slice(-1)}-${number}`,
    question_number: String(number),
    source_order: number,
    choices: objective ? [1, 2, 3, 4, 5].map((n) => ({ label: `${n}`, text: `t${n}` })) : [],
    allow_objective: objective,
    objective_answer_key: objective ? answer : '',
    subjective_answer: objective ? '' : answer,
    is_published: true,
  };
}

function item(section, number, bodyPage, solution) {
  return {
    exam_id: EXAM,
    section,
    problem_number: number,
    paper_id: PAPER_PROBLEM,
    raw_page: bodyPage,
    item_region_1k: [100 + number, 50, 300 + number, 480],
    answer_kind: 'objective',
    answer_text: '①',
    solution_paper_id: PAPER_SOLUTION,
    solution_raw_page: solution.page,
    solution_number_region_1k: solution.numberRegion,
    solution_content_region_1k: solution.contentRegion,
    solution_source: 'vlm',
  };
}

// 이미 추출된 고3 회차: 공통(1~3번) + 확률과 통계(23·24번). 해설지는 위 TWO_COLUMN_BLOCKS 와 같은 배치.
function reviewTables() {
  const [c1, c2, c3, e23, e24] = TWO_COLUMN_BLOCKS;
  return {
    mock_exams: [
      {
        id: EXAM,
        academy_id: ACADEMY,
        created_by: 'user-1',
        grade: 3,
        exam_year: 2025,
        school_year: 2026,
        exam_month: 10,
        org: 'edu',
        curriculum_code: 'rev_2015',
        status: 'review',
        stage: 'extracting',
        last_error: '',
      },
    ],
    mock_exam_papers: [
      {
        id: PAPER_PROBLEM,
        exam_id: EXAM,
        kind: 'problem',
        elective: 'probstats',
        storage_bucket: 'problem-documents',
        storage_path: 'mock/problem.pdf',
        file_name: '2025 고3 10월 교육청 (확통).pdf',
        sha256: 'sha-problem',
        size_bytes: 1000,
      },
      {
        id: PAPER_SOLUTION,
        exam_id: EXAM,
        kind: 'solution',
        elective: 'probstats',
        storage_bucket: 'problem-documents',
        storage_path: 'mock/solution.pdf',
        file_name: '2025 고3 10월 교육청 (확통) - 해설.pdf',
        sha256: 'sha-solution',
        size_bytes: 2000,
      },
    ],
    mock_exam_sections: [
      { exam_id: EXAM, section: 'common', academy_id: ACADEMY, pb_document_id: DOC_COMMON, extract_job_id: 'job-common' },
      { exam_id: EXAM, section: 'probstats', academy_id: ACADEMY, pb_document_id: DOC_PROB, extract_job_id: 'job-prob' },
    ],
    pb_extract_jobs: [
      { id: 'job-common', status: 'completed', error_code: '', error_message: '' },
      { id: 'job-prob', status: 'review_required', error_code: '', error_message: '' },
    ],
    pb_documents: [DOC_COMMON, DOC_PROB].map((id, i) => ({
      id,
      academy_id: ACADEMY,
      status: 'draft_review_required',
      source_pdf_storage_bucket: 'problem-documents',
      source_pdf_storage_path: 'mock/problem.pdf',
      source_pdf_size_bytes: 1000,
      source_pdf_sha256: 'sha-problem',
      meta: {
        extract_mode: 'mock_exam_pdf',
        mock_scope: { exam_id: EXAM, section: i === 0 ? 'common' : 'probstats', paper_id: PAPER_PROBLEM, raw_page_from: 1, raw_page_to: 4 },
      },
    })),
    pb_questions: [
      question(DOC_COMMON, 1, '③'),
      question(DOC_COMMON, 2, '⑤'),
      question(DOC_COMMON, 3, '63'),
      question(DOC_PROB, 23, '②'),
      question(DOC_PROB, 24, '17'),
    ],
    mock_exam_items: [
      item('common', 1, 1, c1),
      item('common', 2, 1, c2),
      item('common', 3, 2, c3),
      item('probstats', 23, 3, e23),
      item('probstats', 24, 4, e24),
    ],
  };
}

function prepare(tables, documentId, extra = {}) {
  return prepareMockReview({
    supa: fakeSupa(tables),
    academyId: ACADEMY,
    documentId,
    loadPaperPdf: async () => Buffer.from('pdf'),
    readEvidence: async () => TWO_COLUMN_EVIDENCE(),
    // 시험지 글자 층을 읽지 못한 것으로 둔다(선지 번호 자리는 아래 전용 테스트에서 본다).
    readChoiceWords: async () => [],
    retryDelaysMs: [],
    ...extra,
  });
}

test('previewMockSolutionRefs reports the solution positions that would change and writes nothing', async () => {
  const tables = reviewTables();
  await prepare(tables, DOC_COMMON);
  const preview = (extra = {}) =>
    previewMockSolutionRefs({
      supa: fakeSupa(tables),
      academyId: ACADEMY,
      documentId: DOC_COMMON,
      loadPaperPdf: async () => Buffer.from('pdf'),
      readEvidence: async () => TWO_COLUMN_EVIDENCE(),
      retryDelaysMs: [],
      ...extra,
    });
  // 방금 준비한 구간: 달라지는 문항이 없다.
  let res = await preview();
  assert.equal(res.ok, true);
  assert.equal(res.preview, true);
  assert.equal(res.solutionCount, 3);
  assert.deepEqual(res.changes, []);

  const numberOf = (cropId) => tables.textbook_problem_crops.find((c) => c.id === cropId).problem_number;
  const refs = tables.textbook_problem_solution_refs;
  // 이어진 부분이 있는 두 문항: 하나는 옛 규칙의 값(이어진 부분 없음)으로 되돌리고, 하나는 사람이 고친 위치로 둔다.
  const [stale, edited] = refs.filter((r) => (r.continuation_regions || []).length > 0);
  const computed = structuredClone(stale.continuation_regions);
  stale.continuation_regions = [];
  edited.continuation_regions = [];
  edited.edited_at = '2026-01-01T00:00:00Z';
  const before = JSON.stringify(tables);

  res = await preview();
  assert.deepEqual(res.changes.map((c) => c.number), [numberOf(stale.crop_id)]);
  assert.equal(res.changes[0].cropId, stale.crop_id);
  assert.deepEqual(res.changes[0].before.continuation_regions, []);
  assert.deepEqual(res.changes[0].after.continuation_regions, computed);
  assert.equal(res.changes[0].after.source_kind, 'sol');
  assert.equal(res.solutionProtected, 1);
  // 아무것도 쓰지 않았다.
  assert.equal(JSON.stringify(tables), before);

  const other = await preview({ documentId: 'd0000000-0000-4000-8000-000000000009' });
  assert.equal(other.ok, false);
  assert.equal(other.error, 'not_mock_section');
});

test('prepareMockReview stages one section as one review scope', async () => {
  const tables = reviewTables();
  const res = await prepare(tables, DOC_COMMON);
  assert.equal(res.ok, true);
  assert.equal(res.state, 'ready');
  assert.equal(res.gradeLabel, '대수+미적분1');
  assert.equal(res.bookName, '2025 고3 10월 교육청 · 공통');
  assert.equal(res.questionCount, 3);
  assert.equal(res.cropCount, 3);
  assert.equal(res.answersSeeded, 3);
  assert.equal(res.solutionCount, 3);
  assert.equal(res.solutionContinued, 2);
  assert.deepEqual(res.solutionMissing, []);
  assert.deepEqual(res.missingAnswers, []);
  assert.equal(res.unpublished, 0);

  // 책 행은 숨겨 두고, 시험지·해설지 PDF 를 과정 라벨로 연결한다.
  assert.deepEqual(
    tables.resource_files.map((r) => [r.id, r.category, r.is_published, r.name]),
    [[DOC_COMMON, 'mock_past', false, '2025 고3 10월 교육청 · 공통']],
  );
  assert.deepEqual(
    tables.resource_file_links.map((l) => [l.grade, l.storage_key, l.migration_status]),
    [
      ['대수+미적분1#body', 'mock/problem.pdf', 'migrated'],
      ['대수+미적분1#sol', 'mock/solution.pdf', 'migrated'],
    ],
  );

  const crops = tables.textbook_problem_crops;
  assert.deepEqual(
    crops.map((c) => [c.problem_number, c.raw_page, c.item_region_1k, c.pb_question_uid, c.sub_key, c.big_name, c.mid_name]),
    [
      ['1', 1, [101, 50, 301, 480], 'uid-1-1', 'A', '2025 고3 10월 교육청', '공통'],
      ['2', 1, [102, 50, 302, 480], 'uid-1-2', 'A', '2025 고3 10월 교육청', '공통'],
      ['3', 2, [103, 50, 303, 480], 'uid-1-3', 'A', '2025 고3 10월 교육청', '공통'],
    ],
  );
  const cropId = (number) => crops.find((c) => c.problem_number === number).id;
  assert.deepEqual(
    tables.textbook_crop_question_links.map((l) => [l.crop_id, l.pb_question_id]),
    [
      [cropId('1'), 'q-1-1'],
      [cropId('2'), 'q-1-2'],
      [cropId('3'), 'q-1-3'],
    ],
  );
  assert.deepEqual(
    tables.textbook_problem_answers.map((a) => [a.crop_id, a.answer_kind, a.answer_text, a.answer_source]),
    [
      [cropId('1'), 'objective', '③', 'vlm'],
      [cropId('2'), 'objective', '⑤', 'vlm'],
      [cropId('3'), 'subjective', '63', 'vlm'],
    ],
  );

  const ref = (number) => tables.textbook_problem_solution_refs.find((r) => r.crop_id === cropId(number));
  assert.equal(ref('1').source_kind, 'sol');
  assert.equal(ref('1').raw_page, 1);
  assert.deepEqual(ref('1').number_region_1k, [120, 100, 132, 114]);
  assert.deepEqual(ref('1').content_region_1k, [118, 94, 594, 464]);
  assert.deepEqual(ref('1').continuation_regions, []);
  assert.equal(ref('1').edited_at, null);
  assert.deepEqual(ref('2').continuation_regions, [{ raw_page: 1, region_1k: [111, 514, 384, 884] }]);
  // 공통의 마지막 풀이는 선택과목 머리 줄 위에서 끝난다.
  assert.deepEqual(ref('3').continuation_regions, [{ raw_page: 2, region_1k: [108, 94, 284, 464] }]);
  // 이미 공개된 회차의 문항은 그대로 공개돼 있다.
  assert.equal(tables.pb_questions.every((q) => q.is_published === true), true);
});

test('prepareMockReview is idempotent and keeps what a person fixed', async () => {
  const tables = reviewTables();
  await prepare(tables, DOC_COMMON);
  const crop2 = tables.textbook_problem_crops.find((c) => c.problem_number === '2');
  // 사람이 2번의 정답과 해설 위치, 3번의 문항 영역을 고쳤다.
  Object.assign(tables.textbook_problem_answers.find((a) => a.crop_id === crop2.id), {
    answer_text: '④',
    answer_source: 'manual',
  });
  Object.assign(tables.textbook_problem_solution_refs.find((r) => r.crop_id === crop2.id), {
    content_region_1k: [598, 94, 800, 464],
    continuation_regions: [],
    edited_at: '2026-11-20T00:00:00.000Z',
  });
  const crop3 = tables.textbook_problem_crops.find((c) => c.problem_number === '3');
  Object.assign(crop3, { item_region_1k: [10, 10, 500, 500], region_source: 'manual' });

  const again = await prepare(tables, DOC_COMMON, { refreshAnswers: true });
  assert.equal(again.cropsWritten, 0);
  assert.equal(again.answersSeeded, 0);
  assert.equal(again.answersRefreshed, 0);
  assert.equal(again.solutionsWritten, 0);
  assert.equal(again.solutionProtected, 1);
  assert.equal(tables.textbook_problem_crops.length, 3);
  assert.deepEqual(crop3.item_region_1k, [10, 10, 500, 500]);
  assert.equal(tables.textbook_problem_answers.find((a) => a.crop_id === crop2.id).answer_text, '④');
  assert.deepEqual(tables.textbook_problem_solution_refs.find((r) => r.crop_id === crop2.id).content_region_1k, [598, 94, 800, 464]);
  assert.equal(tables.resource_file_links.length, 2);
});

test('prepareMockReview relinks questions after a re-extraction and resets recreated ones', async () => {
  const tables = reviewTables();
  await prepare(tables, DOC_COMMON);
  const crops = tables.textbook_problem_crops;
  tables.textbook_review_findings = crops.map((c) => ({ id: `f-${c.id}`, crop_id: c.id }));
  tables.textbook_problem_analyses = crops.map((c) => ({ id: `n-${c.id}`, crop_id: c.id }));
  // 다시 추출: 1번은 같은 uid 로 id 만 바뀌고 정답이 바뀌었다. 2번은 uid 까지 새로 만들어졌다. 3번은 없어졌다.
  tables.pb_questions = [
    { ...question(DOC_COMMON, 1, '②'), id: 'q-new-1' },
    { ...question(DOC_COMMON, 2, '⑤'), id: 'q-new-2', question_uid: 'uid-new-2' },
    ...tables.pb_questions.filter((q) => q.document_id === DOC_PROB),
  ];
  const res = await prepare(tables, DOC_COMMON, { refreshAnswers: true });
  assert.equal(res.cropCount, 2);
  assert.equal(res.cropsRemoved, 1);
  assert.equal(res.reviewsReset, 1);
  assert.equal(res.answersRefreshed, 1);
  const crop1 = crops.find((c) => c.problem_number === '1');
  const crop2 = crops.find((c) => c.problem_number === '2');
  assert.equal(crop2.pb_question_uid, 'uid-new-2');
  assert.deepEqual(
    tables.textbook_crop_question_links.filter((l) => [crop1.id, crop2.id].includes(l.crop_id)).map((l) => l.pb_question_id),
    ['q-new-1', 'q-new-2'],
  );
  assert.equal(tables.textbook_problem_answers.find((a) => a.crop_id === crop1.id).answer_text, '②');
  // 같은 문항(1번)의 검수 기록은 남고, 새로 만든 문항(2번)의 기록은 비운다.
  assert.equal(tables.textbook_review_findings.some((f) => f.crop_id === crop1.id), true);
  assert.equal(tables.textbook_review_findings.some((f) => f.crop_id === crop2.id), false);
  assert.equal(tables.textbook_problem_analyses.some((f) => f.crop_id === crop2.id), false);
});

test('prepareMockReview waits while the exam or the section is being extracted', async () => {
  const queued = reviewTables();
  queued.mock_exams[0].status = 'queued';
  assert.deepEqual(
    (({ ok, state, reason }) => ({ ok, state, reason }))(await prepare(queued, DOC_COMMON)),
    { ok: true, state: 'waiting', reason: 'exam_queued' },
  );
  const extracting = reviewTables();
  extracting.pb_extract_jobs[0].status = 'extracting';
  const res = await prepare(extracting, DOC_COMMON);
  assert.equal(res.state, 'waiting');
  assert.equal(res.reason, 'extracting');
  assert.equal(res.bookId, DOC_COMMON);
  assert.equal(extracting.textbook_problem_crops, undefined);
});

test('prepareMockReview requests the whole exam only when no section has questions', async () => {
  const tables = reviewTables();
  tables.mock_exams[0].status = 'draft';
  tables.pb_questions = [];
  tables.pb_extract_jobs = [];
  for (const l of tables.mock_exam_sections) l.extract_job_id = null;
  // 실행기가 허락하지 않으면 추출을 걸지 않는다.
  const refused = await prepare(tables, DOC_COMMON);
  assert.deepEqual([refused.ok, refused.error], [false, 'needs_extract']);
  assert.equal(tables.mock_exams[0].status, 'draft');

  const res = await prepare(tables, DOC_COMMON, { allowExtract: true });
  assert.deepEqual([res.state, res.reason, res.requested], ['waiting', 'exam_queued', 'all']);
  assert.equal(tables.mock_exams[0].status, 'queued');
  assert.deepEqual(tables.mock_exams[0].progress, { request: 'all' });
  assert.equal(tables.pb_extract_jobs.length, 0);
});

test('prepareMockReview requeues only its own section when other sections already have questions', async () => {
  const tables = reviewTables();
  tables.pb_questions = tables.pb_questions.filter((q) => q.document_id === DOC_PROB);
  tables.pb_extract_jobs[0] = { id: 'job-common', status: 'failed', error_code: 'vlm_failed', error_message: 'gemini timeout' };
  // 실패한 작업은 실행기가 허락할 때만 다시 건다.
  const failed = await prepare(tables, DOC_COMMON);
  assert.deepEqual([failed.ok, failed.error, failed.message], [false, 'extract_failed', 'gemini timeout']);

  const res = await prepare(tables, DOC_COMMON, { allowExtract: true });
  assert.deepEqual([res.state, res.reason, res.requested], ['waiting', 'extract_queued', 'section']);
  assert.equal(tables.mock_exams[0].status, 'review');
  const job = tables.pb_extract_jobs[tables.pb_extract_jobs.length - 1];
  assert.equal(job.document_id, DOC_COMMON);
  assert.equal(job.status, 'queued');
  assert.equal(job.source_version, 'mock_exam_pdf_v1');
  assert.deepEqual(job.result_summary.mock_scope.section, 'common');
  assert.equal(tables.mock_exam_sections[0].extract_job_id, job.id);
  assert.equal(tables.pb_documents[0].status, 'extract_queued');

  // 검수에서 미리 만든 구간 문서에는 추출 범위가 없다: 문항 영역에서 만든다.
  const unscoped = reviewTables();
  unscoped.pb_questions = unscoped.pb_questions.filter((q) => q.document_id === DOC_PROB);
  unscoped.pb_extract_jobs = [];
  unscoped.mock_exam_sections[0].extract_job_id = null;
  unscoped.pb_documents[0].meta = { mock_review: { publish_on_confirm: true } };
  const scoped = await prepare(unscoped, DOC_COMMON, { allowExtract: true });
  assert.deepEqual([scoped.state, scoped.reason, scoped.requested], ['waiting', 'extract_queued', 'section']);
  assert.deepEqual(unscoped.pb_documents[0].meta, {
    mock_review: { publish_on_confirm: true },
    extract_mode: 'mock_exam_pdf',
    mock_scope: { exam_id: EXAM, section: 'common', paper_id: PAPER_PROBLEM, raw_page_from: 1, raw_page_to: 2 },
  });
  assert.equal(unscoped.pb_extract_jobs.length, 1);
});

test('prepareMockReview asks the exam worker for the sections that were never extracted', async () => {
  // 확률과 통계만 뽑아 둔 회차의 공통: 문항 영역도 없다. 뽑지 않은 구간만 맡기고 다른 구간의 문항은 그대로 둔다.
  const tables = reviewTables();
  tables.pb_questions = tables.pb_questions.filter((q) => q.document_id === DOC_PROB);
  tables.mock_exam_items = tables.mock_exam_items.filter((it) => it.section === 'probstats');
  tables.pb_extract_jobs = [];
  tables.mock_exam_sections[0].extract_job_id = null;
  tables.pb_documents[0].meta = { mock_review: { publish_on_confirm: true } };
  const res = await prepare(tables, DOC_COMMON, { allowExtract: true });
  assert.deepEqual([res.state, res.reason, res.requested], ['waiting', 'exam_queued', 'sections']);
  assert.equal(tables.mock_exams[0].status, 'queued');
  assert.deepEqual(tables.mock_exams[0].progress, { request: 'sections', sections: ['common'] });
  assert.equal(tables.pb_extract_jobs.length, 0);
  assert.equal(tables.pb_questions.length, 2);

  // 문항 영역이 가리키는 문제지가 없으면 걸 수 없다.
  const broken = reviewTables();
  broken.pb_questions = broken.pb_questions.filter((q) => q.document_id === DOC_PROB);
  broken.pb_extract_jobs = [];
  broken.mock_exam_sections[0].extract_job_id = null;
  for (const it of broken.mock_exam_items) if (it.section === 'common') it.paper_id = 'p-gone';
  const none = await prepare(broken, DOC_COMMON, { allowExtract: true });
  assert.deepEqual([none.ok, none.error], [false, 'no_items']);
});

test('prepareMockReview hides the questions of a section that is published on confirm', async () => {
  const tables = reviewTables();
  tables.pb_documents[1].meta.mock_review = { publish_on_confirm: true, created_at: '2026-11-20T00:00:00.000Z' };
  const res = await prepare(tables, DOC_PROB);
  assert.equal(res.gradeLabel, '확률과 통계');
  assert.equal(res.publishOnConfirm, true);
  assert.equal(res.unpublished, 2);
  assert.deepEqual(
    tables.pb_questions.map((q) => [q.question_number, q.is_published]),
    [
      ['1', true],
      ['2', true],
      ['3', true],
      ['23', false],
      ['24', false],
    ],
  );
  // 확정해 공개한 뒤에는 다시 숨기지 않는다.
  for (const q of tables.pb_questions) q.is_published = true;
  tables.pb_documents[1].meta.mock_review.published_at = '2026-11-21T00:00:00.000Z';
  const after = await prepare(tables, DOC_PROB);
  assert.equal(after.publishOnConfirm, false);
  assert.equal(after.unpublished, 0);
  assert.equal(tables.pb_questions.every((q) => q.is_published), true);
});

test('prepareMockReview marks questions without a solution and re-anchors one found in another solution paper', async () => {
  const tables = reviewTables();
  // 1번은 해설 위치를 못 찾았고, 2번은 다른 해설지(기하)에서 찾았다. 표가 같으면 앞 선택과목 해설지를 쓴다.
  Object.assign(tables.mock_exam_items[0], { solution_paper_id: null, solution_raw_page: null, solution_number_region_1k: null });
  tables.mock_exam_items[1].solution_paper_id = 'p-other-solution';
  tables.mock_exam_papers.push({
    id: 'p-other-solution',
    exam_id: EXAM,
    kind: 'solution',
    elective: 'geometry',
    storage_bucket: 'problem-documents',
    storage_path: 'mock/solution-geometry.pdf',
  });
  const evidence = TWO_COLUMN_EVIDENCE();
  const lines = evidence.lines;
  // 이 해설지의 같은 자리에 "2." 가 적혀 있다.
  evidence.lines = (page, region) =>
    page === 1 && region[0] <= 600 && region[2] >= 612 && region[1] <= 100 ? [{ text: '2.', yMin: 600, yMax: 612 }] : lines(page, region);
  const res = await prepare(tables, DOC_COMMON, { readEvidence: async () => evidence });
  assert.deepEqual(res.solutionMissing, ['1']);
  assert.deepEqual(res.solutionReanchored, ['2']);
  const crops = tables.textbook_problem_crops;
  const ref = (number) => tables.textbook_problem_solution_refs.find((r) => r.crop_id === crops.find((c) => c.problem_number === number).id);
  // 해설지가 있는데 못 찾은 풀이는 '해설 없음'(none)이 아니다: 쪽 0 인 sol 행이라 검수에서 "해설 위치 없음"으로 막힌다.
  assert.deepEqual([ref('1').source_kind, ref('1').raw_page, ref('1').continuation_regions], ['sol', 0, null]);
  assert.equal(ref('2').source_kind, 'sol');
  assert.equal(ref('2').raw_page, 1);
});

// ── 선지 번호 자리 ────────────────────────────────────────────────────────

// 1000 x 1000 쪽의 낱말 상자(좌표가 곧 0..1000 값).
function word(text, xMin, yMin, xMax = xMin + 12, yMax = yMin + 10) {
  return { text, xMin, yMin, xMax, yMax };
}

function wordPage(page, words) {
  return { page, width: 1000, height: 1000, words };
}

test('choiceNumberRegion wraps the choice marks inside the item region', () => {
  const region = [100, 50, 400, 480];
  const row = (y, marks, from = 70, step = 80) => [...marks].map((ch, i) => word(ch, from + i * step, y));
  // 한 줄 선지
  assert.deepEqual(choiceNumberRegion(wordPage(1, row(250, '①②③④⑤')), region), [250, 70, 260, 402]);
  // 두 줄 선지(①②③ / ④⑤): 두 줄을 모두 감싼다.
  assert.deepEqual(
    choiceNumberRegion(wordPage(1, [...row(250, '①②③', 70, 130), ...row(290, '④⑤', 70, 130)]), region),
    [250, 70, 300, 342],
  );
  // 다른 꼴의 번호 글자(➀~➄)와 뒤에 값이 붙은 낱말("③12")
  assert.deepEqual(choiceNumberRegion(wordPage(1, [word('➀', 70, 250), word('➁', 150, 250), word('③12', 230, 250, 260)]), region), [
    250, 70, 260, 260,
  ]);
  // 본문에 ①, ② 가 적혀 있어도 가장 아래 것(선지)을 고른다.
  assert.deepEqual(
    choiceNumberRegion(wordPage(1, [word('①', 60, 130), word('②', 200, 130), ...row(350, '①②③④⑤')]), region),
    [350, 70, 360, 402],
  );
  // 문항 영역 밖(다른 문항)의 번호는 세지 않는다.
  assert.equal(choiceNumberRegion(wordPage(1, row(450, '①②③④⑤')), region), null);
  assert.equal(choiceNumberRegion(wordPage(1, row(250, '①②③④⑤', 600)), region), null);
  // 번호가 두 종류뿐이면 선지로 보지 않는다.
  assert.equal(choiceNumberRegion(wordPage(1, row(250, '①②')), region), null);
  // 쪽 크기를 모르면 읽지 않는다.
  assert.equal(choiceNumberRegion({ page: 1, width: 0, height: 0, words: row(250, '①②③④⑤') }, region), null);
});

test('validChoiceRegion and regionInside check a stored region', () => {
  assert.deepEqual(validChoiceRegion([250, 70, 260, 402]), [250, 70, 260, 402]);
  assert.equal(validChoiceRegion([]), null);
  assert.equal(validChoiceRegion(null), null);
  assert.equal(validChoiceRegion([250, 70, 250, 402]), null);
  assert.equal(validChoiceRegion([250, 70, 260, 1200]), null);
  assert.equal(regionInside([250, 70, 260, 402], [100, 50, 400, 480]), true);
  assert.equal(regionInside([250, 48, 260, 402], [100, 50, 400, 480]), true);
  assert.equal(regionInside([250, 70, 420, 402], [100, 50, 400, 480]), false);
});

function choiceTables() {
  const tables = reviewTables();
  // 1번·2번은 객관식, 3번은 주관식. 1번과 2번의 문항 영역을 위아래로 나눈다.
  tables.mock_exam_items[0].item_region_1k = [100, 50, 300, 480];
  tables.mock_exam_items[1].item_region_1k = [320, 50, 520, 480];
  return tables;
}

const CHOICE_PAGES = () => [
  wordPage(1, [
    ...[...'①②③④⑤'].map((ch, i) => word(ch, 70 + i * 80, 250)),
    // 2번은 번호 글자가 없다(선지가 그림인 문항).
    word('풀이', 70, 400),
  ]),
  wordPage(2, [...[...'①②③④⑤'].map((ch, i) => word(ch, 70 + i * 80, 250))]),
];

test('prepareMockReview stores where the choice marks are printed', async () => {
  const tables = choiceTables();
  const loaded = [];
  const extra = {
    loadPaperPdf: async (paper) => {
      loaded.push(paper.id);
      return Buffer.from('pdf');
    },
    readChoiceWords: async () => CHOICE_PAGES(),
  };
  const res = await prepare(tables, DOC_COMMON, extra);
  assert.equal(res.ok, true);
  assert.equal(res.choiceRegionsWritten, 2);
  assert.deepEqual(res.choiceRegionsMissing, ['2']);
  assert.equal(res.choiceRegionsUnread, false);
  const stored = (number) =>
    tables.mock_exam_items.find((it) => it.section === 'common' && it.problem_number === number).choice_number_region_1k;
  assert.deepEqual(stored(1), [250, 70, 260, 402]);
  // 읽었지만 찾지 못한 문항은 빈 배열로 적어 다시 읽지 않는다. 주관식(3번)과 다른 구간은 건드리지 않는다.
  assert.deepEqual(stored(2), []);
  assert.equal(stored(3), undefined);
  assert.equal(tables.mock_exam_items.find((it) => it.section === 'probstats').choice_number_region_1k, undefined);
  assert.deepEqual(loaded, [PAPER_PROBLEM, PAPER_SOLUTION]);

  // 다시 준비하면 시험지 PDF 를 받지 않는다.
  loaded.length = 0;
  const again = await prepare(tables, DOC_COMMON, extra);
  assert.equal(again.choiceRegionsWritten, 0);
  assert.deepEqual(again.choiceRegionsMissing, []);
  assert.deepEqual(loaded, [PAPER_SOLUTION]);

  // 적어 둔 영역이 지금의 문항 영역을 벗어나면(다시 추출해 영역이 바뀜) 다시 읽는다.
  Object.assign(tables.mock_exam_items[0], { choice_number_region_1k: [600, 70, 610, 402] });
  loaded.length = 0;
  const moved = await prepare(tables, DOC_COMMON, extra);
  assert.equal(moved.choiceRegionsWritten, 1);
  assert.deepEqual(stored(1), [250, 70, 260, 402]);
  assert.deepEqual(loaded, [PAPER_PROBLEM, PAPER_SOLUTION]);
});

test('prepareMockReview does not store choice regions when the paper could not be read', async () => {
  const tables = choiceTables();
  const res = await prepare(tables, DOC_COMMON, { readChoiceWords: async () => [] });
  assert.equal(res.ok, true);
  assert.equal(res.choiceRegionsUnread, true);
  assert.equal(res.choiceRegionsWritten, 0);
  assert.equal(tables.mock_exam_items.every((it) => it.choice_number_region_1k === undefined), true);
  // 글자 층이 없는 PDF(쪽은 있고 낱말이 없음)는 찾지 못한 것으로 적는다.
  const scanned = await prepare(tables, DOC_COMMON, {
    readChoiceWords: async () => [wordPage(1, []), wordPage(2, [])],
  });
  assert.equal(scanned.choiceRegionsUnread, false);
  assert.deepEqual(scanned.choiceRegionsMissing, ['1', '2']);
  assert.deepEqual(tables.mock_exam_items[0].choice_number_region_1k, []);
});

// ── 확정할 때 공개 ────────────────────────────────────────────────────────

test('publishMockReview publishes a confirmed section once and syncs the presets', async () => {
  const tables = reviewTables();
  tables.pb_documents[1].meta.mock_review = { publish_on_confirm: true, created_at: '2026-11-20T00:00:00.000Z' };
  for (const q of tables.pb_questions) if (q.document_id === DOC_PROB) q.is_published = false;
  const synced = [];
  let failPresets = false;
  const publish = (documentId) =>
    publishMockReview({
      supa: fakeSupa(tables),
      academyId: ACADEMY,
      documentId,
      syncPresets: async (_supa, examId) => {
        synced.push(examId);
        if (failPresets) throw new Error('preset_down');
        return { synced: 1 };
      },
      retryDelaysMs: [],
    });
  const res = await publish(DOC_PROB);
  assert.deepEqual([res.ok, res.published, res.section, res.presetsSynced], [true, true, 'probstats', 1]);
  assert.equal(tables.pb_questions.every((q) => q.is_published === true), true);
  const meta = tables.pb_documents[1].meta;
  assert.equal(mockReviewPending(meta), false);
  assert.ok(meta.mock_review.published_at);
  assert.equal(meta.mock_scope.section, 'probstats');
  // 다시 불러도 한 번만 공개한다. 검수에서 공개한 구간은 프리셋만 다시 맞춘다(실패하면 이유를 돌려준다).
  const publishedAt = meta.mock_review.published_at;
  failPresets = true;
  const again = await publish(DOC_PROB);
  assert.deepEqual([again.ok, again.published, again.presetsSynced, again.presetError], [true, false, 0, 'preset_down']);
  assert.equal(tables.pb_documents[1].meta.mock_review.published_at, publishedAt);
  failPresets = false;
  // 처음부터 공개돼 있던 구간은 건드리지 않는다.
  const untouched = await publish(DOC_COMMON);
  assert.deepEqual([untouched.published, 'presetsSynced' in untouched], [false, false]);
  assert.deepEqual(synced, [EXAM, EXAM]);
  const other = await publish('d0000000-0000-4000-8000-000000000009');
  assert.deepEqual([other.ok, other.error], [false, 'not_mock_section']);
});

test('syncMockExamPresetsForExam leaves out sections that wait for confirmation', async () => {
  const DOC_CALC = 'd0000000-0000-4000-8000-000000000003';
  const docs = { common: DOC_COMMON, probstats: DOC_PROB, calculus: DOC_CALC };
  const presetTables = (hidden) => {
    const numbered = (documentId, from, count) =>
      Array.from({ length: count }, (_, i) => ({
        id: `q-${documentId.slice(-1)}-${from + i}`,
        question_uid: `uid-${documentId.slice(-1)}-${from + i}`,
        academy_id: ACADEMY,
        document_id: documentId,
        question_number: String(from + i),
        source_order: from + i,
        question_type: '객관식',
        meta: {},
      }));
    return {
      mock_exams: [
        { id: EXAM, academy_id: ACADEMY, grade: 3, exam_year: 2025, school_year: 2026, exam_month: 10, org: 'edu', created_by: null },
      ],
      mock_exam_sections: Object.entries(docs).map(([section, id]) => ({ exam_id: EXAM, section, pb_document_id: id })),
      pb_documents: Object.entries(docs).map(([section, id]) => ({
        id,
        meta: hidden.includes(section) ? { mock_review: { publish_on_confirm: true } } : {},
      })),
      pb_questions: [...numbered(DOC_COMMON, 1, 22), ...numbered(DOC_PROB, 23, 8), ...numbered(DOC_CALC, 23, 8)],
      pb_export_presets: [],
    };
  };
  const electives = (tables) => tables.pb_export_presets.map((p) => p.render_config.mockExamMeta.elective);

  const open = presetTables([]);
  assert.equal((await syncMockExamPresetsForExam(fakeSupa(open), EXAM)).synced, 2);
  assert.deepEqual(electives(open), ['probstats', 'calculus']);
  // 확정 전인 선택과목은 프리셋을 만들지 않는다.
  const partly = presetTables(['probstats']);
  assert.equal((await syncMockExamPresetsForExam(fakeSupa(partly), EXAM)).synced, 1);
  assert.deepEqual(electives(partly), ['calculus']);
  // 공통이 확정 전이면 어느 프리셋도 만들지 않는다.
  const none = presetTables(['common']);
  assert.equal((await syncMockExamPresetsForExam(fakeSupa(none), EXAM)).synced, 0);
  assert.deepEqual(electives(none), []);
});

test('syncMockExamPresetsForExam makes one preset per 가형·나형 section of 30 questions', async () => {
  const DOC_GA = 'd0000000-0000-4000-8000-00000000000a';
  const DOC_NA = 'd0000000-0000-4000-8000-00000000000b';
  const numbered = (documentId, count) =>
    Array.from({ length: count }, (_, i) => ({
      id: `q-${documentId.slice(-1)}-${i + 1}`,
      question_uid: `uid-${documentId.slice(-1)}-${i + 1}`,
      academy_id: ACADEMY,
      document_id: documentId,
      question_number: String(i + 1),
      source_order: i + 1,
      question_type: '객관식',
      meta: {},
    }));
  const tables = {
    mock_exams: [
      { id: EXAM, academy_id: ACADEMY, grade: 3, exam_year: 2020, school_year: 2021, exam_month: 11, org: 'csat', created_by: null },
    ],
    mock_exam_sections: [
      { exam_id: EXAM, section: 'ga', pb_document_id: DOC_GA },
      { exam_id: EXAM, section: 'na', pb_document_id: DOC_NA },
    ],
    pb_documents: [
      { id: DOC_GA, meta: {} },
      { id: DOC_NA, meta: {} },
    ],
    // 나형은 아직 29문항이라 프리셋을 만들지 않는다.
    pb_questions: [...numbered(DOC_GA, 30), ...numbered(DOC_NA, 29)],
    pb_export_presets: [],
  };
  assert.equal((await syncMockExamPresetsForExam(fakeSupa(tables), EXAM)).synced, 1);
  const preset = tables.pb_export_presets[0];
  assert.equal(preset.display_name, '2020 고3 11월 수능 (가형)');
  assert.equal(preset.source_document_id, DOC_GA);
  assert.deepEqual(preset.source_document_ids, [DOC_GA]);
  assert.equal(preset.selected_question_ids.length, 30);
  const cfg = preset.render_config;
  assert.equal(cfg.mockExamMeta.elective, 'ga');
  assert.deepEqual(cfg.titlePageIndices, [1]);
  assert.deepEqual(cfg.titlePageHeaders, [{ page: 1, title: '수학 영역', subtitle: '가형' }]);
  assert.deepEqual(cfg.pageColumnQuestionCounts, []);
  // 1~21번 5지선다형, 22~30번 단답형
  assert.equal(cfg.questionModeByQuestionUid['uid-a-21'], 'objective');
  assert.equal(cfg.questionModeByQuestionUid['uid-a-22'], 'subjective');
});

test('syncMockExamPresetsForExam fills a 가형·나형 paper with the slots that point to the other section', async () => {
  const DOC_GA = 'd0000000-0000-4000-8000-00000000000a';
  const DOC_NA = 'd0000000-0000-4000-8000-00000000000b';
  const numbered = (documentId, count) =>
    Array.from({ length: count }, (_, i) => ({
      id: `q-${documentId.slice(-1)}-${i + 1}`,
      question_uid: `uid-${documentId.slice(-1)}-${i + 1}`,
      academy_id: ACADEMY,
      document_id: documentId,
      question_number: String(i + 1),
      source_order: i + 1,
      question_type: '객관식',
      meta: { score_point: 3 },
    }));
  const build = (gaMeta) => ({
    mock_exams: [
      { id: EXAM, academy_id: ACADEMY, grade: 3, exam_year: 2020, school_year: 2021, exam_month: 11, org: 'csat', created_by: null },
    ],
    mock_exam_sections: [
      { exam_id: EXAM, section: 'ga', pb_document_id: DOC_GA },
      { exam_id: EXAM, section: 'na', pb_document_id: DOC_NA },
    ],
    pb_documents: [
      { id: DOC_GA, meta: gaMeta },
      { id: DOC_NA, meta: {} },
    ],
    // 나형 11번은 가형 6번과 같은 문항이라 나형 문서에는 문항이 없다.
    pb_questions: [...numbered(DOC_GA, 30), ...numbered(DOC_NA, 30).filter((q) => q.question_number !== '11')],
    mock_exam_items: [
      { exam_id: EXAM, section: 'na', problem_number: 11, pb_question_id: 'q-a-6', score: 4, choice_order: [5, 4, 3, 2, 1], stem_override: null, merged_at: '2026-11-24T00:00:00Z' },
      // 합치지 않은 자리는 프리셋에 영향이 없다.
      { exam_id: EXAM, section: 'na', problem_number: 12, pb_question_id: 'q-b-12', score: null, choice_order: null, stem_override: null, merged_at: null },
    ],
    pb_export_presets: [],
  });

  const tables = build({});
  assert.equal((await syncMockExamPresetsForExam(fakeSupa(tables), EXAM)).synced, 2);
  const na = tables.pb_export_presets.find((p) => p.render_config.mockExamMeta.elective === 'na');
  assert.equal(na.selected_question_uids.length, 30);
  assert.equal(na.selected_question_uids[10], 'uid-a-6');
  assert.equal(na.selected_question_ids[10], 'q-a-6');
  assert.deepEqual(na.source_document_ids, [DOC_NA]);
  assert.equal(na.render_config.questionScoreByQuestionUid['uid-a-6'], 4);
  assert.equal(na.render_config.questionScoreByQuestionUid['uid-b-12'], 3);
  // 가형 프리셋은 그대로 자기 문항 30개다.
  const ga = tables.pb_export_presets.find((p) => p.render_config.mockExamMeta.elective === 'ga');
  assert.equal(ga.selected_question_uids[5], 'uid-a-6');
  assert.equal(ga.render_config.questionScoreByQuestionUid['uid-a-6'], 3);

  // 문항을 가진 가형이 아직 확정 전이면 나형은 29문항이라 프리셋을 만들지 않는다.
  const pending = build({ mock_review: { publish_on_confirm: true, published_at: null } });
  assert.equal((await syncMockExamPresetsForExam(fakeSupa(pending), EXAM)).synced, 0);
});

test('mockSectionScope reads the paper and the page range from the cropped items', () => {
  const items = [
    { section: 'common', paper_id: 'p1', raw_page: 3 },
    { section: 'common', paper_id: 'p1', raw_page: 1 },
    { section: 'common', paper_id: null, raw_page: 9 },
    { section: 'calculus', paper_id: 'p2', raw_page: 10 },
  ];
  const papers = [{ id: 'p1' }, { id: 'p2' }];
  assert.deepEqual(mockSectionScope('e1', 'common', items, papers), {
    exam_id: 'e1',
    section: 'common',
    paper_id: 'p1',
    raw_page_from: 1,
    raw_page_to: 3,
  });
  assert.equal(mockSectionScope('e1', 'geometry', items, papers), null);
  assert.equal(mockSectionScope('e1', 'calculus', items, [{ id: 'p1' }]), null);
});

test('prepareMockReview refuses documents that are not a mock section', async () => {
  const res = await prepare(reviewTables(), 'd0000000-0000-4000-8000-000000000009');
  assert.deepEqual([res.ok, res.status, res.error], [false, 400, 'not_mock_section']);
});

// ── 검수 범위 만들기 ──────────────────────────────────────────────────────

test('mockExpectedSections lists the sections that have a problem paper or a document', () => {
  const paper = (kind, elective) => ({ kind, elective });
  assert.deepEqual(mockExpectedSections({ grade: 3 }, [paper('problem', 'calculus'), paper('solution', 'geometry')], []), [
    'common',
    'calculus',
  ]);
  assert.deepEqual(mockExpectedSections({ grade: 1 }, [paper('problem', '')], []), ['common']);
  // 가형·나형 회차: 공통 구간 없이 유형마다 구간 하나.
  assert.deepEqual(mockExpectedSections({ grade: 3 }, [paper('problem', 'na'), paper('problem', 'ga')], []), ['ga', 'na']);
  assert.deepEqual(mockExpectedSections({ grade: 3 }, [paper('problem', 'na'), paper('solution', 'ga')], []), ['na']);
  assert.deepEqual(
    mockExpectedSections({ grade: 3 }, [paper('problem', 'probstats')], [{ section: 'geometry', pb_document_id: 'x' }]),
    ['common', 'probstats', 'geometry'],
  );
  const papers = [
    { id: 'c', kind: 'problem', elective: 'calculus' },
    { id: 'p', kind: 'problem', elective: 'probstats' },
  ];
  assert.equal(mockSectionPaper(3, 'common', papers).id, 'p');
  assert.equal(mockSectionPaper(3, 'calculus', papers).id, 'c');
  assert.equal(mockSectionPaper(3, 'geometry', papers), null);
});

function identity(tables) {
  return prepareMockReviewIdentity({ supa: fakeSupa(tables), academyId: ACADEMY, examId: EXAM, retryDelaysMs: [] });
}

test('prepareMockReviewIdentity returns the review scopes of an extracted exam', async () => {
  const tables = reviewTables();
  const res = await identity(tables);
  assert.equal(res.ok, true);
  assert.equal(res.title, '2025 고3 10월 교육청');
  assert.equal(res.created, 0);
  assert.deepEqual(
    res.sections.map((s) => [s.section, s.label, s.documentId, s.gradeLabel, s.questionCount, s.publishedCount, s.publishOnConfirm]),
    [
      ['common', '공통', DOC_COMMON, '대수+미적분1', 3, 3, false],
      ['probstats', '확률과 통계', DOC_PROB, '확률과 통계', 2, 2, false],
    ],
  );
  assert.equal(tables.pb_documents.length, 2);
  assert.deepEqual(
    tables.resource_files.map((r) => [r.id, r.category, r.is_published]),
    [
      [DOC_COMMON, 'mock_past', false],
      [DOC_PROB, 'mock_past', false],
    ],
  );
});

test('prepareMockReviewIdentity creates section documents for an exam that was not extracted yet', async () => {
  const tables = reviewTables();
  tables.mock_exams[0].status = 'draft';
  tables.mock_exam_sections = [];
  tables.pb_documents = [];
  tables.pb_questions = [];
  tables.pb_extract_jobs = [];
  const res = await identity(tables);
  assert.equal(res.created, 2);
  assert.deepEqual(
    res.sections.map((s) => [s.section, s.questionCount, s.publishOnConfirm]),
    [
      ['common', 0, true],
      ['probstats', 0, true],
    ],
  );
  const docs = tables.pb_documents;
  assert.deepEqual(
    docs.map((d) => [d.source_filename, d.status, d.source_type_code, d.course_key, d.source_pdf_storage_path, d.meta.mock_review.publish_on_confirm]),
    [
      ['2025 고3 10월 교육청 · 공통', 'uploaded', 'mock_past', '', 'mock/problem.pdf', true],
      ['2025 고3 10월 교육청 · 확률과 통계', 'uploaded', 'mock_past', 'H-probstats', 'mock/problem.pdf', true],
    ],
  );
  assert.deepEqual(
    tables.mock_exam_sections.map((l) => [l.section, l.pb_document_id, l.extract_job_id]),
    [
      ['common', docs[0].id, null],
      ['probstats', docs[1].id, null],
    ],
  );
  // 다시 불러도 문서를 더 만들지 않는다.
  const again = await identity(tables);
  assert.equal(again.created, 0);
  assert.equal(tables.pb_documents.length, 2);
  assert.deepEqual(
    again.sections.map((s) => s.documentId),
    docs.map((d) => d.id),
  );
});

test('prepareMockReviewIdentity does not create documents while the exam is being extracted', async () => {
  const tables = reviewTables();
  tables.mock_exams[0].status = 'running';
  tables.mock_exam_sections = [];
  tables.pb_documents = [];
  const res = await identity(tables);
  assert.deepEqual([res.ok, res.status, res.error], [false, 409, 'exam_extracting']);
  assert.equal(tables.pb_documents.length, 0);

  const missing = reviewTables();
  missing.mock_exam_papers = missing.mock_exam_papers.filter((p) => p.kind !== 'problem');
  const none = await identity(missing);
  assert.deepEqual([none.ok, none.error], [false, 'problem_paper_missing']);
});
