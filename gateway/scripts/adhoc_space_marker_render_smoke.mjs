#!/usr/bin/env node
// XeLaTeX 실제 빌드 스모크: [공백:N] → \hspace*{Nem} 후 xelatex 컴파일 성공 여부.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { buildTexSource } from '../src/problem_bank/render_engine/xelatex/template.js';

function compile(name, stem, choices = []) {
  const question = {
    id: `qa-${name}`,
    question_number: 1,
    stem,
    choices,
    equations: [],
    meta: {},
  };
  const src = buildTexSource(question, {});
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), `space-marker-${name}-`));
  const texPath = path.join(dir, 'q.tex');
  fs.writeFileSync(texPath, src, 'utf8');

  const proc = spawnSync(
    'xelatex',
    ['-interaction=nonstopmode', '-halt-on-error', 'q.tex'],
    { cwd: dir, encoding: 'utf8' },
  );

  const ok = proc.status === 0;
  const log = proc.stdout + '\n' + (proc.stderr || '');
  return { ok, dir, log, src };
}

let pass = 0;
let fail = 0;

function run(name, stem) {
  const { ok, dir, log, src } = compile(name, stem);
  const hasHspace = /\\hspace\*\{[^}]+em\}/.test(src);
  const containsMarker = /\[공백:/.test(src);

  if (ok && hasHspace && !containsMarker) {
    console.log(`  ok   ${name}  (xelatex 성공, \\hspace* 확인)`);
    pass += 1;
  } else {
    console.error(`  FAIL ${name}`);
    console.error(`    ok=${ok} hasHspace=${hasHspace} containsMarker=${containsMarker}`);
    console.error(`    dir=${dir}`);
    if (!ok) {
      const errIdx = log.lastIndexOf('! ');
      const snippet = errIdx >= 0 ? log.slice(errIdx, errIdx + 400) : log.slice(-400);
      console.error(`    log tail: ${snippet}`);
    }
    fail += 1;
  }
}

console.log('[xelatex 실제 컴파일]');
run('simple', '가 [공백:3]나');
run('inline', '답은[공백:2]입니다');
run('multi', 'A[공백:1]B[공백:2]C[공백:3]D');
run('decimal', 'X[공백:1.5]Y');
run('clamp', 'Z[공백:50]W');  // 20em clamp

console.log(`\n결과: ${pass} pass, ${fail} fail`);
if (fail > 0) process.exit(1);
