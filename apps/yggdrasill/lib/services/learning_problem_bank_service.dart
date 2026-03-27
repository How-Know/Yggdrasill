import 'package:supabase_flutter/supabase_flutter.dart';

class LearningProblemChoice {
  const LearningProblemChoice({
    required this.label,
    required this.text,
  });

  final String label;
  final String text;

  factory LearningProblemChoice.fromDynamic(dynamic value) {
    final map = _mapOrEmpty(value);
    return LearningProblemChoice(
      label: '${map['label'] ?? ''}'.trim(),
      text: '${map['text'] ?? ''}'.trim(),
    );
  }
}

class LearningProblemEquation {
  const LearningProblemEquation({
    required this.token,
    required this.raw,
    required this.latex,
  });

  final String token;
  final String raw;
  final String latex;

  factory LearningProblemEquation.fromDynamic(dynamic value) {
    final map = _mapOrEmpty(value);
    return LearningProblemEquation(
      token: '${map['token'] ?? ''}'.trim(),
      raw: '${map['raw'] ?? ''}'.trim(),
      latex: '${map['latex'] ?? ''}'.trim(),
    );
  }

  String get bestText => latex.isNotEmpty ? latex : raw;
}

class LearningProblemQuestion {
  const LearningProblemQuestion({
    required this.id,
    required this.documentId,
    required this.questionNumber,
    required this.questionType,
    required this.stem,
    required this.choices,
    required this.objectiveChoices,
    required this.equations,
    required this.sourcePage,
    required this.sourceOrder,
    required this.curriculumCode,
    required this.sourceTypeCode,
    required this.courseLabel,
    required this.gradeLabel,
    required this.examYear,
    required this.semesterLabel,
    required this.examTermLabel,
    required this.schoolName,
    required this.publisherName,
    required this.materialName,
    required this.confidence,
    required this.meta,
    required this.createdAt,
    required this.documentSourceName,
  });

  final String id;
  final String documentId;
  final String questionNumber;
  final String questionType;
  final String stem;
  final List<LearningProblemChoice> choices;
  final List<LearningProblemChoice> objectiveChoices;
  final List<LearningProblemEquation> equations;
  final int sourcePage;
  final int sourceOrder;
  final String curriculumCode;
  final String sourceTypeCode;
  final String courseLabel;
  final String gradeLabel;
  final int? examYear;
  final String semesterLabel;
  final String examTermLabel;
  final String schoolName;
  final String publisherName;
  final String materialName;
  final double confidence;
  final Map<String, dynamic> meta;
  final DateTime? createdAt;
  final String documentSourceName;

  String get displayQuestionNumber {
    final normalized = questionNumber.trim();
    if (normalized.isNotEmpty) return normalized;
    final fallbackOrder = sourceOrder > 0 ? sourceOrder : sourceOrder + 1;
    return '$fallbackOrder';
  }

  List<LearningProblemChoice> get effectiveChoices =>
      objectiveChoices.isNotEmpty ? objectiveChoices : choices;

  String get renderedStem => _renderTextWithEquation(stem, equations);

  String renderChoiceText(LearningProblemChoice choice) {
    return _renderTextWithEquation(choice.text, equations);
  }

  factory LearningProblemQuestion.fromMap(
    Map<String, dynamic> map, {
    required String documentSourceName,
  }) {
    final choices = _listOrEmpty(map['choices'])
        .map((e) => LearningProblemChoice.fromDynamic(e))
        .toList(growable: false);
    final objectiveChoices = _listOrEmpty(map['objective_choices'])
        .map((e) => LearningProblemChoice.fromDynamic(e))
        .toList(growable: false);
    final equations = _listOrEmpty(map['equations'])
        .map((e) => LearningProblemEquation.fromDynamic(e))
        .toList(growable: false);
    final meta = _mapOrEmpty(map['meta']);
    return LearningProblemQuestion(
      id: '${map['id'] ?? ''}',
      documentId: '${map['document_id'] ?? ''}',
      questionNumber: '${map['question_number'] ?? ''}',
      questionType: '${map['question_type'] ?? ''}',
      stem: '${map['stem'] ?? ''}',
      choices: choices,
      objectiveChoices: objectiveChoices,
      equations: equations,
      sourcePage: _intOrZero(map['source_page']),
      sourceOrder: _intOrZero(map['source_order']),
      curriculumCode: '${map['curriculum_code'] ?? ''}',
      sourceTypeCode: '${map['source_type_code'] ?? ''}',
      courseLabel: '${map['course_label'] ?? ''}',
      gradeLabel: '${map['grade_label'] ?? ''}',
      examYear: _intOrNull(map['exam_year']),
      semesterLabel: '${map['semester_label'] ?? ''}',
      examTermLabel: '${map['exam_term_label'] ?? ''}',
      schoolName: '${map['school_name'] ?? ''}',
      publisherName: '${map['publisher_name'] ?? ''}',
      materialName: '${map['material_name'] ?? ''}',
      confidence: _doubleOrZero(map['confidence']),
      meta: meta,
      createdAt: _dateTimeOrNull(map['created_at']),
      documentSourceName: documentSourceName,
    );
  }
}

