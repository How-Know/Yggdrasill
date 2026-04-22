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

async function supabaseCreateUploadUrl({ bucket, key }) {
  const supa = getSupabase();
  const { data, error } = await supa.storage
    .from(bucket)
    .createSignedUploadUrl(key);
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
 * @param {{driver: 'supabase'|'r2', bucket: string, key: string, contentType?: string, expiresIn?: number}} opts
 */
export async function createUploadUrl(opts) {
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
    return supabaseCreateUploadUrl({ bucket, key });
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

export const SUPPORTED_DRIVERS = Object.freeze(['supabase', 'r2']);
export const DEFAULT_TEXTBOOK_BUCKET = 'textbooks';
export const DEFAULT_TEXTBOOK_DRIVER = 'supabase';
