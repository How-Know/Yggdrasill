import test from 'node:test';
import assert from 'node:assert/strict';

import {
  computeM5SyncFingerprint,
  createM5HomeworksEnvelope,
  sanitizeGroupsForDevicePayload
} from '../src/m5_sync_fingerprint.js';
import { isM5SyncAckMatch } from '../src/m5_sync_ack.js';

test('fingerprint is stable across object key order', () => {
  const left = [{ group_id: 'g1', phase: 2, children: [{ id: 'i1', page: 3 }] }];
  const right = [{ children: [{ page: 3, id: 'i1' }], phase: 2, group_id: 'g1' }];
  assert.equal(computeM5SyncFingerprint(left), computeM5SyncFingerprint(right));
});

test('device payload limits are applied before envelope fingerprinting', () => {
  const groups = Array.from({ length: 3 }, (_, groupIndex) => ({
    group_id: `g${groupIndex}`,
    children: Array.from({ length: 4 }, (_, childIndex) => ({
      id: `g${groupIndex}-i${childIndex}`
    }))
  }));
  const sanitized = sanitizeGroupsForDevicePayload(groups, {
    groupLimit: 2,
    childrenLimit: 2
  });
  const envelope = createM5HomeworksEnvelope({
    academyId: 'a1',
    deviceId: 'm5-device-010',
    studentId: 's1',
    groups: sanitized,
    syncSeq: 7,
    publishedAt: '2026-08-06T00:00:00.000Z'
  });

  assert.equal(envelope.groups.length, 2);
  assert.equal(envelope.groups[0].children.length, 2);
  assert.equal(envelope.meta.sync_fp, computeM5SyncFingerprint(sanitized));
  assert.equal(envelope.meta.sync_seq, 7);
});

test('sync ack only matches a successful apply with the latest fingerprint', () => {
  const expected = '0123456789abcdef';
  assert.equal(
    isM5SyncAckMatch(expected, {
      type: 'homeworks_apply',
      ok: true,
      sync_fp: expected
    }),
    true
  );
  assert.equal(
    isM5SyncAckMatch(expected, {
      type: 'homeworks_apply',
      ok: true,
      sync_fp: 'fedcba9876543210'
    }),
    false
  );
  assert.equal(
    isM5SyncAckMatch(expected, {
      type: 'homeworks_apply',
      ok: false,
      sync_fp: expected
    }),
    false
  );
});
