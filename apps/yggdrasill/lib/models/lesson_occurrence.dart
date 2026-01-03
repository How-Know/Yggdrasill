/// 고정된 "원본 회차(occurrence)" 모델
///
/// 목적:
/// - 사이클 내 회차(sessionOrder)와 원본 시간(originalClassDateTime)을 영구 고정
/// - 보강(replace)은 같은 occurrence를 다른 시간에 수행하더라도 cycle/sessionOrder가 흔들리지 않게 함
/// - 추가수업(add)은 kind='extra' occurrence로 저장하여 사이클 집계에서 별도로 분리 가능
class LessonOccurrence {
  final String id;
  final String studentId;
  final String kind; // 'regular' | 'extra'
  final int cycle;
  final int? sessionOrder;
  final DateTime originalClassDateTime;
  final DateTime? originalClassEndTime;
  final int? durationMinutes;
  final String? sessionTypeId;
  final String? setId;
  final String? snapshotId;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final int? version;

  const LessonOccurrence({
    required this.id,
    required this.studentId,
    required this.kind,
    required this.cycle,
    this.sessionOrder,
    required this.originalClassDateTime,
    this.originalClassEndTime,
    this.durationMinutes,
    this.sessionTypeId,
    this.setId,
    this.snapshotId,
    this.createdAt,
    this.updatedAt,
    this.version,
  });

  static DateTime? _parseTsOpt(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    if (v is String) return DateTime.tryParse(v);
    return null;
  }

  static int? _parseIntOpt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  factory LessonOccurrence.fromMap(Map<String, dynamic> map) {
    final id = map['id']?.toString() ?? '';
    final studentId = map['student_id']?.toString() ?? '';
    final kind = (map['kind']?.toString() ?? 'regular').trim();
    final cycle = _parseIntOpt(map['cycle']) ?? 0;

    final originalDt = _parseTsOpt(map['original_class_datetime']);
    if (id.isEmpty || studentId.isEmpty || originalDt == null || cycle <= 0) {
      throw ArgumentError('Invalid LessonOccurrence map: id=$id student_id=$studentId cycle=$cycle original=$originalDt');
    }

    return LessonOccurrence(
      id: id,
      studentId: studentId,
      kind: kind.isEmpty ? 'regular' : kind,
      cycle: cycle,
      sessionOrder: _parseIntOpt(map['session_order']),
      originalClassDateTime: originalDt,
      originalClassEndTime: _parseTsOpt(map['original_class_end_time']),
      durationMinutes: _parseIntOpt(map['duration_minutes']),
      sessionTypeId: map['session_type_id']?.toString(),
      setId: map['set_id']?.toString(),
      snapshotId: map['snapshot_id']?.toString(),
      createdAt: _parseTsOpt(map['created_at']),
      updatedAt: _parseTsOpt(map['updated_at']),
      version: _parseIntOpt(map['version']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'student_id': studentId,
      'kind': kind,
      'cycle': cycle,
      'session_order': sessionOrder,
      'original_class_datetime': originalClassDateTime.toIso8601String(),
      'original_class_end_time': originalClassEndTime?.toIso8601String(),
      'duration_minutes': durationMinutes,
      'session_type_id': sessionTypeId,
      'set_id': setId,
      'snapshot_id': snapshotId,
      'created_at': createdAt?.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
      'version': version,
    }..removeWhere((k, v) => v == null);
  }
}


