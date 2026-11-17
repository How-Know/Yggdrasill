import '../screens/problem_bank/naesin_link_school_name.dart';

/// 내신 시험지의 과정(과목) 선택지. 키·이름은 문제은행 분류와 같다.
class SchoolExamCourse {
  const SchoolExamCourse(this.key, this.label, this.curriculumCode, this.schoolLevel);

  final String key;
  final String label;

  /// 이 과정이 속한 교육과정. 중등 과정은 두 교육과정에서 키가 같아 빈 값이다.
  final String curriculumCode;
  final String schoolLevel;
}

const List<SchoolExamCourse> kSchoolExamCourses = [
  SchoolExamCourse('M1-1', '1-1', '', 'middle'),
  SchoolExamCourse('M1-2', '1-2', '', 'middle'),
  SchoolExamCourse('M2-1', '2-1', '', 'middle'),
  SchoolExamCourse('M2-2', '2-2', '', 'middle'),
  SchoolExamCourse('M3-1', '3-1', '', 'middle'),
  SchoolExamCourse('M3-2', '3-2', '', 'middle'),
  SchoolExamCourse('H1-c1', '공통수학1', 'rev_2022', 'high'),
  SchoolExamCourse('H1-c2', '공통수학2', 'rev_2022', 'high'),
  SchoolExamCourse('H-algebra', '대수', 'rev_2022', 'high'),
  SchoolExamCourse('H-calc1', '미적분1', 'rev_2022', 'high'),
  SchoolExamCourse('H-calc2', '미적분2', 'rev_2022', 'high'),
  SchoolExamCourse('H1-math-upper', '수학(상)', 'rev_2015', 'high'),
  SchoolExamCourse('H1-math-lower', '수학(하)', 'rev_2015', 'high'),
  SchoolExamCourse('H-math1', '수학1', 'rev_2015', 'high'),
  SchoolExamCourse('H-math2', '수학2', 'rev_2015', 'high'),
  SchoolExamCourse('H-calculus', '미적분', 'rev_2015', 'high'),
  SchoolExamCourse('H-probstats', '확률과 통계', '', 'high'),
  SchoolExamCourse('H-geometry', '기하', '', 'high'),
];

SchoolExamCourse? schoolExamCourseByKey(String key) {
  for (final c in kSchoolExamCourses) {
    if (c.key == key) return c;
  }
  return null;
}

/// 2022 개정 교육과정 적용 시기: 중1·고1은 2025년, 2학년은 2026년, 3학년은 2027년부터.
String schoolExamCurriculumOf(int? examYear, int? grade) {
  if (examYear == null || grade == null) return 'rev_2022';
  return examYear >= 2024 + grade ? 'rev_2022' : 'rev_2015';
}

/// 내신 시험지 한 부의 분류. 파일 이름에서 읽고, 업로드 창에서 고칠 수 있다.
class SchoolExamFileInfo {
  const SchoolExamFileInfo({
    this.examYear,
    this.schoolShortName = '',
    this.schoolLevel = '',
    this.grade,
    this.semesterLabel = '',
    this.examTermLabel = '',
    this.courseKey = '',
    this.curriculumCode = 'rev_2022',
    this.essayPart = false,
  });

  final int? examYear;

  /// 경신중, 정화여고 같은 줄임 이름
  final String schoolShortName;

  /// middle | high
  final String schoolLevel;
  final int? grade;

  /// 1학기 | 2학기
  final String semesterLabel;

  /// 중간 | 기말
  final String examTermLabel;
  final String courseKey;
  final String curriculumCode;

  /// 같은 시험의 서술형 부분만 따로 만든 파일
  final bool essayPart;

  String get schoolName => naesinSchoolDisplayName(schoolShortName);
  String get gradeKey => grade == null || schoolLevel.isEmpty ? '' : '${schoolLevel == 'high' ? 'H' : 'M'}$grade';
  String get gradeLabel => grade == null ? '' : '$grade';
  String get courseLabel => schoolExamCourseByKey(courseKey)?.label ?? '';

  /// 학교 이름이 "…중", "…고" 꼴이고 학년의 학교급과 맞는가
  bool get schoolValid {
    if (!RegExp(r'^[가-힣A-Za-z0-9]+(중|고)$').hasMatch(schoolShortName)) return false;
    if (schoolLevel.isEmpty) return true;
    return schoolShortName.endsWith('고') == (schoolLevel == 'high');
  }

  /// 빠진 항목 이름. 비어 있어야 올릴 수 있다.
  List<String> get missing => [
        if (examYear == null) '연도',
        if (!schoolValid) '학교',
        if (grade == null || schoolLevel.isEmpty) '학년',
        if (semesterLabel.isEmpty) '학기',
        if (examTermLabel.isEmpty) '중간·기말',
        if (schoolExamCourseByKey(courseKey)?.schoolLevel != schoolLevel || courseKey.isEmpty) '과정',
      ];
  bool get isComplete => missing.isEmpty;

