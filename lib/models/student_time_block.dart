import 'package:flutter/material.dart';

class StudentTimeBlock {
  final String id;
  final String studentId;
  final String? groupId;
  final int dayIndex; // 0: 월요일 ~ 6: 일요일
  final DateTime startTime;
  final Duration duration;
  final DateTime createdAt;

  StudentTimeBlock({
    required this.id,
    required this.studentId,
    this.groupId,
    required this.dayIndex,
    required this.startTime,
    required this.duration,
    required this.createdAt,
  });

  factory StudentTimeBlock.fromJson(Map<String, dynamic> json) {
    return StudentTimeBlock(
      id: json['id'] as String,
      studentId: json['studentId'] as String,
      groupId: json['groupId'] as String?,
      dayIndex: json['dayIndex'] as int,
      startTime: DateTime.parse(json['startTime'] as String),
      duration: Duration(minutes: json['duration'] as int),
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'student_id': studentId,
    'group_id': groupId,
    'day_index': dayIndex,
    'start_time': startTime.toIso8601String(),
    'duration': duration.inMinutes,
    'created_at': createdAt.toIso8601String(),
  };

  StudentTimeBlock copyWith({
    String? id,
    String? studentId,
    String? groupId,
    int? dayIndex,
    DateTime? startTime,
    Duration? duration,
    DateTime? createdAt,
  }) {
    return StudentTimeBlock(
      id: id ?? this.id,
      studentId: studentId ?? this.studentId,
      groupId: groupId ?? this.groupId,
      dayIndex: dayIndex ?? this.dayIndex,
      startTime: startTime ?? this.startTime,
      duration: duration ?? this.duration,
      createdAt: createdAt ?? this.createdAt,
    );
  }
} 