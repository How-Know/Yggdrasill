// 개념책 쪽 전사 시범: 같은 쪽 이미지·같은 지시문으로 Gemini와 OpenAI를 각각 돌려 정확도와 실제 비용을 비교한다.
//
//   Gemini: 게이트웨이 GEMINI_API_KEY 로 이 실행기가 직접 부른다.
//   OpenAI: Edge 함수 concept_page_read 를 부른다(키는 Edge 비밀값에만 있다). 운영자 이메일 인증 코드로 로그인한다.
//
// 사용(게이트웨이 폴더 기준. 저장소 맨 위에서는 node gateway/scripts/pilot_concept_page_read.mjs ...):
//   node scripts/pilot_concept_page_read.mjs prepare [--grade 1-1] [--pages 8-20] [--series gaeyu] [--book <id>]
//   node scripts/pilot_concept_page_read.mjs run --route gemini|openai [--repeat 2] [--effort low] [--pages 8-13] [--dry-run] [--force]
//   node scripts/pilot_concept_page_read.mjs report [--key-pages 8-13]
//   node scripts/pilot_concept_page_read.mjs organize [--pages 8-13] [--criteria <id,id>] [--tier primary|deep] [--effort medium] [--dry-run]
//       같은 쪽을 두 번 읽은 OpenAI 전사(r1·r2)를 Edge 함수 concept_draft_organize 로 보내 개념 초안을 받는다.
//   node scripts/pilot_concept_page_read.mjs draft-report [--draft <drafts/파일.json>]  (organize 가 끝나면 자동으로 만든다)
//   [--out <폴더>]  기본은 ~/yggdrasill_pilot/concept_page_read/<series>_<grade>
//
// 결과물에는 교재 본문이 들어가므로 저장소 안에는 쓰지 않는다.
import dotenv from 'dotenv';
import { createClient } from '@supabase/supabase-js';
import sharp from 'sharp';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, join, relative, resolve } from 'node:path';
import { createInterface } from 'node:readline/promises';
import { fileURLToPath } from 'node:url';
import {
  buildConceptPagePrompt,
  CONCEPT_PAGE_PROMPT_VERSION,
  CONCEPT_PAGE_SCHEMA,
  parseConceptPage,
} from '../../supabase/functions/concept_page_read/prompt.ts';
import {
  buildConceptDraftPrompt,
  CONCEPT_DRAFT_PROMPT_VERSION,
  prepareUnit,
} from '../../supabase/functions/concept_draft_organize/organize.ts';

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
dotenv.config({ path: join(REPO_ROOT, 'gateway', '.env'), quiet: true });
const RENDER_LONG_EDGE = 1900;
const GEMINI_PRICE = { input: 2, output: 12 }; // USD / 1M tokens, 프롬프트 20만 토큰 이하
const FULL_BOOK_PAGES = 527; // 개념+유형 6권 본문 쪽 수(견적용)

function arg(name, fallback = '') {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] && !process.argv[i + 1].startsWith('--')
    ? String(process.argv[i + 1]).trim()
    : fallback;
}
const flag = (name) => process.argv.includes(`--${name}`);

function parseRange(spec) {
  const out = new Set();
  for (const part of String(spec).split(',')) {
    const [a, b] = part.split('-').map((v) => Number.parseInt(v, 10));
    if (!Number.isFinite(a)) continue;
    for (let p = a; p <= (Number.isFinite(b) ? b : a); p += 1) out.add(p);
  }
  return [...out].sort((x, y) => x - y);
}

const command = process.argv[2] || '';
const series = arg('series', 'gaeyu');
const grade = arg('grade', '1-1');
const outDir = resolve(arg('out', join(homedir(), 'yggdrasill_pilot', 'concept_page_read', `${series}_${grade}`)));
if (!relative(REPO_ROOT, outDir).startsWith('..')) {
  console.error('결과 폴더가 저장소 안입니다. 교재 본문이 커밋되지 않도록 저장소 밖 폴더를 고르세요.');
  process.exit(1);
}
const pad = (n) => String(n).padStart(3, '0');
const manifestPath = join(outDir, 'manifest.json');

function serviceClient() {
  const url = String(process.env.SUPABASE_URL || '').trim();
  const key = String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim();
  if (!url || !key) throw new Error('gateway/.env 에 SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 가 없습니다.');
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
}

// ───────────────────────── prepare ─────────────────────────

function unitPathFor(payload, page) {
  for (const big of payload?.units ?? []) {
    for (const mid of big?.middles ?? []) {
      for (const sub of mid?.sub_units ?? []) {
        const s = Number(sub?.start_page);
        const e = Number(sub?.end_page);
        if (Number.isFinite(s) && Number.isFinite(e) && page >= s && page <= e) {
          return [big?.name, mid?.name, sub?.name].map((v) => String(v ?? '').trim()).filter(Boolean);
        }
      }
    }
  }
  return [];
}

async function fetchAll(query) {
  const rows = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await query().range(from, from + 999);
    if (error) throw new Error(error.message);
    rows.push(...(data ?? []));
    if (!data || data.length < 1000) break;
  }
  return rows;
}

function maskSvg(width, height, masks) {
  const font = Math.round(width / 45);
  const rects = masks
    .map((m) => {
      const [y0, x0, y1, x1] = m.bbox_1k;
      const x = (x0 / 1000) * width;
      const y = (y0 / 1000) * height;
      const w = ((x1 - x0) / 1000) * width;
      const h = ((y1 - y0) / 1000) * height;
      return `<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="#bdbdbd"/>` +
        `<text x="${x + font * 0.4}" y="${y + font * 1.2}" font-family="Arial" font-size="${font}" fill="#4a4a4a">${m.label}</text>`;
    })
    .join('');
  return Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}">${rects}</svg>`);
}

