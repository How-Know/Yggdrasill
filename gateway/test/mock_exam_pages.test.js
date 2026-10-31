import { strict as assert } from 'node:assert';
import { test } from 'node:test';

import {
  assignProblemItems,
  assignSolutionSections,
  electiveStartPageFromText,
  expectedNumbers,
  normalizeAnswer,
  normalizeProblemPage,
  normalizeSolutionPage,
  sectionFromLabel,
} from '../src/mock_exam/mock_pages.js';
import { buildPrompt } from '../src/problem_bank/extract_engines/vlm/prompt.js';

test('구간 이름과 정답 표기를 맞춘다', () => {
  assert.equal(sectionFromLabel('[선택: 확률과 통계]'), 'probstats');
  assert.equal(sectionFromLabel('■ [선택: 미적분]'), 'calculus');
  assert.equal(sectionFromLabel('기하'), 'geometry');
  assert.equal(sectionFromLabel('[공통: 수학Ⅰ·수학Ⅱ]'), 'common');
  assert.equal(sectionFromLabel('정답'), '');
  assert.deepEqual(normalizeAnswer('⑤'), { kind: 'objective', text: '⑤' });
  assert.deepEqual(normalizeAnswer('(3)'), { kind: 'objective', text: '③' });
  assert.deepEqual(normalizeAnswer(' 64 '), { kind: 'subjective', text: '64' });
  assert.equal(normalizeAnswer(''), null);
});

test('학년별 기대 번호: 고3 공통 22·선택 8, 고1·고2 30', () => {
  assert.equal(expectedNumbers(3, 'common').length, 22);
  assert.deepEqual(expectedNumbers(3, 'calculus'), [23, 24, 25, 26, 27, 28, 29, 30]);
  assert.equal(expectedNumbers(1, 'common').length, 30);
  assert.deepEqual(expectedNumbers(2, 'probstats'), []);
});

test('문제지: 공통은 첫 문제지에서만, 선택 문항은 지면 선택과목으로 간다', () => {
  const page = (number, title) => ({
    page: number <= 22 ? 1 : 9,
    result: normalizeProblemPage({
      page_title: title,
      items: [{ number, region: [100, 50, 400, 480] }],
    }),
  });
  const first = assignProblemItems({
    grade: 3,
    paperElective: 'probstats',
    pages: [page(1, '수학 영역'), page(23, '수학 영역(확률과 통계)')],
    takeCommon: true,
  });
  assert.deepEqual(first.map((i) => `${i.section}${i.number}`), ['common1', 'probstats23']);
  const second = assignProblemItems({
    grade: 3,
    paperElective: 'calculus',
    pages: [page(1, '수학 영역'), page(23, '수학 영역(미적분)')],
    takeCommon: false,
  });
  assert.deepEqual(second.map((i) => `${i.section}${i.number}`), ['calculus23']);
  const g1 = assignProblemItems({
    grade: 1,
    paperElective: '',
    pages: [page(25, '수학 영역')],
    takeCommon: true,
  });
  assert.deepEqual(g1.map((i) => `${i.section}${i.number}`), ['common25']);
});

test('문제지 판독: 좌표가 없거나 겹친 번호는 버린다', () => {
  const out = normalizeProblemPage({
    items: [
      { number: '3.', region: [10, 520, 300, 980] },
      { number: 3, region: [310, 520, 600, 980] },
      { number: 4, region: [1, 2, 3] },
    ],
  });
  assert.deepEqual(out.items.map((i) => i.number), [3]);
});

