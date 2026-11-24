// AI 가 빠뜨린 해설 시작점 채우기(solution_anchor.js). 2026 고3 3월: 해설 1쪽 셋째 단의 12·13·14번.
import test from 'node:test';
import assert from 'node:assert/strict';

import { assignSolutionSections, buildSolutionPagePrompt } from '../src/mock_exam/mock_pages.js';
import {
  addMissingSolutionBlocks,
  fillMissingSolutionBlocks,
  mergeRereadBlocks,
  missingSolutionKeys,
  pagesToReread,
  solutionHeadsFromWords,
  solutionSectionsOfPaper,
} from '../src/mock_exam/solution_anchor.js';

// 좌표가 곧 0..1000 값인 낱말 상자
function word(text, xMin, yMin, width = 14) {
  return { text, xMin, yMin, xMax: xMin + width, yMax: yMin + 10 };
}

// "12. [출제의도] 수열의 합" 한 줄
function headWords(number, x, y) {
  return [word(`${number}.`, x, y), word('[출제의도]', x + 19, y, 50), word('이해하기', x + 75, y, 40)];
}

function block(number, y, x, bottom = y + 60) {
  return { number, numberRegion: [y, x, y + 9, x + 15], contentRegion: [y, x, bottom, x + 250] };
}

function evidenceOf(wordsByPage) {
  return { hasText: true, words: (page) => wordsByPage[page] || [] };
}

// 3월 해설지와 같은 꼴: 1쪽은 3단인데 AI 가 셋째 단(12·13·14)을 읽지 못했다.
function marchPages() {
  return [
    {
      page: 1,
      result: {
        answerTables: [],
        headers: [],
        blocks: [
          block(1, 357, 104), block(2, 393, 104), block(3, 443, 104), block(4, 508, 104),
          block(5, 611, 104), block(6, 686, 104), block(7, 802, 104, 900),
          block(8, 168, 372), block(9, 258, 372), block(10, 457, 372), block(11, 696, 372, 900),
        ],
      },
    },
    {
      page: 2,
      result: {
        answerTables: [],
        headers: [],
        blocks: [
          block(15, 500, 104), block(16, 664, 372), block(17, 732, 372), block(18, 812, 372),
          block(19, 886, 372), block(20, 320, 641), block(21, 646, 641),
        ],
      },
    },
    {
      page: 3,
      result: {
        answerTables: [],
        headers: [],
        blocks: [
          block(22, 493, 104),
          block(23, 293, 372), block(24, 323, 372), block(25, 387, 372), block(26, 592, 372), block(27, 748, 372),
          block(28, 252, 641), block(29, 576, 641), block(30, 721, 641),
        ],
      },
    },
  ];
}

// 글자 층: AI 가 찾은 번호도 그대로 적혀 있다(좌표가 조금 어긋난다).
function marchWords({ without = [] } = {}) {
  const heads = [
    [1, 104, 357], [7, 104, 802], [8, 372, 168], [11, 372, 697],
    [12, 641, 148], [13, 641, 442], [14, 641, 628],
  ].filter(([n]) => !without.includes(n));
  return { 1: heads.flatMap(([n, x, y]) => headWords(n, x, y)) };
}

const assignMarch = (pages) => assignSolutionSections({ grade: 3, paperElective: 'probstats', pages }).solutions;

test('solutionHeadsFromWords: 번호 뒤에 "출제의도"가 오는 낱말만 해설 머리다', () => {
  const words = [
    ...headWords(12, 641, 148),
    word('13.[출제의도]', 641, 442, 60),
    word('14.', 104, 300), word('출제의도', 123, 300, 40), word(':', 165, 300, 4),
    // 풀이 안의 번호 꼴 글자들
    word('3.', 104, 500), word('따라서', 123, 500, 30),
    word('3.14', 372, 500, 20),
    word('31.', 372, 600), word('[출제의도]', 391, 600, 50),
    // 번호와 "[출제의도]" 가 다른 줄
    word('5.', 372, 700), word('[출제의도]', 391, 730, 50),
  ];
  assert.deepEqual(
    solutionHeadsFromWords(words).map((h) => [h.number, h.region]),
    [
      [14, [300, 104, 310, 118]],
      [12, [148, 641, 158, 655]],
      [13, [442, 641, 452, 701]],
    ],
  );
  assert.deepEqual(solutionHeadsFromWords(null), []);
});

test('addMissingSolutionBlocks: 빠진 단의 번호를 글자 층 자리로 넣고 영역은 다음 번호 위까지 잡는다', () => {
  const pages = marchPages();
  const before = JSON.stringify(pages);
  const res = addMissingSolutionBlocks({ pages, evidence: evidenceOf(marchWords()), numbers: [12, 13, 14] });
  assert.deepEqual(res.added, [{ page: 1, number: 12 }, { page: 1, number: 13 }, { page: 1, number: 14 }]);
  const of = (n) => res.pages[0].result.blocks.find((b) => b.number === n);
  assert.deepEqual(of(12), { number: 12, numberRegion: [148, 641, 158, 655], contentRegion: [148, 641, 441, 891] });
  assert.deepEqual(of(13).contentRegion, [442, 641, 627, 891]);
  // 단의 마지막 번호는 그 쪽 해설이 끝나는 높이까지
  assert.deepEqual(of(14).contentRegion, [628, 641, 900, 891]);
  // 다른 블록과 받은 목록은 그대로다.
  assert.equal(res.pages[0].result.blocks.length, 14);
  assert.deepEqual(of(11), block(11, 696, 372, 900));
  assert.equal(JSON.stringify(pages), before);
  assert.equal(res.pages[1], pages[1]);
});

