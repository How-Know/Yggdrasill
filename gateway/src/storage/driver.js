// gateway/src/storage/driver.js
//
// Thin storage adapter so that callers (HTTP endpoints, workers, batch scripts)
// can request signed upload / download URLs without knowing which provider is
// behind the bucket. Current implementation supports Supabase Storage and
// leaves a stub for Cloudflare R2 that can be filled in once we adopt the
// `@aws-sdk/client-s3` presigner.
//
// Every function is async and returns `{ ok, ... }` (never throws) so that
// the HTTP layer can translate adapter failures into clean JSON errors.
//
// SECURITY TODO (pre-release):
// - Add caller identity binding (user_id / device_id) before issuing URLs.
// - Shorten expiresIn defaults once the client-side refresh flow is in place.

import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

let _supa = null;
function getSupabase() {
  if (_supa) return _supa;
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    throw new Error(
      'storage/driver: Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY in env',
    );
  }
  _supa = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return _supa;
}

function sanitizeString(v) {
  return typeof v === 'string' ? v.trim() : '';
}

function isSupportedDriver(driver) {
  return driver === 'supabase' || driver === 'r2';
}

// ---------- Supabase implementation ----------------------------------------

async function supabaseCreateUploadUrl({ bucket, key, upsert = false }) {
  const supa = getSupabase();
  const { data, error } = await supa.storage
    .from(bucket)
    .createSignedUploadUrl(key, { upsert });
  if (error) {
    return { ok: false, error: `supabase_upload_url_failed: ${error.message || error}` };
  }
  // createSignedUploadUrl returns { path, token, signedUrl }.
  // The client can PUT directly to signedUrl (for small files) or POST the
  // token to the Supabase endpoint. We expose both so the caller can choose.
  return {
    ok: true,
    url: String(data?.signedUrl || ''),
    token: String(data?.token || ''),
    method: 'PUT',
    headers: { 'Content-Type': 'application/pdf' },
  };
}

async function supabaseCreateDownloadUrl({ bucket, key, expiresIn }) {
  const supa = getSupabase();
  const ttl = Number.isFinite(expiresIn) && expiresIn > 0 ? Math.floor(expiresIn) : 60 * 30;
  const { data, error } = await supa.storage
    .from(bucket)
    .createSignedUrl(key, ttl);
  if (error) {
    return { ok: false, error: `supabase_download_url_failed: ${error.message || error}` };
  }
  return { ok: true, url: String(data?.signedUrl || ''), expires_in: ttl };
}

async function supabaseHead({ bucket, key }) {
  const supa = getSupabase();
  // Supabase JS SDK does not expose HEAD directly, but `list` of the parent
  // folder with a search on the basename returns size / updated_at metadata.
  try {
    const segments = String(key).split('/');
    const base = segments.pop() || '';
    const prefix = segments.join('/');
    const { data, error } = await supa.storage
      .from(bucket)
      .list(prefix, { limit: 100, search: base });
    if (error) {
      return { ok: false, error: `supabase_head_failed: ${error.message || error}` };
    }
    const entry = Array.isArray(data) ? data.find((e) => e?.name === base) : null;
    if (!entry) return { ok: false, error: 'not_found' };
    return {
      ok: true,
      size: Number(entry?.metadata?.size || 0),
      updated_at: entry?.updated_at || null,
    };
  } catch (e) {
    return { ok: false, error: `supabase_head_exception: ${e?.message || e}` };
  }
}

async function supabaseRemove({ bucket, key }) {
  const supa = getSupabase();
  const { error } = await supa.storage.from(bucket).remove([key]);
  if (error) {
    return { ok: false, error: `supabase_remove_failed: ${error.message || error}` };
  }
  return { ok: true };
}

