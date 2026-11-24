// 임시: build_side/stem_fix.json 의 본문을 pb_questions.stem 에 쓴다(승인된 13문항).
//   고치기 전 본문은 저장소 밖 백업 파일에 먼저 적는다. --apply 가 없으면 쓰지 않고 차이만 센다.
import 'dotenv/config';
import fs from 'node:fs';
import path from 'node:path';
import { createClient } from '@supabase/supabase-js';

const apply = process.argv.includes('--apply');
const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const fix = JSON.parse(fs.readFileSync(path.resolve('build_side', 'stem_fix.json'), 'utf8'));
const ids = Object.keys(fix);
const { data: rows, error } = await supa.from('pb_questions').select('id, question_number, stem, updated_at').in('id', ids);
if (error) {
  console.log(`읽기 실패: ${error.message}`);
  process.exit(1);
}
const backupDir = path.join(process.env.LOCALAPPDATA, 'Yggdrasill');
const backupPath = path.join(backupDir, 'stem_fix_backup_20261123.json');
if (apply) {
  if (fs.existsSync(backupPath)) {
    console.log('백업 파일이 이미 있다. 덮어쓰지 않고 멈춘다.');
    process.exit(1);
  }
  fs.writeFileSync(backupPath, JSON.stringify(rows, null, 1));
  console.log(`백업 ${rows.length}문항: ${backupPath}`);
}
let done = 0;
for (const row of rows) {
  const next = fix[row.id];
  // 바뀌는 글자만 센다: 줄 끝 `\` 추가 또는 대각선 칸 한 행.
  const delta = next.length - row.stem.length;
  if (next === row.stem) {
    console.log(`${row.question_number}: 이미 같음`);
    continue;
  }
  if (!apply) {
    console.log(`${row.question_number}: 길이 ${row.stem.length} → ${next.length} (${delta >= 0 ? '+' : ''}${delta})`);
    continue;
  }
  const { error: upErr } = await supa.from('pb_questions').update({ stem: next }).eq('id', row.id);
  if (upErr) {
    console.log(`${row.question_number}: 쓰기 실패 ${upErr.message}`);
    continue;
  }
  const { data: after } = await supa.from('pb_questions').select('stem').eq('id', row.id).maybeSingle();
  console.log(`${row.question_number}: ${after?.stem === next ? '씀·확인' : '쓴 뒤 값이 다름'}`);
  if (after?.stem === next) done += 1;
}
console.log(`끝: 대상 ${ids.length}, 읽음 ${rows.length}, ${apply ? `씀 ${done}` : '쓰지 않음'}`);
