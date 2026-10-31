import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider } from '../_shared/ai/fake.ts';
import {
  buildComparePrompt,
  type CompareItem,
  compareTargetOf,
  CONCEPT_COMPARE_SCHEMA,
  entryPages,
  evidenceText,
  overlapNames,
  parseCompareProposal,
  reviewEntries,
} from './compare.ts';
import { proposeCompare } from './run.ts';

const A = '00000000-0000-4000-8000-00000000000a';
const B = '00000000-0000-4000-8000-00000000000b';
const SA = '00000000-0000-4000-8000-0000000000a1';

const target = (id: string, name: string, extra: Record<string, unknown> = {}) =>
  compareTargetOf({
    id,
    name,
    folder: ['대수', '소인수분해'],
    content: `${name} 기본 서술`,
    statements: [{ id: SA, confirmed: false, text: '다른 교재 설명' }],
    sources: 2,
    books: ['쎈'],
    content_draft: false,
    ...extra,
  })!;

const items: CompareItem[] = [
  { key: 'c0', title: '소수', content: '1보다 큰 자연수 중 약수가 둘', evidence: '소수 정의', candidates: [target(A, '소수')] },
  {
    key: 'c1',
    title: '합성수',
    content: '약수가 셋 이상',
    evidence: '',
    candidates: [target(A, '소수'), target(B, '합성수', { content_draft: true })],
  },
  { key: 'c2', title: '서로소', content: '최대공약수 1', evidence: '', candidates: [target(B, '합성수')] },
];

Deno.test('검토 항목: 저장된 검토에서 뺀 것을 제외하고, 블록이 없으면 초안 근거 블록을 쓴다. 검토가 없으면 AI 초안', () => {
  const draft = { concepts: [{ title: '가', content: '가 글', source_blocks: ['p1'] }, { title: '나', content: '나 글', source_blocks: ['p2'] }] };
  assertEquals(reviewEntries({ draft, review: {} }).map((e) => [e.key, e.title, e.blocks]), [['c0', '가', ['p1']], ['c1', '나', ['p2']]]);
  const review = {
    concepts: [
      { key: 'c0', index: 0, mark: 'drop', title: '가' },
      { key: 'c1', index: 1, mark: 'edit', title: ' 나2 ', content: '고친 글', relation: { kind: 'source', concept_id: A } },
      { key: 'c1.1', index: 1, mark: 'keep', title: '나 나눔', content: 'x', blocks: ['p9'], relation: { kind: 'hold', concept_id: 'zz' } },
      { key: 'c9', index: 9, mark: 'keep', title: '없는 번호' },
    ],
  };
  assertEquals(reviewEntries({ draft, review }).map((e) => [e.key, e.title, e.content, e.blocks, e.target]), [
    ['c1', '나2', '고친 글', ['p2'], A],
    ['c1.1', '나 나눔', 'x', ['p9'], null],
  ]);
});

Deno.test('폴더 제안의 겹침은 라이브러리 개념만 이름으로 쓰고, 근거 글은 블록 순서대로 잇는다', () => {
  const names = overlapNames({
    overlaps: [
      { concept: 0, other: '라이브러리 대수 > 소인수분해 > 소수', reason: '' },
      { concept: 0, other: '초안 소수와 합성수: 소수', reason: '' },
      { concept: 1, other: '라이브러리 합성수', reason: '' },
    ],
  });
  assertEquals([...names.entries()], [[0, ['소수']], [1, ['합성수']]]);
  assertEquals(overlapNames(null).size, 0);
  const prepared = { blocks: [{ id: 'a', raw_page: 12, title: '정의', text: '글 A' }, { id: 'b', raw_page: 14, text: '글 B', figure_description: '그림' }] };
  assertEquals(evidenceText(prepared, ['b', 'zz', 'a']), '글 B 그림\n정의 글 A');
  assertEquals(entryPages(prepared, ['b', 'zz', 'a', 'b']), [14, 12]);
});

