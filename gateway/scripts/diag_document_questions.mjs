// 추출된 문서의 문항 번호와 crop 연결을 본다 (읽기 전용).
//
// 사용: node scripts/diag_document_questions.mjs <document_id>
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

// 문서 id 를 모를 때는 런 좌표로도 찾을 수 있다:
//   node scripts/diag_document_questions.mjs --run <book_id> <grade> <big> <mid> <sub_key> <sub_index>
const argv = process.argv.slice(2);

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

let documentId = '';
if (argv[0] === '--run') {
  const [, bookId, grade, big, mid, subKey, subIndex] = argv;
  const { data, error: runError } = await supabase
    .from('textbook_pb_extract_runs')
    .select('pb_document_id')
    .eq('book_id', bookId)
    .eq('grade_label', grade)
    .eq('big_order', Number(big))
    .eq('mid_order', Number(mid))
    .eq('sub_key', subKey)
    .eq('sub_index', Number(subIndex))
    .maybeSingle();
  if (runError) throw new Error(runError.message);
  documentId = String(data?.pb_document_id ?? '').trim();
} else {
  documentId = String(argv[0] || '').trim();
}
if (!documentId) throw new Error('document_id 를 찾지 못했습니다');

const { data: questions, error } = await supabase
  .from('pb_questions')
  .select('id,question_number,question_type,subjective_answer,source_order')
  .eq('document_id', documentId)
  .order('source_order', { ascending: true });
if (error) throw new Error(error.message);

const { data: links } = await supabase
  .from('textbook_crop_question_links')
  .select('crop_id,pb_question_id')
  .in('pb_question_id', (questions ?? []).map((q) => q.id));
const cropByQuestion = new Map(
  (links ?? []).map((l) => [l.pb_question_id, l.crop_id]),
);
const { data: crops } = await supabase
  .from('textbook_problem_crops')
  .select('id,problem_number,item_name')
  .in('id', [...cropByQuestion.values()]);
const cropById = new Map((crops ?? []).map((c) => [c.id, c]));

for (const q of questions ?? []) {
  const crop = cropById.get(cropByQuestion.get(q.id));
  const answer = String(q.subjective_answer ?? '').replace(/\s+/g, ' ').slice(0, 34);
  console.log(
    `${String(q.question_number).padEnd(10)} ${q.question_type.padEnd(11)} ` +
      `답=${answer.padEnd(34)} crop=${crop ? `${crop.problem_number} (${crop.item_name})` : '연결없음'}`,
  );
}
