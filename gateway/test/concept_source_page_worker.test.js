import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile as execFileCb } from 'node:child_process';
import { promisify } from 'node:util';
import { PDFDocument } from 'pdf-lib';

import {
  CONCEPT_PAGE_MAX_BYTES,
  ConceptPageError,
  conceptPageImageKey,
  createConceptPageWorker,
  pngSize,
  renderPdfPagePng,
} from '../src/concept_source_page_worker.js';

const execFile = promisify(execFileCb);
const popplerMissing = await execFile('pdftoppm', ['-v'], { windowsHide: true })
  .then(() => false)
  .catch((e) => (e?.code === 'ENOENT' ? 'poppler(pdftoppm) 없음' : false));

const contentKeyOf = (row) => String(row?.content_hash || '').replace(/[^a-z0-9]/gi, '').slice(0, 16) || 'nohash';

const JOB = {
  id: 'job-1',
  academy_id: 'acad-1',
  book_id: 'book-1',
  grade_label: '1-1',
  raw_page: 12,
  link_id: 7,
  content_key: 'sha256ABCDEF0123',
  attempts: 0,
};
const LINK = {
  id: 7,
  academy_id: 'acad-1',
  file_id: 'book-1',
  grade: '1-1#body',
  storage_driver: 'supabase',
  storage_bucket: 'textbooks',
  storage_key: 'academies/acad-1/files/book-1/1-1/body.pdf',
  migration_status: 'migrated',
  content_hash: 'sha256:ABCDEF0123456789ffff',
};
const PNG = (w, h, extra = 0) => {
  const b = Buffer.alloc(33 + extra);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(b, 0);
  b.write('IHDR', 12, 'latin1');
  b.writeUInt32BE(w, 16);
  b.writeUInt32BE(h, 20);
  return b;
};

function harness({ job = JOB, link = LINK, ensure, render, upload } = {}) {
  const calls = { finish: [], uploads: [], ensure: 0, renders: [], logs: [] };
  const store = {
    async beat() {},
    async claimNext() {
      const j = job;
      job = null;
      return j;
    },
    async heartbeat() {},
    async getLink(id) {
      assert.equal(id, JOB.link_id);
      return link;
    },
    async upload(key, bytes) {
      calls.uploads.push({ key, bytes: bytes.length });
      return upload ? upload(key) : { ok: true };
    },
    async finish(j, name, patch) {
      calls.finish.push({ id: j.id, name, ...patch });
      return true;
    },
  };
  const worker = createConceptPageWorker({
    store,
    workerName: 'pb-api@test',
    contentKeyOf,
    ensureOriginal: async (row) => {
      calls.ensure += 1;
      if (ensure) return ensure(row);
      return 'C:/cache/7_sha256ABCDEF0123.pdf';
    },
    renderPage: async (args) => {
      calls.renders.push(args);
      if (render) return render(args);
      return { bytes: PNG(1131, 1600), width: 1131, height: 1600 };
    },
    log: { info: (m) => calls.logs.push(m), warn: (m) => calls.logs.push(m) },
    setRepeat: () => 0,
    clearRepeat: () => {},
  });
  return { worker, calls };
}

test('PDF 쪽 번호 그대로 렌더해 올리고, 그 원본 연결·해시 경로로 ready 를 적는다', async () => {
  const { worker, calls } = harness();
  assert.equal(await worker.tick(), 'ready');
  assert.equal(calls.ensure, 1);
  assert.deepEqual(calls.renders, [{ srcPath: 'C:/cache/7_sha256ABCDEF0123.pdf', page: 12 }]);
  assert.deepEqual(calls.uploads.map((u) => u.key), ['academies/acad-1/books/book-1/links/7/sha256ABCDEF0123_p12.png']);
  assert.equal(conceptPageImageKey(JOB), calls.uploads[0].key);
  const done = calls.finish[0];
  assert.deepEqual(
    [done.status, done.image_key, done.width, done.height, done.name],
    ['ready', calls.uploads[0].key, 1131, 1600, 'pb-api@test'],
  );
  assert.equal(await worker.tick(), 'idle');
});

test('연결이 다른 책·학년이거나 옛 연결이거나 파일이 바뀌었으면 원본을 받지 않고 실패 코드만 적는다', async () => {
  const cases = [
    [null, 'link_missing'],
    [{ ...LINK, grade: '1-2#body' }, 'link_mismatch'],
    [{ ...LINK, grade: '1-1#sol' }, 'link_mismatch'],
    [{ ...LINK, academy_id: 'acad-2' }, 'link_mismatch'],
    [{ ...LINK, migration_status: 'legacy' }, 'link_legacy'],
    [{ ...LINK, storage_key: null }, 'link_legacy'],
    [{ ...LINK, content_hash: 'sha256:9999' }, 'source_changed'],
  ];
  for (const [link, code] of cases) {
    const { worker, calls } = harness({ link });
    assert.equal(await worker.tick(), 'failed', code);
    assert.equal(calls.ensure, 0, code);
    assert.deepEqual(calls.uploads, [], code);
    assert.deepEqual([calls.finish[0].status, calls.finish[0].error, calls.finish[0].image_key], ['failed', code, null]);
  }
});

