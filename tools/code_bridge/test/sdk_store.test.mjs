import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, test } from 'node:test';
import { SqliteLocalAgentStore } from '@cursor/sdk/sqlite';
import { sdkStateRoot, sdkStorePathFits } from '../src/lib.mjs';

const ID = 'd6edbfa8-ea23-44c6-899c-838e54044368';
const dirs = [];
after(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

async function saveCheckpoint(store) {
  const agentId = 'agent-11111111-2222-3333-4444-555555555555';
  await store.checkpoints.create({ agentId, blobId: 'ab'.repeat(32), data: new Uint8Array([1, 2, 3]) });
  return store.checkpoints.get({ agentId, blobId: 'ab'.repeat(32) });
}

test('요청별 대화 기록 폴더는 짧고 Windows 길이 한도 안에 든다', () => {
  const root = sdkStateRoot(ID);
  assert.ok(root.endsWith(join('ygg-code-bridge', 'sdk', ID)));
  assert.equal(sdkStorePathFits(root, 'win32'), true);
  assert.equal(sdkStorePathFits(`C:\\${'x'.repeat(170)}`, 'win32'), false);
  assert.equal(sdkStorePathFits(`/${'x'.repeat(400)}`, 'linux'), true);
});

test('짧은 폴더의 SQLite 기록에는 대화 체크포인트가 저장된다', async () => {
  const base = mkdtempSync(join(tmpdir(), 'cb-sdk-'));
  dirs.push(base);
  const store = await SqliteLocalAgentStore.open({ workspaceRef: join(base, 'work'), stateRoot: sdkStateRoot(ID, base) });
  try {
    assert.deepEqual([...(await saveCheckpoint(store))], [1, 2, 3]);
  } finally {
    await store.dispose();
  }
});

test('SDK 기본 위치는 %TEMP% 복사본에서 260자를 넘어 체크포인트를 열지 못한다', { skip: process.platform !== 'win32' }, async () => {
  const work = join(tmpdir(), 'ygg-code-bridge', '00000000-0000-4000-8000-000000000000');
  const store = await SqliteLocalAgentStore.open({ workspaceRef: work });
  dirs.push(join(store.stateRoot, '..', '..'));
  try {
    assert.ok(store.stateRoot.startsWith(join(homedir(), '.cursor', 'projects')));
    assert.equal(sdkStorePathFits(store.stateRoot, 'win32'), false);
    await assert.rejects(saveCheckpoint(store), /unable to open database file/);
  } finally {
    await store.dispose();
  }
});
