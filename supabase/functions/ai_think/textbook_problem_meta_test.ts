import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider } from '../_shared/ai/fake.ts';
import {
  buildConceptCandidates,
  conceptIdsFromRefs,
  type ConceptSourceRow,
  normalizeUnitName,
  unitMatches,
} from './textbook_concept_candidates.ts';
import { isMetaTodo, type MetaDictionary, metaFromModel, needsVisualTags, runMetaBatch } from './textbook_problem_meta.ts';
import { compareMetaFields } from './textbook_problem_review.ts';
import { normalizeVisualTags } from './textbook_visual_tags.ts';

const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const CROP_A = id(901);
const CROP_B = id(902);

const rows: ConceptSourceRow[] = [
  { id: id(1), name: '정수의 덧셈', unitPath: ['정수와 유리수', '정수와 유리수의 계산'] },
  { id: id(2), name: '절댓값', unitPath: ['수와 연산', '정수와 유리수'] },
  { id: id(3), name: '일차방정식의 해', unitPath: ['문자와 식', '일차방정식의 풀이'] },
  { id: id(1), name: '정수의 덧셈', unitPath: ['수와 연산', '정수와 유리수'] },
];

Deno.test('단원 이름: 앞뒤 번호·공백을 빼고 대·중단원 중 하나가 맞으면 같은 단원이다', () => {
  assertEquals(normalizeUnitName('Ⅰ. 수와 연산'), '수와연산');
  assertEquals(normalizeUnitName('자료의 정리와 해석(1)'), '자료의정리와해석');
  assertEquals(normalizeUnitName('1. 소인수분해'), '소인수분해');
  assert(unitMatches(['정수와 유리수', '정수와 유리수의 계산'], '정수와 유리수', '정수와 유리수의 덧셈과 뺄셈'));
  assert(unitMatches(['통계', '자료의 정리와 해석'], '통계', '자료의 정리와 해석(1)'));
  assert(unitMatches(['수와 연산', '소인수분해'], '소인수분해', '최대공약수와 최소공배수'));
  assert(!unitMatches(['문자와 식', '일차방정식'], '학교 시험 대비 실력 향상 테스트', '1회 실력 향상 테스트'));
  assert(!unitMatches([], '정수와 유리수', '정수와 유리수'));
});

Deno.test('개념 후보: 단원이 맞는 개념만 짧은 번호로 보내고, 맞는 단원이 없으면 학년 전체를 쓴다', () => {
  const unit = buildConceptCandidates(rows, '정수와 유리수', '정수와 유리수의 덧셈과 뺄셈');
  assertEquals(unit.scope, 'unit');
  assertEquals(unit.list.map((c) => c.id), [id(1), id(2)]);
  assertEquals(unit.list.map((c) => c.ref), ['k1', 'k2']);

  const grade = buildConceptCandidates(rows, '학교 시험 대비 실력 향상 테스트', '1회 실력 향상 테스트');
  assertEquals(grade.scope, 'grade');
  assertEquals(grade.list.length, 3);

  assertEquals(buildConceptCandidates([], '정수와 유리수', '').scope, 'none');
});

Deno.test('개념 ref: 목록에 없는 번호는 버리고 같은 개념은 한 번만, 최대 4개', () => {
  const c = buildConceptCandidates(rows, '학교 시험', '종합');
  assertEquals(conceptIdsFromRefs(['k2', 'k9', 'k2', ' k1 '], c), [id(2), id(1)]);
  assertEquals(conceptIdsFromRefs('k1', c), []);
});

function dict(): MetaDictionary {
  return {
    candidates: buildConceptCandidates(rows, '정수와 유리수', '정수와 유리수의 덧셈과 뺄셈'),
    thinkByCode: new Map([['T1', id(501)], ['T2', id(502)]]),
    typeNames: ['정의', '성질', '방법'],
  };
}

