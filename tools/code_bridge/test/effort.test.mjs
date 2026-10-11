import assert from 'node:assert/strict';
import { test } from 'node:test';
import { DEFAULT_MODEL, loadConfig, requestEffort, resolveModelSelection, usedEffort } from '../src/lib.mjs';

const env = { CODE_BRIDGE_WORKER_TOKEN: 't', CURSOR_API_KEY: 'k' };
const p = (context, effort, fast) => [
  { id: 'context', value: context },
  { id: 'reasoning_effort', value: effort },
  { id: 'fast', value: fast },
];
// 2026-10-10 Cursor.models.list()의 grok-4.7 모양(줄임)
const grok47 = {
  id: 'grok-4.7',
  displayName: 'Grok 4.7',
  parameters: [
    { id: 'context', values: [{ value: '256k' }, { value: '500k' }] },
    { id: 'reasoning_effort', values: ['low', 'medium', 'high', 'xhigh'].map((value) => ({ value })) },
    { id: 'fast', values: [{ value: 'false' }, { value: 'true' }] },
  ],
  variants: ['256k', '500k'].flatMap((c) =>
    ['low', 'medium', 'high', 'xhigh'].flatMap((e) =>
      ['false', 'true'].map((f) => ({ params: p(c, e, f), displayName: `Grok 4.7 ${e}`, isDefault: c === '500k' && e === 'high' && f === 'true' })),
    ),
  ),
};
const grok45 = {
  id: 'grok-4.5',
  parameters: [{ id: 'effort', values: ['low', 'medium', 'high'].map((value) => ({ value })) }],
  variants: ['low', 'medium', 'high'].map((e) => ({ params: [{ id: 'effort', value: e }], isDefault: e === 'high' })),
};
const composer = { id: 'composer-2.5', aliases: ['composer'], parameters: [{ id: 'fast', values: [{ value: 'false' }, { value: 'true' }] }] };
const catalog = [grok47, grok45, composer];

test('기본 모델은 grok-4.7, 환경 변수로 바꿀 수 있다', () => {
  assert.equal(DEFAULT_MODEL, 'grok-4.7');
  assert.equal(loadConfig(env).model, 'grok-4.7');
  assert.equal(loadConfig({ ...env, CODE_BRIDGE_MODEL: ' composer-2.5 ' }).model, 'composer-2.5');
  assert.equal(loadConfig({ ...env, CODE_BRIDGE_MODEL: ' ' }).model, 'grok-4.7');
});

test('요청 강도: medium·high·xhigh만, 비었거나 모르는 값은 high', () => {
  assert.equal(requestEffort({ request: { effort: 'xhigh' } }), 'xhigh');
  assert.equal(requestEffort({ request: { effort: 'medium' } }), 'medium');
  for (const bad of [undefined, null, 'low', 'max', 3]) assert.equal(requestEffort({ request: { effort: bad } }), 'high');
  assert.equal(requestEffort({}), 'high', '옛 요청');
});

test('grok-4.7: 강도만 바꾸고 나머지는 Cursor 기본 조합(500k, fast)을 따른다', () => {
  for (const e of ['medium', 'high', 'xhigh']) {
    const out = resolveModelSelection(catalog, 'grok-4.7', e);
    assert.equal(out.effort, e);
    assert.equal(out.selection.id, 'grok-4.7');
    assert.deepEqual(
      [...out.selection.params].sort((a, b) => a.id.localeCompare(b.id)),
      [{ id: 'context', value: '500k' }, { id: 'fast', value: 'true' }, { id: 'reasoning_effort', value: e }],
    );
  }
});

test('지원하지 않는 강도는 가장 가까운 값, 강도 옵션이 없거나 목록이 없으면 id만', () => {
  const g45 = resolveModelSelection(catalog, 'grok-4.5', 'xhigh');
  assert.equal(g45.effort, 'high');
  assert.deepEqual(g45.selection, { id: 'grok-4.5', params: [{ id: 'effort', value: 'high' }] });
  assert.deepEqual(resolveModelSelection(catalog, 'composer', 'high'), { selection: { id: 'composer-2.5' }, effort: null });
  assert.deepEqual(resolveModelSelection(null, 'grok-4.7', 'high'), { selection: { id: 'grok-4.7' }, effort: null });
  assert.deepEqual(resolveModelSelection(catalog, 'unknown-x', 'high'), { selection: { id: 'unknown-x' }, effort: null });
});

test('목록에 없는 조합은 만들지 않고, 강도가 맞는 실제 조합 중 기본과 가장 닮은 것을 쓴다', () => {
  const sparse = {
    ...grok47,
    variants: [
      { params: p('500k', 'high', 'true'), isDefault: true },
      { params: p('256k', 'medium', 'false') },
    ],
  };
  const out = resolveModelSelection([sparse], 'grok-4.7', 'medium');
  assert.equal(out.effort, 'medium');
  assert.deepEqual(out.selection.params, p('256k', 'medium', 'false'));
});

test('실제 강도: 실행 결과의 모델 옵션을 먼저 보고, 없으면 고른 값', () => {
  assert.equal(usedEffort({ id: 'grok-4.7', params: [{ id: 'reasoning_effort', value: 'xhigh' }] }, 'high'), 'xhigh');
  assert.equal(usedEffort({ id: 'grok-4.7' }, 'high'), 'high');
  assert.equal(usedEffort(undefined, null), null);
});