  /// "2025 2학년 1학기 중간" (고등은 과정 이름을 붙인다)
  String get title => [
        if (examYear != null) '$examYear',
        if (grade != null) '$grade학년',
        if (semesterLabel.isNotEmpty) semesterLabel,
        if (examTermLabel.isNotEmpty) examTermLabel,
        if (schoolLevel == 'high' && courseLabel.isNotEmpty) courseLabel,
        if (essayPart) '(서술형)',
      ].join(' ');

  SchoolExamFileInfo copyWith({
    int? examYear,
    String? schoolShortName,
    String? schoolLevel,
    int? grade,
    String? semesterLabel,
    String? examTermLabel,
    String? courseKey,
    String? curriculumCode,
  }) =>
      SchoolExamFileInfo(
        examYear: examYear ?? this.examYear,
        schoolShortName: schoolShortName ?? this.schoolShortName,
        schoolLevel: schoolLevel ?? this.schoolLevel,
        grade: grade ?? this.grade,
        semesterLabel: semesterLabel ?? this.semesterLabel,
        examTermLabel: examTermLabel ?? this.examTermLabel,
        courseKey: courseKey ?? this.courseKey,
        curriculumCode: curriculumCode ?? this.curriculumCode,
        essayPart: essayPart,
      );

  /// 연도를 바꾼다(비울 수 있다).
  SchoolExamFileInfo withExamYear(int? year) => SchoolExamFileInfo(
        examYear: year,
        schoolShortName: schoolShortName,
        schoolLevel: schoolLevel,
        grade: grade,
        semesterLabel: semesterLabel,
        examTermLabel: examTermLabel,
        courseKey: courseKey,
        curriculumCode: curriculumCode,
        essayPart: essayPart,
      ).normalized();

  /// 학교 이름을 바꾼다. 이름 끝(중·고)으로 학교급을 맞추고, 학교급이 바뀌면 과정을 다시 고르게 비운다.
  SchoolExamFileInfo withSchool(String raw) {
    final short = shortSchoolName(raw);
    final level = short.endsWith('중') ? 'middle' : (short.endsWith('고') ? 'high' : schoolLevel);
    return SchoolExamFileInfo(
      examYear: examYear,
      schoolShortName: short,
      schoolLevel: level,
      grade: grade,
      semesterLabel: semesterLabel,
      examTermLabel: examTermLabel,
      courseKey: level == schoolLevel ? courseKey : '',
      curriculumCode: curriculumCode,
      essayPart: essayPart,
    ).normalized();
  }

  /// 경신중학교 → 경신중, 정화여자고등학교 → 정화여고
  static String shortSchoolName(String raw) => raw
      .replaceAll(RegExp(r'\s+'), '')
      .replaceFirst(RegExp(r'여자중학교$'), '여중')
      .replaceFirst(RegExp(r'여자고등학교$'), '여고')
      .replaceFirst(RegExp(r'중학교$'), '중')
      .replaceFirst(RegExp(r'고등학교$'), '고');

  /// 학년·학기가 바뀌면 중등 과정과 교육과정을 그에 맞춘다(고등 과정은 고른 값을 둔다).
  SchoolExamFileInfo normalized() {
    var key = courseKey;
    if (schoolLevel == 'middle' && grade != null && semesterLabel.isNotEmpty) {
      final current = schoolExamCourseByKey(courseKey);
      if (current == null || current.schoolLevel != 'middle' || !courseKey.startsWith('M$grade-')) {
        key = 'M$grade-${semesterLabel == '2학기' ? 2 : 1}';
      }
    } else if (schoolLevel == 'high' && schoolExamCourseByKey(courseKey)?.schoolLevel != 'high') {
      key = '';
    }
    final fixed = schoolExamCourseByKey(key)?.curriculumCode ?? '';
    return copyWith(
      courseKey: key,
      curriculumCode: fixed.isNotEmpty ? fixed : schoolExamCurriculumOf(examYear, grade),
    );
  }

  /// 문서·문항 분류 컬럼(확정 때 쓴다)
  Map<String, dynamic> classificationColumns() => {
        'school_level': schoolLevel,
        'grade_key': gradeKey,
        'course_key': courseKey,
        'course_label': courseLabel,
        'grade_label': gradeLabel,
        'exam_year': examYear,
        'semester_label': semesterLabel,
        'exam_term_label': examTermLabel,
        'school_name': schoolName,
      };

