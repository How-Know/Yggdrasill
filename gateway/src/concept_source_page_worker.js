// Think 개념 출처 원본 쪽 이미지 대기열(concept_source_page_images) 처리.
// Edge가 요청한 PDF 쪽 하나를 PNG로 만들어 private 버킷에 올린다.
// 로그에는 실패 코드만 남긴다. 서명 URL·키·원본 오류 문구는 남기지 않는다.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export const CONCEPT_PAGE_BUCKET = "concept-source-pages";
export const CONCEPT_PAGE_LONG_EDGE = 1600;
export const CONCEPT_PAGE_SMALL_EDGE = 1100;
// Edge가 모델에 넣는 상한(8MB)보다 작아야 한다.
export const CONCEPT_PAGE_MAX_BYTES = 7 * 1024 * 1024;

const JOBS = "concept_source_page_images";
const WORKERS = "concept_source_page_workers";
const LINK_COLUMNS =
  "id, academy_id, file_id, grade, storage_driver, storage_bucket, storage_key, migration_status, file_size_bytes, content_hash";

export const CONCEPT_PAGE_FAILURES = new Set([
  "link_missing",
  "link_mismatch",
  "link_legacy",
  "source_changed",
  "source_download_failed",
  "page_out_of_range",
  "render_failed",
  "image_too_large",
  "upload_failed",
]);

export class ConceptPageError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

export function conceptPageImageKey(job) {
  return (
    `academies/${job.academy_id}/books/${job.book_id}/links/${job.link_id}/` +
    `${job.content_key}_p${job.raw_page}.png`
  );
}

export function pngSize(bytes) {
  const sig = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (!bytes || bytes.length < 24) return null;
  for (let i = 0; i < sig.length; i += 1) if (bytes[i] !== sig[i]) return null;
  if (bytes.toString("latin1", 12, 16) !== "IHDR") return null;
  const width = bytes.readUInt32BE(16);
  const height = bytes.readUInt32BE(20);
  if (!width || !height) return null;
  return { width, height };
}

export async function renderPdfPagePng({
  execFile,
  srcPath,
  page,
  longEdge = CONCEPT_PAGE_LONG_EDGE,
  tmpRoot = os.tmpdir(),
}) {
  let pages;
  try {
    const info = await execFile("pdfinfo", [srcPath], {
      maxBuffer: 4 * 1024 * 1024,
      windowsHide: true,
    });
    const m = /^Pages:\s+(\d+)/m.exec(String(info?.stdout ?? info ?? ""));
    pages = m ? Number(m[1]) : NaN;
  } catch {
    throw new ConceptPageError("render_failed");
  }
  if (!Number.isInteger(pages) || pages < 1) {
    throw new ConceptPageError("render_failed");
  }
  if (!Number.isInteger(page) || page < 1 || page > pages) {
    throw new ConceptPageError("page_out_of_range");
  }
  const dir = await fs.promises.mkdtemp(path.join(tmpRoot, "ygg-cpage-"));
  try {
    const outBase = path.join(dir, "page");
    try {
      await execFile(
        "pdftoppm",
        [
          "-f",
          String(page),
          "-l",
          String(page),
          "-png",
          "-singlefile",
          "-scale-to",
          String(longEdge),
          srcPath,
          outBase,
        ],
        { maxBuffer: 16 * 1024 * 1024, windowsHide: true },
      );
    } catch {
      throw new ConceptPageError("render_failed");
    }
    const bytes = await fs.promises.readFile(`${outBase}.png`).catch(() => null);
    const size = pngSize(bytes);
    if (!size) throw new ConceptPageError("render_failed");
    return { bytes, width: size.width, height: size.height, pages };
  } finally {
    await fs.promises.rm(dir, { recursive: true, force: true }).catch(() => {});
  }
}

/** supabase-js(서버 키) 위의 얇은 대기열 접근. 상태를 바꾸는 쓰기는 모두 조건부다. */
export function createConceptPageStore(supa) {
  const nowIso = () => new Date().toISOString();
  return {
    async beat(workerName) {
      const { error } = await supa
        .from(WORKERS)
        .upsert({ name: workerName, seen_at: nowIso() }, { onConflict: "name" });
      if (error) throw new ConceptPageError(`beat_failed:${error.code || "x"}`);
    },
    async claimNext(workerName) {
      const { data, error } = await supa
        .from(JOBS)
        .select(
          "id, academy_id, book_id, grade_label, raw_page, link_id, content_key, attempts",
        )
        .eq("status", "queued")
        .order("requested_at", { ascending: true })
        .limit(1);
      if (error) throw new ConceptPageError(`poll_failed:${error.code || "x"}`);
      const job = data?.[0];
      if (!job) return null;
      const at = nowIso();
      const claimed = await supa
        .from(JOBS)
        .update({
          status: "working",
          worker_name: workerName,
          started_at: at,
          heartbeat_at: at,
          finished_at: null,
          error: null,
          attempts: Number(job.attempts || 0) + 1,
        })
        .eq("id", job.id)
        .eq("status", "queued")
        .eq("link_id", job.link_id)
        .eq("content_key", job.content_key)
        .select("id");
      if (claimed.error) {
        throw new ConceptPageError(`claim_failed:${claimed.error.code || "x"}`);
      }
      return claimed.data?.length ? job : false;
    },
    async heartbeat(job, workerName) {
      await supa
        .from(JOBS)
        .update({ heartbeat_at: nowIso() })
        .eq("id", job.id)
        .eq("status", "working")
        .eq("worker_name", workerName);
    },
    async finish(job, workerName, patch) {
      const at = nowIso();
      const { data, error } = await supa
        .from(JOBS)
        .update({ ...patch, finished_at: at, heartbeat_at: at })
        .eq("id", job.id)
        .eq("status", "working")
        .eq("worker_name", workerName)
        .eq("link_id", job.link_id)
        .eq("content_key", job.content_key)
        .select("id");
      if (error) throw new ConceptPageError(`finish_failed:${error.code || "x"}`);
      return Boolean(data?.length);
    },
    async getLink(linkId) {
      const { data, error } = await supa
        .from("resource_file_links")
        .select(LINK_COLUMNS)
        .eq("id", linkId)
        .maybeSingle();
      if (error) throw new ConceptPageError("link_missing");
      return data || null;
    },
    async upload(key, bytes) {
      const { error } = await supa.storage
        .from(CONCEPT_PAGE_BUCKET)
        .upload(key, bytes, { contentType: "image/png", upsert: true });
      return { ok: !error };
    },
  };
}

