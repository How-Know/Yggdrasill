import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/models/student_flow.dart';

void main() {
  test('legacy flow names migrate to new defaults in memory', () {
    expect(StudentFlow.normalizeName('현행'), '개념');
    expect(StudentFlow.normalizeName('선행'), '유형');
    expect(StudentFlow.normalizeName('문제'), '유형');
    expect(
      StudentFlow.defaultNames,
      const ['개념', '연산', '유형', '사고', '테스트', '서술', '행동'],
    );
  });

  test('default flow priority follows the default flow order', () {
    expect(StudentFlow.defaultPriority('개념'), 0);
    expect(StudentFlow.defaultPriority('연산'), 1);
    expect(StudentFlow.defaultPriority('유형'), 2);
    expect(StudentFlow.defaultPriority('문제'), 2);
    expect(StudentFlow.defaultPriority('사고'), 3);
    expect(StudentFlow.defaultPriority('테스트'), 4);
    expect(StudentFlow.defaultPriority('서술'), 5);
    expect(StudentFlow.defaultPriority('행동'), 6);
    expect(StudentFlow.defaultPriority('사용자 플로우'), 7);
  });

  test('default flows are always enabled when decoded or serialized', () {
    final decoded = StudentFlow.fromJson(const {
      'id': 'flow-1',
      'name': '서술',
      'enabled': false,
      'orderIndex': 4,
    });

    expect(decoded.enabled, isTrue);
    expect(decoded.copyWith(enabled: false).enabled, isTrue);
    expect(decoded.toJson()['enabled'], isTrue);
  });
}
