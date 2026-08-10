/// 학생앱 온라인 presence (학원 등원중 / 집).
class StudentAppPresence {
  const StudentAppPresence({
    required this.studentId,
    required this.isOnline,
    required this.lastSeen,
    required this.locationKind,
  });

  final String studentId;
  final bool isOnline;
  final DateTime lastSeen;
  /// `academy` | `home` | `unknown`
  final String locationKind;

  /// 하트비트 주기(25s)보다 여유 있게 — 이보다 오래되면 오프라인으로 본다.
  static const Duration staleAfter = Duration(seconds: 90);

  bool get isEffectivelyOnline {
    if (!isOnline) return false;
    return DateTime.now().toUtc().difference(lastSeen.toUtc()) <= staleAfter;
  }

  bool get isAtAcademy => locationKind == 'academy';
  bool get isAtHome => locationKind == 'home';

  /// UI 라벨: `앱, 학원` / `앱, 집` / `앱`
  String get badgeLabel {
    if (isAtAcademy) return '앱, 학원';
    if (isAtHome) return '앱, 집';
    return '앱';
  }

  static StudentAppPresence? fromRow(Map<String, dynamic> row) {
    final id = (row['student_id'] as String?)?.trim() ?? '';
    if (id.isEmpty) return null;
    final seenRaw = row['last_seen'];
    final seen = seenRaw == null
        ? DateTime.now().toUtc()
        : DateTime.tryParse(seenRaw.toString())?.toUtc() ??
            DateTime.now().toUtc();
    final kind = '${row['location_kind'] ?? 'unknown'}'.trim();
    return StudentAppPresence(
      studentId: id,
      isOnline: row['is_online'] == true,
      lastSeen: seen,
      locationKind: kind.isEmpty ? 'unknown' : kind,
    );
  }
}
