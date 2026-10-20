import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider } from '../_shared/ai/fake.ts';
import { type AnchorConcept, buildAnchorPrompt, CONCEPT_ANCHOR_SCHEMA, parseAnchorProposal } from './anchors.ts';
import { proposeConceptAnchors } from './run.ts';

const C = (id: string, name: string, type: string, anchor: string | null = null): AnchorConcept =>
  ({ id, name, type, content: `${name} 본문`, anchor_id: anchor });

const concepts = [
  C('a', '공약수', '정의'),
  C('b', '최대공약수', '정의', 'a'),
  C('c', '최대공약수의 성질', '성질'),
  C('d', '서로소', '정의', 'zz'),
];

Deno.test('지시에 폴더 경로·유형 순서·지금 묶음 번호가 들어간다(다른 폴더 연결은 빼고)', () => {
  const p = buildAnchorPrompt({ folderPath: ['대수', '약수와 배수'], concepts, typeOrder: ['정의', '표현', '성질'] });
  assert(p.userText.includes('폴더: 대수 > 약수와 배수'));
  assert(p.userText.includes('정의 → 표현 → 성질'));
  assert(p.userText.includes('[1] 최대공약수 (정의) · 지금 묶음: [0]'));
  assert(p.userText.includes('[3] 서로소 (정의)\n'));
});

Deno.test('제안: 번호를 id로 바꾸고, 답이 없는 개념은 지금 연결을 두며, 고리·자기 자신은 끊는다', () => {
  const text = JSON.stringify({
    summary: '공약수 줄기',
    links: [
      { concept: 0, anchor: 2, reason: '고리' },
      { concept: 2, anchor: 1, reason: '최대공약수를 쓴다' },
      { concept: 3, anchor: 3, reason: '자기' },
      { concept: 2, anchor: 0, reason: '두 번째는 무시' },
      { concept: 9, anchor: 0, reason: '없는 번호' },
    ],
  });
  const p = parseAnchorProposal(text, concepts);
  assert(p);
  assertEquals(p.items.map((i) => [i.concept_id, i.anchor_id, i.current_anchor_id]), [
    ['a', 'c', null],
    ['b', 'a', 'a'],
    ['c', null, null],
    ['d', null, null],
  ]);
  assertEquals(p.checks, { unanswered: ['b'], broken: ['c'] });
  assertEquals(p.items[2].reason, '최대공약수를 쓴다');
  assertEquals(parseAnchorProposal('문장', concepts), null);
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
  walk(CONCEPT_ANCHOR_SCHEMA);

  const provider = new FakeAiProvider([{ text: JSON.stringify({ summary: 's', links: [{ concept: 1, anchor: 0, reason: 'r' }] }) }]);
  const out = await proposeConceptAnchors(provider, {
    model: 'gpt-test',
    reasoningEffort: 'medium',
    folderPath: ['대수'],
    concepts,
    typeOrder: ['정의'],
  });
  assertEquals(out.error, null);
  assertEquals(provider.requests[0].jsonSchema?.name, 'concept_anchor_plan');
  assertEquals(out.proposal?.items[1].anchor_id, 'a');

  const bad = await proposeConceptAnchors(new FakeAiProvider([{ text: '문장' }]), {
    model: 'gpt-test',
    reasoningEffort: 'medium',
    folderPath: [],
    concepts,
    typeOrder: [],
  });
  assertEquals(bad.error, 'invalid_output');
});
