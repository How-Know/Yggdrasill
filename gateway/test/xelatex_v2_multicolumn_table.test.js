import test from 'node:test';
import assert from 'node:assert/strict';

import { buildDocumentTexSource as buildV1Document } from '../src/problem_bank/render_engine/xelatex/template.js';
import { buildDocumentTexSource as buildV2Document } from '../src/problem_bank/render_engine/xelatex_v2/template.js';

const renderers = [
  ['V1 thumbnail renderer', buildV1Document],
  ['V2 PDF renderer', buildV2Document],
];

for (const [rendererName, buildDocumentTexSource] of renderers) {
test(`${rendererName}: mixed raw-tabular row keeps multicolumn at alignment level`, () => {
  const stem = String.raw`줄기와 잎 그림이다.
[문단]
[표시작]
\begin{tabular}{|c|ccccc|}
\multicolumn{6}{c}{\text{신조어 줄임말 사용 횟수}} \\
\hline
\text{줄기} & \multicolumn{5}{c|}{\text{잎}} \\
\hline
0 & 1 & 2 & 5 & & \\
1 & 0 & 0 & 3 & 7 & 8 \\
\hline
\end{tabular}
[표끝]`;

  const tex = buildDocumentTexSource(
    [{
      id: 'q-multicolumn',
      question_uid: 'q-multicolumn',
      question_number: '24',
      stem,
      equations: [],
      objective_choices: [],
      allow_objective: false,
      allow_subjective: true,
      export_mode: 'subjective',
      meta: {},
    }],
    {
      profile: 'naesin',
      paper: 'A4',
      columns: 1,
      maxQuestionsPerPage: 1,
      hidePreviewHeader: true,
      hideQuestionNumber: true,
    },
  );

  assert.doesNotMatch(
    tex,
    /\\settowidth\{\\YggCellNat\}\{\\multicolumn/,
    'multicolumn must not be measured outside tabular',
  );
  assert.match(
    tex,
    /\\parbox[^&]+& \\multicolumn\{5\}\{c\|\}\{\\text\{잎\}\}/,
    'mixed row must emit multicolumn directly after the alignment separator',
  );
});

test(`${rendererName}: cline header rule is not converted into cell content`, () => {
  const stem = String.raw`단계별 합격자 수를 나타낸 표이다.
[표시작]
\begin{tabular}{|c|c|c|}
\hline
\text{단계} & \multicolumn{2}{c|}{\text{합격자(명)}} \\
\cline{2-3}
& \text{남학생} & \text{여학생} \\
\hline
\text{1단계} & 89184 & 89238 \\
\hline
\end{tabular}
[표끝]`;

  const tex = buildDocumentTexSource(
    [{
      id: 'q-cline-header',
      question_uid: 'q-cline-header',
      question_number: '259',
      stem,
      equations: [],
      objective_choices: [],
      allow_objective: false,
      allow_subjective: true,
      export_mode: 'subjective',
      meta: {},
    }],
    {
      profile: 'naesin',
      paper: 'A4',
      columns: 1,
      maxQuestionsPerPage: 1,
      hidePreviewHeader: true,
      hideQuestionNumber: true,
    },
  );

  assert.doesNotMatch(
    tex,
    /\\cline/,
    'cline must be consumed before cell measurement and parbox rendering',
  );
  assert.match(
    tex,
    /\\multicolumn\{2\}\{c\|\}\{\\text\{합격자\(명\)\}\}/,
    'the spanning header must remain at tabular alignment level',
  );
  assert.match(
    tex,
    /남학생[\s\S]*여학생/,
    'the row following cline must retain all header cells',
  );
});
}

test('V2 PDF renderer: autoWrap keeps column widths and grows row height naturally', () => {
  const stem = String.raw`세 그룹의 설명이다.
[표시작]
\begin{tabular}{|c|l|}
\text{그룹 A} & \text{짧은 설명} \\
\text{그룹 C} & \text{같은 순서에 있는 숫자끼리 더한 매우 긴 설명} \\
\end{tabular}
[표끝]`;

  const tex = buildV2Document(
    [{
      id: 'q-auto-wrap',
      question_uid: 'q-auto-wrap',
      question_number: '4',
      stem,
      equations: [],
      objective_choices: [],
      allow_objective: false,
      allow_subjective: true,
      export_mode: 'subjective',
      meta: {
        table_scales: {
          'raw:1': {
            widthMax: true,
            autoWrap: true,
            columnScales: [0.4, 1.6],
          },
        },
      },
    }],
    {
      profile: 'naesin',
      paper: 'A4',
      columns: 1,
      maxQuestionsPerPage: 1,
      hidePreviewHeader: true,
      hideQuestionNumber: true,
    },
  );

  assert.doesNotMatch(
    tex,
    /\\settowidth\{\\YggCellNat\}/,
    'auto-wrap columns must not expand to the natural one-line text width',
  );
  assert.match(
    tex,
    /\\parbox\[c\]\{\\tblcelwdB\}/,
    'auto-wrap cells must use a fixed width and natural height',
  );
  assert.doesNotMatch(
    tex,
    /\\parbox\[c\]\[[0-9.]+em\]\[c\]/,
    'auto-wrap cells must not force a fixed row height',
  );
});
