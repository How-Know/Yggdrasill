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
  final DateTime createdAt;
  final DateTime updatedAt;

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
    required this.createdAt,
    required this.updatedAt,
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
      createdAt: now,
      updatedAt: now,
    );
  }

  factory AttendanceRecord.fromMap(Map<String, dynamic> map) {
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
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
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
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
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
    DateTime? createdAt,
    DateTime? updatedAt,
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
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
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
    return 'AttendanceRecord(id: $id, studentId: $studentId, classDateTime: $classDateTime, className: $className, isPresent: $isPresent)';
  }
}