  /// `meta.source_classification` (문제은행 문서 확정과 같은 모양)
  Map<String, dynamic> sourceClassification() => {
        'private_material': false,
        'school_past_exam': true,
        'mock_past_exam': false,
        'school_level': schoolLevel,
        'grade_key': gradeKey,
        'course_key': courseKey,
        'course_label': courseLabel,
        'textbook_course': {'grade_key': gradeKey, 'course_key': courseKey, 'course_label': courseLabel},
        'naesin': {
          'year': examYear == null ? '' : '$examYear',
          'school_name': schoolName,
          'grade': gradeLabel,
          'school_level': schoolLevel,
          'grade_key': gradeKey,
          'course_key': courseKey,
          'course_label': courseLabel,
          'semester': semesterLabel,
          'exam_term': examTermLabel,
        },
      };

  /// "2025년 대구 수성구 경북고 고1공통 1학기중간 공통수학1 (서술형).hwpx" 같은 이름을 읽는다.
  /// 못 읽은 항목은 비워 둔다.
  static SchoolExamFileInfo parse(String fileName) {
    var name = fileName.trim();
    final dot = name.lastIndexOf('.');
    if (dot > 0 && name.length - dot <= 6) name = name.substring(0, dot);
    final essay = name.contains('서술형');
    name = name.replaceAll(RegExp(r'[()\[\]_]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

    final yearMatch = RegExp(r'(20\d{2})\s*년').firstMatch(name) ?? RegExp(r'(?<!\d)(20\d{2})(?!\d)').firstMatch(name);
    final year = yearMatch == null ? null : int.parse(yearMatch.group(1)!);

    var school = '';
    for (final token in name.split(' ')) {
      if (RegExp(r'^[중고]\s*[1-3]').hasMatch(token) || token.startsWith('중등') || token.startsWith('고등')) continue;
      final short = shortSchoolName(token);
      if (RegExp(r'^[가-힣]{2,}(중|고)$').hasMatch(short)) {
        school = short;
        break;
      }
    }

    var level = school.endsWith('중') ? 'middle' : (school.endsWith('고') ? 'high' : '');
    int? grade;
    final gradeMatch = RegExp(r'(?:^| )(중|고)\s*([1-3])').firstMatch(name);
    final middleCourse = RegExp(r'중등\s*수학\s*([1-3])\s*(상|하)').firstMatch(name);
    if (gradeMatch != null) {
      if (level.isEmpty) level = gradeMatch.group(1) == '고' ? 'high' : 'middle';
      grade = int.parse(gradeMatch.group(2)!);
    } else if (middleCourse != null) {
      if (level.isEmpty) level = 'middle';
      grade = int.parse(middleCourse.group(1)!);
    }

    final semMatch = RegExp(r'([12])\s*학기').firstMatch(name);
    final semester = semMatch == null ? '' : '${semMatch.group(1)}학기';
    final term = name.contains('중간') ? '중간' : (name.contains('기말') ? '기말' : '');

    var courseKey = '';
    if (level == 'middle') {
      if (middleCourse != null && (grade == null || '$grade' == middleCourse.group(1))) {
        courseKey = 'M${middleCourse.group(1)}-${middleCourse.group(2) == '하' ? 2 : 1}';
      } else if (grade != null && semester.isNotEmpty) {
        courseKey = 'M$grade-${semester == '2학기' ? 2 : 1}';
      }
    } else if (level == 'high') {
      final flat = name
          .replaceAll(' ', '')
          .replaceAll('Ⅱ', '2')
          .replaceAll('Ⅰ', '1')
          .replaceAll('II', '2')
          .replaceAll('I', '1');
      final by2022 = schoolExamCurriculumOf(year, grade) == 'rev_2022';
      const ordered = <(String, String)>[
        ('공통수학1', 'H1-c1'),
        ('공통수학2', 'H1-c2'),
        ('확률과통계', 'H-probstats'),
        ('확통', 'H-probstats'),
        ('미적분1', 'H-calc1'),
        ('미적분2', 'H-calc2'),
        ('미적분', 'H-calculus'),
        ('기하', 'H-geometry'),
        ('대수', 'H-algebra'),
        ('수학상', 'H1-math-upper'),
        ('수학하', 'H1-math-lower'),
        ('수학1', 'H-math1'),
        ('수학2', 'H-math2'),
      ];
      for (final (word, key) in ordered) {
        if (!flat.contains(word)) continue;
        // 2022 개정 학년의 "미적분"은 미적분1 로 본다(2015 과목 이름과 같아서).
        courseKey = key == 'H-calculus' && by2022 ? 'H-calc1' : key;
        break;
      }
    }

    return SchoolExamFileInfo(
      examYear: year,
      schoolShortName: school,
      schoolLevel: level,
      grade: grade,
      semesterLabel: semester,
      examTermLabel: term,
      courseKey: courseKey,
      essayPart: essay,
    ).normalized();
  }
}
