// 임시(읽기만): 검수 문항(crop id)의 반영 대기 본문을 build_side/staged_stem.json 에 { 문항 id: 본문 } 으로 적는다.
import 'dotenv/config';
import fs from 'node:fs';
import path from 'node:path';
import { createClient } from '@supabase/supabase-js';

const [cropId, questionId] = process.argv.slice(2);
const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const { data, error } = await supa.from('textbook_problem_analyses').select('staged_changes').eq('crop_id', cropId).maybeSingle();
if (error || !data) {
  console.log(`읽지 못함: ${error?.message || '없음'}`);
  process.exit(1);
}
const staged = data.staged_changes || {};
const stemEntry = staged.stem;
const stem = typeof stemEntry === 'string' ? stemEntry : stemEntry?.value ?? stemEntry?.after ?? null;
console.log(`반영 대기 필드: ${Object.keys(staged).join(', ')} · 본문 꼴: ${typeof stemEntry === 'object' && stemEntry ? Object.keys(stemEntry).join(',') : typeof stemEntry}`);
if (typeof stem !== 'string') process.exit(1);
fs.writeFileSync(path.resolve('build_side', 'staged_stem.json'), JSON.stringify({ [questionId]: stem }, null, 1));
const at = stem.indexOf('[표시작]');
console.log(at < 0 ? '표 없음' : stem.slice(Math.max(0, at - 60), at + 420));
