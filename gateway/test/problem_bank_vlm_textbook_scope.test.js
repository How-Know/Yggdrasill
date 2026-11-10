import test from 'node:test';
import assert from 'node:assert/strict';

import {
  isRetryableVlmChunkError,
  normalizeIndependentSetPayloadQuestions,
  selectExpectedQuestions,
} from '../src/problem_bank/extract_engines/vlm/runner.js';
import { buildRowUpdate } from '../src/problem_bank/extract_engines/vlm/writeback.js';

test('textbook VLM retries transient fetch failures but not daily quota exhaustion', () => {
  assert.equal(isRetryableVlmChunkError('fetch failed'), true);
  assert.equal(isRetryableVlmChunkError('ECONNRESET: socket hang up'), true);
  assert.equal(
    isRetryableVlmChunkError(
      'vlm_gemini_http_499: { "error": { "code": 499, "message": "The operation was cancelled.", "status": "CANCELLED" } }',
    ),
    true,
  );
  assert.equal(
    isRetryableVlmChunkError(
      'RESOURCE_EXHAUSTED generate_requests_per_model_per_day please retry in 12h',
    ),
    false,
  );
});

test('textbook VLM keeps only crop-scoped questions in crop order', () => {
  const questions = [
    { question_number: '12', stem: '확인 체크 문항' },
    { question_number: '010', stem: '필수유형 문항 10' },
    { question_number: '11', stem: '필수유형 문항 11' },
    { question_number: '99', stem: '연습문제 문항' },
  ];

  assert.deepEqual(
    selectExpectedQuestions(questions, ['10', '11']),
    [
      { question_number: '10', stem: '필수유형 문항 10' },
      { question_number: '11', stem: '필수유형 문항 11' },
    ],
  );
});

test('textbook VLM deduplicates repeated expected question numbers', () => {
  const questions = [
    { question_number: '7', stem: '첫 번째 결과' },
    { question_number: '7', stem: '중복 결과' },
  ];

  assert.deepEqual(selectExpectedQuestions(questions, ['7']), [
    { question_number: '7', stem: '첫 번째 결과' },
  ]);
});

test('non-textbook VLM remains unchanged when no crop scope is provided', () => {
  const questions = [
    { question_number: '1' },
    { question_number: '2' },
  ];

  assert.strictEqual(selectExpectedQuestions(questions, []), questions);
});

test('independent set extraction does not duplicate item stem into common_stem and splits ~어라/~여라 instructions', () => {
  const scope = {
    book_id: 'b1',
    grade_label: '1-2',
    big_order: 0,
    mid_order: 0,
    sub_key: 'A',
  };
  const setHeaderRanges = [{ from: 1, to: 3, headerNumber: '01~03', rawPage: 10 }];
  const q1 = {
    question_number: '01',
    ...buildRowUpdate(null, {
      question_number: '01',
      source_page: 10,
      is_set_question: true,
      set_type: 'independent_set',
      stem: '다음 중 옳은 것은 ○표, 옳지 않은 것은 ×표를 ([공백:3]) 안에 써넣어라.\n[문단]\n도형의 기본 요소는 점, 선, 면이다.',
      sub_questions: [],
    }),
  };
  const q2 = {
    question_number: '02',
    ...buildRowUpdate(null, {
      question_number: '02',
      source_page: 10,
      is_set_question: true,
      set_type: 'independent_set',
      stem: '점이 움직인 자리는 선이 된다.',
      sub_questions: [],
    }),
  };
  const q3 = {
    question_number: '03',
    ...buildRowUpdate(null, {
      question_number: '03',
      source_page: 10,
      is_set_question: true,
      set_type: 'independent_set',
      stem: '면은 무수히 많은 선으로 이루어져 있다.',
      sub_questions: [],
    }),
  };
  const normalized = normalizeIndependentSetPayloadQuestions([q1, q2, q3], scope, setHeaderRanges);
  assert.equal(
    normalized[0].meta.set_model.common_stem,
    '다음 중 옳은 것은 ○표, 옳지 않은 것은 ×표를 ([공백:3]) 안에 써넣어라.',
  );
  assert.equal(normalized[0].stem, '도형의 기본 요소는 점, 선, 면이다.');
  assert.equal(
    normalized[1].meta.set_model.common_stem,
    '다음 중 옳은 것은 ○표, 옳지 않은 것은 ×표를 ([공백:3]) 안에 써넣어라.',
  );
  assert.equal(normalized[1].stem, '점이 움직인 자리는 선이 된다.');
  assert.equal(
    normalized[2].meta.set_model.common_stem,
    '다음 중 옳은 것은 ○표, 옳지 않은 것은 ×표를 ([공백:3]) 안에 써넣어라.',
  );
  assert.equal(normalized[2].stem, '면은 무수히 많은 선으로 이루어져 있다.');
});

