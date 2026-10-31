// 로컬 모의고사 PDF 를 mock_exams 에 등록하고 추출 대기열에 넣는다.
// 매니저 업로드 대화상자와 같은 파일명 규칙을 쓴다.
//   node scripts/mock_exam_enqueue.mjs --academy <uuid> <pdf> [<pdf> ...]
import 'dotenv/config';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { createClient } from '@supabase/supabase-js';

const FILE_RE =
  /^(\d{4})\s*고\s*([123])\s*(\d{1,2})\s*월\s*(교육청|평가원|수능)\s*(?:\(\s*(확통|확률과\s*통계|미적분?|기하)\s*\))?\s*(?:[-_]\s*(해설))?\s*$/;
const ORG = { 교육청: 'edu', 평가원: 'kice', 수능: 'csat' };
const ORG_LABEL = { edu: '교육청', kice: '평가원', csat: '수능' };

function electiveOf(raw) {
  const s = String(raw || '').replace(/\s+/g, '');
  if (s.startsWith('확')) return 'probstats';
  if (s.startsWith('미')) return 'calculus';
  if (s.startsWith('기')) return 'geometry';
  return '';
}

export function parseMockFileName(file) {
  if (path.extname(file).toLowerCase() !== '.pdf') return null;
  const m = FILE_RE.exec(path.basename(file, path.extname(file)).trim());
  if (!m) return null;
  const grade = Number(m[2]);
  const elective = electiveOf(m[5]);
  if ((grade === 3) !== Boolean(elective)) return null;
  return {
    file,
    examYear: Number(m[1]),
    grade,
    month: Number(m[3]),
    org: ORG[m[4]],
    elective,
    kind: m[6] ? 'solution' : 'problem',
  };
}

async function main() {
  const args = process.argv.slice(2);
  const ai = args.indexOf('--academy');
  const academyId = ai >= 0 ? args[ai + 1] : '';
  const files = args.filter((a, i) => i !== ai && i !== ai + 1);
  if (!academyId || files.length === 0) {
    throw new Error('usage: --academy <uuid> <pdf> [<pdf> ...]');
  }
  const parsed = files.map((f) => {
    const p = parseMockFileName(f);
    if (!p) throw new Error(`파일명을 읽지 못함: ${f}`);
    return p;
  });
  const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const groups = new Map();
  for (const p of parsed) {
    const key = `${p.grade}|${p.examYear}|${p.month}|${p.org}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(p);
  }
  for (const group of groups.values()) {
    const head = group[0];
    const title = `${head.examYear} 고${head.grade} ${head.month}월 ${ORG_LABEL[head.org]}`;
    const { data: exam, error } = await supa
      .from('mock_exams')
      .upsert(
        {
          academy_id: academyId,
          grade: head.grade,
          exam_year: head.examYear,
          school_year: head.grade === 3 ? head.examYear + 1 : head.examYear,
          exam_month: head.month,
          org: head.org,
          title,
        },
        { onConflict: 'academy_id,grade,exam_year,exam_month,org' },
      )
      .select('id, status')
      .single();
    if (error) throw new Error(`mock_exams upsert: ${error.message}`);
    if (exam.status === 'queued' || exam.status === 'running') {
      console.log(`skip (추출 중): ${title}`);
      continue;
    }
    for (const p of group) {
      const bytes = fs.readFileSync(p.file);
      const objectPath = `${academyId}/mock-exams/${exam.id}/${p.kind}_${p.elective || 'common'}_${Date.now()}.pdf`;
      const up = await supa.storage
        .from('problem-documents')
        .upload(objectPath, bytes, { contentType: 'application/pdf', upsert: false });
      if (up.error) throw new Error(`storage upload: ${up.error.message}`);
      const { error: paperErr } = await supa.from('mock_exam_papers').upsert(
        {
          academy_id: academyId,
          exam_id: exam.id,
          kind: p.kind,
          elective: p.elective,
          storage_bucket: 'problem-documents',
          storage_path: objectPath,
          file_name: path.basename(p.file),
          sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
          size_bytes: bytes.length,
          page_count: null,
        },
        { onConflict: 'exam_id,kind,elective' },
      );
      if (paperErr) throw new Error(`mock_exam_papers upsert: ${paperErr.message}`);
    }
    const { error: qErr } = await supa
      .from('mock_exams')
      .update({ status: 'queued', stage: '', last_error: '', progress: { request: 'all' } })
      .eq('id', exam.id);
    if (qErr) throw new Error(`queue: ${qErr.message}`);
    console.log(`queued ${title} (${exam.id}) files=${group.length}`);
  }
}

main().catch((err) => {
  console.error(err?.message || err);
  process.exit(1);
});
