import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/problem_bank/mock_exam/mock_exam_models.dart';
import 'package:yggdrasill_manager/screens/textbook/mock_exam_review_panel.dart';
import 'package:yggdrasill_manager/services/mock_exam_review_service.dart';
import 'package:yggdrasill_manager/services/textbook_problem_review_service.dart';
import 'package:yggdrasill_manager/services/textbook_workflow_runner.dart';
import 'package:yggdrasill_manager/services/textbook_workflow_service.dart';

MockExamPaper _paper(String kind, [String elective = '']) => MockExamPaper(
      id: '$kind-$elective',
      kind: kind,
      elective: elective,
      storageBucket: 'problem-documents',
      storagePath: 'x.pdf',
      fileName: 'x.pdf',
      pageCount: null,
    );

MockExam _exam({int grade = 3, int year = 2025, int month = 10, String org = 'edu', String status = 'review'}) => MockExam(
      id: 'exam-1',
      grade: grade,
      examYear: year,
      schoolYear: null,
      month: month,
      org: org,
      title: '',
      status: status,
      stage: '',
      progress: const {},
      lastError: '',
      updatedAt: null,
    );

Map<String, dynamic> _identitySection({String section = 'common', String label = '공통', String course = '대수+미적분1'}) => {
      'section': section,
      'label': label,
      'documentId': 'doc-$section',
      'bookId': 'doc-$section',
      'bookName': '2025 고3 10월 교육청 · $label',
      'gradeLabel': course,
      'questionCount': 22,
      'publishedCount': 22,
      'publishOnConfirm': false,
    };

TextbookSubunitWorkflow _workflow({String status = 'done', String? confirmedAt, bool withOrder = true}) =>
    TextbookSubunitWorkflow.fromJson({
      'id': 'wf-1',
      'academy_id': 'ac-1',
      'book_id': 'doc-common',
      'grade_label': '대수+미적분1',
      'scope_key': 'A',
      'crop_status': 'confirmed',
      'pipeline_status': status,
      'pipeline_phase': 'review',
      'pipeline_detail': '준비됨 20/22',
      'confirmed_at': confirmedAt,
      if (withOrder)
        'work_order': MockExamReviewService.mockExamWorkOrder(
          academyId: 'ac-1',
          title: '2025 고3 10월 교육청',
          section: _identitySection(),
        ).toJson(),
    });

