import '../models/education_level.dart';
import '../models/student.dart';

/// 내신 기출·문제은행 프리셋과 동일한 시험 구간·학기·링크 키 규칙을 한곳에 둡니다.
class NaesinExamContext {
  NaesinExamContext._();

  static const List<String> examTerms = <String>['중간고사', '기말고사'];

  static const List<int> linkYears = <int>[2021, 2022, 2023, 2024, 2025];

  static const List<String> middleSchools = <String>[
    '경신중',
    '능인중',
    '대륜중',
    '동도중',
    '소선여중',
    '오성중',
    '정화중',
    '황금중',
  ];

  static const List<String> highSchools = <String>[
    '경북고',
    '경신고',
    '능인고',
    '대구여고',
    '대륜고',
    '오성고',
    '정화여고',
    '혜화여고',
  ];

  /// [homework_quick_add_proxy_dialog] / [problem_bank_view] 와 동일한 월·일 분기.
  static String defaultNaesinExamTermByDate(DateTime now) {
    final month = now.month;
    final day = now.day;
    if (month <= 4) return '중간고사';
    if (month == 5) return day <= 15 ? '중간고사' : '기말고사';
    if (month <= 7) return '기말고사';
    if (month <= 9) return '중간고사';
    if (month == 10) return day <= 15 ? '중간고사' : '기말고사';
    return '기말고사';
  }

  static int defaultSemesterByDate(DateTime now) => now.month <= 7 ? 1 : 2;

  static List<NaesinGradeOption> gradeOptionsForLevel(EducationLevel level) {
    switch (level) {
      case EducationLevel.high:
        return const <NaesinGradeOption>[
          NaesinGradeOption(key: 'H1', label: '고1', level: EducationLevel.high, grade: 1),
          NaesinGradeOption(key: 'H2', label: '고2', level: EducationLevel.high, grade: 2),
          NaesinGradeOption(key: 'H3', label: '고3', level: EducationLevel.high, grade: 3),
        ];
      case EducationLevel.middle:
      case EducationLevel.elementary:
        return const <NaesinGradeOption>[
          NaesinGradeOption(key: 'M1', label: '중1', level: EducationLevel.middle, grade: 1),
          NaesinGradeOption(key: 'M2', label: '중2', level: EducationLevel.middle, grade: 2),
          NaesinGradeOption(key: 'M3', label: '중3', level: EducationLevel.middle, grade: 3),
        ];
    }
  }

  /// H2는 4과목, H3는 프리셋 연결용 최소 옵션(대수).
  static List<NaesinCourseOption> courseOptionsForGrade(String gradeKey) {
    switch (gradeKey) {
      case 'M1':
        return const <NaesinCourseOption>[
          NaesinCourseOption(key: 'M1-1', label: '1-1'),
          NaesinCourseOption(key: 'M1-2', label: '1-2'),
        ];
      case 'M2':
        return const <NaesinCourseOption>[
          NaesinCourseOption(key: 'M2-1', label: '2-1'),
          NaesinCourseOption(key: 'M2-2', label: '2-2'),
        ];
      case 'M3':
        return const <NaesinCourseOption>[
          NaesinCourseOption(key: 'M3-1', label: '3-1'),
          NaesinCourseOption(key: 'M3-2', label: '3-2'),
        ];
      case 'H1':
        return const <NaesinCourseOption>[
          NaesinCourseOption(key: 'H1-c1', label: '공통수학1'),
          NaesinCourseOption(key: 'H1-c2', label: '공통수학2'),
        ];
      case 'H2':
        return const <NaesinCourseOption>[
          NaesinCourseOption(key: 'H-algebra', label: '대수'),
          NaesinCourseOption(key: 'H-calc1', label: '미적분1'),
          NaesinCourseOption(key: 'H-calc2', label: '미적분2'),
          NaesinCourseOption(key: 'H-probstats', label: '확률과 통계'),
        ];
      case 'H3':
        return const <NaesinCourseOption>[
          NaesinCourseOption(key: 'H-algebra', label: '대수'),
        ];
      default:
        return const <NaesinCourseOption>[
          NaesinCourseOption(key: 'M1-1', label: '1-1'),
          NaesinCourseOption(key: 'M1-2', label: '1-2'),
        ];
    }
  }

  static String courseLabel(String courseKey) {
    for (final g in <String>['M1', 'M2', 'M3', 'H1', 'H2', 'H3']) {
      for (final option in courseOptionsForGrade(g)) {
        if (option.key == courseKey) return option.label;
      }
    }
    return courseKey.trim();
  }

  /// 과제 빠른 추가 [_initNaesinFilterDefaults] 와 동일 규칙.
  static ({String gradeKey, String courseKey}) initialGradeCourseFromStudent(
    Student? student,
    DateTime now,
  ) {
    final level = student?.educationLevel == EducationLevel.high
        ? EducationLevel.high
        : EducationLevel.middle;
    final rawGrade = student?.grade ?? 1;
    final safeGrade = rawGrade.clamp(1, 3);
    final semester = defaultSemesterByDate(now);
    final gradeKey = level == EducationLevel.high ? 'H$safeGrade' : 'M$safeGrade';
    final courseKey = switch (gradeKey) {
      'M1' => semester == 1 ? 'M1-1' : 'M1-2',
      'M2' => semester == 1 ? 'M2-1' : 'M2-2',
      'M3' => semester == 1 ? 'M3-1' : 'M3-2',
      'H1' => semester == 1 ? 'H1-c1' : 'H1-c2',
      _ => 'H-algebra',
    };
    return (gradeKey: gradeKey, courseKey: courseKey);
  }

  static String buildNaesinLinkKey({
    required String gradeKey,
    required String courseKey,
    required String examTerm,
    required String school,
    required int year,
  }) {
    return '$gradeKey|$courseKey|$examTerm|$school|$year';
  }

  static NaesinLinkSelection? parseNaesinLinkKey(String raw) {
    final normalized = raw.trim();
    if (normalized.isEmpty) return null;
    final parts = normalized.split('|');
    if (parts.length != 5) return null;
    final g = parts[0].trim();
    final c = parts[1].trim();
    final t = parts[2].trim();
    final s = parts[3].trim();
    final y = int.tryParse(parts[4].trim());
    if (g.isEmpty || c.isEmpty || t.isEmpty || s.isEmpty || y == null) {
      return null;
    }
    return NaesinLinkSelection(
      gradeKey: g,
      courseKey: c,
      examTerm: t,
      school: s,
      year: y,
    );
  }

  static List<String> schoolsForGradeKey(String gradeKey) {
    if (gradeKey.startsWith('H')) {
      return highSchools;
    }
    return middleSchools;
  }
}

class NaesinGradeOption {
  final String key;
  final String label;
  final EducationLevel level;
  final int grade;

  const NaesinGradeOption({
    required this.key,
    required this.label,
    required this.level,
    required this.grade,
  });
}

class NaesinCourseOption {
  final String key;
  final String label;

  const NaesinCourseOption({required this.key, required this.label});
}

class NaesinLinkSelection {
  final String gradeKey;
  final String courseKey;
  final String examTerm;
  final String school;
  final int year;

  const NaesinLinkSelection({
    required this.gradeKey,
    required this.courseKey,
    required this.examTerm,
    required this.school,
    required this.year,
  });
}
