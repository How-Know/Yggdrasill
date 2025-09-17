import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

class SelfStudyTimeBlock {
  final String id;
  final String studentId;
  final int dayIndex;
  final int startHour;
  final int startMinute;
  final Duration duration;
  final DateTime createdAt;
  final String? setId;
  final int? number;

  SelfStudyTimeBlock({
    required this.id,
    required this.studentId,
    required this.dayIndex,
    required this.startHour,
    required this.startMinute,
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
      startHour: json['start_hour'] as int,
      startMinute: json['start_minute'] as int,
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
    'start_hour': startHour,
    'start_minute': startMinute,
    'duration': duration.inMinutes,
    'created_at': createdAt.toIso8601String(),
    'set_id': setId,
    'number': number,
  };

  Map<String, dynamic> toDb() => toJson();

  SelfStudyTimeBlock copyWith({
    String? id,
    String? studentId,
    int? dayIndex,
    int? startHour,
    int? startMinute,
    Duration? duration,
    DateTime? createdAt,
    String? setId,
    int? number,
  }) {
    return SelfStudyTimeBlock(
      id: id ?? this.id,
      studentId: studentId ?? this.studentId,
      dayIndex: dayIndex ?? this.dayIndex,
      startHour: startHour ?? this.startHour,
      startMinute: startMinute ?? this.startMinute,
      duration: duration ?? this.duration,
      createdAt: createdAt ?? this.createdAt,
      setId: setId ?? this.setId,
      number: number ?? this.number,
    );
  }
}

/// 여러 SelfStudyTimeBlock을 setId, number와 함께 일관성 있게 생성하는 헬퍼
class SelfStudyTimeBlockFactory {
  /// 여러 시간에 대해 한 번에 자습 블록을 생성 (setId, number 자동 부여)
  static List<SelfStudyTimeBlock> createBlocksWithSetIdAndNumber({
    required String studentId,
    required int dayIndex,
    required List<DateTime> startTimes,
    required Duration duration,
  }) {
    final uuid = Uuid();
    final setId = uuid.v4();
    // 시간순 정렬
    final sortedTimes = List<DateTime>.from(startTimes)..sort();
    return List.generate(sortedTimes.length, (i) {
      return SelfStudyTimeBlock(
        id: uuid.v4(),
        studentId: studentId,
        dayIndex: dayIndex,
        startHour: sortedTimes[i].hour,
        startMinute: sortedTimes[i].minute,
        duration: duration,
        createdAt: DateTime.now(),
        setId: setId,
        number: i + 1,
      );
    });
  }
}