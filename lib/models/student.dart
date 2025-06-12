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

  const Grade(this.level, this.name, this.value);

  Map<String, dynamic> toJson() => {
    'level': level.index,
    'name': name,
    'value': value,
  };

  factory Grade.fromJson(Map<String, dynamic> json) => Grade(
    EducationLevel.values[json['level']],
    json['name'],
    json['value'],
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
    Grade(EducationLevel.high, 'N수', 4),
  ],
};

class Student {
  final String name;
  final String school;
  final EducationLevel educationLevel;
  final Grade grade;
  final String phoneNumber;
  final String parentPhoneNumber;
  final DateTime registrationDate;
  ClassInfo? _classInfo;

  Student({
    required this.name,
    required this.school,
    required this.educationLevel,
    required this.grade,
    ClassInfo? classInfo,
    this.phoneNumber = '',
    this.parentPhoneNumber = '',
    DateTime? registrationDate,
  })  : _classInfo = classInfo,
        registrationDate = registrationDate ?? DateTime.now();

  ClassInfo? get classInfo => _classInfo;
  set classInfo(ClassInfo? value) => _classInfo = value;

  Student copyWith({
    String? name,
    String? school,
    EducationLevel? educationLevel,
    Grade? grade,
    ClassInfo? classInfo,
    String? phoneNumber,
    String? parentPhoneNumber,
    DateTime? registrationDate,
  }) {
    return Student(
      name: name ?? this.name,
      school: school ?? this.school,
      educationLevel: educationLevel ?? this.educationLevel,
      grade: grade ?? this.grade,
      classInfo: classInfo ?? this.classInfo,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      parentPhoneNumber: parentPhoneNumber ?? this.parentPhoneNumber,
      registrationDate: registrationDate ?? this.registrationDate,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'school': school,
    'educationLevel': educationLevel.index,
    'grade': grade.toJson(),
    'classId': classInfo?.id,
    'phoneNumber': phoneNumber,
    'parentPhoneNumber': parentPhoneNumber,
    'registrationDate': registrationDate.toIso8601String(),
  };

  factory Student.fromJson(Map<String, dynamic> json, Map<String, ClassInfo> classesById) => Student(
    name: json['name'],
    school: json['school'],
    educationLevel: EducationLevel.values[json['educationLevel']],
    grade: Grade.fromJson(json['grade']),
    classInfo: json['classId'] != null ? classesById[json['classId']] : null,
    phoneNumber: json['phoneNumber'],
    parentPhoneNumber: json['parentPhoneNumber'],
    registrationDate: DateTime.parse(json['registrationDate']),
  );
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