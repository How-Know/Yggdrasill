import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/services/textbook_workflow_runner.dart';
import 'package:yggdrasill_manager/services/textbook_workflow_service.dart';

TextbookSubunitWorkflow _workflow(Map<String, dynamic> extra) =>
    TextbookSubunitWorkflow.fromJson(<String, dynamic>{
      'id': 'wf-1',
      'academy_id': 'ac',
      'book_id': 'book',
      'grade_label': '고1',
      'big_order': 0,
      'mid_order': 1,
      'scope_key': 'A',
      ...extra,
    });

void main() {
  group('추출 런이 읽을 번호', () {
    test('빠진 본문이 없으면 건너뛴다', () {
      expect(
        TextbookWorkflowRunner.extractTargetsOf([
          (number: '0001', hasBody: true),
          (number: '0002', hasBody: true),
        ]),
        isNull,
      );
    });

    test('처음 추출이면 전부 읽는다', () {
      expect(
        TextbookWorkflowRunner.extractTargetsOf([
          (number: '0001', hasBody: false),
          (number: '0002', hasBody: false),
        ]),
        isEmpty,
      );
    });

    test('본문이 하나라도 있으면 빠진 번호만 읽는다', () {
      expect(
        TextbookWorkflowRunner.extractTargetsOf([
          (number: '0001', hasBody: true),
          (number: ' 0002 ', hasBody: false),
          (number: '0003', hasBody: true),
          (number: '0004', hasBody: false),
        ]),
        ['0002', '0004'],
      );
    });

    test('본문이 있는데 빠진 크롭에 번호가 없으면 전체 추출로 넘어가지 않는다', () {
      expect(
        TextbookWorkflowRunner.extractTargetsOf([
          (number: '0001', hasBody: true),
          (number: '', hasBody: false),
        ]),
        isNull,
      );
    });
  });

  group('소단원 상태', () {
    test('작업 상태가 없거나 임시저장뿐인데 본문이 있으면 기존 추출이다', () {
      expect(
        TextbookSubunitStage.of(extractedBodies: 12),
        TextbookSubunitStage.legacy,
      );
      expect(
        TextbookSubunitStage.of(
          workflow: _workflow({'crop_status': 'draft'}),
          extractedBodies: 12,
        ),
        TextbookSubunitStage.legacy,
      );
      expect(
        TextbookSubunitStage.of(extractedBodies: 0),
        TextbookSubunitStage.none,
      );
    });

    test('본문이 붙은 문항을 모두 예전에 검수했으면 검수 완료이고, 이어서 마무리 대상이다', () {
      final stage = TextbookSubunitStage.of(extractedBodies: 12, reviewedBodies: 12);
      expect(stage, TextbookSubunitStage.reviewed);
      expect(stage.isLegacy, isTrue);
      expect(
        TextbookSubunitStage.of(extractedBodies: 12, reviewedBodies: 11),
        TextbookSubunitStage.legacy,
      );
      expect(
        TextbookSubunitStage.of(
          workflow: _workflow({'crop_status': 'confirmed'}),
          extractedBodies: 12,
          reviewedBodies: 12,
        ),
        TextbookSubunitStage.inProgress,
      );
    });

    test('크롭을 확정했거나 확정 뒤 다시 열었으면 진행이다', () {
      expect(
        TextbookSubunitStage.of(
          workflow: _workflow({'crop_status': 'confirmed'}),
          extractedBodies: 0,
        ),
        TextbookSubunitStage.inProgress,
      );
      expect(
        TextbookSubunitStage.of(
          workflow: _workflow({
            'crop_status': 'draft',
            'work_order': {'academy_id': 'ac', 'book_id': 'book', 'scope_key': 'A'},
          }),
          extractedBodies: 30,
        ),
        TextbookSubunitStage.inProgress,
      );
    });

    test('3단계에서 확정했으면 확정이다', () {
      expect(
        TextbookSubunitStage.of(
          workflow: _workflow({
            'crop_status': 'confirmed',
            'confirmed_at': '2026-11-09T01:00:00Z',
          }),
          extractedBodies: 30,
        ),
        TextbookSubunitStage.confirmed,
      );
    });
  });

  test('본문 연결 크롭은 소단원 키로, 개념서는 쪽 범위의 W행으로 센다', () {
    final counts = TextbookWorkflowService.countCropsByScope(
      [
        {
          'big_order': 0,
          'mid_order': 0,
          'sub_key': 'a',
          'raw_page': 10,
          'textbook_problem_analyses': {'math_status': 'approved', 'quality_status': 'approved'},
        },
        {
          'big_order': 0,
          'mid_order': 0,
          'sub_key': 'A',
          'raw_page': 11,
          'textbook_problem_analyses': [
            {'math_status': 'approved', 'quality_status': 'issue'},
          ],
        },
        {'big_order': 0, 'mid_order': 0, 'sub_key': 'B', 'raw_page': 12},
        {'big_order': 1, 'mid_order': 0, 'sub_key': 'B', 'raw_page': 40},
        {'big_order': 1, 'mid_order': 0, 'sub_key': 'C', 'raw_page': 44},
        {'big_order': 1, 'mid_order': 0, 'sub_key': 'A', 'raw_page': 99},
      ],
      [
        {'big_order': 0, 'mid_order': 0, 'sub_key': 'A'},
        {'big_order': 0, 'mid_order': 0, 'sub_key': 'B'},
        {
          'big_order': 1,
          'mid_order': 0,
          'sub_key': 'W0',
          'scope_kind': 'wonri_sub_unit',
          'body_start_page': 38,
          'body_end_page': 41,
        },
        {
          'big_order': 1,
          'mid_order': 0,
          'sub_key': 'W1',
          'scope_kind': 'wonri_sub_unit',
          'body_start_page': 42,
          'body_end_page': 45,
        },
      ],
    );
    expect(counts, {
      '0/0/A': (bodies: 2, reviewed: 1),
      '0/0/B': (bodies: 1, reviewed: 0),
      '1/0/W0': (bodies: 1, reviewed: 0),
      '1/0/W1': (bodies: 1, reviewed: 0),
    });
  });
}
