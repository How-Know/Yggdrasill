import { corsHeaders } from '../_shared/cors.ts';
import { createAdminClient } from '../_shared/supabase.ts';

const RENDER_PROFILE = 'student-single-v1';
const SET_COMMON_PROFILE = 'student-set-common-v1';
const SET_ITEM_PROFILE = 'student-set-item-v1';
const BODY_PAGE_PROFILE = 'student-body-page-v1';
const BODY_PAGE_CACHE_PREFIX = 'textbook-pages';
const RENDERER_VERSION = 'pb_render_v4_colontext_12:student-single-v5';
const SIGNED_URL_SECONDS = 10 * 60;
const BODY_SIGNED_URL_SECONDS = 60 * 60;
const DEFAULT_WARM_BATCH_MAX = 40;

function extractSetInfo(question: Record<string, unknown> | null) {
  if (!question) return null;
  const meta = question.meta && typeof question.meta === 'object'
    ? question.meta as Record<string, unknown>
    : {};
  const model = meta.set_model && typeof meta.set_model === 'object'
    ? meta.set_model as Record<string, unknown>
    : {};
  const delivery = meta.delivery_unit && typeof meta.delivery_unit === 'object'
    ? meta.delivery_unit as Record<string, unknown>
    : {};
  const setType = String(model.set_type ?? '').trim();
  const deliveryType = String(delivery.delivery_type ?? '').trim();
  const commonStem = String(
    delivery.common_stem ?? model.common_stem ?? model.commonStem ?? '',
  ).trim();
  if (!commonStem) return null;
  if (setType !== 'independent_set' && deliveryType !== 'independent_item') {
    return null;
  }
  const setKey = String(
    delivery.set_id ?? delivery.set_key ?? model.set_key ?? model.setKey ?? '',
  ).trim();
  if (!setKey) return null;
  return {
    set_type: 'independent_set',
    set_key: setKey,
    header_number: String(model.header_number ?? '').trim() || null,
    item_order: typeof model.item_order === 'number' ? model.item_order : null,
  };
}

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

function isMissingRelationError(error: unknown, relationName: string) {
  const source = error && typeof error === 'object'
    ? error as { code?: unknown; message?: unknown }
    : {};
  const code = String(source.code ?? '').trim().toUpperCase();
  const message = String(source.message ?? error ?? '');
  const referencesRelation =
    message.toLowerCase().includes(relationName.toLowerCase());
  return (
    referencesRelation &&
    (
      code === '42P01' ||
      code === 'PGRST205' ||
      /relation .* does not exist/i.test(message) ||
      /could not find .*schema cache/i.test(message)
    )
  );
}

async function resolveQuestion(
  admin: AdminClient,
  academyId: string,
  crop: { id: string; pb_question_uid?: string | null },
) {
  const fields = 'id,question_uid,stem,choices,figure_refs,meta';
  const { data: canonicalLink, error: canonicalError } = await admin
    .from('textbook_crop_question_links')
    .select('pb_question_id')
    .eq('academy_id', academyId)
    .eq('crop_id', crop.id)
    .maybeSingle();
  if (
    canonicalError &&
    !isMissingRelationError(canonicalError, 'textbook_crop_question_links')
  ) {
    throw new Error(`canonical_link_lookup_failed:${canonicalError.message}`);
  }
  if (canonicalLink?.pb_question_id) {
    const { data, error } = await admin
      .from('pb_questions')
      .select(fields)
      .eq('academy_id', academyId)
      .eq('is_published', true)
      .eq('id', canonicalLink.pb_question_id)
      .maybeSingle();
    if (error) {
      throw new Error(`canonical_question_lookup_failed:${error.message}`);
    }
    if (data) return data as Record<string, unknown>;
  }

  if (crop.pb_question_uid) {
    const { data } = await admin
      .from('pb_questions')
      .select(fields)
      .eq('academy_id', academyId)
      .eq('is_published', true)
      .eq('question_uid', crop.pb_question_uid)
      .maybeSingle();
    if (data) return data as Record<string, unknown>;
  }
  const { data, error } = await admin
    .from('pb_questions')
    .select(fields)
    .eq('academy_id', academyId)
    .eq('is_published', true)
    .contains('meta', { textbook_crop_page: { crop_id: crop.id } })
    .order('updated_at', { ascending: false })
    .limit(1);
  if (error) throw new Error(`question_fallback_failed:${error.message}`);
  return (data?.[0] ?? null) as Record<string, unknown> | null;
}

async function resolveQuestionsForCrops(
  admin: AdminClient,
  academyId: string,
  crops: Array<{ id: string; pb_question_uid?: string | null }>,
) {
  const byCropId = new Map<string, Record<string, unknown> | null>();
  if (crops.length === 0) return byCropId;
  const fields = 'id,question_uid,stem,choices,figure_refs,meta';
  const cropIds = crops.map((crop) => crop.id);

  const linkedIdByCropId = new Map<string, string>();
  const { data: canonicalLinks, error: canonicalError } = await admin
    .from('textbook_crop_question_links')
    .select('crop_id,pb_question_id')
    .eq('academy_id', academyId)
    .in('crop_id', cropIds);
  if (
    canonicalError &&
    !isMissingRelationError(canonicalError, 'textbook_crop_question_links')
  ) {
    throw new Error(`canonical_link_batch_failed:${canonicalError.message}`);
  }
  for (const row of canonicalLinks ?? []) {
    if (row.crop_id && row.pb_question_id) {
      linkedIdByCropId.set(String(row.crop_id), String(row.pb_question_id));
    }
  }

  const questionById = new Map<string, Record<string, unknown>>();
  const linkedIds = [...new Set([...linkedIdByCropId.values()])];
  if (linkedIds.length > 0) {
    const { data, error } = await admin
      .from('pb_questions')
      .select(fields)
      .eq('academy_id', academyId)
      .eq('is_published', true)
      .in('id', linkedIds);
    if (error) throw new Error(`canonical_question_batch_failed:${error.message}`);
    for (const q of data ?? []) {
      questionById.set(String(q.id), q as Record<string, unknown>);
    }
  }

  const missingUids = new Set<string>();
  for (const crop of crops) {
    const linkedId = linkedIdByCropId.get(crop.id);
    const linkedQ = linkedId ? questionById.get(linkedId) : undefined;
    if (linkedQ) {
      byCropId.set(crop.id, linkedQ);
    } else if (crop.pb_question_uid) {
      missingUids.add(String(crop.pb_question_uid));
    }
  }

  const questionByUid = new Map<string, Record<string, unknown>>();
  if (missingUids.size > 0) {
    const { data, error } = await admin
      .from('pb_questions')
      .select(fields)
      .eq('academy_id', academyId)
      .eq('is_published', true)
      .in('question_uid', [...missingUids]);
    if (error) throw new Error(`uid_question_batch_failed:${error.message}`);
    for (const q of data ?? []) {
      if (q.question_uid) {
        questionByUid.set(String(q.question_uid), q as Record<string, unknown>);
      }
    }
  }

  for (const crop of crops) {
    if (byCropId.has(crop.id)) continue;
    const byUid = crop.pb_question_uid
      ? questionByUid.get(String(crop.pb_question_uid))
      : undefined;
    if (byUid) {
      byCropId.set(crop.id, byUid);
      continue;
    }
    byCropId.set(crop.id, await resolveQuestion(admin, academyId, crop));
  }
  return byCropId;
}

