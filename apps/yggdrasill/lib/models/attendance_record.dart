import 'package:uuid/uuid.dart';

class AttendanceRecord {
  final String? id;
  final String studentId;
  final DateTime classDateTime; // 실제 수업 시작 시간
  final DateTime classEndTime; // 실제 수업 종료 시간
  final String className;
  final bool isPresent; // 출석 여부
  final DateTime? arrivalTime; // 등원 시간 (슬라이드시트와 연동)
  final DateTime? departureTime; // 하원 시간 (슬라이드시트와 연동)
  final String? notes; // 비고 (지각, 조퇴 등)
  final String? sessionTypeId; // 수업 타입
  final String? setId; // student_time_block set_id
  final String? snapshotId; // lesson snapshot 근거
  final String? batchSessionId; // 배치 세션 참조
  final int? cycle; // 등록 회차
  final int? sessionOrder; // 회차 내 순서
  final bool isPlanned; // 예정 여부
  final DateTime createdAt;
  final DateTime updatedAt;
  final int version; // 낙관적 잠금을 위한 버전

  AttendanceRecord({
    this.id,
    required this.studentId,
    required this.classDateTime,
    required this.classEndTime,
    required this.className,
    required this.isPresent,
    this.arrivalTime,
    this.departureTime,
    this.notes,
    this.sessionTypeId,
    this.setId,
    this.snapshotId,
    this.batchSessionId,
    this.cycle,
    this.sessionOrder,
    this.isPlanned = false,
    required this.createdAt,
    required this.updatedAt,
    this.version = 1,
  });

  factory AttendanceRecord.create({
    required String studentId,
    required DateTime classDateTime,
    required DateTime classEndTime,
    required String className,
    required bool isPresent,
    DateTime? arrivalTime,
    DateTime? departureTime,
    String? notes,
    String? sessionTypeId,
    String? setId,
    String? snapshotId,
    String? batchSessionId,
    int? cycle,
    int? sessionOrder,
    bool isPlanned = false,
  }) {
    final now = DateTime.now();
    return AttendanceRecord(
      id: const Uuid().v4(),
      studentId: studentId,
      classDateTime: classDateTime,
      classEndTime: classEndTime,
      className: className,
      isPresent: isPresent,
      arrivalTime: arrivalTime,
      departureTime: departureTime,
      notes: notes,
      sessionTypeId: sessionTypeId,
      setId: setId,
      snapshotId: snapshotId,
      batchSessionId: batchSessionId,
      cycle: cycle,
      sessionOrder: sessionOrder,
      isPlanned: isPlanned,
      createdAt: now,
      updatedAt: now,
      version: 1,
    );
  }

  factory AttendanceRecord.fromMap(Map<String, dynamic> map) {
    int _asInt(dynamic v) {
      if (v == null) return 0;
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? 0;
      return 0;
    }
    return AttendanceRecord(
      id: map['id'] as String?,
      studentId: map['student_id'] as String,
      classDateTime: DateTime.parse(map['class_date_time'] as String),
      classEndTime: DateTime.parse(map['class_end_time'] as String),
      className: map['class_name'] as String,
      isPresent: (map['is_present'] as int) == 1,
      arrivalTime: map['arrival_time'] != null 
          ? DateTime.parse(map['arrival_time'] as String)
          : null,
      departureTime: map['departure_time'] != null 
          ? DateTime.parse(map['departure_time'] as String)
          : null,
      notes: map['notes'] as String?,
      sessionTypeId: map['session_type_id'] as String?,
      setId: map['set_id'] as String?,
      snapshotId: map['snapshot_id'] as String?,
      batchSessionId: map['batch_session_id'] as String?,
      cycle: map['cycle'] is num ? (map['cycle'] as num).toInt() : null,
      sessionOrder: map['session_order'] is num ? (map['session_order'] as num).toInt() : null,
      isPlanned: map['is_planned'] == true || map['is_planned'] == 1,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
      version: _asInt(map['version']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'student_id': studentId,
      'class_date_time': classDateTime.toIso8601String(),
      'class_end_time': classEndTime.toIso8601String(),
      'class_name': className,
      'is_present': isPresent ? 1 : 0,
      'arrival_time': arrivalTime?.toIso8601String(),
      'departure_time': departureTime?.toIso8601String(),
      'notes': notes,
      'session_type_id': sessionTypeId,
      'set_id': setId,
      'snapshot_id': snapshotId,
      'batch_session_id': batchSessionId,
      'cycle': cycle,
      'session_order': sessionOrder,
      'is_planned': isPlanned,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'version': version,
    };
  }

  AttendanceRecord copyWith({
    String? id,
    String? studentId,
    DateTime? classDateTime,
    DateTime? classEndTime,
    String? className,
    bool? isPresent,
    DateTime? arrivalTime,
    DateTime? departureTime,
    String? notes,
    String? sessionTypeId,
    String? setId,
    String? snapshotId,
    String? batchSessionId,
    int? cycle,
    int? sessionOrder,
    bool? isPlanned,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? version,
  }) {
    return AttendanceRecord(
      id: id ?? this.id,
      studentId: studentId ?? this.studentId,
      classDateTime: classDateTime ?? this.classDateTime,
      classEndTime: classEndTime ?? this.classEndTime,
      className: className ?? this.className,
      isPresent: isPresent ?? this.isPresent,
      arrivalTime: arrivalTime ?? this.arrivalTime,
      departureTime: departureTime ?? this.departureTime,
      notes: notes ?? this.notes,
      sessionTypeId: sessionTypeId ?? this.sessionTypeId,
      setId: setId ?? this.setId,
      snapshotId: snapshotId ?? this.snapshotId,
      batchSessionId: batchSessionId ?? this.batchSessionId,
      cycle: cycle ?? this.cycle,
      sessionOrder: sessionOrder ?? this.sessionOrder,
      isPlanned: isPlanned ?? this.isPlanned,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      version: version ?? this.version,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AttendanceRecord &&
        other.id == id &&
        other.studentId == studentId &&
        other.classDateTime == classDateTime &&
        other.classEndTime == classEndTime;
  }

  @override
  int get hashCode {
    return id.hashCode ^
        studentId.hashCode ^
        classDateTime.hashCode ^
        classEndTime.hashCode;
  }

  @override
  String toString() {
    return 'AttendanceRecord(id: $id, studentId: $studentId, classDateTime: $classDateTime, className: $className, isPresent: $isPresent, version: $version)';
  }
}