Deno.test('메타 결과: 새 개념은 가장 가까운 목록 개념이 있어야 남고, 목록 개념 이름이면 그 개념을 고른 것으로 본다', () => {
  const m = metaFromModel({
    crop_id: CROP_A,
    concept_refs: ['k1', 'k77'],
    thinking_codes: ['T2', 'T9', 'T2'],
    new_concepts: [
      { name: '절댓값', type: '정의', content: '설명', near_ref: 'k1', reason: '' },
      { name: '정수의 덧셈의 교환법칙', type: '없는 유형', content: '$a+b=b+a$', near_ref: 'k1', reason: '목록에 없음' },
      { name: '폴더를 못 고른 개념', type: '성질', content: '설명', near_ref: null, reason: '' },
    ],
  }, dict());
  assertEquals(m.conceptIds, [id(1), id(2)]);
  assertEquals(m.thinkingIds, [id(502)]);
  assertEquals(m.proposals.length, 1);
  assertEquals(m.proposals[0].name, '정수의 덧셈의 교환법칙');
  assertEquals(m.proposals[0].near_concept_id, id(1));
  assertEquals(m.proposals[0].type, '성질');
  assertEquals(m.droppedProposals, ['폴더를 못 고른 개념']);
});

Deno.test('메타 대상: 문제은행 문항과 본문이 있고 아직 메타를 고르지 않은 문항, 사람이 모두 고친 문항은 제외', () => {
  const base = { crop_id: CROP_A, pb_question_id: id(700), stem: '본문' };
  assert(isMetaTodo(base, false));
  assert(!isMetaTodo({ ...base, pb_question_id: '' }, false));
  assert(!isMetaTodo({ ...base, stem: '' }, false));
  assert(!isMetaTodo({ ...base, meta_checked_at: '2026-11-13T00:00:00Z' }, false));
  assert(isMetaTodo({ ...base, meta_checked_at: '2026-11-13T00:00:00Z' }, true));
  assert(!isMetaTodo({ ...base, meta_sources: { concepts: 'owner', thinkings: 'owner' } }, true));
  assert(isMetaTodo({ ...base, meta_sources: { concepts: 'owner' } }, false));
});

Deno.test('시각 태그: 빈 태그는 누락이고 "없음"은 다른 태그와 함께 두지 않는다', () => {
  assertEquals(normalizeVisualTags(['없음']), ['없음']);
  assertEquals(normalizeVisualTags([' 삼각형 ', '없음', '삼각형', '']), ['삼각형']);
  assertEquals(normalizeVisualTags(null), []);

  const m = metaFromModel({ crop_id: CROP_A, concept_refs: [], thinking_codes: [], new_concepts: [], visual_tags: ['없음', '삼각형', '지어낸 태그'] }, dict());
  assertEquals(m.visualTags, ['삼각형']);
  assertEquals(metaFromModel({ crop_id: CROP_A, visual_tags: ['지어낸 태그'] }, dict()).visualTags, []);

  const checked = { crop_id: CROP_A, pb_question_id: id(700), stem: '본문', meta_checked_at: '2026-11-13T00:00:00Z' };
  assert(!needsVisualTags(checked), '풀이 전 문항은 2단계 풀이가 태그를 고른다');
  assert(needsVisualTags({ ...checked, ai_solution: '풀이' }));
  assert(!needsVisualTags({ ...checked, ai_solution: '풀이', visual_tags: ['없음'] }));
  assert(isMetaTodo({ ...checked, ai_solution: '풀이' }, false));
  assert(isMetaTodo({ ...checked, ai_solution: '풀이', meta_sources: { concepts: 'owner', thinkings: 'owner' } }, false));
  assert(!isMetaTodo({ ...checked, ai_solution: '풀이', visual_tags: ['삼각형'] }, false));
});

