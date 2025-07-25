import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

class StudentTimeBlock {
  final String id;
  final String studentId;
  final String? groupId;
  final int dayIndex; // 0: 월요일 ~ 6: 일요일
  final DateTime startTime;
  final Duration duration;
  final DateTime createdAt;
  final String? setId; // 같은 셋에 속한 블록끼리 공유
  final int? number;   // 1, 2, 3... 넘버링
  final String? sessionTypeId; // 수업카드 드롭시 등록되는 수업명(또는 고유값)

  StudentTimeBlock({
    required this.id,
    required this.studentId,
    this.groupId,
    required this.dayIndex,
    required this.startTime,
    required this.duration,
    required this.createdAt,
    this.setId,
    this.number,
    this.sessionTypeId,
  });

  factory StudentTimeBlock.fromJson(Map<String, dynamic> json) {
    return StudentTimeBlock(
      id: json['id'] as String,
      studentId: json['student_id'] as String? ?? json['studentId'] as String,
      groupId: json['group_id'] as String? ?? json['groupId'] as String?,
      dayIndex: json['day_index'] as int? ?? json['dayIndex'] as int,
      startTime: DateTime.parse(json['start_time'] as String? ?? json['startTime'] as String),
      duration: Duration(minutes: json['duration'] as int),
      createdAt: DateTime.parse(json['created_at'] as String? ?? json['createdAt'] as String),
      setId: json['set_id'] as String? ?? json['setId'] as String?,
      number: json['number'] as int?,
      sessionTypeId: json['session_type_id'] as String?,
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
    'session_type_id': sessionTypeId,
  };

  StudentTimeBlock copyWith({
    String? id,
    String? studentId,
    String? groupId,
    int? dayIndex,
    DateTime? startTime,
    Duration? duration,
    DateTime? createdAt,
    String? setId,
    int? number,
    String? sessionTypeId,
  }) {
    return StudentTimeBlock(
      id: id ?? this.id,
      studentId: studentId ?? this.studentId,
      groupId: groupId ?? this.groupId,
      dayIndex: dayIndex ?? this.dayIndex,
      startTime: startTime ?? this.startTime,
      duration: duration ?? this.duration,
      createdAt: createdAt ?? this.createdAt,
      setId: setId ?? this.setId,
      number: number ?? this.number,
      sessionTypeId: sessionTypeId ?? this.sessionTypeId,
    );
  }
}

/// 여러 StudentTimeBlock을 setId, number와 함께 일관성 있게 생성하는 헬퍼
class StudentTimeBlockFactory {
  /// 여러 학생/시간에 대해 한 번에 시간블록을 생성 (setId, number 자동 부여)
  static List<StudentTimeBlock> createBlocksWithSetIdAndNumber({
    required List<String> studentIds,
    required int dayIndex,
    required List<DateTime> startTimes,
    required Duration duration,
  }) {
    final uuid = Uuid();
    final setId = uuid.v4();
    // 시간순 정렬
    final sortedTimes = List<DateTime>.from(startTimes)..sort();
    return List.generate(sortedTimes.length, (i) {
      return StudentTimeBlock(
        id: uuid.v4(),
        studentId: studentIds[0], // 단일 학생 등록 기준
        dayIndex: dayIndex,
        startTime: sortedTimes[i],
        duration: duration,
        createdAt: DateTime.now(),
        setId: setId,
        number: i + 1,
      );
    });
  }
} 