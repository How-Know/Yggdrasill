// 시험지 PDF 를 다루는 도구(poppler). 쪽 이미지와 글자 상자를 읽는다.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile as execFileCb } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFileCb);

export async function withTempPdf(buffer, fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'school-exam-'));
  const pdfPath = path.join(dir, 'source.pdf');
  fs.writeFileSync(pdfPath, buffer);
  try {
    return await fn(pdfPath, dir);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

export async function renderPagePng(pdfPath, dir, page, dpi = 130) {
  const outBase = path.join(dir, `p${page}_${dpi}`);
  await execFileAsync(
    'pdftoppm',
    ['-png', '-f', String(page), '-l', String(page), '-singlefile', '-r', String(dpi), pdfPath, outBase],
    { timeout: 60_000, windowsHide: true },
  );
  return fs.readFileSync(`${outBase}.png`);
}

function decodeEntities(text) {
  return String(text || '')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/&amp;/g, '&');
}

/// `pdftotext -bbox` 출력 → [{ page, width, height, words: [{ text, xMin, yMin, xMax, yMax }] }]
export function parseBboxHtml(html) {
  const pages = [];
  const pageRe = /<page\s+width="([\d.]+)"\s+height="([\d.]+)"\s*>([\s\S]*?)<\/page>/g;
  const wordRe = /<word\s+xMin="([\d.-]+)"\s+yMin="([\d.-]+)"\s+xMax="([\d.-]+)"\s+yMax="([\d.-]+)"\s*>([\s\S]*?)<\/word>/g;
  let m;
  while ((m = pageRe.exec(String(html || ''))) !== null) {
    const words = [];
    let w;
    while ((w = wordRe.exec(m[3])) !== null) {
      const text = decodeEntities(w[5]).trim();
      if (!text) continue;
      words.push({
        text,
        xMin: Number(w[1]),
        yMin: Number(w[2]),
        xMax: Number(w[3]),
        yMax: Number(w[4]),
      });
    }
    pages.push({ page: pages.length + 1, width: Number(m[1]), height: Number(m[2]), words });
  }
  return pages;
}

/// 글자 층이 없는 PDF(스캔본)는 빈 words 를 돌려준다.
export async function readWordBoxes(pdfPath) {
  try {
    const { stdout } = await execFileAsync('pdftotext', ['-bbox', pdfPath, '-'], {
      timeout: 120_000,
      windowsHide: true,
      maxBuffer: 256 * 1024 * 1024,
    });
    return parseBboxHtml(stdout);
  } catch (_) {
    return [];
  }
}

export async function mapLimit(items, limit, fn) {
  const out = new Array(items.length);
  let next = 0;
  const run = async () => {
    while (next < items.length) {
      const i = next;
      next += 1;
      out[i] = await fn(items[i], i);
    }
  };
  await Promise.all(Array.from({ length: Math.max(1, Math.min(limit, items.length)) }, run));
  return out;
}
