import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider } from '../_shared/ai/fake.ts';
import { collectStep, JOB_MAX_MS, jobAgeMs, jobOutcome, pollStep, SAVING_STALE_MS } from './jobs.ts';
import { type ConceptTypeRef, prepareUnit, type TranscriptBlock } from './organize.ts';
import { conceptDraftOutcome, conceptDraftRequest, organizeConceptDraft } from './run.ts';

const TYPES: ConceptTypeRef[] = [{ name: '정의', description: '뜻', legacy_sub_type: '정의' }];
const block = (kind: string, text: string, bbox: number[]): TranscriptBlock =>
  ({ kind, title: '', text, bbox_1k: bbox, figure_description: '', uncertain: false });
const prepared = prepareUnit([
  { raw_page: 8, display_page: 8, a: [block('concept_box', '점: 위치만 있고 크기가 없는 것', [100, 100, 200, 800])], b: [] },
]);
const opts = { model: 'gpt-test', reasoningEffort: 'medium', bookName: 'x', gradeLabel: '1-2', unitPath: [], prepared, criteria: [], types: TYPES };
const now = Date.parse('2026-10-19T07:30:00Z');
const ago = (ms: number) => new Date(now - ms).toISOString();

Deno.test('작업 상태: 끝난 작업은 다시 묻지 않고, 저장 중인 작업은 오래 멈췄을 때만 이어받는다', () => {
  assertEquals(collectStep({ status: 'done', updated_at: ago(0) }, now), 'done');
  assertEquals(collectStep({ status: 'failed', updated_at: ago(0) }, now), 'failed');
  assertEquals(collectStep({ status: 'running', updated_at: ago(0) }, now), 'poll');
  assertEquals(collectStep({ status: 'saving', updated_at: ago(1000) }, now), 'wait');
  assertEquals(collectStep({ status: 'saving', updated_at: ago(SAVING_STALE_MS + 1) }, now), 'poll');
  assertEquals(jobAgeMs({ created_at: ago(90_000) }, now), 90_000);
});

Deno.test('공급자 상태: 도는 중이면 기다리고, 너무 오래면 끊고, 끝났으면 저장한다', () => {
  const running = { state: 'running', status: 'in_progress' } as const;
  assertEquals(pollStep(running, 60_000), 'running');
  assertEquals(pollStep(running, JOB_MAX_MS + 1), 'timeout');
  assertEquals(pollStep({ state: 'failed', error: 'x' }, 1), 'finish');
});

Deno.test('백그라운드 결과는 바로 부른 정리와 같은 초안·검사가 된다', async () => {
  const direct = await organizeConceptDraft(new FakeAiProvider(), opts);

  const provider = new FakeAiProvider([{ pendingPolls: 2 }]);
  const { id } = await provider.background.start(conceptDraftRequest(opts));
  assertEquals((await provider.background.poll(id)).state, 'running');
  assertEquals((await provider.background.poll(id)).state, 'running');
  const done = await provider.background.poll(id);
  assert(done.state === 'done');
  const out = jobOutcome(done, { prepared, concept_types: TYPES });
  assertEquals(out.error, null);
  assertEquals(out.draft, direct.draft);
  assertEquals(out.checks, direct.checks);
  assertEquals(provider.background.started[0].req.jsonSchema?.name, 'concept_draft');
});

Deno.test('백그라운드 실패·잘린 결과·형식이 틀린 결과는 초안 없이 이유를 남긴다', async () => {
  assertEquals(jobOutcome({ state: 'failed', error: 'ai_timeout' }, { prepared, concept_types: TYPES }).error, 'ai_timeout');

  const provider = new FakeAiProvider([{ text: '문장' }, { error: 'boom' }]);
  const bad = await provider.background.poll((await provider.background.start(conceptDraftRequest(opts))).id);
  assert(bad.state === 'done');
  assertEquals(jobOutcome(bad, { prepared, concept_types: TYPES }).error, 'invalid_output');
  const failed = await provider.background.poll((await provider.background.start(conceptDraftRequest(opts))).id);
  assertEquals(failed, { state: 'failed', error: 'boom' });

  const cut = conceptDraftOutcome({ ...bad.result, status: 'incomplete', incompleteReason: 'max_output_tokens' }, { prepared, types: TYPES });
  assertEquals(cut.error, 'incomplete:max_output_tokens');
});