async function supabaseListDeep({ bucket, prefix, limit = 500 }) {
  // Supabase Storage `list()` is not recursive, so we walk the tree
  // depth-first. Returns full object keys (relative to the bucket root).
  const supa = getSupabase();
  const root = sanitizeString(prefix).replace(/\/+$/, '');
  const keys = [];
  const stack = [root];
  let visited = 0;
  const maxVisits = 200;
  while (stack.length > 0 && visited < maxVisits) {
    const cur = stack.shift();
    visited += 1;
    // eslint-disable-next-line no-await-in-loop
    const { data, error } = await supa.storage
      .from(bucket)
      .list(cur, { limit, offset: 0, sortBy: { column: 'name', order: 'asc' } });
    if (error) {
      return {
        ok: false,
        error: `supabase_list_failed: ${error.message || error}`,
      };
    }
    if (!Array.isArray(data)) continue;
    for (const entry of data) {
      if (!entry || !entry.name) continue;
      const full = cur ? `${cur}/${entry.name}` : entry.name;
      // A Supabase "folder" has id === null (there is no `isDirectory`).
      if (entry.id == null) {
        stack.push(full);
      } else {
        keys.push(full);
      }
    }
  }
  return { ok: true, keys };
}

async function supabaseRemoveByPrefix({ bucket, prefix }) {
  const listed = await supabaseListDeep({ bucket, prefix });
  if (!listed.ok) return listed;
  const keys = listed.keys;
  if (keys.length === 0) return { ok: true, removed: 0 };
  const supa = getSupabase();
  // Supabase remove accepts batches; chunk to avoid gigantic payloads.
  const chunkSize = 200;
  let removed = 0;
  for (let i = 0; i < keys.length; i += chunkSize) {
    const chunk = keys.slice(i, i + chunkSize);
    // eslint-disable-next-line no-await-in-loop
    const { error } = await supa.storage.from(bucket).remove(chunk);
    if (error) {
      return {
        ok: false,
        error: `supabase_remove_failed: ${error.message || error}`,
        removed,
      };
    }
    removed += chunk.length;
  }
  return { ok: true, removed };
}

async function supabaseRemoveByMatchingPrefix({ bucket, folder, nameStartsWith }) {
  // For buckets that store book artifacts at the top level (e.g. the
  // `resource-covers` bucket keeps `<academy>/resource-covers/<bookId>_*.png`).
  const supa = getSupabase();
  const { data, error } = await supa.storage
    .from(bucket)
    .list(folder, { limit: 1000 });
  if (error) {
    return { ok: false, error: `supabase_list_failed: ${error.message || error}` };
  }
  if (!Array.isArray(data) || data.length === 0) {
    return { ok: true, removed: 0 };
  }
  const keys = data
    .filter((e) => e && e.id != null && typeof e.name === 'string')
    .filter((e) => e.name.startsWith(nameStartsWith))
    .map((e) => (folder ? `${folder}/${e.name}` : e.name));
  if (keys.length === 0) return { ok: true, removed: 0 };
  const { error: removeErr } = await supa.storage.from(bucket).remove(keys);
  if (removeErr) {
    return {
      ok: false,
      error: `supabase_remove_failed: ${removeErr.message || removeErr}`,
    };
  }
  return { ok: true, removed: keys.length };
}

// ---------- Cloudflare R2 stubs --------------------------------------------
// These are left intentionally unimplemented. When we switch to R2:
//   1. `npm i @aws-sdk/client-s3 @aws-sdk/s3-request-presigner`.
//   2. Read R2_ACCOUNT_ID / R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY from env.
//   3. Build an S3Client with endpoint `https://<account>.r2.cloudflarestorage.com`.
//   4. Use getSignedUrl(new PutObjectCommand(...)) / GetObjectCommand.
// Until then any call returns a clear "not implemented" error so callers can
// fall back to the Supabase driver.

async function r2NotImplemented(op) {
  return { ok: false, error: `r2_${op}_not_implemented` };
}

// ---------- Public API ------------------------------------------------------

/**
 * Get a signed upload URL for a given object.
 * @param {{driver: 'supabase'|'r2', bucket: string, key: string, contentType?: string, expiresIn?: number, upsert?: boolean}} opts
 */
