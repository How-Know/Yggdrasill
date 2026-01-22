import { corsHeaders } from '../_shared/cors.ts';
import { createAdminClient, createUserClient } from '../_shared/supabase.ts';
import { sha256Hex, stableStringify } from '../_shared/hash.ts';

type FiltersJson = {
  slug?: string;
  is_active_only?: boolean;
  traits?: string[];
  area_ids?: string[];
  group_ids?: string[];
  round_labels?: string[];
  part_indexes?: number[];
  version_min?: number;
  version_max?: number;
  include_images_only?: boolean;
};

function normalizeFilters(raw: FiltersJson): Required<Pick<FiltersJson, 'slug' | 'is_active_only'>> &
  Omit<FiltersJson, 'slug' | 'is_active_only'> {
  const slug = (raw.slug ?? 'trait_v1').trim() || 'trait_v1';
  const is_active_only = raw.is_active_only ?? true;
  const traits = [...new Set((raw.traits ?? []).map((s) => String(s).trim()).filter(Boolean))].sort();
  const area_ids = [...new Set((raw.area_ids ?? []).map((s) => String(s).trim()).filter(Boolean))].sort();
  const group_ids = [...new Set((raw.group_ids ?? []).map((s) => String(s).trim()).filter(Boolean))].sort();
  const round_labels = [...new Set((raw.round_labels ?? []).map((s) => String(s).trim()).filter(Boolean))].sort();
  const part_indexes = [...new Set((raw.part_indexes ?? []).map((n) => Number(n)).filter((n) => Number.isFinite(n)) as number[])].sort((a, b) => a - b);
  const version_min = typeof raw.version_min === 'number' ? raw.version_min : undefined;
  const version_max = typeof raw.version_max === 'number' ? raw.version_max : undefined;
  const include_images_only = raw.include_images_only ?? false;
  return { slug, is_active_only, traits, area_ids, group_ids, round_labels, part_indexes, version_min, version_max, include_images_only };
}

function toQuestionPayload(row: any) {
  return {
    id: row.id,
    area_id: row.area_id ?? null,
    group_id: row.group_id ?? null,
    trait: row.trait,
    text: row.text,
    type: row.type,
    min_score: row.min_score ?? null,
    max_score: row.max_score ?? null,
    weight: row.weight ?? null,
    reverse: row.reverse ?? null,
    tags: row.tags ?? null,
    memo: row.memo ?? null,
    image_url: row.image_url ?? null,
    pair_id: row.pair_id ?? null,
    round_label: row.round_label ?? null,
    part_index: row.part_index ?? null,
    version: row.version ?? null,
    is_active: !!row.is_active,
    created_at: row.created_at ?? null,
    updated_at: row.updated_at ?? null,
  };
}

async function getOpenAiApiKey(admin: any): Promise<string | null> {
  const env = Deno.env.get('OPENAI_API_KEY');
  if (env && env.trim()) return env.trim();
  try {
    const { data, error } = await admin
      .from('platform_config')
      .select('config_value')
      .eq('config_key', 'openai_api_key')
      .maybeSingle();
    if (error) return null;
    const v = (data?.config_value ?? '').trim();
    return v || null;
  } catch {
    return null;
  }
}

function computeQuantMetrics(payloads: any[]) {
  const total = payloads.length;
  const byTrait: Record<string, number> = {};
  const byType: Record<string, number> = {};
  let reverseY = 0;
  let withImage = 0;
  const weights: number[] = [];
  const scaleRanges: Record<string, number> = {};

  for (const p of payloads) {
    byTrait[p.trait] = (byTrait[p.trait] ?? 0) + 1;
    byType[p.type] = (byType[p.type] ?? 0) + 1;
    if (String(p.reverse || '').toUpperCase() === 'Y') reverseY += 1;
    if ((p.image_url ?? '').toString().trim().length > 0) withImage += 1;
    if (typeof p.weight === 'number') weights.push(p.weight);
    if (p.type === 'scale') {
      const min = typeof p.min_score === 'number' ? p.min_score : 1;
      const max = typeof p.max_score === 'number' ? p.max_score : 10;
      const k = `${min}~${max}`;
      scaleRanges[k] = (scaleRanges[k] ?? 0) + 1;
    }
  }

  const weightStats = weights.length
    ? {
        min: Math.min(...weights),
        max: Math.max(...weights),
        avg: weights.reduce((a, b) => a + b, 0) / weights.length,
      }
    : null;

  return { total, byTrait, byType, reverseY, reverseRatio: total ? reverseY / total : 0, withImage, withImageRatio: total ? withImage / total : 0, weightStats, scaleRanges };
}

