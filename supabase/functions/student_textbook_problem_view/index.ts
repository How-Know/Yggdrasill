import { corsHeaders } from '../_shared/cors.ts';
import { createAdminClient } from '../_shared/supabase.ts';

const RENDER_PROFILE = 'student-single-v1';
const RENDERER_VERSION = 'pb_render_v4_slotmeasure_01:student-single-v3';
const SIGNED_URL_SECONDS = 10 * 60;
const DEFAULT_WARM_BATCH_MAX = 100;

type AdminClient = ReturnType<typeof createAdminClient>;

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

function canonicalize(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === 'object') {
    const source = value as Record<string, unknown>;
    return Object.fromEntries(
      Object.keys(source).sort().map((key) => [key, canonicalize(source[key])]),
    );
  }
  return value;
}

async function sha256(value: string) {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
}

async function questionContentHash(question: Record<string, unknown>) {
  return await sha256(JSON.stringify(canonicalize({
    stem: String(question.stem ?? ''),
    choices: Array.isArray(question.choices) ? question.choices : [],
    figure_refs: Array.isArray(question.figure_refs) ? question.figure_refs : [],
    meta: question.meta && typeof question.meta === 'object' ? question.meta : {},
  })));
}

async function studentIdentity(admin: AdminClient, req: Request) {
  const token = (req.headers.get('Authorization') ?? '')
    .replace(/^Bearer\s+/i, '')
    .trim();
  if (!token) return null;
  const { data: authData, error: authError } = await admin.auth.getUser(token);
  if (authError || !authData.user) return null;
  const { data: account, error: accountError } = await admin
    .from('student_app_accounts')
    .select('academy_id,student_id,user_id')
    .eq('user_id', authData.user.id)
    .maybeSingle();
  if (accountError || !account?.academy_id || !account?.student_id) return null;
  return account;
}

async function activeTextbookLinks(admin: AdminClient, account: {
  academy_id: string;
  student_id: string;
}) {
  const { data: flows, error: flowError } = await admin
    .from('student_flows')
    .select('id')
    .eq('academy_id', account.academy_id)
    .eq('student_id', account.student_id)
    .or('enabled.eq.true,enabled.is.null');
  if (flowError) throw new Error(`flow_query_failed:${flowError.message}`);
  const flowIds = (flows ?? []).map((flow) => flow.id);
  if (flowIds.length === 0) return [];
  const { data: links, error: linkError } = await admin
    .from('flow_textbook_links')
    .select('book_id,grade_label')
    .eq('academy_id', account.academy_id)
    .in('flow_id', flowIds);
  if (linkError) throw new Error(`link_query_failed:${linkError.message}`);
  const dedup = new Map<string, { book_id: string; grade_label: string }>();
  for (const link of links ?? []) {
    dedup.set(`${link.book_id}\u0000${link.grade_label}`, link);
  }
  return [...dedup.values()];
}

function isActiveCrop(
  crop: { book_id: string; grade_label: string },
  links: Array<{ book_id: string; grade_label: string }>,
) {
  return links.some(
    (link) =>
      link.book_id === crop.book_id &&
      link.grade_label === crop.grade_label,
  );
}

async function resolveQuestion(
  admin: AdminClient,
  academyId: string,
  crop: { id: string; pb_question_uid?: string | null },
) {
  const fields = 'id,question_uid,stem,choices,figure_refs,meta';
  if (crop.pb_question_uid) {
    const { data } = await admin
      .from('pb_questions')
      .select(fields)
      .eq('academy_id', academyId)
      .eq('question_uid', crop.pb_question_uid)
      .maybeSingle();
    if (data) return data as Record<string, unknown>;
  }
  const { data, error } = await admin
    .from('pb_questions')
    .select(fields)
    .eq('academy_id', academyId)
    .contains('meta', { textbook_crop_page: { crop_id: crop.id } })
    .order('updated_at', { ascending: false })
    .limit(1);
  if (error) throw new Error(`question_fallback_failed:${error.message}`);
  return (data?.[0] ?? null) as Record<string, unknown> | null;
}

async function enqueueOne(
  admin: AdminClient,
  academyId: string,
  cropId: string,
  priority: number,
  pbQuestionId?: string,
) {
  const { error } = await admin.from('question_render_jobs').insert({
    academy_id: academyId,
    crop_id: cropId,
    pb_question_id: pbQuestionId || null,
    render_profile: RENDER_PROFILE,
    cache_key: `pending:${cropId}:${RENDER_PROFILE}`,
    status: 'queued',
    priority,
    available_at: new Date().toISOString(),
  });
  // Partial unique index enforces dedup; a duplicate live job is success.
  if (error?.code === '23505') {
    // A warm-up job may already be queued at low priority. When the student
    // opens that exact problem, promote the existing job instead of leaving it
    // behind the entire warm-up backlog.
    if (priority < 2) {
      const { data: existing } = await admin
        .from('question_render_jobs')
        .select('id,priority,status')
        .eq('academy_id', academyId)
        .eq('crop_id', cropId)
        .eq('render_profile', RENDER_PROFILE)
        .in('status', ['queued', 'rendering'])
        .order('priority', { ascending: true })
        .limit(1)
        .maybeSingle();
      if (
        existing?.status === 'queued' &&
        Number(existing.priority ?? 100) > priority
      ) {
        const { error: promoteError } = await admin
          .from('question_render_jobs')
          .update({
            priority,
            available_at: new Date().toISOString(),
            error: '',
          })
          .eq('id', existing.id)
          .eq('status', 'queued');
        if (promoteError) {
          throw new Error(`enqueue_promote_failed:${promoteError.message}`);
        }
      }
    }
    return false;
  }
  if (error) {
    throw new Error(`enqueue_failed:${error.message}`);
  }
  return true;
}