Deno.test('지시에 항목 글·근거, 후보의 폴더·출처 수·책·수정안 있음·다른 서술이 들어간다', () => {
  const p = buildComparePrompt({ unitPath: ['소인수분해'], bookName: '개념+유형', items });
  assert(p.userText.includes('교재: 개념+유형 · 단원: 소인수분해'));
  assert(p.userText.includes('[항목 0] 소수'));
  assert(p.userText.includes('교재 근거: 소수 정의'));
  assert(p.userText.includes('후보 0: 소수 · 폴더 대수 > 소인수분해 · 출처 2개(쎈)'));
  assert(p.userText.includes('후보 1: 합성수 · 폴더 대수 > 소인수분해 · 출처 2개(쎈) · 수정안 있음'));
  assert(p.userText.includes('서술 0(확정 전): 다른 교재 설명'));
});

Deno.test('제안: 번호를 항목 key·개념 id로 바꾸고, 대상이 필요한데 후보가 아니거나 서술 번호가 틀린 답은 버린다', () => {
  const text = JSON.stringify({
    summary: '요약',
    items: [
      { item: 0, choice: 'source', candidate: 0, statement: 0, reason: '같은 설명', differences: '' },
      { item: 0, choice: 'new', candidate: -1, statement: -1, reason: '두 번째', differences: '' },
      { item: 1, choice: 'revise', candidate: 1, statement: -1, reason: '조건 보충', differences: '조건' },
      { item: 2, choice: 'source', candidate: 0, statement: 5, reason: '없는 서술', differences: '' },
      { item: 7, choice: 'new', candidate: -1, statement: -1, reason: '없는 항목', differences: '' },
      { item: 2, choice: 'merge', candidate: 0, statement: -1, reason: '모르는 선택', differences: '' },
    ],
  });
  const p = parseCompareProposal(text, items, ['c9'], ['c10']);
  assert(p);
  assertEquals(p.items.map((i) => [i.key, i.choice, i.concept_id, i.statement_id, i.draft_exists]), [
    ['c0', 'source', A, SA, false],
    ['c1', 'revise', B, null, true],
  ]);
  assertEquals(p.checks, { no_candidates: ['c9'], over_limit: ['c10'], unanswered: ['c2'] });
  assertEquals(p.candidates.c1.map((c) => c.name), ['소수', '합성수']);

  const loose = parseCompareProposal(JSON.stringify({
    summary: '',
    items: [
      { item: 0, choice: 'statement', candidate: 3, statement: -1, reason: '없는 후보', differences: '' },
      { item: 1, choice: 'new', candidate: 0, statement: -1, reason: '다름', differences: '' },
      { item: 2, choice: 'hold', candidate: 0, statement: -1, reason: '애매', differences: '' },
    ],
  }), items, [], []);
  assertEquals(loose?.items.map((i) => [i.key, i.choice, i.concept_id]), [['c1', 'new', null], ['c2', 'hold', B]]);
  assertEquals(parseCompareProposal('문장', items, [], []), null);
});

Deno.test('형식은 strict 조건을 지키고, 실행은 형식을 붙여 부른다', async () => {
  const walk = (s: Record<string, unknown>) => {
    if (s.type === 'object') {
      assertEquals(s.additionalProperties, false);
      assertEquals([...(s.required as string[])].sort(), Object.keys(s.properties as object).sort());
      for (const v of Object.values(s.properties as Record<string, Record<string, unknown>>)) walk(v);
    }
    if (s.type === 'array') walk(s.items as Record<string, unknown>);
  };
  walk(CONCEPT_COMPARE_SCHEMA);

  const provider = new FakeAiProvider([{
    text: JSON.stringify({ summary: 's', items: [{ item: 0, choice: 'statement', candidate: 0, statement: -1, reason: 'r', differences: 'd' }] }),
  }]);
  const opts = { model: 'gpt-test', reasoningEffort: 'medium', unitPath: [], bookName: '', items, noCandidates: [], overLimit: [] };
  const out = await proposeCompare(provider, opts);
  assertEquals(out.error, null);
  assertEquals(provider.requests[0].jsonSchema?.name, 'concept_draft_compare');
  assertEquals(out.proposal?.items[0].concept_id, A);

  const bad = await proposeCompare(new FakeAiProvider([{ text: '문장' }]), opts);
  assertEquals(bad.error, 'invalid_output');
});
