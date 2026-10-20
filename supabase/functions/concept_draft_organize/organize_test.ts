import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider } from '../_shared/ai/fake.ts';
import {
  acyclicAnchors,
  buildConceptDraftPrompt,
  checkConceptDraft,
  CONCEPT_DRAFT_SCHEMA,
  conceptTypeRefs,
  type ConceptTypeRef,
  criterionRefs,
  formulas,
  MAX_PAGES,
  parseConceptDraft,
  prepareUnit,
  readConceptDraftBody,
  type TranscriptBlock,
} from './organize.ts';
import { organizeConceptDraft } from './run.ts';

const TYPES: ConceptTypeRef[] = [
  { name: '정의', description: '뜻', legacy_sub_type: '정의' },
  { name: '성질', description: '사실', legacy_sub_type: '정리' },
  { name: '방법', description: '계산 절차', legacy_sub_type: '연산' },
];

function block(kind: string, text: string, bbox: number[], title = ''): TranscriptBlock {
  return { kind, title, text, bbox_1k: bbox, figure_description: '', uncertain: false };
}

const pageA = [
  block('page_furniture', '8 | 1. 소인수분해', [950, 70, 965, 160]),
  block('concept_box', '(1) 소수: $1$보다 큰 자연수 중에서 약수가 $1$과 자기 자신뿐인 수', [130, 160, 200, 780]),
  block('note', '• $2$는 유일하게 짝수인 소수이다.', [200, 160, 230, 510], '참고'),
  block('other', '(1) 모두', [860, 200, 880, 240]),
];
const pageB = [
  block('page_furniture', '8 | 1. 소인수분해', [950, 70, 965, 160]),
  block('concept_box', '(1) 소수: $1$보다 큰 자연수 중에서 약수가 $1$과 자기 자신뿐인 수', [131, 161, 199, 779]),
  block('note', '• $3$는 유일하게 짝수인 소수이다.', [201, 160, 231, 512], '참고'),
  block('figure', '에라토스테네스의 체', [360, 770, 440, 920]),
];

Deno.test('두 번 읽기 맞추기: 쪽 장식은 빼고, 글자가 다른 곳·한쪽에만 있는 블록을 찾는다', () => {
  const prepared = prepareUnit([{ raw_page: 8, display_page: 8, a: pageA, b: pageB }]);
  assertEquals(prepared.furniture.map((b) => b.id), ['p8-a0']);
  assertEquals(prepared.blocks.map((b) => b.id), ['p8-a1', 'p8-a2', 'p8-a3', 'p8-b3']);
  const byType = Object.fromEntries(prepared.disagreements.map((d) => [d.id, d.type]));
  assertEquals(byType['p8-a2'], 'text_differs');
  assertEquals(byType['p8-a3'], 'missing_in_b');
  assertEquals(byType['p8-b3'], 'only_in_b');
  assertEquals(byType['p8-a1'], undefined);
});

Deno.test('지시에 블록 id·다른 읽기·확정 기준과 초안이 구분되어 들어간다', () => {
  const prepared = prepareUnit([{ raw_page: 8, display_page: 8, a: pageA, b: pageB }]);
  const p = buildConceptDraftPrompt({
    bookName: '개념+유형',
    gradeLabel: '1-1',
    unitPath: ['수와 연산', '소인수분해', '소인수분해'],
    prepared,
    criteria: [
      { id: 'c1', title: '노드 분리 기준', body: '정의 하나가 노드 하나', version: 2, state: 'confirmed' },
      { id: 'c1', title: '노드 분리 기준', body: '고치는 중', version: 2, state: 'draft' },
    ],
    types: TYPES,
  });
  assert(p.userText.includes('[p8-a1] 8쪽 · concept_box'));
  assert(p.userText.includes('- 방법 (기존 구분 연산): 계산 절차'));
  assert(p.instructions.includes('new_types'));
  assert(p.userText.includes('두 번째 읽기에만 있음'));
  assert(p.userText.includes('노드 분리 기준 (확정 v2)'));
  assert(p.userText.includes('확정 전 초안(참고만)'));
  assert(!p.userText.includes('8 | 1. 소인수분해'));
  const none = buildConceptDraftPrompt({ bookName: 'x', gradeLabel: '1-1', unitPath: [], prepared, criteria: [], types: [] });
  assert(none.userText.includes('확정 기준: 없음'));
  assert(none.userText.includes('개념 유형 목록: 없음'));
});