async function enqueueOne(
  admin: AdminClient,
  academyId: string,
  cropId: string,
  priority: number,
  pbQuestionId?: string,
  renderProfile = RENDER_PROFILE,
  cacheKeyOverride?: string,
) {
  const { error } = await admin.from('question_render_jobs').insert({
    academy_id: academyId,
    crop_id: cropId,
    pb_question_id: pbQuestionId || null,
    render_profile: renderProfile,
    cache_key: cacheKeyOverride || `pending:${cropId}:${renderProfile}`,
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
        .eq('render_profile', renderProfile)
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
  crops: Array<{
    id: string;
    priority: number;
    pb_question_id?: string;
    render_profile?: string;
  }>,
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
          crop.render_profile ?? RENDER_PROFILE,
        )
      ),
    );
    inserted += results.filter(Boolean).length;
  }
  return inserted;
}

function bodyContentHashShort(value: unknown) {
  const raw = String(value ?? '').replace(/[^a-z0-9]/gi, '');
  return raw.slice(0, 16) || 'nohash';
}

async function enqueueBodyPageIfNeeded(
  admin: AdminClient,
  academyId: string,
  cropId: string,
  cacheKey: string,
  priority: number,
) {
  const { data: active } = await admin
    .from('question_render_jobs')
    .select('id,priority,status')
    .eq('academy_id', academyId)
    .eq('render_profile', BODY_PAGE_PROFILE)
    .eq('cache_key', cacheKey)
    .in('status', ['queued', 'rendering'])
    .limit(1)
    .maybeSingle();
  if (active) {
    if (active.status === 'queued' && Number(active.priority ?? 100) > priority) {
      await admin
        .from('question_render_jobs')
        .update({
          priority,
          available_at: new Date().toISOString(),
          error: '',
        })
        .eq('id', active.id)
        .eq('status', 'queued');
    }
    return false;
  }
  return await enqueueOne(
    admin,
    academyId,
    cropId,
    priority,
    undefined,
    BODY_PAGE_PROFILE,
    cacheKey,
  );
}

async function signedBodyFallback(
  admin: AdminClient,
  academyId: string,
  crop: {
    id?: string;
    book_id: string;
    grade_label: string;
    raw_page: number | null;
    item_region_1k: number[] | null;
  },
  options?: { enqueuePage?: boolean },
) {
  const { data: links, error } = await admin
    .from('resource_file_links')
    .select('id,storage_bucket,storage_key,content_hash,created_at')
    .eq('academy_id', academyId)
    .eq('file_id', crop.book_id)
    .eq('grade', `${crop.grade_label}#body`)
    .not('storage_bucket', 'is', null)
    .not('storage_key', 'is', null)
    .order('created_at', { ascending: false })
    .limit(1);
  if (error || !links?.[0]?.storage_bucket || !links[0].storage_key) return null;
  const link = links[0];
  const hashShort = bodyContentHashShort(link.content_hash);
  const bodyCacheKey = `${link.id}:${hashShort}`;
  const rawPage = typeof crop.raw_page === 'number' && crop.raw_page > 0
    ? crop.raw_page
    : null;
  const pageDir = `${BODY_PAGE_CACHE_PREFIX}/${link.id}`;
  const pageName = rawPage ? `${hashShort}_p${rawPage}.pdf` : null;
  const pageKey = pageName ? `${pageDir}/${pageName}` : null;

  const [signedFull, pageList] = await Promise.all([
    admin.storage
      .from(link.storage_bucket)
      .createSignedUrl(link.storage_key, BODY_SIGNED_URL_SECONDS),
    pageName
      ? admin.storage
          .from(link.storage_bucket)
          .list(pageDir, { search: pageName, limit: 4 })
      : Promise.resolve({ data: null, error: null }),
  ]);

  const fullUrl = !signedFull.error ? signedFull.data?.signedUrl ?? null : null;
  const pageExists = Boolean(
    pageName &&
      !pageList.error &&
      (pageList.data ?? []).some((obj) => obj.name === pageName),
  );

  let bodyPageUrl: string | null = null;
  let bodyPageStatus = 'missing';
  if (pageExists && pageKey) {
    const { data: signedPage, error: signedPageError } = await admin.storage
      .from(link.storage_bucket)
      .createSignedUrl(pageKey, BODY_SIGNED_URL_SECONDS);
    if (!signedPageError && signedPage?.signedUrl) {
      bodyPageUrl = signedPage.signedUrl;
      bodyPageStatus = 'ready';
    }
  } else if (options?.enqueuePage && rawPage && crop.id) {
    const jobCacheKey = `bodypage:${link.id}:${hashShort}:${rawPage}`;
    await enqueueBodyPageIfNeeded(admin, academyId, crop.id, jobCacheKey, 0);
    bodyPageStatus = 'queued';
  }

  if (!fullUrl && !bodyPageUrl) return null;
  return {
    ok: true,
    status: bodyPageUrl ? 'ready' : 'fallback',
    source: bodyPageUrl ? 'body_page_pdf' : 'body_pdf',
    pdf_url: bodyPageUrl ?? fullUrl,
    body_pdf_url: fullUrl,
    body_page_pdf_url: bodyPageUrl,
    body_page_status: bodyPageStatus,
    body_cache_key: bodyCacheKey,
    expires_in: BODY_SIGNED_URL_SECONDS,
    raw_page: crop.raw_page,
    item_region_1k: crop.item_region_1k,
    fallback: {
      raw_page: crop.raw_page,
      item_region_1k: crop.item_region_1k,
    },
  };
}