export async function createUploadUrl(opts) {
  const driver = sanitizeString(opts?.driver);
  const bucket = sanitizeString(opts?.bucket);
  const key = sanitizeString(opts?.key);
  const upsert = opts?.upsert === true;
  if (!isSupportedDriver(driver)) {
    return { ok: false, error: `unsupported_driver: ${driver}` };
  }
  if (!bucket || !key) {
    return { ok: false, error: 'missing_bucket_or_key' };
  }
  if (driver === 'supabase') {
    return supabaseCreateUploadUrl({ bucket, key, upsert });
  }
  return r2NotImplemented('upload_url');
}

/**
 * Get a signed download URL for a given object.
 * @param {{driver: 'supabase'|'r2', bucket: string, key: string, expiresIn?: number}} opts
 */
export async function createDownloadUrl(opts) {
  const driver = sanitizeString(opts?.driver);
  const bucket = sanitizeString(opts?.bucket);
  const key = sanitizeString(opts?.key);
  const expiresIn = Number(opts?.expiresIn);
  if (!isSupportedDriver(driver)) {
    return { ok: false, error: `unsupported_driver: ${driver}` };
  }
  if (!bucket || !key) {
    return { ok: false, error: 'missing_bucket_or_key' };
  }
  if (driver === 'supabase') {
    return supabaseCreateDownloadUrl({ bucket, key, expiresIn });
  }
  return r2NotImplemented('download_url');
}

/**
 * Cheap existence + size check. Useful for finalize() to verify the client
 * actually finished the upload before we flip migration_status to 'dual'.
 * @param {{driver: 'supabase'|'r2', bucket: string, key: string}} opts
 */
export async function statObject(opts) {
  const driver = sanitizeString(opts?.driver);
  const bucket = sanitizeString(opts?.bucket);
  const key = sanitizeString(opts?.key);
  if (!isSupportedDriver(driver)) {
    return { ok: false, error: `unsupported_driver: ${driver}` };
  }
  if (!bucket || !key) {
    return { ok: false, error: 'missing_bucket_or_key' };
  }
  if (driver === 'supabase') {
    return supabaseHead({ bucket, key });
  }
  return r2NotImplemented('stat');
}

/**
 * Delete an object. Used when we want to discard a half-finished upload or
 * wipe a key before overwriting.
 * @param {{driver: 'supabase'|'r2', bucket: string, key: string}} opts
 */
export async function removeObject(opts) {
  const driver = sanitizeString(opts?.driver);
  const bucket = sanitizeString(opts?.bucket);
  const key = sanitizeString(opts?.key);
  if (!isSupportedDriver(driver)) {
    return { ok: false, error: `unsupported_driver: ${driver}` };
  }
  if (!bucket || !key) {
    return { ok: false, error: 'missing_bucket_or_key' };
  }
  if (driver === 'supabase') {
    return supabaseRemove({ bucket, key });
  }
  return r2NotImplemented('remove');
}

/**
 * Recursively remove every object under a prefix (folder-style). Used by
 * book deletion to sweep PDFs and crops in one call.
 * @param {{driver: 'supabase'|'r2', bucket: string, prefix: string}} opts
 */
export async function removeObjectsByPrefix(opts) {
  const driver = sanitizeString(opts?.driver);
  const bucket = sanitizeString(opts?.bucket);
  const prefix = sanitizeString(opts?.prefix);
  if (!isSupportedDriver(driver)) {
    return { ok: false, error: `unsupported_driver: ${driver}` };
  }
  if (!bucket) {
    return { ok: false, error: 'missing_bucket' };
  }
  if (driver === 'supabase') {
    return supabaseRemoveByPrefix({ bucket, prefix });
  }
  return r2NotImplemented('remove_prefix');
}

/**
 * Remove every object in a folder whose basename starts with `nameStartsWith`.
 * Handy for the `resource-covers` bucket where covers live at the folder
 * top level (e.g. `<academy>/resource-covers/<book_id>_<ts>.png`).
 * @param {{driver: 'supabase'|'r2', bucket: string, folder: string, nameStartsWith: string}} opts
 */
