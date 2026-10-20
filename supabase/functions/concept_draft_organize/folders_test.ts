import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider } from '../_shared/ai/fake.ts';
import { displayPageOf, masksFromCrops, sameMasks } from '../_shared/concept_book.ts';
import {
  buildFolderPrompt,
  checkFolderPlan,
  CONCEPT_FOLDER_SCHEMA,
  libraryOutline,
  parseFolderPlan,
  pendingDraftOf,
} from './folders.ts';
import { proposeConceptFolders } from './run.ts';

const categories = [
  { id: 'r1', name: '대수', parent_id: null, code: 'ALG' },
  { id: 'r2', name: '기하', parent_id: null, code: 'GEOM' },
  { id: 'c1', name: '수와 연산', parent_id: 'r1' },
  { id: 'c2', name: '약수와 배수', parent_id: 'c1' },
  { id: 's1', name: '바로가기', parent_id: 'r1', code: 'SHORTCUT' },
  { id: 'o1', name: '부모 없음', parent_id: 'gone' },
];

Deno.test('라이브러리 개요: 영역부터 시작하는 경로만, 바로가기·끊긴 폴더는 뺀다', () => {
  const outline = libraryOutline(categories, [
    { main_category_id: 'c2', name: '약수' },
    { main_category_id: 'c2', name: '배수' },
  ]);
  assertEquals(outline.roots, ['대수', '기하']);
  assertEquals(outline.folders.map((f) => f.path), [['대수', '수와 연산'], ['대수', '수와 연산', '약수와 배수']]);
  assertEquals(outline.folders[1].count, 2);
});

Deno.test('폴더 지시문: 교재 단원은 참고로만 주고, 기존 폴더와 개념을 함께 준다', () => {
  const outline = libraryOutline(categories, []);
  const p = buildFolderPrompt({
    outline,
    unitPath: ['소인수분해', '소수와 합성수'],
    concepts: [{ index: 0, title: '소수', concept_type: 'definition', content: '1보다 큰 자연수 중…' }],
  });
  assert(p.instructions.includes('참고일 뿐'));
  assert(p.userText.includes('대수 > 수와 연산 > 약수와 배수'));
  assert(p.userText.includes('교재 단원(참고만): 소인수분해 > 소수와 합성수'));
  assert(p.userText.includes('[0] 소수'));
});

Deno.test('폴더 제안 검사: 영역 밖·빠진·겹친 개념과 새로 만들 폴더를 찾는다', () => {
  const outline = libraryOutline(categories, []);
  const plan = parseFolderPlan(JSON.stringify({
    notes: '수와 연산 아래에 둡니다.',
    folders: [{ path: ['대수', '수와 연산', '소인수분해'], reason: '약수와 배수 옆' }, { path: ['대수'], reason: '짧음' }],
    placements: [
      { concept: 0, path: ['대수', '수와 연산', '소인수분해'], reason: '' },
      { concept: 0, path: ['대수', '수와 연산'], reason: '' },
      { concept: 1, path: ['수', '소수'], reason: '' },
      { concept: 2, path: [' 대수 ', '수와 연산', '약수와 배수'], reason: '' },
      { concept: 9, path: ['대수', 'x'], reason: '' },
    ],
  }));
  assert(plan);
  assertEquals(plan.folders.length, 1);
  const checks = checkFolderPlan(plan, outline, 4);
  assertEquals(checks.duplicate, [0]);
  assertEquals(checks.unknown_root, [1]);
  assertEquals(checks.unplaced, [1, 3]);
  assertEquals(checks.new_folders, [['대수', '수와 연산', '소인수분해']]);
  assertEquals(parseFolderPlan('폴더는'), null);
});

Deno.test('다른 초안의 자리: 검토를 저장했으면 운영자 폴더(뺀 것 제외), 아니면 AI 제안', () => {
  const titles = [{ title: '소수' }, { title: '합성수' }, { title: '' }];
  const ai = pendingDraftOf({
    unit_path: ['소인수분해', '소수와 합성수'],
    draft_concepts: titles,
    placements: [
      { concept: 0, path: ['대수', '수와 연산', '소인수분해'] },
      { concept: 0, path: ['대수', '다른 곳'] },
      { concept: 1, path: ['대수'] },
      { concept: 2, path: ['대수', '수와 연산'] },
    ],
  });
  assertEquals(ai, { unit: '소수와 합성수', concepts: [{ title: '소수', path: ['대수', '수와 연산', '소인수분해'] }] });
  const reviewed = pendingDraftOf({
    unit_path: ['소인수분해'],
    review_saved_at: '2026-10-17T00:00:00Z',
    draft_concepts: titles,
    placements: [{ concept: 0, path: ['대수', 'AI 자리'] }],
    review_concepts: [
      { title: '소수(고침)', mark: 'edit', folder: ['대수', '수와 연산', '소수'] },
      { title: '합성수', mark: 'drop', folder: ['대수', '수와 연산', '소수'] },
    ],
  });
  assertEquals(reviewed?.concepts, [{ title: '소수(고침)', path: ['대수', '수와 연산', '소수'] }]);
  assertEquals(pendingDraftOf({ unit_path: [], draft_concepts: titles, placements: null }), null);
});