test('independent set with shared figure in first item propagates common_figure_assets to siblings', () => {
  const scope = {
    book_id: 'sr_1_2',
    grade_label: '중1-2',
    big_order: 0,
    mid_order: 0,
    sub_key: 'A',
  };
  const setHeaderRanges = [{ from: 7, to: 9, headerNumber: '07~09', rawPage: 12 }];
  const sharedAsset = {
    bucket: 'problem-previews',
    path: 'figures/shared-line.png',
    figure_index: 1,
  };
  const q7 = {
    question_number: '07',
    stem: '그림을 보고, 다음을 구하여라.\n[그림]\n두 점 A, C 사이의 거리',
    meta: {
      is_set_question: true,
      figure_assets: [sharedAsset],
      set_model: {
        version: 1,
        set_type: 'independent_set',
      },
    },
  };
  const q8 = {
    question_number: '08',
    stem: '두 점 B, D 사이의 거리',
    meta: {
      is_set_question: true,
      set_model: {
        version: 1,
        set_type: 'independent_set',
      },
    },
  };
  const q9 = {
    question_number: '09',
    stem: '선분 AD의 중점 M이 나타내는 수',
    meta: {
      is_set_question: true,
      set_model: {
        version: 1,
        set_type: 'independent_set',
      },
    },
  };
  const normalized = normalizeIndependentSetPayloadQuestions([q7, q8, q9], scope, setHeaderRanges);
  for (const row of normalized) {
    assert.equal(row.meta.set_model.common_stem, '그림을 보고, 다음을 구하여라.\n[그림]');
    assert.equal(row.meta.set_model.common_figure_assets.length, 1);
    assert.equal(row.meta.figure_assets.length, 1);
    assert.equal(row.meta.figure_assets[0].path, 'figures/shared-line.png');
  }
  assert.equal(normalized[0].stem, '두 점 A, C 사이의 거리');
  assert.equal(normalized[1].stem, '두 점 B, D 사이의 거리');
  assert.equal(normalized[2].stem, '선분 AD의 중점 M이 나타내는 수');
});

test('independent set where each item has its own figure does not borrow the first item figure', () => {
  const scope = {
    book_id: 'sr_1_2',
    grade_label: '중1-2',
    big_order: 0,
    mid_order: 2,
    sub_key: 'A',
  };
  const setHeaderRanges = [{ from: 5, to: 8, headerNumber: '05~08', rawPage: 41 }];
  const ownAsset = { bucket: 'problem-previews', path: 'figures/05.png', figure_index: 1 };
  const common = '그림에서 $l\\parallel m$일 때, $\\angle x$의 크기를 구하여라.';
  const mk = (number, stem, assets) => ({
    question_number: number,
    stem,
    meta: {
      is_set_question: true,
      ...(assets ? { figure_assets: assets } : {}),
      set_model: { version: 1, set_type: 'independent_set', common_stem: `${common}\n[그림]` },
    },
  });
  const normalized = normalizeIndependentSetPayloadQuestions(
    [
      mk('05', '[그림]\n[문단]\n해 $l\\parallel m$이므로', [ownAsset]),
      mk('06', '[그림]'),
      mk('07', '[그림]'),
      mk('08', '[그림]'),
    ],
    scope,
    setHeaderRanges,
  );
  for (const row of normalized) {
    assert.doesNotMatch(String(row.meta.set_model.common_stem), /\[그림\]/);
    assert.equal((row.meta.set_model.common_figure_assets || []).length, 0);
    assert.match(row.stem, /\[그림\]/);
  }
  assert.equal(normalized[0].meta.figure_assets[0].path, 'figures/05.png');
  for (const row of normalized.slice(1)) {
    assert.equal((row.meta.figure_assets || []).length, 0);
  }
});


