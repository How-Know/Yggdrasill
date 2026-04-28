import 'academic_season.dart';
import 'education_level.dart';

class SeasonRoadmapEntry {
  final String id;
  final int seasonYear;
  final AcademicSeasonCode seasonCode;
  final String? school;
  final EducationLevel educationLevel;
  final int grade;
  final String? gradeKey;
  final String courseLabelSnapshot;
  final bool isOptional;
  final int orderIndex;
  final String? note;
  final DateTime? updatedAt;

  const SeasonRoadmapEntry({
    required this.id,
    required this.seasonYear,
    required this.seasonCode,
    required this.school,
    required this.educationLevel,
    required this.grade,
    required this.gradeKey,
    required this.courseLabelSnapshot,
    required this.isOptional,
    required this.orderIndex,
    required this.note,
    required this.updatedAt,
  });

  bool get hasLinkedCourse => (gradeKey ?? '').trim().isNotEmpty;

  String get targetLabel => '${getEducationLevelName(educationLevel)} $grade학년';

  AcademicSeason get season =>
      AcademicSeason(year: seasonYear, code: seasonCode);

  SeasonRoadmapEntry copyWith({
    String? id,
    int? seasonYear,
    AcademicSeasonCode? seasonCode,
    String? school,
    bool clearSchool = false,
    EducationLevel? educationLevel,
    int? grade,
    String? gradeKey,
    bool clearGradeKey = false,
    String? courseLabelSnapshot,
    bool? isOptional,
    int? orderIndex,
    String? note,
    bool clearNote = false,
    DateTime? updatedAt,
  }) {
    return SeasonRoadmapEntry(
      id: id ?? this.id,
      seasonYear: seasonYear ?? this.seasonYear,
      seasonCode: seasonCode ?? this.seasonCode,
      school: clearSchool ? null : (school ?? this.school),
      educationLevel: educationLevel ?? this.educationLevel,
      grade: grade ?? this.grade,
      gradeKey: clearGradeKey ? null : (gradeKey ?? this.gradeKey),
      courseLabelSnapshot: courseLabelSnapshot ?? this.courseLabelSnapshot,
      isOptional: isOptional ?? this.isOptional,
      orderIndex: orderIndex ?? this.orderIndex,
      note: clearNote ? null : (note ?? this.note),
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toLocalRow() => {
        'id': id,
        'season_year': seasonYear,
        'season_code': seasonCode.shortCode,
        'school': school,
        'education_level': educationLevel.index,
        'grade': grade,
        'grade_key': gradeKey,
        'course_label_snapshot': courseLabelSnapshot,
        'is_optional': isOptional ? 1 : 0,
        'order_index': orderIndex,
        'note': note,
        'updated_at': (updatedAt ?? DateTime.now()).toUtc().toIso8601String(),
      };

  Map<String, dynamic> toRemoteRow(String academyId) => {
        ...toLocalRow(),
        'academy_id': academyId,
        'is_optional': isOptional,
      };

  factory SeasonRoadmapEntry.fromRow(Map<String, dynamic> row) {
    int asInt(dynamic value, [int fallback = 0]) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return int.tryParse((value ?? '').toString()) ?? fallback;
    }

    bool asBool(dynamic value) {
      if (value is bool) return value;
      if (value is int) return value != 0;
      if (value is num) return value != 0;
      return value.toString().toLowerCase() == 'true';
    }

    DateTime? asDate(dynamic value) {
      final text = (value ?? '').toString().trim();
      if (text.isEmpty) return null;
      return DateTime.tryParse(text);
    }

    final levelIndex = asInt(row['education_level']);
    final safeLevelIndex =
        levelIndex.clamp(0, EducationLevel.values.length - 1).toInt();

    return SeasonRoadmapEntry(
      id: (row['id'] ?? '').toString(),
      seasonYear: asInt(row['season_year']),
      seasonCode: AcademicSeasonCode.fromShortCode(
          (row['season_code'] ?? '').toString()),
      school: _nullableText(row['school']),
      educationLevel: EducationLevel.values[safeLevelIndex],
      grade: asInt(row['grade']),
      gradeKey: _nullableText(row['grade_key']),
      courseLabelSnapshot:
          (row['course_label_snapshot'] ?? '').toString().trim(),
      isOptional: asBool(row['is_optional']),
      orderIndex: asInt(row['order_index']),
      note: _nullableText(row['note']),
      updatedAt: asDate(row['updated_at']),
    );
  }

  static String? _nullableText(dynamic value) {
    final text = (value ?? '').toString().trim();
    return text.isEmpty ? null : text;
  }
}
