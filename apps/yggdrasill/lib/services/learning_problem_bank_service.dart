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
    required this.questionUid,
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
  final String questionUid;
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

  String get stableQuestionKey =>
      questionUid.trim().isNotEmpty ? questionUid.trim() : id.trim();

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
      questionUid: questionUid,
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
      questionUid:
          '${map['question_uid'] ?? map['questionUid'] ?? map['id'] ?? ''}',
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

/// 학습앱 UI의 출처 키 → Supabase `pb_documents.source_type_code` (매니저와 동일).
List<String> pbSourceTypeCodesForLearningUi(String uiSourceTypeCode) {
  switch (uiSourceTypeCode.trim()) {
    case 'private_material':
      return const <String>['market_book', 'lecture_book', 'ebs_book'];
    case 'self_made':
      return const <String>['original_item'];
    default:
      return <String>[uiSourceTypeCode.trim()];
  }
}

/// 문서 정렬용: 초·중·고 단계와 학년 숫자를 휴리스틱으로 합친 값(작을수록 저학년 쪽).
int pbDocumentGradeSortRank(String gradeLabel, String courseLabel) {
  final merged = '$gradeLabel$courseLabel'.replaceAll(RegExp(r'\s'), '');
  var levelBase = 500;
  if (merged.contains('초')) {
    levelBase = 0;
  } else if (merged.contains('중')) {
    levelBase = 100;
  } else if (merged.contains('고')) {
    levelBase = 200;
  }
  final m = RegExp(r'(\d+)').firstMatch(merged);
  final n = m != null ? int.tryParse(m.group(1) ?? '') ?? 50 : 50;
  return levelBase + n;
}

/// `pb_documents` 한 행(매니저 추출 단위) 요약 — 문제은행 왼쪽 문서 목록용.
class LearningProblemDocumentSummary {
  const LearningProblemDocumentSummary({
    required this.id,
    required this.schoolName,
    required this.sourceFilename,
    required this.courseLabel,
    required this.gradeLabel,
    this.examYear,
    this.semesterLabel = '',
    this.examTermLabel = '',
    this.updatedAt,
  });

  final String id;
  final String schoolName;
  final String sourceFilename;
  final String courseLabel;
  final String gradeLabel;
  final int? examYear;
  final String semesterLabel;
  final String examTermLabel;
  final DateTime? updatedAt;

  String get displayTitle {
    final name = sourceFilename.trim();
    if (name.isNotEmpty) return name;
    final raw = id.trim();
    if (raw.length <= 12) return raw.isEmpty ? '(문서)' : raw;
    return '${raw.substring(0, 12)}…';
  }

