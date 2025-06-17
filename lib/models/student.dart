import 'package:flutter/material.dart';
import 'class_info.dart';
import 'education_level.dart';

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

