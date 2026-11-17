import test from 'node:test';
import assert from 'node:assert/strict';

import { parseBboxHtml } from '../src/problem_bank/school_exam/pdf_tools.js';
import { EXAM_TEXT_EM_1K_FALLBACK, measureTextEm1k } from '../src/problem_bank/school_exam/text_em.js';
import {
  buildItemRegionPrompt,
  detectExamItemRegions,
  normalizeItemRegions,
  questionHint,
} from '../src/problem_bank/school_exam/item_regions.js';
import {
  examAnswerSeed,
  examReviewCourseLabel,
  examTitle,
  prepareExamReview,
  storedSourceItem,
} from '../src/problem_bank/school_exam/review_staging.js';

// ── PDF 글자 크기 ─────────────────────────────────────────────────────────

test('parseBboxHtml reads page size and word boxes', () => {
  const html =
    '<doc><page width="728.000000" height="1031.000000">' +
    '<word xMin="10.0" yMin="20.0" xMax="41.56" yMax="31.0">다음은</word>' +
    '<word xMin="50.0" yMin="20.0" xMax="60.0" yMax="31.0">a&lt;b</word>' +
    '</page><page width="728" height="1031"></page></doc>';
  const pages = parseBboxHtml(html);
  assert.equal(pages.length, 2);
  assert.equal(pages[0].width, 728);
  assert.deepEqual(pages[0].words[0], { text: '다음은', xMin: 10, yMin: 20, xMax: 41.56, yMax: 31 });
  assert.equal(pages[0].words[1].text, 'a<b');
  assert.equal(pages[1].words.length, 0);
});

test('measureTextEm1k takes the median Hangul advance over the page width', () => {
  const words = [];
  // 본문: 10.52pt 글자 60낱말(3음절), 제목: 20pt 글자 2낱말
  for (let i = 0; i < 60; i += 1) words.push({ text: '유리수', xMin: 0, xMax: 31.56, yMin: 0, yMax: 10 });
  for (let i = 0; i < 2; i += 1) words.push({ text: '수학영역', xMin: 0, xMax: 80, yMin: 0, yMax: 20 });
  words.push({ text: 'abc', xMin: 0, xMax: 99, yMin: 0, yMax: 10 });
  const r = measureTextEm1k([{ page: 1, width: 728, height: 1031, words }]);
  assert.equal(r.source, 'text_layer');
  assert.equal(r.em1k, 14.45);
});

test('measureTextEm1k falls back when the PDF has no text layer', () => {
  const r = measureTextEm1k([{ page: 1, width: 728, height: 1031, words: [] }]);
  assert.equal(r.source, 'fallback');
  assert.equal(r.em1k, EXAM_TEXT_EM_1K_FALLBACK);
});

// ── 문항 영역 ─────────────────────────────────────────────────────────────

test('questionHint drops structure markers and math delimiters', () => {
  assert.equal(questionHint('[문단] 다음 중 $x^2$ 의 값은? [그림]'), '다음 중 x^2 의 값은?');
  assert.equal(questionHint('가'.repeat(60)).length, 45);
});

test('buildItemRegionPrompt lists keys in order with hints', () => {
  const prompt = buildItemRegionPrompt([
    { key: '16', hint: '다음 중 옳은 것은?', kind: '객관식' },
    { key: '17', hint: '풀이 과정을 쓰시오.', kind: '서술형' },
  ]);
  assert.match(prompt, /1\) key "16" · 객관식 · 첫머리: 다음 중 옳은 것은\?/);
  assert.match(prompt, /2\) key "17" · 서술형/);
  assert.match(prompt, /서술형 1/);
});

test('normalizeItemRegions keeps requested keys with valid regions only', () => {
  const regions = normalizeItemRegions(
    {
      items: [
        { key: 1, found: true, region: [100, 50, 200, 460] },
        { key: '2', found: false, region: [300, 50, 400, 460] },
        { key: '3', found: true, region: [0, 0, 900, 900] },
        { key: '9', found: true, region: [10, 10, 50, 50] },
        { key: '4', found: true, region: [500, 500, 503, 900] },
      ],
    },
    ['1', '2', '3', '4'],
  );
  assert.deepEqual(Array.from(regions.keys()), ['1']);
  assert.deepEqual(regions.get('1'), [96, 46, 204, 464]);
});

