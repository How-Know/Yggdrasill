#!/usr/bin/env node
// Smoke test for display-style cases normalization.

import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  expandCasesEnvironmentToDisplayArray,
  normalizeMathLatex,
} from '../src/problem_bank/render_engine/utils/text.js';
import { buildTexSource } from '../src/problem_bank/render_engine/xelatex/template.js';

const simple = String.raw`\begin{cases} ax+by=7 \\ bx+ay=5 \end{cases}`;
const expanded = expandCasesEnvironmentToDisplayArray(simple);
assert.ok(expanded.includes(String.raw`\left\{\hspace{0.45em}\begin{array}`), expanded);
assert.ok(expanded.includes(String.raw`\displaystyle ax+by=7`), expanded);
assert.ok(expanded.includes(String.raw`\\[0.35em]`), expanded);
assert.ok(!expanded.includes(String.raw`\begin{cases}`), expanded);

const withCondition = String.raw`\begin{cases} 3x-2 & (x<1) \\ x^2-3x+a & (x\ge1) \end{cases}`;
const expandedWithCondition = normalizeMathLatex(withCondition);
assert.ok(expandedWithCondition.includes(String.raw`@{}l@{\quad}l@{}`), expandedWithCondition);
assert.ok(expandedWithCondition.includes(String.raw`\displaystyle 3x-2 & \displaystyle (x<1)`), expandedWithCondition);

const nested = String.raw`\text{소수} \begin{cases} \text{유한소수} \\ \text{무한소수} \begin{cases} \text{순환소수} \\ box{~~} \end{cases} \end{cases}`;
const expandedNested = expandCasesEnvironmentToDisplayArray(nested, { thinBrace: true });
assert.ok(!expandedNested.includes(String.raw`\begin{cases}`), expandedNested);
assert.ok(!expandedNested.includes(String.raw`\end{cases}`), expandedNested);
assert.ok((expandedNested.match(/\\begin\{array\}/g) || []).length >= 2, expandedNested);
assert.ok(expandedNested.includes(String.raw`\text{무한소수} \vcenter`), expandedNested);

const source = buildTexSource({
  id: 'cases-display-smoke',
  question_number: 1,
  stem: simple,
  choices: [],
  equations: [],
  meta: {},
});
assert.ok(source.includes(String.raw`\vcenter{\hbox{\scalebox{0.65}[0.72]`), source);
assert.ok(source.includes(String.raw`\hspace{0.22em}`), source);
assert.ok(source.includes(String.raw`\begin{array}`), source);
assert.ok(!source.includes(String.raw`\begin{cases}`), source);

const nestedSource = buildTexSource({
  id: 'cases-nested-smoke',
  question_number: 1,
  stem: `box{~~} 안의 수에 해당하는 것은?\n[박스시작]\n${nested}\n[박스끝]`,
  choices: [
    { label: '①', text: String.raw`-\sqrt{\frac{4}{25}}` },
    { label: '②', text: String.raw`\sqrt{0.16}` },
  ],
  equations: [],
  meta: {},
});
assert.ok(!nestedSource.includes(String.raw`\begin{cases}`), nestedSource);
assert.ok(!nestedSource.includes(String.raw`\end{cases}`), nestedSource);

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cases-display-'));
fs.writeFileSync(path.join(dir, 'q.tex'), source, 'utf8');
const proc = spawnSync(
  'xelatex',
  ['-interaction=nonstopmode', '-halt-on-error', 'q.tex'],
  { cwd: dir, encoding: 'utf8' },
);
assert.equal(proc.status, 0, proc.stdout + proc.stderr);

fs.writeFileSync(path.join(dir, 'nested.tex'), nestedSource, 'utf8');
const nestedProc = spawnSync(
  'xelatex',
  ['-interaction=nonstopmode', '-halt-on-error', 'nested.tex'],
  { cwd: dir, encoding: 'utf8' },
);
assert.equal(nestedProc.status, 0, nestedProc.stdout + nestedProc.stderr);

console.log('cases display smoke: ok');
