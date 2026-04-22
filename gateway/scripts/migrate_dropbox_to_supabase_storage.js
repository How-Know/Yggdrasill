// Bulk migration helper: Dropbox URLs -> Supabase Storage ('textbooks' bucket).
//
// Goal:
//   For every `public.resource_file_links` row whose `migration_status='legacy'`
//   (or explicitly re-run on a subset), download the Dropbox PDF, upload it
//   to Supabase Storage under the canonical key derived from
//   `buildTextbookStorageKey`, and flip the row to `migration_status='dual'`
//   while keeping the original Dropbox URL intact. The existing runtime
//   endpoints (`/textbook/pdf/finalize`) already implement the same semantics
//   for a single row; this script is a batch wrapper around them.
//
// Usage:
//   node scripts/migrate_dropbox_to_supabase_storage.js \
//     [--limit 20]                 # hard cap on rows processed per run (default 10)
//     [--academy-id <uuid>]        # restrict to one academy
//     [--file-id <uuid>]           # restrict to one book (most common for cautious rollout)
//     [--link-id <int>]            # restrict to a single link row
//     [--status legacy|dual]       # source status to migrate from (default 'legacy')
//     [--target dual|migrated]     # status to flip to after successful upload (default 'dual')
//     [--dry-run]                  # log plan, skip downloads and writes
//     [--skip-existing]            # skip rows that already have a storage_key
//     [--min-size-mb <number>]     # skip PDFs smaller than this (default 0)
//
// Environment:
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY    (required for DB + storage)
//   TEXTBOOK_BUCKET                            (default 'textbooks')
//
// SAFETY:
//   - Never touches the `url` column (Dropbox link is preserved as-is).
//   - Per-row failures are logged and the row is left at `legacy` so it can
//     be retried on a later run.
//   - To roll a row back, run:
//       UPDATE public.resource_file_links
//          SET migration_status='legacy' WHERE id = <link_id>;

import 'dotenv/config';
import crypto from 'node:crypto';
import { Buffer } from 'node:buffer';
import { createClient } from '@supabase/supabase-js';
import {
  buildTextbookStorageKey,
  DEFAULT_TEXTBOOK_BUCKET,
  DEFAULT_TEXTBOOK_DRIVER,
} from '../src/storage/driver.js';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const TEXTBOOK_BUCKET = (process.env.TEXTBOOK_BUCKET || DEFAULT_TEXTBOOK_BUCKET).trim();

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  console.error('[migrate] SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY is missing');
  process.exit(1);
}

const supa = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

function parseArgs(argv) {
  const out = {
    limit: 10,
    academyId: '',
    fileId: '',
    linkId: '',
    status: 'legacy',
    target: 'dual',
    dryRun: false,
    skipExisting: false,
    minSizeMb: 0,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    const next = () => argv[++i] || '';
    if (a === '--limit') out.limit = Math.max(1, Number(next()) || 10);
    else if (a === '--academy-id') out.academyId = String(next()).trim();
    else if (a === '--file-id') out.fileId = String(next()).trim();
    else if (a === '--link-id') out.linkId = String(next()).trim();
    else if (a === '--status') out.status = String(next()).trim() || 'legacy';
    else if (a === '--target') out.target = String(next()).trim() || 'dual';
    else if (a === '--dry-run') out.dryRun = true;
    else if (a === '--skip-existing') out.skipExisting = true;
    else if (a === '--min-size-mb') out.minSizeMb = Number(next()) || 0;
  }
  if (!['legacy', 'dual'].includes(out.status)) {
    throw new Error(`Invalid --status ${out.status}; expected 'legacy' or 'dual'`);
  }
  if (!['dual', 'migrated'].includes(out.target)) {
    throw new Error(`Invalid --target ${out.target}; expected 'dual' or 'migrated'`);
  }
  return out;
}

function parseGradeComposite(raw) {
  const s = String(raw || '').trim();
  const idx = s.indexOf('#');
  if (idx < 0) return { gradeLabel: s, kind: '' };
  return {
    gradeLabel: s.slice(0, idx).trim(),
    kind: s.slice(idx + 1).trim().toLowerCase(),
  };
}

// Dropbox share links serve a preview page unless `dl=1` is present.
function toDropboxDirectDownload(url) {
  if (!url) return '';
  try {
    const u = new URL(url);
    if (u.hostname.includes('dropbox.com')) {
      u.searchParams.set('dl', '1');
      return u.toString();
    }
    return url;
  } catch {
    return url;
  }
}

async function fetchPdfBytes(url) {
  const direct = toDropboxDirectDownload(url);
  const res = await fetch(direct, { redirect: 'follow' });
  if (!res.ok) {
    throw new Error(`download_failed_${res.status}`);
  }
  const buf = Buffer.from(await res.arrayBuffer());
  if (buf.length === 0) throw new Error('empty_download');
  return buf;
}