test('detectExamItemRegions retries the page, then looks at the neighbour page', async () => {
  const calls = [];
  const answers = {
    // 1쪽 첫 호출: 1번만 찾는다. 재시도: 2번을 찾는다. 3번은 사실 2쪽에 있다.
    '1:1,2,3': { items: [{ key: '1', found: true, region: [100, 50, 200, 460] }] },
    '1:2,3': { items: [{ key: '2', found: true, region: [300, 50, 400, 460] }] },
    '2:3': { items: [{ key: '3', found: true, region: [100, 50, 250, 460] }] },
  };
  const found = await detectExamItemRegions({
    pdfPath: 'x.pdf',
    dir: '.',
    pageCount: 2,
    questions: [
      { key: '1', page: 1, order: 1, hint: 'a' },
      { key: '2', page: 1, order: 2, hint: 'b' },
      { key: '3', page: 1, order: 3, hint: 'c' },
    ],
    renderPage: async (_pdf, _dir, page) => Buffer.from(`page-${page}`),
    callImageJson: async ({ prompt, page }) => {
      const keys = Array.from(prompt.matchAll(/key "(\d+)"/g)).map((m) => m[1]).join(',');
      calls.push(`${page}:${keys}`);
      return answers[`${page}:${keys}`] || { items: [] };
    },
  });
  assert.deepEqual(calls, ['1:1,2,3', '1:2,3', '2:3']);
  assert.equal(found.get('1').rawPage, 1);
  assert.equal(found.get('2').rawPage, 1);
  assert.deepEqual(found.get('3'), { rawPage: 2, region1k: [96, 46, 254, 464] });
});

// ── 검수 준비 ─────────────────────────────────────────────────────────────

test('examReviewCourseLabel maps course keys to the concept grade label', () => {
  assert.equal(examReviewCourseLabel({ course_key: 'M2-1', course_label: '중등' }), '2-1');
  assert.equal(examReviewCourseLabel({ course_key: 'H1-c1' }), '공통수학1');
  assert.equal(examReviewCourseLabel({ course_key: 'H-math1', course_label: '수학1' }), '대수');
  assert.equal(examReviewCourseLabel({ course_key: 'H-math2' }), '미적분1');
  assert.equal(examReviewCourseLabel({ course_key: 'H-probstats' }), '확률과 통계');
  assert.equal(examReviewCourseLabel({ course_key: '', course_label: '수학Ⅱ' }), '미적분1');
  assert.equal(examReviewCourseLabel({ course_key: '', course_label: '' }), '');
  assert.equal(
    examReviewCourseLabel({ course_key: 'M1-1', meta: { exam_review: { course_label: '1-2' } } }),
    '1-2',
  );
});

test('examTitle names the paper without the school', () => {
  assert.equal(
    examTitle({ exam_year: 2025, grade_key: 'M2', semester_label: '1학기', exam_term_label: '중간', school_level: 'middle' }),
    '2025 2학년 1학기 중간',
  );
  assert.equal(
    examTitle({
      exam_year: '2025',
      grade_key: 'H1',
      semester_label: '1학기',
      exam_term_label: '중간',
      school_level: 'high',
      course_label: '공통수학1',
      source_filename: '2025년 경신고 고1공통 1학기중간 공통수학1 (서술형).hwpx',
    }),
    '2025 1학년 1학기 중간 공통수학1 (서술형)',
  );
});

test('examAnswerSeed uses the choice key only for questions with printed choices', () => {
  const five = [1, 2, 3, 4, 5].map((n) => ({ label: `${n}`, text: `t${n}` }));
  assert.deepEqual(
    examAnswerSeed({ allow_objective: true, objective_answer_key: '③', subjective_answer: 't3', choices: five }),
    { answer_kind: 'objective', answer_text: '③' },
  );
  // 주관식 문항에 AI 가 만든 객관식 보기: 원문 선지가 없으므로 주관식 정답을 쓴다.
  assert.deepEqual(
    examAnswerSeed({ allow_objective: true, objective_answer_key: '②', subjective_answer: '12', choices: [] }),
    { answer_kind: 'subjective', answer_text: '12' },
  );
  assert.equal(examAnswerSeed({ allow_objective: false, objective_answer_key: '', subjective_answer: ' ' }), null);
});

test('storedSourceItem needs a page and a valid region', () => {
  assert.deepEqual(storedSourceItem({ meta: { source_item: { raw_page: 2, region_1k: [10, 20, 300, 400] } } }), {
    rawPage: 2,
    region1k: [10, 20, 300, 400],
  });
  assert.equal(storedSourceItem({ meta: { source_item: { raw_page: 0, region_1k: [10, 20, 300, 400] } } }), null);
  assert.equal(storedSourceItem({ meta: {} }), null);
});