  /// 트리에서 학교/연도를 따로 쓰므로 행 부제는 과정·학년·시험 메타 중심.
  String get displaySubtitle {
    final parts = <String>[];
    final cg = <String>[
      courseLabel.trim(),
      gradeLabel.trim(),
    ].where((e) => e.isNotEmpty).join(' · ');
    if (cg.isNotEmpty) parts.add(cg);
    final sem = semesterLabel.trim();
    final term = examTermLabel.trim();
    if (sem.isNotEmpty && term.isNotEmpty) {
      parts.add('$sem · $term');
    } else if (sem.isNotEmpty) {
      parts.add(sem);
    } else if (term.isNotEmpty) {
      parts.add(term);
    }
    return parts.join(' · ');
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
    required this.selectedQuestionUids,
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
  final List<String> selectedQuestionUids;
  List<String> get selectedQuestionIds => selectedQuestionUids;
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
    final selectedQuestionUidsRaw =
        _listOrEmpty(options['selectedQuestionUidsOrdered']).isNotEmpty
            ? options['selectedQuestionUidsOrdered']
            : (_listOrEmpty(options['selectedQuestionIdsOrdered']).isNotEmpty
                ? options['selectedQuestionIdsOrdered']
                : map['selected_question_ids']);
    return LearningProblemExportJob(
      id: '${map['id'] ?? ''}',
      academyId: '${map['academy_id'] ?? ''}',
      documentId: '${map['document_id'] ?? ''}',
      status: '${map['status'] ?? ''}',
      templateProfile: '${map['template_profile'] ?? ''}',
      paperSize: '${map['paper_size'] ?? ''}',
      includeAnswerSheet: map['include_answer_sheet'] == true,
      includeExplanation: map['include_explanation'] == true,
      selectedQuestionUids:
          _listOrEmpty(selectedQuestionUidsRaw).map((e) => '$e').toList(),
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

class LearningProblemPdfPreviewArtifact {
  const LearningProblemPdfPreviewArtifact({
    required this.questionId,
    required this.questionUid,
    required this.status,
    required this.jobId,
    required this.pdfUrl,
    required this.thumbnailUrl,
    required this.error,
    required this.pollAfterMs,
  });

  final String questionId;
  final String questionUid;
  final String status;
  final String jobId;
  final String pdfUrl;
  final String thumbnailUrl;
  final String error;
  final int pollAfterMs;

  bool get isPending => status == 'queued' || status == 'running';
  bool get isCompleted => status == 'completed';
  bool get isFailed => status == 'failed' || status == 'cancelled';

  factory LearningProblemPdfPreviewArtifact.fromMap(
    Map<String, dynamic> map, {
    int defaultPollAfterMs = 0,
  }) {
    return LearningProblemPdfPreviewArtifact(
      questionId: '${map['questionId'] ?? ''}'.trim(),
      questionUid: '${map['questionUid'] ?? ''}'.trim(),
      status: '${map['status'] ?? ''}'.trim().toLowerCase(),
      jobId: '${map['jobId'] ?? ''}'.trim(),
      pdfUrl: '${map['pdfUrl'] ?? ''}'.trim(),
      thumbnailUrl: '${map['thumbnailUrl'] ?? ''}'.trim(),
      error: '${map['error'] ?? ''}'.trim(),
      pollAfterMs: _intOrZero(map['pollAfterMs'] ?? defaultPollAfterMs),
    );
  }
}

class LearningProblemDocumentExportPreset {
  const LearningProblemDocumentExportPreset({
    required this.id,
    required this.academyId,
    required this.sourceDocumentId,
    required this.sourceDocumentIds,
    required this.documentId,
    required this.displayName,
    required this.sourceDocumentName,
    required this.documentName,
    required this.renderConfig,
    required this.selectedQuestionUids,
    required this.selectedQuestionCount,
    required this.questionModeByQuestionUid,
    required this.titlePageTopText,
    required this.includeAcademyLogo,
    required this.timeLimitText,
    required this.includeQuestionScore,
    required this.questionScoreByQuestionUid,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String academyId;
  final String sourceDocumentId;
  final List<String> sourceDocumentIds;
  final String documentId;
  final String displayName;
  final String sourceDocumentName;
  final String documentName;
  final Map<String, dynamic> renderConfig;
  final List<String> selectedQuestionUids;
  final int selectedQuestionCount;
  final Map<String, String> questionModeByQuestionUid;
  final String titlePageTopText;
  final bool includeAcademyLogo;
  final String timeLimitText;
  final bool includeQuestionScore;
  final Map<String, double> questionScoreByQuestionUid;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  String get templateProfile =>
      '${renderConfig['templateProfile'] ?? ''}'.trim();
  String get paperSize => '${renderConfig['paperSize'] ?? ''}'.trim();
  String get naesinLinkKey => '${renderConfig['naesinLinkKey'] ?? ''}'.trim();
  List<String> get selectedQuestionIds => selectedQuestionUids;
  Map<String, String> get questionModeByQuestionId => questionModeByQuestionUid;
  Map<String, double> get questionScoreByQuestionId =>
      questionScoreByQuestionUid;

  factory LearningProblemDocumentExportPreset.fromMap(
    Map<String, dynamic> map,
  ) {
    final renderConfig = _mapOrEmpty(
      map['render_config'] is Map ? map['render_config'] : map['renderConfig'],
    );
    final modeMapRaw = _mapOrEmpty(
      map['question_mode_by_question_uid'] is Map
          ? map['question_mode_by_question_uid']
          : (map['questionModeByQuestionUid'] is Map
              ? map['questionModeByQuestionUid']
              : (map['question_mode_by_question_id'] is Map
                  ? map['question_mode_by_question_id']
                  : map['questionModeByQuestionId'])),
    );
    final selectedQuestionUids = _listOrEmpty(
      map['selected_question_uids'] is List
          ? map['selected_question_uids']
          : (_listOrEmpty(map['selectedQuestionUids']).isNotEmpty
              ? map['selectedQuestionUids']
              : (map['selected_question_ids'] is List
                  ? map['selected_question_ids']
                  : map['selectedQuestionIds'])),
    )
        .map((e) => '$e'.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    final sourceDocumentIds = _listOrEmpty(
      map['source_document_ids'] is List
          ? map['source_document_ids']
          : map['sourceDocumentIds'],
    )
        .map((e) => '$e'.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    final sourceDocumentName =
        '${map['source_document_name'] ?? map['sourceDocumentName'] ?? ''}'
            .trim();
    final documentName =
        '${map['document_name'] ?? map['documentName'] ?? ''}'.trim();
    final displayName =
        '${map['display_name'] ?? map['displayName'] ?? ''}'.trim();
    final selectedQuestionCount = _intOrNull(
          map['selected_question_count'] ?? map['selectedQuestionCount'],
        ) ??
        selectedQuestionUids.length;
    final fallbackDisplayName = displayName.isNotEmpty
        ? displayName
        : (documentName.isNotEmpty
            ? documentName
            : (sourceDocumentName.isNotEmpty ? sourceDocumentName : '세팅저장'));
    final titlePageTopText = '${renderConfig['titlePageTopText'] ?? ''}'
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final includeAcademyLogo = renderConfig['includeAcademyLogo'] == true;
    final timeLimitText = '${renderConfig['timeLimitText'] ?? ''}'
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final includeQuestionScore = renderConfig['includeQuestionScore'] == true;
    final questionScoreByQuestionUid = _scoreMapFromDynamic(
      renderConfig['questionScoreByQuestionUid'] ??
          renderConfig['questionScoreByQuestionId'],
    );
    final sourceDocumentId =
        '${map['source_document_id'] ?? map['sourceDocumentId'] ?? ''}'.trim();
    final resolvedSourceDocumentIds = sourceDocumentIds.isNotEmpty
        ? sourceDocumentIds
        : (sourceDocumentId.isNotEmpty
            ? <String>[sourceDocumentId]
            : const <String>[]);
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
      academyId: '${map['academy_id'] ?? map['academyId'] ?? ''}'.trim(),
      sourceDocumentId: sourceDocumentId,
      sourceDocumentIds: resolvedSourceDocumentIds,
      documentId: '${map['document_id'] ?? map['documentId'] ?? ''}'.trim(),
      displayName: fallbackDisplayName,
      sourceDocumentName: sourceDocumentName,
      documentName: documentName,
      renderConfig: renderConfig,
      selectedQuestionUids: selectedQuestionUids,
      selectedQuestionCount: selectedQuestionCount,
      questionModeByQuestionUid: modeMap,
      titlePageTopText:
          titlePageTopText.isEmpty ? '2026학년도 대학수학능력시험 문제지' : titlePageTopText,
      includeAcademyLogo: includeAcademyLogo,
      timeLimitText: timeLimitText,
      includeQuestionScore: includeQuestionScore,
      questionScoreByQuestionUid: questionScoreByQuestionUid,
      createdAt: _dateTimeOrNull(map['created_at']),
      updatedAt: _dateTimeOrNull(map['updated_at']),
    );
  }
}

class LearningProblemSavedSettingsDocumentResult {
  const LearningProblemSavedSettingsDocumentResult({
    required this.documentId,
    required this.copiedQuestionCount,
    required this.selectedQuestionUids,
    this.preset,
  });

  final String documentId;
  final int copiedQuestionCount;
  final List<String> selectedQuestionUids;
  List<String> get selectedQuestionIds => selectedQuestionUids;
  final LearningProblemDocumentExportPreset? preset;

  factory LearningProblemSavedSettingsDocumentResult.fromGatewayResponse(
    Map<String, dynamic> payload,
  ) {
    final document = _mapOrEmpty(payload['document']);
    final presetMap = _mapOrEmpty(payload['preset']);
    return LearningProblemSavedSettingsDocumentResult(
      documentId:
          '${document['id'] ?? payload['sourceDocumentId'] ?? ''}'.trim(),
      copiedQuestionCount: _intOrZero(payload['copiedQuestionCount']),
      selectedQuestionUids: _listOrEmpty(
        _listOrEmpty(payload['selectedQuestionUids']).isNotEmpty
            ? payload['selectedQuestionUids']
            : payload['selectedQuestionIds'],
      )
          .map((e) => '$e'.trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false),
      preset: presetMap.isEmpty
          ? null
          : LearningProblemDocumentExportPreset.fromMap(presetMap),
    );
  }
}

class LearningProblemLiveRelease {
  const LearningProblemLiveRelease({
    required this.id,
    required this.academyId,
    required this.presetId,
    required this.sourceDocumentIds,
    required this.templateProfile,
    required this.paperSize,
    required this.activeExportJobId,
    required this.frozenExportJobId,
    required this.policy,
    required this.note,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String academyId;
  final String presetId;
  final List<String> sourceDocumentIds;
  final String templateProfile;
  final String paperSize;
  final String activeExportJobId;
  final String frozenExportJobId;
  final Map<String, dynamic> policy;
  final String note;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory LearningProblemLiveRelease.fromMap(Map<String, dynamic> map) {
    final sourceDocIds = _listOrEmpty(
      map['source_document_ids'] is List
          ? map['source_document_ids']
          : map['sourceDocumentIds'],
    )
        .map((e) => '$e'.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    return LearningProblemLiveRelease(
      id: '${map['id'] ?? ''}'.trim(),
      academyId: '${map['academy_id'] ?? map['academyId'] ?? ''}'.trim(),
      presetId: '${map['preset_id'] ?? map['presetId'] ?? ''}'.trim(),
      sourceDocumentIds: sourceDocIds,
      templateProfile:
          '${map['template_profile'] ?? map['templateProfile'] ?? ''}'.trim(),
      paperSize: '${map['paper_size'] ?? map['paperSize'] ?? ''}'.trim(),
      activeExportJobId:
          '${map['active_export_job_id'] ?? map['activeExportJobId'] ?? ''}'
              .trim(),
      frozenExportJobId:
          '${map['frozen_export_job_id'] ?? map['frozenExportJobId'] ?? ''}'
              .trim(),
      policy: _mapOrEmpty(map['policy']),
      note: '${map['note'] ?? ''}'.trim(),
      createdAt: _dateTimeOrNull(map['created_at']),
      updatedAt: _dateTimeOrNull(map['updated_at']),
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

  Future<List<LearningProblemDocumentSummary>> listReadyDocuments({
    required String academyId,
    required String curriculumCode,
    required String schoolLevel,
    required String detailedCourse,
    required String sourceTypeCode,
    int limit = 2000,
  }) async {
    final dbCodes = pbSourceTypeCodesForLearningUi(sourceTypeCode);
    final rows = await _client
        .from('pb_documents')
        .select(
          'id,school_name,course_label,grade_label,source_type_code,curriculum_code,meta,source_filename,updated_at,exam_year,semester_label,exam_term_label',
        )
        .eq('academy_id', academyId)
        .eq('curriculum_code', curriculumCode)
        .inFilter('source_type_code', dbCodes)
        .eq('status', 'ready')
        .limit(limit);

    final list = <LearningProblemDocumentSummary>[];
    for (final item in (rows as List<dynamic>)) {
      final row = _mapOrEmpty(item);
      if (_isSavedSettingsDocumentRow(row)) continue;
      final docId = '${row['id'] ?? ''}'.trim();
      if (docId.isEmpty) continue;
      final courseLabel = '${row['course_label'] ?? ''}'.trim();
      final gradeLabel = '${row['grade_label'] ?? ''}'.trim();
      if (!_matchesLevel(schoolLevel, courseLabel, gradeLabel)) continue;
      if (!_matchesDetailedCourse(detailedCourse, courseLabel, gradeLabel)) {
        continue;
      }
      list.add(
        LearningProblemDocumentSummary(
          id: docId,
          schoolName: '${row['school_name'] ?? ''}'.trim(),
          sourceFilename: '${row['source_filename'] ?? ''}'.trim(),
          courseLabel: courseLabel,
          gradeLabel: gradeLabel,
          examYear: _intOrNull(row['exam_year']),
          semesterLabel: '${row['semester_label'] ?? ''}'.trim(),
          examTermLabel: '${row['exam_term_label'] ?? ''}'.trim(),
          updatedAt: _dateTimeOrNull(row['updated_at']),
        ),
      );
    }
    list.sort((a, b) {
      final ae = a.schoolName.trim().isEmpty;
      final be = b.schoolName.trim().isEmpty;
      if (ae != be) return ae ? 1 : -1;
      final c = a.schoolName.compareTo(b.schoolName);
      if (c != 0) return c;
      final ya = a.examYear;
      final yb = b.examYear;
      if (ya != yb) {
        if (ya == null && yb == null) {
          // fall through
        } else if (ya == null) {
          return 1;
        } else if (yb == null) {
          return -1;
        } else {
          final ycmp = yb.compareTo(ya);
          if (ycmp != 0) return ycmp;
        }
      }
      final ga = pbDocumentGradeSortRank(a.gradeLabel, a.courseLabel);
      final gb = pbDocumentGradeSortRank(b.gradeLabel, b.courseLabel);
      if (ga != gb) return ga.compareTo(gb);
      final f = a.sourceFilename.compareTo(b.sourceFilename);
      if (f != 0) return f;
      final ua = a.updatedAt;
      final ub = b.updatedAt;
      if (ua == null && ub == null) return a.id.compareTo(b.id);
      if (ua == null) return 1;
      if (ub == null) return -1;
      final t = ub.compareTo(ua);
      if (t != 0) return t;
      return a.id.compareTo(b.id);
    });
    return list;
  }

  Future<List<LearningProblemQuestion>> searchQuestions({
    required String academyId,
    required String curriculumCode,
    required String schoolLevel,
    required String detailedCourse,
    required String sourceTypeCode,
    String? schoolName,
    String? documentId,
    int limit = 400,
  }) async {
    final safeDocId = (documentId ?? '').trim();
    final safeSchoolName = (schoolName ?? '').trim();
    final dbSourceCodes = pbSourceTypeCodesForLearningUi(sourceTypeCode);
    final readyDocRows = await _client
        .from('pb_documents')
        .select(
          'id,source_filename,school_name,course_label,grade_label,curriculum_code,source_type_code,meta',
        )
        .eq('academy_id', academyId)
        .eq('curriculum_code', curriculumCode)
        .inFilter('source_type_code', dbSourceCodes)
        .eq('status', 'ready')
        .limit(4000);

    final readyDocIds = <String>{};
    final documentNameMap = <String, String>{};
    for (final item in (readyDocRows as List<dynamic>)) {
      final row = _mapOrEmpty(item);
      if (_isSavedSettingsDocumentRow(row)) continue;
      final docId = '${row['id'] ?? ''}'.trim();
      if (docId.isEmpty) continue;
      if (safeDocId.isNotEmpty && docId != safeDocId) {
        continue;
      }
      final docSchoolName = '${row['school_name'] ?? ''}'.trim();
      if (safeDocId.isEmpty &&
          safeSchoolName.isNotEmpty &&
          docSchoolName != safeSchoolName) {
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
              'question_uid',
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
          .inFilter('source_type_code', dbSourceCodes)
          .inFilter('document_id', docChunk);

      if (safeDocId.isEmpty && safeSchoolName.isNotEmpty) {
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

  Future<List<LearningProblemQuestion>> loadQuestionsByQuestionUids({
    required String academyId,
    required Iterable<String> questionUids,
  }) async {
    final safeAcademyId = academyId.trim();
    final requestedUids = questionUids
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (safeAcademyId.isEmpty || requestedUids.isEmpty) {
      return const <LearningProblemQuestion>[];
    }
    final uniqueRequested = <String>[];
    final seenRequested = <String>{};
    for (final uid in requestedUids) {
      if (!seenRequested.add(uid)) continue;
      uniqueRequested.add(uid);
    }

    const selectFields = 'id,question_uid,document_id,question_number,'
        'question_type,stem,choices,objective_choices,allow_objective,'
        'allow_subjective,objective_answer_key,subjective_answer,reviewer_notes,'
        'equations,source_page,source_order,curriculum_code,source_type_code,'
        'course_label,grade_label,exam_year,semester_label,exam_term_label,'
        'school_name,publisher_name,material_name,confidence,figure_refs,meta,'
        'created_at';
    final byUid = <String, Map<String, dynamic>>{};
    final byId = <String, Map<String, dynamic>>{};
    final docIds = <String>{};

    Future<void> collectByField({
      required String field,
      required List<String> values,
    }) async {
      for (final chunk in _chunkStrings(values, 250)) {
        dynamic rows;
        try {
          rows = await _client
              .from('pb_questions')
              .select(selectFields)
              .eq('academy_id', safeAcademyId)
              .inFilter(field, chunk);
        } catch (_) {
          continue;
        }
        for (final raw in _listOrEmpty(rows)) {
          final row = _mapOrEmpty(raw);
          if (row.isEmpty) continue;
          final uid = '${row['question_uid'] ?? ''}'.trim();
          final id = '${row['id'] ?? ''}'.trim();
          if (uid.isNotEmpty) {
            byUid.putIfAbsent(uid, () => row);
          }
          if (id.isNotEmpty) {
            byId.putIfAbsent(id, () => row);
          }
          final docId = '${row['document_id'] ?? ''}'.trim();
          if (docId.isNotEmpty) {
            docIds.add(docId);
          }
        }
      }
    }

    await collectByField(field: 'question_uid', values: uniqueRequested);
    final unresolved = uniqueRequested
        .where((uid) => !byUid.containsKey(uid) && !byId.containsKey(uid))
        .toList(growable: false);
    if (unresolved.isNotEmpty) {
      await collectByField(field: 'id', values: unresolved);
    }

    final docNameById = <String, String>{};
    if (docIds.isNotEmpty) {
      for (final chunk in _chunkStrings(docIds.toList(growable: false), 250)) {
        try {
          final rows = await _client
              .from('pb_documents')
              .select('id,source_filename')
              .eq('academy_id', safeAcademyId)
              .inFilter('id', chunk);
          for (final raw in _listOrEmpty(rows)) {
            final row = _mapOrEmpty(raw);
            final id = '${row['id'] ?? ''}'.trim();
            if (id.isEmpty) continue;
            docNameById[id] = '${row['source_filename'] ?? ''}'.trim();
          }
        } catch (_) {
          continue;
        }
      }
    }

    final out = <LearningProblemQuestion>[];
    for (final uid in uniqueRequested) {
      final row = byUid[uid] ?? byId[uid];
      if (row == null) continue;
      final docId = '${row['document_id'] ?? ''}'.trim();
      out.add(
        LearningProblemQuestion.fromMap(
          row,
          documentSourceName: docNameById[docId] ?? '',
        ),
      );
    }
    return out;
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
    required List<String> selectedQuestionUidsOrdered,
    required Map<String, String> questionModeByQuestionUid,
    required Map<String, dynamic> renderConfig,
    required String templateProfile,
    required String paperSize,
    required bool includeAnswerSheet,
    required bool includeExplanation,
    String displayName = '',
  }) async {
    if (!hasGateway) {
      throw Exception('세팅 저장은 게이트웨이 연결이 필요합니다.');
    }
    final selectedUids = selectedQuestionUidsOrdered
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    if (selectedUids.isEmpty) {
      throw Exception('저장할 문항이 비어 있습니다.');
    }
    final modeMap = <String, String>{};
    for (final uid in selectedUids) {
      final mode = (questionModeByQuestionUid[uid] ?? '').trim();
      if (mode.isEmpty) continue;
      modeMap[uid] = mode;
    }
    final payload = await _gatewayPost(
      '/pb/documents/save-settings',
      body: <String, dynamic>{
        'academyId': academyId,
        'sourceDocumentId': sourceDocumentId,
        'createdBy': _client.auth.currentUser?.id,
        'selectedQuestionUidsOrdered': selectedUids,
        'questionModeByQuestionUid': modeMap,
        'renderConfig': renderConfig,
        'templateProfile': templateProfile.trim(),
        'paperSize': paperSize.trim(),
        'includeAnswerSheet': includeAnswerSheet,
        'includeExplanation': includeExplanation,
        'displayName': displayName.trim(),
      },
    );
    return LearningProblemSavedSettingsDocumentResult.fromGatewayResponse(
      payload,
    );
  }

  Future<List<LearningProblemDocumentExportPreset>> listExportPresets({
    required String academyId,
    int limit = 120,
    int offset = 0,
  }) async {
    final safeLimit = limit.clamp(1, 500).toInt();
    final safeOffset = offset < 0 ? 0 : offset;
    if (hasGateway) {
      final json = await _gatewayGet(
        '/pb/export-presets',
        query: <String, String>{
          'academyId': academyId,
          'limit': '$safeLimit',
          'offset': '$safeOffset',
        },
      );
      return _listOrEmpty(json['presets'])
          .map((e) =>
              LearningProblemDocumentExportPreset.fromMap(_mapOrEmpty(e)))
          .where((e) => e.id.isNotEmpty)
          .toList(growable: false);
    }

    final rows = await _client
        .from('pb_export_presets')
        .select('*')
        .eq('academy_id', academyId)
        .order('created_at', ascending: false)
        .range(safeOffset, safeOffset + safeLimit - 1);
    final rawMaps = (rows as List<dynamic>)
        .map(_mapOrEmpty)
        .where((row) => row.isNotEmpty)
        .toList(growable: false);
    if (rawMaps.isEmpty) return const <LearningProblemDocumentExportPreset>[];

    final docIds = <String>{};
    for (final row in rawMaps) {
      final sourceId = '${row['source_document_id'] ?? ''}'.trim();
      final sourceIds = _listOrEmpty(row['source_document_ids'])
          .map((e) => '$e'.trim())
          .where((e) => e.isNotEmpty);
      final documentId = '${row['document_id'] ?? ''}'.trim();
      if (sourceId.isNotEmpty) docIds.add(sourceId);
      docIds.addAll(sourceIds);
      if (documentId.isNotEmpty) docIds.add(documentId);
    }
    final docNameById = <String, String>{};
    for (final chunk in _chunkStrings(docIds.toList(growable: false), 250)) {
      final docRows = await _client
          .from('pb_documents')
          .select('id,source_filename')
          .eq('academy_id', academyId)
          .inFilter('id', chunk);
      for (final item in (docRows as List<dynamic>)) {
        final row = _mapOrEmpty(item);
        final id = '${row['id'] ?? ''}'.trim();
        if (id.isEmpty) continue;
        docNameById[id] = '${row['source_filename'] ?? ''}'.trim();
      }
    }

    final enriched = rawMaps.map((row) {
      final sourceId = '${row['source_document_id'] ?? ''}'.trim();
      final documentId = '${row['document_id'] ?? ''}'.trim();
      final selectedUids = _listOrEmpty(
        _listOrEmpty(row['selected_question_uids']).isNotEmpty
            ? row['selected_question_uids']
            : row['selected_question_ids'],
      );
      final fallbackDisplay = '${row['display_name'] ?? ''}'.trim().isNotEmpty
          ? '${row['display_name'] ?? ''}'.trim()
          : (docNameById[documentId] ?? '');
      return <String, dynamic>{
        ...row,
        'display_name': fallbackDisplay,
        'source_document_name': docNameById[sourceId] ?? '',
        'document_name': docNameById[documentId] ?? '',
        'selected_question_count': selectedUids.length,
      };
    }).toList(growable: false);

    return enriched
        .map(LearningProblemDocumentExportPreset.fromMap)
        .where((e) => e.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<LearningProblemDocumentExportPreset?> renameExportPreset({
    required String academyId,
    required String presetId,
    required String displayName,
  }) async {
    final safeDisplayName = displayName.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (safeDisplayName.isEmpty) {
      throw Exception('프리셋 이름을 입력해 주세요.');
    }
    if (hasGateway) {
      final json = await _gatewayPost(
        '/pb/export-presets/$presetId/rename',
        body: <String, dynamic>{
          'academyId': academyId,
          'displayName': safeDisplayName,
        },
      );
      final presetMap = _mapOrEmpty(json['preset']);
      if (presetMap.isEmpty) return null;
      return LearningProblemDocumentExportPreset.fromMap(presetMap);
    }

    final updated = await _client
        .from('pb_export_presets')
        .update(<String, dynamic>{
          'display_name': safeDisplayName,
          'updated_at': DateTime.now().toIso8601String(),
        })
        .eq('academy_id', academyId)
        .eq('id', presetId)
        .select('*')
        .maybeSingle();
    if (updated == null) return null;
    return LearningProblemDocumentExportPreset.fromMap(_mapOrEmpty(updated));
  }

  Future<LearningProblemDocumentExportPreset?> updateExportPresetNaesinLink({
    required String academyId,
    required String presetId,
    String? naesinLinkKey,
  }) async {
    final safePresetId = presetId.trim();
    if (safePresetId.isEmpty) {
      throw Exception('presetId가 비어 있습니다.');
    }
    final safeLinkKey = (naesinLinkKey ?? '').trim();
    dynamic existing;
    try {
      existing = await _client
          .from('pb_export_presets')
          .select('*')
          .eq('academy_id', academyId)
          .eq('id', safePresetId)
          .maybeSingle();
    } catch (_) {
      return null;
    }
    if (existing == null) return null;
    final current = _mapOrEmpty(existing);
    final currentRenderConfig = _mapOrEmpty(
      current['render_config'] is Map
          ? current['render_config']
          : current['renderConfig'],
    );
    final nextRenderConfig = <String, dynamic>{...currentRenderConfig};
    if (safeLinkKey.isEmpty) {
      nextRenderConfig.remove('naesinLinkKey');
    } else {
      nextRenderConfig['naesinLinkKey'] = safeLinkKey;
    }
    dynamic updated;
    try {
      updated = await _client
          .from('pb_export_presets')
          .update(<String, dynamic>{
            'render_config': nextRenderConfig,
            'updated_at': DateTime.now().toIso8601String(),
          })
          .eq('academy_id', academyId)
          .eq('id', safePresetId)
          .select('*')
          .maybeSingle();
    } catch (_) {
      return null;
    }
    if (updated == null) return null;
    return LearningProblemDocumentExportPreset.fromMap(_mapOrEmpty(updated));
  }

  Future<LearningProblemDocumentExportPreset?> getExportPresetById({
    required String academyId,
    required String presetId,
  }) async {
    final safeAcademyId = academyId.trim();
    final safePresetId = presetId.trim();
    if (safeAcademyId.isEmpty || safePresetId.isEmpty) return null;

    if (hasGateway) {
      try {
        final json = await _gatewayGet(
          '/pb/export-presets/$safePresetId',
          query: <String, String>{'academyId': safeAcademyId},
        );
        final presetMap = _mapOrEmpty(json['preset']);
        if (presetMap.isNotEmpty) {
          return LearningProblemDocumentExportPreset.fromMap(presetMap);
        }
      } catch (_) {
        // fallback
      }
    }

    dynamic row;
    try {
      row = await _client
          .from('pb_export_presets')
          .select('*')
          .eq('academy_id', safeAcademyId)
          .eq('id', safePresetId)
          .maybeSingle();
    } catch (_) {
      return null;
    }
    if (row == null) return null;
    return LearningProblemDocumentExportPreset.fromMap(_mapOrEmpty(row));
  }

  Future<void> deleteExportPreset({
    required String academyId,
    required String presetId,
  }) async {
    final safeAcademyId = academyId.trim();
    final safePresetId = presetId.trim();
    if (safeAcademyId.isEmpty || safePresetId.isEmpty) return;
    if (hasGateway) {
      try {
        await _gatewayPost(
          '/pb/export-presets/$safePresetId/delete',
          body: <String, dynamic>{'academyId': safeAcademyId},
        );
        return;
      } catch (_) {
        // gateway 장애/네트워크 실패 시 DB 직접 삭제로 폴백
      }
    }
    await _client
        .from('pb_export_presets')
        .delete()
        .eq('academy_id', safeAcademyId)
        .eq('id', safePresetId);
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
          .or(
            'source_document_id.eq.$documentId,source_document_ids.cs.{$documentId}',
          )
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

  Future<List<LearningProblemLiveRelease>> listLiveReleases({
    required String academyId,
    int limit = 120,
    int offset = 0,
  }) async {
    final safeLimit = limit.clamp(1, 500).toInt();
    final safeOffset = offset < 0 ? 0 : offset;
    dynamic rows;
    try {
      rows = await _client
          .from('pb_live_releases')
          .select('*')
          .eq('academy_id', academyId)
          .order('updated_at', ascending: false)
          .range(safeOffset, safeOffset + safeLimit - 1);
    } catch (e) {
      if (_isMissingLiveReleaseRelationError(e)) {
        return const <LearningProblemLiveRelease>[];
      }
      rethrow;
    }
    return _listOrEmpty(rows)
        .map((e) => LearningProblemLiveRelease.fromMap(_mapOrEmpty(e)))
        .where((e) => e.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<LearningProblemLiveRelease?> getLiveReleaseById({
    required String academyId,
    required String liveReleaseId,
  }) async {
    final safeId = liveReleaseId.trim();
    if (safeId.isEmpty) return null;
    dynamic row;
    try {
      row = await _client
          .from('pb_live_releases')
          .select('*')
          .eq('academy_id', academyId)
          .eq('id', safeId)
          .maybeSingle();
    } catch (e) {
      if (_isMissingLiveReleaseRelationError(e)) {
        return null;
      }
      rethrow;
    }
    if (row == null) return null;
    return LearningProblemLiveRelease.fromMap(_mapOrEmpty(row));
  }

  Future<LearningProblemLiveRelease?> getLatestLiveReleaseForPreset({
    required String academyId,
    required String presetId,
  }) async {
    final safePresetId = presetId.trim();
    if (safePresetId.isEmpty) return null;
    dynamic row;
    try {
      row = await _client
          .from('pb_live_releases')
          .select('*')
          .eq('academy_id', academyId)
          .eq('preset_id', safePresetId)
          .order('updated_at', ascending: false)
          .limit(1)
          .maybeSingle();
    } catch (e) {
      if (_isMissingLiveReleaseRelationError(e)) {
        return null;
      }
      rethrow;
    }
    if (row == null) return null;
    return LearningProblemLiveRelease.fromMap(_mapOrEmpty(row));
  }

  Future<Map<String, LearningProblemLiveRelease>>
      getLatestLiveReleaseMapForPresets({
    required String academyId,
    required Iterable<String> presetIds,
  }) async {
    final safePresetIds = presetIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (academyId.trim().isEmpty || safePresetIds.isEmpty) {
      return const <String, LearningProblemLiveRelease>{};
    }
    final out = <String, LearningProblemLiveRelease>{};
    const chunkSize = 120;
    for (var offset = 0; offset < safePresetIds.length; offset += chunkSize) {
      final end = (offset + chunkSize < safePresetIds.length)
          ? offset + chunkSize
          : safePresetIds.length;
      final chunk = safePresetIds.sublist(offset, end);
      dynamic rows;
      try {
        rows = await _client
            .from('pb_live_releases')
            .select('*')
            .eq('academy_id', academyId)
            .inFilter('preset_id', chunk)
            .order('updated_at', ascending: false);
      } catch (e) {
        if (_isMissingLiveReleaseRelationError(e)) {
          return const <String, LearningProblemLiveRelease>{};
        }
        rethrow;
      }
      for (final raw in _listOrEmpty(rows)) {
        final release = LearningProblemLiveRelease.fromMap(_mapOrEmpty(raw));
        final key = release.presetId.trim();
        if (key.isEmpty || out.containsKey(key)) continue;
        out[key] = release;
      }
    }
    return out;
  }

  Future<LearningProblemLiveRelease?> upsertLiveReleaseForPreset({
    required String academyId,
    required String presetId,
    List<String> sourceDocumentIds = const <String>[],
    String templateProfile = 'csat',
    String paperSize = 'A4',
    String activeExportJobId = '',
    String note = '',
    Map<String, dynamic>? policy,
  }) async {
    final safePresetId = presetId.trim();
    if (safePresetId.isEmpty) {
      throw Exception('presetId가 비어 있습니다.');
    }
    final safeSourceDocumentIds = sourceDocumentIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final safePolicy = policy == null || policy.isEmpty
        ? <String, dynamic>{
            'applyStatuses': const <String>['assigned', 'in_progress'],
          }
        : Map<String, dynamic>.from(policy);
    final userId = _client.auth.currentUser?.id;
    final basePayload = <String, dynamic>{
      'academy_id': academyId,
      'preset_id': safePresetId,
      'source_document_ids': safeSourceDocumentIds,
      'template_profile':
          templateProfile.trim().isEmpty ? 'csat' : templateProfile.trim(),
      'paper_size': paperSize.trim().isEmpty ? 'A4' : paperSize.trim(),
      'active_export_job_id':
          activeExportJobId.trim().isEmpty ? null : activeExportJobId.trim(),
      'policy': safePolicy,
      'note': note.trim().isEmpty ? null : note.trim(),
      'updated_by': userId,
    };
    final existing = await getLatestLiveReleaseForPreset(
      academyId: academyId,
      presetId: safePresetId,
    );
    dynamic row;
    try {
      if (existing != null && existing.id.isNotEmpty) {
        row = await _client
            .from('pb_live_releases')
            .update(basePayload)
            .eq('academy_id', academyId)
            .eq('id', existing.id)
            .select('*')
            .maybeSingle();
      } else {
        row = await _client
            .from('pb_live_releases')
            .insert(<String, dynamic>{
              ...basePayload,
              'created_by': userId,
            })
            .select('*')
            .maybeSingle();
      }
    } catch (e) {
      if (_isMissingLiveReleaseRelationError(e)) {
        return null;
      }
      rethrow;
    }
    if (row == null) return null;
    return LearningProblemLiveRelease.fromMap(_mapOrEmpty(row));
  }

  Future<LearningProblemExportJob> createExportJob({
    required String academyId,
    required String documentId,
    required String templateProfile,
    required String paperSize,
    required bool includeAnswerSheet,
    required bool includeExplanation,
    required List<String> selectedQuestionUids,
    String renderHash = '',
    bool previewOnly = false,
    Map<String, dynamic> options = const <String, dynamic>{},
  }) async {
    final safeRenderHash = renderHash.trim();
    final selectedUids = selectedQuestionUids
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
    final payloadOptions = <String, dynamic>{
      ...options,
      // 워커가 uid 순서 fallback을 id 배열로 잘못 해석하지 않도록
      // 선택 uid 배열을 명시적으로 전달한다.
      'selectedQuestionUids': selectedUids,
      'selectedQuestionIds': selectedUids,
      if (!(options.containsKey('selectedQuestionUidsOrdered')))
        'selectedQuestionUidsOrdered': selectedUids,
      if (!(options.containsKey('selectedQuestionIdsOrdered')))
        'selectedQuestionIdsOrdered': selectedUids,
    };
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
          'selectedQuestionUids': selectedUids,
          'renderHash': safeRenderHash,
          'previewOnly': previewOnly,
          'options': payloadOptions,
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
      'selected_question_ids': selectedUids,
      'options': payloadOptions,
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

  Future<String> regenerateExportSignedUrl({
    required String academyId,
    required String exportJobId,
    int ttlSeconds = 60 * 15,
  }) async {
    final safeJobId = exportJobId.trim();
    if (safeJobId.isEmpty) return '';
    final safeTtl = ttlSeconds.clamp(60, 60 * 60 * 24 * 7).toInt();
    if (hasGateway) {
      try {
        final json = await _gatewayGet(
          '/pb/jobs/export/$safeJobId/signed-url',
          query: <String, String>{
            'academyId': academyId,
            'ttlSeconds': '$safeTtl',
          },
        );
        return '${json['signedUrl'] ?? ''}'.trim();
      } catch (_) {
        // fallback
      }
    }

    final row = await _client
        .from('pb_exports')
        .select('output_storage_bucket,output_storage_path,status')
        .eq('academy_id', academyId)
        .eq('id', safeJobId)
        .maybeSingle();
    if (row == null) return '';
    final map = Map<String, dynamic>.from(row as Map<dynamic, dynamic>);
    if ('${map['status'] ?? ''}'.trim() != 'completed') return '';
    final bucket = '${map['output_storage_bucket'] ?? ''}'.trim();
    final path = '${map['output_storage_path'] ?? ''}'.trim();
    if (bucket.isEmpty || path.isEmpty) return '';
    try {
      return await _client.storage.from(bucket).createSignedUrl(path, safeTtl);
    } catch (_) {
      return '';
    }
  }

  Future<Map<String, dynamic>> cleanupLegacySavedSettingsClones({
    required String academyId,
    bool dryRun = true,
    int limit = 300,
  }) async {
    if (hasGateway) {
      final json = await _gatewayPost(
        '/pb/admin/cleanup-legacy-saved-settings',
        body: <String, dynamic>{
          'academyId': academyId,
          'dryRun': dryRun,
          'limit': limit.clamp(1, 5000),
        },
      );
      return _mapOrEmpty(json);
    }

    final rows = await _client
        .from('pb_documents')
        .select('id,source_filename,created_at,meta')
        .eq('academy_id', academyId)
        .order('created_at', ascending: false)
        .limit(limit.clamp(1, 2000));
    final docs = (rows as List<dynamic>).map(_mapOrEmpty).where((row) {
      final meta = _mapOrEmpty(row['meta']);
      final saved = meta['saved_settings'] ?? meta['savedSettings'];
      return saved is Map;
    }).toList(growable: false);
    final ids = docs
        .map((row) => '${row['id'] ?? ''}'.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    if (dryRun || ids.isEmpty) {
      return <String, dynamic>{
        'ok': true,
        'dryRun': dryRun,
        'legacyDocumentCount': ids.length,
        'deletedDocumentCount': 0,
        'documents': docs,
      };
    }

    for (final chunk in _chunkStrings(ids, 150)) {
      await _client
          .from('pb_documents')
          .delete()
          .eq('academy_id', academyId)
          .inFilter('id', chunk);
    }
    return <String, dynamic>{
      'ok': true,
      'dryRun': false,
      'legacyDocumentCount': ids.length,
      'deletedDocumentCount': ids.length,
      'documents': docs,
    };
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

  Future<Map<String, String>> batchRenderThumbnails({
    required String academyId,
    required List<String> questionIds,
    String documentId = '',
    Map<String, dynamic>? renderConfig,
    String templateProfile = '',
    String paperSize = '',
    Map<String, String> questionModeByQuestionUid = const <String, String>{},
  }) async {
    if (!hasGateway || questionIds.isEmpty) return {};
    try {
      final body = <String, dynamic>{
        'academyId': academyId,
        'questionIds': questionIds,
        'mathEngine': 'xelatex',
      };
      if (documentId.trim().isNotEmpty) body['documentId'] = documentId.trim();
      if (questionModeByQuestionUid.isNotEmpty) {
        body['questionModeByQuestionUid'] = questionModeByQuestionUid;
      }
      if (templateProfile.trim().isNotEmpty) {
        body['templateProfile'] = templateProfile.trim();
      }
      if (paperSize.trim().isNotEmpty) body['paperSize'] = paperSize.trim();
      if (renderConfig != null && renderConfig.isNotEmpty) {
        body['renderConfig'] = renderConfig;
      }

      final result = await _gatewayPost('/pb/preview/batch-render', body: body);
      final thumbnails = result['thumbnails'];
      if (thumbnails is! Map) return {};

      final out = <String, String>{};
      for (final entry in thumbnails.entries) {
        final qid = '${entry.key}'.trim();
        final value = entry.value;
        if (value is Map) {
          final url = '${value['url'] ?? ''}'.trim();
          if (qid.isNotEmpty && url.isNotEmpty) out[qid] = url;
        }
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<Map<String, LearningProblemPdfPreviewArtifact>>
      fetchQuestionPdfPreviewArtifacts({
    required String academyId,
    required List<String> questionIds,
    String documentId = '',
    Map<String, dynamic>? renderConfig,
    String templateProfile = '',
    String paperSize = '',
    bool createJobs = true,
  }) async {
    if (!hasGateway || questionIds.isEmpty) {
      return <String, LearningProblemPdfPreviewArtifact>{};
    }
    try {
      final body = <String, dynamic>{
        'academyId': academyId,
        'questionIds': questionIds,
        'createJobs': createJobs,
        'mathEngine': 'xelatex',
      };
      if (documentId.trim().isNotEmpty) body['documentId'] = documentId.trim();
      if (templateProfile.trim().isNotEmpty) {
        body['templateProfile'] = templateProfile.trim();
      }
      if (paperSize.trim().isNotEmpty) body['paperSize'] = paperSize.trim();
      if (renderConfig != null && renderConfig.isNotEmpty) {
        body['renderConfig'] = renderConfig;
      }

      final result = await _gatewayPost(
        '/pb/preview/pdf-artifacts',
        body: body,
      );
      final defaultPollAfterMs = _intOrZero(result['pollAfterMs']);
      final artifacts = result['artifacts'];
      if (artifacts is! List) {
        return <String, LearningProblemPdfPreviewArtifact>{};
      }

      final out = <String, LearningProblemPdfPreviewArtifact>{};
      for (final one in artifacts) {
        if (one is! Map) continue;
        final artifact = LearningProblemPdfPreviewArtifact.fromMap(
          one.map((key, value) => MapEntry('$key', value)),
          defaultPollAfterMs: defaultPollAfterMs,
        );
        if (artifact.questionId.isEmpty) continue;
        out[artifact.questionId] = artifact;
      }
      return out;
    } catch (_) {
      return <String, LearningProblemPdfPreviewArtifact>{};
    }
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

bool _isSavedSettingsDocumentRow(Map<String, dynamic> row) {
  final meta = _mapOrEmpty(row['meta']);
  if (meta.isEmpty) return false;
  return meta.containsKey('saved_settings') ||
      meta.containsKey('savedSettings');
}

bool _isMissingLiveReleaseRelationError(Object error) {
  final msg = error.toString().toLowerCase();
  return msg.contains('pb_live_releases') &&
      (msg.contains('does not exist') ||
          msg.contains('column') ||
          msg.contains('schema cache') ||
          msg.contains('relation'));
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
