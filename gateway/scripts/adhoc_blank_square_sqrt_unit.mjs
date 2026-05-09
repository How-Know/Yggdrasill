#!/usr/bin/env node
// Smoke test for blank boxes, geometric square symbols, and sqrt-fraction padding.

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { buildTexSource } from '../src/problem_bank/render_engine/xelatex/template.js';

const question = {
  id: 'blank-square-sqrt-smoke',
  question_number: 1,
  stem: [
    '빈칸은 (box{  })(10y+z)와 box{~~}이다.',
    '\\square ABFE와 □CDEF의 넓이를 구하시오.',
    '\\sqrt{\\frac{450}{x}} = y',
  ].join('\n'),
  choices: [],
  equations: [],
  meta: {},
};

const source = buildTexSource(question, {});

assert.ok(source.includes('\\mtemptybox{}'), source);
assert.ok(!/\\boxed\{\s*\}/.test(source), source);
assert.ok(source.includes('\\square ABFE'), source);
assert.ok(source.includes('\\square CDEF'), source);
assert.ok(!source.includes('\\mtemptybox{}ABFE'), source);
assert.ok(!source.includes('\\mtemptybox{}CDEF'), source);
assert.ok(source.includes('\\mtsqrtpad{\\dfrac{450}{x}}'), source);

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'blank-square-sqrt-'));
fs.writeFileSync(path.join(dir, 'q.tex'), source, 'utf8');
const proc = spawnSync(
  'xelatex',
  ['-interaction=nonstopmode', '-halt-on-error', 'q.tex'],
  { cwd: dir, encoding: 'utf8' },
);
assert.equal(proc.status, 0, proc.stdout + proc.stderr);

console.log('blank/square/sqrt smoke: ok');
