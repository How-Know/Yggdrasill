import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const FIXTURES_DIR = path.join(__dirname, 'fixtures', 'hwpx');
const SNAPSHOTS_DIR = path.join(__dirname, 'snapshots', 'extract');

const {
  _parseHwpxBuffer: parseHwpxBuffer,
  _buildQuestionRows: buildQuestionRows,
} = await import('../src/problem_bank_extract_worker.js');

function loadFixture(name) {
  return fs.readFileSync(path.join(FIXTURES_DIR, name));
}

function loadSnapshot(name) {
  const raw = fs.readFileSync(path.join(SNAPSHOTS_DIR, name), 'utf8');
  return JSON.parse(raw);
}

function extractQuestions(fixtureBuffer) {
  const parsed = parseHwpxBuffer(fixtureBuffer);
  const result = buildQuestionRows({
    academyId: 'test-academy',
    documentId: 'test-document',
    extractJobId: 'test-job',
    parsed,
    threshold: 0.85,
  });
  return result;
}

const snapshotFiles = fs
  .readdirSync(SNAPSHOTS_DIR)
  .filter((f) => f.endsWith('.json'));

for (const snapshotFile of snapshotFiles) {
  const snapshot = loadSnapshot(snapshotFile);
  const fixtureName = snapshot.fixture;
  const exp = snapshot.expectations;

  test(`regression: ${fixtureName}`, async (t) => {
    const buf = loadFixture(fixtureName);
    const result = extractQuestions(buf);
    const questions = result.questions || [];

    await t.test('total question count', () => {
      assert.equal(
        questions.length,
        exp.totalQuestions,
        `expected ${exp.totalQuestions} questions, got ${questions.length}`,
      );
    });

    await t.test('question numbers sequence', () => {
      const numbers = questions.map((q) => q.question_number);
      assert.deepEqual(numbers, exp.questionNumbers);
    });

    if (exp.questions) {
      for (const [qNum, qExp] of Object.entries(exp.questions)) {
        await t.test(`Q${qNum} assertions`, () => {
          const q = questions.find((x) => x.question_number === qNum);
          assert.ok(q, `question ${qNum} not found in extraction result`);

          if (qExp.choiceCount !== undefined) {
            const actual = Array.isArray(q.choices) ? q.choices.length : 0;
            assert.equal(
              actual,
              qExp.choiceCount,
              `Q${qNum}: expected ${qExp.choiceCount} choices, got ${actual}`,
            );
          }

          if (qExp.choiceLabels) {
            const labels = (q.choices || []).map((c) => c.label);
            assert.deepEqual(
              labels,
              qExp.choiceLabels,
              `Q${qNum}: choice labels mismatch`,
            );
          }

          if (qExp.equationCountMin !== undefined) {
            const count = Array.isArray(q.equations) ? q.equations.length : 0;
            assert.ok(
              count >= qExp.equationCountMin,
              `Q${qNum}: expected >= ${qExp.equationCountMin} equations, got ${count}`,
            );
          }

          if (qExp.hasBoxContent) {
            const stem = q.stem || '';
            assert.ok(
              stem.includes('[박스시작]'),
              `Q${qNum}: expected box content marker in stem`,
            );
          }

          if (qExp.stemContains) {
            assert.ok(
              (q.stem || '').includes(qExp.stemContains),
              `Q${qNum}: stem missing "${qExp.stemContains}"`,
            );
          }

          if (Array.isArray(qExp.stemContainsAll)) {
            for (const token of qExp.stemContainsAll) {
              assert.ok(
                (q.stem || '').includes(token),
                `Q${qNum}: stem missing "${token}"`,
              );
            }
          }

          if (qExp.stemNotContains) {
            assert.ok(
              !(q.stem || '').includes(qExp.stemNotContains),
              `Q${qNum}: stem should not include "${qExp.stemNotContains}"`,
            );
          }

          if (qExp.stemLineAlignsLength !== undefined) {
            const meta = q.meta || {};
            const aligns = meta.stem_line_aligns || meta.stemLineAligns || [];
            assert.equal(
              aligns.length,
              qExp.stemLineAlignsLength,
              `Q${qNum}: expected ${qExp.stemLineAlignsLength} stem_line_aligns, got ${aligns.length}`,
            );
          }
        });
      }
    }
  });
}
