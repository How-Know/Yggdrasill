// 로컬 모의고사 PDF 를 mock_exams 에 등록한다.
// 매니저 업로드 대화상자와 같은 파일명 규칙을 쓴다.
//   node scripts/mock_exam_enqueue.mjs --academy <uuid|auto> <pdf> [<pdf> ...]
//   node scripts/mock_exam_enqueue.mjs --register --academy auto --dir <folder>
// --register 는 파일만 올리고 추출 대기열에는 넣지 않는다.
// 이미 review 인 시험의 문제지·해설은 바꾸지 않는다.
import 'dotenv/config';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { createClient } from '@supabase/supabase-js';
import {
  collectPdfs,
  parseMockFileName,
  registerMockPdfs,
  resolveAcademyId,
} from '../src/mock_exam/register_files.js';

export { parseMockFileName };

async function main() {
  const args = process.argv.slice(2);
  const register = args.includes('--register');
  const ai = args.indexOf('--academy');
  const academyArg = ai >= 0 ? args[ai + 1] : '';
  const di = args.indexOf('--dir');
  const dir = di >= 0 ? args[di + 1] : '';
  const skip = new Set([ai, ai + 1, di, di + 1, args.indexOf('--register')]);
  const files = [];
  if (dir) collectPdfs(dir, files);
  args.forEach((arg, i) => {
    if (!skip.has(i) && !arg.startsWith('--')) files.push(arg);
  });
  if (!academyArg || files.length === 0) {
    throw new Error('usage: --academy <uuid|auto> [--register] [--dir <folder>] <pdf> ...');
  }
  const parsed = [];
  const unreadable = [];
  for (const file of files) {
    const row = parseMockFileName(file);
    if (!row) unreadable.push(file);
    else parsed.push(row);
  }
  if (!register && unreadable.length > 0) {
    throw new Error(`파일명을 읽지 못함: ${unreadable[0]}`);
  }
  const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const academyId = await resolveAcademyId(supa, academyArg);
  const summary = await registerMockPdfs(supa, academyId, parsed, { queue: !register });
  summary.unreadable = unreadable;
  if (register) {
    const out = path.join(os.tmpdir(), 'mock_exam_register_summary.json');
    fs.writeFileSync(out, JSON.stringify(summary, null, 2));
    console.log(`summary ${out}`);
  }
}

const invokedDirectly =
  process.argv[1] &&
  import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;
if (invokedDirectly) {
  main().catch((err) => {
    console.error(err?.message || err);
    process.exit(1);
  });
}