Deno.test('메타 실행: 한 번의 JSON 호출로 묶음을 처리하고 개념은 UUID 대신 짧은 번호로 보낸다', async () => {
  const provider = new FakeAiProvider((req) => {
    const payload = JSON.parse((req.input[0] as { parts: { text: string }[] }).parts[0].text);
    return {
      text: JSON.stringify({
        problems: (payload.problems as { crop_id: string }[]).map((p, i) => ({
          crop_id: p.crop_id,
          concept_refs: [payload.candidate_concepts[i % payload.candidate_concepts.length].ref],
          thinking_codes: ['T1'],
          new_concepts: [],
        })),
      }),
    };
  });
  const { byCrop } = await runMetaBatch(
    { provider, model: 'fake-model', safetyId: 'hash', signal: new AbortController().signal },
    {
      unit: { gradeLabel: '1-1', bigName: '정수와 유리수', midName: '정수와 유리수의 덧셈과 뺄셈' },
      dict: dict(),
      thinkList: [{ code: 'T1', kind: 'frame', category: '일반', title: '조건 정리' }],
      types: [{ name: '정의', description: '' }, { name: '성질', description: '' }, { name: '방법', description: '' }],
      items: [
        { crop_id: CROP_A, problem_number: '1', stem: '$(-3)+5$ 를 계산하시오.', existing_answer: '2' },
        { crop_id: CROP_B, problem_number: '2', common_stem: '다음을 계산하시오.', stem: '$|-4|$', ai_solution: '4' },
      ],
    },
  );
  assertEquals(provider.requests.length, 1);
  const req = provider.requests[0];
  assertEquals(req.jsonSchema?.name, 'textbook_problem_meta');
  assertEquals(req.reasoningEffort, 'low');
  const sent = JSON.stringify(req.input);
  assert(!sent.includes(id(1)) && !sent.includes(id(2)), '개념 UUID 를 모델에 보내지 않는다');
  assertEquals(byCrop.get(CROP_A)?.conceptIds, [id(1)]);
  assertEquals(byCrop.get(CROP_B)?.conceptIds, [id(2)]);
  assertEquals(byCrop.get(CROP_B)?.thinkingIds, [id(501)]);
});

Deno.test('메타 실행: 시각 태그를 고를 문항의 그림은 본문 JSON 뒤에 문항 표시와 함께 붙인다', async () => {
  const provider = new FakeAiProvider((req) => {
    const payload = JSON.parse((req.input[0] as { parts: { text: string }[] }).parts[0].text);
    return {
      text: JSON.stringify({
        problems: (payload.problems as { crop_id: string; figure_images: number }[]).map((p) => ({
          crop_id: p.crop_id,
          concept_refs: [],
          thinking_codes: [],
          new_concepts: [],
          visual_tags: p.figure_images > 0 ? ['삼각형'] : ['없음'],
        })),
      }),
    };
  });
  const { byCrop } = await runMetaBatch(
    { provider, model: 'fake-model', safetyId: 'hash', signal: new AbortController().signal },
    {
      unit: { gradeLabel: '1-2', bigName: '평면도형', midName: '삼각형의 작도' },
      dict: dict(),
      thinkList: [],
      types: [{ name: '성질', description: '' }],
      items: [
        { crop_id: CROP_A, problem_number: '1', stem: '다음 그림에서[그림]', ai_solution: '풀이' },
        { crop_id: CROP_B, problem_number: '2', stem: '정수를 모두 골라라.', ai_solution: '풀이' },
      ],
      figureUrls: new Map([[CROP_A, ['https://example.com/a.png', 'https://example.com/b.png']]]),
    },
  );
  const parts = (provider.requests[0].input[0] as { parts: Array<{ type: string; text?: string; url?: string; detail?: string }> }).parts;
  assertEquals(parts.map((p) => p.type), ['text', 'text', 'image', 'image']);
  assert(parts[1].text?.includes(CROP_A));
  assertEquals(parts[2].detail, 'low');
  assertEquals(byCrop.get(CROP_A)?.visualTags, ['삼각형']);
  assertEquals(byCrop.get(CROP_B)?.visualTags, ['없음']);
});

Deno.test('정답 대조 단계 메타: 사람이 고친 항목은 쓰지 않고, 개념·사고가 모두 있을 때만 메타를 고른 것으로 본다', () => {
  const now = '2026-11-13T00:00:00Z';
  const full = compareMetaFields({}, [id(1)], [id(501)], now);
  assertEquals(full.concept_ids, [id(1)]);
  assertEquals(full.concept_proposals, []);
  assertEquals(full.meta_checked_at, now);

  assertEquals(compareMetaFields(null, [], [id(501)], now).meta_checked_at, null);

  const owner = compareMetaFields({ concepts: 'owner' }, [], [id(501)], now);
  assert(!('concept_ids' in owner) && !('concept_proposals' in owner));
  assertEquals(owner.thinking_ids, [id(501)]);
  assertEquals(owner.meta_checked_at, now);
});