class LearningProblemBankService {
  LearningProblemBankService({
    SupabaseClient? client,
  }) : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Future<List<String>> listSchoolsForSchoolPast({
    required String academyId,
    required String curriculumCode,
    required String schoolLevel,
    required String detailedCourse,
    int limit = 2000,
  }) async {
    final rows = await _client
        .from('pb_documents')
        .select(
          'school_name,course_label,grade_label,source_type_code,curriculum_code',
        )
        .eq('academy_id', academyId)
        .eq('curriculum_code', curriculumCode)
        .eq('source_type_code', 'school_past')
        .limit(limit);

    final out = <String>{};
    for (final item in (rows as List<dynamic>)) {
      final row = _mapOrEmpty(item);
      final schoolName = '${row['school_name'] ?? ''}'.trim();
      if (schoolName.isEmpty) continue;
      final courseLabel = '${row['course_label'] ?? ''}'.trim();
      final gradeLabel = '${row['grade_label'] ?? ''}'.trim();
      if (!_matchesLevel(schoolLevel, courseLabel, gradeLabel)) continue;
      if (!_matchesDetailedCourse(detailedCourse, courseLabel, gradeLabel)) {
        continue;
      }
      out.add(schoolName);
    }
    return out.toList(growable: false);
  }

  Future<List<LearningProblemQuestion>> searchQuestions({
    required String academyId,
    required String curriculumCode,
    required String schoolLevel,
    required String detailedCourse,
    required String sourceTypeCode,
    String? schoolName,
    int limit = 400,
  }) async {
    var q = _client
        .from('pb_questions')
        .select(
          [
            'id',
            'document_id',
            'question_number',
            'question_type',
            'stem',
            'choices',
            'objective_choices',
            'equations',
            'source_page',
            'source_order',
            'curriculum_code',
            'source_type_code',
            'course_label',
            'grade_label',
            'exam_year',
            'semester_label',
            'exam_term_label',
            'school_name',
            'publisher_name',
            'material_name',
            'confidence',
            'meta',
            'created_at',
          ].join(','),
        )
        .eq('academy_id', academyId)
        .eq('curriculum_code', curriculumCode)
        .eq('source_type_code', sourceTypeCode);

    final safeSchoolName = (schoolName ?? '').trim();
    if (safeSchoolName.isNotEmpty) {
      q = q.eq('school_name', safeSchoolName);
    }

    final rows = await q.order('created_at', ascending: false).limit(limit);
    final list =
        (rows as List<dynamic>).map((e) => _mapOrEmpty(e)).where((row) {
      final courseLabel = '${row['course_label'] ?? ''}'.trim();
      final gradeLabel = '${row['grade_label'] ?? ''}'.trim();
      if (!_matchesLevel(schoolLevel, courseLabel, gradeLabel)) {
        return false;
      }
      if (!_matchesDetailedCourse(detailedCourse, courseLabel, gradeLabel)) {
        return false;
      }
      return true;
    }).toList(growable: false);

    if (list.isEmpty) return const <LearningProblemQuestion>[];

    final docIds = list
        .map((e) => '${e['document_id'] ?? ''}'.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final documentNameMap = <String, String>{};
    if (docIds.isNotEmpty) {
      final docRows = await _client
          .from('pb_documents')
          .select('id,source_filename')
          .inFilter('id', docIds);
      for (final item in (docRows as List<dynamic>)) {
        final row = _mapOrEmpty(item);
        final id = '${row['id'] ?? ''}'.trim();
        if (id.isEmpty) continue;
        documentNameMap[id] = '${row['source_filename'] ?? ''}'.trim();
      }
    }

    return list
        .map(
          (row) => LearningProblemQuestion.fromMap(
            row,
            documentSourceName:
                documentNameMap['${row['document_id'] ?? ''}'.trim()] ?? '',
          ),
        )
        .toList(growable: false);
  }
}

bool _matchesLevel(String level, String courseLabel, String gradeLabel) {
  final safeLevel = level.trim();
  if (safeLevel.isEmpty || safeLevel == '전체') return true;
  final merged = '$courseLabel $gradeLabel'.replaceAll(' ', '');
  if (merged.isEmpty) return true;
  final hasExplicitLevel =
      merged.contains('초') || merged.contains('중') || merged.contains('고');
  if (!hasExplicitLevel) return true;
  if (safeLevel == '초') return merged.contains('초');
  if (safeLevel == '중') return merged.contains('중');
  if (safeLevel == '고') return merged.contains('고');
  return true;
}

bool _matchesDetailedCourse(
  String detailedCourse,
  String courseLabel,
  String gradeLabel,
) {
  final selected = detailedCourse.trim();
  if (selected.isEmpty || selected == '전체') return true;
  final merged = '$courseLabel $gradeLabel';
  if (merged.contains(selected)) return true;
  final compactMerged = merged.replaceAll(' ', '');
  final compactSelected = selected.replaceAll(' ', '');
  if (compactMerged.contains(compactSelected)) return true;
  final normalizedSelected =
      compactSelected.replaceAll(RegExp(r'^(초|중|고)'), '');
  if (normalizedSelected.isNotEmpty &&
      compactMerged.contains(normalizedSelected)) {
    return true;
  }
  return false;
}

String _renderTextWithEquation(
  String input,
  List<LearningProblemEquation> equations,
) {
  final raw = input.trim();
  if (raw.isEmpty || equations.isEmpty) {
    return _stripPotentialWatermarkText(raw);
  }
  final tokenMap = <String, LearningProblemEquation>{};
  for (final eq in equations) {
    final key = eq.token.trim();
    if (key.isEmpty) continue;
    tokenMap[key] = eq;
  }
  var seq = 0;
  final merged = raw.replaceAllMapped(
    RegExp(r'\[\[PB_EQ_[^\]]+\]\]|\[수식\]'),
    (m) {
      final token = m.group(0) ?? '';
      LearningProblemEquation? target = tokenMap[token];
      if (target == null) {
        final idxMatch = RegExp(r'^\[\[PB_EQ_\d+_(\d+)\]\]$').firstMatch(token);
        final idx = int.tryParse(idxMatch?.group(1) ?? '');
        if (idx != null && idx >= 0 && idx < equations.length) {
          target = equations[idx];
        }
      }
      if (target == null && seq < equations.length) {
        target = equations[seq];
        seq += 1;
      }
      final out = target?.bestText.trim() ?? '';
      return out.isNotEmpty ? out : '[수식]';
    },
  );
  return _stripPotentialWatermarkText(merged);
}

String _stripPotentialWatermarkText(String value) {
  var out = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (out.isEmpty) return '';
  out = out
      .replaceAll(RegExp(r'(?:중등|고등)\s*내신기출\s*\d{4}\.\d{2}\.\d{2}'), '')
      .replaceAll(RegExp(r'수식입니다\.?'), '')
      .replaceAll(RegExp(r'무단\s*배포\s*금지'), '')
      .trim();
  return out;
}

Map<String, dynamic> _mapOrEmpty(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((k, dynamic v) => MapEntry('$k', v));
  }
  return const <String, dynamic>{};
}

List<dynamic> _listOrEmpty(dynamic value) {
  if (value is List) return value;
  return const <dynamic>[];
}

DateTime? _dateTimeOrNull(dynamic value) {
  if (value == null) return null;
  final raw = '$value'.trim();
  if (raw.isEmpty) return null;
  return DateTime.tryParse(raw);
}

int _intOrZero(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('$value') ?? 0;
}

int? _intOrNull(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('$value');
}

double _doubleOrZero(dynamic value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return double.tryParse('$value') ?? 0;
}