Deno.test('기준 행: 확정 전 항목은 초안으로만, 확정본과 저장된 초안은 따로 들어간다', () => {
  const refs = criterionRefs([
    { id: 'a', title: '확정만', body: '본문', version: 1, draft_body: null, draft_saved_at: null },
    { id: 'b', title: '', body: '', version: 0, draft_title: '새 기준', draft_body: '초안 본문', draft_saved_at: '2026-10-16T00:00:00Z' },
  ]);
  assertEquals(refs.map((r) => [r.id, r.state, r.title]), [['a', 'confirmed', '확정만'], ['b', 'draft', '새 기준']]);
});

Deno.test('검사: 없는 id, 처리 안 된 블록, 근거 블록에 없는 수식, 근거 없는 개념을 찾는다', () => {
  const prepared = prepareUnit([{ raw_page: 8, display_page: 8, a: pageA, b: pageB }]);
  const checks = checkConceptDraft(
    {
      summary: '',
      concepts: [
        {
          title: '소수',
          concept_type: '정의',
          content: '$1$보다 큰 자연수 중에서 약수가 $1$과 자기 자신뿐인 수. 예: $2, 3, 5, 7$',
          source_blocks: ['p8-a1', 'p9-a9'],
          criterion_notes: '',
          needs_check: '',
          anchor: -1,
        },
        { title: '빈 근거', concept_type: '없는 유형', content: '내용', source_blocks: [], criterion_notes: '', needs_check: '', anchor: 0 },
      ],
      new_types: [],
      excluded: [{ block_ids: ['p8-a3'], reason_type: 'problem_fragment', reason: '문항 첫머리' }],
      questions: [],
    },
    prepared,
    TYPES,
  );
  assertEquals(checks.unknown_types, [1]);
  assertEquals(checks.unknown_ids, ['p9-a9']);
  assertEquals(checks.unaccounted, ['p8-a2', 'p8-b3']);
  assertEquals(checks.formula_warnings, [{ concept: 0, formula: '2, 3, 5, 7' }]);
  assertEquals(checks.concepts_without_source, [1]);
  assertEquals(formulas('$x$ 와 $$2^{3}\\times 3$$'), ['2^{3}\\times 3']);
});

Deno.test('유형: 목록 표기로 맞추고, 목록에 있는 새 유형 제안은 빼며, 거절 때 쓸 유형은 목록 이름만 둔다', () => {
  const text = JSON.stringify({
    summary: 's',
    concepts: [
      { title: 'a', concept_type: ' 성질 ', content: 'x', source_blocks: [], criterion_notes: '', needs_check: '' },
      { title: 'b', concept_type: '판정  기준', content: 'x', source_blocks: [], criterion_notes: '', needs_check: '' },
      { title: 'c', concept_type: '방법', content: 'x', source_blocks: [], criterion_notes: '', needs_check: '' },
    ],
    new_types: [
      { name: '판정 기준', description: '가리는 기준', legacy_sub_type: '연산', closest_existing: '방법', reason: '방법과 다름' },
      { name: '방법', description: '', legacy_sub_type: '연산', closest_existing: '', reason: '' },
      { name: '판정 기준', description: '중복', legacy_sub_type: '정의', closest_existing: '', reason: '' },
      { name: '이상한', description: '', legacy_sub_type: '기타', closest_existing: '없는 것', reason: '' },
    ],
    excluded: [],
    questions: [],
  });
  const d = parseConceptDraft(text, TYPES);
  assert(d);
  assertEquals(d.concepts.map((c) => c.concept_type), ['성질', '판정 기준', '방법']);
  assertEquals(d.new_types.map((t) => [t.name, t.legacy_sub_type, t.closest_existing]), [['판정 기준', '연산', '방법'], ['이상한', '정리', '']]);
  assertEquals(conceptTypeRefs([{ name: '정의', description: 'd', legacy_sub_type: '정의' }, { name: 'x', legacy_sub_type: '기타' }]).map((t) => t.name), ['정의']);
});