export function checkConceptPageLink(job, link, contentKeyOf) {
  if (!link) return "link_missing";
  if (
    String(link.academy_id) !== String(job.academy_id) ||
    String(link.file_id) !== String(job.book_id) ||
    String(link.grade || "") !== `${job.grade_label}#body`
  ) {
    return "link_mismatch";
  }
  const status = String(link.migration_status || "legacy");
  if (
    status === "legacy" ||
    !link.storage_driver ||
    !link.storage_bucket ||
    !link.storage_key
  ) {
    return "link_legacy";
  }
  if (contentKeyOf(link) !== job.content_key) return "source_changed";
  return null;
}

export function createConceptPageWorker({
  store,
  workerName,
  contentKeyOf,
  ensureOriginal,
  renderPage,
  log = console,
  pollMs = 1500,
  idleBackoffMs = 30000,
  heartbeatMs = 15000,
  setTimer = setTimeout,
  clearTimer = clearTimeout,
  setRepeat = setInterval,
  clearRepeat = clearInterval,
}) {
  let running = false;
  let timer = null;
  let beatTimer = null;
  const reported = new Set();

  const problem = (code) => {
    if (reported.has(code)) return;
    reported.add(code);
    log.warn?.(`[concept-page] ${code}`);
  };
  const recovered = (prefix) => {
    for (const code of reported) if (code.startsWith(prefix)) reported.delete(code);
  };

  async function processJob(job) {
    const startedAt = Date.now();
    const jobBeat = setRepeat(() => {
      void store.heartbeat(job, workerName).catch(() => {});
    }, heartbeatMs);
    let code = null;
    let result = null;
    try {
      const link = await store.getLink(job.link_id);
      code = checkConceptPageLink(job, link, contentKeyOf);
      if (!code) {
        let srcPath;
        try {
          srcPath = await ensureOriginal(link);
        } catch {
          code = "source_download_failed";
        }
        if (!code) {
          result = await renderPage({ srcPath, page: job.raw_page });
          if (result.bytes.length > CONCEPT_PAGE_MAX_BYTES) {
            result = await renderPage({
              srcPath,
              page: job.raw_page,
              longEdge: CONCEPT_PAGE_SMALL_EDGE,
            });
          }
          if (result.bytes.length > CONCEPT_PAGE_MAX_BYTES) code = "image_too_large";
        }
        if (!code) {
          const key = conceptPageImageKey(job);
          const up = await store.upload(key, result.bytes).catch(() => ({ ok: false }));
          if (!up?.ok) code = "upload_failed";
          else {
            const kept = await store.finish(job, workerName, {
              status: "ready",
              error: null,
              image_key: key,
              width: result.width,
              height: result.height,
              bytes: result.bytes.length,
            });
            log.info?.(
              `[concept-page] ${kept ? "ready" : "superseded"} ${JSON.stringify({ id: job.id, page: job.raw_page, ms: Date.now() - startedAt })}`,
            );
            return kept ? "ready" : "superseded";
          }
        }
      }
    } catch (e) {
      code = CONCEPT_PAGE_FAILURES.has(e?.code) ? e.code : "render_failed";
    } finally {
      clearRepeat(jobBeat);
    }
    await store
      .finish(job, workerName, {
        status: "failed",
        error: code,
        image_key: null,
        width: null,
        height: null,
        bytes: null,
      })
      .catch(() => false);
    log.warn?.(
      `[concept-page] failed ${JSON.stringify({ id: job.id, page: job.raw_page, code })}`,
    );
    return "failed";
  }

  async function tick() {
    let job;
    try {
      job = await store.claimNext(workerName);
    } catch (e) {
      problem(String(e?.code || "poll_failed"));
      return "error";
    }
    recovered("poll_failed");
    recovered("claim_failed");
    if (job === null) return "idle";
    if (job === false) return "busy";
    return processJob(job);
  }

  async function beat() {
    try {
      await store.beat(workerName);
      recovered("beat_failed");
    } catch (e) {
      problem(String(e?.code || "beat_failed"));
    }
  }

  function schedule(ms) {
    if (!running) return;
    timer = setTimer(async () => {
      const r = await tick().catch(() => "error");
      schedule(r === "error" ? idleBackoffMs : r === "idle" ? pollMs : 0);
    }, ms);
  }

  return {
    tick,
    beat,
    start() {
      if (running) return;
      running = true;
      void beat();
      beatTimer = setRepeat(() => void beat(), heartbeatMs);
      schedule(0);
    },
    stop() {
      running = false;
      if (timer) clearTimer(timer);
      if (beatTimer) clearRepeat(beatTimer);
    },
  };
}
