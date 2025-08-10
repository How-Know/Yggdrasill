class Memo {
  final String id;
  final String original;
  final String summary;
  final DateTime? scheduledAt;
  final bool dismissed;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Memo({
    required this.id,
    required this.original,
    required this.summary,
    this.scheduledAt,
    this.dismissed = false,
    required this.createdAt,
    required this.updatedAt,
  });

  Memo copyWith({
    String? id,
    String? original,
    String? summary,
    DateTime? scheduledAt,
    bool? dismissed,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => Memo(
        id: id ?? this.id,
        original: original ?? this.original,
        summary: summary ?? this.summary,
        scheduledAt: scheduledAt ?? this.scheduledAt,
        dismissed: dismissed ?? this.dismissed,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'original': original,
        'summary': summary,
        'scheduled_at': scheduledAt?.toIso8601String(),
        'dismissed': dismissed ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
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
      );
}


