import test from 'node:test';
import assert from 'node:assert/strict';

import { normalizeDetectResult } from '../src/textbook/vlm_detect_client.js';

test('normalizeDetectResult accepts single-wrapped bbox arrays', () => {
  const result = normalizeDetectResult({
    section: 'type_practice',
    page_kind: 'problem_page',
    page_layout: 'two_column',
    items: [
      {
        number: '0168',
        label: '중',
        is_set_header: false,
        set_range: null,
        content_group: { kind: 'none', label: '', title: '', order: null },
        column: 1,
        bbox: [[79, 58, 93, 128]],
        item_region: [[102, 58, 220, 418]],
      },
    ],
    notes: '',
  });

  assert.equal(result.items.length, 1);
  assert.deepEqual(result.items[0].bbox, [79, 58, 93, 128]);
  assert.deepEqual(result.items[0].item_region, [102, 58, 220, 418]);
});

test('normalizeDetectResult backfills missing item regions for vertical textbook pages', () => {
  const result = normalizeDetectResult({
    section: 'type_practice',
    page_kind: 'problem_page',
    page_layout: 'two_column',
    items: [
      {
        number: '0168',
        label: '중',
        content_group: { kind: 'none', label: '', title: '', order: null },
        column: 1,
        bbox: [79, 58, 93, 128],
      },
      {
        number: '0169',
        label: '상',
        content_group: { kind: 'none', label: '', title: '', order: null },
        column: 1,
        bbox: [382, 58, 396, 186],
      },
      {
        number: '0171',
        label: '하',
        content_group: { kind: 'none', label: '', title: '', order: null },
        column: 2,
        bbox: [79, 503, 93, 573],
      },
    ],
    notes: '',
  });

  assert.deepEqual(result.items[0].item_region, [100, 56, 374, 495]);
  assert.deepEqual(result.items[1].item_region, [403, 56, 980, 495]);
  assert.deepEqual(result.items[2].item_region, [100, 501, 980, 904]);
});