async function reserveBodyPageAnchorCropId(
  admin: AdminClient,
  academyId: string,
  bookId: string,
  gradeLabel: string,
  rawPage: number,
  usedCropIds: Set<string>,
): Promise<string | null> {
  const [{ data: onOrAfter }, { data: fallbackCrops }, { data: busy }] =
    await Promise.all([
      admin
        .from('textbook_problem_crops')
        .select('id,raw_page')
        .eq('academy_id', academyId)
        .eq('book_id', bookId)
        .eq('grade_label', gradeLabel)
        .eq('is_set_header', false)
        .gte('raw_page', rawPage)
        .order('raw_page', { ascending: true })
        .limit(40),
      admin
        .from('textbook_problem_crops')
        .select('id,raw_page')
        .eq('academy_id', academyId)
        .eq('book_id', bookId)
        .eq('grade_label', gradeLabel)
        .eq('is_set_header', false)
        .order('raw_page', { ascending: true })
        .limit(40),
      admin
        .from('question_render_jobs')
        .select('crop_id')
        .eq('academy_id', academyId)
        .eq('render_profile', BODY_PAGE_PROFILE)
        .in('status', ['queued', 'rendering']),
    ]);
  for (const row of busy ?? []) {
    if (row.crop_id) usedCropIds.add(String(row.crop_id));
  }
  for (const list of [onOrAfter ?? [], fallbackCrops ?? []]) {
    for (const row of list) {
      const id = String(row.id ?? '');
      if (id && !usedCropIds.has(id)) {
        usedCropIds.add(id);
        return id;
      }
    }
  }
  return null;
}

