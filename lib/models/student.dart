import 'package:flutter/material.dart';
import 'group_info.dart';
import 'education_level.dart';

class Student {
  final String id;
  final String name;
  final String school;
  final int grade;
  final EducationLevel educationLevel;
  final GroupInfo? groupInfo;
  final String? phoneNumber;
  final String? parentPhoneNumber;
  final DateTime? registrationDate;
  final int? weeklyClassCount;
  final String? groupId;

  Student({
    required this.id,
    required this.name,
    required this.school,
    required this.grade,
    required this.educationLevel,
    this.groupInfo,
    this.phoneNumber,
    this.parentPhoneNumber,
    this.registrationDate,
    this.weeklyClassCount,
    this.groupId,
  });

  Student copyWith({
    String? id,
    String? name,
    String? school,
    int? grade,
    EducationLevel? educationLevel,
    GroupInfo? groupInfo,
    String? phoneNumber,
    String? parentPhoneNumber,
    DateTime? registrationDate,
    int? weeklyClassCount,
    String? groupId,
  }) {
    return Student(
      id: id ?? this.id,
      name: name ?? this.name,
      school: school ?? this.school,
      grade: grade ?? this.grade,
      educationLevel: educationLevel ?? this.educationLevel,
      groupInfo: groupInfo ?? this.groupInfo,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      parentPhoneNumber: parentPhoneNumber ?? this.parentPhoneNumber,
      registrationDate: registrationDate ?? this.registrationDate,
      weeklyClassCount: weeklyClassCount ?? this.weeklyClassCount,
      groupId: groupId,
    );
  }

  factory Student.fromDb(Map<String, dynamic> row) {
    return Student(
      id: row['id'] as String,
      name: row['name'] as String,
      school: row['school'] as String,
      grade: row['grade'] as int,
      educationLevel: EducationLevel.values[row['education_level'] as int],
      phoneNumber: row['phone_number'] as String?,
      parentPhoneNumber: row['parent_phone_number'] as String?,
      registrationDate: row['registration_date'] != null ? DateTime.parse(row['registration_date'] as String) : null,
      weeklyClassCount: row['weekly_class_count'] as int?,
      groupId: row['group_id'] as String?,
      groupInfo: null,
    );
  }

  Map<String, dynamic> toDb() {
    return {
      'id': id,
      'name': name,
      'school': school,
      'grade': grade,
      'education_level': educationLevel.index,
      'phone_number': phoneNumber,
      'parent_phone_number': parentPhoneNumber,
      'registration_date': registrationDate?.toIso8601String(),
      'weekly_class_count': weeklyClassCount,
      'group_id': groupId,
    };
  }
}

class StudentBasicInfo {
  final String studentId;
  final String? phoneNumber;
  final String? parentPhoneNumber;
  final DateTime registrationDate;
  final int weeklyClassCount;
  final String? groupId;

  StudentBasicInfo({
    required this.studentId,
    this.phoneNumber,
    this.parentPhoneNumber,
    required this.registrationDate,
    this.weeklyClassCount = 1,
    this.groupId,
  });

  StudentBasicInfo copyWith({
    String? phoneNumber,
    String? parentPhoneNumber,
    DateTime? registrationDate,
    int? weeklyClassCount,
    String? groupId,
  }) {
    return StudentBasicInfo(
      studentId: studentId,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      parentPhoneNumber: parentPhoneNumber ?? this.parentPhoneNumber,
      registrationDate: registrationDate ?? this.registrationDate,
      weeklyClassCount: weeklyClassCount ?? this.weeklyClassCount,
      groupId: groupId,
    );
  }

  factory StudentBasicInfo.fromDb(Map<String, dynamic> row) {
    return StudentBasicInfo(
      studentId: row['student_id'] as String,
      phoneNumber: row['phone_number'] as String?,
      parentPhoneNumber: row['parent_phone_number'] as String?,
      registrationDate: DateTime.parse(row['registration_date'] as String),
      weeklyClassCount: row['weekly_class_count'] as int? ?? 1,
      groupId: row['group_id'] as String?,
    );
  }

  Map<String, dynamic> toDb() {
    return {
      'student_id': studentId,
      'phone_number': phoneNumber,
      'parent_phone_number': parentPhoneNumber,
      'registration_date': registrationDate.toIso8601String(),
      'weekly_class_count': weeklyClassCount,
      'group_id': groupId,
    };
  }
}

 