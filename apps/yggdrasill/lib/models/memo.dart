class Memo {
  final String id;
  final String original;
  final String summary;
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


