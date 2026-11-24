import test from 'node:test';
import assert from 'node:assert/strict';

import { renderThumbnailGroups } from '../src/problem_bank/preview_batch_fallback.js';

// 묶음에 조판이 안 되는 문항이 있으면 던지는 가짜 조판기
function fakeRenderer(bad) {
  const calls = [];
  const renderGroup = async (questions, qids) => {
    calls.push(qids.join(','));
    const hit = qids.find((id) => bad.has(id));
    if (hit) throw new Error(`! Misplaced \\noalign.   (${hit})`);
    return { thumbnails: Object.fromEntries(qids.map((id) => [id, { url: `https://x/${id}.png` }])), pageCount: qids.length };
  };
  return { calls, renderGroup };
}

const ids = (n) => Array.from({ length: n }, (_, i) => `q${i + 1}`);
const questionsOf = (list) => list.map((id) => ({ id }));

test('a batch that renders is one call', async () => {
  const list = ids(8);
  const r = fakeRenderer(new Set());
  const out = await renderThumbnailGroups({ questions: questionsOf(list), qids: list, renderGroup: r.renderGroup });
  assert.equal(r.calls.length, 1);
  assert.equal(out.pageCount, 8);
  assert.deepEqual(out.failed, []);
  assert.equal(Object.values(out.thumbnails).filter((v) => v.url).length, 8);
});

test('one question that fails keeps the cards of the others', async () => {
  const list = ids(22);
  const r = fakeRenderer(new Set(['q20']));
  const out = await renderThumbnailGroups({ questions: questionsOf(list), qids: list, renderGroup: r.renderGroup });
  assert.deepEqual(out.failed, ['q20']);
  assert.match(out.thumbnails.q20.error, /^render_failed: ! Misplaced/);
  assert.equal(Object.values(out.thumbnails).filter((v) => v.url).length, 21);
  assert.equal(out.pageCount, 21);
  // 22문항을 하나씩 찍지 않는다(반씩 나눈다).
  assert.ok(r.calls.length <= 11, `calls ${r.calls.length}`);
  // 문항과 id 가 같은 순서로 나뉜다.
  assert.ok(r.calls.includes('q20'));
});

test('two failing questions are both isolated', async () => {
  const list = ids(8);
  const r = fakeRenderer(new Set(['q2', 'q7']));
  const out = await renderThumbnailGroups({ questions: questionsOf(list), qids: list, renderGroup: r.renderGroup });
  assert.deepEqual(out.failed.sort(), ['q2', 'q7']);
  assert.equal(Object.values(out.thumbnails).filter((v) => v.url).length, 6);
});

test('a renderer that always fails stops after the failure budget', async () => {
  const list = ids(40);
  const r = fakeRenderer(new Set(list));
  const out = await renderThumbnailGroups({ questions: questionsOf(list), qids: list, renderGroup: r.renderGroup, maxFailedRenders: 5 });
  assert.equal(r.calls.length, 5);
  assert.equal(out.failed.length, 40);
  assert.equal(Object.values(out.thumbnails).filter((v) => v.url).length, 0);
  assert.match(out.firstError, /Misplaced/);
  assert.ok(Object.values(out.thumbnails).some((v) => /^render_skipped/.test(v.error)));
});
