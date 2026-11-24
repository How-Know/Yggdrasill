// 임시(읽기만): 2019 수능 나형 13 반영 대기 본문의 `a | b` 줄 표를 엔진이 읽는 표 형식으로 바꾼 본문을
//   build_side/na13_fix.json 에 적는다. 형식은 같은 회차 가형 18 의 저장 본문과 같게 한다.
import 'dotenv/config';
import fs from 'node:fs';
import path from 'node:path';
import { createClient } from '@supabase/supabase-js';

const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const qid = 'f5b46784-0aa4-4528-a0ee-fc096acccb85';
const staged = JSON.parse(fs.readFileSync(path.resolve('build_side', 'staged_stem.json'), 'utf8'))[qid];
const { data: ref } = await supa.from('pb_questions').select('stem').eq('id', '0a4360e5-52db-4e46-b93a-1119403df9c5').maybeSingle();
const refAt = ref.stem.indexOf('[표시작]');
console.log('--- 가형 18 표 ---');
console.log(ref.stem.slice(refAt, ref.stem.indexOf('[표끝]') + 5));
// 값이 가형 18 의 표와 같으므로(0.5~2.0, 0.1915~0.4772) 그 표 글을 그대로 쓴다.
const refTable = ref.stem.slice(refAt, ref.stem.indexOf('[표끝]') + 5);
const next = staged.replace(/\[표시작\]\n[\s\S]*?\n\[표끝\]/, () => refTable);
console.log('--- 나형 13 바꾼 표 ---');
console.log(next.slice(next.indexOf('[표시작]')));
fs.writeFileSync(path.resolve('build_side', 'na13_fix.json'), JSON.stringify({ [qid]: next }, null, 1));
