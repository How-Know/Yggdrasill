import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const WINDOW_DAYS = Math.max(
  1,
  Number.parseInt(process.env.PB_METRIC_WINDOW_DAYS || '7', 10),
);
const MIN_EXTRACT_SUCCESS = Number.parseFloat(
  process.env.PB_METRIC_MIN_EXTRACT_SUCCESS || '0.9',
);
const MIN_EXPORT_SUCCESS = Number.parseFloat(
  process.env.PB_METRIC_MIN_EXPORT_SUCCESS || '0.9',
);
const MAX_REVIEW_REQUIRED = Number.parseFloat(
  process.env.PB_METRIC_MAX_REVIEW_REQUIRED || '0.6',
);

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  console.error(
    '[pb-quality-metrics] Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY',
  );
  process.exit(1);
}

const supa = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

function avg(values) {
  if (!values.length) return 0;
  return values.reduce((a, b) => a + b, 0) / values.length;
}

function safeNum(v, fallback = 0) {
  const n = Number(v);
  if (Number.isFinite(n)) return n;
  return fallback;
}

function pct(v) {
  return `${(v * 100).toFixed(2)}%`;
}

async function fetchExtractJobs(sinceIso) {
  const rows = await supa
    .from('pb_extract_jobs')
    .select('status,result_summary,created_at')
    .gte('created_at', sinceIso)
    .order('created_at', { ascending: false })
    .limit(5000);
  return Array.isArray(rows) ? rows : [];
}

async function fetchExportJobs(sinceIso) {
  const rows = await supa
    .from('pb_exports')
    .select('status,created_at,page_count')
    .gte('created_at', sinceIso)
    .order('created_at', { ascending: false })
    .limit(5000);
  return Array.isArray(rows) ? rows : [];
}

async function main() {
  const since = new Date(Date.now() - WINDOW_DAYS * 24 * 60 * 60 * 1000);
  const sinceIso = since.toISOString();

  const extractRows = await fetchExtractJobs(sinceIso);
  const exportRows = await fetchExportJobs(sinceIso);

  const extractTotal = extractRows.length;
  const extractSuccessRows = extractRows.filter(
    (r) => r.status === 'completed' || r.status === 'review_required',
  );
  const extractReviewRows = extractRows.filter(
    (r) => r.status === 'review_required',
  );
  const extractFailedRows = extractRows.filter((r) => r.status === 'failed');

  const lowConfidenceRates = [];
  for (const row of extractRows) {
    const summary =
      row.result_summary && typeof row.result_summary === 'object'
        ? row.result_summary
        : {};
    const totalQuestions = safeNum(summary.totalQuestions, 0);
    const lowConfidenceCount = safeNum(summary.lowConfidenceCount, 0);
    if (totalQuestions > 0) {
      lowConfidenceRates.push(lowConfidenceCount / totalQuestions);
    }
  }

  const exportTotal = exportRows.length;
  const exportSuccessRows = exportRows.filter((r) => r.status === 'completed');
  const exportFailedRows = exportRows.filter((r) => r.status === 'failed');
  const exportPageCountAvg = avg(
    exportSuccessRows.map((r) => safeNum(r.page_count, 0)),
  );

  const extractSuccessRate =
    extractTotal > 0 ? extractSuccessRows.length / extractTotal : 1;
  const reviewRequiredRate =
    extractTotal > 0 ? extractReviewRows.length / extractTotal : 0;
  const exportSuccessRate =
    exportTotal > 0 ? exportSuccessRows.length / exportTotal : 1;
  const lowConfidenceRateAvg = avg(lowConfidenceRates);

  const report = {
    windowDays: WINDOW_DAYS,
    sinceIso,
    extract: {
      total: extractTotal,
      success: extractSuccessRows.length,
      failed: extractFailedRows.length,
      reviewRequired: extractReviewRows.length,
      successRate: extractSuccessRate,
      reviewRequiredRate,
      lowConfidenceRateAvg,
    },
    export: {
      total: exportTotal,
      success: exportSuccessRows.length,
      failed: exportFailedRows.length,
      successRate: exportSuccessRate,
      avgPageCount: exportPageCountAvg,
    },
    thresholds: {
      minExtractSuccess: MIN_EXTRACT_SUCCESS,
      minExportSuccess: MIN_EXPORT_SUCCESS,
      maxReviewRequired: MAX_REVIEW_REQUIRED,
    },
  };

  console.log('[pb-quality-metrics] report');
  console.log(JSON.stringify(report, null, 2));

  const failures = [];
  if (extractSuccessRate < MIN_EXTRACT_SUCCESS) {
    failures.push(
      `extractSuccessRate ${pct(extractSuccessRate)} < ${pct(MIN_EXTRACT_SUCCESS)}`,
    );
  }
  if (exportSuccessRate < MIN_EXPORT_SUCCESS) {
    failures.push(
      `exportSuccessRate ${pct(exportSuccessRate)} < ${pct(MIN_EXPORT_SUCCESS)}`,
    );
  }
  if (reviewRequiredRate > MAX_REVIEW_REQUIRED) {
    failures.push(
      `reviewRequiredRate ${pct(reviewRequiredRate)} > ${pct(MAX_REVIEW_REQUIRED)}`,
    );
  }

  if (failures.length) {
    console.error(`[pb-quality-metrics] FAILED: ${failures.join(', ')}`);
    process.exit(1);
  }
  console.log('[pb-quality-metrics] PASSED');
}

main().catch((err) => {
  console.error('[pb-quality-metrics] error', String(err?.message || err));
  process.exit(1);
});
