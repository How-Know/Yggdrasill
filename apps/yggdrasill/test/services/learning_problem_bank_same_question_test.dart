import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/services/learning_problem_bank_service.dart';

void main() {
  const sections = <Map<String, dynamic>>[
    {'exam_id': 'e1', 'section': 'ga', 'pb_document_id': 'doc-ga'},
    {'exam_id': 'e1', 'section': 'na', 'pb_document_id': 'doc-na'},
  ];
  const merged = <Map<String, dynamic>>[
    // 나형 7번 자리 → 가형 5번 문항, 나형 18번 자리 → 가형 13번 문항(나형 배점 4점)
    {'exam_id': 'e1', 'section': 'na', 'problem_number': 7, 'pb_question_id': 'q-ga-5', 'score': null},
    {'exam_id': 'e1', 'section': 'na', 'problem_number': 18, 'pb_question_id': 'q-ga-13', 'score': 4},
    // 가형 26번 자리 → 나형 15번 문항
    {'exam_id': 'e1', 'section': 'ga', 'problem_number': 26, 'pb_question_id': 'q-na-15', 'score': null},
  ];
  Map<String, dynamic> question(String id, String documentId, String number, int score) => {
        'id': id,
        'question_uid': 'uid-$id',
        'document_id': documentId,
        'question_number': number,
        'source_order': int.parse(number),
        'stem': '본문 $id',
        'meta': {'score_point': score, 'mock_exam_item': {'section': documentId.substring(4)}},
      };
  final owners = [
    question('q-ga-5', 'doc-ga', '5', 3),
    question('q-ga-13', 'doc-ga', '13', 3),
    question('q-na-15', 'doc-na', '15', 4),
  ];

  test('문항을 가진 구간이 목록에 없으면 가리키는 자리를 그 시험지 번호로 넣는다', () {
    // 나형 문서만 보는 목록: 나형 15번은 이미 있고, 가형 문항 둘은 없다.
    final rows = pbMockSlotRows(
      sections: sections.where((s) => s['section'] == 'na'),
      mergedItems: merged,
      ownerQuestions: owners,
      listedQuestionIds: {'q-na-15'},
    );
    expect(rows.map((r) => r['question_number']), ['7', '18']);
    expect(rows.every((r) => r['document_id'] == 'doc-na'), isTrue);
    // 문항 id·uid·본문은 그대로다(문항은 하나).
    expect(rows.first['id'], 'q-ga-5');
    expect(rows.first['question_uid'], 'uid-q-ga-5');
    expect(rows.first['stem'], '본문 q-ga-5');
    expect(rows.first['meta']['score_point'], 3);
    expect(rows.first['meta']['mock_slot'], {
      'exam_id': 'e1',
      'section': 'na',
      'number': 7,
      'owner_document_id': 'doc-ga',
    });
    // 자리에 배점이 있으면 그 시험지의 배점을 쓴다.
    expect(rows.last['meta']['score_point'], 4);
    // 원래 문항 행은 바뀌지 않는다.
    expect(owners.first['question_number'], '5');
    expect(owners.first['meta'].containsKey('mock_slot'), isFalse);
  });

  test('문항이 이미 목록에 있으면 한 번만 보인다', () {
    final rows = pbMockSlotRows(
      sections: sections,
      mergedItems: merged,
      ownerQuestions: owners,
      listedQuestionIds: {'q-ga-5', 'q-ga-13', 'q-na-15'},
    );
    expect(rows, isEmpty);
  });

  test('공개되지 않은 문항과 목록에 없는 구간의 자리는 넣지 않는다', () {
    final rows = pbMockSlotRows(
      sections: sections.where((s) => s['section'] == 'na'),
      mergedItems: merged,
      // 가형 13번은 아직 공개 전이라 읽히지 않았다.
      ownerQuestions: [owners[0], owners[2]],
      listedQuestionIds: const <String>{},
    );
    // 가형 문서가 목록에 없으므로 가형 26번 자리도 나오지 않는다.
    expect(rows.map((r) => r['question_number']), ['7']);
  });
}