// PostgREST 질의 모양만 흉내 내는 메모리 DB.
// failOn(표 이름, 동작) 이 오류 글자를 돌려주면 그 요청은 DB 에 닿지 못하고 그 오류로 끝난다(네트워크 끊김 흉내).
// { message, applied: true } 를 돌려주면 DB 에는 반영되고 응답만 오류로 온다.
function fakeSupa(tables, { failOn = null } = {}) {
  let seq = 0;
  const table = (name) => {
    if (!tables[name]) tables[name] = [];
    return tables[name];
  };
  class Query {
    constructor(name) {
      this.name = name;
      this.filters = [];
      this.op = 'select';
    }
    select() {
      return this;
    }
    eq(col, value) {
      this.filters.push((r) => String(r[col]) === String(value));
      return this;
    }
    neq(col, value) {
      this.filters.push((r) => String(r[col]) !== String(value));
      return this;
    }
    in(col, values) {
      const set = new Set(values);
      this.filters.push((r) => set.has(r[col]));
      return this;
    }
    order() {
      return this;
    }
    maybeSingle() {
      this.single = true;
      return this;
    }
    insert(rows) {
      this.op = 'insert';
      this.rows = [].concat(rows);
      return this;
    }
    upsert(rows, opts) {
      this.op = 'upsert';
      this.rows = [].concat(rows);
      this.conflict = String(opts?.onConflict || 'id').split(',');
      this.ignoreDuplicates = opts?.ignoreDuplicates === true;
      return this;
    }
    update(values) {
      this.op = 'update';
      this.values = values;
      return this;
    }
    delete() {
      this.op = 'delete';
      return this;
    }
    // 실제 클라이언트처럼 await 할 때마다 요청을 새로 보낸다.
    then(resolve, reject) {
      try {
        const failure = failOn?.(this.name, this.op);
        if (!failure) {
          resolve({ data: this.run(), error: null });
          return;
        }
        // applied: 요청은 DB 에 반영됐는데 응답만 잃은 경우.
        if (failure.applied) this.run();
        resolve({ data: null, error: { message: failure.message || failure } });
      } catch (err) {
        reject(err);
      }
    }
    run() {
      const rows = table(this.name);
      const match = (r) => this.filters.every((f) => f(r));
      if (this.op === 'select') {
        const hit = rows.filter(match);
        return this.single ? hit[0] || null : hit;
      }
      if (this.op === 'insert') {
        for (const r of this.rows) rows.push({ id: r.id || `${this.name}-${(seq += 1)}`, ...r });
        return null;
      }
      if (this.op === 'upsert') {
        for (const r of this.rows) {
          const cur = rows.find((x) => this.conflict.every((c) => String(x[c]) === String(r[c])));
          if (!cur) rows.push({ id: r.id || `${this.name}-${(seq += 1)}`, ...r });
          else if (!this.ignoreDuplicates) Object.assign(cur, r);
        }
        return null;
      }
      if (this.op === 'update') {
        for (const r of rows.filter(match)) Object.assign(r, this.values);
        return null;
      }
      const keep = rows.filter((r) => !match(r));
      rows.length = 0;
      rows.push(...keep);
      return null;
    }
  }
  return { from: (name) => new Query(name) };
}

const ACADEMY = 'a0000000-0000-4000-8000-000000000001';
const DOC = 'd0000000-0000-4000-8000-000000000001';

function examTables() {
  const five = [1, 2, 3, 4, 5].map((n) => ({ label: `${n}`, text: `t${n}` }));
  return {
    pb_documents: [
      {
        id: DOC,
        academy_id: ACADEMY,
        source_type_code: 'school_past',
        source_filename: '2025년 정화중 중2공통 1학기중간.hwpx',
        source_pdf_storage_bucket: 'problem-documents',
        source_pdf_storage_path: 'a/exam.pdf',
        source_pdf_size_bytes: 1234,
        source_pdf_sha256: 'abc',
        school_level: 'middle',
        school_name: '정화중학교',
        grade_key: 'M2',
        course_key: 'M2-1',
        course_label: '중등',
        exam_year: 2025,
        semester_label: '1학기',
        exam_term_label: '중간',
        meta: {},
      },
    ],
    pb_questions: [
      {
        id: 'q1',
        academy_id: ACADEMY,
        document_id: DOC,
        question_uid: 'u1',
        question_number: '1',
        source_page: 1,
        source_order: 1,
        question_type: '객관식',
        stem: '다음 중 옳은 것은?',
        choices: five,
        allow_objective: true,
        objective_answer_key: '③',
        subjective_answer: 't3',
        source_item: { raw_page: 1, region_1k: [80, 50, 190, 460] },
      },
      {
        id: 'q2',
        academy_id: ACADEMY,
        document_id: DOC,
        question_uid: 'u2',
        question_number: '2',
        source_page: 1,
        source_order: 2,
        question_type: '주관식',
        stem: '값을 구하시오.',
        choices: [],
        allow_objective: false,
        objective_answer_key: '',
        subjective_answer: '12',
      },
      {
        id: 'q3',
        academy_id: ACADEMY,
        document_id: DOC,
        question_uid: 'u3',
        question_number: '3',
        source_page: 2,
        source_order: 3,
        question_type: '서술형',
        stem: '풀이 과정을 쓰시오.',
        choices: [],
        allow_objective: false,
        objective_answer_key: '',
        subjective_answer: '',
      },
    ],
  };
}