async function uploadToStorage({ key, bytes }) {
  const { error } = await supa.storage
    .from(TEXTBOOK_BUCKET)
    .upload(key, bytes, {
      contentType: 'application/pdf',
      upsert: true,
    });
  if (error) {
    throw new Error(`upload_failed: ${error.message || error}`);
  }
}

async function fetchTargetRows(args) {
  let query = supa
    .from('resource_file_links')
    .select(
      'id, academy_id, file_id, grade, url, storage_driver, storage_bucket, storage_key, migration_status, file_size_bytes, content_hash, uploaded_at',
    )
    .eq('migration_status', args.status)
    .order('id', { ascending: true })
    .limit(args.limit);
  if (args.academyId) query = query.eq('academy_id', args.academyId);
  if (args.fileId) query = query.eq('file_id', args.fileId);
  if (args.linkId) query = query.eq('id', Number(args.linkId));
  const { data, error } = await query;
  if (error) throw new Error(`select_failed: ${error.message}`);
  return Array.isArray(data) ? data : [];
}

async function migrateRow(row, args) {
  const { gradeLabel, kind } = parseGradeComposite(row.grade);
  if (!gradeLabel || !kind) {
    return { ok: false, error: `bad_grade_composite: ${row.grade}` };
  }
  if (!['body', 'ans', 'sol'].includes(kind)) {
    return { ok: false, error: `unknown_kind: ${kind}` };
  }
  if (!row.url || typeof row.url !== 'string' || row.url.trim() === '') {
    return { ok: false, error: 'empty_url' };
  }
  if (args.skipExisting && row.storage_key) {
    return { ok: true, skipped: true, reason: 'already_has_storage_key' };
  }

  let storageKey;
  try {
    storageKey = buildTextbookStorageKey({
      academyId: row.academy_id,
      fileId: row.file_id,
      gradeLabel,
      kind,
    });
  } catch (e) {
    return { ok: false, error: `key_build_failed: ${e?.message || e}` };
  }

  if (args.dryRun) {
    return {
      ok: true,
      dryRun: true,
      plan: {
        linkId: row.id,
        from: row.url,
        to: `${TEXTBOOK_BUCKET}/${storageKey}`,
        target_status: args.target,
      },
    };
  }

  let bytes;
  try {
    bytes = await fetchPdfBytes(row.url);
  } catch (e) {
    return { ok: false, error: `dropbox_fetch: ${e?.message || e}` };
  }
  const sizeMb = bytes.length / (1024 * 1024);
  if (args.minSizeMb > 0 && sizeMb < args.minSizeMb) {
    return { ok: true, skipped: true, reason: `below_min_size_${sizeMb.toFixed(2)}mb` };
  }

  try {
    await uploadToStorage({ key: storageKey, bytes });
  } catch (e) {
    return { ok: false, error: e?.message || String(e) };
  }

  const contentHash = crypto.createHash('sha256').update(bytes).digest('hex');
  const payload = {
    storage_driver: DEFAULT_TEXTBOOK_DRIVER,
    storage_bucket: TEXTBOOK_BUCKET,
    storage_key: storageKey,
    migration_status: args.target,
    file_size_bytes: bytes.length,
    content_hash: contentHash,
    uploaded_at: new Date().toISOString(),
  };
  const { data: updated, error } = await supa
    .from('resource_file_links')
    .update(payload)
    .eq('id', row.id)
    .select()
    .maybeSingle();
  if (error) {
    return { ok: false, error: `db_update_failed: ${error.message}` };
  }
  return {
    ok: true,
    linkId: row.id,
    storageKey,
    sizeMb: Number(sizeMb.toFixed(2)),
    contentHash,
    row: updated,
  };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  console.log('[migrate] args', args);
  const rows = await fetchTargetRows(args);
  console.log(`[migrate] fetched ${rows.length} candidate rows (status=${args.status})`);
  if (rows.length === 0) return;

  const summary = { ok: 0, skipped: 0, failed: 0 };
  for (const row of rows) {
    const started = Date.now();
    const result = await migrateRow(row, args);
    const ms = Date.now() - started;
    const tag = result.ok ? (result.skipped ? 'SKIP' : result.dryRun ? 'PLAN' : 'DONE') : 'FAIL';
    console.log(`[migrate] ${tag} id=${row.id} grade=${row.grade} academy=${row.academy_id} file=${row.file_id} t=${ms}ms`, {
      size: result.sizeMb,
      reason: result.reason,
      error: result.error,
      plan: result.plan,
    });
    if (!result.ok) summary.failed += 1;
    else if (result.skipped) summary.skipped += 1;
    else summary.ok += 1;
  }
  console.log('[migrate] summary', summary);
  if (summary.failed > 0) process.exitCode = 2;
}

main().catch((e) => {
  console.error('[migrate] fatal', e);
  process.exit(1);
});
