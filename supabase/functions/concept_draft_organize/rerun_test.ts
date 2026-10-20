import { assertEquals } from 'jsr:@std/assert@1';
import { rerunDraftId, rerunFinishCode, rerunPlan } from './rerun.ts';

const DRAFT = '3c2b1a09-8f7e-4d6c-9b5a-4e3f2d1c0b9a';
const CRIT = '0b1c2d3e-4f50-4a61-8b72-9c83d4e5f6a7';

const action = (partial: Record<string, unknown> = {}) => ({
  id: 'a1',
  kind: 'concept_draft_rerun',
  status: 'proposed',
  payload: { draft_id: DRAFT, criterion_ids: [CRIT, 'not-a-uuid'], reason: '기준을 바꿈' },
  ...partial,
});

const draft = (partial: Record<string, unknown> = {}) => ({
  id: DRAFT,
  academy_id: 'ac',
  book_id: 'bk',
  grade_label: '중1',
  unit_path: ['수와 연산', '소인수분해'],
  pages: [8, 9],
  status: 'open',
  ...partial,
});

Deno.test('다시 정리: 카드 종류·상태·초안 id를 확인한다', () => {
  assertEquals(rerunDraftId(null), { ok: false, status: 404, error: 'action_not_found' });
  assertEquals(rerunDraftId(action({ kind: 'concept_draft_change' })), { ok: false, status: 400, error: 'action_kind_invalid' });
  assertEquals(rerunDraftId(action({ status: 'applied' })), { ok: false, status: 409, error: 'action_not_pending' });
  assertEquals(rerunDraftId(action({ payload: { draft_id: 'x' } })), { ok: false, status: 400, error: 'invalid_draft' });
  assertEquals(rerunDraftId(action()), { ok: true, draftId: DRAFT });
});

Deno.test('다시 정리: 열린 초안의 책·학년·단원·쪽과 카드의 기준만으로 요청을 만든다', () => {
  assertEquals(rerunPlan(action(), null), { ok: false, status: 404, error: 'draft_not_found' });
  assertEquals(rerunPlan(action(), draft({ status: 'replaced' })), { ok: false, status: 409, error: 'draft_closed' });
  assertEquals(rerunPlan(action(), draft({ id: CRIT })), { ok: false, status: 400, error: 'invalid_draft' });
  assertEquals(rerunPlan(action(), draft()), {
    ok: true,
    draftId: DRAFT,
    body: { academy_id: 'ac', book_id: 'bk', grade_label: '중1', unit_path: ['수와 연산', '소인수분해'], pages: [8, 9], criterion_ids: [CRIT] },
  });
});

Deno.test('다시 정리: 마무리 RPC 오류 코드를 골라 돌려준다', () => {
  assertEquals(rerunFinishCode('action_not_pending'), 'action_not_pending');
  assertEquals(rerunFinishCode('ERROR: concept_draft_closed'), 'concept_draft_closed');
  assertEquals(rerunFinishCode('connection reset'), 'rerun_finish_failed');
});
