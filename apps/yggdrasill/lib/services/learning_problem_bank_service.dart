import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
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
    required this.allowObjective,
    required this.allowSubjective,
    required this.objectiveAnswerKey,
    required this.subjectiveAnswer,
    required this.reviewerNotes,
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
    required this.figureRefs,
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
  final bool allowObjective;
  final bool allowSubjective;
  final String objectiveAnswerKey;
  final String subjectiveAnswer;
  final String reviewerNotes;
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
  final List<String> figureRefs;
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

  LearningProblemQuestion copyWith({
    String? questionType,
    List<LearningProblemChoice>? choices,
    List<LearningProblemChoice>? objectiveChoices,
    bool? allowObjective,
    bool? allowSubjective,
    String? objectiveAnswerKey,
    String? subjectiveAnswer,
    String? reviewerNotes,
  }) {
    return LearningProblemQuestion(
      id: id,
      documentId: documentId,
      questionNumber: questionNumber,
      questionType: questionType ?? this.questionType,
      stem: stem,
      choices: choices ?? this.choices,
      objectiveChoices: objectiveChoices ?? this.objectiveChoices,
      allowObjective: allowObjective ?? this.allowObjective,
      allowSubjective: allowSubjective ?? this.allowSubjective,
      objectiveAnswerKey: objectiveAnswerKey ?? this.objectiveAnswerKey,
      subjectiveAnswer: subjectiveAnswer ?? this.subjectiveAnswer,
      reviewerNotes: reviewerNotes ?? this.reviewerNotes,
      equations: equations,
      sourcePage: sourcePage,
      sourceOrder: sourceOrder,
      curriculumCode: curriculumCode,
      sourceTypeCode: sourceTypeCode,
      courseLabel: courseLabel,
      gradeLabel: gradeLabel,
      examYear: examYear,
      semesterLabel: semesterLabel,
      examTermLabel: examTermLabel,
      schoolName: schoolName,
      publisherName: publisherName,
      materialName: materialName,
      confidence: confidence,
      figureRefs: figureRefs,
      meta: meta,
      createdAt: createdAt,
      documentSourceName: documentSourceName,
    );
  }

  List<Map<String, dynamic>> get figureAssets {
    final raw = meta['figure_assets'];
    if (raw is! List) return const <Map<String, dynamic>>[];
    return raw
        .map<Map<String, dynamic>>((e) => _mapOrEmpty(e))
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  List<Map<String, dynamic>> get orderedFigureAssets {
    final assets = figureAssets.toList(growable: true);
    if (assets.isEmpty) return const <Map<String, dynamic>>[];
    assets.sort((a, b) {
      final ai = _intOrNull(a['figure_index']) ?? 1 << 20;
      final bi = _intOrNull(b['figure_index']) ?? 1 << 20;
      if (ai != bi) return ai.compareTo(bi);
      final ad = '${a['created_at'] ?? ''}';
      final bd = '${b['created_at'] ?? ''}';
      return bd.compareTo(ad);
    });
    return assets;
  }

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
    final figureRefs = _listOrEmpty(map['figure_refs'])
        .map((e) => '$e'.trim())
        .where((e) => e.isNotEmpty)
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
      allowObjective: map['allow_objective'] != false,
      allowSubjective: map['allow_subjective'] != false,
      objectiveAnswerKey: '${map['objective_answer_key'] ?? ''}'.trim(),
      subjectiveAnswer: '${map['subjective_answer'] ?? ''}'.trim(),
      reviewerNotes: '${map['reviewer_notes'] ?? ''}'.trim(),
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
      figureRefs: figureRefs,
      meta: meta,
      createdAt: _dateTimeOrNull(map['created_at']),
      documentSourceName: documentSourceName,
    );
  }
}

class LearningProblemExportJob {
  const LearningProblemExportJob({
    required this.id,
    required this.academyId,
    required this.documentId,
    required this.status,
    required this.templateProfile,
    required this.paperSize,
    required this.includeAnswerSheet,
    required this.includeExplanation,
    required this.selectedQuestionIds,
    required this.outputUrl,
    required this.outputStorageBucket,
    required this.outputStoragePath,
    required this.pageCount,
    required this.errorCode,
    required this.errorMessage,
    required this.renderHash,
    required this.previewOnly,
    required this.options,
    required this.resultSummary,
    required this.createdAt,
    required this.updatedAt,
    this.startedAt,
    this.finishedAt,
  });