Deno.test('주제 묶음: 빈 개념을 뺀 번호로 맞추고, 범위 밖·자기 자신·고리는 -1로 끊는다', () => {
  const c = (title: string, anchor: unknown) =>
    ({ title, concept_type: '정의', content: 'x', source_blocks: [], criterion_notes: '', needs_check: '', anchor });
  const text = JSON.stringify({
    summary: 's',
    concepts: [
      c('공약수', -1),
      { title: '', content: '', concept_type: '', source_blocks: [], criterion_notes: '', needs_check: '', anchor: -1 },
      c('최대공약수', 0),
      c('최대공약수의 성질', 2),
      c('자기', 4),
      c('범위 밖', 99),
      c('고리 가', 7),
      c('고리 나', 6),
      c('숫자 아님', '0'),
    ],
    new_types: [],
    excluded: [],
    questions: [],
  });
  const d = parseConceptDraft(text, TYPES);
  assert(d);
  assertEquals(d.concepts.map((x) => [x.title, x.anchor]), [
    ['공약수', -1],
    ['최대공약수', 0],
    ['최대공약수의 성질', 1],
    ['자기', -1],
    ['범위 밖', -1],
    ['고리 가', 6],
    ['고리 나', -1],
    ['숫자 아님', -1],
  ]);
  assertEquals(acyclicAnchors([2, 0, 1, -1]), [2, 0, -1, -1]);
});

Deno.test('요청 본문 검사', () => {
  assertEquals(readConceptDraftBody({}), { ok: false, error: 'pages_required' });
  assertEquals(readConceptDraftBody({ pages: [{ raw_page: 'x', a: [] }] }), { ok: false, error: 'invalid_page' });
  assertEquals(readConceptDraftBody({ pages: [{ raw_page: 8, a: [] }], criterion_ids: ['nope'] }), { ok: false, error: 'invalid_criteria' });
  const ok = readConceptDraftBody({ pages: [{ raw_page: 8, a: pageA }], criterion_ids: ['0b0e5a2c-1111-4222-8333-944455556666'] });
  assert(ok.ok);
  if (ok.ok) assertEquals(ok.pages[0].b, []);
  const many = (n: number) => ({ pages: Array.from({ length: n }, (_, i) => ({ raw_page: i + 1, a: pageA })) });
  assert(readConceptDraftBody(many(MAX_PAGES)).ok);
  assertEquals(MAX_PAGES, 20);
  assertEquals(readConceptDraftBody(many(MAX_PAGES + 1)), { ok: false, error: 'too_many_pages' });
});

Deno.test('12쪽 넘는 소단원은 출력 한도를 늘린다', () => {
  const prompt = (n: number) =>
    buildConceptDraftPrompt({
      bookName: 'x',
      gradeLabel: '1-1',
      unitPath: [],
      prepared: prepareUnit(Array.from({ length: n }, (_, i) => ({ raw_page: i + 1, display_page: null, a: pageA, b: pageB }))),
      criteria: [],
      types: TYPES,
    }).maxOutputTokens;
  assert(prompt(13) > prompt(12));
  assertEquals(prompt(20), prompt(13));
});

Deno.test('형식은 strict 조건을 지킨다', () => {
  const walk = (s: Record<string, unknown>) => {
    if (s.type === 'object') {
      assertEquals(s.additionalProperties, false);
      assertEquals([...(s.required as string[])].sort(), Object.keys(s.properties as object).sort());
      for (const v of Object.values(s.properties as Record<string, Record<string, unknown>>)) walk(v);
    }
    if (s.type === 'array') walk(s.items as Record<string, unknown>);
  };
  walk(CONCEPT_DRAFT_SCHEMA);
});

Deno.test('정리 실행: 형식을 붙여 부르고, 결과에 검사를 붙인다', async () => {
  const prepared = prepareUnit([{ raw_page: 8, display_page: 8, a: pageA, b: [] }]);
  const provider = new FakeAiProvider();
  const out = await organizeConceptDraft(provider, {
    model: 'gpt-test',
    reasoningEffort: 'medium',
    bookName: 'x',
    gradeLabel: '1-1',
    unitPath: [],
    prepared,
    criteria: [],
    types: TYPES,
  });
  assertEquals(out.error, null);
  assert(provider.requests[0].input.some((m) => m.kind === 'message' && m.parts.some((p) => p.type === 'text' && p.text.includes('- 성질 (기존 구분 정리)'))));
  assertEquals(provider.requests[0].jsonSchema?.name, 'concept_draft');
  assert(out.checks);
  assertEquals(out.checks.unaccounted.length, prepared.blocks.length);

  const bad = await organizeConceptDraft(new FakeAiProvider([{ text: '문장' }]), {
    model: 'gpt-test',
    reasoningEffort: 'medium',
    bookName: 'x',
    gradeLabel: '1-1',
    unitPath: [],
    prepared,
    criteria: [],
    types: [],
  });
  assertEquals(bad.error, 'invalid_output');
});
