import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider } from '../_shared/ai/fake.ts';
import {
  buildEvidencePrompt,
  CONCEPT_EVIDENCE_SCHEMA,
  evidenceInput,
  type EvidenceSource,
  parseEvidenceProposal,
} from './evidence.ts';
import { proposeEvidenceScopes } from './run.ts';

const ST = '00000000-0000-4000-8000-0000000000s1';
const rpcData = {
  concept_id: 'c',
  groups: [
    { statement_id: null, kind: 'base', text: '1보다 큰 자연수 중 약수가 1과 자기 자신뿐인 수', md5: 'm-base' },
    { statement_id: ST, kind: 'draft', text: '다른 교재 설명', md5: 'm-st' },
  ],
  sources: [
    {
      id: 's1', statement_id: null, book_name: '개념+유형', grade_label: '1-1', raw_page: 8, display_page: 18,
      evidence_scope: 'unknown',
      blocks: [{ id: 'p8-a0', kind: 'concept_box', title: '소수', text: '1과 자기 자신만을 약수로 가지는 수', figure_description: null, uncertain: true }],
    },
    { id: 's2', statement_id: null, book_name: '쎈', grade_label: '1-1', raw_page: 3, display_page: null, evidence_scope: 'part', blocks: [] },
    { id: 's3', statement_id: ST, book_name: '쎈', grade_label: '1-1', raw_page: 4, display_page: null, evidence_scope: 'bad',
      blocks: [{ id: 'p4-a0', kind: 'note', title: '', text: '주의', figure_description: '', uncertain: false }] },
  ],
};

Deno.test('근거 조회 결과에서 서술 하나와 근거가 있는 출처만 고른다', () => {
  const base = evidenceInput(rpcData, null);
  assert(base);
  assertEquals([base.basisKind, base.basisMd5], ['base', 'm-base']);
  assertEquals(base.sources.map((s) => s.id), ['s1']);
  assertEquals(base.noBlocks, ['s2'], '근거 블록이 없는 출처는 보내지 않는다');
  const other = evidenceInput(rpcData, ST);
  assert(other);
  assertEquals(other.sources.map((s) => [s.id, s.scope]), [['s3', 'unknown']]);
  assertEquals(evidenceInput(rpcData, 'zz'), null);
  assertEquals(evidenceInput(null, null), null);
});

Deno.test('지시에 서술 종류·글, 출처의 교재·쪽·지금 범위·근거 글·불확실 표시가 들어간다', () => {
  const input = evidenceInput(rpcData, null)!;
  const p = buildEvidencePrompt({ conceptName: '소수', ...input });
  assert(p.userText.includes('개념: 소수'));
  assert(p.userText.includes('기본 서술:'));
  assert(p.userText.includes('[0] 개념+유형 1-1 18쪽(PDF 8) · 지금 범위: 범위 미확인'));
  assert(p.userText.includes('[concept_box · 소수] 1과 자기 자신만을 약수로 가지는 수 (읽기 불확실)'));
  assert(!p.userText.includes('쎈'));
});

const sources: EvidenceSource[] = [
  { id: 'a', book_name: '', grade_label: '', raw_page: 1, display_page: null, scope: 'unknown', blocks: [] },
  { id: 'b', book_name: '', grade_label: '', raw_page: 2, display_page: null, scope: 'part', blocks: [] },
  { id: 'c', book_name: '', grade_label: '', raw_page: 3, display_page: null, scope: 'unknown', blocks: [] },
];

Deno.test('제안: 번호를 출처 id로 바꾸고, 모르는 범위·번호·두 번째 답은 버리며 답 없는 출처를 알린다', () => {
  const text = JSON.stringify({
    summary: '요약',
    items: [
      { source: 0, scope: 'whole', reason: '정의가 다 있음', covered: '정의', missing: '' },
      { source: 1, scope: 'all', reason: '모르는 범위', covered: '', missing: '' },
      { source: 0, scope: 'related', reason: '두 번째', covered: '', missing: '' },
      { source: 7, scope: 'part', reason: '없는 번호', covered: '', missing: '' },
      { source: 2, scope: 'part', reason: '조건 없음', covered: '정의', missing: '적용 조건' },
    ],
  });
  const p = parseEvidenceProposal(text, sources, 'md5', ['z']);
  assert(p);
  assertEquals(p.items.map((i) => [i.source_id, i.scope, i.current_scope]), [['a', 'whole', 'unknown'], ['c', 'part', 'unknown']]);
  assertEquals(p.items[1].missing, '적용 조건');
  assertEquals(p.checks, { no_blocks: ['z'], unanswered: ['b'] });
  assertEquals(p.basis_md5, 'md5');
  assertEquals(parseEvidenceProposal('문장', sources, 'md5', []), null);
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
  walk(CONCEPT_EVIDENCE_SCHEMA);

  const input = evidenceInput(rpcData, null)!;
  const provider = new FakeAiProvider([{
    text: JSON.stringify({ summary: 's', items: [{ source: 0, scope: 'part', reason: 'r', covered: '', missing: '' }] }),
  }]);
  const out = await proposeEvidenceScopes(provider, { model: 'gpt-test', reasoningEffort: 'medium', conceptName: '소수', ...input });
  assertEquals(out.error, null);
  assertEquals(provider.requests[0].jsonSchema?.name, 'concept_source_scope');
  assertEquals(out.proposal?.items[0].source_id, 's1');
  assertEquals(out.proposal?.basis_md5, 'm-base');

  const bad = await proposeEvidenceScopes(new FakeAiProvider([{ text: '문장' }]), {
    model: 'gpt-test',
    reasoningEffort: 'medium',
    conceptName: '',
    ...input,
  });
  assertEquals(bad.error, 'invalid_output');
});
