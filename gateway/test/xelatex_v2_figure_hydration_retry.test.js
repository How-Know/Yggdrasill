import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { hydrateFiguresForXeLatex } from '../src/problem_bank/render_engine/xelatex_v2/renderer.js';

const PNG_1X1 = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  'base64',
);

function questionWithFigure() {
  return {
    id: 'question-1',
    meta: {
      figure_assets: [{
        bucket: 'problem-previews',
        path: 'figures/question-1.png',
        figure_index: 1,
        mime_type: 'image/png',
      }],
    },
  };
}

test('figure hydration retries a transient storage failure', async () => {
  const workDir = fs.mkdtempSync(path.join(os.tmpdir(), 'pb-figure-retry-'));
  let attempts = 0;
  const client = {
    storage: {
      from: () => ({
        download: async () => {
          attempts += 1;
          if (attempts < 3) return { data: null, error: new Error('fetch failed') };
          return { data: new Blob([PNG_1X1]), error: null };
        },
      }),
    },
  };
  const question = questionWithFigure();

  try {
    const result = await hydrateFiguresForXeLatex([question], client, workDir);
    assert.equal(attempts, 3);
    assert.equal(result.appliedCount, 1);
    assert.equal(question.figure_local_paths.length, 1);
    assert.equal(fs.existsSync(question.figure_local_paths[0]), true);
  } finally {
    fs.rmSync(workDir, { recursive: true, force: true });
  }
});

test('figure hydration fails instead of silently omitting a stem figure', async () => {
  const workDir = fs.mkdtempSync(path.join(os.tmpdir(), 'pb-figure-fail-'));
  const client = {
    storage: {
      from: () => ({
        download: async () => ({ data: null, error: new Error('fetch failed') }),
      }),
    },
  };

  try {
    await assert.rejects(
      hydrateFiguresForXeLatex([questionWithFigure()], client, workDir),
      /fig hydration failed.*figure download failed after 3 attempts/,
    );
  } finally {
    fs.rmSync(workDir, { recursive: true, force: true });
  }
});