test('addMissingSolutionBlocks: 찾는 번호가 아니거나 AI 가 이미 찾은 자리는 넣지 않는다', () => {
  const pages = marchPages();
  // 11번은 글자 층 좌표(697)와 AI 좌표(696)가 조금 다르지만 같은 자리다.
  const res = addMissingSolutionBlocks({ pages, evidence: evidenceOf(marchWords()), numbers: [11, 13] });
  assert.deepEqual(res.added, [{ page: 1, number: 13 }]);
  // 글자 층이 없으면 아무것도 하지 않는다.
  const none = addMissingSolutionBlocks({ pages, evidence: { hasText: false, words: () => null }, numbers: [12] });
  assert.deepEqual(none.added, []);
  assert.equal(none.pages, pages);
});

test('addMissingSolutionBlocks: 같은 단 위쪽 블록이 새 번호를 넘어가 있으면 그 위에서 끊는다', () => {
  const pages = marchPages();
  pages[0].result.blocks.push(block(12, 148, 641, 900));
  const res = addMissingSolutionBlocks({ pages, evidence: evidenceOf(marchWords()), numbers: [13, 14] });
  const of = (n) => res.pages[0].result.blocks.find((b) => b.number === n);
  assert.deepEqual(of(12).contentRegion, [148, 641, 441, 891]);
  assert.deepEqual(of(13).contentRegion, [442, 641, 627, 891]);
});

test('missingSolutionKeys · solutionSectionsOfPaper: 해설지가 맡는 구간에서 시작점이 없는 번호', () => {
  const found = assignMarch(marchPages());
  const sections = solutionSectionsOfPaper({ grade: 3, paperElective: 'probstats', fromFirstPage: true, found });
  assert.deepEqual(sections, ['common', 'probstats']);
  assert.deepEqual(missingSolutionKeys({ grade: 3, sections, found }), [
    { section: 'common', number: 12 },
    { section: 'common', number: 13 },
    { section: 'common', number: 14 },
  ]);
  // 앞 해설지에서 이미 찾은 번호는 빠진 것이 아니다.
  const known = new Map([['common|13', {}]]);
  assert.deepEqual(
    missingSolutionKeys({ grade: 3, sections, found, known }).map((m) => m.number),
    [12, 14],
  );
  // 둘째 해설지는 공통을 맡지 않는다. 선택과목만 뽑을 때는 그 과목만.
  assert.deepEqual(
    solutionSectionsOfPaper({ grade: 3, paperElective: 'calculus', fromFirstPage: false, found: new Map() }),
    ['calculus'],
  );
  assert.deepEqual(
    solutionSectionsOfPaper({ grade: 3, paperElective: 'probstats', fromFirstPage: false, only: new Set(['geometry']), found }),
    [],
  );
  assert.deepEqual(solutionSectionsOfPaper({ grade: 1, found: new Map() }), ['common']);
  // 가형·나형 해설지는 첫 해설지여도 그 유형 구간(1~30번)만 맡는다.
  const ga = solutionSectionsOfPaper({ grade: 3, paperElective: 'ga', fromFirstPage: true, found: new Map() });
  assert.deepEqual(ga, ['ga']);
  assert.equal(missingSolutionKeys({ grade: 3, sections: ga, found: new Map([['ga|1', {}]]) }).length, 29);
  assert.deepEqual(
    solutionSectionsOfPaper({ grade: 3, paperElective: 'na', fromFirstPage: false, only: new Set(['ga']), found: new Map() }),
    [],
  );
});

test('pagesToReread: 앞 번호가 있는 쪽부터 뒤 번호가 있는 쪽까지만 다시 읽는다', () => {
  const found = assignMarch(marchPages());
  assert.deepEqual(
    pagesToReread({ missing: [{ section: 'common', number: 13 }], found, pageNumbers: [1, 2, 3] }),
    [1, 2],
  );
  // 앞뒤 번호를 하나도 못 찾은 구간은 다시 읽지 않는다.
  assert.deepEqual(
    pagesToReread({ missing: [{ section: 'geometry', number: 25 }], found, pageNumbers: [1, 2, 3] }),
    [],
  );
  // 마지막 번호가 빠졌으면 앞 번호 쪽과 그다음 쪽
  const short = new Map([...found].filter(([key]) => key !== 'probstats|30'));
  assert.deepEqual(
    pagesToReread({ missing: [{ section: 'probstats', number: 30 }], found: short, pageNumbers: [1, 2, 3, 4] }),
    [3, 4],
  );
});