void main() {
  group('모의고사 교육과정', () {
    test('고1 은 2025년, 고2 는 2026년 시행분부터 2022 개정이다', () {
      expect(mockExamCurriculumCode(1, 2024), 'rev_2015');
      expect(mockExamCurriculumCode(1, 2025), 'rev_2022');
      expect(mockExamCurriculumCode(1, 2026), 'rev_2022');
      expect(mockExamCurriculumCode(2, 2025), 'rev_2015');
      expect(mockExamCurriculumCode(2, 2026), 'rev_2022');
      expect(mockExamCurriculumCode(3, 2025), 'rev_2015');
      expect(mockExamCurriculumCode(3, 2026), 'rev_2015');
    });
  });

  group('검수할 구간', () {
    test('고3 은 공통과 문제지가 올라온 선택과목, 고1·고2 는 공통 하나다', () {
      expect(
        mockExamReviewSections(grade: 3, papers: [_paper('problem', 'calculus'), _paper('solution', 'calculus')]),
        ['common', 'calculus'],
      );
      expect(
        mockExamReviewSections(
          grade: 3,
          papers: [_paper('problem', 'geometry'), _paper('problem', 'probstats'), _paper('problem', 'calculus')],
        ),
        ['common', 'probstats', 'calculus', 'geometry'],
      );
      expect(mockExamReviewSections(grade: 1, papers: [_paper('problem'), _paper('solution')]), ['common']);
    });

    test('해설만 있는 회차는 구간이 없고, 이미 문서가 있는 구간은 문제지가 없어도 넣는다', () {
      expect(mockExamReviewSections(grade: 3, papers: [_paper('solution', 'calculus')]), isEmpty);
      expect(mockExamReviewSections(grade: 2, papers: const []), isEmpty);
      expect(
        mockExamReviewSections(grade: 3, papers: [_paper('problem', 'probstats')], linkedSections: ['geometry']),
        ['common', 'probstats', 'geometry'],
      );
    });

    test('가형·나형 회차는 공통 없이 문제지가 올라온 유형마다 구간 하나다', () {
      final legacyPapers = [_paper('problem', 'na'), _paper('solution', 'ga'), _paper('problem', 'ga')];
      expect(mockExamReviewSections(grade: 3, papers: legacyPapers), ['ga', 'na']);
      expect(mockExamReviewSections(grade: 3, papers: [_paper('problem', 'na'), _paper('solution', 'ga')]), ['na']);
      expect(mockExamExpectedNumbers(3, 'ga'), hasLength(30));
      expect(mockExamExpectedNumbers(1, 'na'), isEmpty);
    });
  });

  group('확정 때 공개', () {
    test('검수에서 만든 구간만, 아직 공개하지 않았을 때만 대기다', () {
      expect(MockExamReviewService.mockReviewPending(null), isFalse);
      expect(MockExamReviewService.mockReviewPending('x'), isFalse);
      expect(MockExamReviewService.mockReviewPending(const <String, dynamic>{}), isFalse);
      expect(MockExamReviewService.mockReviewPending({'publish_on_confirm': true}), isTrue);
      expect(MockExamReviewService.mockReviewPending({'publish_on_confirm': true, 'published_at': ''}), isTrue);
      expect(
        MockExamReviewService.mockReviewPending({'publish_on_confirm': true, 'published_at': '2026-11-20T00:00:00Z'}),
        isFalse,
      );
      expect(MockExamReviewService.mockReviewPending({'publish_on_confirm': false}), isFalse);
    });
  });

  group('작업 지시', () {
    test('구간 문서가 책이고, 구간 전체가 검수 범위 하나다', () {
      final order = MockExamReviewService.mockExamWorkOrder(
        academyId: 'ac-1',
        title: '2025 고3 10월 교육청',
        section: _identitySection(),
      );
      expect(order.bookId, 'doc-common');
      expect(order.gradeLabel, '대수+미적분1');
      expect(order.bookName, '2025 고3 10월 교육청 · 공통');
      expect(order.label, '2025 고3 10월 교육청 · 공통');
      expect(order.bigName, '2025 고3 10월 교육청');
      expect(order.midName, '공통');
      expect((order.bigOrder, order.midOrder, order.scopeKey), (0, 0, 'A'));
      expect(order.reviewSubKeys, ['A']);
      expect(order.indexedSubKeys, ['A']);
      expect(order.supportsExtraction, isFalse);
      expect(order.workflowKey, 'doc-common|대수+미적분1|0|0|A');
    });

    test('모의고사는 정답을 시중교재처럼 보고(정답표 보호 없음) 전체를 검수한다', () {
      final order = MockExamReviewService.mockExamWorkOrder(
        academyId: 'ac-1',
        title: '2025 고3 10월 교육청',
        section: _identitySection(section: 'calculus', label: '미적분', course: '미적분2'),
      );
      expect(order.isMockExam, isTrue);
      expect(order.isSchoolExam, isFalse);
      expect(order.isDocumentScope, isTrue);
      expect(order.reviewScope.protectAnswerKey, isFalse);
      expect(order.reviewScope.reviewMode, '');
      expect(order.reviewScope.gradeLabel, '미적분2');
    });

    test('모의고사는 배점을 본문과 따로 보관하므로 검수 카드에 배점을 찍는다', () {
      final order = MockExamReviewService.mockExamWorkOrder(
        academyId: 'ac-1',
        title: '2025 고3 10월 교육청',
        section: _identitySection(),
      );
      expect(order.reviewScope.scoreOnCard, isTrue);
      // 범위의 값이 문항으로 내려간다(카드를 찍을 때 문항만 넘어온다).
      expect(TextbookProblemReviewItem.fromJson({'crop_id': 'c1', 'score_on_card': true}).scoreOnCard, isTrue);
      expect(TextbookProblemReviewItem.fromJson({'crop_id': 'c1'}).scoreOnCard, isFalse);
    });

    test('저장했다 읽어도 같은 작업 지시다', () {
      final order = MockExamReviewService.mockExamWorkOrder(
        academyId: 'ac-1',
        title: '2025 고3 10월 교육청',
        section: _identitySection(),
      );
      final back = TextbookSubunitWorkOrder.fromJson(order.toJson());
      expect(back.isMockExam, isTrue);
      expect(back.workflowKey, order.workflowKey);
      expect(back.supportsExtraction, isFalse);
      expect(back.reviewSubKeys, ['A']);
      expect(back.bookName, order.bookName);
    });

    test('책 이름이 비면 회차·구간으로 이름을 만든다', () {
      final order = MockExamReviewService.mockExamWorkOrder(
        academyId: 'ac-1',
        title: '2025 고1 6월 교육청',
        section: {'documentId': 'doc-9', 'label': '공통', 'gradeLabel': '공통수학1+공통수학2'},
      );
      expect(order.bookId, 'doc-9');
      expect(order.label, '2025 고1 6월 교육청 · 공통');
    });
  });

  group('구간 목록', () {
    test('검수 진행 상태', () {
      MockExamReviewStage stageOf(TextbookSubunitWorkflow? wf) =>
          MockExamReviewSection(section: 'common', documentId: 'doc-common', workflow: wf).stage;
      expect(stageOf(null), MockExamReviewStage.notStarted);
      expect(stageOf(_workflow(withOrder: false)), MockExamReviewStage.notStarted);
      expect(stageOf(_workflow(status: 'queued')), MockExamReviewStage.running);
      expect(stageOf(_workflow(status: 'running')), MockExamReviewStage.running);
      expect(stageOf(_workflow(status: 'failed')), MockExamReviewStage.failed);
      expect(stageOf(_workflow(status: 'idle')), MockExamReviewStage.stopped);
      expect(stageOf(_workflow()), MockExamReviewStage.reviewing);
      expect(stageOf(_workflow(confirmedAt: '2026-11-20T00:00:00Z')), MockExamReviewStage.confirmed);
    });

    test('회차 키는 업로드 창이 읽은 값과 같고, 시작 전 구간·확정 수를 센다', () {
      final exam = MockExamReviewExam(
        exam: _exam(),
        sections: [
          MockExamReviewSection(
            section: 'common',
            documentId: 'doc-common',
            workflow: _workflow(confirmedAt: '2026-11-20T00:00:00Z'),
          ),
          const MockExamReviewSection(section: 'calculus', documentId: 'doc-calculus', publishOnConfirm: true),
          const MockExamReviewSection(section: 'geometry'),
        ],
      );
      final file = parseMockExamFileName('2025 고3 10월 교육청 (미적).pdf')!;
      expect(exam.examKey, file.examKey);
      expect(exam.title, '2025 고3 10월 교육청');
      expect(exam.notExtracted, isFalse);
      expect([for (final s in exam.notStartedSections) s.section], ['calculus', 'geometry']);
      expect(exam.confirmedCount, 1);
      expect(exam.workflows.length, 1);
      expect(exam.sections[1].label, '미적분');
      expect(MockExamReviewExam(exam: _exam(status: 'draft'), sections: const []).notExtracted, isTrue);
    });

    test('목록 표시 상태(이 앱에서 돌고 있지 않을 때)', () {
      String labelOf(TextbookSubunitWorkflow? wf) =>
          mockExamSectionStatus(MockExamReviewSection(section: 'common', documentId: 'doc-common', workflow: wf), null)
              .label;
      expect(labelOf(null), '검수 전');
      expect(labelOf(_workflow(status: 'running')), '멈춤');
      expect(labelOf(_workflow(status: 'failed')), '실패');
      expect(labelOf(_workflow(status: 'idle')), '중단됨');
      expect(labelOf(_workflow()), '검수 대기');
      expect(labelOf(_workflow(confirmedAt: '2026-11-20T00:00:00Z')), '확정');
      final waiting = mockExamSectionStatus(
        MockExamReviewSection(section: 'common', documentId: 'doc-common', workflow: _workflow()),
        null,
      );
      expect(waiting.detail, '준비됨 20/22');
    });
  });

  group('실행기: 모의고사 준비', () {
    test('기다리는 이유를 진행 글로 바꾼다', () {
      expect(TextbookWorkflowRunner.mockWaitingLabel('exam_queued'), contains('회차 추출 대기'));
      expect(TextbookWorkflowRunner.mockWaitingLabel('exam_running'), contains('회차 추출 중'));
      expect(TextbookWorkflowRunner.mockWaitingLabel('extract_queued'), contains('본문 추출 대기'));
      expect(TextbookWorkflowRunner.mockWaitingLabel('extracting'), contains('본문 추출 중'));
      expect(TextbookWorkflowRunner.mockWaitingLabel(''), contains('본문 추출 중'));
    });

    test('준비 결과: 목록이든 수든 빠진 항목을 센다', () {
      final res = TextbookWorkflowRunner.mockPrepareSummary({
        'state': 'ready',
        'cropCount': 22,
        'solutionCount': 21,
        'solutionContinued': 6,
        'missingAnswers': [3],
        'solutionMissing': [22],
        'solutionUnchecked': [14, 15],
        'pageFallbacks': const [],
        'unpublished': 22,
      }, waited: true);
      expect(res.extractSkipped, isFalse);
      for (final part in ['22', '21', '6', '정답 없음 1', '해설 위치 없음 1', '해설 이어짐 확인 못 함 2', '확정 전 비공개 22']) {
        expect(res.detail, contains(part));
      }
      expect(res.detail, isNot(contains('문항 영역 못 찾음')));

      final plain = TextbookWorkflowRunner.mockPrepareSummary({'cropCount': 8, 'pageFallbacks': 2}, waited: false);
      expect(plain.extractSkipped, isTrue);
      expect(plain.detail, contains('문항 영역 못 찾음 2'));
      expect(plain.detail, isNot(contains('해설')));
      expect(plain.detail, isNot(contains('비공개')));
    });

    test('게이트웨이 오류 코드를 읽을 수 있는 말로 바꾼다', () {
      String say(String raw) => TextbookWorkflowRunner.describeMockPrepareError(Exception(raw));
      expect(say('gateway_post_failed(409): exam_extract_failed: 해설 PDF 를 읽지 못함'), '회차 추출 실패: 해설 PDF 를 읽지 못함');
      expect(say('gateway_post_failed(409): extract_failed: timeout'), '본문 추출 실패: timeout');
      expect(say('gateway_post_failed(409): extract_failed'), '본문 추출 실패');
      for (final code in [
        'no_questions',
        'no_items',
        'needs_extract',
        'not_mock_section',
        'exam_not_found',
        'document_not_found',
        'course_unresolved',
        'pdf_source_required',
      ]) {
        final text = say('gateway_post_failed(400): $code');
        expect(text, isNot(contains(code)), reason: code);
        expect(text, isNot(contains('gateway_post_failed')), reason: code);
      }
      // 모르는 오류는 원문을 그대로 보인다.
      expect(say('SocketException: connection refused'), 'SocketException: connection refused');
    });

    test('검수 시작 오류도 읽을 수 있는 말로 바꾼다', () {
      for (final code in ['exam_extracting', 'problem_paper_missing', 'exam_not_found', 'course_unresolved']) {
        final text = MockExamReviewService.describeError(Exception('gateway_post_failed(409): $code'));
        expect(text, isNot(contains(code)), reason: code);
      }
    });
  });

  group('저장된 해설 이어짐', () {
    test('계산해 둔 조각만 읽고, 사람이 고친 행과 계산 전 행은 뺀다', () {
      final out = storedSolutionContinuations([
        {
          'crop_id': 'c1',
          'continuation_regions': [
            {'raw_page': 5, 'region_1k': [60, 510, 400, 950]},
            {'raw_page': 6, 'region_1k': [60, 50, 200, 490]},
          ],
          'edited_at': null,
        },
        {'crop_id': 'c2', 'continuation_regions': const [], 'edited_at': null},
        {'crop_id': 'c3', 'continuation_regions': null, 'edited_at': null},
        {
          'crop_id': 'c4',
          'continuation_regions': [
            {'raw_page': 5, 'region_1k': [60, 510, 400, 950]},
          ],
          'edited_at': '2026-11-20T00:00:00Z',
        },
        {
          'crop_id': 'c5',
          'continuation_regions': [
            {'raw_page': 7, 'region_1k': [1, 2, 3]},
            {'region_1k': [1, 2, 3, 4]},
            {'raw_page': 8.0, 'region_1k': [10, 20, 30, 40]},
          ],
        },
        'x',
      ]);
      expect(out.keys, unorderedEquals(['c1', 'c2', 'c5']));
      expect(out['c1'], hasLength(2));
      expect(out['c1']![1], {'raw_page': 6, 'region_1k': [60, 50, 200, 490]});
      // 빈 목록은 "이어지지 않음"으로 계산해 둔 것이다(예전 추정으로 돌아가지 않는다).
      expect(out['c2'], isEmpty);
      expect(out['c5'], [
        {'raw_page': 8, 'region_1k': [10, 20, 30, 40]},
      ]);
    });
  });

  group('정답·해설 카드를 찍지 못한 문항', () {
    test('이유는 머리말을 떼고 조판 오류가 앞에 오게 줄인다', () {
      expect(
        solutionCardErrorText(Exception('Exception: xelatex failed: ! Missing \$ inserted. l.42 x')),
        'xelatex failed: ! Missing \$ inserted. l.42 x',
      );
      expect(solutionCardErrorText('  여러\n줄   오류 '), '여러 줄 오류');
      expect(solutionCardErrorText(''), '알 수 없는 오류');
      expect(solutionCardErrorText('가' * 900).length, 600);
    });

    test('해설 카드를 못 만든 문항은 준비됨이 아니고, 이유가 문항에 남는다', () {
      final failed = TextbookProblemReviewItem.fromJson({
        'crop_id': 'c1',
        'render_checks': {
          'problem_ok': true,
          'solution_ok': false,
          'answer_solution_error': 'xelatex failed: ! Missing \$ inserted.',
          'issue_title': '정답·해설 카드를 만들지 못함',
        },
      });
      expect(failed.solutionCardError, 'xelatex failed: ! Missing \$ inserted.');
      expect(failed.renderBlocksReady, isTrue);
      expect(failed.readyBlockers, contains('V2 렌더 이상'));
      final ok = TextbookProblemReviewItem.fromJson({
        'crop_id': 'c2',
        'render_checks': {'problem_ok': true, 'solution_ok': true},
      });
      expect(ok.solutionCardError, isEmpty);
      expect(ok.renderBlocksReady, isFalse);
    });
  });

  group('이미 옮겨 둔 해설', () {
    Map<String, dynamic> row({String math = 'clean', String? solution = r'$x=1$', Object? found}) => {
          'crop_id': 'c1',
          'math_status': math,
          'solution_transcribed': solution,
          'quality_checks': {
            if (found != null) 'solution_vision': {'found': found},
          },
          'fix_proposal': {'proposed_solution_transcribed': 'x=1', 'proposed_solution_answer': '1'},
        };

    test('정답이 통과하고 해설을 옮겨 둔 문항은 수정 단계가 다시 옮긴 해설을 반영 대기에 올리지 않는다', () {
      final settled = TextbookProblemReviewItem.fromJson(row());
      expect(settled.solutionSettled, isTrue);
      expect(settled.proposedSolutionTranscribed, 'x=1');
      expect(settled.stageableSolutionTranscribed, isNull);
      expect(settled.stageableSolutionAnswer, isNull);
      expect(TextbookProblemReviewItem.fromJson(row(math: 'approved', found: true)).solutionSettled, isTrue);
    });

    test('정답이 안 맞거나 해설을 못 찾았거나 옮긴 해설이 없으면 다시 옮긴 해설을 쓴다', () {
      for (final r in [row(math: 'issue'), row(found: false), row(solution: null), row(solution: '  ')]) {
        final it = TextbookProblemReviewItem.fromJson(r);
        expect(it.solutionSettled, isFalse);
        expect(it.stageableSolutionTranscribed, 'x=1');
        expect(it.stageableSolutionAnswer, '1');
      }
    });

    test('세 정답은 일치했는데 해설 논리 오류만 남은 문항도 옮겨 둔 해설을 그대로 둔다', () {
      final logicOnly = {...row(math: 'issue'), 'answer_matched': true, 'mismatch_reason': '해설 논리 오류: 부호가 틀렸다.'};
      final it = TextbookProblemReviewItem.fromJson(logicOnly);
      expect(it.solutionLogicOnly, isTrue);
      expect(it.solutionSettled, isTrue);
      expect(it.stageableSolutionTranscribed, isNull);
      // 정답이 어긋난 문항은 해설을 다시 읽어 온 값을 쓴다.
      final mismatch = TextbookProblemReviewItem.fromJson({...logicOnly, 'answer_matched': false});
      expect(mismatch.solutionSettled, isFalse);
      final other = TextbookProblemReviewItem.fromJson({...logicOnly, 'mismatch_reason': '해설 정답과 채점 정답이 다르다.'});
      expect(other.solutionSettled, isFalse);
    });
  });

  group('모의고사 월 탭', () {
    MockExamReviewExam exam(int month, int year) => MockExamReviewExam(
          exam: _exam(month: month, year: year),
          sections: const [],
        );

    test('있는 달만 작은 달부터 나오고, 없는 달을 고르면 가장 이른 달로 돌아간다', () {
      final months = mockExamMonths([
        exam(11, 2024),
        exam(3, 2026),
        exam(3, 2024),
        exam(6, 2025),
      ]);
      expect(months, [3, 6, 11]);
      expect(mockExamSelectedMonth(months, 6), 6);
      expect(mockExamSelectedMonth(months, 4), 3);
      expect(mockExamSelectedMonth(const [], 3), isNull);
    });
  });

  group('해설 그림 다시 찾기', () {
    Map<String, dynamic> row({Object? checkedAt = '2026-11-20T09:05:18Z', List<Object> assets = const [], bool flagged = true}) => {
          'crop_id': 'c1',
          'has_solution_ref': true,
          'solution_raw_page': 5,
          'solution_region_1k': [409, 640, 867, 904],
          'solution_transcribed': r'$x=1$',
          'solution_figures_checked_at': checkedAt,
          'solution_figure_assets': assets,
          'render_checks': flagged ? {'solution_ok': false, 'issue_kind': 'figure'} : {'solution_ok': true},
        };

    test('찾아봤지만 못 붙였고 렌더 검수가 해설 그림 누락으로 본 문항만 다시 찾는다', () {
      expect(TextbookProblemReviewItem.fromJson(row()).solutionFigureSearchMissed, isTrue);
      // 아직 찾아보지 않은 문항은 처음 찾기 대상이다.
      final fresh = TextbookProblemReviewItem.fromJson(row(checkedAt: null));
      expect(fresh.solutionFigureSearchMissed, isFalse);
      expect(fresh.needsSolutionFigures, isTrue);
      // 그림이 붙어 있거나 렌더 검수가 그림 누락으로 보지 않으면 다시 찾지 않는다.
      expect(
        TextbookProblemReviewItem.fromJson(row(assets: [
          {'path': 'a.png'},
        ])).solutionFigureSearchMissed,
        isFalse,
      );
      expect(TextbookProblemReviewItem.fromJson(row(flagged: false)).solutionFigureSearchMissed, isFalse);
    });
  });
}
