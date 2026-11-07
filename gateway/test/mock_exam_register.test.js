import { strict as assert } from 'node:assert';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';

import { parseMockFileName, registerMockPdfs } from '../src/mock_exam/register_files.js';

const samplePath = path.join(os.tmpdir(), 'mock-exam-register-sample.pdf');
fs.writeFileSync(samplePath, Buffer.from('%PDF-1.1\n'));

test('정리된 모의고사 파일명을 시험과 선택과목으로 읽는다', () => {
  const problem = parseMockFileName('2024 고3 10월 교육청 (미적분).pdf');
  assert.equal(problem.examYear, 2024);
  assert.equal(problem.grade, 3);
  assert.equal(problem.month, 10);
  assert.equal(problem.org, 'edu');
  assert.equal(problem.elective, 'calculus');
  assert.equal(problem.kind, 'problem');

  const solution = parseMockFileName('2025 고3 3월 교육청 (기하)_해설.pdf');
  assert.equal(solution.kind, 'solution');
  assert.equal(solution.elective, 'geometry');

  const tight = parseMockFileName('2024 고3 4월 교육청 (확통) -해설.pdf');
  assert.equal(tight.kind, 'solution');
  assert.equal(tight.elective, 'probstats');

  const grade1 = parseMockFileName('2024 고1 3월 교육청.pdf');
  assert.equal(grade1.grade, 1);
  assert.equal(grade1.elective, '');
  assert.equal(grade1.kind, 'problem');

  assert.equal(parseMockFileName('2024 고1 3월 교육청 (미적).pdf'), null);
  assert.equal(parseMockFileName('2024 고3 3월 교육청.pdf'), null);
});

function memorySupa({ status = 'draft', existingPaper = false } = {}) {
  const calls = { queued: 0, uploads: 0, paperWrites: 0 };
  const examQuery = () => ({
    select() {
      return {
        async single() {
          return { data: { id: 'exam-1', status }, error: null };
        },
      };
    },
  });
  const paperQuery = () => {
    const chain = {
      eq() {
        return chain;
      },
      async maybeSingle() {
        return { data: existingPaper ? { id: 'paper-1', sha256: 'old' } : null, error: null };
      },
    };
    return chain;
  };
  return {
    calls,
    from(table) {
      if (table === 'mock_exams') {
        return {
          upsert() {
            return examQuery();
          },
          update(patch) {
            return {
              eq() {
                if (patch.status === 'queued') calls.queued += 1;
                return Promise.resolve({ error: null });
              },
            };
          },
        };
      }
      return {
        select() {
          return paperQuery();
        },
        upsert() {
          calls.paperWrites += 1;
          return Promise.resolve({ error: null });
        },
      };
    },
    storage: {
      from() {
        return {
          async upload() {
            calls.uploads += 1;
            return { error: null };
          },
        };
      },
    },
  };
}

const sample = {
  file: samplePath,
  examYear: 2024,
  grade: 1,
  month: 3,
  org: 'edu',
  elective: '',
  kind: 'problem',
};

test('카드 등록은 추출 대기열에 넣지 않는다', async () => {
  const supa = memorySupa();
  const summary = await registerMockPdfs(supa, 'academy-1', [sample], { queue: false, quiet: true });
  assert.equal(supa.calls.queued, 0);
  assert.equal(supa.calls.uploads, 1);
  assert.equal(summary.created, 1);
});

test('추출 요청은 대기열에 넣는다', async () => {
  const supa = memorySupa();
  await registerMockPdfs(supa, 'academy-1', [sample], { queue: true, quiet: true });
  assert.equal(supa.calls.queued, 1);
});

test('이미 추출된 시험의 PDF 는 카드 등록에서 바꾸지 않는다', async () => {
  const supa = memorySupa({ status: 'review', existingPaper: true });
  const summary = await registerMockPdfs(supa, 'academy-1', [sample], { queue: false, quiet: true });
  assert.equal(summary.kept, 1);
  assert.equal(supa.calls.uploads, 0);
  assert.equal(supa.calls.queued, 0);
});