test('원본 받기·렌더·올리기 실패는 각각의 코드로 남기고, 서명 URL·오류 원문은 로그에 남기지 않는다', async () => {
  const leaky = 'src_signed_url_failed: https://x.supabase.co/storage/v1/object/sign/textbooks/a.pdf?token=SECRET';
  const download = harness({ ensure: async () => { throw new Error(leaky); } });
  assert.equal(await download.worker.tick(), 'failed');
  assert.equal(download.calls.finish[0].error, 'source_download_failed');
  assert.deepEqual(download.calls.renders, []);
  assert.ok(download.calls.logs.every((m) => !/token|https?:|SECRET|sign/i.test(m)), download.calls.logs.join('\n'));

  const out = harness({ render: async () => { throw new ConceptPageError('page_out_of_range'); } });
  assert.equal(await out.worker.tick(), 'failed');
  assert.equal(out.calls.finish[0].error, 'page_out_of_range');
  assert.deepEqual(out.calls.uploads, []);

  const boom = harness({ render: async () => { throw new Error(leaky); } });
  assert.equal(await boom.worker.tick(), 'failed');
  assert.equal(boom.calls.finish[0].error, 'render_failed');
  assert.ok(boom.calls.logs.every((m) => !/token|SECRET/.test(m)));

  const up = harness({ upload: () => ({ ok: false }) });
  assert.equal(await up.worker.tick(), 'failed');
  assert.equal(up.calls.finish[0].error, 'upload_failed');
});

test('이미지가 너무 크면 한 번 작게 다시 만들고, 그래도 크면 image_too_large', async () => {
  const big = { bytes: PNG(1600, 1600, CONCEPT_PAGE_MAX_BYTES), width: 1600, height: 1600 };
  const small = { bytes: PNG(1100, 1100), width: 1100, height: 1100 };
  const shrink = harness({ render: async ({ longEdge }) => (longEdge ? small : big) });
  assert.equal(await shrink.worker.tick(), 'ready');
  assert.deepEqual(shrink.calls.renders.map((r) => r.longEdge), [undefined, 1100]);
  assert.equal(shrink.calls.finish[0].width, 1100);

  const huge = harness({ render: async () => big });
  assert.equal(await huge.worker.tick(), 'failed');
  assert.equal(huge.calls.finish[0].error, 'image_too_large');
});

test('대기열 표가 아직 없으면(운영 DB 미반영) 오류 코드만 한 번 남기고 계속 버틴다', async () => {
  const logs = [];
  const worker = createConceptPageWorker({
    store: {
      async beat() { throw new ConceptPageError('beat_failed:PGRST205'); },
      async claimNext() { throw new ConceptPageError('poll_failed:PGRST205'); },
    },
    workerName: 'pb-api@test',
    contentKeyOf,
    ensureOriginal: async () => assert.fail('호출되면 안 됨'),
    renderPage: async () => assert.fail('호출되면 안 됨'),
    log: { info: (m) => logs.push(m), warn: (m) => logs.push(m) },
  });
  assert.equal(await worker.tick(), 'error');
  assert.equal(await worker.tick(), 'error');
  await worker.beat();
  await worker.beat();
  assert.deepEqual(logs, ['[concept-page] poll_failed:PGRST205', '[concept-page] beat_failed:PGRST205']);
});

test('pngSize 는 PNG 머리만 받아들인다', () => {
  assert.deepEqual(pngSize(PNG(10, 20)), { width: 10, height: 20 });
  assert.equal(pngSize(Buffer.from('%PDF-1.7 not a png at all.......')), null);
  assert.equal(pngSize(null), null);
});

test('실제 poppler: 쪽마다 크기가 다른 PDF에서 요청한 PDF 쪽만 그린다', { skip: popplerMissing }, async () => {
  const dir = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'ygg-cpage-test-'));
  try {
    const doc = await PDFDocument.create();
    doc.addPage([400, 200]);
    doc.addPage([200, 600]);
    doc.addPage([300, 300]);
    const src = path.join(dir, 'book.pdf');
    await fs.promises.writeFile(src, await doc.save());

    const p2 = await renderPdfPagePng({ execFile, srcPath: src, page: 2, tmpRoot: dir });
    assert.equal(p2.pages, 3);
    assert.equal(p2.height, 1600, '세로로 긴 2쪽은 높이가 긴 변');
    assert.ok(Math.abs(p2.width - 533) <= 2, `2쪽 너비 ${p2.width}`);
    assert.deepEqual(pngSize(p2.bytes), { width: p2.width, height: p2.height });

    const p1 = await renderPdfPagePng({ execFile, srcPath: src, page: 1, tmpRoot: dir });
    assert.deepEqual([p1.width, p1.height], [1600, 800], '가로로 긴 1쪽');
    const p3 = await renderPdfPagePng({ execFile, srcPath: src, page: 3, longEdge: 1100, tmpRoot: dir });
    assert.deepEqual([p3.width, p3.height], [1100, 1100]);

    for (const page of [0, 4]) {
      await assert.rejects(
        renderPdfPagePng({ execFile, srcPath: src, page, tmpRoot: dir }),
        (e) => e.code === 'page_out_of_range',
      );
    }
    await assert.rejects(
      renderPdfPagePng({ execFile, srcPath: path.join(dir, 'missing.pdf'), page: 1, tmpRoot: dir }),
      (e) => e.code === 'render_failed',
    );
    const left = (await fs.promises.readdir(dir)).filter((n) => n.startsWith('ygg-cpage-'));
    assert.deepEqual(left, [], '임시 폴더를 남기지 않는다');
  } finally {
    await fs.promises.rm(dir, { recursive: true, force: true });
  }
});
