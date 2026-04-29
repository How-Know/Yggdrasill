import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/models/academic_season.dart';
import 'package:mneme_flutter/models/education_level.dart';
import 'package:mneme_flutter/models/homework_learning_track.dart';
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

  test('로드맵 기준 과제 학습분류를 계산한다', () {
    expect(
      SeasonRoadmapService.classifyDefaultLearningTrack(
        referenceDate: DateTime(2025, 4),
        educationLevel: EducationLevel.middle,
        grade: 1,
        courseLabel: '1-1',
      ),
      HomeworkLearningTrack.current,
    );
    expect(
      SeasonRoadmapService.classifyDefaultLearningTrack(
        referenceDate: DateTime(2025, 4),
        educationLevel: EducationLevel.middle,
        grade: 1,
        courseLabel: '1-2',
      ),
      HomeworkLearningTrack.preLearning,
    );
    expect(
      SeasonRoadmapService.classifyDefaultLearningTrack(
        referenceDate: DateTime(2025, 9),
        educationLevel: EducationLevel.middle,
        grade: 1,
        courseLabel: '1-1',
      ),
      HomeworkLearningTrack.foundational,
    );
    expect(
      SeasonRoadmapService.classifyDefaultLearningTrack(
        referenceDate: DateTime(2025, 9),
        educationLevel: EducationLevel.middle,
        grade: 1,
        courseLabel: '올림피아드',
      ),
      HomeworkLearningTrack.extra,
    );
  });

  test('초등학생은 정규 로드맵 과정을 선행으로 분류한다', () {
    expect(
      SeasonRoadmapService.classifyDefaultLearningTrack(
        referenceDate: DateTime(2025, 4),
        educationLevel: EducationLevel.elementary,
        grade: 6,
        courseLabel: '1-1',
      ),
      HomeworkLearningTrack.preLearning,
    );
    expect(
      SeasonRoadmapService.classifyDefaultLearningTrack(
        referenceDate: DateTime(2025, 4),
        educationLevel: EducationLevel.elementary,
        grade: 6,
        courseLabel: '초등심화',
      ),
      HomeworkLearningTrack.extra,
    );
  });

  test('고3과 N수생은 고2 과정은 현행, 그 이전 과정은 기반학습으로 분류한다', () {
    for (final grade in const [3, 4]) {
      expect(
        SeasonRoadmapService.classifyDefaultLearningTrack(
          referenceDate: DateTime(2025, 4),
          educationLevel: EducationLevel.high,
          grade: grade,
          courseLabel: '대수',
        ),
        HomeworkLearningTrack.current,
      );
      expect(
        SeasonRoadmapService.classifyDefaultLearningTrack(
          referenceDate: DateTime(2025, 9),
          educationLevel: EducationLevel.high,
          grade: grade,
          courseLabel: '공통수학2',
        ),
        HomeworkLearningTrack.foundational,
      );
    }
  });

  test('과제번호는 학습분류 prefix 형식만 허용한다', () {
    expect(HomeworkLearningTrack.isValidAssignmentCode('CLAB1234'), isTrue);
    expect(HomeworkLearningTrack.isValidAssignmentCode('PLCD5678'), isTrue);
    expect(HomeworkLearningTrack.isValidAssignmentCode('ABCD1234'), isFalse);
    expect(HomeworkLearningTrack.isValidAssignmentCode('CL1234'), isFalse);
    expect(
      HomeworkLearningTrack.assignmentCodeMatchesTrack('FLZX0001', 'FL'),
      isTrue,
    );
    expect(
      HomeworkLearningTrack.assignmentCodeMatchesTrack('FLZX0001', 'CL'),
      isFalse,
    );
  });

  test('그룹 과제는 같은 학습분류만 허용한다', () {
    expect(
      HomeworkLearningTrack.hasUniformCodes(const ['CL', 'CL', 'CL']),
      isTrue,
    );
    expect(
      HomeworkLearningTrack.hasUniformCodes(const ['CL', 'PL']),
      isFalse,
    );
  });
}