Deno.test('폴더 지시문: 다른 초안의 자리와 그중 라이브러리에 없는 폴더를 따로 보여 준다', () => {
  const outline = libraryOutline(categories, []);
  const p = buildFolderPrompt({
    outline,
    unitPath: ['소인수분해', '소인수분해하기'],
    concepts: [{ index: 0, title: '소인수분해', concept_type: 'definition', content: '' }],
    pending: [{ unit: '소수와 합성수', concepts: [{ title: '소수', path: ['대수', '수와 연산', '소인수분해'] }] }],
  });
  assert(p.instructions.includes('이미 있는 폴더처럼'));
  assert(p.userText.includes('- 초안 소수와 합성수: 소수 → 대수 > 수와 연산 > 소인수분해'));
  const fresh = p.userText.split('라이브러리에 아직 없는 폴더')[1];
  assert(fresh.includes('- 대수 > 수와 연산 > 소인수분해'));
  assert(!fresh.includes('- 대수 > 수와 연산\n'));
  assert(!buildFolderPrompt({ outline, unitPath: [], concepts: [] }).userText.includes('검토 중인 다른 초안'));
});

Deno.test('겹침: 번호·이름이 있는 것만, 개념마다 같은 상대는 한 번, 최대 3개', () => {
  const plan = parseFolderPlan(JSON.stringify({
    notes: '',
    folders: [],
    placements: [],
    overlaps: [
      { concept: 0, other: '초안 소수와 합성수: 소수', reason: '같은 정의' },
      { concept: 0, other: '초안 소수와 합성수: 소수', reason: '중복' },
      { concept: 0, other: 'a', reason: '' },
      { concept: 0, other: 'b', reason: '' },
      { concept: 0, other: 'c', reason: '' },
      { concept: 1, other: ' ', reason: '' },
      { concept: -1, other: 'x', reason: '' },
    ],
  }));
  assertEquals(plan?.overlaps.map((o) => o.other), ['초안 소수와 합성수: 소수', 'a', 'b']);
  assertEquals(parseFolderPlan(JSON.stringify({ notes: '', folders: [], placements: [] }))?.overlaps, []);
});

Deno.test('폴더 제안 형식은 strict 조건을 지킨다', () => {
  const walk = (s: Record<string, unknown>) => {
    if (s.type === 'object') {
      assertEquals(s.additionalProperties, false);
      assertEquals([...(s.required as string[])].sort(), Object.keys(s.properties as object).sort());
      for (const v of Object.values(s.properties as Record<string, Record<string, unknown>>)) walk(v);
    }
    if (s.type === 'array') walk(s.items as Record<string, unknown>);
  };
  walk(CONCEPT_FOLDER_SCHEMA);
});

Deno.test('폴더 제안 실행: 형식을 붙여 부르고 검사를 붙인다', async () => {
  const outline = libraryOutline(categories, []);
  const text = JSON.stringify({
    notes: 'n',
    folders: [],
    placements: [{ concept: 0, path: ['대수', '수와 연산'], reason: 'r' }],
    overlaps: [{ concept: 0, other: '라이브러리 소수', reason: '' }, { concept: 5, other: '없는 번호', reason: '' }],
  });
  const provider = new FakeAiProvider([{ text }]);
  const out = await proposeConceptFolders(provider, {
    model: 'gpt-test',
    reasoningEffort: 'medium',
    outline,
    unitPath: [],
    concepts: [{ index: 0, title: '소수', concept_type: 'definition', content: '' }],
  });
  assertEquals(out.error, null);
  assertEquals(provider.requests[0].jsonSchema?.name, 'concept_folder_plan');
  assertEquals(out.checks?.unplaced, []);
  assertEquals(out.plan?.overlaps.map((o) => o.concept), [0]);
  const bad = await proposeConceptFolders(new FakeAiProvider([{ text: '문장' }]), {
    model: 'gpt-test',
    reasoningEffort: 'medium',
    outline,
    unitPath: [],
    concepts: [],
  });
  assertEquals(bad.error, 'invalid_output');
});

Deno.test('가림 영역: 문항 영역(없으면 문항 상자)을 왼쪽 단부터 위에서 아래로 이름 붙인다', () => {
  const masks = masksFromCrops([
    { raw_page: 8, item_region_1k: [600, 520, 800, 950], problem_number: '0003', display_page: 8 },
    { raw_page: 8, item_region_1k: null, bbox_1k: [100, 50, 300, 480], problem_number: '0001' },
    { raw_page: 8, item_region_1k: [400, 50, 500, 480], problem_number: '' },
    { raw_page: 8, item_region_1k: [500, 50, 400, 480] },
  ]);
  assertEquals(masks, [
    { label: 'M1', bbox_1k: [100, 50, 300, 480], problem_number: '0001' },
    { label: 'M2', bbox_1k: [400, 50, 500, 480] },
    { label: 'M3', bbox_1k: [600, 520, 800, 950], problem_number: '0003' },
  ]);
  assert(sameMasks(masks, masks.map((m) => ({ ...m }))));
  assert(!sameMasks(masks, masks.slice(1)));
  assert(!sameMasks(masks, [{ ...masks[0], bbox_1k: [101, 50, 300, 480] }, masks[1], masks[2]]));
  assertEquals(displayPageOf([{ display_page: null }, { display_page: 8 }]), 8);
});