async function prepare() {
  const pages = parseRange(arg('pages', '8-20'));
  const db = serviceClient();
  const { data: metaRows, error } = await db
    .from('textbook_metadata')
    .select('academy_id,book_id,grade_label,payload')
    .eq('grade_label', grade);
  if (error) throw new Error(error.message);
  const bookArg = arg('book', '');
  const candidates = (metaRows ?? []).filter(
    (r) => r.payload?.series === series && (!bookArg || r.book_id === bookArg),
  );
  if (candidates.length === 0) throw new Error(`${series} ${grade} 교재 정보가 없습니다.`);
  let picked = null;
  let pickedCount = -1;
  for (const r of candidates) {
    const { count, error: ce } = await db
      .from('textbook_problem_crops')
      .select('id', { count: 'exact', head: true })
      .eq('academy_id', r.academy_id)
      .eq('book_id', r.book_id)
      .eq('grade_label', r.grade_label);
    if (ce) throw new Error(ce.message);
    if ((count ?? 0) > pickedCount) {
      picked = r;
      pickedCount = count ?? 0;
    }
  }
  if (!picked || pickedCount <= 0) throw new Error('문항 기록이 있는 교재 항목이 없습니다.');
  const { data: file } = await db.from('resource_files').select('name').eq('id', picked.book_id).maybeSingle();
  const bookName = String(file?.name ?? '').trim() || series;
  console.log(`교재: ${bookName} ${grade} (항목 ${candidates.length}개 중 문항 기록 ${pickedCount}개인 항목)`);

  const crops = await fetchAll(() =>
    db
      .from('textbook_problem_crops')
      .select('raw_page,display_page,problem_number,item_region_1k,bbox_1k')
      .eq('academy_id', picked.academy_id)
      .eq('book_id', picked.book_id)
      .eq('grade_label', picked.grade_label)
      .gte('raw_page', pages[0])
      .lte('raw_page', pages[pages.length - 1])
      .order('raw_page', { ascending: true }),
  );

  mkdirSync(join(outDir, 'pages'), { recursive: true });
  mkdirSync(join(outDir, 'cache'), { recursive: true });
  const pdfPath = join(outDir, 'cache', 'body.pdf');
  if (!existsSync(pdfPath)) {
    const link = await db
      .from('resource_file_links')
      .select('storage_bucket,storage_key')
      .eq('file_id', picked.book_id)
      .eq('grade', `${grade}#body`)
      .maybeSingle();
    if (link.error || !link.data) throw new Error(`본문 PDF 연결을 찾지 못했습니다: ${link.error?.message ?? '없음'}`);
    const dl = await db.storage.from(link.data.storage_bucket).download(link.data.storage_key);
    if (dl.error) throw new Error(dl.error.message);
    writeFileSync(pdfPath, Buffer.from(await dl.data.arrayBuffer()));
  }

  const manifestPages = [];
  for (const page of pages) {
    const tmpPrefix = join(outDir, 'cache', `render_${pad(page)}`);
    execFileSync('pdftoppm', ['-png', '-scale-to', String(RENDER_LONG_EDGE), '-f', String(page), '-l', String(page), pdfPath, tmpPrefix]);
    const rendered = readdirSync(join(outDir, 'cache')).find((f) => f.startsWith(`render_${pad(page)}`) && f.endsWith('.png'));
    if (!rendered) throw new Error(`${page}쪽을 그리지 못했습니다.`);
    const origRel = `pages/p${pad(page)}.orig.png`;
    const maskedRel = `pages/p${pad(page)}.png`;
    renameSync(join(outDir, 'cache', rendered), join(outDir, origRel));

    const pageCrops = crops
      .filter((c) => Number(c.raw_page) === page)
      .map((c) => ({
        problem_number: String(c.problem_number ?? '').trim(),
        bbox_1k: Array.isArray(c.item_region_1k) && c.item_region_1k.length === 4 ? c.item_region_1k : c.bbox_1k,
        display_page: c.display_page,
      }))
      .filter((c) => Array.isArray(c.bbox_1k) && c.bbox_1k.length === 4)
      .sort((a, b) => a.bbox_1k[1] - b.bbox_1k[1] || a.bbox_1k[0] - b.bbox_1k[0]);
    const masks = pageCrops.map((c, i) => ({
      label: `M${i + 1}`,
      bbox_1k: c.bbox_1k.map((v) => Math.round(Number(v))),
      ...(c.problem_number ? { problem_number: c.problem_number } : {}),
    }));
    const meta = await sharp(join(outDir, origRel)).metadata();
    await sharp(join(outDir, origRel))
      .composite([{ input: maskSvg(meta.width, meta.height, masks), top: 0, left: 0 }])
      .png()
      .toFile(join(outDir, maskedRel));
    const displayPage = pageCrops.find((c) => Number.isFinite(Number(c.display_page)))?.display_page ?? null;
    manifestPages.push({
      raw_page: page,
      display_page: displayPage === null ? null : Number(displayPage),
      unit_path: unitPathFor(picked.payload, page),
      image: maskedRel,
      orig: origRel,
      width: meta.width,
      height: meta.height,
      masks,
    });
    console.log(`  ${page}쪽: ${meta.width}×${meta.height}, 가린 문항 ${masks.length}개, 단원 ${unitPathFor(picked.payload, page).join(' > ') || '-'}`);
  }
  const manifest = {
    created_at: new Date().toISOString(),
    prompt_version: CONCEPT_PAGE_PROMPT_VERSION,
    book: { book_id: picked.book_id, name: bookName, grade, series },
    render_long_edge: RENDER_LONG_EDGE,
    pages: manifestPages,
  };
  writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
  console.log(`준비 끝: ${outDir}`);
}

// ───────────────────────── run ─────────────────────────

function loadManifest() {
  if (!existsSync(manifestPath)) throw new Error(`먼저 prepare 를 실행하세요: ${manifestPath}`);
  return JSON.parse(readFileSync(manifestPath, 'utf8'));
}

function promptFor(manifest, p) {
  return buildConceptPagePrompt({
    bookName: manifest.book.name,
    gradeLabel: manifest.book.grade,
    unitPath: p.unit_path,
    rawPage: p.raw_page,
    displayPage: p.display_page,
    masks: p.masks,
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function geminiBody(prompt, b64, effort) {
  return {
    systemInstruction: { parts: [{ text: prompt.instructions }] },
    contents: [{
      role: 'user',
      parts: [
        { inlineData: { mimeType: 'image/png', data: b64 }, mediaResolution: { level: 'media_resolution_ultra_high' } },
        { text: prompt.userText },
      ],
    }],
    generationConfig: {
      responseMimeType: 'application/json',
      responseJsonSchema: CONCEPT_PAGE_SCHEMA,
      thinkingConfig: { thinkingLevel: effort },
      maxOutputTokens: 32768,
    },
  };
}

function geminiConfig() {
  const key = String(process.env.GEMINI_API_KEY || '').trim();
  if (!key) throw new Error('gateway/.env 에 GEMINI_API_KEY 가 없습니다.');
  const model = arg('gemini-model', String(process.env.TEXTBOOK_VLM_MODEL || '').trim() || 'gemini-3.1-pro-preview');
  return { key, model, base: 'https://generativelanguage.googleapis.com/v1beta/models' };
}

async function geminiCountTokens(cfg, body) {
  const res = await fetch(`${cfg.base}/${cfg.model}:countTokens`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-goog-api-key': cfg.key },
    body: JSON.stringify({ generateContentRequest: { model: `models/${cfg.model}`, ...body } }),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`countTokens ${res.status}: ${json?.error?.message ?? ''}`);
  return json.totalTokens;
}

async function callGemini(cfg, body) {
  const started = Date.now();
  let lastError = '';
  for (let attempt = 0; attempt < 3; attempt += 1) {
    if (attempt > 0) await sleep(4000 * attempt);
    let res;
    try {
      res = await fetch(`${cfg.base}/${cfg.model}:generateContent`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'x-goog-api-key': cfg.key },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(300000),
      });
    } catch (e) {
      lastError = `network: ${e instanceof Error ? e.message : String(e)}`;
      continue;
    }
    const json = await res.json().catch(() => ({}));
    if (res.status === 429 || res.status >= 500) {
      lastError = `${res.status}: ${json?.error?.message ?? ''}`;
      continue;
    }
    if (!res.ok) return { ok: false, error: `${res.status}: ${json?.error?.message ?? ''}`, latency_ms: Date.now() - started };
    const cand = json.candidates?.[0];
    const text = (cand?.content?.parts ?? []).filter((p) => !p.thought && typeof p.text === 'string').map((p) => p.text).join('');
    const u = json.usageMetadata ?? {};
    const usage = {
      inputTokens: u.promptTokenCount ?? 0,
      cachedInputTokens: u.cachedContentTokenCount ?? 0,
      outputTokens: (u.candidatesTokenCount ?? 0) + (u.thoughtsTokenCount ?? 0),
      reasoningTokens: u.thoughtsTokenCount ?? 0,
    };
    const cost = (usage.inputTokens * GEMINI_PRICE.input + usage.outputTokens * GEMINI_PRICE.output) / 1_000_000;
    const page = parseConceptPage(text);
    const finish = String(cand?.finishReason ?? '');
    return {
      ok: Boolean(page) && finish === 'STOP',
      error: page ? (finish === 'STOP' ? null : `finish:${finish}`) : `invalid_output (finish:${finish})`,
      model: json.modelVersion || cfg.model,
      usage,
      cost_usd: Math.round(cost * 1e6) / 1e6,
      latency_ms: Date.now() - started,
      page,
      raw_text: text,
    };
  }
  return { ok: false, error: lastError, latency_ms: Date.now() - started };
}

async function openAiSession() {
  const url = String(process.env.SUPABASE_URL || '').trim();
  const anonKey = String(process.env.SUPABASE_ANON_KEY || '').trim();
  if (!url || !anonKey) throw new Error('gateway/.env 에 SUPABASE_URL / SUPABASE_ANON_KEY 가 없습니다.');
  const client = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: true } });
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  try {
    const email = arg('email', '') || (await rl.question('운영자 이메일: ')).trim();
    const sent = await client.auth.signInWithOtp({ email, options: { shouldCreateUser: false } });
    if (sent.error) throw new Error(`인증 코드 보내기 실패: ${sent.error.message}`);
    const code = (await rl.question('메일로 받은 인증 코드: ')).trim();
    const verified = await client.auth.verifyOtp({ email, token: code, type: 'email' });
    if (verified.error || !verified.data.session) throw new Error(`로그인 실패: ${verified.error?.message ?? '세션 없음'}`);
  } finally {
    rl.close();
  }
  return {
    url,
    anonKey,
    async token() {
      const { data } = await client.auth.getSession();
      return data.session?.access_token ?? '';
    },
    // 다른 기기(매니저 앱) 세션은 건드리지 않는다.
    close: () => client.auth.signOut({ scope: 'local' }),
  };
}