export async function removeObjectsByPrefixInFolder(opts) {
  const driver = sanitizeString(opts?.driver);
  const bucket = sanitizeString(opts?.bucket);
  const folder = sanitizeString(opts?.folder);
  const nameStartsWith = sanitizeString(opts?.nameStartsWith);
  if (!isSupportedDriver(driver)) {
    return { ok: false, error: `unsupported_driver: ${driver}` };
  }
  if (!bucket || !nameStartsWith) {
    return { ok: false, error: 'missing_bucket_or_name_prefix' };
  }
  if (driver === 'supabase') {
    return supabaseRemoveByMatchingPrefix({ bucket, folder, nameStartsWith });
  }
  return r2NotImplemented('remove_name_prefix');
}

/**
 * Convenience helper used by `/textbook/pdf/*` endpoints to derive the
 * canonical storage_key from the logical identifiers. Keeping this in one
 * place makes it trivial to change the path scheme later.
 */
export function buildTextbookStorageKey({ academyId, fileId, gradeLabel, kind }) {
  const a = sanitizeString(academyId);
  const f = sanitizeString(fileId);
  const g = sanitizeString(gradeLabel).replace(/[\\/]/g, '_');
  const k = sanitizeString(kind);
  if (!a || !f || !g || !k) {
    throw new Error('buildTextbookStorageKey: missing required fields');
  }
  return `academies/${a}/files/${f}/${g}/${k}.pdf`;
}

function slugForFileName(input) {
  const s = sanitizeString(input);
  // Keep word chars, dash, tilde (~ appears in 48~52 set-header numbers),
  // fold the rest to '_' so that Storage accepts the path segment.
  return s.replace(/[^A-Za-z0-9_\-~]/g, '_');
}

/**
 * Canonical crop storage key.
 * Path: academies/<academy_id>/books/<book_id>/<grade_label>/
 *   <big_order>_<mid_order>_<sub_key>/<problem_number>.png
 */
export function buildTextbookCropStorageKey({
  academyId,
  bookId,
  gradeLabel,
  bigOrder,
  midOrder,
  subKey,
  problemNumber,
  ext = 'png',
}) {
  const a = sanitizeString(academyId);
  const b = sanitizeString(bookId);
  const g = slugForFileName(gradeLabel);
  const s = sanitizeString(subKey).toUpperCase();
  const num = slugForFileName(problemNumber);
  if (!a || !b || !g || !s || !num) {
    throw new Error('buildTextbookCropStorageKey: missing required fields');
  }
  const bigI = Number.isFinite(Number(bigOrder)) ? Number(bigOrder) : 0;
  const midI = Number.isFinite(Number(midOrder)) ? Number(midOrder) : 0;
  return (
    `academies/${a}/books/${b}/${g}/` +
    `${bigI}_${midI}_${s}/${num}.${ext}`
  );
}

/**
 * Server-side direct upload. Primarily used by endpoints that receive
 * base64-encoded bytes and need to push them straight into Storage without
 * round-tripping through a signed URL.
 */
export async function uploadBytes(opts) {
  const driver = sanitizeString(opts?.driver);
  const bucket = sanitizeString(opts?.bucket);
  const key = sanitizeString(opts?.key);
  const contentType = sanitizeString(opts?.contentType) || 'application/octet-stream';
  const bytes = opts?.bytes;
  if (!isSupportedDriver(driver)) {
    return { ok: false, error: `unsupported_driver: ${driver}` };
  }
  if (!bucket || !key) {
    return { ok: false, error: 'missing_bucket_or_key' };
  }
  if (!(bytes instanceof Uint8Array) && !Buffer.isBuffer(bytes)) {
    return { ok: false, error: 'missing_bytes' };
  }
  if (driver !== 'supabase') {
    return r2NotImplemented('upload_bytes');
  }
  const supa = getSupabase();
  const { error } = await supa.storage.from(bucket).upload(key, bytes, {
    contentType,
    upsert: true,
  });
  if (error) {
    return {
      ok: false,
      error: `supabase_upload_bytes_failed: ${error.message || error}`,
    };
  }
  return { ok: true };
}

export const SUPPORTED_DRIVERS = Object.freeze(['supabase', 'r2']);
export const DEFAULT_TEXTBOOK_BUCKET = 'textbooks';
export const DEFAULT_TEXTBOOK_CROPS_BUCKET = 'textbook-crops';
export const DEFAULT_TEXTBOOK_DRIVER = 'supabase';
