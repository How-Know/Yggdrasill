import test from 'node:test';
import assert from 'node:assert/strict';

import { buildTexSource } from '../src/problem_bank/render_engine/xelatex_v2/template.js';

function questionWithStem(stem) {
  return {
    id: 'q-aligned-block',
    question_uid: 'q-aligned-block',
    question_number: '30',
    stem,
    equations: [],
    choices: [],
    objective_choices: [],
    allow_objective: false,
    allow_subjective: true,
    export_mode: 'subjective',
    meta: {},
  };
}

function stemOf(lines) {
  return lines.join('\n');
}

test('a multi-line aligned block after a text line stays one formula', () => {
  const tex = buildTexSource(questionWithStem(stemOf([
    '8, 12',
    '',
    '\\begin{aligned}',
    '8 &= 2^3',
    '12 &= 2^2 \\times 3',
    '\\hline',
    '(\\text{최대공약수}) &= 2^2 = \\mtemptybox{}',
    '\\end{aligned}',
    '따라서 구하시오.',
  ])));

  assert.doesNotMatch(tex, /\$\\displaystyle \\begin\{aligned\}\$/);
  assert.doesNotMatch(tex, /\$\\displaystyle \\end\{aligned\}\$/);
  assert.doesNotMatch(tex, /\$\\displaystyle \\hline\$/);

  const numbersAt = tex.indexOf('$\\displaystyle 8$, $\\displaystyle 12$');
  const formulaAt = tex.indexOf('\\begin{array}{rl}');
  const afterAt = tex.indexOf('따라서 구하시오.');
  assert.ok(numbersAt >= 0, 'leading numbers stay outside the formula');
  assert.ok(formulaAt > numbersAt, 'the formula follows the leading numbers');
  assert.ok(afterAt > formulaAt, 'text after the formula stays outside it');

  assert.match(tex, /8 &= 2\^3 \\\\/);
  assert.match(tex, /12 &= 2\^2 \\times 3 \\\\/);
  assert.match(tex, /\\hline/);
  assert.match(tex, /\\end\{array\}/);
});

test('an aligned row that already contains a line break is not doubled', () => {
  const tex = buildTexSource(questionWithStem(stemOf([
    '12, 16',
    '\\begin{aligned}',
    '12 &= \\mtemptybox{} \\times 3 \\\\ \\mtemptybox{} &= 2^4',
    '\\hline',
    '(\\text{최대공약수}) &= 2^2 = \\mtemptybox{}',
    '\\end{aligned}',
  ])));

  assert.match(tex, /\\begin\{array\}\{rl\}/);
  assert.match(tex, /12 &= \\mtemptybox\{\} \\times 3 \\\\ \\mtemptybox\{\} &= 2\^4 \\\\/);
  assert.doesNotMatch(tex, /2\^4 \\\\\\\\/);
  assert.doesNotMatch(tex, /\$\\displaystyle \\begin\{aligned\}\$/);
});

test('a line break before box~~ inside aligned stays an empty box', () => {
  const tex = buildTexSource(questionWithStem(stemOf([
    '12, 16',
    '\\begin{aligned}',
    '12 &= \\mtemptybox{} \\times 3 \\\\\nbox{~~} &= 2^4',
    '\\hline',
    '(\\text{최대공약수}) &= 2^2 = \\mtemptybox{}',
    '\\end{aligned}',
  ])));

  assert.match(tex, /12 &= \\mtemptybox\{\} \\times 3 \\\\ \\mtemptybox\{\} &= 2\^4/);
  assert.doesNotMatch(tex, /\\nbox/);
  assert.doesNotMatch(tex, /\\mathord\{\\sim\}/);
});

test('a pure aligned segment still renders as one formula', () => {
  const tex = buildTexSource(questionWithStem(stemOf([
    '\\begin{aligned}',
    '8 &= 2^3 \\\\',
    '12 &= 2^2 \\\\',
    '\\end{aligned}',
  ])));

  assert.match(tex, /\\begin\{aligned\}/);
  assert.match(tex, /8 &= 2\^3 \\\\/);
  assert.doesNotMatch(tex, /2\^3 \\\\\\\\/);
  assert.doesNotMatch(tex, /\$\\displaystyle \\begin\{aligned\}\$/);
});

test('an unclosed aligned environment does not swallow the following sentence', () => {
  const tex = buildTexSource(questionWithStem(stemOf([
    '\\begin{aligned}',
    '8 &= 2^3',
    '다음 문장이다.',
  ])));

  assert.match(tex, /다음 문장이다/);
  assert.doesNotMatch(tex, /\\begin\{array\}/);
});