async function handleBodyView(
  admin: AdminClient,
  account: { academy_id: string; student_id: string },
  links: Array<{ book_id: string; grade_label: string }>,
  body: Record<string, unknown>,
) {
  const cropId = String(body.crop_id ?? '').trim();
  let bookId = String(body.book_id ?? '').trim();
  let gradeLabel = String(body.grade_label ?? '').trim();
  const requestedPage = Number(body.raw_page ?? 0);
  const rawPrefetch = Array.isArray(body.prefetch_pages)
    ? body.prefetch_pages
        .map((v) => Number(v))
        .filter((n) => Number.isInteger(n) && n > 0)
    : [];
  let targetCrop: {
    id?: string;
    book_id: string;
    grade_label: string;
    raw_page: number | null;
    item_region_1k: number[] | null;
  } | null = null;

  if (cropId) {
    const { data: current, error: cropError } = await admin
      .from('textbook_problem_crops')
      .select('id,academy_id,book_id,grade_label,raw_page,item_region_1k,is_set_header')
      .eq('academy_id', account.academy_id)
      .eq('id', cropId)
      .maybeSingle();
    if (cropError) throw new Error(`body_crop_query_failed:${cropError.message}`);
    if (!current || current.is_set_header || !isActiveCrop(current, links)) {
      return json({ ok: false, error: 'crop_not_assigned' }, 403);
    }
    bookId = String(current.book_id);
    gradeLabel = String(current.grade_label);
    targetCrop = {
      id: String(current.id),
      book_id: bookId,
      grade_label: gradeLabel,
      raw_page: typeof current.raw_page === 'number' ? current.raw_page : null,
      item_region_1k: Array.isArray(current.item_region_1k)
        ? current.item_region_1k
        : null,
    };
  } else if (
    bookId &&
    gradeLabel &&
    Number.isInteger(requestedPage) &&
    requestedPage > 0
  ) {
    if (!isActiveCrop({ book_id: bookId, grade_label: gradeLabel }, links)) {
      return json({ ok: false, error: 'crop_not_assigned' }, 403);
    }
    const usedIds = new Set<string>();
    const anchorCropId = await reserveBodyPageAnchorCropId(
      admin,
      account.academy_id,
      bookId,
      gradeLabel,
      requestedPage,
      usedIds,
    );
    targetCrop = {
      id: anchorCropId ?? undefined,
      book_id: bookId,
      grade_label: gradeLabel,
      raw_page: requestedPage,
      item_region_1k: null,
    };
  } else {
    return json({ ok: false, error: 'crop_id_required' }, 400);
  }

  const rawPage = typeof targetCrop.raw_page === 'number' ? targetCrop.raw_page : 0;
  const [fallback, pageRegionsRes] = await Promise.all([
    signedBodyFallback(
      admin,
      account.academy_id,
      targetCrop,
      { enqueuePage: true },
    ),
    rawPage > 0
      ? admin
          .from('textbook_problem_crops')
          .select('id,item_region_1k,bbox_1k,choice_regions_1k')
          .eq('academy_id', account.academy_id)
          .eq('book_id', bookId)
          .eq('grade_label', gradeLabel)
          .eq('raw_page', rawPage)
          .eq('is_set_header', false)
      : Promise.resolve({ data: null, error: null }),
  ]);
  if (!fallback) {
    return json({ ok: false, error: 'body_pdf_not_found' }, 404);
  }
  const pageRegions = (pageRegionsRes.data ?? []).map((row) => ({
    crop_id: String(row.id),
    item_region_1k: Array.isArray(row.item_region_1k) ? row.item_region_1k : null,
    bbox_1k: Array.isArray(row.bbox_1k) ? row.bbox_1k : null,
    choice_regions_1k:
      row.choice_regions_1k && typeof row.choice_regions_1k === 'object'
        ? row.choice_regions_1k
        : null,
  }));

  // 최소 앞뒤 1장(priority 1), 최대 현재 소단원 전체(priority 2)를 1쪽 PDF로 선행 준비한다.
  const prefetchPageUrls: Record<string, string> = {};
  if (rawPage > 0 && fallback.body_cache_key) {
    const [linkId, hashShort] = fallback.body_cache_key.split(':');
    if (linkId && hashShort) {
      const neighborPages = [
        ...(rawPage > 1 ? [rawPage - 1] : []),
        rawPage + 1,
      ];
      const orderedPrefetch: number[] = [];
      const seenPrefetch = new Set<number>([rawPage]);
      for (const p of [...neighborPages, ...rawPrefetch]) {
        if (seenPrefetch.has(p) || p <= 0) continue;
        seenPrefetch.add(p);
        orderedPrefetch.push(p);
        if (orderedPrefetch.length >= 24) break;
      }

      const { data: linkRow } = await admin
        .from('resource_file_links')
        .select('storage_bucket')
        .eq('id', Number(linkId))
        .maybeSingle();
      if (linkRow?.storage_bucket && orderedPrefetch.length > 0) {
        const bucket = String(linkRow.storage_bucket);
        const pageDir = `${BODY_PAGE_CACHE_PREFIX}/${linkId}`;
        const { data: existingList } = await admin.storage
          .from(bucket)
          .list(pageDir, {
            search: `${hashShort}_p`,
            limit: 400,
          });
        const existingNames = new Set(
          (existingList ?? []).map((o) => String(o.name)),
        );

        const toSign: number[] = [];
        const toQueue: Array<{ page: number; priority: number }> = [];
        for (const p of orderedPrefetch) {
          const name = `${hashShort}_p${p}.pdf`;
          if (existingNames.has(name)) {
            if (toSign.length < 10) toSign.push(p);
          } else {
            const isNeighbor = p === rawPage - 1 || p === rawPage + 1;
            toQueue.push({ page: p, priority: isNeighbor ? 1 : 2 });
          }
        }

        const signPromise = Promise.all(
          toSign.map(async (p) => {
            const key = `${pageDir}/${hashShort}_p${p}.pdf`;
            const { data: s } = await admin.storage
              .from(bucket)
              .createSignedUrl(key, BODY_SIGNED_URL_SECONDS);
            if (s?.signedUrl) prefetchPageUrls[String(p)] = s.signedUrl;
          }),
        );

        const usedIds = new Set<string>(
          targetCrop.id ? [targetCrop.id] : [],
        );
        const queuePromise = (async () => {
          for (const item of toQueue) {
            const anchorId = await reserveBodyPageAnchorCropId(
              admin,
              account.academy_id,
              bookId,
              gradeLabel,
              item.page,
              usedIds,
            );
            if (!anchorId) break;
            await enqueueBodyPageIfNeeded(
              admin,
              account.academy_id,
              anchorId,
              `bodypage:${linkId}:${hashShort}:${item.page}`,
              item.priority,
            );
          }
        })();

        await Promise.all([signPromise, queuePromise]);
      }
    }
  }

  return json({
    ...fallback,
    crop_id: cropId || null,
    page_regions: pageRegions,
    prefetch_page_urls: prefetchPageUrls,
    poll_after_ms: 900,
  });
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
      { enqueuePage: true },
    );
    return fallback
      ? json(fallback)
      : json({ ok: false, error: 'question_not_mapped' }, 404);
  }

  const setInfo = extractSetInfo(question);
  if (setInfo) {
    const [commonResolved, itemAssetsRes, bodyFallback] = await Promise.all([
      resolveSetCommonForCrop(admin, account.academy_id, current, setInfo.set_key),
      admin
        .from('question_render_assets')
        .select(
          'crop_id,render_profile,cache_key,storage_bucket,storage_path,page_count,rendered_at,content_hash,renderer_version',
        )
        .eq('academy_id', account.academy_id)
        .eq('crop_id', cropId)
        .eq('render_profile', SET_ITEM_PROFILE)
        .eq('render_error', '')
        .not('rendered_at', 'is', null)
        .order('rendered_at', { ascending: false })
        .limit(4),
      signedBodyFallback(admin, account.academy_id, current),
    ]);
    const itemHash = await questionContentHash(question);
    const itemPick = pickBestAsset(
      (itemAssetsRes.data ?? []) as AssetRow[],
      cropId,
      SET_ITEM_PROFILE,
      itemHash,
    );
    const queueBatch: Array<{
      id: string;
      priority: number;
      pb_question_id?: string;
      render_profile: string;
    }> = [];
    if (!commonResolved.asset || commonResolved.needsRefresh) {
      queueBatch.push({
        id: commonResolved.canonicalCropId,
        priority: commonResolved.asset ? 1 : 0,
        pb_question_id: commonResolved.canonicalQuestionId ??
          (String(question.id ?? '') || undefined),
        render_profile: SET_COMMON_PROFILE,
      });
    }
    if (!itemPick.asset || itemPick.needsRefresh) {
      queueBatch.push({
        id: cropId,
        priority: itemPick.asset ? 1 : 0,
        pb_question_id: String(question.id ?? '') || undefined,
        render_profile: SET_ITEM_PROFILE,
      });
    }
    const enqueued = queueBatch.length > 0
      ? await enqueueInChunks(admin, account.academy_id, queueBatch)
      : 0;
    return json({
      ok: true,
      status: 'queued',
      source: 'question_render_set',
      crop_id: cropId,
      enqueued,
      poll_after_ms: 1200,
      body_pdf_url: bodyFallback?.body_pdf_url,
      body_page_pdf_url: bodyFallback?.body_page_pdf_url,
      body_page_status: bodyFallback?.body_page_status,
      body_cache_key: bodyFallback?.body_cache_key,
      raw_page: current.raw_page,
      item_region_1k: current.item_region_1k,
      fallback: bodyFallback?.fallback,
      set_info: setInfo,
    }, 202);
  }

  const contentHash = await questionContentHash(question);
  const { data: assets, error: assetError } = await admin
    .from('question_render_assets')
    .select(
      'cache_key,storage_bucket,storage_path,page_count,rendered_at,content_hash,renderer_version',
    )
    .eq('academy_id', account.academy_id)
    .eq('crop_id', cropId)
    .eq('render_profile', RENDER_PROFILE)
    .eq('render_error', '')
    .not('rendered_at', 'is', null)
    .order('rendered_at', { ascending: false })
    .limit(8);
  if (assetError) throw new Error(`asset_query_failed:${assetError.message}`);
  const rows = assets ?? [];
  const currentVersion = rows.filter(
    (row) => String(row.renderer_version ?? '') === RENDERER_VERSION,
  );
  const exactAsset = currentVersion.find(
    (row) => String(row.content_hash ?? '') === contentHash,
  );
  // stale-while-revalidate. 렌더러 버전을 올리면 기존 캐시가 한꺼번에 조회
  // 대상에서 빠져 모든 학생이 동시에 로딩을 보게 된다. 그래서 완벽히 맞는
  // 산출물이 없으면 (해시만 다르거나 구버전이라도) 있는 것을 즉시 보여주고
  // 최신본은 뒤에서 다시 만든다.
  const asset = exactAsset ?? currentVersion[0] ?? rows[0] ?? null;
  const needsRefresh = Boolean(asset && !exactAsset);
  if (asset) {
    // 본문모드용 body PDF 서명은 문항 PDF 서명과 병렬로 받는다.
    const bodyFallbackPromise = signedBodyFallback(
      admin,
      account.academy_id,
      current,
    );
    const { data: signed, error: signedError } = await admin.storage
      .from(asset.storage_bucket)
      .createSignedUrl(asset.storage_path, SIGNED_URL_SECONDS);
    if (!signedError && signed?.signedUrl) {
      if (needsRefresh) {
        await enqueueOne(
          admin,
          account.academy_id,
          cropId,
          1,
          String(question.id ?? '') || undefined,
        );
      }
      const bodyFallback = await bodyFallbackPromise;
      return json({
        ok: true,
        status: 'ready',
        source: 'question_render',
        pdf_url: signed.signedUrl,
        body_pdf_url: bodyFallback?.body_pdf_url ?? null,
        body_page_pdf_url: bodyFallback?.body_page_pdf_url ?? null,
        body_page_status: bodyFallback?.body_page_status ?? null,
        body_cache_key: bodyFallback?.body_cache_key ?? null,
        expires_in: SIGNED_URL_SECONDS,
        cache_key: asset.cache_key,
        page_count: asset.page_count,
        rendered_at: asset.rendered_at,
        raw_page: current.raw_page,
        item_region_1k: current.item_region_1k,
        ...(setInfo ? { set_info: setInfo } : {}),
      });
    }
  }

  // 선택 문항만 우선 큐잉한다. 이웃은 클라이언트가 선택 문항 ready 이후에
  // 따로 prefetch 하므로, 콜드 교재에서 예열 적체를 더 키우지 않는다.
  await enqueueOne(
    admin,
    account.academy_id,
    cropId,
    0,
    String(question.id ?? '') || undefined,
  );
  const bodyFallback = await signedBodyFallback(
    admin,
    account.academy_id,
    current,
    { enqueuePage: true },
  );
  return json({
    ok: true,
    status: 'queued',
    source: 'question_render',
    crop_id: cropId,
    enqueued: 1,
    poll_after_ms: 1200,
    body_pdf_url: bodyFallback?.body_pdf_url,
    body_page_pdf_url: bodyFallback?.body_page_pdf_url,
    body_page_status: bodyFallback?.body_page_status,
    body_cache_key: bodyFallback?.body_cache_key,
    raw_page: current.raw_page,
    item_region_1k: current.item_region_1k,
    fallback: bodyFallback?.fallback,
    ...(setInfo ? { set_info: setInfo } : {}),
  }, 202);
}

