import 'package:uuid/uuid.dart';

enum OverrideType { skip, replace, add }
enum OverrideStatus { planned, completed, canceled }
enum OverrideReason { makeup, holiday, teacher, other }

class SessionOverride {
  final String id;
  final String studentId;
  final String? sessionTypeId; // 수업 종류(이름/ID)
  final String? setId; // 세트 식별자
  final String? occurrenceId; // lesson_occurrences FK (원본 회차 고정 참조)
  final OverrideType overrideType;
  final DateTime? originalClassDateTime; // skip/replace 대상 회차
  final DateTime? replacementClassDateTime; // replace/add 대체/추가 회차
  final int? durationMinutes; // 분 단위
  final OverrideReason? reason;
  final OverrideStatus status;
  final String? originalAttendanceId; // 결석 레코드 ID (보강 상쇄 링크)
  final String? replacementAttendanceId; // 보강 출석 레코드 ID
  final DateTime createdAt;
  final DateTime updatedAt;
  final int version; // OCC

  SessionOverride({
    String? id,
    required this.studentId,
    this.sessionTypeId,
    this.setId,
    this.occurrenceId,
    required this.overrideType,
    this.originalClassDateTime,
    this.replacementClassDateTime,
    this.durationMinutes,
    this.reason,
    required this.status,
    this.originalAttendanceId,
    this.replacementAttendanceId,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.version = 1,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  SessionOverride copyWith({
    String? id,
    String? studentId,
    String? sessionTypeId,
    String? setId,
    String? occurrenceId,
    OverrideType? overrideType,
    DateTime? originalClassDateTime,
    DateTime? replacementClassDateTime,
    int? durationMinutes,
    OverrideReason? reason,
    OverrideStatus? status,
    String? originalAttendanceId,
    String? replacementAttendanceId,
    DateTime? createdAt,
    DateTime? updatedAt,
    int? version,
  }) {
    return SessionOverride(
      id: id ?? this.id,
      studentId: studentId ?? this.studentId,
      sessionTypeId: sessionTypeId ?? this.sessionTypeId,
      setId: setId ?? this.setId,
      occurrenceId: occurrenceId ?? this.occurrenceId,
      overrideType: overrideType ?? this.overrideType,
      originalClassDateTime: originalClassDateTime ?? this.originalClassDateTime,
      replacementClassDateTime: replacementClassDateTime ?? this.replacementClassDateTime,
      durationMinutes: durationMinutes ?? this.durationMinutes,
      reason: reason ?? this.reason,
      status: status ?? this.status,
      originalAttendanceId: originalAttendanceId ?? this.originalAttendanceId,
      replacementAttendanceId: replacementAttendanceId ?? this.replacementAttendanceId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      version: version ?? this.version,
    );
  }

  static OverrideType _typeFromString(String s) {
    switch (s) {
      case 'skip':
        return OverrideType.skip;
      case 'replace':
        return OverrideType.replace;
      case 'add':
        return OverrideType.add;
      default:
        return OverrideType.add;
    }
  }

  // Public helpers for external use
  static OverrideType parseType(String s) => _typeFromString(s);
  static String typeToString(OverrideType t) => _typeToString(t);
  static OverrideStatus parseStatus(String s) => _statusFromString(s);
  static String statusToString(OverrideStatus s) => _statusToString(s);
  static OverrideReason? parseReason(String? s) => _reasonFromString(s);
  static String? reasonToString(OverrideReason? r) => _reasonToString(r);

  static String _typeToString(OverrideType t) {
    switch (t) {
      case OverrideType.skip:
        return 'skip';
      case OverrideType.replace:
        return 'replace';
      case OverrideType.add:
        return 'add';
    }
  }

  static OverrideStatus _statusFromString(String s) {
    switch (s) {
      case 'planned':
        return OverrideStatus.planned;
      case 'completed':
        return OverrideStatus.completed;
      case 'canceled':
        return OverrideStatus.canceled;
      default:
        return OverrideStatus.planned;
    }
  }

  static String _statusToString(OverrideStatus s) {
    switch (s) {
      case OverrideStatus.planned:
        return 'planned';
      case OverrideStatus.completed:
        return 'completed';
      case OverrideStatus.canceled:
        return 'canceled';
    }
  }

  static OverrideReason? _reasonFromString(String? s) {
    if (s == null) return null;
    switch (s) {
      case 'makeup':
        return OverrideReason.makeup;
      case 'holiday':
        return OverrideReason.holiday;
      case 'teacher':
        return OverrideReason.teacher;
      case 'other':
        return OverrideReason.other;
      default:
        return OverrideReason.other;
    }
  }

  static String? _reasonToString(OverrideReason? r) {
    if (r == null) return null;
    switch (r) {
      case OverrideReason.makeup:
        return 'makeup';
      case OverrideReason.holiday:
        return 'holiday';
      case OverrideReason.teacher:
        return 'teacher';
      case OverrideReason.other:
        return 'other';
    }
  }

  factory SessionOverride.fromMap(Map<String, dynamic> map) {
    return SessionOverride(
      id: map['id'] as String,
      studentId: map['student_id'] as String,
      sessionTypeId: map['session_type_id'] as String?,
      setId: map['set_id'] as String?,
      occurrenceId: map['occurrence_id']?.toString(),
      overrideType: _typeFromString(map['override_type'] as String),
      originalClassDateTime: map['original_class_datetime'] != null
          ? DateTime.parse(map['original_class_datetime'] as String)
          : null,
      replacementClassDateTime: map['replacement_class_datetime'] != null
          ? DateTime.parse(map['replacement_class_datetime'] as String)
          : null,
      durationMinutes: map['duration_minutes'] as int?,
      reason: _reasonFromString(map['reason'] as String?),
      status: _statusFromString(map['status'] as String),
      originalAttendanceId: map['original_attendance_id'] as String?,
      replacementAttendanceId: map['replacement_attendance_id'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
      version: (map['version'] is num) ? (map['version'] as num).toInt() : 1,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'student_id': studentId,
      'session_type_id': sessionTypeId,
      'set_id': setId,
      'occurrence_id': occurrenceId,
      'override_type': _typeToString(overrideType),
      'original_class_datetime': originalClassDateTime?.toIso8601String(),
      'replacement_class_datetime': replacementClassDateTime?.toIso8601String(),
      'duration_minutes': durationMinutes,
      'reason': _reasonToString(reason),
      'status': _statusToString(status),
      'original_attendance_id': originalAttendanceId,
      'replacement_attendance_id': replacementAttendanceId,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'version': version,
    };
  }
}