async function enqueueInChunks(
  admin: AdminClient,
  academyId: string,
  crops: Array<{ id: string; priority: number; pb_question_id?: string }>,
) {
  let inserted = 0;
  for (let offset = 0; offset < crops.length; offset += 10) {
    const chunk = crops.slice(offset, offset + 10);
    const results = await Promise.all(
      chunk.map((crop) =>
        enqueueOne(
          admin,
          academyId,
          crop.id,
          crop.priority,
          crop.pb_question_id,
        )
      ),
    );
    inserted += results.filter(Boolean).length;
  }
  return inserted;
}

async function signedBodyFallback(
  admin: AdminClient,
  academyId: string,
  crop: {
    book_id: string;
    grade_label: string;
    raw_page: number | null;
    item_region_1k: number[] | null;
  },
) {
  const { data: links, error } = await admin
    .from('resource_file_links')
    .select('storage_bucket,storage_key,created_at')
    .eq('academy_id', academyId)
    .eq('file_id', crop.book_id)
    .eq('grade', `${crop.grade_label}#body`)
    .not('storage_bucket', 'is', null)
    .not('storage_key', 'is', null)
    .order('created_at', { ascending: false })
    .limit(1);
  if (error || !links?.[0]?.storage_bucket || !links[0].storage_key) return null;
  const link = links[0];
  const { data: signed, error: signedError } = await admin.storage
    .from(link.storage_bucket)
    .createSignedUrl(link.storage_key, SIGNED_URL_SECONDS);
  if (signedError || !signed?.signedUrl) return null;
  return {
    ok: true,
    status: 'fallback',
    source: 'body_pdf',
    pdf_url: signed.signedUrl,
    body_pdf_url: signed.signedUrl,
    expires_in: SIGNED_URL_SECONDS,
    raw_page: crop.raw_page,
    item_region_1k: crop.item_region_1k,
    fallback: {
      raw_page: crop.raw_page,
      item_region_1k: crop.item_region_1k,
    },
  };
}

async function handleView(
  admin: AdminClient,
  account: { academy_id: string; student_id: string },
  links: Array<{ book_id: string; grade_label: string }>,
  body: Record<string, unknown>,
) {
  const cropId = String(body.crop_id ?? '').trim();
  if (!cropId) return json({ ok: false, error: 'crop_id_required' }, 400);
  const neighborIds = Array.isArray(body.neighbor_crop_ids)
    ? [...new Set(body.neighbor_crop_ids.map(String).filter(Boolean))].slice(0, 20)
    : [];
  const requestedIds = [...new Set([cropId, ...neighborIds])];
  const { data: crops, error: cropError } = await admin
    .from('textbook_problem_crops')
    .select('id,academy_id,book_id,grade_label,raw_page,item_region_1k,pb_question_uid,is_set_header')
    .eq('academy_id', account.academy_id)
    .in('id', requestedIds);
  if (cropError) throw new Error(`crop_query_failed:${cropError.message}`);
  const allowed = (crops ?? []).filter(
    (crop) => !crop.is_set_header && isActiveCrop(crop, links),
  );
  const current = allowed.find((crop) => crop.id === cropId);
  if (!current) {
    return json({ ok: false, error: 'crop_not_assigned' }, 403);
  }

  const question = await resolveQuestion(admin, account.academy_id, current);
  if (!question) {
    const fallback = await signedBodyFallback(
      admin,
      account.academy_id,
      current,
    );
    return fallback
      ? json(fallback)
      : json({ ok: false, error: 'question_not_mapped' }, 404);
  }

  const contentHash = await questionContentHash(question);
  const { data: assets, error: assetError } = await admin
    .from('question_render_assets')
    .select('cache_key,storage_bucket,storage_path,page_count,rendered_at')
    .eq('academy_id', account.academy_id)
    .eq('crop_id', cropId)
    .eq('render_profile', RENDER_PROFILE)
    .eq('renderer_version', RENDERER_VERSION)
    .eq('content_hash', contentHash)
    .eq('render_error', '')
    .not('rendered_at', 'is', null)
    .order('rendered_at', { ascending: false })
    .limit(1);
  if (assetError) throw new Error(`asset_query_failed:${assetError.message}`);
  const asset = assets?.[0];
  if (asset) {
    const { data: signed, error: signedError } = await admin.storage
      .from(asset.storage_bucket)
      .createSignedUrl(asset.storage_path, SIGNED_URL_SECONDS);
    if (!signedError && signed?.signedUrl) {
      return json({
        ok: true,
        status: 'ready',
        source: 'question_render',
        pdf_url: signed.signedUrl,
        expires_in: SIGNED_URL_SECONDS,
        cache_key: asset.cache_key,
        page_count: asset.page_count,
        rendered_at: asset.rendered_at,
        raw_page: current.raw_page,
        item_region_1k: current.item_region_1k,
      });
    }
  }

  const queue = allowed
    .filter((crop) => crop.id === cropId || Boolean(crop.pb_question_uid))
    .map((crop) => ({
      id: crop.id,
      priority: crop.id === cropId ? 0 : 1,
      pb_question_id:
        crop.id === cropId ? String(question.id ?? '') || undefined : undefined,
    }));
  const inserted = await enqueueInChunks(admin, account.academy_id, queue);
  const bodyFallback = await signedBodyFallback(
    admin,
    account.academy_id,
    current,
  );
  return json({
    ok: true,
    status: 'queued',
    source: 'question_render',
    crop_id: cropId,
    enqueued: inserted,
    poll_after_ms: 1800,
    body_pdf_url: bodyFallback?.body_pdf_url,
    raw_page: current.raw_page,
    item_region_1k: current.item_region_1k,
    fallback: bodyFallback?.fallback,
  }, 202);
}