  final String id;
  final String academyId;
  final String documentId;
  final String status;
  final String templateProfile;
  final String paperSize;
  final bool includeAnswerSheet;
  final bool includeExplanation;
  final List<String> selectedQuestionIds;
  final String outputUrl;
  final String outputStorageBucket;
  final String outputStoragePath;
  final int pageCount;
  final String errorCode;
  final String errorMessage;
  final String renderHash;
  final bool previewOnly;
  final Map<String, dynamic> options;
  final Map<String, dynamic> resultSummary;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  bool get isTerminal =>
      status == 'completed' || status == 'failed' || status == 'cancelled';

  factory LearningProblemExportJob.fromMap(Map<String, dynamic> map) {
    final options = _mapOrEmpty(map['options']);
    final resultSummary = _mapOrEmpty(map['result_summary']);
    return LearningProblemExportJob(
      id: '${map['id'] ?? ''}',
      academyId: '${map['academy_id'] ?? ''}',
      documentId: '${map['document_id'] ?? ''}',
      status: '${map['status'] ?? ''}',
      templateProfile: '${map['template_profile'] ?? ''}',
      paperSize: '${map['paper_size'] ?? ''}',
      includeAnswerSheet: map['include_answer_sheet'] == true,
      includeExplanation: map['include_explanation'] == true,
      selectedQuestionIds:
          _listOrEmpty(map['selected_question_ids']).map((e) => '$e').toList(),
      outputUrl: '${map['output_url'] ?? ''}',
      outputStorageBucket: '${map['output_storage_bucket'] ?? ''}'.trim(),
      outputStoragePath: '${map['output_storage_path'] ?? ''}'.trim(),
      pageCount: _intOrZero(map['page_count']),
      errorCode: '${map['error_code'] ?? ''}',
      errorMessage: '${map['error_message'] ?? ''}',
      renderHash: '${map['render_hash'] ?? options['renderHash'] ?? ''}'.trim(),
      previewOnly:
          map['preview_only'] == true || options['previewOnly'] == true,
      options: options,
      resultSummary: resultSummary,
      createdAt: _dateTimeOrNull(map['created_at']) ?? DateTime.now(),
      updatedAt: _dateTimeOrNull(map['updated_at']) ?? DateTime.now(),
      startedAt: _dateTimeOrNull(map['started_at']),
      finishedAt: _dateTimeOrNull(map['finished_at']),
    );
  }
}

