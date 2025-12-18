import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

class StudentTimeBlock {
  final String id;
  final String studentId;
  final int dayIndex; // 0: 월요일 ~ 6: 일요일
  final int startHour;
  final int startMinute;
  final Duration duration;
  final DateTime createdAt;
  final DateTime startDate; // 적용 시작일(로컬 날짜)
  final DateTime? endDate; // 적용 종료일(누적 기록용), null이면 현재 유효
  final String? setId; // 같은 셋에 속한 블록끼리 공유
  final int? number;   // 1, 2, 3... 넘버링
  final String? sessionTypeId; // 수업카드 드롭시 등록되는 수업명(또는 고유값)
  final int? weeklyOrder; // 주간 내 n번째 수업(요일/시간 순 정렬 결과)

  StudentTimeBlock({
    required this.id,
    required this.studentId,
    required this.dayIndex,
    required this.startHour,
    required this.startMinute,
    required this.duration,
    required this.createdAt,
    required this.startDate,
    this.endDate,
    this.setId,
    this.number,
    this.sessionTypeId,
    this.weeklyOrder,
  });

  factory StudentTimeBlock.fromJson(Map<String, dynamic> json) {
    return StudentTimeBlock(
      id: json['id'] as String,
      studentId: json['student_id'] as String? ?? json['studentId'] as String,
      dayIndex: json['day_index'] as int? ?? json['dayIndex'] as int,
      startHour: json['start_hour'] as int,
      startMinute: json['start_minute'] as int,
      duration: Duration(minutes: json['duration'] as int),
      createdAt: DateTime.parse(json['created_at'] as String? ?? json['createdAt'] as String),
      startDate: DateTime.parse(
        (json['start_date'] as String?) ??
            (json['startDate'] as String? ?? (json['created_at'] as String? ?? json['createdAt'] as String)),
      ),
      endDate: (json['end_date'] as String?) != null
          ? DateTime.tryParse(json['end_date'] as String)
          : (json['endDate'] as String?) != null
              ? DateTime.tryParse(json['endDate'] as String)
              : null,
      setId: json['set_id'] as String? ?? json['setId'] as String?,
      number: json['number'] as int?,
      sessionTypeId: json['session_type_id'] as String?,
      weeklyOrder: json['weekly_order'] as int?,
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
    'start_date': _asDateString(startDate),
    'end_date': endDate != null ? _asDateString(endDate!) : null,
    'set_id': setId,
    'number': number,
    'session_type_id': sessionTypeId,
    'weekly_order': weeklyOrder,
  };

  StudentTimeBlock copyWith({
    String? id,
    String? studentId,
    int? dayIndex,
    int? startHour,
    int? startMinute,
    Duration? duration,
    DateTime? createdAt,
    DateTime? startDate,
    DateTime? endDate,
    String? setId,
    int? number,
    String? sessionTypeId,
    int? weeklyOrder,
  }) {
    return StudentTimeBlock(
      id: id ?? this.id,
      studentId: studentId ?? this.studentId,
      dayIndex: dayIndex ?? this.dayIndex,
      startHour: startHour ?? this.startHour,
      startMinute: startMinute ?? this.startMinute,
      duration: duration ?? this.duration,
      createdAt: createdAt ?? this.createdAt,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      setId: setId ?? this.setId,
      number: number ?? this.number,
      sessionTypeId: sessionTypeId ?? this.sessionTypeId,
      weeklyOrder: weeklyOrder ?? this.weeklyOrder,
    );
  }

  static String _asDateString(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    return d.toIso8601String().split('T').first;
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
    DateTime? startDate,
    DateTime? endDate,
  }) {
    final uuid = Uuid();
    final setId = uuid.v4();
    final now = DateTime.now();
    final sd = startDate != null
        ? DateTime(startDate.year, startDate.month, startDate.day)
        : DateTime(now.year, now.month, now.day);
    final ed = endDate != null ? DateTime(endDate.year, endDate.month, endDate.day) : null;
    // 시간순 정렬
    final sortedTimes = List<DateTime>.from(startTimes)..sort();
    return List.generate(sortedTimes.length, (i) {
      return StudentTimeBlock(
        id: uuid.v4(),
        studentId: studentIds[0], // 단일 학생 등록 기준
        dayIndex: dayIndex,
        startHour: sortedTimes[i].hour,
        startMinute: sortedTimes[i].minute,
        duration: duration,
        createdAt: now,
        startDate: sd,
        endDate: ed,
        setId: setId,
        number: i + 1,
      );
    });
  }
} 