import 'package:flutter/material.dart';
import 'group_info.dart';
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
  final GroupInfo? groupInfo;
  final String? groupId;
  final int weeklyClassCount;

  Student({
    required this.id,
    required this.name,
    required this.school,
    required this.grade,
    required this.educationLevel,
    this.phoneNumber,
    this.parentPhoneNumber,
    required this.registrationDate,
    this.groupInfo,
    this.groupId,
    this.weeklyClassCount = 1,
  });

  factory Student.fromJson(Map<String, dynamic> json, [Map<String, GroupInfo>? groupsById]) {
    final groupInfoJson = json['groupInfo'] as Map<String, dynamic>?;
    final groupInfo = groupInfoJson != null
        ? (groupsById != null && groupsById.containsKey(groupInfoJson['id'])
            ? groupsById[groupInfoJson['id']]
            : GroupInfo.fromJson(groupInfoJson))
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
      groupInfo: groupInfo,
      groupId: json['groupId'] as String?,
      weeklyClassCount: json['weeklyClassCount'] as int? ?? 1,
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
      'groupId': groupInfo?.id,
      'weeklyClassCount': weeklyClassCount,
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
    GroupInfo? groupInfo,
    String? groupId,
    int? weeklyClassCount,
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
      groupInfo: groupInfo ?? this.groupInfo,
      groupId: groupId ?? this.groupId,
      weeklyClassCount: weeklyClassCount ?? this.weeklyClassCount,
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
      registrationDate: DateTime.parse(row['registration_date'] as String),
      groupInfo: null,
      groupId: row['group_id'] as String?,
      weeklyClassCount: row['weekly_class_count'] as int? ?? 1,
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
      'registration_date': registrationDate.toIso8601String(),
      'group_id': groupInfo?.id,
      'weekly_class_count': weeklyClassCount,
    };
  }
}

 