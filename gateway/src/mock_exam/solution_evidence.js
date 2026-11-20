// 해설 PDF 에서 풀이 영역을 정할 때 쓰는 근거를 읽는다(poppler).
//
//   잉크   = 쪽을 낮은 해상도 흑백으로 그려, 영역 안에 글자·그림이 있는지와 그 위아래 끝을 본다.
//            단 폭을 거의 다 채우는 가로선(머리글 줄, 상자·표 테두리)과 점 몇 개뿐인 줄은 잉크로 치지 않는다.
//   글자 줄 = 글자 층의 낱말을 줄로 묶어, 선택과목 구간이 시작하는 머리 줄을 찾는 데 쓴다.
//
// 좌표는 모두 쪽 기준 0..1000, 영역은 [ymin, xmin, ymax, xmax] (solution_layout.js 와 같다).
import fs from 'node:fs';
import path from 'node:path';
import { execFile as execFileCb } from 'node:child_process';
import { promisify } from 'node:util';

import { readWordBoxes, withTempPdf } from '../problem_bank/school_exam/pdf_tools.js';

const execFileAsync = promisify(execFileCb);

const INK_DPI = 50;
const DARK_BELOW = 215;
// 줄 하나에 이보다 어두운 점이 적으면 잉크로 치지 않는다(상자 세로 테두리, 티끌).
const ROW_MIN_DARK = 3;
// 폭의 이만큼 이상이 어두운 줄은 가로선이다.
const RULE_FRACTION = 0.7;
const MIN_INK_ROWS = 3;
// 글자 층이 있다고 볼 낱말 수
const TEXT_LAYER_MIN_WORDS = 20;

/// PGM(P5) 한 장 → { width, height, data }
export function parsePgm(buffer) {
  let pos = 0;
  const token = () => {
    for (;;) {
      while (pos < buffer.length && /\s/.test(String.fromCharCode(buffer[pos]))) pos += 1;
      if (buffer[pos] !== 0x23) break;
      while (pos < buffer.length && buffer[pos] !== 0x0a) pos += 1;
    }
    const start = pos;
    while (pos < buffer.length && !/\s/.test(String.fromCharCode(buffer[pos]))) pos += 1;
    return buffer.toString('latin1', start, pos);
  };
  if (token() !== 'P5') throw new Error('pgm_format_unsupported');
  const width = Number(token());
  const height = Number(token());
  const max = Number(token());
  if (!(width > 0) || !(height > 0) || max !== 255) throw new Error('pgm_header_invalid');
  pos += 1;
  const data = buffer.subarray(pos, pos + width * height);
  if (data.length < width * height) throw new Error('pgm_truncated');
  return { width, height, data };
}

