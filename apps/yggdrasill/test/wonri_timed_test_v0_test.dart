import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/utils/wonri_timed_test_v0.dart';

void main() {
  group('개념원리 시간제한 테스트 V0 유형 정규화', () {
    test('실제 교재 명칭과 공백 변형을 네 유형으로 묶는다', () {
      expect(normalizeWonriTimedTestCategory('필수유형'), 'essential');
      expect(normalizeWonriTimedTestCategory('대표 유형'), 'essential');
      expect(normalizeWonriTimedTestCategory('확인 체크'), 'check');
      expect(normalizeWonriTimedTestCategory('확인체크'), 'check');
      expect(normalizeWonriTimedTestCategory('연습문제'), 'practice');
      expect(normalizeWonriTimedTestCategory('개념원리 익히기'), 'concept');
      expect(normalizeWonriTimedTestCategory('개념익히기'), 'concept');
      expect(normalizeWonriTimedTestCategory('기타 유형'), isNull);
    });
  });

  group('개념원리 시간제한 테스트 V0 자동채점 필터', () {
    test('DB _student_grading_mode의 self 규칙을 따른다', () {
      expect(
        isWonriTimedTestAutoGradable({
          'answer_kind': 'objective',
          'answer_text': '',
        }),
        isTrue,
      );
      expect(
        isWonriTimedTestAutoGradable({
          'answer_kind': 'subjective',
          'answer_text': '12',
        }),
        isTrue,
      );
      for (final answer in [
        '(1) 2 (2) 3',
        '(가) 1, (나) 2',
        r'\begin{cases}x=1\end{cases}',
        '풀이 12쪽',
        'x절편: 2, y절편: 4',
      ]) {
        expect(
          isWonriTimedTestAutoGradable({
            'answer_kind': 'subjective',
            'answer_text': answer,
          }),
          isFalse,
          reason: answer,
        );
      }
      expect(
        isWonriTimedTestAutoGradable({'answer_kind': 'image'}),
        isFalse,
      );
      expect(isWonriTimedTestAutoGradable(const {}), isFalse);
    });

    test('명시된 grading_mode를 우선한다', () {
      expect(
        isWonriTimedTestAutoGradable({
          'answer_kind': 'subjective',
          'answer_text': '12',
          'grading_mode': 'self',
        }),
        isFalse,
      );
    });
  });

  group('개념원리 시간제한 테스트 V0 가중 순서', () {
    final candidates = [
      for (var i = 0; i < 8; i++) ('e$i', '필수유형'),
      for (var i = 0; i < 6; i++) ('c$i', '확인 체크'),
      for (var i = 0; i < 4; i++) ('p$i', '연습문제'),
      for (var i = 0; i < 2; i++) ('n$i', '개념원리 익히기'),
      ('z0', '기타'),
    ];

    List<(String, String)> order(String seed) =>
        wonriTimedTestWeightedOrder<(String, String)>(
          candidates: candidates,
          categoryLabelOf: (candidate) => candidate.$2,
          stableIdOf: (candidate) => candidate.$1,
          seedMaterial: seed,
        );

    test('같은 seed는 같은 순서를 만들고 모든 문항을 한 번만 포함한다', () {
      final first = order('student-a|selection-a');
      final second = order('student-a|selection-a');
      expect(first, second);
      expect(first.map((item) => item.$1).toSet().length, candidates.length);
      expect(first.length, candidates.length);
    });

    test('preferred 네 유형을 모두 소진한 뒤 기타를 배치한다', () {
      final result = order('student-b|selection-a');
      expect(result.last.$1, 'z0');
    });

    test('유형 후보가 고갈되어도 남은 유형으로 끝까지 채운다', () {
      final result = wonriTimedTestWeightedOrder<(String, String)>(
        candidates: const [
          ('e0', '필수유형'),
          ('p0', '연습문제'),
          ('p1', '연습문제'),
        ],
        categoryLabelOf: (candidate) => candidate.$2,
        stableIdOf: (candidate) => candidate.$1,
        seedMaterial: 'depleted',
      );
      expect(result.map((item) => item.$1).toSet(), {'e0', 'p0', 'p1'});
    });
  });
}
