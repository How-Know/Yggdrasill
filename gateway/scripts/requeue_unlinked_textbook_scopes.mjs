import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const apply = process.argv.includes('--apply');
const bookArgIndex = process.argv.indexOf('--book-id');
const requestedBookId =
  bookArgIndex >= 0 ? String(process.argv[bookArgIndex + 1] || '').trim() : '';

const url = String(process.env.SUPABASE_URL || '').trim();
const serviceKey = String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim();
if (!url || !serviceKey) {
  throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required');
}

const supabase = createClient(url, serviceKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

function chunks(values, size = 100) {
  const result = [];
  for (let offset = 0; offset < values.length; offset += size) {
    result.push(values.slice(offset, offset + size));
  }
  return result;
}

function scopeKey(row) {
  return [
    row.academy_id,
    row.book_id,
    row.grade_label,
    Number(row.big_order),
    Number(row.mid_order),
    String(row.sub_key || '').toUpperCase(),
    Number(row.sub_index || 0),
  ].join('|');
}

async function selectAll(table, columns, configure) {
  const rows = [];
  for (let from = 0; ; from += 1000) {
    let query = supabase.from(table).select(columns).range(from, from + 999);
    query = configure ? configure(query) : query;
    const { data, error } = await query;
    if (error) throw new Error(`${table}_select_failed:${error.message}`);
    rows.push(...(data || []));
    if (!data || data.length < 1000) return rows;
  }
}

async function updateInChunks(table, ids, patch) {
  for (const idChunk of chunks(ids)) {
    const { error } = await supabase
      .from(table)
      .update(patch)
      .in('id', idChunk);
    if (error) throw new Error(`${table}_update_failed:${error.message}`);
  }
}

let metadataQuery = supabase
  .from('textbook_metadata')
  .select('academy_id,book_id,grade_label,payload')
  .eq('payload->>series', 'wonri');
if (requestedBookId) metadataQuery = metadataQuery.eq('book_id', requestedBookId);
const { data: metadata, error: metadataError } = await metadataQuery;
if (metadataError) {
  throw new Error(`textbook_metadata_select_failed:${metadataError.message}`);
}

const targets = [];
const missingRuns = [];
for (const book of metadata || []) {
  const scope = (query) =>
    query
      .eq('academy_id', book.academy_id)
      .eq('book_id', book.book_id)
      .eq('grade_label', book.grade_label);
  const crops = await selectAll(
    'textbook_problem_crops',
    'id,academy_id,book_id,grade_label,big_order,mid_order,sub_key,sub_index',
    (query) => scope(query).eq('is_set_header', false),
  );
  const linkedCropIds = new Set();
  for (const cropChunk of chunks(crops.map((crop) => crop.id))) {
    const { data, error } = await supabase
      .from('textbook_crop_question_links')
      .select('crop_id')
      .in('crop_id', cropChunk);
    if (error) throw new Error(`canonical_links_select_failed:${error.message}`);
    for (const link of data || []) linkedCropIds.add(link.crop_id);
  }

  const unresolvedKeys = new Set(
    crops
      .filter((crop) => !linkedCropIds.has(crop.id))
      .map(scopeKey),
  );
  if (unresolvedKeys.size === 0) continue;

  const runs = await selectAll(
    'textbook_pb_extract_runs',
    'id,academy_id,book_id,grade_label,big_order,mid_order,sub_key,sub_index,pb_document_id,extract_job_id,status',
    scope,
  );
  const runByScope = new Map(runs.map((run) => [scopeKey(run), run]));
  for (const key of unresolvedKeys) {
    const run = runByScope.get(key);
    if (!run?.pb_document_id || !run?.extract_job_id) {
      missingRuns.push(key);
      continue;
    }
    targets.push(run);
  }
}

const uniqueTargets = [
  ...new Map(targets.map((target) => [target.extract_job_id, target])).values(),
];
const jobIds = uniqueTargets.map((target) => target.extract_job_id);
const jobs = [];
for (const jobChunk of chunks(jobIds)) {
  const { data, error } = await supabase
    .from('pb_extract_jobs')
    .select('id,status')
    .in('id', jobChunk);
  if (error) throw new Error(`extract_jobs_select_failed:${error.message}`);
  jobs.push(...(data || []));
}
const statusByJob = new Map(jobs.map((job) => [job.id, job.status]));
const ready = uniqueTargets.filter(
  (target) => !['queued', 'extracting'].includes(statusByJob.get(target.extract_job_id)),
);
const alreadyActive = uniqueTargets.length - ready.length;

console.log(JSON.stringify({
  mode: apply ? 'apply' : 'dry-run',
  ready_scopes: ready.length,
  already_active_scopes: alreadyActive,
  missing_run_scopes: missingRuns.length,
}, null, 2));

if (!apply || ready.length === 0) process.exit(0);

const now = new Date().toISOString();
await updateInChunks(
  'pb_documents',
  [...new Set(ready.map((target) => target.pb_document_id))],
  { status: 'extract_queued', updated_at: now },
);
await updateInChunks(
  'textbook_pb_extract_runs',
  ready.map((target) => target.id),
  { status: 'queued', error_code: '', error_message: '', updated_at: now },
);
await updateInChunks(
  'pb_extract_jobs',
  ready.map((target) => target.extract_job_id),
  {
    status: 'queued',
    error_code: '',
    error_message: '',
    result_summary: {},
    started_at: null,
    finished_at: null,
    updated_at: now,
  },
);

console.log(JSON.stringify({ queued_scopes: ready.length }, null, 2));