test('해설: 공통 정답 상자와 선택 정답 상자, 해설 시작점을 구간에 배정한다', () => {
  // 2024 수능 확통 해설 1쪽·12쪽 모양.
  const p1 = normalizeSolutionPage({
    answer_tables: [
      {
        label: '[공통: 수학Ⅰ·수학Ⅱ]',
        region: [60, 40, 200, 480],
        entries: [
          { number: 1, answer: '⑤' },
          { number: 16, answer: '7' },
        ],
      },
    ],
    blocks: [
      { number: 1, number_region: [300, 40, 320, 60], content_region: [300, 40, 600, 480] },
      { number: 3, number_region: [60, 520, 80, 540], content_region: [60, 520, 500, 980] },
    ],
  });
  const p12 = normalizeSolutionPage({
    answer_tables: [
      {
        label: '[선택: 확률과 통계]',
        region: [60, 40, 160, 480],
        entries: [
          { number: 23, answer: '⑤' },
          { number: 30, answer: '19' },
        ],
      },
    ],
    blocks: [
      { number: 23, number_region: [300, 40, 320, 60], content_region: [300, 40, 500, 480] },
      { number: 25, number_region: [100, 520, 120, 540], content_region: [100, 520, 400, 980] },
    ],
  });
  const { answers, solutions } = assignSolutionSections({
    grade: 3,
    paperElective: 'probstats',
    pages: [
      { page: 1, result: p1 },
      { page: 12, result: p12 },
    ],
  });
  assert.equal(answers.get('common|1').text, '⑤');
  assert.equal(answers.get('common|16').kind, 'subjective');
  assert.equal(answers.get('probstats|30').text, '19');
  assert.equal(solutions.get('common|3').page, 1);
  assert.equal(solutions.get('probstats|25').page, 12);
});

test('해설 한 권에 세 선택과목이 다 있으면 머리마다 구간이 바뀐다', () => {
  const block = (number, y, x = 40) => ({
    number,
    number_region: [y, x, y + 20, x + 20],
    content_region: [y, x, y + 200, x + 440],
  });
  const pages = [
    {
      page: 12,
      result: normalizeSolutionPage({
        section_headers: [{ label: '■ [선택: 확률과 통계]', region: [40, 40, 60, 480] }],
        blocks: [block(23, 100)],
      }),
    },
    {
      page: 14,
      result: normalizeSolutionPage({
        blocks: [block(30, 100)],
        section_headers: [{ label: '■ [선택: 미적분]', region: [400, 40, 420, 480] }],
      }),
    },
    {
      page: 15,
      result: normalizeSolutionPage({
        blocks: [block(23, 100), block(24, 600)],
      }),
    },
    {
      page: 17,
      result: normalizeSolutionPage({
        section_headers: [{ label: '기하', region: [40, 520, 60, 980] }],
        blocks: [block(30, 100), block(23, 100, 520)],
      }),
    },
  ];
  // 미적분 해설지라도 머리가 앞서므로 확통 해설이 확통에 들어간다.
  const { solutions } = assignSolutionSections({ grade: 3, paperElective: 'calculus', pages });
  assert.equal(solutions.get('probstats|23').page, 12);
  assert.equal(solutions.get('probstats|30').page, 14);
  assert.equal(solutions.get('calculus|23').page, 15);
  assert.equal(solutions.get('calculus|30').page, 17);
  assert.equal(solutions.get('geometry|23').page, 17);
});

test('고1·고2 해설은 머리와 상관없이 모두 공통이다', () => {
  const { answers } = assignSolutionSections({
    grade: 2,
    pages: [
      {
        page: 1,
        result: normalizeSolutionPage({
          answer_tables: [
            { label: '', region: [60, 40, 200, 480], entries: [{ number: 29, answer: '12' }] },
          ],
        }),
      },
    ],
  });
  assert.equal(answers.get('common|29').text, '12');
});

test('해설 텍스트에서 선택과목 시작 쪽을 찾는다', () => {
  const texts = ['■ [공통: 수학Ⅰ·수학Ⅱ]', '...', '■ [선택: 확률과 통계]\n23. 출제의도'];
  assert.equal(electiveStartPageFromText(texts, 'probstats'), 3);
  assert.equal(electiveStartPageFromText(texts, 'geometry'), null);
});

test('문제은행 추출 프롬프트에 모의고사 규칙이 실린다', () => {
  const prompt = buildPrompt({
    mockScope: { exam_id: 'e', section: 'common', raw_page_from: 1, raw_page_to: 2 },
    expectedQuestionNumbers: ['1', '2'],
  });
  assert.match(prompt, /모의고사 문제지 추출 범위/);
  assert.doesNotMatch(prompt, /교재 소단원 추출 범위/);
});
