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
  /// - null/빈값/알 수 없는 값 -> schedule (일반 메모 기본)
  /// - 한글 라벨('일정'/'상담'/'문의')도 지원
  static String normalize(String? raw) {
    final v = (raw ?? '').trim();
    if (v.isEmpty) return schedule;
    if (v == '일정') return schedule;
    if (v == '상담') return consult;
    if (v == '문의') return inquiry;
    if (v == schedule || v == consult || v == inquiry) return v;
    return schedule;
  }
}

/// `memoInquiryOriginalJoined` 형식의 original(전화:/학교·학년:/가능 요일·시간:) 여부.
bool memoOriginalLooksLikeFormInquiry(String original) {
  final t = original.trim();
  if (t.isEmpty) return false;
  return t.contains('전화:') ||
      t.contains('학교·학년:') ||
      t.contains('가능 요일·시간:');
}

/// 문의 탭에 올릴 메모. Supabase에 문의 전용 컬럼이 없으면 original만 남아도 목록에 유지.
bool memoIsFormInquiryForList(Memo m) {
  if (m.categoryKey != MemoCategory.inquiry) return false;
  if ((m.inquiryPhone ?? '').trim().isNotEmpty) return true;
  if ((m.inquirySchoolGrade ?? '').trim().isNotEmpty) return true;
  if ((m.inquiryAvailability ?? '').trim().isNotEmpty) return true;
  if ((m.inquiryNote ?? '').trim().isNotEmpty) return true;
  return memoOriginalLooksLikeFormInquiry(m.original);
}

/// 카드 표시: DB 컬럼 우선, 비어 있으면 original에서 파싱.
class MemoInquiryCardLines {
  final String contact;
  final String schoolGrade;
  final String availability;

  const MemoInquiryCardLines({
    required this.contact,
    required this.schoolGrade,
    required this.availability,
  });
}

MemoInquiryCardLines memoInquiryCardLines(Memo m) {
  var c = (m.inquiryPhone ?? '').trim();
  var sg = (m.inquirySchoolGrade ?? '').trim();
  var av = (m.inquiryAvailability ?? '').trim();
  if (c.isNotEmpty || sg.isNotEmpty || av.isNotEmpty) {
    return MemoInquiryCardLines(contact: c, schoolGrade: sg, availability: av);
  }
  final p = memoParseInquiryFromOriginal(m.original);
  return MemoInquiryCardLines(contact: p.$1, schoolGrade: p.$2, availability: p.$3);
}

(String phone, String schoolGrade, String availability) memoParseInquiryFromOriginal(
    String original) {
  var phone = '';
  var school = '';
  var avail = '';
  for (final raw in original.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('전화:')) {
      phone = line.substring('전화:'.length).trim();
    } else if (line.startsWith('학교·학년:')) {
      school = line.substring('학교·학년:'.length).trim();
    } else if (line.startsWith('가능 요일·시간:')) {
      avail = line.substring('가능 요일·시간:'.length).trim();
    }
  }
  return (phone, school, avail);
}

/// 문의 메모 카드 제목 한 줄 (전화 > 학교·학년 > 가능시간 > 메모 앞부분)
String memoInquirySummaryLine({
  required String phone,
  required String schoolGrade,
  required String availability,
  required String note,
}) {
  final p = phone.trim();
  if (p.isNotEmpty) return p;
  final s = schoolGrade.trim();
  if (s.isNotEmpty) return s;
  final a = availability.trim();
  if (a.isNotEmpty) return a;
  final n = note.trim();
  if (n.isNotEmpty) {
    return n.length > 48 ? '${n.substring(0, 48)}…' : n;
  }
  return '문의';
}

