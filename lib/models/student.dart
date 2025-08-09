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
      groupId: groupId ?? this.groupId,
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
    };
  }

  // 호환성을 위한 getter들 (기본값 제공)
  DateTime get registrationDate => DateTime.now();
  int get weeklyClassCount => 1;

  @override
  String toString() {
    return 'Student(id: $id, name: $name, school: $school, grade: $grade, educationLevel: $educationLevel, groupInfo: $groupInfo, phoneNumber: $phoneNumber, parentPhoneNumber: $parentPhoneNumber, groupId: $groupId)';
  }
}

class StudentBasicInfo {
  final String studentId;
  final String? phoneNumber;
  final String? parentPhoneNumber;
  final String? groupId;
  final DateTime? registrationDate;
  final String? memo;

  StudentBasicInfo({
    required this.studentId,
    this.phoneNumber,
    this.parentPhoneNumber,
    this.groupId,
    this.registrationDate,
    this.memo,
  });

  StudentBasicInfo copyWith({
    String? phoneNumber,
    String? parentPhoneNumber,
    String? groupId,
    DateTime? registrationDate,
    String? memo,
  }) {
    return StudentBasicInfo(
      studentId: studentId,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      parentPhoneNumber: parentPhoneNumber ?? this.parentPhoneNumber,
      groupId: groupId ?? this.groupId,
      registrationDate: registrationDate ?? this.registrationDate,
      memo: memo ?? this.memo,
    );
  }

  factory StudentBasicInfo.fromDb(Map<String, dynamic> row) {
    return StudentBasicInfo(
      studentId: row['student_id'] as String,
      phoneNumber: row['phone_number'] as String?,
      parentPhoneNumber: row['parent_phone_number'] as String?,
      groupId: row['group_id'] as String?,
      memo: row['memo'] as String?,
    );
  }

  Map<String, dynamic> toDb() {
    return {
      'student_id': studentId,
      'phone_number': phoneNumber,
      'parent_phone_number': parentPhoneNumber,
      'group_id': groupId,
      'memo': memo,
    };
  }

  // 호환성을 위한 getter들 (기본값 제공)
  int get weeklyClassCount => 1;
  String get studentPaymentType => 'monthly';
  int get studentSessionCycle => 1;

  @override
  String toString() {
    return 'StudentBasicInfo(studentId: $studentId, phoneNumber: $phoneNumber, parentPhoneNumber: $parentPhoneNumber, groupId: $groupId, memo: $memo)';
  }
}

 