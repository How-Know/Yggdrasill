// Verifies /textbook/pdf/page resolves by storage_key (the high-school
// courseKey vs courseLabel mismatch case that previously 404'd).
//
// Usage: node gateway/scripts/adhoc_test_page_by_storagekey.mjs <storage_key> <page>

import 'dotenv/config';

const gw = process.env.PB_GATEWAY_URL || 'http://localhost:8787';
const apiKey = process.env.PB_GATEWAY_API_KEY || process.env.PB_API_KEY || '';
const storageKey =
  process.argv[2] ||
  'academies/3ff51b8d-3cfb-4a36-a1a1-b63aebbde677/files/c3ae29ad-4d99-4078-8381-00357074d151/H1-c1/sol.pdf';
const page = Number(process.argv[3] || '1');

const uri = `${gw}/textbook/pdf/page?storage_key=${encodeURIComponent(storageKey)}&page=${page}`;
const started = Date.now();
const res = await fetch(uri, { headers: { 'x-api-key': apiKey } });
const body = await res.json().catch(() => ({}));
const secs = ((Date.now() - started) / 1000).toFixed(2);
console.log(`HTTP ${res.status} in ${secs}s`);
console.log(
  JSON.stringify({
    ok: body.ok,
    error: body.error,
    link_id: body.link_id,
    source_page: body.source_page,
    local_page: body.local_page,
    migration_status: body.migration_status,
    has_url: typeof body.url === 'string' && body.url.length > 0,
  }),
);
process.exit(0);