type AssetRow = {
  crop_id: string;
  render_profile: string;
  cache_key: string;
  storage_bucket: string;
  storage_path: string;
  page_count: number;
  rendered_at: string;
  content_hash: string;
  renderer_version: string;
};

function pickBestAsset(
  rows: AssetRow[],
  cropId: string,
  profile: string,
  contentHash: string,
) {
  const matching = rows.filter(
    (row) => row.crop_id === cropId && row.render_profile === profile,
  );
  const currentVersion = matching.filter(
    (row) => String(row.renderer_version ?? '') === RENDERER_VERSION,
  );
  const exactAsset = currentVersion.find(
    (row) => String(row.content_hash ?? '') === contentHash,
  );
  const asset = exactAsset ?? currentVersion[0] ?? matching[0] ?? null;
  return {
    asset,
    needsRefresh: Boolean(asset && !exactAsset),
  };
}

function compareProblemNumber(a: string, b: string) {
  const na = Number.parseInt(a.trim(), 10);
  const nb = Number.parseInt(b.trim(), 10);
  const aDigits = /^\d+$/.test(a.trim());
  const bDigits = /^\d+$/.test(b.trim());
  if (aDigits && bDigits && na !== nb) return na - nb;
  return a.localeCompare(b, 'ko');
}

async function resolveSetCommonForCrop(
  admin: AdminClient,
  academyId: string,
  crop: { id: string; book_id: string; grade_label: string; raw_page?: number | null },
  setKey: string,
) {
  const page = typeof crop.raw_page === 'number' ? crop.raw_page : null;
  let query = admin
    .from('textbook_problem_crops')
    .select('id,pb_question_uid,raw_page,problem_number')
    .eq('academy_id', academyId)
    .eq('book_id', crop.book_id)
    .eq('grade_label', crop.grade_label)
    .eq('is_set_header', false)
    .not('pb_question_uid', 'is', null);
  if (page != null) {
    query = query.in('raw_page', [Math.max(1, page - 1), page, page + 1]);
  }
  const { data: nearbyCrops } = await query.limit(120);
  const list = (nearbyCrops ?? []).map((c) => ({
    id: String(c.id),
    pb_question_uid: c.pb_question_uid ? String(c.pb_question_uid) : null,
    raw_page: typeof c.raw_page === 'number' ? c.raw_page : 0,
    problem_number: String(c.problem_number ?? ''),
  }));
  if (list.length === 0) {
    return {
      canonicalCropId: crop.id,
      canonicalQuestionId: undefined as string | undefined,
      asset: null as AssetRow | null,
      needsRefresh: false,
    };
  }
  const questionsByCrop = await resolveQuestionsForCrops(admin, academyId, list);
  const matching = list
    .filter((c) => extractSetInfo(questionsByCrop.get(c.id) ?? null)?.set_key === setKey)
    .sort((a, b) =>
      a.raw_page !== b.raw_page
        ? a.raw_page - b.raw_page
        : compareProblemNumber(a.problem_number, b.problem_number)
    );
  const canonical = matching[0];
  const siblingIds = matching.length > 0 ? matching.map((m) => m.id) : [crop.id];
  const canonicalCropId = canonical?.id ?? crop.id;
  const canonicalQuestion = canonical
    ? questionsByCrop.get(canonical.id) ?? null
    : null;
  const canonicalQuestionId = canonicalQuestion
    ? (String(canonicalQuestion.id ?? '') || undefined)
    : undefined;
  const canonicalHash = canonicalQuestion
    ? await questionContentHash(canonicalQuestion)
    : '';

  const { data: commonAssets } = await admin
    .from('question_render_assets')
    .select(
      'crop_id,render_profile,cache_key,storage_bucket,storage_path,page_count,rendered_at,content_hash,renderer_version',
    )
    .eq('academy_id', academyId)
    .in('crop_id', siblingIds)
    .eq('render_profile', SET_COMMON_PROFILE)
    .eq('render_error', '')
    .not('rendered_at', 'is', null)
    .order('rendered_at', { ascending: false })
    .limit(12);
  const rows = (commonAssets ?? []) as AssetRow[];
  const bestRow = rows.find((r) => String(r.renderer_version ?? '') === RENDERER_VERSION) ??
    rows[0] ??
    null;
  const exactRow = canonicalHash
    ? rows.find(
      (r) =>
        String(r.renderer_version ?? '') === RENDERER_VERSION &&
        String(r.content_hash ?? '') === canonicalHash,
    )
    : bestRow;
  const asset = exactRow ?? bestRow ?? null;
  return {
    canonicalCropId,
    canonicalQuestionId,
    asset,
    needsRefresh: Boolean(asset && canonicalHash && !exactRow),
  };
}

