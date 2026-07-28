// ?�정 ?�코?�로 만들?�진 문제?�??문서?� 문항 ?��? 본다 (?�기 ?�용).
//
// ?�용: node scripts/diag_scope_documents.mjs <book_id> <grade> <big> <mid> <sub_key> [sub_index]
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const [bookId, gradeLabel, big, mid, subKey, subIndex = '0'] =
  process.argv.slice(2);

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const contains = {
  textbook_scope: {
    book_id: bookId,
    grade_label: gradeLabel,
    big_order: Number(big),
    mid_order: Number(mid),
    sub_key: subKey,
    sub_index: Number(subIndex),
  },
};

const { data: docs, error } = await supabase
  .from('pb_documents')
  .select('id,material_name,source_filename,status,created_at')
  .contains('meta', contains);
if (error) throw new Error(error.message);

if (!docs?.length) {
  console.log('?�당 ?�코?�로 만들?�진 문서 ?�음');
} else {
  for (const doc of docs) {
    const { count } = await supabase
      .from('pb_questions')
      .select('id', { count: 'exact', head: true })
      .eq('document_id', doc.id);
    console.log(
      `${doc.id} · ${doc.material_name} / ${doc.source_filename} · ${doc.status} · ` +
        `문항 ${count ?? 0}�?· ${doc.created_at.slice(0, 19)}`,
    );
  }
}

const { data: runs } = await supabase
  .from('textbook_pb_extract_runs')
  .select('id,status,error_message,updated_at')
  .eq('book_id', bookId)
  .eq('grade_label', gradeLabel)
  .eq('big_order', Number(big))
  .eq('mid_order', Number(mid))
  .eq('sub_key', subKey)
  .eq('sub_index', Number(subIndex));
for (const run of runs ?? []) {
  console.log(
    `run ${run.id} · ${run.status} · ${run.error_message || ''} · ${run.updated_at.slice(0, 19)}`,
  );
}
