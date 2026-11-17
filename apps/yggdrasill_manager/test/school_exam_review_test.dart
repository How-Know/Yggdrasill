import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/services/school_exam_file_info.dart';
import 'package:yggdrasill_manager/services/school_exam_review_service.dart';
import 'package:yggdrasill_manager/services/textbook_problem_review_service.dart';
import 'package:yggdrasill_manager/services/textbook_workflow_service.dart';

void main() {
  group('시험지 파일 이름 읽기', () {
    test('고등: 학교·학년·학기·시험·과정을 읽는다', () {
      final info = SchoolExamFileInfo.parse('2025년 대구 수성구 경북고 고1공통 1학기중간 공통수학1.hwpx');
      expect(info.isComplete, isTrue);
      expect(info.examYear, 2025);
      expect(info.schoolName, '경북고등학교');
      expect(info.gradeKey, 'H1');
      expect(info.courseKey, 'H1-c1');
      expect(info.curriculumCode, 'rev_2022');
      expect(info.essayPart, isFalse);
      expect(info.title, '2025 1학년 1학기 중간 공통수학1');
      expect(info.classificationColumns(), {
        'school_level': 'high',
        'grade_key': 'H1',
        'course_key': 'H1-c1',
        'course_label': '공통수학1',
        'grade_label': '1',
        'exam_year': 2025,
        'semester_label': '1학기',
        'exam_term_label': '중간',
        'school_name': '경북고등학교',
      });
      final naesin = info.sourceClassification()['naesin'] as Map;
      expect(naesin['year'], '2025');
      expect(naesin['school_name'], '경북고등학교');
      expect(info.sourceClassification()['school_past_exam'], isTrue);
    });

    test('서술형 부분 파일은 같은 시험의 다른 시험지로 구분한다', () {
      final info = SchoolExamFileInfo.parse('2025년 대구 수성구 경북고 고1공통 1학기중간 공통수학1 (서술형).pdf');
      expect(info.isComplete, isTrue);
      expect(info.essayPart, isTrue);
      expect(info.title, '2025 1학년 1학기 중간 공통수학1 (서술형)');
    });

    test('중등: 과정은 학년·학기로 정하고 교육과정은 연도·학년으로 정한다', () {
      final first = SchoolExamFileInfo.parse('내신 2023년 대구 수성구 경신중 중1공통 1학기기말 중등수학1상.hwpx');
      expect(first.isComplete, isTrue);
      expect(first.schoolName, '경신중학교');
      expect(first.gradeKey, 'M1');
      expect(first.courseKey, 'M1-1');
      expect(first.curriculumCode, 'rev_2015');
      expect(first.title, '2023 1학년 1학기 기말');

      final third = SchoolExamFileInfo.parse('2023년 대구 수성구 황금중 중3 2학기기말 중등수학3하.hwpx');
      expect(third.isComplete, isTrue);
      expect(third.courseKey, 'M3-2');
      expect(third.title, '2023 3학년 2학기 기말');

      // 2022 개정은 중1·고1이 2025년, 2학년이 2026년부터다.
      expect(SchoolExamFileInfo.parse('2025년 대구 수성구 소선여중 중1 1학기중간.pdf').curriculumCode, 'rev_2022');
      expect(SchoolExamFileInfo.parse('2025년 대구 수성구 소선여중 중2 1학기중간.pdf').curriculumCode, 'rev_2015');
      expect(SchoolExamFileInfo.parse('2025년 대구 수성구 소선여중 중1 1학기중간.pdf').schoolName, '소선여자중학교');
    });

    test('2015 과정 이름(수학Ⅰ·수학Ⅱ)을 읽는다', () {
      final one = SchoolExamFileInfo.parse('2024년 대구 수성구 대륜고 고2 1학기중간 수학Ⅰ.hwpx');
      expect(one.courseKey, 'H-math1');
      expect(one.curriculumCode, 'rev_2015');
      expect(one.title, '2024 2학년 1학기 중간 수학1');
      expect(SchoolExamFileInfo.parse('2024년 대구 수성구 정화여고 고2 2학기기말 수학II.hwpx').courseKey, 'H-math2');
      expect(SchoolExamFileInfo.parse('2024년 대구 수성구 정화여고 고2 2학기기말 수학II.hwpx').schoolName, '정화여자고등학교');
    });

    test('못 읽은 항목은 빠진 항목으로 알려 준다', () {
      final info = SchoolExamFileInfo.parse('스캔본_003.pdf');
      expect(info.isComplete, isFalse);
      expect(info.missing, ['연도', '학교', '학년', '학기', '중간·기말', '과정']);
      // 고등은 과정 이름이 없으면 과정을 고르게 남긴다.
      expect(SchoolExamFileInfo.parse('2025년 대구 수성구 경북고 고1 1학기중간.pdf').missing, ['과정']);
    });

    test('학교를 고치면 학교급을 맞추고, 학교급이 바뀌면 과정을 다시 고르게 한다', () {
      final middle = SchoolExamFileInfo.parse('2025년 대구 수성구 경신중 중1 1학기중간.pdf');
      expect(middle.isComplete, isTrue);
      expect(middle.withSchool('능인중학교').schoolShortName, '능인중');
      expect(middle.withSchool('능인중학교').isComplete, isTrue);
      final high = middle.withSchool('경신고등학교');
      expect(high.schoolLevel, 'high');
      expect(high.courseKey, '');
      expect(high.missing, ['과정']);
      expect(middle.withSchool('경신').missing, ['학교']);
      expect(middle.withExamYear(null).missing, ['연도']);
      expect(middle.withExamYear(2024).curriculumCode, 'rev_2015');
    });
  });

  group('시험지 목록', () {
    Map<String, dynamic> row({String sourceType = 'school_past', String pdf = 'a.pdf', String file = '경북고.hwpx'}) => {
          'id': 'doc-1',
          'academy_id': 'ac-1',
          'status': 'ready',
          'source_filename': file,
          'source_storage_path': 'a.hwpx',
          'source_pdf_storage_path': pdf,
          'source_type_code': sourceType,
          'school_level': 'high',
          'grade_key': 'H1',
          'course_key': 'H1-c1',
          'course_label': '공통수학1',
          'exam_year': '2025',
          'semester_label': '1학기',
          'exam_term_label': '중간',
          'school_name': '경북고등학교',
        };

    TextbookSubunitWorkflow workflow({String status = 'done', String? confirmedAt, bool withOrder = true}) =>
        TextbookSubunitWorkflow.fromJson({
          'id': 'wf-1',
          'academy_id': 'ac-1',
          'book_id': 'doc-1',
          'grade_label': '공통수학1',
          'scope_key': 'A',
          'crop_status': 'confirmed',
          'pipeline_status': status,
          'confirmed_at': confirmedAt,
          if (withOrder)
            'work_order': {
              'academy_id': 'ac-1',
              'book_id': 'doc-1',
              'grade_label': '공통수학1',
              'series_key': TextbookSubunitWorkOrder.schoolExamSeriesKey,
              'scope_key': 'A',
              'review_mode': TextbookReviewUnitScope.answerOnlyMode,
            },
        });

    test('제목과 같은 시험지 키는 업로드 창이 읽은 값과 같다', () {
      final doc = SchoolExamDocument.fromRow(row());
      final info = SchoolExamFileInfo.parse('2025년 대구 수성구 경북고 고1공통 1학기중간 공통수학1.hwpx');
      expect(doc.title, info.title);
      expect(doc.published, isTrue);
      expect(
        doc.examKey,
        schoolExamKey(
          schoolName: info.schoolName,
          examYear: info.examYear,
          gradeKey: info.gradeKey,
          semesterLabel: info.semesterLabel,
          examTermLabel: info.examTermLabel,
          courseKey: info.courseKey,
          essayPart: info.essayPart,
        ),
      );
      final essay = SchoolExamDocument.fromRow(row(file: '경북고 (서술형).hwpx'));
      expect(essay.title, '2025 1학년 1학기 중간 공통수학1 (서술형)');
      expect(essay.examKey, isNot(doc.examKey));
    });

    test('검수 진행 상태', () {
      expect(SchoolExamDocument.fromRow(row()).stage, SchoolExamStage.notStarted);
      expect(SchoolExamDocument.fromRow(row(pdf: '')).stage, SchoolExamStage.noPdf);
      SchoolExamStage stageOf(TextbookSubunitWorkflow wf) => SchoolExamDocument.fromRow(row(), workflow: wf).stage;
      expect(stageOf(workflow(status: 'queued')), SchoolExamStage.running);
      expect(stageOf(workflow(status: 'running')), SchoolExamStage.running);
      expect(stageOf(workflow(status: 'failed')), SchoolExamStage.failed);
      expect(stageOf(workflow(status: 'idle')), SchoolExamStage.stopped);
      expect(stageOf(workflow()), SchoolExamStage.reviewing);
      expect(stageOf(workflow(confirmedAt: '2026-11-16T00:00:00Z')), SchoolExamStage.confirmed);
      // 작업 지시가 없는 행은 아직 시작 전으로 본다.
      expect(stageOf(workflow(withOrder: false)), SchoolExamStage.notStarted);
    });

    test('초안 시험지(분류 코드가 비어 있다)는 공개 전이다', () {
      final draft = SchoolExamDocument.fromRow(row(sourceType: ''));
      expect(draft.published, isFalse);
      expect(draft.hasPdf, isTrue);
    });

    test('작업 지시: 시험지는 정답표를 지키고, 이미 공개된 시험지는 정답만 검수한다', () {
      final order = workflow().workOrder!;
      expect(order.isSchoolExam, isTrue);
      expect(order.reviewScope.protectAnswerKey, isTrue);
      expect(order.reviewScope.reviewMode, TextbookReviewUnitScope.answerOnlyMode);
      final textbook = TextbookSubunitWorkOrder.fromJson({
        'academy_id': 'ac-1',
        'book_id': 'b-1',
        'grade_label': '중1-1',
        'series_key': 'ssen',
        'scope_key': 'A',
      });
      expect(textbook.isSchoolExam, isFalse);
      expect(textbook.reviewScope.protectAnswerKey, isFalse);
      expect(textbook.reviewScope.reviewMode, '');
    });
  });
}
