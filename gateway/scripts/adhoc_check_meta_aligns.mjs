import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const docId = process.argv[2] || 'c2e37ceb-164f-4d0f-96f6-f63e2112ea74';
const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

const { data } = await supa
  .from('pb_questions')
  .select('question_number, stem, meta')
  .eq('document_id', docId)
  .order('question_number');

const alignCounts = { left: 0, center: 0, right: 0, justify: 0, other: 0 };

for (const q of data) {
  const meta = q.meta || {};
  const aligns = meta.stem_line_aligns || meta.stemLineAligns || [];
  if (!aligns.length) continue;
  let hasNonLeft = false;
  for (const a of aligns) {
    const k = String(a || '').toLowerCase();
    if (k === 'left' || k === '') alignCounts.left += 1;
    else if (k === 'center' || k === 'middle') { alignCounts.center += 1; hasNonLeft = true; }
    else if (k === 'right') { alignCounts.right += 1; hasNonLeft = true; }
    else if (k === 'justify' || k === 'both') { alignCounts.justify += 1; hasNonLeft = true; }
    else { alignCounts.other += 1; hasNonLeft = true; }
  }
  if (hasNonLeft) {
    console.log(`Q${q.question_number}: aligns=[${aligns.join(',')}]`);
    const stemLines = (q.stem || '').split('\n');
    aligns.forEach((a, i) => {
      if (a && a !== 'left') {
        console.log(`  line[${i}] (${a}): ${String(stemLines[i] || '').slice(0, 80)}`);
      }
    });
  }
}

console.log('\nTotal counts:', alignCounts);
