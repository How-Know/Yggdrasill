import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

class SelfStudyTimeBlock {
  final String id;
  final String studentId;
  final int dayIndex;
  final DateTime startTime;
  final Duration duration;
  final DateTime createdAt;
  final String? setId;
  final int? number;

  SelfStudyTimeBlock({
    required this.id,
    required this.studentId,
    required this.dayIndex,
    required this.startTime,
    required this.duration,
    required this.createdAt,
    this.setId,
    this.number,
  });

  factory SelfStudyTimeBlock.fromJson(Map<String, dynamic> json) {
    return SelfStudyTimeBlock(
      id: json['id'] as String,
      studentId: json['student_id'] as String? ?? json['studentId'] as String,
      dayIndex: json['day_index'] as int? ?? json['dayIndex'] as int,
      startTime: DateTime.parse(json['start_time'] as String? ?? json['startTime'] as String),
      duration: Duration(minutes: json['duration'] as int),
      createdAt: DateTime.parse(json['created_at'] as String? ?? json['createdAt'] as String),
      setId: json['set_id'] as String? ?? json['setId'] as String?,
      number: json['number'] as int?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'student_id': studentId,
    'day_index': dayIndex,
    'start_time': startTime.toIso8601String(),
    'duration': duration.inMinutes,
    'created_at': createdAt.toIso8601String(),
    'set_id': setId,
    'number': number,
  };

  SelfStudyTimeBlock copyWith({
    String? id,
    String? studentId,
    int? dayIndex,
    DateTime? startTime,
    Duration? duration,
    DateTime? createdAt,
    String? setId,
    int? number,
  }) {
    return SelfStudyTimeBlock(
      id: id ?? this.id,
      studentId: studentId ?? this.studentId,
      dayIndex: dayIndex ?? this.dayIndex,
      startTime: startTime ?? this.startTime,
      duration: duration ?? this.duration,
      createdAt: createdAt ?? this.createdAt,
      setId: setId ?? this.setId,
      number: number ?? this.number,
    );
  }
} 