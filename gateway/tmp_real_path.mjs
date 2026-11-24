// 임시: 실제 경로(pb-api /pb/preview/batch-render)로 교재 문항 하나의 카드를 찍어 받아 본다.
//   앱의 카드 새로고침과 같은 요청이다(그 문항의 저장 카드가 지금 엔진으로 다시 찍힌다).
import 'dotenv/config';
import fs from 'node:fs';
import path from 'node:path';
import { createClient } from '@supabase/supabase-js';

const academyId = '3ff51b8d-3cfb-4a36-a1a1-b63aebbde677';
const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const { data: rows, error } = await supa.from('pb_questions').select('id, question_number, stem, meta')
  .eq('academy_id', academyId).eq('source_type_code', 'market_book').eq('is_published', true)
  .like('stem', '%오른쪽%표%[표시작]%').limit(40);
if (error) {
  console.log(`조회 실패: ${error.message}`);
  process.exit(1);
}
// 표가 본문 끝에 하나 있고 저장된 표 위치가 없는 문항 하나.
const pick = (rows || []).find((q) => (q.stem.match(/\[표시작\]/g) || []).length === 1 && /\[표끝\]\s*$/.test(q.stem) && !q.meta?.table_layout);
if (!pick) {
  console.log('맞는 문항 없음');
  process.exit(1);
}
const port = process.env.PB_API_PORT || '8787';
const res = await fetch(`http://127.0.0.1:${port}/pb/preview/batch-render`, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', 'x-api-key': process.env.PB_API_KEY || '' },
  body: JSON.stringify({ academyId, questionIds: [pick.id] }),
});
const json = await res.json();
const thumb = json?.thumbnails?.[pick.id];
const url = typeof thumb === 'string' ? thumb : thumb?.url || thumb?.signedUrl || '';
console.log(`문항 ${pick.question_number} (${pick.id}) · 응답 ${res.status} · ok=${json?.ok} · 카드 꼴: ${thumb && typeof thumb === 'object' ? Object.keys(thumb).join(',') : typeof thumb}`);
if (!url) process.exit(1);
const img = await fetch(url);
fs.writeFileSync(path.resolve('build_side', 'real_path.png'), Buffer.from(await img.arrayBuffer()));
console.log('build_side/real_path.png');
