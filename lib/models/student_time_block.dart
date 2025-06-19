import 'package:flutter/material.dart';

class StudentTimeBlock {
  final String id;
  final String studentId;
  final String? classId;
  final int dayIndex; // 0: 월요일 ~ 6: 일요일
  final DateTime startTime;
  final Duration duration;
  final DateTime createdAt;

  StudentTimeBlock({
    required this.id,
    required this.studentId,
    this.classId,
    required this.dayIndex,
    required this.startTime,
    required this.duration,
    required this.createdAt,
  });

  factory StudentTimeBlock.fromJson(Map<String, dynamic> json) {
    return StudentTimeBlock(
      id: json['id'] as String,
      studentId: json['studentId'] as String,
      classId: json['classId'] as String?,
      dayIndex: json['dayIndex'] as int,
      startTime: DateTime.parse(json['startTime'] as String),
      duration: Duration(minutes: json['duration'] as int),
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'studentId': studentId,
      'classId': classId,
      'dayIndex': dayIndex,
      'startTime': startTime.toIso8601String(),
      'duration': duration.inMinutes,
      'createdAt': createdAt.toIso8601String(),
    };
  }
} 