import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/academic_season.dart';
import '../models/education_level.dart';
import '../models/homework_learning_track.dart';
import '../models/season_roadmap_entry.dart';
import 'academy_db.dart';
import 'answer_key_service.dart';
import 'runtime_flags.dart';
import 'tag_preset_service.dart';
import 'tenant_service.dart';

class SeasonRoadmapService {
  SeasonRoadmapService._internal();
  static final SeasonRoadmapService instance = SeasonRoadmapService._internal();

  bool get _writeServer =>
      RuntimeFlags.serverOnly ||
      TagPresetService.preferSupabaseRead ||
      TagPresetService.dualWrite;
  bool get _writeLocal =>
      !RuntimeFlags.serverOnly &&
      (!TagPresetService.preferSupabaseRead || TagPresetService.dualWrite);

  static const List<_RoadmapSpec> _defaultSpecs = [
    _RoadmapSpec(AcademicSeasonCode.spring, EducationLevel.middle, 1, '1-1', 0),
    _RoadmapSpec(AcademicSeasonCode.spring, EducationLevel.middle, 2, '2-1', 0),
    _RoadmapSpec(AcademicSeasonCode.spring, EducationLevel.middle, 3, '3-1', 0),
    _RoadmapSpec(AcademicSeasonCode.spring, EducationLevel.high, 1, '공통수학1', 0),
    _RoadmapSpec(AcademicSeasonCode.spring, EducationLevel.high, 2, '대수', 0),
    _RoadmapSpec(AcademicSeasonCode.spring, EducationLevel.high, 2, '미적분1', 1),
    _RoadmapSpec(AcademicSeasonCode.fall, EducationLevel.middle, 1, '1-2', 0),
    _RoadmapSpec(AcademicSeasonCode.fall, EducationLevel.middle, 2, '2-2', 0),
    _RoadmapSpec(AcademicSeasonCode.fall, EducationLevel.middle, 3, '3-2', 0),
    _RoadmapSpec(AcademicSeasonCode.fall, EducationLevel.high, 1, '공통수학2', 0),
    _RoadmapSpec(AcademicSeasonCode.fall, EducationLevel.high, 2, '확률과 통계', 0),
    _RoadmapSpec(AcademicSeasonCode.fall, EducationLevel.high, 2, '미적분2', 1,
        isOptional: true),
    _RoadmapSpec(AcademicSeasonCode.fall, EducationLevel.high, 2, '기하', 2,
        isOptional: true),
  ];

  static List<SeasonRoadmapEntry> buildDefaultEntriesForYear(
    int seasonYear,
    Map<String, String> gradeKeyByLabel,
  ) {
    final normalizedKeys = _normalizeGradeKeyMap(gradeKeyByLabel);
    return _defaultSpecs.map((spec) {
      final labelKey = _normalizeLabel(spec.courseLabel);
      return SeasonRoadmapEntry(
        id: _defaultEntryId(
          seasonYear: seasonYear,
          seasonCode: spec.seasonCode,
          educationLevel: spec.educationLevel,
          grade: spec.grade,
          orderIndex: spec.orderIndex,
        ),
        seasonYear: seasonYear,
        seasonCode: spec.seasonCode,
        school: null,
        educationLevel: spec.educationLevel,
        grade: spec.grade,
        gradeKey: normalizedKeys[labelKey],
        courseLabelSnapshot: spec.courseLabel,
        isOptional: spec.isOptional,
        orderIndex: spec.orderIndex,
        note: null,
        updatedAt: DateTime.now().toUtc(),
      );
    }).toList();
  }

  static List<SeasonRoadmapEntry> resolveGradeKeys(
    List<SeasonRoadmapEntry> entries,
    Map<String, String> gradeKeyByLabel,
  ) {
    final normalizedKeys = _normalizeGradeKeyMap(gradeKeyByLabel);
    return entries.map((entry) {
      final resolvedKey =
          normalizedKeys[_normalizeLabel(entry.courseLabelSnapshot)];
      if (resolvedKey == entry.gradeKey) return entry;
      return entry.copyWith(
        gradeKey: resolvedKey,
        clearGradeKey: resolvedKey == null,
        updatedAt: DateTime.now().toUtc(),
      );
    }).toList();
  }

