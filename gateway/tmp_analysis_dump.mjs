// 임시(읽기만): 검수 문항(crop id)의 분석 행을 열 이름과 값(길면 자름)으로 적는다.
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const [cropId, max = '500'] = process.argv.slice(2);
const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const { data, error } = await supa.from('textbook_problem_analyses').select('*').eq('crop_id', cropId).maybeSingle();
if (error || !data) {
  console.log(`읽지 못함: ${error?.message || '없음'}`);
  process.exit(1);
}
const cut = (v) => {
  if (v == null) return null;
  const s = typeof v === 'string' ? v : JSON.stringify(v);
  return s.length > Number(max) ? `${s.slice(0, Number(max))}… (${s.length}자)` : s;
};
for (const [k, v] of Object.entries(data)) {
  if (v == null || v === '' || (Array.isArray(v) && v.length === 0)) continue;
  if (k === 'staged_changes' && v && typeof v === 'object') {
    for (const [k2, v2] of Object.entries(v)) console.log(`staged.${k2}: ${cut(v2)}`);
    continue;
  }
  console.log(`${k}: ${cut(v)}`);
}