class LearningProblemDocumentExportPreset {
  const LearningProblemDocumentExportPreset({
    required this.id,
    required this.academyId,
    required this.sourceDocumentId,
    required this.documentId,
    required this.renderConfig,
    required this.selectedQuestionIds,
    required this.questionModeByQuestionId,
    required this.titlePageTopText,
    required this.includeQuestionScore,
    required this.questionScoreByQuestionId,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String academyId;
  final String sourceDocumentId;
  final String documentId;
  final Map<String, dynamic> renderConfig;
  final List<String> selectedQuestionIds;
  final Map<String, String> questionModeByQuestionId;
  final String titlePageTopText;
  final bool includeQuestionScore;
  final Map<String, double> questionScoreByQuestionId;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory LearningProblemDocumentExportPreset.fromMap(
    Map<String, dynamic> map,
  ) {
    final renderConfig = _mapOrEmpty(map['render_config']);
    final modeMapRaw = _mapOrEmpty(map['question_mode_by_question_id']);
    final titlePageTopText = '${renderConfig['titlePageTopText'] ?? ''}'
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final includeQuestionScore = renderConfig['includeQuestionScore'] == true;
    final questionScoreByQuestionId =
        _scoreMapFromDynamic(renderConfig['questionScoreByQuestionId']);
    final modeMap = <String, String>{};
    for (final entry in modeMapRaw.entries) {
      final id = entry.key.trim();
      if (id.isEmpty) continue;
      final mode = '${entry.value ?? ''}'.trim();
      if (mode.isEmpty) continue;
      modeMap[id] = mode;
    }
    return LearningProblemDocumentExportPreset(
      id: '${map['id'] ?? ''}'.trim(),
      academyId: '${map['academy_id'] ?? ''}'.trim(),
      sourceDocumentId: '${map['source_document_id'] ?? ''}'.trim(),
      documentId: '${map['document_id'] ?? ''}'.trim(),
      renderConfig: renderConfig,
      selectedQuestionIds: _listOrEmpty(map['selected_question_ids'])
          .map((e) => '$e'.trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false),
      questionModeByQuestionId: modeMap,
      titlePageTopText:
          titlePageTopText.isEmpty ? '2026학년도 대학수학능력시험 문제지' : titlePageTopText,
      includeQuestionScore: includeQuestionScore,
      questionScoreByQuestionId: questionScoreByQuestionId,
      createdAt: _dateTimeOrNull(map['created_at']),
      updatedAt: _dateTimeOrNull(map['updated_at']),
    );
  }
}

class LearningProblemSavedSettingsDocumentResult {
  const LearningProblemSavedSettingsDocumentResult({
    required this.documentId,
    required this.copiedQuestionCount,
    required this.selectedQuestionIds,
    this.preset,
  });

  final String documentId;
  final int copiedQuestionCount;
  final List<String> selectedQuestionIds;
  final LearningProblemDocumentExportPreset? preset;

  factory LearningProblemSavedSettingsDocumentResult.fromGatewayResponse(
    Map<String, dynamic> payload,
  ) {
    final document = _mapOrEmpty(payload['document']);
    final presetMap = _mapOrEmpty(payload['preset']);
    return LearningProblemSavedSettingsDocumentResult(
      documentId: '${document['id'] ?? ''}'.trim(),
      copiedQuestionCount: _intOrZero(payload['copiedQuestionCount']),
      selectedQuestionIds: _listOrEmpty(payload['selectedQuestionIds'])
          .map((e) => '$e'.trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false),
      preset: presetMap.isEmpty
          ? null
          : LearningProblemDocumentExportPreset.fromMap(presetMap),
    );
  }
}

class LearningProblemBankService {
  LearningProblemBankService({
    SupabaseClient? client,
    http.Client? httpClient,
    String? gatewayBaseUrl,
    String? gatewayApiKey,
  })  : _client = client ?? Supabase.instance.client,
        _http = httpClient ?? http.Client(),
        _gatewayBaseUrl = _resolveGatewayUrl(gatewayBaseUrl),
        _gatewayApiKey = (gatewayApiKey ??
                const String.fromEnvironment('PB_GATEWAY_API_KEY',
                    defaultValue: ''))
            .trim();

  static String _resolveGatewayUrl(String? explicit) {
    if (explicit != null && explicit.trim().isNotEmpty) {
      return explicit.trim();
    }
    const dartDefine =
        String.fromEnvironment('PB_GATEWAY_URL', defaultValue: '');
    if (dartDefine.isNotEmpty) return dartDefine;
    try {
      final envValue = Platform.environment['PB_GATEWAY_URL'] ?? '';
      if (envValue.isNotEmpty) return envValue;
    } catch (_) {}
    return 'http://localhost:8787';
  }

  final SupabaseClient _client;
  final http.Client _http;
  final String _gatewayBaseUrl;
  final String _gatewayApiKey;

  bool get hasGateway => _gatewayBaseUrl.isNotEmpty;

  Uri _gatewayUri(String path, [Map<String, String>? query]) {
    final base = _gatewayBaseUrl.endsWith('/')
        ? _gatewayBaseUrl.substring(0, _gatewayBaseUrl.length - 1)
        : _gatewayBaseUrl;
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('$base$normalizedPath');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(queryParameters: query);
  }

  Map<String, String> _gatewayHeaders() {
    final out = <String, String>{
      'Content-Type': 'application/json',
    };
    if (_gatewayApiKey.isNotEmpty) {
      out['x-api-key'] = _gatewayApiKey;
    }
    return out;
  }

  Future<Map<String, dynamic>> _gatewayGet(
    String path, {
    Map<String, String>? query,
  }) async {
    final uri = _gatewayUri(path, query);
    final res = await _http.get(uri, headers: _gatewayHeaders());
    final decoded = _decodeJsonMap(res.body);
    if (res.statusCode < 200 ||
        res.statusCode >= 300 ||
        decoded['ok'] != true) {
      throw Exception(
        'gateway_get_failed(${res.statusCode}): ${decoded['error'] ?? decoded['message'] ?? res.body}',
      );
    }
    return decoded;
  }

  Future<Map<String, dynamic>> _gatewayPost(
    String path, {
    required Map<String, dynamic> body,
  }) async {
    final uri = _gatewayUri(path);
    final res = await _http.post(
      uri,
      headers: _gatewayHeaders(),
      body: jsonEncode(body),
    );
    final decoded = _decodeJsonMap(res.body);
    if (res.statusCode < 200 ||
        res.statusCode >= 300 ||
        decoded['ok'] != true) {
      throw Exception(
        'gateway_post_failed(${res.statusCode}): ${decoded['error'] ?? decoded['message'] ?? res.body}',
      );
    }
    return decoded;
  }

  Map<String, dynamic> _decodeJsonMap(String raw) {
    try {
      final value = jsonDecode(raw);
      if (value is Map<String, dynamic>) return value;
      if (value is Map) {
        return value.map((k, dynamic v) => MapEntry('$k', v));
      }
      return <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

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
        .eq('status', 'ready')
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
    final safeSchoolName = (schoolName ?? '').trim();
    final readyDocRows = await _client
        .from('pb_documents')
        .select(
          'id,source_filename,school_name,course_label,grade_label,curriculum_code,source_type_code',
        )
        .eq('academy_id', academyId)
        .eq('curriculum_code', curriculumCode)
        .eq('source_type_code', sourceTypeCode)
        .eq('status', 'ready')
        .limit(4000);

    final readyDocIds = <String>{};
    final documentNameMap = <String, String>{};
    for (final item in (readyDocRows as List<dynamic>)) {
      final row = _mapOrEmpty(item);
      final docId = '${row['id'] ?? ''}'.trim();
      if (docId.isEmpty) continue;
      final docSchoolName = '${row['school_name'] ?? ''}'.trim();
      if (safeSchoolName.isNotEmpty && docSchoolName != safeSchoolName) {
        continue;
      }
      final courseLabel = '${row['course_label'] ?? ''}'.trim();
      final gradeLabel = '${row['grade_label'] ?? ''}'.trim();
      if (!_matchesLevel(schoolLevel, courseLabel, gradeLabel)) {
        continue;
      }
      if (!_matchesDetailedCourse(detailedCourse, courseLabel, gradeLabel)) {
        continue;
      }
      readyDocIds.add(docId);
      documentNameMap[docId] = '${row['source_filename'] ?? ''}'.trim();
    }

    if (readyDocIds.isEmpty) {
      return const <LearningProblemQuestion>[];
    }

    final fetchedRows = <Map<String, dynamic>>[];
    for (final docChunk
        in _chunkStrings(readyDocIds.toList(growable: false), 250)) {
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
              'allow_objective',
              'allow_subjective',
              'objective_answer_key',
              'subjective_answer',
              'reviewer_notes',
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
              'figure_refs',
              'meta',
              'created_at',
            ].join(','),
          )
          .eq('academy_id', academyId)
          .eq('curriculum_code', curriculumCode)
          .eq('source_type_code', sourceTypeCode)
          .inFilter('document_id', docChunk);

      if (safeSchoolName.isNotEmpty) {
        q = q.eq('school_name', safeSchoolName);
      }
      final rows = await q.order('created_at', ascending: false).limit(limit);
      fetchedRows.addAll((rows as List<dynamic>).map(_mapOrEmpty));
    }

    if (fetchedRows.isEmpty) return const <LearningProblemQuestion>[];

    fetchedRows.sort((a, b) {
      final left = _dateTimeOrNull(a['created_at']);
      final right = _dateTimeOrNull(b['created_at']);
      if (left == null && right == null) return 0;
      if (left == null) return 1;
      if (right == null) return -1;
      return right.compareTo(left);
    });

    final deduped = <String, Map<String, dynamic>>{};
    for (final row in fetchedRows) {
      final id = '${row['id'] ?? ''}'.trim();
      if (id.isEmpty || deduped.containsKey(id)) continue;
      deduped[id] = row;
    }

    final list = deduped.values.where((row) {
      final documentId = '${row['document_id'] ?? ''}'.trim();
      if (!readyDocIds.contains(documentId)) return false;
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

    final limited = list.length > limit ? list.take(limit).toList() : list;
    return limited
        .map(
          (row) => LearningProblemQuestion.fromMap(
            row,
            documentSourceName:
                documentNameMap['${row['document_id'] ?? ''}'.trim()] ?? '',
          ),
        )
        .toList(growable: false);
  }

  Future<Map<String, int>> loadQuestionOrders({
    required String academyId,
    required String scopeKey,
    required List<String> questionIds,
  }) async {
    final safeScope = scopeKey.trim();
    final safeIds = questionIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (safeScope.isEmpty || safeIds.isEmpty) {
      return const <String, int>{};
    }
    final rows = await _client
        .from('learning_problem_bank_question_orders')
        .select('question_id,order_index')
        .eq('academy_id', academyId)
        .eq('scope_key', safeScope)
        .inFilter('question_id', safeIds);
    final out = <String, int>{};
    for (final item in (rows as List<dynamic>)) {
      final row = _mapOrEmpty(item);
      final questionId = '${row['question_id'] ?? ''}'.trim();
      if (questionId.isEmpty) continue;
      final order = _intOrZero(row['order_index']);
      out[questionId] = order < 0 ? 0 : order;
    }
    return out;
  }

  Future<void> saveQuestionOrders({
    required String academyId,
    required String scopeKey,
    required List<String> orderedQuestionIds,
  }) async {
    final safeScope = scopeKey.trim();
    final safeIds = orderedQuestionIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (safeScope.isEmpty || safeIds.isEmpty) return;
    final rows = safeIds
        .asMap()
        .entries
        .map((entry) => <String, dynamic>{
              'academy_id': academyId,
              'scope_key': safeScope,
              'question_id': entry.value,
              'order_index': entry.key,
            })
        .toList(growable: false);
    await _client
        .from('learning_problem_bank_question_orders')
        .upsert(rows, onConflict: 'academy_id,scope_key,question_id');
  }

  Future<LearningProblemSavedSettingsDocumentResult>
      saveExportSettingsAsDocument({
    required String academyId,
    required String sourceDocumentId,
    required List<String> selectedQuestionIdsOrdered,
    required Map<String, String> questionModeByQuestionId,
    required Map<String, dynamic> renderConfig,
    required String templateProfile,
    required String paperSize,
    required bool includeAnswerSheet,
    required bool includeExplanation,
  }) async {
    if (!hasGateway) {
      throw Exception('세팅 저장은 게이트웨이 연결이 필요합니다.');
    }
    final selectedIds = selectedQuestionIdsOrdered
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (selectedIds.isEmpty) {
      throw Exception('저장할 문항이 비어 있습니다.');
    }
    final modeMap = <String, String>{};
    for (final id in selectedIds) {
      final mode = (questionModeByQuestionId[id] ?? '').trim();
      if (mode.isEmpty) continue;
      modeMap[id] = mode;
    }
    final payload = await _gatewayPost(
      '/pb/documents/save-settings',
      body: <String, dynamic>{
        'academyId': academyId,
        'sourceDocumentId': sourceDocumentId,
        'createdBy': _client.auth.currentUser?.id,
        'selectedQuestionIdsOrdered': selectedIds,
        'questionModeByQuestionId': modeMap,
        'renderConfig': renderConfig,
        'templateProfile': templateProfile.trim(),
        'paperSize': paperSize.trim(),
        'includeAnswerSheet': includeAnswerSheet,
        'includeExplanation': includeExplanation,
      },
    );
    return LearningProblemSavedSettingsDocumentResult.fromGatewayResponse(
      payload,
    );
  }

  Future<LearningProblemDocumentExportPreset?> getDocumentExportPreset({
    required String academyId,
    required String documentId,
  }) async {
    if (hasGateway) {
      try {
        final json = await _gatewayGet(
          '/pb/documents/$documentId/export-preset',
          query: <String, String>{'academyId': academyId},
        );
        final presetMap = _mapOrEmpty(json['preset']);
        if (presetMap.isEmpty) return null;
        return LearningProblemDocumentExportPreset.fromMap(presetMap);
      } catch (_) {
        // fallback
      }
    }
    dynamic row;
    try {
      row = await _client
          .from('pb_export_presets')
          .select('*')
          .eq('academy_id', academyId)
          .eq('document_id', documentId)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
    } catch (_) {
      return null;
    }
    if (row == null) return null;
    return LearningProblemDocumentExportPreset.fromMap(
      _mapOrEmpty(row),
    );
  }

  Future<LearningProblemExportJob> createExportJob({
    required String academyId,
    required String documentId,
    required String templateProfile,
    required String paperSize,
    required bool includeAnswerSheet,
    required bool includeExplanation,
    required List<String> selectedQuestionIds,
    String renderHash = '',
    bool previewOnly = false,
    Map<String, dynamic> options = const <String, dynamic>{},
  }) async {
    final safeRenderHash = renderHash.trim();
    if (hasGateway) {
      final json = await _gatewayPost(
        '/pb/jobs/export',
        body: {
          'academyId': academyId,
          'documentId': documentId,
          'requestedBy': _client.auth.currentUser?.id,
          'templateProfile': templateProfile,
          'paperSize': paperSize,
          'includeAnswerSheet': includeAnswerSheet,
          'includeExplanation': includeExplanation,
          'selectedQuestionIds': selectedQuestionIds,
          'renderHash': safeRenderHash,
          'previewOnly': previewOnly,
          'options': options,
        },
      );
      return LearningProblemExportJob.fromMap(_mapOrEmpty(json['job']));
    }

    final basePayload = <String, dynamic>{
      'academy_id': academyId,
      'document_id': documentId,
      'requested_by': _client.auth.currentUser?.id,
      'status': 'queued',
      'template_profile': templateProfile.trim(),
      'paper_size': paperSize.trim(),
      'include_answer_sheet': includeAnswerSheet,
      'include_explanation': includeExplanation,
      'selected_question_ids': selectedQuestionIds,
      'options': options,
      'output_storage_bucket': 'problem-exports',
      'output_storage_path': '',
      'output_url': '',
      'page_count': 0,
      'worker_name': '',
      'error_code': '',
      'error_message': '',
    };
    final payloadWithHash = <String, dynamic>{
      ...basePayload,
      'render_hash': safeRenderHash,
      'preview_only': previewOnly,
    };
    dynamic row;
    try {
      row = await _client
          .from('pb_exports')
          .insert(payloadWithHash)
          .select('*')
          .single();
    } catch (_) {
      row = await _client
          .from('pb_exports')
          .insert(basePayload)
          .select('*')
          .single();
    }
    return LearningProblemExportJob.fromMap(
      Map<String, dynamic>.from(row as Map<dynamic, dynamic>),
    );
  }

  Future<LearningProblemExportJob?> getExportJob({
    required String academyId,
    required String jobId,
  }) async {
    if (hasGateway) {
      try {
        final json = await _gatewayGet(
          '/pb/jobs/export/$jobId',
          query: {'academyId': academyId},
        );
        return LearningProblemExportJob.fromMap(_mapOrEmpty(json['job']));
      } catch (_) {
        // fallback
      }
    }

    final row = await _client
        .from('pb_exports')
        .select('*')
        .eq('id', jobId)
        .eq('academy_id', academyId)
        .maybeSingle();
    if (row == null) return null;
    return LearningProblemExportJob.fromMap(
      Map<String, dynamic>.from(row as Map<dynamic, dynamic>),
    );
  }

  Future<List<LearningProblemExportJob>> listExportJobs({
    required String academyId,
    String? documentId,
    String? status,
    String? renderHash,
    bool? previewOnly,
    int limit = 40,
  }) async {
    final safeDocumentId = (documentId ?? '').trim();
    final safeStatus = (status ?? '').trim();
    final safeRenderHash = (renderHash ?? '').trim();

    if (hasGateway) {
      try {
        final query = <String, String>{
          'academyId': academyId,
          'limit': '$limit',
          if (safeDocumentId.isNotEmpty) 'documentId': safeDocumentId,
          if (safeStatus.isNotEmpty) 'status': safeStatus,
          if (safeRenderHash.isNotEmpty) 'renderHash': safeRenderHash,
          if (previewOnly != null)
            'previewOnly': previewOnly ? 'true' : 'false',
        };
        final json = await _gatewayGet('/pb/jobs/export', query: query);
        return (json['jobs'] as List<dynamic>? ?? const <dynamic>[])
            .map((e) => LearningProblemExportJob.fromMap(_mapOrEmpty(e)))
            .toList(growable: false);
      } catch (_) {
        // fallback
      }
    }

    dynamic rows;
    try {
      var q =
          _client.from('pb_exports').select('*').eq('academy_id', academyId);
      if (safeDocumentId.isNotEmpty) {
        q = q.eq('document_id', safeDocumentId);
      }
      if (safeStatus.isNotEmpty) {
        q = q.eq('status', safeStatus);
      }
      if (safeRenderHash.isNotEmpty) {
        q = q.eq('render_hash', safeRenderHash);
      }
      if (previewOnly != null) {
        q = q.eq('preview_only', previewOnly);
      }
      rows = await q.order('created_at', ascending: false).limit(limit);
    } catch (_) {
      var fallback =
          _client.from('pb_exports').select('*').eq('academy_id', academyId);
      if (safeDocumentId.isNotEmpty) {
        fallback = fallback.eq('document_id', safeDocumentId);
      }
      if (safeStatus.isNotEmpty) {
        fallback = fallback.eq('status', safeStatus);
      }
      rows = await fallback.order('created_at', ascending: false).limit(limit);
    }
    var jobs = (rows as List<dynamic>)
        .map(
          (e) => LearningProblemExportJob.fromMap(
            Map<String, dynamic>.from(e as Map<dynamic, dynamic>),
          ),
        )
        .toList(growable: false);
    if (safeRenderHash.isNotEmpty) {
      jobs = jobs.where((e) => e.renderHash == safeRenderHash).toList();
    }
    if (previewOnly != null) {
      jobs = jobs.where((e) => e.previewOnly == previewOnly).toList();
    }
    return jobs;
  }

  Future<LearningProblemExportJob?> findReusableCompletedExport({
    required String academyId,
    required String renderHash,
    bool? previewOnly,
  }) async {
    final safeHash = renderHash.trim();
    if (safeHash.isEmpty) return null;
    final jobs = await listExportJobs(
      academyId: academyId,
      status: 'completed',
      renderHash: safeHash,
      previewOnly: previewOnly,
      limit: 12,
    );
    for (final job in jobs) {
      if (job.outputUrl.trim().isNotEmpty) {
        return job;
      }
    }
    return null;
  }

  Future<void> clearExportStorageArtifact({
    required String academyId,
    required String jobId,
  }) async {
    if (hasGateway) {
      try {
        await _gatewayPost(
          '/pb/jobs/export/$jobId/cleanup',
          body: {'academyId': academyId},
        );
        return;
      } catch (_) {
        // fallback
      }
    }

    final row = await _client
        .from('pb_exports')
        .select('output_storage_bucket,output_storage_path')
        .eq('academy_id', academyId)
        .eq('id', jobId)
        .maybeSingle();
    if (row == null) return;
    final map = Map<String, dynamic>.from(row as Map<dynamic, dynamic>);
    final bucket = '${map['output_storage_bucket'] ?? ''}'.trim();
    final path = '${map['output_storage_path'] ?? ''}'.trim();

    if (bucket.isNotEmpty && path.isNotEmpty) {
      try {
        await _client.storage.from(bucket).remove([path]);
      } catch (_) {
        // ignore cleanup error
      }
    }

    await _client
        .from('pb_exports')
        .update({
          'output_storage_bucket': '',
          'output_storage_path': '',
          'output_url': '',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('academy_id', academyId)
        .eq('id', jobId);
  }

  Future<Uint8List> downloadPdfBytesFromUrl(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) {
      throw Exception('유효한 PDF 다운로드 URL이 없습니다.');
    }
    final res = await _http.get(uri);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('PDF 다운로드 실패(${res.statusCode})');
    }
    if (res.bodyBytes.isEmpty) {
      throw Exception('다운로드한 PDF 데이터가 비어 있습니다.');
    }
    return res.bodyBytes;
  }

  Future<String> createStorageSignedUrl({
    required String bucket,
    required String path,
    int expiresInSeconds = 60 * 60 * 24,
  }) async {
    final safeBucket = bucket.trim();
    final safePath = path.trim();
    if (safeBucket.isEmpty || safePath.isEmpty) return '';
    return _client.storage
        .from(safeBucket)
        .createSignedUrl(safePath, expiresInSeconds);
  }

  Future<Map<String, String>> fetchQuestionPreviews({
    required String academyId,
    required List<String> questionIds,
    Map<String, dynamic>? layout,
  }) async {
    if (!hasGateway || questionIds.isEmpty) return {};
    try {
      final urlResult = await _gatewayPost(
        '/pb/preview/urls',
        body: <String, dynamic>{
          'academyId': academyId,
          'questionIds': questionIds,
        },
      );

      final map = <String, String>{};
      final missing = <String>[];
      final previews = urlResult['previews'];
      if (previews is List) {
        for (final entry in previews) {
          if (entry is! Map) continue;
          final qId = '${entry['questionId'] ?? ''}'.trim();
          final url = '${entry['imageUrl'] ?? ''}'.trim();
          if (qId.isNotEmpty && url.isNotEmpty) {
            map[qId] = url;
          } else if (qId.isNotEmpty) {
            missing.add(qId);
          }
        }
      }

      if (missing.isNotEmpty) {
        final body = <String, dynamic>{
          'academyId': academyId,
          'questionIds': missing,
        };
        if (layout != null && layout.isNotEmpty) body['layout'] = layout;
        final genResult = await _gatewayPost(
          '/pb/preview/questions',
          body: body,
        );
        final genPreviews = genResult['previews'];
        if (genPreviews is List) {
          for (final entry in genPreviews) {
            if (entry is! Map) continue;
            final qId = '${entry['questionId'] ?? ''}'.trim();
            final url = '${entry['imageUrl'] ?? ''}'.trim();
            if (qId.isNotEmpty && url.isNotEmpty) map[qId] = url;
          }
        }
      }

      return map;
    } catch (e) {
      // ignore preview fetch errors silently
      return {};
    }
  }

  Future<Map<String, String>> fetchPreviewHtmlBatch({
    required String academyId,
    required List<String> questionIds,
    Map<String, dynamic>? layout,
  }) async {
    if (!hasGateway || questionIds.isEmpty) return {};
    try {
      final body = <String, dynamic>{
        'academyId': academyId,
        'questionIds': questionIds,
      };
      if (layout != null && layout.isNotEmpty) body['layout'] = layout;

      final result = await _gatewayPost(
        '/pb/preview/html',
        body: body,
      );

      final questions = result['questions'];
      if (questions is! List) return {};

      final map = <String, String>{};
      for (final entry in questions) {
        if (entry is! Map) continue;
        final qId = '${entry['questionId'] ?? ''}'.trim();
        final html = '${entry['html'] ?? ''}'.trim();
        if (qId.isNotEmpty && html.isNotEmpty) map[qId] = html;
      }
      return map;
    } catch (e) {
      return {};
    }
  }

  Future<String?> fetchDocumentPreviewHtml({
    required String academyId,
    required List<String> questionIds,
    Map<String, dynamic>? renderConfig,
    String profile = 'naesin',
    String paper = 'B4',
    Map<String, dynamic>? baseLayout,
    int maxQuestionsPerPage = 4,
  }) async {
    if (!hasGateway || questionIds.isEmpty) return null;
    try {
      final body = <String, dynamic>{
        'academyId': academyId,
        'questionIds': questionIds,
        'mode': 'document',
        'profile': profile,
        'paper': paper,
        'maxQuestionsPerPage': maxQuestionsPerPage,
      };
      if (renderConfig != null) body['renderConfig'] = renderConfig;
      if (baseLayout != null) body['baseLayout'] = baseLayout;

      final result = await _gatewayPost('/pb/preview/html', body: body);
      return '${result['html'] ?? ''}'.trim();
    } catch (e) {
      return null;
    }
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

List<List<String>> _chunkStrings(List<String> input, int chunkSize) {
  final safeChunkSize = chunkSize <= 0 ? 1 : chunkSize;
  if (input.isEmpty) return const <List<String>>[];
  final out = <List<String>>[];
  for (var i = 0; i < input.length; i += safeChunkSize) {
    final end =
        (i + safeChunkSize > input.length) ? input.length : i + safeChunkSize;
    out.add(input.sublist(i, end));
  }
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

Map<String, double> _scoreMapFromDynamic(dynamic value) {
  if (value is! Map) return const <String, double>{};
  final out = <String, double>{};
  for (final entry in value.entries) {
    final id = '${entry.key}'.trim();
    if (id.isEmpty) continue;
    final raw = entry.value;
    final score = raw is num ? raw.toDouble() : double.tryParse('$raw');
    if (score == null || !score.isFinite || score < 0) continue;
    out[id] = score;
  }
  return out;
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