  static HomeworkLearningTrack classifyLearningTrack({
    required DateTime referenceDate,
    required EducationLevel educationLevel,
    required int grade,
    required String courseLabel,
    required Iterable<SeasonRoadmapEntry> roadmapEntries,
  }) {
    final label = _normalizeLabel(courseLabel);
    if (label.isEmpty) return HomeworkLearningTrack.extra;
    if (educationLevel == EducationLevel.elementary) {
      return roadmapEntries.any((entry) {
        return _normalizeLabel(entry.courseLabelSnapshot) == label;
      })
          ? HomeworkLearningTrack.preLearning
          : HomeworkLearningTrack.extra;
    }
    if (educationLevel == EducationLevel.high && grade >= 3) {
      final matches = roadmapEntries.where((entry) {
        return _normalizeLabel(entry.courseLabelSnapshot) == label;
      }).toList();
      if (matches.isEmpty) return HomeworkLearningTrack.extra;
      final isHighSecondGradeCourse = matches.any((entry) {
        return entry.educationLevel == EducationLevel.high && entry.grade == 2;
      });
      return isHighSecondGradeCourse
          ? HomeworkLearningTrack.current
          : HomeworkLearningTrack.foundational;
    }
    final currentSeason = AcademicSeason.fromDate(referenceDate);
    final currentOrder = _absoluteSeasonOrder(currentSeason);
    final matches = roadmapEntries.where((entry) {
      if (entry.educationLevel != educationLevel) return false;
      if (entry.grade != grade) return false;
      return _normalizeLabel(entry.courseLabelSnapshot) == label;
    }).toList();
    if (matches.isEmpty) return HomeworkLearningTrack.extra;

    final sameSeason = matches.any((entry) {
      return _absoluteSeasonOrder(entry.season) == currentOrder;
    });
    if (sameSeason) return HomeworkLearningTrack.current;

    final hasFuture = matches.any((entry) {
      return _absoluteSeasonOrder(entry.season) > currentOrder;
    });
    if (hasFuture) return HomeworkLearningTrack.preLearning;

    return HomeworkLearningTrack.foundational;
  }

  static HomeworkLearningTrack classifyDefaultLearningTrack({
    required DateTime referenceDate,
    required EducationLevel educationLevel,
    required int grade,
    required String courseLabel,
  }) {
    final year = referenceDate.year;
    final entries = buildDefaultEntriesForYear(year, const <String, String>{});
    return classifyLearningTrack(
      referenceDate: referenceDate,
      educationLevel: educationLevel,
      grade: grade,
      courseLabel: courseLabel,
      roadmapEntries: entries,
    );
  }

  Future<List<SeasonRoadmapEntry>> loadRoadmapForYear(int seasonYear) async {
    final stored = await _loadStoredRoadmapForYear(seasonYear);
    final gradeKeys = await _loadGradeKeyByLabel();
    final entriesById = <String, SeasonRoadmapEntry>{
      for (final entry in stored) entry.id: entry,
    };

    var changed = false;
    for (final entry in buildDefaultEntriesForYear(seasonYear, gradeKeys)) {
      if (!entriesById.containsKey(entry.id)) {
        entriesById[entry.id] = entry;
        changed = true;
      }
    }

    final resolved = resolveGradeKeys(entriesById.values.toList(), gradeKeys);
    for (final entry in resolved) {
      final before = entriesById[entry.id];
      if (before == null || before.gradeKey != entry.gradeKey) {
        changed = true;
      }
      entriesById[entry.id] = entry;
    }

    final list = _sortEntries(entriesById.values.toList());
    if (changed && list.isNotEmpty) {
      await upsertRoadmapEntries(list);
    }
    return list;
  }

  Future<List<SeasonRoadmapEntry>> lookupRoadmap({
    required int seasonYear,
    required AcademicSeasonCode seasonCode,
    required String? school,
    required EducationLevel educationLevel,
    required int grade,
  }) async {
    final entries = await loadRoadmapForYear(seasonYear);
    final schoolValue = (school ?? '').trim();
    final candidates = entries.where((entry) {
      if (entry.seasonCode != seasonCode) return false;
      if (entry.educationLevel != educationLevel) return false;
      if (entry.grade != grade) return false;
      final entrySchool = (entry.school ?? '').trim();
      return entrySchool.isEmpty || entrySchool == schoolValue;
    }).toList();
    final schoolSpecific = candidates
        .where((entry) => (entry.school ?? '').trim() == schoolValue)
        .toList();
    return _sortEntries(
      schoolValue.isNotEmpty && schoolSpecific.isNotEmpty
          ? schoolSpecific
          : candidates
              .where((entry) => (entry.school ?? '').trim().isEmpty)
              .toList(),
    );
  }

