class StudentPausePeriod {
  final String id;
  final String academyId;
  final String studentId;
  final DateTime pausedFrom; // date-only (local)
  final DateTime? pausedTo; // date-only (local), null이면 휴원 진행중
  final String? note;

  StudentPausePeriod({
    required this.id,
    required this.academyId,
    required this.studentId,
    required this.pausedFrom,
    required this.pausedTo,
    required this.note,
  });

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

  factory StudentPausePeriod.fromMap(Map<String, dynamic> m) {
    return StudentPausePeriod(
      id: (m['id'] ?? '').toString(),
      academyId: (m['academy_id'] ?? '').toString(),
      studentId: (m['student_id'] ?? '').toString(),
      pausedFrom: _parseDateOnly(m['paused_from']),
      pausedTo: _parseDateOnlyOpt(m['paused_to']),
      note: (m['note'] as String?)?.toString(),
    );
  }

  bool isActiveOn(DateTime dateLocal) {
    final d = DateTime(dateLocal.year, dateLocal.month, dateLocal.day);
    if (d.isBefore(pausedFrom)) return false;
    if (pausedTo == null) return true;
    return !d.isAfter(pausedTo!);
  }
}