async function handleViewSet(
  admin: AdminClient,
  account: { academy_id: string; student_id: string },
  links: Array<{ book_id: string; grade_label: string }>,
  body: Record<string, unknown>,
) {
  const cropIds = Array.isArray(body.crop_ids)
    ? [...new Set(body.crop_ids.map(String).filter(Boolean))].slice(0, 20)
    : [];
  if (cropIds.length === 0) {
    return json({ ok: false, error: 'crop_ids_required' }, 400);
  }
  const commonCropId = String(body.common_crop_id ?? cropIds[0]).trim() || cropIds[0];

  const queryCropIds = [...new Set([commonCropId, ...cropIds])];
  const { data: crops, error: cropError } = await admin
    .from('textbook_problem_crops')
    .select('id,academy_id,book_id,grade_label,raw_page,item_region_1k,pb_question_uid,is_set_header')
    .eq('academy_id', account.academy_id)
    .in('id', queryCropIds);
  if (cropError) throw new Error(`set_crop_query_failed:${cropError.message}`);
  const allowedById = new Map(
    (crops ?? [])
      .filter((crop) => !crop.is_set_header && isActiveCrop(crop, links))
      .map((crop) => [String(crop.id), crop]),
  );
  const commonCrop = allowedById.get(commonCropId);
  if (!commonCrop || cropIds.some((id) => !allowedById.has(id))) {
    return json({ ok: false, error: 'crop_not_assigned' }, 403);
  }

  const orderedCrops = cropIds.map((id) => allowedById.get(id)!);
  const allCrops = commonCropId === cropIds[0]
    ? orderedCrops
    : [commonCrop, ...orderedCrops];
  const questionsByCropId = await resolveQuestionsForCrops(
    admin,
    account.academy_id,
    allCrops,
  );
  const commonQuestion = questionsByCropId.get(commonCropId) ?? null;
  if (!commonQuestion) {
    const fallback = await signedBodyFallback(admin, account.academy_id, commonCrop);
    return fallback
      ? json(fallback)
      : json({ ok: false, error: 'question_not_mapped' }, 404);
  }

  const hashesByCropId = new Map<string, string>();
  for (const [id, q] of questionsByCropId.entries()) {
    if (q) hashesByCropId.set(id, await questionContentHash(q));
  }

  const targetProfiles = [SET_COMMON_PROFILE, SET_ITEM_PROFILE];
  const { data: assets, error: assetError } = await admin
    .from('question_render_assets')
    .select(
      'crop_id,render_profile,cache_key,storage_bucket,storage_path,page_count,rendered_at,content_hash,renderer_version',
    )
    .eq('academy_id', account.academy_id)
    .in('crop_id', queryCropIds)
    .in('render_profile', targetProfiles)
    .eq('render_error', '')
    .not('rendered_at', 'is', null)
    .order('rendered_at', { ascending: false })
    .limit(60);
  if (assetError) throw new Error(`set_asset_query_failed:${assetError.message}`);
  const assetRows = (assets ?? []) as AssetRow[];

  const jobsToEnqueue: Array<{
    id: string;
    priority: number;
    pb_question_id?: string;
    render_profile: string;
  }> = [];

  let commonPick = pickBestAsset(
    assetRows,
    commonCropId,
    SET_COMMON_PROFILE,
    hashesByCropId.get(commonCropId) ?? '',
  );
  const commonSetInfo = extractSetInfo(commonQuestion);
  if ((!commonPick.asset || commonPick.needsRefresh) && commonSetInfo) {
    const resolved = await resolveSetCommonForCrop(
      admin,
      account.academy_id,
      commonCrop,
      commonSetInfo.set_key,
    );
    if (resolved.asset) {
      commonPick = {
        asset: resolved.asset,
        needsRefresh: resolved.needsRefresh,
      };
    }
    if (!commonPick.asset || commonPick.needsRefresh) {
      jobsToEnqueue.push({
        id: resolved.canonicalCropId,
        priority: commonPick.asset ? 1 : 0,
        pb_question_id: resolved.canonicalQuestionId ??
          (String(commonQuestion.id ?? '') || undefined),
        render_profile: SET_COMMON_PROFILE,
      });
    }
  } else if (!commonPick.asset || commonPick.needsRefresh) {
    jobsToEnqueue.push({
      id: commonCropId,
      priority: commonPick.asset ? 1 : 0,
      pb_question_id: String(commonQuestion.id ?? '') || undefined,
      render_profile: SET_COMMON_PROFILE,
    });
  }

  const itemPicks = cropIds.map((id) => {
    const crop = allowedById.get(id)!;
    const question = questionsByCropId.get(id) ?? null;
    const profile = SET_ITEM_PROFILE;
    if (!question) {
      return { crop, question: null, profile, asset: null, needsRefresh: false };
    }
    const pick = pickBestAsset(
      assetRows,
      id,
      profile,
      hashesByCropId.get(id) ?? '',
    );
    if (!pick.asset || pick.needsRefresh) {
      jobsToEnqueue.push({
        id,
        priority: pick.asset ? 1 : 0,
        pb_question_id: String(question.id ?? '') || undefined,
        render_profile: profile,
      });
    }
    return {
      crop,
      question,
      profile,
      asset: pick.asset,
      needsRefresh: pick.needsRefresh,
    };
  });

  const bodyFallbackPromise = signedBodyFallback(
    admin,
    account.academy_id,
    orderedCrops[0],
  );
  const commonSignPromise = commonPick.asset
    ? admin.storage
        .from(commonPick.asset.storage_bucket)
        .createSignedUrl(commonPick.asset.storage_path, SIGNED_URL_SECONDS)
    : Promise.resolve({ data: null, error: null });
  const itemSignPromises = itemPicks.map((item) =>
    item.asset
      ? admin.storage
          .from(item.asset.storage_bucket)
          .createSignedUrl(item.asset.storage_path, SIGNED_URL_SECONDS)
      : Promise.resolve({ data: null, error: null })
  );
  const enqueuePromise = jobsToEnqueue.length > 0
    ? enqueueInChunks(admin, account.academy_id, jobsToEnqueue)
    : Promise.resolve(0);

  const [bodyFallback, commonSign, itemSigns] = await Promise.all([
    bodyFallbackPromise,
    commonSignPromise,
    Promise.all(itemSignPromises),
    enqueuePromise,
  ]);

  const commonUrl = !commonSign.error ? commonSign.data?.signedUrl ?? null : null;
  const itemsOut = itemPicks.map((item, idx) => {
    const sign = itemSigns[idx];
    const url = !sign.error ? sign.data?.signedUrl ?? null : null;
    return {
      crop_id: item.crop.id,
      status: url ? 'ready' : 'queued',
      pdf_url: url,
      raw_page: item.crop.raw_page,
      item_region_1k: item.crop.item_region_1k,
    };
  });
  const allReady = Boolean(commonUrl) && itemsOut.every((it) => it.status === 'ready');

  return json({
    ok: true,
    status: allReady ? 'ready' : 'queued',
    source: 'question_render_set',
    common: {
      crop_id: commonCropId,
      status: commonUrl ? 'ready' : 'queued',
      pdf_url: commonUrl,
    },
    items: itemsOut,
    body_pdf_url: bodyFallback?.body_pdf_url ?? null,
    body_page_pdf_url: bodyFallback?.body_page_pdf_url ?? null,
    body_page_status: bodyFallback?.body_page_status ?? null,
    body_cache_key: bodyFallback?.body_cache_key ?? null,
    poll_after_ms: 1200,
    expires_in: SIGNED_URL_SECONDS,
  }, allReady ? 200 : 202);
}

