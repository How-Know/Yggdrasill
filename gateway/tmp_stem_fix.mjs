// 임시: 저장된 본문을 읽어 "바꿀 본문" 을 build_side/stem_fix.json 에 적는다(DB 에는 쓰지 않는다).
//   - 2017 수능 나형 7: 머리 두 행(지역 A / 지역 B + \multirow) → \diagbox 한 행
//   - 행 끝이 `\` 하나인 표 12문항: 표 안의 줄 끝 `\` → `\\`
import 'dotenv/config';
import fs from 'node:fs';
import path from 'node:path';
import { createClient } from '@supabase/supabase-js';
import { normalizeTabularRowEnds } from './src/problem_bank/render_engine/xelatex_v2/template.js';

const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const out = {};
const report = [];
const { data: diagQ } = await supa.from('pb_questions').select('id, stem').eq('question_uid', 'b379eed2-142b-4d4f-821c-6611f5307e41').maybeSingle();
if (diagQ) {
  const re = /\\text\{지역 A\}\s*&\s*\\multirow\{2\}\{\*\}\{(\\text\{희망함\})\}\s*&\s*\\multirow\{2\}\{\*\}\{(\\text\{희망하지 않음\})\}\s*&\s*\\multirow\{2\}\{\*\}\{(\\text\{합계\})\}\s*\\\\\s*\\text\{지역 B\}\s*&\s*&\s*&\s*\\\\/;
  const next = diagQ.stem.replace(re, (_m, a, b, c) => `\\diagbox{\\text{지역 B}}{\\text{지역 A}} & ${a} & ${b} & ${c} \\\\`);
  report.push(`2017 나형 7: ${next !== diagQ.stem ? '바뀜' : '패턴 없음'}`);
  if (next !== diagQ.stem) out[diagQ.id] = next;
}
const ids = fs.readFileSync(path.resolve('build_side', 'rowend_ids.txt'), 'utf8').split(/\r?\n/).map((s) => s.trim()).filter(Boolean).map((s) => s.split(/\s+/));
for (const [id, name] of ids) {
  const { data: q } = await supa.from('pb_questions').select('id, stem').eq('id', id).maybeSingle();
  if (!q) {
    report.push(`${name}: 읽지 못함`);
    continue;
  }
  let changed = 0;
  const next = q.stem.replace(/(\\begin\{tabular\}\{[^}]*\})([\s\S]*?)(\\end\{tabular\})/g, (_m, open, body, close) => {
    const fixed = normalizeTabularRowEnds(body);
    changed += (fixed.length - body.length);
    return open + fixed + close;
  });
  report.push(`${name}: 행 끝 ${changed}곳`);
  if (next !== q.stem) out[q.id] = next;
}
fs.writeFileSync(path.resolve('build_side', 'stem_fix.json'), JSON.stringify(out, null, 1));
console.log(report.join('\n'));