function prepare(tables, layoutRegions, extra = {}) {
  const asked = [];
  return prepareExamReview({
    supa: fakeSupa(tables),
    academyId: ACADEMY,
    documentId: DOC,
    loadPdf: async () => Buffer.from('pdf'),
    readLayout: async ({ questions }) => {
      asked.push(questions.map((q) => q.number));
      return { regions: new Map(Object.entries(layoutRegions)) };
    },
    ...extra,
  }).then((result) => ({ result, asked }));
}

test('prepareExamReview stages one exam paper as one review scope', async () => {
  const tables = examTables();
  const { result, asked } = await prepare(tables, { 2: { rawPage: 1, region1k: [280, 50, 440, 460] } });

  assert.equal(result.ok, true);
  assert.equal(result.gradeLabel, '2-1');
  assert.equal(result.bookName, '정화중학교 2025 2학년 1학기 중간');
  assert.deepEqual(asked, [['2', '3']]);
  assert.deepEqual(result.pageFallbacks, ['3']);
  assert.deepEqual(result.missingAnswers, ['3']);

  assert.deepEqual(
    tables.resource_files.map((r) => [r.id, r.category, r.is_published]),
    [[DOC, 'school_past', false]],
  );
  assert.equal(tables.resource_file_links.length, 1);
  assert.equal(tables.resource_file_links[0].grade, '2-1#body');
  assert.equal(tables.resource_file_links[0].storage_key, 'a/exam.pdf');
  assert.equal(tables.resource_file_links[0].migration_status, 'migrated');

  const crops = tables.textbook_problem_crops;
  assert.deepEqual(
    crops.map((c) => [c.problem_number, c.raw_page, c.item_region_1k.join(','), c.pb_question_uid, c.sub_key]),
    [
      ['1', 1, '80,50,190,460', 'u1', 'A'],
      ['2', 1, '280,50,440,460', 'u2', 'A'],
      ['3', 2, '0,0,1000,1000', 'u3', 'A'],
    ],
  );
  assert.equal(tables.textbook_crop_question_links.length, 3);
  assert.deepEqual(
    tables.textbook_problem_answers.map((a) => [a.answer_kind, a.answer_text, a.answer_source]),
    [
      ['objective', '③', 'vlm'],
      ['subjective', '12', 'vlm'],
    ],
  );
  assert.deepEqual(
    tables.textbook_problem_solution_refs.map((r) => [r.source_kind, r.raw_page, r.number_region_1k.join(',')]),
    [
      ['none', 0, '0,0,0,0'],
      ['none', 0, '0,0,0,0'],
      ['none', 0, '0,0,0,0'],
    ],
  );
});

test('prepareExamReview is idempotent and keeps reviewed values', async () => {
  const tables = examTables();
  await prepare(tables, { 2: { rawPage: 1, region1k: [280, 50, 440, 460] } });
  const answers = tables.textbook_problem_answers;
  answers[0].answer_text = '④';
  answers[0].answer_source = 'manual';
  tables.pb_questions[1].subjective_answer = '13';

  // 다시 준비: 쪽 전체로 남은 3번만 다시 찾는다. 정답은 건드리지 않는다.
  const second = await prepare(tables, { 3: { rawPage: 2, region1k: [100, 50, 300, 460] } });
  assert.deepEqual(second.asked, [['3']]);
  assert.deepEqual(second.result.pageFallbacks, []);
  assert.equal(tables.textbook_problem_crops.length, 3);
  assert.equal(tables.textbook_problem_crops[2].item_region_1k.join(','), '100,50,300,460');
  assert.equal(tables.resource_file_links.length, 1);
  assert.equal(tables.textbook_crop_question_links.length, 3);
  assert.equal(tables.textbook_problem_solution_refs.length, 3);
  assert.deepEqual(answers.map((a) => a.answer_text), ['④', '12']);

  // 다시 추출한 뒤: 사람이 고친 정답은 그대로, 나머지는 문제은행 정답을 따른다.
  const third = await prepare(tables, {}, { refreshAnswers: true });
  assert.deepEqual(third.asked, []);
  assert.equal(third.result.answersRefreshed, 1);
  assert.deepEqual(answers.map((a) => a.answer_text), ['④', '13']);
});

