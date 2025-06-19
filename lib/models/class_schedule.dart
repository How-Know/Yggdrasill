import 'package:flutter/material.dart';

class ClassSchedule {
  final String id;
  final String classId;
  final int dayIndex;
  final DateTime startTime;
  final Duration duration;
  final DateTime createdAt;
  final DateTime? updatedAt;

  ClassSchedule({
    required this.id,
    required this.classId,
    required this.dayIndex,
    required this.startTime,
    required this.duration,
    required this.createdAt,
    this.updatedAt,
  });

  ClassSchedule copyWith({
    String? id,
    String? classId,
    int? dayIndex,
    DateTime? startTime,
    Duration? duration,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return ClassSchedule(
      id: id ?? this.id,
      classId: classId ?? this.classId,
      dayIndex: dayIndex ?? this.dayIndex,
      startTime: startTime ?? this.startTime,
      duration: duration ?? this.duration,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'classId': classId,
      'dayIndex': dayIndex,
      'startTime': startTime.toIso8601String(),
      'duration': duration.inMinutes,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String(),
    };
  }

  factory ClassSchedule.fromJson(Map<String, dynamic> json) {
    return ClassSchedule(
      id: json['id'],
      classId: json['classId'],
      dayIndex: json['dayIndex'],
      startTime: DateTime.parse(json['startTime']),
      duration: Duration(minutes: json['duration']),
      createdAt: DateTime.parse(json['createdAt']),
      updatedAt: json['updatedAt'] != null ? DateTime.parse(json['updatedAt']) : null,
    );
  }
} 