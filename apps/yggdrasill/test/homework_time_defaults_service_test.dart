import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/services/homework_time_defaults_service.dart';

void main() {
  group('권장시간 과정 분류', () {
    test('중등 과정 라벨을 middle로 분류한다', () {
      expect(
        HomeworkTimeDefaultsService.schoolLevelKeyForGradeLabel('중2-1'),
        'middle',
      );
      expect(
        HomeworkTimeDefaultsService.schoolLevelKeyForGradeLabel('3-2'),
        'middle',
      );
    });

    test('신·구 고등 과정 라벨을 high로 분류한다', () {
      for (final label in [
        '공통수학1',
        '대수',
        '미적분Ⅱ',
        '수학(상)',
        '수학Ⅰ',
      ]) {
        expect(
          HomeworkTimeDefaultsService.schoolLevelKeyForGradeLabel(label),
          'high',
          reason: label,
        );
      }
    });
  });

  group('권장시간 문항 분류', () {
    test('개념+유형은 section 카테고리를 그대로 사용한다', () {
      expect(
        HomeworkTimeDefaultsService.categoryKeyFor(
          seriesKey: 'gaeyu',
          label: '',
          section: 'concept_check',
          isWonri: false,
          subKey: 'A',
        ),
        'concept_check',
      );
    });

    test('쎈과 RPM 일반 문항은 subKey A/B/C를 사용한다', () {
      expect(
        HomeworkTimeDefaultsService.categoryKeyFor(
          seriesKey: 'ssen',
          label: '대표 문제',
          section: 'type_practice',
          isWonri: false,
          subKey: 'B',
        ),
        'B',
      );
      expect(
        HomeworkTimeDefaultsService.categoryKeyFor(
          seriesKey: 'rpm',
          label: '서술형',
          section: 'mastery',
          isWonri: false,
          subKey: 'C',
        ),
        'C',
      );
    });

    test('RPM과 개념원리의 실력 UP만 별도 단가 키를 사용한다', () {
      expect(
        HomeworkTimeDefaultsService.categoryKeyFor(
          seriesKey: 'rpm',
          label: '실력',
          section: 'mastery',
          isWonri: false,
          subKey: 'C',
        ),
        '실력 UP',
      );
      expect(
        HomeworkTimeDefaultsService.categoryKeyFor(
          seriesKey: 'wonri',
          label: '실력',
          section: 'exercise',
          isWonri: true,
          subKey: 'D',
        ),
        '실력 UP',
      );
      expect(
        HomeworkTimeDefaultsService.categoryKeyFor(
          seriesKey: 'wonri',
          label: 'STEP1',
          section: 'exercise',
          isWonri: true,
          subKey: 'D',
        ),
        '연습문제',
      );
    });
  });
}
