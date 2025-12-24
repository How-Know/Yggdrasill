class MemoCategory {
  // 저장 키(영문)로 유지: DB/서버 스키마 안정성을 위해 label과 분리
  static const String schedule = 'schedule'; // 일정
  static const String consult = 'consult'; // 상담(신규 등록/체험 등)
  static const String inquiry = 'inquiry'; // 문의(재원생/학부모)

  static const List<String> all = <String>[schedule, consult, inquiry];

  static String labelOf(String key) {
    switch (key) {
      case schedule:
        return '일정';
      case consult:
        return '상담';
      case inquiry:
      default:
        return '문의';
    }
  }

  /// DB/AI/사용자 입력에서 들어온 값을 안전하게 키로 정규화.
  /// - null/빈값/알 수 없는 값 -> inquiry
  /// - 한글 라벨('일정'/'상담'/'문의')도 지원
  static String normalize(String? raw) {
    final v = (raw ?? '').trim();
    if (v.isEmpty) return inquiry;
    if (v == '일정') return schedule;
    if (v == '상담') return consult;
    if (v == '문의') return inquiry;
    if (v == schedule || v == consult || v == inquiry) return v;
    return inquiry;
  }
}

class Memo {
  final String id;
  final String original;
  final String summary;
  final String categoryKey; // schedule|consult|inquiry
  final DateTime? scheduledAt;
  final bool dismissed;
  final DateTime createdAt;
  final DateTime updatedAt;
  // 반복 정보
  final String? recurrenceType; // daily/weekly/monthly/selected_weekdays
  final List<int>? weekdays; // 1=Mon..7=Sun for selected_weekdays
  final DateTime? recurrenceEnd; // 종료일 (없으면 무기한)
  final int? recurrenceCount; // 종료 횟수 (없으면 무제한)

  const Memo({
    required this.id,
    required this.original,
    required this.summary,
    this.categoryKey = MemoCategory.inquiry,
    this.scheduledAt,
    this.dismissed = false,
    required this.createdAt,
    required this.updatedAt,
    this.recurrenceType,
    this.weekdays,
    this.recurrenceEnd,
    this.recurrenceCount,
  });

  Memo copyWith({
    String? id,
    String? original,
    String? summary,
    String? categoryKey,
    DateTime? scheduledAt,
    bool? dismissed,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? recurrenceType,
    List<int>? weekdays,
    DateTime? recurrenceEnd,
    int? recurrenceCount,
  }) => Memo(
        id: id ?? this.id,
        original: original ?? this.original,
        summary: summary ?? this.summary,
        categoryKey: categoryKey ?? this.categoryKey,
        scheduledAt: scheduledAt ?? this.scheduledAt,
        dismissed: dismissed ?? this.dismissed,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        recurrenceType: recurrenceType ?? this.recurrenceType,
        weekdays: weekdays ?? this.weekdays,
        recurrenceEnd: recurrenceEnd ?? this.recurrenceEnd,
        recurrenceCount: recurrenceCount ?? this.recurrenceCount,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'original': original,
        'summary': summary,
        'category': categoryKey,
        'scheduled_at': scheduledAt?.toIso8601String(),
        'dismissed': dismissed ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        'recurrence_type': recurrenceType,
        'weekdays': weekdays == null ? null : weekdays!.join(','),
        'recurrence_end': recurrenceEnd?.toIso8601String(),
        'recurrence_count': recurrenceCount,
      };

  static Memo fromMap(Map<String, dynamic> map) => Memo(
        id: map['id'] as String,
        original: map['original'] as String? ?? '',
        summary: map['summary'] as String? ?? '',
        categoryKey: MemoCategory.normalize(map['category'] as String?),
        scheduledAt: map['scheduled_at'] != null && (map['scheduled_at'] as String).isNotEmpty
            ? DateTime.tryParse(map['scheduled_at'] as String)
            : null,
        dismissed: (map['dismissed'] as int? ?? 0) == 1,
        createdAt: DateTime.tryParse(map['created_at'] as String? ?? '') ?? DateTime.now(),
        updatedAt: DateTime.tryParse(map['updated_at'] as String? ?? '') ?? DateTime.now(),
        recurrenceType: map['recurrence_type'] as String?,
        weekdays: (map['weekdays'] as String?)?.split(',').where((e) => e.isNotEmpty).map(int.parse).toList(),
        recurrenceEnd: map['recurrence_end'] != null && (map['recurrence_end'] as String).isNotEmpty
            ? DateTime.tryParse(map['recurrence_end'] as String)
            : null,
        recurrenceCount: map['recurrence_count'] as int?,
      );
}