test('prepareExamReview relinks crops after a re-extraction', async () => {
  const tables = examTables();
  await prepare(tables, {
    2: { rawPage: 1, region1k: [280, 50, 440, 460] },
    3: { rawPage: 2, region1k: [100, 50, 300, 460] },
  });
  // 검수 기록이 쌓인 뒤 다시 올려 추출: 2번 문항이 새로 만들어지고(uid 바뀜) 3번이 없어졌다.
  const [crop1, crop2] = tables.textbook_problem_crops;
  tables.textbook_problem_analyses = [
    { crop_id: crop1.id, math_status: 'clean' },
    { crop_id: crop2.id, math_status: 'clean' },
  ];
  tables.textbook_review_findings = [{ id: 'f1', crop_id: crop2.id }];
  tables.pb_questions[1].id = 'q2b';
  tables.pb_questions[1].question_uid = 'u2b';
  tables.pb_questions[1].subjective_answer = '15';
  tables.pb_questions.pop();
  const { result, asked } = await prepare(tables, {});
  // 새로 만든 문항은 영역을 다시 찾아 보고, 못 찾으면 예전 영역을 쓴다. 정답은 문제은행 값을 다시 옮긴다.
  assert.deepEqual(asked, [['2']]);
  assert.deepEqual(result.pageFallbacks, []);
  assert.equal(result.answersRefreshed, 1);
  assert.deepEqual(tables.textbook_problem_answers.map((a) => a.answer_text), ['③', '15']);
  assert.equal(result.cropsRemoved, 1);
  // 새로 만들어진 문항의 예전 검수 기록만 비운다.
  assert.equal(result.reviewsReset, 1);
  assert.deepEqual(tables.textbook_problem_analyses.map((a) => a.crop_id), [crop1.id]);
  assert.deepEqual(tables.textbook_review_findings, []);
  assert.deepEqual(
    tables.textbook_problem_crops.map((c) => [c.problem_number, c.pb_question_uid, c.item_region_1k.join(',')]),
    [
      ['1', 'u1', '80,50,190,460'],
      ['2', 'u2b', '280,50,440,460'],
    ],
  );
  const link = tables.textbook_crop_question_links.find((l) => l.crop_id === tables.textbook_problem_crops[1].id);
  assert.equal(link.pb_question_id, 'q2b');
});

test('prepareExamReview identityOnly creates the book and PDF link before extraction', async () => {
  const tables = examTables();
  tables.pb_questions.length = 0;
  const { result, asked } = await prepare(tables, {}, { identityOnly: true });
  assert.deepEqual(result, {
    ok: true,
    bookId: DOC,
    bookName: '정화중학교 2025 2학년 1학기 중간',
    gradeLabel: '2-1',
    schoolName: '정화중학교',
    title: '2025 2학년 1학기 중간',
    identityOnly: true,
  });
  assert.deepEqual(asked, []);
  assert.equal(tables.resource_files.length, 1);
  assert.equal(tables.resource_file_links.length, 1);
  assert.equal(tables.textbook_problem_crops, undefined);
  // 문항이 없으면 전체 준비는 거절한다.
  assert.equal((await prepare(tables, {})).result.error, 'no_questions');
});

test('prepareExamReview refuses documents it cannot stage', async () => {
  const notExam = examTables();
  notExam.pb_documents[0].source_type_code = 'market_book';
  assert.equal((await prepare(notExam, {})).result.error, 'not_school_exam');

  const noPdf = examTables();
  noPdf.pb_documents[0].source_pdf_storage_path = '';
  assert.equal((await prepare(noPdf, {})).result.error, 'pdf_source_required');

  const noCourse = examTables();
  noCourse.pb_documents[0].course_key = '';
  noCourse.pb_documents[0].course_label = '';
  assert.equal((await prepare(noCourse, {})).result.error, 'course_unresolved');

  // 교재 메뉴에서 올린 초안(분류 코드 없음)은 meta.exam_review 로 시험지임을 안다.
  const draft = examTables();
  draft.pb_documents[0].source_type_code = '';
  draft.pb_documents[0].meta = { exam_review: { course_label: '2-1' } };
  assert.equal((await prepare(draft, { 2: { rawPage: 1, region1k: [280, 50, 440, 460] } })).result.ok, true);
});