async function handleWarm(
  admin: AdminClient,
  account: { academy_id: string; student_id: string },
  links: Array<{ book_id: string; grade_label: string }>,
  body: Record<string, unknown>,
) {
  const configuredMax = Math.max(
    1,
    Number.parseInt(
      Deno.env.get('QUESTION_RENDER_WARM_BATCH_MAX') ||
        String(DEFAULT_WARM_BATCH_MAX),
      10,
    ),
  );
  const requestedMax = Number.parseInt(String(body.batch_max ?? configuredMax), 10);
  const batchMax = Math.min(
    configuredMax,
    Math.max(1, Number.isFinite(requestedMax) ? requestedMax : configuredMax),
  );
  const bookId = String(body.book_id ?? '').trim();
  const gradeLabel = String(body.grade_label ?? '').trim();
  const requestedOffset = Number.parseInt(String(body.offset ?? 0), 10);
  const offset = Math.max(
    0,
    Number.isFinite(requestedOffset) ? requestedOffset : 0,
  );
  const selectedLinks = links.filter(
    (link) =>
      (!bookId || link.book_id === bookId) &&
      (!gradeLabel || link.grade_label === gradeLabel),
  );
  if (selectedLinks.length === 0) {
    return json({ ok: false, error: 'active_textbook_not_found' }, 403);
  }

  const queue: Array<{ id: string; priority: number }> = [];
  let hasMore = false;
  for (const link of selectedLinks) {
    if (queue.length >= batchMax) break;
    const remaining = batchMax - queue.length;
    const linkOffset = selectedLinks.length === 1 ? offset : 0;
    const { data: crops, error } = await admin
      .from('textbook_problem_crops')
      .select('id')
      .eq('academy_id', account.academy_id)
      .eq('book_id', link.book_id)
      .eq('grade_label', link.grade_label)
      .eq('is_set_header', false)
      .not('pb_question_uid', 'is', null)
      .order('raw_page', { ascending: true })
      .order('problem_number', { ascending: true })
      .range(linkOffset, linkOffset + remaining);
    if (error) throw new Error(`warm_crop_query_failed:${error.message}`);
    const rows = crops ?? [];
    if (selectedLinks.length === 1 && rows.length > remaining) {
      hasMore = true;
    }
    queue.push(
      ...rows.slice(0, remaining).map((crop) => ({ id: crop.id, priority: 2 })),
    );
  }
  const inserted = await enqueueInChunks(admin, account.academy_id, queue);
  return json({
    ok: true,
    status: 'queued',
    requested: queue.length,
    enqueued: inserted,
    batch_max: batchMax,
    offset,
    next_offset: selectedLinks.length === 1 && hasMore
      ? offset + queue.length
      : null,
    has_more: selectedLinks.length === 1 && hasMore,
  }, 202);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (req.method !== 'POST') {
    return json({ ok: false, error: 'method_not_allowed' }, 405);
  }
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch (_) {
    return json({ ok: false, error: 'invalid_json' }, 400);
  }

  const admin = createAdminClient();
  const account = await studentIdentity(admin, req);
  if (!account) return json({ ok: false, error: 'unauthorized' }, 401);

  try {
    const links = await activeTextbookLinks(admin, account);
    const action = String(body.action ?? 'view').trim().toLowerCase();
    if (action === 'view') return await handleView(admin, account, links, body);
    if (action === 'warm') return await handleWarm(admin, account, links, body);
    return json({ ok: false, error: 'unsupported_action' }, 400);
  } catch (error) {
    console.error('[student_textbook_problem_view]', error);
    return json({ ok: false, error: 'internal_error' }, 500);
  }
});