async function runLlmAnalysis(opts: { apiKey: string; model: string; promptVersion: string; payloads: any[] }) {
  const { apiKey, model, promptVersion, payloads } = opts;
  const maxItems = 120; // guard
  const compact = payloads.slice(0, maxItems).map((p) => ({
    id: p.id,
    trait: p.trait,
    type: p.type,
    reverse: p.reverse,
    weight: p.weight,
    min: p.min_score,
    max: p.max_score,
    text: p.text,
  }));

  const system = `You are a psychometrics and questionnaire design assistant. Output must be valid JSON. prompt_version=${promptVersion}`;
  const user = {
    task: 'Analyze the following questionnaire items for quality and provide actionable recommendations.',
    requirements: {
      output_language: 'ko',
      include_sections: [
        'overall_summary',
        'coverage_balance',
        'redundancy_and_overlap',
        'wording_issues',
        'scale_design_issues',
        'reverse_item_balance',
        'fatigue_and_ordering',
        'top_recommendations',
      ],
      include_evidence: true,
      max_recommendations: 20,
    },
    items: compact,
  };

  const resp = await fetch('https://api.openai.com/v1/chat/completions', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model,
      temperature: 0.2,
      max_tokens: 1800,
      response_format: { type: 'json_object' },
      messages: [
        { role: 'system', content: system },
        { role: 'user', content: JSON.stringify(user) },
      ],
    }),
  });

  if (!resp.ok) {
    const t = await resp.text();
    throw new Error(`openai_http_${resp.status}: ${t.slice(0, 500)}`);
  }
  const data = await resp.json();
  const content = data?.choices?.[0]?.message?.content;
  if (!content || typeof content !== 'string') throw new Error('openai_no_content');
  return JSON.parse(content);
}