/// 흑백 쪽 그림들과 글자 상자로 근거를 만든다(파일을 읽지 않는다: 테스트는 이 함수에 직접 넣는다).
/// images: [{ width, height, data } | null] (쪽 순서), wordPages: readWordBoxes 결과
export function solutionEvidenceFrom({ images = [], wordPages = [] } = {}) {
  const wordCount = wordPages.reduce((sum, p) => sum + (p?.words?.length || 0), 0);
  const hasText = wordCount >= TEXT_LAYER_MIN_WORDS;

  /// 영역 안의 줄마다: 잉크로 칠 줄인가
  const inkRows = (page, region) => {
    const img = images[page - 1];
    if (!img) return null;
    const x0 = Math.max(0, Math.floor((region[1] / 1000) * img.width));
    const x1 = Math.min(img.width, Math.ceil((region[3] / 1000) * img.width));
    const y0 = Math.max(0, Math.floor((region[0] / 1000) * img.height));
    const y1 = Math.min(img.height, Math.ceil((region[2] / 1000) * img.height));
    const width = x1 - x0;
    if (width <= 0 || y1 <= y0) return { rows: [], y0, height: img.height };
    const rows = [];
    for (let y = y0; y < y1; y += 1) {
      let dark = 0;
      const base = y * img.width;
      for (let x = x0; x < x1; x += 1) if (img.data[base + x] < DARK_BELOW) dark += 1;
      rows.push(dark >= ROW_MIN_DARK && dark < width * RULE_FRACTION);
    }
    return { rows, y0, height: img.height };
  };

  return {
    pageCount: Math.max(images.length, wordPages.length),
    hasText,
    inkBounds(page, region) {
      const scan = inkRows(page, region);
      if (!scan) return null;
      const first = scan.rows.indexOf(true);
      if (first < 0 || scan.rows.filter(Boolean).length < MIN_INK_ROWS) return [];
      const last = scan.rows.lastIndexOf(true);
      return [
        Math.floor(((scan.y0 + first) / scan.height) * 1000),
        Math.ceil(((scan.y0 + last + 1) / scan.height) * 1000),
      ];
    },
    firstInk(page, region) {
      const scan = inkRows(page, region);
      if (!scan) return null;
      const first = scan.rows.indexOf(true);
      return first < 0 ? null : Math.floor(((scan.y0 + first) / scan.height) * 1000);
    },
    lines(page, region) {
      if (!hasText) return null;
      const p = wordPages[page - 1];
      if (!p || !(p.width > 0) || !(p.height > 0)) return [];
      const lines = [];
      const words = [];
      for (const w of p.words || []) {
        const cx = (((w.xMin + w.xMax) / 2) / p.width) * 1000;
        const cy = (((w.yMin + w.yMax) / 2) / p.height) * 1000;
        if (cx < region[1] || cx > region[3] || cy < region[0] || cy > region[2]) continue;
        words.push({ text: w.text, x: cx, cy, yMin: (w.yMin / p.height) * 1000, yMax: (w.yMax / p.height) * 1000 });
      }
      words.sort((a, b) => a.yMin - b.yMin || a.x - b.x);
      for (const w of words) {
        const line = lines.find((l) => w.cy >= l.yMin && w.cy <= l.yMax);
        if (line) {
          line.words.push(w);
          line.yMin = Math.min(line.yMin, w.yMin);
          line.yMax = Math.max(line.yMax, w.yMax);
        } else {
          lines.push({ yMin: w.yMin, yMax: w.yMax, words: [w] });
        }
      }
      return lines
        .sort((a, b) => a.yMin - b.yMin)
        .map((l) => ({
          text: l.words
            .sort((a, b) => a.x - b.x)
            .map((w) => w.text)
            .join(' '),
          yMin: Math.floor(l.yMin),
          yMax: Math.ceil(l.yMax),
        }));
    },
  };
}

async function renderGrayPages(pdfPath, dir) {
  const outBase = path.join(dir, 'ink');
  await execFileAsync('pdftoppm', ['-gray', '-r', String(INK_DPI), pdfPath, outBase], {
    timeout: 180_000,
    windowsHide: true,
  });
  const files = fs
    .readdirSync(dir)
    .map((name) => ({ name, page: Number(/^ink-(\d+)\.pgm$/.exec(name)?.[1]) }))
    .filter((f) => f.page > 0);
  const images = [];
  for (const f of files) images[f.page - 1] = parsePgm(fs.readFileSync(path.join(dir, f.name)));
  for (let i = 0; i < images.length; i += 1) images[i] = images[i] || null;
  return images;
}

/// 해설 PDF 한 부의 근거. 쪽을 그리지 못하면 던진다(좌표만으로 조용히 넘어가지 않는다).
export async function readSolutionEvidence(pdfBuffer) {
  return withTempPdf(pdfBuffer, async (pdfPath, dir) => {
    const [images, wordPages] = await Promise.all([renderGrayPages(pdfPath, dir), readWordBoxes(pdfPath)]);
    if (images.length === 0) throw new Error('solution_pdf_render_empty');
    return solutionEvidenceFrom({ images, wordPages });
  });
}
