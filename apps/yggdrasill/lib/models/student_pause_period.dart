class StudentPausePeriod {
  final String id;
  final String academyId;
  final String studentId;
  final DateTime pausedFrom; // date-only (local)
  final DateTime? pausedTo; // date-only (local), null이면 휴원 진행중
  final DateTime? expectedResumeOn; // memo/display only
  final String? note;
  final int? snapshotCycle;
  final int? snapshotSessionCycle;
  final int? snapshotConsumedCount;
  final int? snapshotRemainingCount;

  StudentPausePeriod({
    required this.id,
    required this.academyId,
    required this.studentId,
    required this.pausedFrom,
    required this.pausedTo,
    this.expectedResumeOn,
    required this.note,
    this.snapshotCycle,
    this.snapshotSessionCycle,
    this.snapshotConsumedCount,
    this.snapshotRemainingCount,
  });

  bool get isOpen => pausedTo == null;

  static DateTime _parseDateOnly(dynamic v) {
    if (v == null) return DateTime(1970, 1, 1);
    if (v is DateTime) return DateTime(v.year, v.month, v.day);
    final s = v.toString();
    final dt = DateTime.tryParse(s);
    if (dt == null) return DateTime(1970, 1, 1);
    final local = dt.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  static DateTime? _parseDateOnlyOpt(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return DateTime(v.year, v.month, v.day);
    final dt = DateTime.tryParse(v.toString());
    if (dt == null) return null;
    final local = dt.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  static int? _parseIntOpt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  factory StudentPausePeriod.fromMap(Map<String, dynamic> m) {
    return StudentPausePeriod(
      id: (m['id'] ?? '').toString(),
      academyId: (m['academy_id'] ?? '').toString(),
      studentId: (m['student_id'] ?? '').toString(),
      pausedFrom: _parseDateOnly(m['paused_from']),
      pausedTo: _parseDateOnlyOpt(m['paused_to']),
      expectedResumeOn: _parseDateOnlyOpt(m['expected_resume_on']),
      note: (m['note'] as String?)?.toString(),
      snapshotCycle: _parseIntOpt(m['snapshot_cycle']),
      snapshotSessionCycle: _parseIntOpt(m['snapshot_session_cycle']),
      snapshotConsumedCount: _parseIntOpt(m['snapshot_consumed_count']),
      snapshotRemainingCount: _parseIntOpt(m['snapshot_remaining_count']),
    );
  }

  bool isActiveOn(DateTime dateLocal) {
    final d = DateTime(dateLocal.year, dateLocal.month, dateLocal.day);
    if (d.isBefore(pausedFrom)) return false;
    if (pausedTo == null) return true;
    return !d.isAfter(pausedTo!);
  }
}