// ── 네트워크가 잠깐 끊겼을 때 ─────────────────────────────────────────────

const DROP = 'TypeError: fetch failed';

/// 표·동작마다 처음 times 번의 요청을 끊는다. applied 면 DB 에는 반영되고 응답만 잃는다.
function dropFirst(times, { applied = false, only = null } = {}) {
  const seen = new Map();
  const failOn = (name, op) => {
    const key = `${name}.${op}`;
    if (only && !only.includes(key)) return null;
    const n = (seen.get(key) || 0) + 1;
    seen.set(key, n);
    return n <= times ? { message: DROP, applied } : null;
  };
  failOn.seen = seen;
  return failOn;
}

function stagedRows(tables) {
  return {
    books: tables.resource_files.map((r) => [r.id, r.category, r.is_published]),
    links: tables.resource_file_links.map((l) => [l.grade, l.storage_key]),
    crops: tables.textbook_problem_crops.map((c) => [c.problem_number, c.raw_page, c.item_region_1k.join(','), c.pb_question_uid]),
    questionLinks: tables.textbook_crop_question_links.map((l) => [l.crop_id, l.pb_question_id]),
    answers: tables.textbook_problem_answers.map((a) => [a.crop_id, a.answer_kind, a.answer_text, a.answer_source]),
    solutionRefs: tables.textbook_problem_solution_refs.map((r) => [r.crop_id, r.source_kind]),
  };
}

test('prepareExamReview repeats requests lost to a network drop', async () => {
  const layout = { 2: { rawPage: 1, region1k: [280, 50, 440, 460] } };
  const clean = examTables();
  await prepare(clean, layout);
  assert.equal(stagedRows(clean).links.length, 1);

  // 표·동작마다 첫 요청이 DB 에 닿지 못한 경우와, 닿았는데 응답만 잃은 경우.
  for (const applied of [false, true]) {
    const tables = examTables();
    const failOn = dropFirst(1, { applied });
    let pdfLoads = 0;
    const { result } = await prepare(tables, layout, {
      supa: fakeSupa(tables, { failOn }),
      loadPdf: async () => {
        pdfLoads += 1;
        if (pdfLoads === 1) throw new Error(`exam_pdf_download_failed:${DROP}`);
        return Buffer.from('pdf');
      },
      retryDelaysMs: [0, 0],
    });
    assert.equal(result.ok, true);
    assert.equal(pdfLoads, 2);
    assert.deepEqual(result.pageFallbacks, ['3']);
    // 끊김 없이 돈 것과 같은 행이 한 번씩만 남는다.
    assert.deepEqual(stagedRows(tables), stagedRows(clean), `applied=${applied}`);
    // 겹침을 막는 키가 없는 연결 행은 같은 요청을 다시 보내지 않고, 다시 읽어 본 뒤에만 넣는다.
    assert.equal(failOn.seen.get('resource_file_links.insert'), applied ? 1 : 2);
  }
});

test('prepareExamReview gives up when the network stays down', async () => {
  const tables = examTables();
  const failOn = dropFirst(Infinity, { only: ['pb_documents.select'] });
  await assert.rejects(
    prepare(tables, {}, { supa: fakeSupa(tables, { failOn }), retryDelaysMs: [0, 0] }),
    /exam_review_document_fetch_failed:TypeError: fetch failed/,
  );
  assert.equal(failOn.seen.get('pb_documents.select'), 3);
  assert.equal(tables.resource_files, undefined);
});

test('prepareExamReview does not repeat requests that failed for another reason', async () => {
  const tables = examTables();
  let asked = 0;
  const failOn = (name) => {
    if (name !== 'pb_questions') return null;
    asked += 1;
    return 'permission denied for table pb_questions';
  };
  await assert.rejects(
    prepare(tables, {}, { supa: fakeSupa(tables, { failOn }), retryDelaysMs: [0, 0] }),
    /exam_review_questions_fetch_failed:permission denied/,
  );
  assert.equal(asked, 1);
});