async function callOpenAi(session, manifest, p, b64, effort) {
  const started = Date.now();
  let lastError = '';
  for (let attempt = 0; attempt < 3; attempt += 1) {
    if (attempt > 0) await sleep(8000 * attempt);
    let res;
    try {
      res = await fetch(`${session.url}/functions/v1/concept_page_read`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${await session.token()}`,
          apikey: session.anonKey,
        },
        body: JSON.stringify({
          image_base64: b64,
          mime_type: 'image/png',
          book_name: manifest.book.name,
          grade_label: manifest.book.grade,
          unit_path: p.unit_path,
          raw_page: p.raw_page,
          display_page: p.display_page,
          masks: p.masks,
          effort,
        }),
        signal: AbortSignal.timeout(300000),
      });
    } catch (e) {
      lastError = `network: ${e instanceof Error ? e.message : String(e)}`;
      continue;
    }
    const json = await res.json().catch(() => ({}));
    if (res.status === 429 && json?.error === 'rate_limited') {
      lastError = 'rate_limited';
      await sleep(30000);
      continue;
    }
    if (res.status >= 500 && !json?.usage) {
      lastError = `${res.status}: ${json?.error ?? ''}`;
      continue;
    }
    if (!res.ok || !json.ok) {
      return {
        ok: false,
        error: `${res.status}: ${json?.error ?? ''}`,
        model: json?.model,
        usage: json?.usage,
        cost_usd: json?.cost_usd ?? null,
        latency_ms: Date.now() - started,
      };
    }
    return {
      ok: true,
      error: null,
      model: json.model,
      usage: json.usage,
      cost_usd: json.cost_usd,
      latency_ms: Date.now() - started,
      server_latency_ms: json.latency_ms,
      page: json.page,
    };
  }
  return { ok: false, error: lastError, latency_ms: Date.now() - started };
}

async function pool(items, size, fn) {
  let next = 0;
  await Promise.all(
    Array.from({ length: Math.min(size, items.length) }, async () => {
      while (next < items.length) {
        const item = items[next++];
        await fn(item);
      }
    }),
  );
}

async function run() {
  const route = arg('route', '');
  if (route !== 'gemini' && route !== 'openai') throw new Error('--route gemini 또는 --route openai 를 고르세요.');
  const manifest = loadManifest();
  const repeat = Math.max(1, Number.parseInt(arg('repeat', '2'), 10) || 2);
  const effort = arg('effort', 'low');
  const only = arg('pages', '') ? new Set(parseRange(arg('pages', ''))) : null;
  const pages = manifest.pages.filter((p) => !only || only.has(p.raw_page));
  const dryRun = flag('dry-run');
  const force = flag('force');

  const jobs = [];
  for (let r = 1; r <= repeat; r += 1) {
    for (const p of pages) {
      const file = join(outDir, 'results', route, `r${r}`, `p${pad(p.raw_page)}.json`);
      if (!force && existsSync(file)) {
        const prev = JSON.parse(readFileSync(file, 'utf8'));
        if (prev.ok) continue;
      }
      jobs.push({ r, p, file });
    }
  }
  console.log(`${route}: ${pages.length}쪽 × ${repeat}회 중 남은 호출 ${jobs.length}건 (추론 ${effort})`);

  if (dryRun) {
    if (route === 'gemini') {
      const cfg = geminiConfig();
      const p = pages[0];
      const b64 = readFileSync(join(outDir, p.image)).toString('base64');
      const tokens = await geminiCountTokens(cfg, geminiBody(promptFor(manifest, p), b64, effort));
      console.log(`  ${cfg.model} ${p.raw_page}쪽 입력 토큰(무료 계산): ${tokens}`);
    }
    for (const { r, p } of jobs.slice(0, 3)) {
      const kb = Math.round(readFileSync(join(outDir, p.image)).length / 1024);
      console.log(`  r${r} ${p.raw_page}쪽: 이미지 ${kb}KB, 가린 문항 ${p.masks.length}개`);
    }
    console.log('  시험 실행이라 유료 호출은 하지 않았습니다.');
    return;
  }
  if (jobs.length === 0) return;

  const gemini = route === 'gemini' ? geminiConfig() : null;
  const session = route === 'openai' ? await openAiSession() : null;
  let done = 0;
  try {
    await pool(jobs, route === 'gemini' ? 3 : 2, async ({ r, p, file }) => {
      const b64 = readFileSync(join(outDir, p.image)).toString('base64');
      const out = gemini
        ? await callGemini(gemini, geminiBody(promptFor(manifest, p), b64, effort))
        : await callOpenAi(session, manifest, p, b64, effort);
      mkdirSync(dirname(file), { recursive: true });
      writeFileSync(
        file,
        JSON.stringify(
          { route, read: r, raw_page: p.raw_page, effort, prompt_version: CONCEPT_PAGE_PROMPT_VERSION, at: new Date().toISOString(), ...out },
          null,
          2,
        ),
      );
      done += 1;
      const cost = typeof out.cost_usd === 'number' ? `$${out.cost_usd.toFixed(4)}` : '-';
      console.log(
        `  [${done}/${jobs.length}] r${r} ${p.raw_page}쪽 ${out.ok ? '완료' : `실패(${out.error})`} ` +
          `블록 ${out.page?.blocks?.length ?? 0}개 · 입력 ${out.usage?.inputTokens ?? '-'} · 출력 ${out.usage?.outputTokens ?? '-'} · ${cost} · ${Math.round((out.latency_ms ?? 0) / 1000)}초`,
      );
    });
  } finally {
    await session?.close().catch(() => {});
  }
}

// ───────────────────────── report ─────────────────────────

function normText(s) {
  return String(s ?? '').replace(/\*\*/g, '').replace(/\$/g, '').replace(/\s+/g, '');
}

function similarity(a, b) {
  if (!a && !b) return 1;
  if (!a || !b) return 0;
  const n = a.length;
  const m = b.length;
  let prev = new Uint32Array(m + 1);
  let cur = new Uint32Array(m + 1);
  for (let j = 0; j <= m; j += 1) prev[j] = j;
  for (let i = 1; i <= n; i += 1) {
    cur[0] = i;
    const ca = a.charCodeAt(i - 1);
    for (let j = 1; j <= m; j += 1) {
      const cost = ca === b.charCodeAt(j - 1) ? 0 : 1;
      cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost);
    }
    [prev, cur] = [cur, prev];
  }
  return 1 - prev[m] / Math.max(n, m);
}

// 블록 종류(제목/쪽 장식 등)를 다르게 붙여도 같은 글자면 같게 본다.
function pageText(page) {
  return (page?.blocks ?? [])
    .map((b) => [b.title, b.text].filter(Boolean).join('\n'))
    .join('\n');
}

function lineSet(page) {
  return pageText(page)
    .split('\n')
    .map((l) => l.trim())
    .filter((l) => normText(l).length >= 2);
}

/** a에만 있는 줄(공백·$·** 무시). */
function onlyIn(a, b) {
  const other = new Set(lineSet(b).map(normText));
  return lineSet(a).filter((l) => !other.has(normText(l)));
}

const GRID = 200;

async function inkGrid(path, masks) {
  const { data, info } = await sharp(path).greyscale().resize(GRID * 2, GRID * 2, { fit: 'fill' }).raw().toBuffer({ resolveWithObject: true });
  const grid = new Uint8Array(GRID * GRID);
  for (let y = 0; y < info.height; y += 1) {
    for (let x = 0; x < info.width; x += 1) {
      if (data[y * info.width + x] < 150) grid[Math.floor(y / 2) * GRID + Math.floor(x / 2)] = 1;
    }
  }
  const cell = 1000 / GRID;
  for (const m of masks) {
    const [y0, x0, y1, x1] = m.bbox_1k;
    for (let gy = Math.floor((y0 - 4) / cell); gy < Math.ceil((y1 + 4) / cell); gy += 1) {
      for (let gx = Math.floor((x0 - 4) / cell); gx < Math.ceil((x1 + 4) / cell); gx += 1) {
        if (gy >= 0 && gy < GRID && gx >= 0 && gx < GRID) grid[gy * GRID + gx] = 0;
      }
    }
  }
  return grid;
}

/** 회색 상자 밖 글자(어두운 점) 중 블록 영역이 덮는 비율과 덮이지 않은 칸. */
function coverage(grid, page) {
  const cell = 1000 / GRID;
  const covered = new Uint8Array(GRID * GRID);
  for (const b of page?.blocks ?? []) {
    if (!b.bbox_1k) continue;
    const [y0, x0, y1, x1] = b.bbox_1k;
    for (let gy = Math.max(0, Math.floor((y0 - 10) / cell)); gy < Math.min(GRID, Math.ceil((y1 + 10) / cell)); gy += 1) {
      for (let gx = Math.max(0, Math.floor((x0 - 10) / cell)); gx < Math.min(GRID, Math.ceil((x1 + 10) / cell)); gx += 1) {
        covered[gy * GRID + gx] = 1;
      }
    }
  }
  let ink = 0;
  let hit = 0;
  const missed = [];
  for (let i = 0; i < grid.length; i += 1) {
    if (!grid[i]) continue;
    ink += 1;
    if (covered[i]) hit += 1;
    else missed.push(i);
  }
  return { ratio: ink ? hit / ink : 1, missed };
}

function missedRects(missed) {
  const cell = 1000 / GRID;
  const set = new Set(missed);
  const rects = [];
  for (const i of missed) {
    if (set.has(i - 1) && (i % GRID) !== 0) continue;
    let len = 1;
    while (set.has(i + len) && ((i + len) % GRID) !== 0) len += 1;
    rects.push([Math.floor(i / GRID) * cell, (i % GRID) * cell, cell, len * cell]);
  }
  return rects;
}

const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const pct = (v) => (v === null || v === undefined || Number.isNaN(v) ? '-' : `${Math.round(v * 1000) / 10}%`);
const usd = (v) => (typeof v === 'number' ? `$${v.toFixed(v < 1 ? 4 : 2)}` : '-');

const KIND_COLORS = {
  heading: '#3b82f6',
  concept_box: '#16a34a',
  explanation: '#0ea5e9',
  example: '#a855f7',
  note: '#f59e0b',
  figure: '#ec4899',
  table: '#14b8a6',
  page_furniture: '#9ca3af',
  other: '#ef4444',
};
const KIND_LABELS = {
  heading: '제목',
  concept_box: '개념 상자',
  explanation: '설명',
  example: '예',
  note: '참고',
  figure: '그림',
  table: '표',
  page_furniture: '쪽 장식',
  other: '기타',
};

function loadResults(manifest) {
  const routes = {};
  const base = join(outDir, 'results');
  if (!existsSync(base)) return routes;
  for (const route of readdirSync(base)) {
    routes[route] = {};
    for (const read of readdirSync(join(base, route)).sort()) {
      routes[route][read] = {};
      for (const p of manifest.pages) {
        const f = join(base, route, read, `p${pad(p.raw_page)}.json`);
        if (existsSync(f)) routes[route][read][p.raw_page] = JSON.parse(readFileSync(f, 'utf8'));
      }
    }
  }
  return routes;
}

async function report() {
  const manifest = loadManifest();
  const keyPages = new Set(parseRange(arg('key-pages', '8-13')));
  const results = loadResults(manifest);
  const routeNames = Object.keys(results).sort();
  if (routeNames.length === 0) throw new Error('결과가 없습니다. run 을 먼저 실행하세요.');

  const summary = [];
  for (const route of routeNames) {
    let calls = 0, ok = 0, input = 0, output = 0, reasoning = 0, cost = 0, latency = 0;
    let model = '';
    const okPages = new Set();
    for (const read of Object.keys(results[route])) {
      for (const res of Object.values(results[route][read])) {
        calls += 1;
        if (res.ok) {
          ok += 1;
          okPages.add(`${read}:${res.raw_page}`);
        }
        model = res.model || model;
        input += res.usage?.inputTokens ?? 0;
        output += res.usage?.outputTokens ?? 0;
        reasoning += res.usage?.reasoningTokens ?? 0;
        cost += typeof res.cost_usd === 'number' ? res.cost_usd : 0;
        latency += res.latency_ms ?? 0;
      }
    }
    const perRead = calls ? cost / calls : 0;
    summary.push({ route, model, calls, ok, input, output, reasoning, cost, perRead, latency: calls ? latency / calls : 0 });
  }

  const pageRows = [];
  const sections = [];
  for (const p of manifest.pages) {
    const grid = await inkGrid(join(outDir, p.orig), p.masks);
    const reads = [];
    for (const route of routeNames) {
      for (const read of Object.keys(results[route]).sort()) {
        const res = results[route][read][p.raw_page];
        if (!res) continue;
        const cov = res.page ? coverage(grid, res.page) : null;
        reads.push({ id: `${route}/${read}`, route, read, res, cov });
      }
    }
    const r1 = (route) => reads.find((x) => x.route === route && x.read === 'r1');
    const r2 = (route) => reads.find((x) => x.route === route && x.read === 'r2');
    const self = {};
    for (const route of routeNames) {
      const a = r1(route)?.res?.page;
      const b = r2(route)?.res?.page;
      self[route] = a && b ? similarity(normText(pageText(a)), normText(pageText(b))) : null;
    }
    const [ra, rb] = routeNames;
    const cross = ra && rb && r1(ra)?.res?.page && r1(rb)?.res?.page
      ? similarity(normText(pageText(r1(ra).res.page)), normText(pageText(r1(rb).res.page)))
      : null;
    pageRows.push({ p, reads, self, cross });

    const overlays = reads
      .map((x, i) => {
        const blocks = (x.res.page?.blocks ?? [])
          .map((b, bi) => (b.bbox_1k
            ? `<rect class="blk" data-b="${esc(x.id)}#${bi}" x="${b.bbox_1k[1]}" y="${b.bbox_1k[0]}" width="${b.bbox_1k[3] - b.bbox_1k[1]}" height="${b.bbox_1k[2] - b.bbox_1k[0]}" stroke="${KIND_COLORS[b.kind]}" />`
            : ''))
          .join('');
        const missed = (x.cov ? missedRects(x.cov.missed) : [])
          .map(([y, xx, h, w]) => `<rect class="miss" x="${xx}" y="${y}" width="${w}" height="${h}"/>`)
          .join('');
        return `<g class="ov" data-read="${esc(x.id)}" style="display:${i === 0 ? 'inline' : 'none'}">${blocks}${missed}</g>`;
      })
      .join('');
    const radios = reads
      .map((x, i) => `<label><input type="radio" name="ov${p.raw_page}" value="${esc(x.id)}" ${i === 0 ? 'checked' : ''}> ${esc(x.id)}</label>`)
      .join(' ');

    const columns = routeNames
      .map((route) => {
        const tabs = reads.filter((x) => x.route === route);
        const inner = tabs
          .map((x, ti) => {
            if (!x.res.page) return `<div class="read" data-tab="${esc(x.id)}" style="display:${ti === 0 ? 'block' : 'none'}"><p class="err">실패: ${esc(x.res.error)}</p></div>`;
            const blocks = x.res.page.blocks
              .map((b, bi) => {
                const key = `${x.id}/p${p.raw_page}/${bi}`;
                const marks = keyPages.has(p.raw_page) && x.read === 'r1'
                  ? `<div class="marks" data-key="${esc(key)}">${[
                    ['ok', '정확'],
                    ['wrong', '글자·수식 틀림'],
                    ['partial', '일부 빠짐'],
                    ['extra', '넣으면 안 됨'],
                  ].map(([v, l]) => `<button data-v="${v}">${l}</button>`).join('')}</div>`
                  : '';
                return `<div class="block" data-b="${esc(x.id)}#${bi}">` +
                  `<div class="bh"><span class="kind" style="background:${KIND_COLORS[b.kind]}">${KIND_LABELS[b.kind]}</span>` +
                  `${b.title ? `<b>${esc(b.title)}</b>` : ''}${b.uncertain ? '<span class="unc">불확실</span>' : ''}` +
                  `${b.continues_from_prev_page ? '<span class="cont">앞쪽에서 이어짐</span>' : ''}${b.continues_to_next_page ? '<span class="cont">다음 쪽으로 이어짐</span>' : ''}</div>` +
                  `<div class="tx">${esc(b.text).replace(/\*\*(.+?)\*\*/g, '<b>$1</b>')}</div>` +
                  `${b.figure_description ? `<div class="fig">그림: ${esc(b.figure_description)}</div>` : ''}${marks}</div>`;
              })
              .join('');
            const missingBox = keyPages.has(p.raw_page) && x.read === 'r1'
              ? `<textarea class="missing" data-key="${esc(`${x.id}/p${p.raw_page}`)}" placeholder="통째로 빠진 내용이 있으면 적어 주세요"></textarea>`
              : '';
            return `<div class="read" data-tab="${esc(x.id)}" style="display:${ti === 0 ? 'block' : 'none'}">` +
              `<p class="meta">${esc(x.res.model)} · 쪽 종류 ${esc(x.res.page.page_kind)} · 블록 ${x.res.page.blocks.length}개 · 글자 영역 ${pct(x.cov?.ratio)} 덮음 · ${usd(x.res.cost_usd)}` +
              `${x.res.page.notes ? `<br>메모: ${esc(x.res.page.notes)}` : ''}</p>${blocks}${missingBox}</div>`;
          })
          .join('');
        const tabButtons = tabs.map((x, ti) => `<button class="tab ${ti === 0 ? 'on' : ''}" data-tab="${esc(x.id)}">${esc(x.read)}</button>`).join('');
        return `<div class="col"><h3>${esc(route)} ${tabButtons}</h3>${inner}</div>`;
      })
      .join('');

    const diffs = ra && rb && r1(ra)?.res?.page && r1(rb)?.res?.page
      ? `<details><summary>두 경로(r1)가 다르게 옮긴 줄 보기</summary><div class="diff">` +
        `<div><h4>${esc(ra)}에만</h4>${onlyIn(r1(ra).res.page, r1(rb).res.page).map((l) => `<div>${esc(l)}</div>`).join('') || '<div>없음</div>'}</div>` +
        `<div><h4>${esc(rb)}에만</h4>${onlyIn(r1(rb).res.page, r1(ra).res.page).map((l) => `<div>${esc(l)}</div>`).join('') || '<div>없음</div>'}</div>` +
        `</div></details>`
      : '';

    sections.push(
      `<section id="p${p.raw_page}"><h2>${p.raw_page}쪽 <small>${esc(p.unit_path.join(' > '))}${keyPages.has(p.raw_page) ? ' · <span class="keytag">정답 확인 대상</span>' : ''}</small></h2>` +
        `<div class="row"><div class="imgcol"><div class="ovsel">${radios} <label><input type="checkbox" class="showmiss" checked> 덮지 않은 글자(빨강)</label></div>` +
        `<div class="imgwrap"><img src="${esc(p.image)}" loading="lazy"><svg viewBox="0 0 1000 1000" preserveAspectRatio="none">${overlays}</svg></div></div>` +
        `<div class="cols">${columns}</div></div>${diffs}</section>`,
    );
  }

  const summaryRows = summary
    .map((s) => `<tr><td>${esc(s.route)}</td><td>${esc(s.model)}</td><td>${s.ok}/${s.calls}</td><td>${s.input.toLocaleString()}</td><td>${s.output.toLocaleString()} (추론 ${s.reasoning.toLocaleString()})</td><td>${Math.round(s.latency / 1000)}초</td><td>${usd(s.cost)}</td><td>${usd(s.perRead)}</td><td>${usd(s.perRead * FULL_BOOK_PAGES)} / ${usd(s.perRead * FULL_BOOK_PAGES * 2)}</td></tr>`)
    .join('');
  const agreeRows = pageRows
    .map(({ p, reads, self, cross }) => {
      const covCells = reads.map((x) => `<td>${x.res.ok ? pct(x.cov?.ratio) : '실패'}</td>`).join('');
      const selfCells = routeNames.map((r) => `<td>${pct(self[r])}</td>`).join('');
      return `<tr><td><a href="#p${p.raw_page}">${p.raw_page}</a>${keyPages.has(p.raw_page) ? ' ★' : ''}</td><td>${p.masks.length}</td>${selfCells}<td>${pct(cross)}</td>${covCells}</tr>`;
    })
    .join('');
  const readHeads = pageRows[0]?.reads.map((x) => `<th>덮음 ${esc(x.id)}</th>`).join('') ?? '';
  const selfHeads = routeNames.map((r) => `<th>${esc(r)} r1↔r2 일치</th>`).join('');

  const html = `<!doctype html><html lang="ko"><head><meta charset="utf-8"><title>개념책 쪽 전사 시범 · ${esc(manifest.book.name)} ${esc(manifest.book.grade)}</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
<script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
<script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"></script>
<style>
body{font-family:Pretendard,'Malgun Gothic',sans-serif;margin:24px;color:#1f2937;background:#f8fafc}
table{border-collapse:collapse;margin:8px 0 20px;background:#fff}td,th{border:1px solid #e5e7eb;padding:4px 8px;font-size:13px;text-align:right}th{background:#f1f5f9}td:first-child,th:first-child{text-align:left}
section{background:#fff;border:1px solid #e5e7eb;border-radius:12px;padding:16px;margin:20px 0}
.row{display:flex;gap:16px;align-items:flex-start}.imgcol{flex:0 0 36%;position:sticky;top:8px}
.imgwrap{position:relative}.imgwrap img{width:100%;display:block;border:1px solid #e5e7eb}.imgwrap svg{position:absolute;inset:0;width:100%;height:100%}
.blk{fill:none;stroke-width:3;vector-effect:non-scaling-stroke}.blk.hl{fill:rgba(250,204,21,.25);stroke-width:5}.miss{fill:rgba(239,68,68,.55)}
.nomiss .miss{display:none}
.cols{flex:1;display:flex;gap:12px;min-width:0}.col{flex:1;min-width:0}.col h3{margin:0 0 6px;font-size:15px}
.tab{font-size:12px;margin-left:4px;border:1px solid #cbd5e1;background:#fff;border-radius:6px;cursor:pointer}.tab.on{background:#1e293b;color:#fff}
.block{border:1px solid #e5e7eb;border-radius:8px;padding:6px 8px;margin:6px 0}.block.hl{border-color:#facc15;background:#fefce8}
.bh{display:flex;gap:6px;align-items:center;font-size:12px;margin-bottom:4px}.kind{color:#fff;border-radius:4px;padding:0 6px}
.unc{color:#b45309}.cont{color:#64748b}.tx{white-space:pre-wrap;font-size:14px;line-height:1.6}.fig{font-size:12px;color:#be185d;margin-top:4px}
.meta{font-size:12px;color:#475569}.err{color:#dc2626}.keytag{color:#b45309}
.marks{margin-top:4px;display:flex;gap:4px}.marks button{font-size:11px;border:1px solid #cbd5e1;background:#fff;border-radius:4px;cursor:pointer}
.marks button.on[data-v=ok]{background:#dcfce7}.marks button.on[data-v=wrong]{background:#fee2e2}.marks button.on[data-v=partial]{background:#ffedd5}.marks button.on[data-v=extra]{background:#e0e7ff}
textarea.missing{width:100%;min-height:48px;margin-top:6px}
.diff{display:flex;gap:16px;font-size:13px}.diff>div{flex:1;white-space:pre-wrap}
#tally{position:sticky;top:0;background:#1e293b;color:#fff;padding:8px 12px;border-radius:8px;font-size:13px;z-index:5}
</style></head><body>
<h1>개념책 쪽 전사 시범 · ${esc(manifest.book.name)} ${esc(manifest.book.grade)}</h1>
<p>${manifest.pages[0]?.raw_page}–${manifest.pages[manifest.pages.length - 1]?.raw_page}쪽 · 지시문 ${esc(manifest.prompt_version)} · 같은 이미지(긴 변 ${manifest.render_long_edge}px, 문항 영역 회색으로 가림)를 두 경로에 보냈습니다.</p>
<h2>비용</h2>
<table><tr><th>경로</th><th>모델</th><th>성공</th><th>입력 토큰</th><th>출력 토큰</th><th>평균 시간</th><th>합계</th><th>한 쪽 한 번</th><th>전권 ${FULL_BOOK_PAGES}쪽 1회 / 2회</th></tr>${summaryRows}</table>
<h2>쪽별 일치·덮음</h2>
<p>일치: 같은 경로를 두 번 읽은 결과(또는 두 경로 r1)의 글자 일치율(공백·$·** 무시, 블록 종류 무시). 덮음: 회색 상자 밖 글자 중 블록 영역이 덮는 비율(빨강 = 덮지 않은 곳, 놓쳤을 수 있음).</p>
<table><tr><th>쪽</th><th>가린 문항</th>${selfHeads}<th>경로 간 일치(r1)</th>${readHeads}</tr>${agreeRows}</table>
<div id="tally">정답 확인(★ 쪽, r1): 표시한 블록이 여기 집계됩니다. <button id="export">표시 결과 내보내기(JSON)</button></div>
${sections.join('\n')}
<script>
const STORE='concept_page_read_marks:${esc(manifest.book.book_id)}:${esc(manifest.book.grade)}:${esc(manifest.prompt_version)}';
const state=JSON.parse(localStorage.getItem(STORE)||'{"marks":{},"missing":{}}');
function save(){localStorage.setItem(STORE,JSON.stringify(state));tally();}
function tally(){const by={};for(const [k,v] of Object.entries(state.marks)){const r=k.split('/')[0];by[r]=by[r]||{ok:0,wrong:0,partial:0,extra:0};by[r][v]++;}
const miss={};for(const [k,v] of Object.entries(state.missing)){if(v.trim()){const r=k.split('/')[0];miss[r]=(miss[r]||0)+1;}}
const parts=Object.keys({...by,...miss}).sort().map(r=>{const t=by[r]||{ok:0,wrong:0,partial:0,extra:0};const n=t.ok+t.wrong+t.partial+t.extra;return r+': 표시 '+n+'개 · 정확 '+t.ok+' · 틀림 '+t.wrong+' · 일부 빠짐 '+t.partial+' · 넣으면 안 됨 '+t.extra+' · 통째로 빠진 쪽 '+(miss[r]||0)+(n?' · 정확도 '+Math.round(t.ok/n*1000)/10+'%':'');});
document.querySelector('#tally').firstChild.textContent=(parts.join(' │ ')||'정답 확인(★ 쪽, r1): 아직 표시한 블록이 없습니다.')+' ';}
document.querySelectorAll('.marks').forEach(m=>{const k=m.dataset.key;m.querySelectorAll('button').forEach(b=>{if(state.marks[k]===b.dataset.v)b.classList.add('on');
b.onclick=()=>{if(state.marks[k]===b.dataset.v){delete state.marks[k];}else{state.marks[k]=b.dataset.v;}m.querySelectorAll('button').forEach(x=>x.classList.toggle('on',state.marks[k]===x.dataset.v));save();};});});
document.querySelectorAll('textarea.missing').forEach(t=>{t.value=state.missing[t.dataset.key]||'';t.oninput=()=>{state.missing[t.dataset.key]=t.value;save();};});
document.querySelectorAll('.ovsel input[type=radio]').forEach(r=>r.onchange=()=>{const sec=r.closest('section');sec.querySelectorAll('g.ov').forEach(g=>g.style.display=g.dataset.read===r.value?'inline':'none');});
document.querySelectorAll('.showmiss').forEach(c=>c.onchange=()=>c.closest('section').querySelector('.imgwrap').classList.toggle('nomiss',!c.checked));
document.querySelectorAll('.tab').forEach(t=>t.onclick=()=>{const col=t.closest('.col');col.querySelectorAll('.tab').forEach(x=>x.classList.toggle('on',x===t));col.querySelectorAll('.read').forEach(x=>x.style.display=x.dataset.tab===t.dataset.tab?'block':'none');
const sec=t.closest('section');sec.querySelectorAll('g.ov').forEach(g=>g.style.display=g.dataset.read===t.dataset.tab?'inline':'none');sec.querySelectorAll('.ovsel input[type=radio]').forEach(r=>r.checked=r.value===t.dataset.tab);});
document.querySelectorAll('.block').forEach(b=>{const id=b.dataset.b;const sec=b.closest('section');b.onmouseenter=()=>{sec.querySelectorAll('rect.blk').forEach(r=>r.classList.toggle('hl',r.dataset.b===id));const g=[...sec.querySelectorAll('g.ov')];const read=id.split('#')[0];g.forEach(x=>x.style.display=x.dataset.read===read?'inline':'none');};b.onmouseleave=()=>sec.querySelectorAll('rect.blk.hl').forEach(r=>r.classList.remove('hl'));});
document.querySelector('#export').onclick=()=>{const blob=new Blob([JSON.stringify({exported_at:new Date().toISOString(),store:STORE,...state},null,2)],{type:'application/json'});const a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download='concept_page_read_marks.json';a.click();};
tally();
window.addEventListener('load',()=>{if(!window.renderMathInElement)return;document.querySelectorAll('.tx,.diff').forEach(el=>renderMathInElement(el,{delimiters:[{left:'$$',right:'$$',display:true},{left:'$',right:'$',display:false}],throwOnError:false}));});
</script></body></html>`;
  const file = join(outDir, 'report.html');
  writeFileSync(file, html);
  for (const s of summary) {
    console.log(`${s.route} (${s.model}): 성공 ${s.ok}/${s.calls}, 합계 ${usd(s.cost)}, 한 쪽 한 번 ${usd(s.perRead)}, 전권 1회 ${usd(s.perRead * FULL_BOOK_PAGES)}`);
  }
  for (const { p, reads, self, cross } of pageRows) {
    const selfText = routeNames.map((r) => `${r} ${pct(self[r])}`).join(' · ');
    const covText = reads.map((x) => `${x.id} ${x.res.ok ? pct(x.cov?.ratio) : '실패'}`).join(' · ');
    console.log(`  ${p.raw_page}쪽 반복 일치 ${selfText} · 경로 간 ${pct(cross)} · 덮음 ${covText}`);
  }
  console.log(`보고서: ${file}`);
}

// ───────────────────────── organize (2단계: 개념 초안) ─────────────────────────

const DRAFT_ROUTE = 'openai';
const DRAFT_TYPE_LABELS = {
  definition: '정의',
  property: '성질',
  method: '방법',
  notation: '표기',
  caution: '주의',
  other: '기타',
};
const EXCLUDE_LABELS = {
  problem_fragment: '문항 조각',
  section_label: '구역 이름',
  illustration: '장식 그림',
  answer_reference: '정답 안내',
  duplicate: '중복',
  other: '기타',
};

function organizeInput(manifest) {
  const pages = parseRange(arg('pages', '8-13'));
  const inManifest = new Map(manifest.pages.map((p) => [p.raw_page, p]));
  const out = [];
  for (const raw of pages) {
    const p = inManifest.get(raw);
    if (!p) throw new Error(`${raw}쪽은 준비되지 않았습니다.`);
    const read = (r) => {
      const f = join(outDir, 'results', DRAFT_ROUTE, r, `p${pad(raw)}.json`);
      if (!existsSync(f)) return null;
      const j = JSON.parse(readFileSync(f, 'utf8'));
      return j.ok ? j.page.blocks : null;
    };
    const a = read('r1');
    if (!a) throw new Error(`${raw}쪽 ${DRAFT_ROUTE} 첫 번째 전사가 없습니다.`);
    out.push({ raw_page: raw, display_page: p.display_page, a, b: read('r2') ?? [] });
  }
  const unitPath = manifest.pages.find((p) => p.raw_page === pages[0])?.unit_path ?? [];
  return { pages: out, unitPath };
}

async function organize() {
  const manifest = loadManifest();
  const { pages, unitPath } = organizeInput(manifest);
  const criterionIds = arg('criteria', '').split(',').map((s) => s.trim()).filter(Boolean);
  const tiers = [...new Set(arg('tier', 'primary').split(',').map((t) => (t.trim() === 'deep' ? 'deep' : 'primary')))];
  const effort = arg('effort', 'medium');
  const prepared = prepareUnit(pages);
  const prompt = buildConceptDraftPrompt({
    bookName: manifest.book.name,
    gradeLabel: manifest.book.grade,
    unitPath,
    prepared,
    criteria: [],
  });
  console.log(
    `${unitPath.join(' > ')} ${pages[0].raw_page}–${pages[pages.length - 1].raw_page}쪽: 블록 ${prepared.blocks.length}개 · 쪽 장식 ${prepared.furniture.length}개 · ` +
      `두 번 읽기가 다른 곳 ${prepared.disagreements.length}개 · 지시 글자 ${prompt.userText.length.toLocaleString()}자 · 기준 ${criterionIds.length}개 · ${tiers.join(',')}/${effort}`,
  );
  if (flag('dry-run')) {
    const byType = {};
    for (const d of prepared.disagreements) byType[d.type] = (byType[d.type] ?? 0) + 1;
    console.log(`  다른 곳: ${JSON.stringify(byType)}`);
    console.log('  시험 실행이라 유료 호출은 하지 않았습니다.');
    return;
  }
  if (criterionIds.length === 0) console.log('  정리 기준 없이 만듭니다. 결과에 "확정 기준 없음"으로 표시됩니다.');

  const session = await openAiSession();
  try {
    for (const tier of tiers) {
      const started = Date.now();
      let json = {};
      let status = 0;
      try {
        const res = await fetch(`${session.url}/functions/v1/concept_draft_organize`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${await session.token()}`, apikey: session.anonKey },
          body: JSON.stringify({
            book_name: manifest.book.name,
            grade_label: manifest.book.grade,
            unit_path: unitPath,
            pages,
            criterion_ids: criterionIds,
            tier,
            effort,
          }),
          signal: AbortSignal.timeout(300000),
        });
        status = res.status;
        json = await res.json().catch(() => ({}));
      } catch (e) {
        json = { ok: false, error: e instanceof Error ? e.message : String(e) };
      }
      if (!json.ok) {
        console.error(`  ${tier}: 실패(${status}): ${json.error ?? ''} · 비용 ${usd(json.cost_usd)}`);
        process.exitCode = 1;
        continue;
      }
      const stamp = new Date().toISOString().replace(/[-:]/g, '').slice(0, 15);
      const name = `p${pad(pages[0].raw_page)}-${pad(pages[pages.length - 1].raw_page)}_${tier}_${effort}_${stamp}`;
      mkdirSync(join(outDir, 'drafts'), { recursive: true });
      const file = join(outDir, 'drafts', `${name}.json`);
      writeFileSync(
        file,
        JSON.stringify({ at: new Date().toISOString(), unit_path: unitPath, pages: pages.map((p) => p.raw_page), client_latency_ms: Date.now() - started, ...json }, null, 2),
      );
      console.log(
        `  ${tier}: 개념 초안 ${json.draft.concepts.length}개 · 뺀 묶음 ${json.draft.excluded.length}개 · 처리 안 된 블록 ${json.checks.unaccounted.length}개 · ` +
          `원문 대조 안 되는 수식 ${json.checks.formula_warnings.length}개 · ${json.model} · ${usd(json.cost_usd)} · ${Math.round(json.latency_ms / 1000)}초`,
      );
      await draftReport(file);
    }
  } finally {
    await session.close().catch(() => {});
  }
}

function cropSvg(p, bbox, maxWidth = 420) {
  if (!bbox) return '';
  const [y0, x0, y1, x1] = bbox;
  const x = (x0 / 1000) * p.width;
  const y = (y0 / 1000) * p.height;
  const w = Math.max(1, ((x1 - x0) / 1000) * p.width);
  const h = Math.max(1, ((y1 - y0) / 1000) * p.height);
  const width = Math.min(maxWidth, w);
  return `<svg class="crop" viewBox="${x} ${y} ${w} ${h}" width="${width}" height="${(width * h) / w}"><image href="../${esc(p.orig)}" width="${p.width}" height="${p.height}"/></svg>`;
}

async function draftReport(fileArg) {
  const manifest = loadManifest();
  const draftsDir = join(outDir, 'drafts');
  let file = fileArg || (arg('draft', '') ? resolve(outDir, arg('draft', '')) : '');
  if (!file) {
    const list = existsSync(draftsDir) ? readdirSync(draftsDir).filter((f) => f.endsWith('.json')).sort() : [];
    if (list.length === 0) throw new Error('초안이 없습니다. organize 를 먼저 실행하세요.');
    file = join(draftsDir, list[list.length - 1]);
  }
  const d = JSON.parse(readFileSync(file, 'utf8'));
  const pageOf = new Map(manifest.pages.map((p) => [p.raw_page, p]));
  const blocks = new Map([...d.prepared.blocks, ...d.prepared.furniture].map((b) => [b.id, b]));
  const disById = new Map(d.prepared.disagreements.map((x) => [x.id, x]));
  const DIS_LABEL = { text_differs: '두 번 읽기 글자 다름', missing_in_b: '두 번째 읽기에 없음', only_in_b: '첫 번째 읽기에 없음' };
  const tx = (s) => `<div class="tx">${esc(s).replace(/\*\*(.+?)\*\*/g, '<b>$1</b>')}</div>`;
  const blockView = (id) => {
    const b = blocks.get(id);
    if (!b) return `<div class="src bad">없는 블록 id: ${esc(id)}</div>`;
    const dis = disById.get(id);
    const p = pageOf.get(b.raw_page);
    return `<div class="src"><div class="srch"><b>${b.raw_page}쪽</b> · ${esc(KIND_LABELS[b.kind] ?? b.kind)}${b.title ? ` · ${esc(b.title)}` : ''} <code>${esc(id)}</code>` +
      `${dis ? ` <span class="warn">${DIS_LABEL[dis.type]}</span>` : ''}${b.uncertain ? ' <span class="warn">전사 불확실</span>' : ''}</div>` +
      `${p ? cropSvg(p, b.bbox_1k) : ''}${tx(b.text)}` +
      `${dis?.type === 'text_differs' ? `<div class="alt">두 번째 읽기: ${tx(dis.b_text)}</div>` : ''}</div>`;
  };
  const warnByConcept = new Map();
  for (const w of d.checks.formula_warnings) {
    if (!warnByConcept.has(w.concept)) warnByConcept.set(w.concept, []);
    warnByConcept.get(w.concept).push(w.formula);
  }
  const noSource = new Set(d.checks.concepts_without_source);
  const conceptNeedsCheck = (c, i) =>
    Boolean(c.needs_check) || warnByConcept.has(i) || noSource.has(i) || c.source_blocks.some((id) => disById.has(id) || !blocks.has(id));

  const concepts = d.draft.concepts
    .map((c, i) => {
      const flags = [
        c.needs_check ? `<div class="flag">Think 확인 요청: ${esc(c.needs_check)}</div>` : '',
        warnByConcept.has(i) ? `<div class="flag">근거 블록에서 찾지 못한 수식: ${warnByConcept.get(i).map((f) => `<code>${esc(f)}</code>`).join(' ')}</div>` : '',
        noSource.has(i) ? '<div class="flag">근거 블록이 없습니다.</div>' : '',
      ].join('');
      return `<article class="concept ${conceptNeedsCheck(c, i) ? 'chk' : ''}" id="c${i}"><h3>${i + 1}. ${esc(c.title)} <span class="type">${esc(DRAFT_TYPE_LABELS[c.concept_type] ?? c.concept_type)}</span></h3>` +
        `${tx(c.content)}${flags}<div class="crit">기준 적용: ${esc(c.criterion_notes || '-')}</div>` +
        `<div class="marks" data-key="c${i}">${[['keep', '이대로'], ['edit', '고칠 것'], ['drop', '빼기']].map(([v, l]) => `<button data-v="${v}">${l}</button>`).join('')}` +
        `<input class="memo" data-key="c${i}" placeholder="메모"></div>` +
        `<details><summary>근거 블록 ${c.source_blocks.length}개</summary>${c.source_blocks.map(blockView).join('')}</details></article>`;
    })
    .join('');

  const excludedGroups = {};
  for (const e of d.draft.excluded) (excludedGroups[e.reason_type] ??= []).push(e);
  const excluded = Object.entries(excludedGroups)
    .map(([k, list]) => `<details><summary>${esc(EXCLUDE_LABELS[k] ?? k)} ${list.reduce((n, e) => n + e.block_ids.length, 0)}개</summary>` +
      list.map((e) => `<div class="exc"><div class="reason">${esc(e.reason)}</div>${e.block_ids.map(blockView).join('')}</div>`).join('') + '</details>')
    .join('');

  const unaccounted = d.checks.unaccounted.length
    ? `<details open><summary>어디에도 쓰지 않은 블록 ${d.checks.unaccounted.length}개 (개념에서 빠졌을 수 있음)</summary>${d.checks.unaccounted.map(blockView).join('')}</details>`
    : '<p>어디에도 쓰지 않은 블록: 없음</p>';
  const unknown = d.checks.unknown_ids.length ? `<p class="warn">Think가 적은 없는 블록 id: ${d.checks.unknown_ids.map(esc).join(', ')}</p>` : '';
  const checkCount = d.draft.concepts.filter((c, i) => conceptNeedsCheck(c, i)).length;
  const criteria = d.criteria.length
    ? d.criteria.map((c) => `${esc(c.title)} (${c.state === 'confirmed' ? `확정 v${c.version}` : '확정 전 초안'})`).join(', ')
    : '<span class="warn">확정 기준 없음 — Think의 기본 규칙(정의·성질·방법 단위)으로만 나눴습니다</span>';
  const furniture = d.prepared.furniture.length;

  const html = `<!doctype html><html lang="ko"><head><meta charset="utf-8"><title>개념 초안 · ${esc(d.unit_path.join(' > '))}</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
<script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
<script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"></script>
<style>
body{font-family:Pretendard,'Malgun Gothic',sans-serif;margin:24px auto;max-width:980px;color:#1f2937;background:#f8fafc;padding:0 16px}
.box{background:#fff;border:1px solid #e5e7eb;border-radius:12px;padding:16px;margin:16px 0}
.summary{white-space:pre-wrap;font-size:15px;line-height:1.7}
.concept{background:#fff;border:1px solid #e5e7eb;border-radius:12px;padding:12px 16px;margin:12px 0}.concept.chk{border-left:4px solid #f59e0b}
.concept h3{margin:0 0 6px;font-size:16px}.type{font-size:12px;background:#e0f2fe;color:#0369a1;border-radius:4px;padding:1px 6px;margin-left:4px}
.tx{white-space:pre-wrap;line-height:1.7}.flag{color:#b45309;font-size:13px;margin-top:6px}.crit{color:#64748b;font-size:12px;margin-top:6px}
.src{border-top:1px dashed #e5e7eb;padding:8px 0}.srch{font-size:12px;color:#475569;margin-bottom:4px}.crop{display:block;border:1px solid #e5e7eb;margin:4px 0;background:#fff}
.alt{background:#fff7ed;border-radius:6px;padding:4px 8px;margin-top:4px;font-size:13px}.warn{color:#b45309}.bad{color:#dc2626}
.exc{margin:8px 0 8px 12px}.reason{font-size:13px;color:#334155}
.marks{display:flex;gap:6px;align-items:center;margin-top:8px}.marks button{font-size:12px;border:1px solid #cbd5e1;background:#fff;border-radius:6px;cursor:pointer;padding:2px 8px}
.marks button.on[data-v=keep]{background:#dcfce7}.marks button.on[data-v=edit]{background:#ffedd5}.marks button.on[data-v=drop]{background:#fee2e2}.memo{flex:1;font-size:12px}
summary{cursor:pointer;color:#334155;margin-top:6px}code{font-size:11px;color:#64748b}
#bar{position:sticky;top:0;background:#1e293b;color:#fff;padding:8px 12px;border-radius:8px;font-size:13px;z-index:5}
</style></head><body>
<h1>개념 초안 · ${esc(d.unit_path.join(' > '))} (${d.pages[0]}–${d.pages[d.pages.length - 1]}쪽)</h1>
<p>${esc(manifest.book.name)} ${esc(manifest.book.grade)} · 정리 기준: ${criteria}<br>
${esc(d.model)} (${esc(d.tier)}/${esc(d.effort)}) · ${usd(d.cost_usd)} · ${Math.round(d.latency_ms / 1000)}초 · 지시문 ${esc(d.prompt_version)} · 전사 OpenAI 두 번 읽기</p>
<p class="warn">아직 저장하지 않은 초안입니다. 개념 라이브러리에는 들어가지 않았습니다.</p>
<div id="bar"><span>표시: 아직 없음</span> <button id="export">표시 결과 내보내기(JSON)</button></div>
<div class="box"><h2>결과 요약 (Think)</h2><div class="summary">${esc(d.draft.summary)}</div>
<p>개념 초안 ${d.draft.concepts.length}개 (확인 필요 ${checkCount}개) · 뺀 블록 ${d.draft.excluded.reduce((n, e) => n + e.block_ids.length, 0)}개 · 쪽 장식 자동 제외 ${furniture}개 · 두 번 읽기가 다른 곳 ${d.prepared.disagreements.length}개</p>
${d.draft.questions.length ? `<h3>Think가 묻는 것</h3><ul>${d.draft.questions.map((q) => `<li>${esc(q)}</li>`).join('')}</ul>` : ''}</div>
<div class="box"><h2>코드 검사</h2>${unaccounted}${unknown}<p>근거 블록에서 찾지 못한 수식: ${d.checks.formula_warnings.length}개 (해당 개념에 표시)</p></div>
<h2>개념 초안</h2>${concepts}
<div class="box"><h2>뺀 것</h2>${excluded || '없음'}</div>
<script>
const STORE='concept_draft_marks:${esc(basename(file))}';
const state=JSON.parse(localStorage.getItem(STORE)||'{"marks":{},"memos":{}}');
function save(){localStorage.setItem(STORE,JSON.stringify(state));tally();}
function tally(){const t={keep:0,edit:0,drop:0};for(const v of Object.values(state.marks))t[v]++;document.querySelector('#bar span').textContent='표시: 이대로 '+t.keep+' · 고칠 것 '+t.edit+' · 빼기 '+t.drop+' / ${d.draft.concepts.length}개';}
document.querySelectorAll('.marks').forEach(m=>{const k=m.dataset.key;m.querySelectorAll('button').forEach(b=>{if(state.marks[k]===b.dataset.v)b.classList.add('on');b.onclick=()=>{if(state.marks[k]===b.dataset.v)delete state.marks[k];else state.marks[k]=b.dataset.v;m.querySelectorAll('button').forEach(x=>x.classList.toggle('on',state.marks[k]===x.dataset.v));save();};});});
document.querySelectorAll('.memo').forEach(i=>{i.value=state.memos[i.dataset.key]||'';i.oninput=()=>{state.memos[i.dataset.key]=i.value;save();};});
document.querySelector('#export').onclick=()=>{const blob=new Blob([JSON.stringify({exported_at:new Date().toISOString(),draft:'${esc(basename(file))}',...state},null,2)],{type:'application/json'});const a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download='concept_draft_marks.json';a.click();};
tally();
window.addEventListener('load',()=>{if(!window.renderMathInElement)return;document.querySelectorAll('.tx,.flag').forEach(el=>renderMathInElement(el,{delimiters:[{left:'$$',right:'$$',display:true},{left:'$',right:'$',display:false}],throwOnError:false}));});
</script></body></html>`;
  const out = file.replace(/\.json$/, '.html');
  writeFileSync(out, html);
  console.log(`초안 보고서: ${out}`);
}

const commands = { prepare, run, report, organize, 'draft-report': () => draftReport('') };
if (!commands[command]) {
  console.error('사용: node scripts/pilot_concept_page_read.mjs prepare|run|report [옵션] (파일 첫머리 설명 참고)');
  process.exit(1);
}
try {
  await commands[command]();
  process.exit(0);
} catch (e) {
  console.error(e instanceof Error ? e.message : String(e));
  process.exit(1);
}
