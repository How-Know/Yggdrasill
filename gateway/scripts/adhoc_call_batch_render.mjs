// Actually POST /pb/preview/batch-render against the live pb-api process
// using this document's questions, and dump the response so we can see what
// the manager app sees.
import 'dotenv/config';
import http from 'node:http';
import { createClient } from '@supabase/supabase-js';

const docId = process.argv[2] || 'c2e37ceb-164f-4d0f-96f6-f63e2112ea74';
const port = Number.parseInt(process.env.PB_API_PORT || '8787', 10);
const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

const { data: doc } = await supa
  .from('pb_documents')
  .select('id, academy_id')
  .eq('id', docId)
  .maybeSingle();
if (!doc) { console.log('no doc'); process.exit(1); }

const { data: rows } = await supa
  .from('pb_questions')
  .select('id, question_uid, question_number')
  .eq('document_id', docId);
rows.sort((a, b) => Number(a.question_number || 0) - Number(b.question_number || 0));
const questionIds = rows.map((r) => r.question_uid || r.id);
console.log(`doc=${doc.id} academy=${doc.academy_id} questions=${questionIds.length}`);

const body = JSON.stringify({
  academyId: doc.academy_id,
  questionIds,
  documentId: doc.id,
  templateProfile: 'naesin',
  paperSize: 'A4',
  mathEngine: 'xelatex',
});

const payload = await new Promise((resolve, reject) => {
  const req = http.request(
    {
      host: '127.0.0.1',
      port,
      path: '/pb/preview/batch-render',
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    },
    (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
    },
  );
  req.on('error', reject);
  req.write(body);
  req.end();
});

console.log(`status=${payload.status}`);
let json;
try { json = JSON.parse(payload.body); } catch { json = null; }
if (!json) { console.log(payload.body.slice(0, 2000)); process.exit(0); }

if (json.thumbnails) {
  const thumbs = json.thumbnails;
  const ids = Object.keys(thumbs);
  let withUrl = 0, withError = 0;
  for (const k of ids) {
    const v = thumbs[k] || {};
    if (v.url) withUrl++;
    if (v.error) withError++;
  }
  console.log(`thumbnails keys=${ids.length} withUrl=${withUrl} withError=${withError}`);
  const missing = questionIds.filter((qid) => !thumbs[qid] || !thumbs[qid].url);
  console.log(`missing count=${missing.length}`);
  for (const qid of missing.slice(0, 5)) {
    const row = rows.find((r) => (r.question_uid || r.id) === qid);
    console.log(`  Q${row?.question_number} id=${qid} -> ${JSON.stringify(thumbs[qid] || null)}`);
  }
  if (json.warning || json.error) {
    console.log('top-level warning/error:', json.warning, json.error);
  }
} else {
  console.log(JSON.stringify(json, null, 2).slice(0, 2000));
}
