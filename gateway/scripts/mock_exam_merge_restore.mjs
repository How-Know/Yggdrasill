// 합치기(mock_exam_merge_same.mjs --apply)를 기록 파일로 되돌린다.
//   node scripts/mock_exam_merge_restore.mjs --file <기록 파일.json>            되돌릴 수 있는지만 본다 (DB 를 바꾸지 않는다)
//   node scripts/mock_exam_merge_restore.mjs --file <기록 파일.json> --apply    되돌린다
// 지운 문항·크롭·검수 기록을 다시 넣고, 자리를 합치기 전 값으로 돌린다.

import 'dotenv/config';
import fs from 'node:fs';
import { createClient } from '@supabase/supabase-js';
import { checkMergeRestore, restoreMergeBackup } from '../src/mock_exam/merge_same.js';

async function main() {
  const argv = process.argv.slice(2);
  const file = argv.includes('--file') ? String(argv[argv.indexOf('--file') + 1] || '') : '';
  if (!file) {
    console.error('사용: node scripts/mock_exam_merge_restore.mjs --file <기록 파일.json> [--apply]');
    process.exit(2);
  }
  const backup = JSON.parse(fs.readFileSync(file, 'utf8'));
  const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });
  const slot = backup?.plan?.slot || {};
  const rows = Object.entries(backup?.tables || {}).map(([table, list]) => `${table} ${list.length}`).join(', ');
  console.log(`기록: ${slot.section} ${slot.number}번 자리 (${backup?.takenAt}) / ${rows}`);
  const reason = await checkMergeRestore(supa, backup);
  if (reason) {
    console.log(`되돌릴 수 없음: ${reason}`);
    process.exit(1);
  }
  if (!argv.includes('--apply')) {
    console.log('되돌릴 수 있음 (--apply 를 붙이면 되돌린다)');
    return;
  }
  const result = await restoreMergeBackup(supa, backup);
  console.log(`되돌림: 넣음 ${JSON.stringify(result.inserted)} / 건너뜀 ${JSON.stringify(result.skipped)}`);
}

main().catch((e) => {
  console.error(e?.message || e);
  process.exit(1);
});
