import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// 크롭 저장 API 의 sub_key 화이트리스트가 DB CHECK 제약보다 좁으면, DB 는
// 받아주는데 API 가 400 으로 막아서 저장 단계에서만 터진다. 실제로 개념+유형
// 'F'(한 번 더 연습) 슬롯을 추가할 때 마이그레이션만 고쳐서 sync-scope 가
// invalid_sub_key 로 실패했다. 두 목록이 갈라지지 않게 고정한다.

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, '..', '..');

function latestSubKeyCheck(table) {
  const dir = path.join(repoRoot, 'supabase', 'migrations');
  const pattern = new RegExp(
    `${table}_sub_key_chk[\\s\\S]*?check\\s*\\(\\s*sub_key\\s+in\\s*\\(([^)]*)\\)`,
    'i',
  );
  let found = null;
  for (const name of fs.readdirSync(dir).sort()) {
    if (!name.endsWith('.sql')) continue;
    const match = fs.readFileSync(path.join(dir, name), 'utf8').match(pattern);
    if (match) found = match[1];
  }
  assert.ok(found, `${table} 의 sub_key CHECK 제약을 마이그레이션에서 찾지 못했다`);
  return found
    .split(',')
    .map((s) => s.trim().replace(/^'|'$/g, ''))
    .filter(Boolean)
    .sort();
}

function apiSubKeys() {
  const source = fs.readFileSync(
    path.join(repoRoot, 'gateway', 'src', 'problem_bank_api.js'),
    'utf8',
  );
  const match = source.match(
    /const TEXTBOOK_CROP_SUB_KEYS = Object\.freeze\(\[([^\]]*)\]\)/,
  );
  assert.ok(match, 'problem_bank_api.js 에 TEXTBOOK_CROP_SUB_KEYS 상수가 없다');
  return match[1]
    .split(',')
    .map((s) => s.trim().replace(/^'|'$/g, ''))
    .filter(Boolean)
    .sort();
}

test('crops API sub_key whitelist matches the DB CHECK constraint', () => {
  assert.deepEqual(apiSubKeys(), latestSubKeyCheck('textbook_problem_crops'));
});

test('extract runs and crops share the same sub_key set', () => {
  assert.deepEqual(
    latestSubKeyCheck('textbook_pb_extract_runs'),
    latestSubKeyCheck('textbook_problem_crops'),
  );
});

test('no handler hardcodes a sub_key list beside the shared constant', () => {
  const source = fs.readFileSync(
    path.join(repoRoot, 'gateway', 'src', 'problem_bank_api.js'),
    'utf8',
  );
  const inline = source.match(/\[\s*'A',\s*'B',\s*'C'(?:,\s*'[A-Z]')*\s*\]/g);
  assert.equal(
    inline,
    null,
    `sub_key 목록을 인라인으로 적은 곳이 남아 있다: ${inline}`,
  );
});
