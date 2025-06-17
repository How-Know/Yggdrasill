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