  Future<void> upsertRoadmapEntries(List<SeasonRoadmapEntry> entries) async {
    if (entries.isEmpty) return;
    if (_writeLocal) {
      await AcademyDbService.instance.upsertSeasonRoadmapEntries(
        entries.map((entry) => entry.toLocalRow()).toList(),
      );
    }
    if (_writeServer) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ??
            await TenantService.instance.ensureActiveAcademy();
        final rows =
            entries.map((entry) => entry.toRemoteRow(academyId)).toList();
        await Supabase.instance.client
            .from('season_roadmap_entries')
            .upsert(rows, onConflict: 'academy_id,id');
      } catch (e, st) {
        // ignore: avoid_print
        print('[SeasonRoadmap][save] supabase write failed: $e\n$st');
        if (RuntimeFlags.serverOnly) rethrow;
      }
    }
  }

  Future<List<SeasonRoadmapEntry>> _loadStoredRoadmapForYear(
      int seasonYear) async {
    if (TagPresetService.preferSupabaseRead) {
      try {
        final academyId = await TenantService.instance.getActiveAcademyId() ??
            await TenantService.instance.ensureActiveAcademy();
        final data = await Supabase.instance.client
            .from('season_roadmap_entries')
            .select(
              'id,season_year,season_code,school,education_level,grade,grade_key,course_label_snapshot,is_optional,order_index,note,updated_at',
            )
            .eq('academy_id', academyId)
            .eq('season_year', seasonYear);
        final rows = (data as List).cast<Map<String, dynamic>>();
        if (rows.isNotEmpty) {
          return _sortEntries(
            rows.map(SeasonRoadmapEntry.fromRow).toList(),
          );
        }
      } catch (e, st) {
        // ignore: avoid_print
        print('[SeasonRoadmap][load] supabase load failed: $e\n$st');
        if (RuntimeFlags.serverOnly) return <SeasonRoadmapEntry>[];
      }
    }

    if (RuntimeFlags.serverOnly) return <SeasonRoadmapEntry>[];
    final localRows = await AcademyDbService.instance
        .loadSeasonRoadmapEntriesForYear(seasonYear);
    final local =
        localRows.map((row) => SeasonRoadmapEntry.fromRow(row)).toList();
    if (TagPresetService.preferSupabaseRead && local.isNotEmpty) {
      await upsertRoadmapEntries(local);
    }
    return _sortEntries(local);
  }

  Future<Map<String, String>> _loadGradeKeyByLabel() async {
    final rows = await AnswerKeyService.instance.loadAnswerKeyGrades();
    final out = <String, String>{};
    for (final row in rows) {
      final label = (row['label'] ?? '').toString().trim();
      final key = (row['grade_key'] ?? '').toString().trim();
      if (label.isEmpty || key.isEmpty) continue;
      out[label] = key;
    }
    return out;
  }

  static List<SeasonRoadmapEntry> _sortEntries(
      List<SeasonRoadmapEntry> entries) {
    entries.sort((a, b) {
      final season = a.season.sortOrder.compareTo(b.season.sortOrder);
      if (season != 0) return season;
      final level = a.educationLevel.index.compareTo(b.educationLevel.index);
      if (level != 0) return level;
      final grade = a.grade.compareTo(b.grade);
      if (grade != 0) return grade;
      return a.orderIndex.compareTo(b.orderIndex);
    });
    return entries;
  }

  static Map<String, String> _normalizeGradeKeyMap(
      Map<String, String> gradeKeyByLabel) {
    return {
      for (final item in gradeKeyByLabel.entries)
        _normalizeLabel(item.key): item.value,
    };
  }

  static String _normalizeLabel(String value) => value.trim();

  static int _absoluteSeasonOrder(AcademicSeason season) {
    return season.year * AcademicSeasonCode.values.length + season.sortOrder;
  }

  static String _defaultEntryId({
    required int seasonYear,
    required AcademicSeasonCode seasonCode,
    required EducationLevel educationLevel,
    required int grade,
    required int orderIndex,
  }) {
    return 'default-$seasonYear-${seasonCode.shortCode}-${educationLevel.index}-$grade-$orderIndex';
  }
}

class _RoadmapSpec {
  final AcademicSeasonCode seasonCode;
  final EducationLevel educationLevel;
  final int grade;
  final String courseLabel;
  final int orderIndex;
  final bool isOptional;

  const _RoadmapSpec(
    this.seasonCode,
    this.educationLevel,
    this.grade,
    this.courseLabel,
    this.orderIndex, {
    this.isOptional = false,
  });
}
