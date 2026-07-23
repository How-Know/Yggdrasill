import { createHash } from 'crypto';

const DEFAULT_GROUP_LIMIT = 8;
const DEFAULT_CHILDREN_LIMIT = 3;

function stableNormalize(value) {
  if (Array.isArray(value)) {
    return value.map(stableNormalize);
  }
  if (value && typeof value === 'object') {
    return Object.keys(value)
      .sort()
      .reduce((acc, key) => {
        acc[key] = stableNormalize(value[key]);
        return acc;
      }, {});
  }
  return value;
}

export function stableStringify(value) {
  return JSON.stringify(stableNormalize(value));
}

export function sanitizeGroupsForDevicePayload(
  groups,
  { groupLimit = DEFAULT_GROUP_LIMIT, childrenLimit = DEFAULT_CHILDREN_LIMIT } = {}
) {
  if (!Array.isArray(groups)) return [];
  const trimmed = groups.slice(0, groupLimit);
  return trimmed.map((group) => {
    if (!group || typeof group !== 'object') return group;
    const children = Array.isArray(group.children)
      ? group.children.slice(0, childrenLimit)
      : group.children;
    return { ...group, children };
  });
}

export function computeM5SyncFingerprint(groups) {
  return createHash('sha256')
    .update(stableStringify(groups))
    .digest('hex')
    .slice(0, 16);
}

export function createM5HomeworksEnvelope({
  academyId,
  deviceId,
  studentId,
  groups,
  source = 'unknown',
  syncSeq = 0,
  publishedAt = new Date().toISOString()
}) {
  const payloadGroups = Array.isArray(groups) ? groups : [];
  return {
    groups: payloadGroups,
    meta: {
      sync_seq: syncSeq,
      sync_fp: computeM5SyncFingerprint(payloadGroups),
      source,
      academy_id: academyId,
      device_id: deviceId,
      student_id: studentId,
      published_at: publishedAt,
      group_count: payloadGroups.length
    }
  };
}
