import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/models/academic_season.dart';
import 'package:mneme_flutter/models/education_level.dart';
import 'package:mneme_flutter/services/season_roadmap_service.dart';

void main() {
  test('시즌 경계일을 계산한다', () {
    expect(
      AcademicSeason.fromDate(DateTime(2025, 1, 1)).code,
      AcademicSeasonCode.winter,
    );
    expect(
      AcademicSeason.fromDate(DateTime(2025, 7, 15)).code,
      AcademicSeasonCode.spring,
    );
    expect(
      AcademicSeason.fromDate(DateTime(2025, 7, 16)).code,
      AcademicSeasonCode.summer,
    );
    expect(
      AcademicSeason.fromDate(DateTime(2025, 8, 15)).code,
      AcademicSeasonCode.summer,
    );
    expect(
      AcademicSeason.fromDate(DateTime(2025, 8, 16)).code,
      AcademicSeasonCode.fall,
    );
  });

  test('기본 로드맵은 기존 과정과 매칭하고 누락 과정은 미연결로 둔다', () {
    final entries = SeasonRoadmapService.buildDefaultEntriesForYear(
      2025,
      const {
        '1-1': 'course-middle-1-1',
        '공통수학1': 'course-common-math-1',
      },
    );

    final middleSpring = entries.singleWhere(
      (entry) =>
          entry.seasonCode == AcademicSeasonCode.spring &&
          entry.educationLevel == EducationLevel.middle &&
          entry.grade == 1,
    );
    expect(middleSpring.gradeKey, 'course-middle-1-1');
    expect(middleSpring.hasLinkedCourse, isTrue);

    final highSpringAlgebra = entries.singleWhere(
      (entry) =>
          entry.seasonCode == AcademicSeasonCode.spring &&
          entry.educationLevel == EducationLevel.high &&
          entry.grade == 2 &&
          entry.courseLabelSnapshot == '대수',
    );
    expect(highSpringAlgebra.gradeKey, isNull);
    expect(highSpringAlgebra.hasLinkedCourse, isFalse);
  });
}
