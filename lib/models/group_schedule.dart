import 'package:flutter/material.dart';

class GroupSchedule {
  final String id;
  final String groupId;
  final int dayIndex;
  final DateTime startTime;
  final Duration duration;
  final DateTime createdAt;
  final DateTime? updatedAt;

  GroupSchedule({
    required this.id,
    required this.groupId,
    required this.dayIndex,
    required this.startTime,
    required this.duration,
    required this.createdAt,
    this.updatedAt,
  });

  GroupSchedule copyWith({
    String? id,
    String? groupId,
    int? dayIndex,
    DateTime? startTime,
    Duration? duration,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return GroupSchedule(
      id: id ?? this.id,
      groupId: groupId ?? this.groupId,
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
      'groupId': groupId,
      'dayIndex': dayIndex,
      'startTime': startTime.toIso8601String(),
      'duration': duration.inMinutes,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt?.toIso8601String(),
    };
  }

  factory GroupSchedule.fromJson(Map<String, dynamic> json) {
    return GroupSchedule(
      id: json['id'],
      groupId: json['groupId'],
      dayIndex: json['dayIndex'],
      startTime: DateTime.parse(json['startTime']),
      duration: Duration(minutes: json['duration']),
      createdAt: DateTime.parse(json['createdAt']),
      updatedAt: json['updatedAt'] != null ? DateTime.parse(json['updatedAt']) : null,
    );
  }
} 