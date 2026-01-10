class StudentChargePoint {
  final String id;
  final String academyId;
  final String studentId;
  final int cycle;
  final String? chargePointOccurrenceId;
  final DateTime? chargePointDateTime; // local
  final DateTime? nextDueDateTime; // local (다음 수강 예정일)
  final DateTime? computedAt; // local

  StudentChargePoint({
    required this.id,
    required this.academyId,
    required this.studentId,
    required this.cycle,
    required this.chargePointOccurrenceId,
    required this.chargePointDateTime,
    required this.nextDueDateTime,
    required this.computedAt,
  });

  static DateTime? _parseTsOpt(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v.toLocal();
    final dt = DateTime.tryParse(v.toString());
    return dt?.toLocal();
  }

  factory StudentChargePoint.fromMap(Map<String, dynamic> m) {
    int asInt(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v?.toString() ?? '') ?? 0;
    }

    return StudentChargePoint(
      id: (m['id'] ?? '').toString(),
      academyId: (m['academy_id'] ?? '').toString(),
      studentId: (m['student_id'] ?? '').toString(),
      cycle: asInt(m['cycle']),
      chargePointOccurrenceId: m['charge_point_occurrence_id']?.toString(),
      chargePointDateTime: _parseTsOpt(m['charge_point_datetime']),
      nextDueDateTime: _parseTsOpt(m['next_due_datetime']),
      computedAt: _parseTsOpt(m['computed_at']),
    );
  }
}

