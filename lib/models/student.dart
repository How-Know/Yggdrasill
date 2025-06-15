import 'package:flutter/material.dart';
import 'class_info.dart';

enum EducationLevel {
  elementary,
  middle,
  high,
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

class Student {
  final String id;
  final String name;
  final String school;
  final int grade;
  final EducationLevel educationLevel;
  final String? phoneNumber;
  final String? parentPhoneNumber;
  final DateTime registrationDate;
  final ClassInfo? classInfo;

  Student({
    required this.id,
    required this.name,
    required this.school,
    required this.grade,
    required this.educationLevel,
    this.phoneNumber,
    this.parentPhoneNumber,
    required this.registrationDate,
    this.classInfo,
  });

  factory Student.fromJson(Map<String, dynamic> json, [Map<String, ClassInfo>? classesById]) {
    final classInfoJson = json['classInfo'] as Map<String, dynamic>?;
    final classInfo = classInfoJson != null
        ? (classesById != null && classesById.containsKey(classInfoJson['id'])
            ? classesById[classInfoJson['id']]
            : ClassInfo.fromJson(classInfoJson))
        : null;

    return Student(
      id: json['id'] as String,
      name: json['name'] as String,
      school: json['school'] as String,
      grade: json['grade'] as int,
      educationLevel: EducationLevel.values[json['educationLevel'] as int],
      phoneNumber: json['phoneNumber'] as String?,
      parentPhoneNumber: json['parentPhoneNumber'] as String?,
      registrationDate: DateTime.parse(json['registrationDate'] as String),
      classInfo: classInfo,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'school': school,
      'grade': grade,
      'educationLevel': educationLevel.index,
      'phoneNumber': phoneNumber,
      'parentPhoneNumber': parentPhoneNumber,
      'registrationDate': registrationDate.toIso8601String(),
      'classInfo': classInfo?.toJson(),
    };
  }

  Student copyWith({
    String? id,
    String? name,
    String? school,
    int? grade,
    EducationLevel? educationLevel,
    String? phoneNumber,
    String? parentPhoneNumber,
    DateTime? registrationDate,
    ClassInfo? classInfo,
  }) {
    return Student(
      id: id ?? this.id,
      name: name ?? this.name,
      school: school ?? this.school,
      grade: grade ?? this.grade,
      educationLevel: educationLevel ?? this.educationLevel,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      parentPhoneNumber: parentPhoneNumber ?? this.parentPhoneNumber,
      registrationDate: registrationDate ?? this.registrationDate,
      classInfo: classInfo ?? this.classInfo,
    );
  }
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