test('fillMissingSolutionBlocks: 빠진 번호가 없으면 근거도 AI 도 부르지 않는다', async () => {
  const pages = marchPages();
  pages[0].result.blocks.push(block(12, 148, 641), block(13, 442, 641), block(14, 628, 641));
  let calls = 0;
  const res = await fillMissingSolutionBlocks({
    grade: 3,
    paperElective: 'probstats',
    pages,
    assign: assignMarch,
    loadEvidence: async () => { calls += 1; return evidenceOf({}); },
    reread: async () => { calls += 1; return []; },
  });
  assert.equal(calls, 0);
  assert.equal(res.pages, pages);
  assert.deepEqual([res.textLayer, res.reread, res.missing, res.errors], [[], [], [], []]);
});

test('fillMissingSolutionBlocks: 글자 층에서 다 찾으면 AI 로 다시 읽지 않는다', async () => {
  let rereads = 0;
  const res = await fillMissingSolutionBlocks({
    grade: 3,
    paperElective: 'probstats',
    pages: marchPages(),
    assign: assignMarch,
    loadEvidence: async () => evidenceOf(marchWords()),
    reread: async () => { rereads += 1; return []; },
  });
  assert.equal(rereads, 0);
  assert.deepEqual(res.textLayer.map((a) => a.number), [12, 13, 14]);
  assert.deepEqual(res.missing, []);
  const found = assignMarch(res.pages);
  assert.deepEqual(found.get('common|13').numberRegion, [442, 641, 452, 655]);
  assert.equal(found.get('common|13').page, 1);
  assert.equal(found.size, 30);
});

test('fillMissingSolutionBlocks: 글자 층에 없는 번호만 앞뒤 쪽을 한 번 더 읽어 넣는다', async () => {
  const asked = [];
  const res = await fillMissingSolutionBlocks({
    grade: 3,
    paperElective: 'probstats',
    pages: marchPages(),
    assign: assignMarch,
    loadEvidence: async () => evidenceOf(marchWords({ without: [14] })),
    reread: async (pages, numbers) => {
      asked.push({ pages, numbers });
      return [
        // 다시 읽은 결과에는 이미 아는 번호도 들어 있다: 빠진 번호만 쓴다.
        { page: 1, result: { blocks: [block(11, 696, 372, 900), block(13, 442, 641), block(14, 628, 641, 900)] } },
        { page: 2, result: { blocks: [block(15, 500, 104)] } },
      ];
    },
  });
  assert.deepEqual(asked, [{ pages: [1, 2], numbers: [14] }]);
  assert.deepEqual(res.textLayer.map((a) => a.number), [12, 13]);
  assert.deepEqual(res.reread, [{ page: 1, number: 14 }]);
  assert.deepEqual(res.missing, []);
  const blocks = res.pages[0].result.blocks;
  assert.equal(blocks.filter((b) => b.number === 13).length, 1);
  assert.deepEqual(blocks.find((b) => b.number === 14).contentRegion, [628, 641, 900, 891]);
  // 13번 영역은 14번 위에서 끝난다.
  assert.deepEqual(blocks.find((b) => b.number === 13).contentRegion, [442, 641, 627, 891]);
});

test('fillMissingSolutionBlocks: 근거를 못 읽거나 다시 읽기가 실패해도 던지지 않고 못 채운 번호를 알린다', async () => {
  const res = await fillMissingSolutionBlocks({
    grade: 3,
    paperElective: 'probstats',
    pages: marchPages(),
    assign: assignMarch,
    loadEvidence: async () => { throw new Error('pdftoppm_failed'); },
    reread: async () => { throw new Error('gemini_down'); },
  });
  assert.deepEqual(res.missing.map((m) => m.number), [12, 13, 14]);
  assert.deepEqual(res.rereadPages, [1, 2]);
  assert.deepEqual(res.errors, ['evidence: pdftoppm_failed', 'reread: gemini_down']);
  assert.deepEqual(res.pages, marchPages());
});

test('mergeRereadBlocks: 다시 읽은 블록은 찾던 번호만, 없는 자리에만 넣는다', () => {
  const pages = marchPages();
  const res = mergeRereadBlocks({
    pages,
    reread: [{ page: 1, result: { blocks: [block(12, 150, 640, 440), block(9, 258, 372)] } }],
    numbers: [12, 9],
  });
  assert.deepEqual(res.added, [{ page: 1, number: 12 }]);
  assert.deepEqual(res.pages[0].result.blocks.find((b) => b.number === 12).contentRegion, [150, 640, 440, 890]);
});

test('buildSolutionPagePrompt: 다시 읽을 때만 못 찾은 번호를 알려 준다', () => {
  assert.doesNotMatch(buildSolutionPagePrompt({ grade: 3, page: 1 }), /찾지 못했다/);
  const prompt = buildSolutionPagePrompt({ grade: 3, page: 1, lookFor: [13, 14] });
  assert.match(prompt, /13, 14번 해설의 시작점을 찾지 못했다/);
  assert.match(prompt, /지어내지 않는다/);
});