/// 저장/검색용 평문 (문의 전용)
String memoInquiryOriginalJoined({
  required String phone,
  required String schoolGrade,
  required String availability,
  required String note,
}) {
  final buf = <String>[];
  final p = phone.trim();
  final s = schoolGrade.trim();
  final a = availability.trim();
  final n = note.trim();
  if (p.isNotEmpty) buf.add('전화: $p');
  if (s.isNotEmpty) buf.add('학교·학년: $s');
  if (a.isNotEmpty) buf.add('가능 요일·시간: $a');
  if (n.isNotEmpty) buf.add('메모: $n');
  return buf.join('\n');
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
  // 문의(structured) — 일정/상담에서는 null
  final String? inquiryPhone;
  final String? inquirySchoolGrade;
  final String? inquiryAvailability;
  final String? inquiryNote;
  final int? inquirySortIndex;

  const Memo({
    required this.id,
    required this.original,
    required this.summary,
    this.categoryKey = MemoCategory.schedule,
    this.scheduledAt,
    this.dismissed = false,
    required this.createdAt,
    required this.updatedAt,
    this.recurrenceType,
    this.weekdays,
    this.recurrenceEnd,
    this.recurrenceCount,
    this.inquiryPhone,
    this.inquirySchoolGrade,
    this.inquiryAvailability,
    this.inquiryNote,
    this.inquirySortIndex,
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
    String? inquiryPhone,
    String? inquirySchoolGrade,
    String? inquiryAvailability,
    String? inquiryNote,
    int? inquirySortIndex,
  }) =>
      Memo(
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
        inquiryPhone: inquiryPhone ?? this.inquiryPhone,
        inquirySchoolGrade: inquirySchoolGrade ?? this.inquirySchoolGrade,
        inquiryAvailability: inquiryAvailability ?? this.inquiryAvailability,
        inquiryNote: inquiryNote ?? this.inquiryNote,
        inquirySortIndex: inquirySortIndex ?? this.inquirySortIndex,
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
        'inquiry_phone': inquiryPhone,
        'inquiry_school_grade': inquirySchoolGrade,
        'inquiry_availability': inquiryAvailability,
        'inquiry_note': inquiryNote,
        'inquiry_sort_index': inquirySortIndex,
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
        inquiryPhone: map['inquiry_phone'] as String?,
        inquirySchoolGrade: map['inquiry_school_grade'] as String?,
        inquiryAvailability: map['inquiry_availability'] as String?,
        inquiryNote: map['inquiry_note'] as String?,
        inquirySortIndex: map['inquiry_sort_index'] as int?,
      );
}

Memo memoNewPlain({
  required String id,
  required DateTime now,
  required String original,
  required String categoryKey,
  DateTime? scheduledAt,
  String summary = '요약 중...',
}) {
  return Memo(
    id: id,
    original: original.trim(),
    summary: summary,
    categoryKey: MemoCategory.normalize(categoryKey),
    scheduledAt: scheduledAt,
    dismissed: false,
    createdAt: now,
    updatedAt: now,
  );
}

Memo memoNewInquiry({
  required String id,
  required DateTime now,
  required String phone,
  required String schoolGrade,
  required String availability,
  required String note,
  required int sortIndex,
}) {
  final p = phone.trim();
  final s = schoolGrade.trim();
  final a = availability.trim();
  final n = note.trim();
  return Memo(
    id: id,
    original: memoInquiryOriginalJoined(
      phone: p,
      schoolGrade: s,
      availability: a,
      note: n,
    ),
    summary: memoInquirySummaryLine(
      phone: p,
      schoolGrade: s,
      availability: a,
      note: n,
    ),
    categoryKey: MemoCategory.inquiry,
    scheduledAt: null,
    dismissed: false,
    createdAt: now,
    updatedAt: now,
    inquiryPhone: p.isEmpty ? null : p,
    inquirySchoolGrade: s.isEmpty ? null : s,
    inquiryAvailability: a.isEmpty ? null : a,
    inquiryNote: n.isEmpty ? null : n,
    inquirySortIndex: sortIndex,
  );
}

/// 문의 탭 정렬: 위에서부터 오래된 순.
/// - `inquiry_sort_index` 없음(null): 레거시·상단 티어, 그 안에서는 `createdAt` 오름차순
/// - 인덱스 있음: 0,1,2… 오름차순(append·드래그 순서). null 티어 아래에 배치
int compareInquiryMemos(Memo a, Memo b) {
  final ai = a.inquirySortIndex;
  final bi = b.inquirySortIndex;
  final aHas = ai != null;
  final bHas = bi != null;
  if (aHas != bHas) {
    return aHas ? 1 : -1;
  }
  if (aHas && bHas && ai != bi) {
    return ai.compareTo(bi);
  }
  return a.createdAt.compareTo(b.createdAt);
}

