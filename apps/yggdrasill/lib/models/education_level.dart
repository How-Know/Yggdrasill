enum EducationLevel {
  elementary,
  middle,
  high,
}

String getEducationLevelName(EducationLevel level) {
  switch (level) {
    case EducationLevel.elementary:
      return '초등';
    case EducationLevel.middle:
      return '중등';
    case EducationLevel.high:
      return '고등';
  }
}

/// 고등 과정인데 학교명이 전형적인 중학교명(…중)으로만 보일 때.
/// 진학 후 `education_level`만 올리고 `school`을 안 바꾼 경우를 의심할 수 있다.
bool schoolNameLikelyMiddleWhenHighLevel(String school, EducationLevel level) {
  if (level != EducationLevel.high) return false;
  final t = school.trim();
  if (t.isEmpty) return false;
  if (t.contains('중고')) return false;
  if (t.contains('여고') || t.contains('남고') || t.contains('외고')) {
    return false;
  }
  if (t.endsWith('고') || t.contains('고등학교')) return false;
  if (t.endsWith('중')) return true;
  return false;
}

class Grade {
  final EducationLevel level;
  final String name;
  final int value;
  final bool isRepeater;

  const Grade(this.level, this.name, this.value, {this.isRepeater = false});

  Map<String, dynamic> toJson() => {
    'level': level.index,
    'name': name,
    'value': value,
    'isRepeater': isRepeater,
  };

  factory Grade.fromJson(Map<String, dynamic> json) => Grade(
    EducationLevel.values[json['level']],
    json['name'],
    json['value'],
    isRepeater: json['isRepeater'] ?? false,
  );
}

final Map<EducationLevel, List<Grade>> gradesByLevel = {
  EducationLevel.elementary: [
    Grade(EducationLevel.elementary, '1학년', 1),
    Grade(EducationLevel.elementary, '2학년', 2),
    Grade(EducationLevel.elementary, '3학년', 3),
    Grade(EducationLevel.elementary, '4학년', 4),
    Grade(EducationLevel.elementary, '5학년', 5),
    Grade(EducationLevel.elementary, '6학년', 6),
  ],
  EducationLevel.middle: [
    Grade(EducationLevel.middle, '1학년', 1),
    Grade(EducationLevel.middle, '2학년', 2),
    Grade(EducationLevel.middle, '3학년', 3),
  ],
  EducationLevel.high: [
    Grade(EducationLevel.high, '1학년', 1),
    Grade(EducationLevel.high, '2학년', 2),
    Grade(EducationLevel.high, '3학년', 3),
    Grade(EducationLevel.high, 'N수', 4, isRepeater: true),
  ],
}; 