async function handleWarmPage(
  admin: AdminClient,
  account: { academy_id: string; student_id: string },
  links: Array<{ book_id: string; grade_label: string }>,
  body: Record<string, unknown>,
) {
  const cropIds = Array.isArray(body.crop_ids)
    ? [...new Set(body.crop_ids.map(String).filter(Boolean))].slice(0, 40)
    : [];
  if (cropIds.length === 0) {
    return json({ ok: false, error: 'crop_ids_required' }, 400);
  }
  const selectedCropId = String(body.selected_crop_id ?? '').trim();
  const shouldEnqueue = body.enqueue !== false;
  const { data: crops, error } = await admin
    .from('textbook_problem_crops')
    .select('id,book_id,grade_label,raw_page,pb_question_uid,is_set_header')
    .eq('academy_id', account.academy_id)
    .in('id', cropIds);
  if (error) throw new Error(`warm_page_crop_query_failed:${error.message}`);
  const allowedById = new Map(
    (crops ?? [])
      .filter((crop) =>
        !crop.is_set_header &&
        Boolean(crop.pb_question_uid) &&
        isActiveCrop(crop, links)
      )
      .map((crop) => [String(crop.id), crop]),
  );
  const allowed = cropIds
    .map((id) => allowedById.get(id))
    .filter((crop): crop is NonNullable<typeof crop> => Boolean(crop));

  const questionsByCropId = await resolveQuestionsForCrops(
    admin,
    account.academy_id,
    allowed,
  );
  const setsByCropId: Record<string, ReturnType<typeof extractSetInfo>> = {};
  const setInfoByCropId = new Map<string, ReturnType<typeof extractSetInfo>>();
  for (const crop of allowed) {
    const question = questionsByCropId.get(crop.id) ?? null;
    const setInfo = extractSetInfo(question);
    setInfoByCropId.set(crop.id, setInfo);
    if (setInfo) setsByCropId[crop.id] = setInfo;
  }

  if (!shouldEnqueue) {
    return json({
      ok: true,
      status: 'skipped',
      requested: cropIds.length,
      eligible: 0,
      enqueued: 0,
      sets_by_crop_id: setsByCropId,
    });
  }

  const selectedSetKey = selectedCropId
    ? setInfoByCropId.get(selectedCropId)?.set_key ?? null
    : null;
  const desiredJobs: Array<{
    id: string;
    priority: number;
    pb_question_id?: string;
    render_profile: string;
    content_hash: string;
  }> = [];
  const seenCommonSetKeys = new Set<string>();

  for (const crop of allowed) {
    const question = questionsByCropId.get(crop.id) ?? null;
    const setInfo = setInfoByCropId.get(crop.id) ?? null;
    const isSelected = crop.id === selectedCropId ||
      (selectedSetKey != null && setInfo?.set_key === selectedSetKey);
    const priority = isSelected ? 0 : 1;
    const pbQuestionId = String(question?.id ?? '') || undefined;
    const contentHash = question ? await questionContentHash(question) : '';
    if (setInfo) {
      if (!seenCommonSetKeys.has(setInfo.set_key)) {
        seenCommonSetKeys.add(setInfo.set_key);
        desiredJobs.push({
          id: crop.id,
          priority,
          pb_question_id: pbQuestionId,
          render_profile: SET_COMMON_PROFILE,
          content_hash: contentHash,
        });
      }
      desiredJobs.push({
        id: crop.id,
        priority,
        pb_question_id: pbQuestionId,
        render_profile: SET_ITEM_PROFILE,
        content_hash: contentHash,
      });
    } else {
      desiredJobs.push({
        id: crop.id,
        priority,
        pb_question_id: pbQuestionId,
        render_profile: RENDER_PROFILE,
        content_hash: contentHash,
      });
    }
  }

  let queue = desiredJobs;
  if (desiredJobs.length > 0) {
    const { data: existingAssets } = await admin
      .from('question_render_assets')
      .select('crop_id,render_profile,content_hash')
      .eq('academy_id', account.academy_id)
      .eq('renderer_version', RENDERER_VERSION)
      .eq('render_error', '')
      .not('rendered_at', 'is', null)
      .in('crop_id', allowed.map((c) => c.id));
    const exactKeys = new Set(
      (existingAssets ?? []).map((row) =>
        `${row.crop_id}|${row.render_profile}|${row.content_hash}`
      ),
    );
    queue = desiredJobs.filter((job) =>
      !job.content_hash ||
      !exactKeys.has(`${job.id}|${job.render_profile}|${job.content_hash}`)
    );
    const cropById = new Map(allowed.map((c) => [c.id, c]));
    const dedupQueue: typeof queue = [];
    for (const job of queue) {
      if (job.render_profile !== SET_COMMON_PROFILE) {
        dedupQueue.push(job);
        continue;
      }
      const crop = cropById.get(job.id);
      const setInfo = setInfoByCropId.get(job.id);
      if (!crop || !setInfo) {
        dedupQueue.push(job);
        continue;
      }
      const resolved = await resolveSetCommonForCrop(
        admin,
        account.academy_id,
        crop,
        setInfo.set_key,
      );
      if (resolved.asset && !resolved.needsRefresh) continue;
      dedupQueue.push({
        ...job,
        id: resolved.canonicalCropId,
        pb_question_id: resolved.canonicalQuestionId ?? job.pb_question_id,
      });
    }
    queue = dedupQueue;
  }

  const inserted = await enqueueInChunks(admin, account.academy_id, queue);
  return json({
    ok: true,
    status: 'queued',
    requested: cropIds.length,
    eligible: desiredJobs.length,
    enqueued: inserted,
    sets_by_crop_id: setsByCropId,
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

  const queue: Array<{
    id: string;
    priority: number;
    pb_question_id?: string;
    render_profile: string;
  }> = [];
  const seenCommonSetKeys = new Set<string>();
  let processedCrops = 0;
  let hasMore = false;
  for (const link of selectedLinks) {
    if (processedCrops >= batchMax) break;
    const remaining = batchMax - processedCrops;
    const linkOffset = selectedLinks.length === 1 ? offset : 0;
    const { data: crops, error } = await admin
      .from('textbook_problem_crops')
      .select('id,book_id,grade_label,raw_page,pb_question_uid')
      .eq('academy_id', account.academy_id)
      .eq('book_id', link.book_id)
      .eq('grade_label', link.grade_label)
      .eq('is_set_header', false)
      .not('pb_question_uid', 'is', null)
      .order('raw_page', { ascending: true })
      .order('problem_number', { ascending: true })
      .range(linkOffset, linkOffset + remaining);
    if (error) throw new Error(`warm_crop_query_failed:${error.message}`);
    const rows = (crops ?? []).slice(0, remaining);
    if (selectedLinks.length === 1 && (crops ?? []).length > remaining) {
      hasMore = true;
    }
    const questionsByCrop = await resolveQuestionsForCrops(
      admin,
      account.academy_id,
      rows.map((c) => ({
        id: String(c.id),
        pb_question_uid: c.pb_question_uid ? String(c.pb_question_uid) : null,
      })),
    );
    for (const crop of rows) {
      processedCrops += 1;
      const cropId = String(crop.id);
      const q = questionsByCrop.get(cropId) ?? null;
      const pbQuestionId = q ? (String(q.id ?? '') || undefined) : undefined;
      const setInfo = extractSetInfo(q);
      if (setInfo) {
        if (!seenCommonSetKeys.has(setInfo.set_key)) {
          seenCommonSetKeys.add(setInfo.set_key);
          const resolved = await resolveSetCommonForCrop(
            admin,
            account.academy_id,
            {
              id: cropId,
              book_id: String(crop.book_id),
              grade_label: String(crop.grade_label),
              raw_page: typeof crop.raw_page === 'number' ? crop.raw_page : null,
            },
            setInfo.set_key,
          );
          if (!resolved.asset || resolved.needsRefresh) {
            queue.push({
              id: resolved.canonicalCropId,
              priority: 2,
              pb_question_id: resolved.canonicalQuestionId ?? pbQuestionId,
              render_profile: SET_COMMON_PROFILE,
            });
          }
        }
        queue.push({
          id: cropId,
          priority: 2,
          pb_question_id: pbQuestionId,
          render_profile: SET_ITEM_PROFILE,
        });
      } else {
        queue.push({
          id: cropId,
          priority: 2,
          pb_question_id: pbQuestionId,
          render_profile: RENDER_PROFILE,
        });
      }
    }
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
      ? offset + processedCrops
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
    if (action === 'body_view') {
      return await handleBodyView(admin, account, links, body);
    }
    if (action === 'view_set') {
      return await handleViewSet(admin, account, links, body);
    }
    if (action === 'warm_page') {
      return await handleWarmPage(admin, account, links, body);
    }
    if (action === 'warm') return await handleWarm(admin, account, links, body);
    return json({ ok: false, error: 'unsupported_action' }, 400);
  } catch (error) {
    console.error('[student_textbook_problem_view]', error);
    return json({ ok: false, error: 'internal_error' }, 500);
  }
});