function renderHtml(report: any) {
  const esc = (s: any) =>
    String(s ?? '')
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  const metrics = report.metrics ?? {};
  const llm = report.llm ?? null;
  return `<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>성향조사 리포트</title>
  <style>
    body { font-family: ui-sans-serif, system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial; margin: 24px; color: #111; }
    h1,h2 { margin: 0 0 12px; }
    .muted { color: #666; font-size: 13px; }
    pre { background: #f6f6f6; padding: 12px; border-radius: 8px; overflow: auto; }
    table { border-collapse: collapse; width: 100%; margin: 12px 0; }
    th, td { border: 1px solid #ddd; padding: 8px; text-align: left; font-size: 13px; }
  </style>
</head>
<body>
  <h1>성향조사 리포트</h1>
  <div class="muted">run_id=${esc(report.run_id)} · snapshot_id=${esc(report.snapshot_id)} · created_at=${esc(report.created_at)}</div>

  <h2 style="margin-top:18px;">정량 요약</h2>
  <pre>${esc(JSON.stringify(metrics, null, 2))}</pre>

  <h2 style="margin-top:18px;">LLM 분석</h2>
  ${llm ? `<pre>${esc(JSON.stringify(llm, null, 2))}</pre>` : `<div class="muted">LLM 분석이 포함되지 않았습니다.</div>`}
</body>
</html>`;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405, headers: corsHeaders });

  try {
    const userClient = createUserClient(req);
    const { data: userData } = await userClient.auth.getUser();
    if (!userData?.user) return new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

    const body = await req.json();
    const filters = normalizeFilters((body?.filters_json ?? {}) as FiltersJson);
    const model = String(body?.model ?? 'gpt-4.1-mini');
    const prompt_version = String(body?.prompt_version ?? 'v1');
    const force = !!body?.force;
    const source = String(body?.source ?? 'admin_ui');

    const canonicalFilters = stableStringify(filters);
    const filters_hash = await sha256Hex(canonicalFilters);

    const admin = createAdminClient();

    let q = admin
      .from('questions')
      .select('id, area_id, group_id, trait, text, type, min_score, max_score, weight, reverse, tags, memo, image_url, pair_id, round_label, part_index, version, is_active, created_at, updated_at')
      .order('created_at', { ascending: true });

    if (filters.is_active_only) q = q.eq('is_active', true);
    if (filters.traits?.length) q = q.in('trait', filters.traits);
    if (filters.area_ids?.length) q = q.in('area_id', filters.area_ids);
    if (filters.group_ids?.length) q = q.in('group_id', filters.group_ids);
    if (filters.round_labels?.length) q = q.in('round_label', filters.round_labels);
    if (filters.part_indexes?.length) q = q.in('part_index', filters.part_indexes);
    if (typeof filters.version_min === 'number') q = q.gte('version', filters.version_min);
    if (typeof filters.version_max === 'number') q = q.lte('version', filters.version_max);
    if (filters.include_images_only) q = q.neq('image_url', '').not('image_url', 'is', null);

    const { data: rows, error: qe } = await q;
    if (qe) throw qe;

    const payloads = (rows ?? []).map(toQuestionPayload);
    const questions_count = payloads.length;

    const canonicalPayloadConcat = payloads.map((p) => stableStringify(p)).join('\n');
    const questions_hash = await sha256Hex(canonicalPayloadConcat);

    if (!force) {
      const { data: cached, error: ce } = await admin
        .from('trait_report_runs')
        .select('*')
        .eq('status', 'succeeded')
        .eq('filters_hash', filters_hash)
        .eq('questions_hash', questions_hash)
        .eq('prompt_version', prompt_version)
        .eq('model', model)
        .order('created_at', { ascending: false })
        .limit(1)
        .maybeSingle();
      if (!ce && cached?.id) {
        return new Response(JSON.stringify({ cached: true, run: cached }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
      }
    }

    // snapshot header
    const { data: snap, error: se } = await admin
      .from('trait_question_snapshots')
      .insert({
        source,
        filters_json: filters,
        filters_hash,
        questions_count,
        questions_hash,
      })
      .select('id')
      .single();
    if (se) throw se;
    const snapshot_id = snap.id as string;

    if (payloads.length) {
      const items = payloads.map((p, i) => ({
        snapshot_id,
        question_id: p.id,
        order_index: i,
        payload: p,
      }));
      const { error: ie } = await admin.from('trait_question_snapshot_items').insert(items);
      if (ie) throw ie;
    }

    // create run
    const { data: runRow, error: re } = await admin
      .from('trait_report_runs')
      .insert({
        status: 'running',
        snapshot_id,
        filters_hash,
        questions_hash,
        model,
        prompt_version,
      })
      .select('*')
      .single();
    if (re) throw re;
    const run_id = runRow.id as string;

    const metrics = computeQuantMetrics(payloads);

    let llm: any = null;
    let llm_error: string | null = null;
    try {
      const apiKey = await getOpenAiApiKey(admin);
      if (apiKey) {
        llm = await runLlmAnalysis({ apiKey, model, promptVersion: prompt_version, payloads });
      } else {
        llm_error = 'missing_openai_api_key';
      }
    } catch (e) {
      llm_error = String((e as any)?.message ?? e);
    }

    const reportJson = {
      run_id,
      snapshot_id,
      created_at: new Date().toISOString(),
      filters,
      filters_hash,
      questions_hash,
      metrics,
      llm,
      llm_error,
    };

    const html = renderHtml(reportJson);

    const report_json_path = `trait/${run_id}/report.json`;
    const report_html_path = `trait/${run_id}/report.html`;

    const jsonBytes = new TextEncoder().encode(JSON.stringify(reportJson, null, 2));
    const htmlBytes = new TextEncoder().encode(html);

    const up1 = await admin.storage.from('reports').upload(report_json_path, jsonBytes, { upsert: true, contentType: 'application/json' });
    if (up1.error) throw up1.error;
    const up2 = await admin.storage.from('reports').upload(report_html_path, htmlBytes, { upsert: true, contentType: 'text/html; charset=utf-8' });
    if (up2.error) throw up2.error;

    const { data: done, error: de } = await admin
      .from('trait_report_runs')
      .update({
        status: 'succeeded',
        report_json_path,
        report_html_path,
        metrics,
        error: llm_error,
      })
      .eq('id', run_id)
      .select('*')
      .single();
    if (de) throw de;

    return new Response(JSON.stringify({ cached: false, run: done }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
  } catch (e) {
    const msg = String((e as any)?.message ?? e);
    try {
      // best effort: if run exists, mark failed (skip)
    } catch {}
    return new Response(JSON.stringify({ error: msg }), { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
  }
});

