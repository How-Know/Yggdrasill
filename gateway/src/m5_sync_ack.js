export function isM5SyncAckMatch(expectedFingerprint, message) {
  const expected = (expectedFingerprint || '').toString();
  const applied = (message?.sync_fp || '').toString();
  return (
    message?.type === 'homeworks_apply' &&
    message?.ok !== false &&
    expected.length > 0 &&
    applied === expected
  );
}
