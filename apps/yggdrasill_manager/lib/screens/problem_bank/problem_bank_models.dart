class ProblemBankDocument {
  const ProblemBankDocument({
    required this.id,
    required this.academyId,
    required this.sourceFilename,
    required this.sourceStorageBucket,
    required this.sourceStoragePath,
    required this.status,
    required this.examProfile,
    required this.createdAt,
    required this.updatedAt,
    required this.curriculumCode,
    required this.sourceTypeCode,
    required this.courseLabel,
    required this.gradeLabel,
    required this.semesterLabel,
    required this.examTermLabel,
    required this.schoolName,
    required this.publisherName,
    required this.materialName,
    this.examYear,
    this.classificationDetail = const <String, dynamic>{},
    this.meta = const <String, dynamic>{},
  });

  final String id;
  final String academyId;
  final String sourceFilename;
  final String sourceStorageBucket;
  final String sourceStoragePath;
  final String status;
  final String examProfile;
  final DateTime? createdAt;
  final DateTime? updatedAt;
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
  final Map<String, dynamic> classificationDetail;
  final Map<String, dynamic> meta;

  factory ProblemBankDocument.fromMap(Map<String, dynamic> map) {
    final meta = _mapOrEmpty(map['meta']);
    final sourceRaw = _mapOrEmpty(meta['source_classification']);
    final naesin = _mapOrEmpty(sourceRaw['naesin']);
    final privateMaterial = sourceRaw['private_material'] == true;
    final mockPast = sourceRaw['mock_past_exam'] == true;
    final schoolPast = sourceRaw['school_past_exam'] == true;
    final fallbackSourceType = privateMaterial
        ? 'market_book'
        : mockPast
            ? 'mock_past'
            : schoolPast
                ? 'school_past'
                : 'school_past';
    return ProblemBankDocument(
      id: '${map['id'] ?? ''}',
      academyId: '${map['academy_id'] ?? ''}',
      sourceFilename: '${map['source_filename'] ?? ''}',
      sourceStorageBucket: '${map['source_storage_bucket'] ?? ''}',
      sourceStoragePath: '${map['source_storage_path'] ?? ''}',
      status: '${map['status'] ?? ''}',
      examProfile: '${map['exam_profile'] ?? ''}',
      createdAt: _dateTimeOrNull(map['created_at']),
      updatedAt: _dateTimeOrNull(map['updated_at']),
      curriculumCode: '${map['curriculum_code'] ?? 'rev_2022'}'.trim().isEmpty
          ? 'rev_2022'
          : '${map['curriculum_code']}',
      sourceTypeCode:
          '${map['source_type_code'] ?? fallbackSourceType}'.trim().isEmpty
              ? fallbackSourceType
              : '${map['source_type_code']}',
      courseLabel: '${map['course_label'] ?? ''}'.trim(),
      gradeLabel: '${map['grade_label'] ?? naesin['grade'] ?? ''}'.trim(),
      examYear: _intOrNull(map['exam_year']) ?? _intOrNull(naesin['year']),
      semesterLabel:
          '${map['semester_label'] ?? naesin['semester'] ?? ''}'.trim(),
      examTermLabel:
          '${map['exam_term_label'] ?? naesin['exam_term'] ?? ''}'.trim(),
      schoolName: '${map['school_name'] ?? naesin['school_name'] ?? ''}'.trim(),
      publisherName: '${map['publisher_name'] ?? ''}'.trim(),
      materialName: '${map['material_name'] ?? ''}'.trim(),
      classificationDetail: _mapOrEmpty(map['classification_detail']),
      meta: meta,
    );
  }
}

class ProblemBankExtractJob {
  const ProblemBankExtractJob({
    required this.id,
    required this.academyId,
    required this.documentId,
    required this.status,
    required this.retryCount,
    required this.maxRetries,
    required this.workerName,
    required this.resultSummary,
    required this.errorCode,
    required this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
    this.startedAt,
    this.finishedAt,
  });

  final String id;
  final String academyId;
  final String documentId;
  final String status;
  final int retryCount;
  final int maxRetries;
  final String workerName;
  final Map<String, dynamic> resultSummary;
  final String errorCode;
  final String errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  bool get isTerminal =>
      status == 'completed' ||
      status == 'review_required' ||
      status == 'failed' ||
      status == 'cancelled';

  factory ProblemBankExtractJob.fromMap(Map<String, dynamic> map) {
    return ProblemBankExtractJob(
      id: '${map['id'] ?? ''}',
      academyId: '${map['academy_id'] ?? ''}',
      documentId: '${map['document_id'] ?? ''}',
      status: '${map['status'] ?? ''}',
      retryCount: _intOrZero(map['retry_count']),
      maxRetries: _intOrZero(map['max_retries']),
      workerName: '${map['worker_name'] ?? ''}',
      resultSummary: _mapOrEmpty(map['result_summary']),
      errorCode: '${map['error_code'] ?? ''}',
      errorMessage: '${map['error_message'] ?? ''}',
      createdAt: _dateTimeOrNull(map['created_at']) ?? DateTime.now(),
      updatedAt: _dateTimeOrNull(map['updated_at']) ?? DateTime.now(),
      startedAt: _dateTimeOrNull(map['started_at']),
      finishedAt: _dateTimeOrNull(map['finished_at']),
    );
  }
}

class ProblemBankFigureJob {
  const ProblemBankFigureJob({
    required this.id,
    required this.academyId,
    required this.documentId,
    required this.questionId,
    required this.status,
    required this.provider,
    required this.model,
    required this.workerName,
    required this.resultSummary,
    required this.errorCode,
    required this.errorMessage,
    required this.createdAt,
    required this.updatedAt,
    this.startedAt,
    this.finishedAt,
  });

  final String id;
  final String academyId;
  final String documentId;
  final String questionId;
  final String status;
  final String provider;
  final String model;
  final String workerName;
  final Map<String, dynamic> resultSummary;
  final String errorCode;
  final String errorMessage;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  bool get isTerminal =>
      status == 'completed' ||
      status == 'review_required' ||
      status == 'failed' ||
      status == 'cancelled';

  factory ProblemBankFigureJob.fromMap(Map<String, dynamic> map) {
    return ProblemBankFigureJob(
      id: '${map['id'] ?? ''}',
      academyId: '${map['academy_id'] ?? ''}',
      documentId: '${map['document_id'] ?? ''}',
      questionId: '${map['question_id'] ?? ''}',
      status: '${map['status'] ?? ''}',
      provider: '${map['provider'] ?? ''}',
      model: '${map['model_name'] ?? ''}',
      workerName: '${map['worker_name'] ?? ''}',
      resultSummary: _mapOrEmpty(map['result_summary']),
      errorCode: '${map['error_code'] ?? ''}',
      errorMessage: '${map['error_message'] ?? ''}',
      createdAt: _dateTimeOrNull(map['created_at']) ?? DateTime.now(),
      updatedAt: _dateTimeOrNull(map['updated_at']) ?? DateTime.now(),
      startedAt: _dateTimeOrNull(map['started_at']),
      finishedAt: _dateTimeOrNull(map['finished_at']),
    );
  }
}

class ProblemBankChoice {
  const ProblemBankChoice({
    required this.label,
    required this.text,
  });

  final String label;
  final String text;

  factory ProblemBankChoice.fromMap(Map<String, dynamic> map) {
    return ProblemBankChoice(
      label: '${map['label'] ?? ''}',
      text: '${map['text'] ?? ''}',
    );
  }

  Map<String, dynamic> toMap() => {
        'label': label,
        'text': text,
      };
}

class ProblemBankEquation {
  const ProblemBankEquation({
    required this.token,
    required this.raw,
    required this.latex,
    required this.mathml,
    required this.confidence,
  });

  final String token;
  final String raw;
  final String latex;
  final String mathml;
  final double confidence;

  factory ProblemBankEquation.fromMap(Map<String, dynamic> map) {
    return ProblemBankEquation(
      token: '${map['token'] ?? ''}',
      raw: '${map['raw'] ?? ''}',
      latex: '${map['latex'] ?? ''}',
      mathml: '${map['mathml'] ?? ''}',
      confidence: _doubleOrZero(map['confidence']),
    );
  }

  Map<String, dynamic> toMap() => {
        if (token.trim().isNotEmpty) 'token': token,
        'raw': raw,
        'latex': latex,
        'mathml': mathml,
        'confidence': confidence,
      };
}

class ProblemBankQuestion {
  const ProblemBankQuestion({
    required this.id,
    required this.academyId,
    required this.documentId,
    required this.extractJobId,
    required this.sourcePage,
    required this.sourceOrder,
    required this.questionNumber,
    required this.questionType,
    required this.stem,
    required this.choices,
    required this.figureRefs,
    required this.equations,
    required this.sourceAnchors,
    required this.confidence,
    required this.flags,
    required this.isChecked,
    required this.reviewerNotes,
    required this.allowObjective,
    required this.allowSubjective,
    required this.objectiveChoices,
    required this.objectiveAnswerKey,
    required this.subjectiveAnswer,
    required this.objectiveGenerated,
    required this.curriculumCode,
    required this.sourceTypeCode,
    required this.courseLabel,
    required this.gradeLabel,
    required this.semesterLabel,
    required this.examTermLabel,
    required this.schoolName,
    required this.publisherName,
    required this.materialName,
    required this.classificationDetail,
    required this.meta,
    required this.createdAt,
    required this.updatedAt,
    this.examYear,
  });

  final String id;
  final String academyId;
  final String documentId;
  final String extractJobId;
  final int sourcePage;
  final int sourceOrder;
  final String questionNumber;
  final String questionType;
  final String stem;
  final List<ProblemBankChoice> choices;
  final List<String> figureRefs;
  final List<ProblemBankEquation> equations;
  final Map<String, dynamic> sourceAnchors;
  final double confidence;
  final List<String> flags;
  final bool isChecked;
  final String reviewerNotes;
  final bool allowObjective;
  final bool allowSubjective;
  final List<ProblemBankChoice> objectiveChoices;
  final String objectiveAnswerKey;
  final String subjectiveAnswer;
  final bool objectiveGenerated;
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
  final Map<String, dynamic> classificationDetail;
  final Map<String, dynamic> meta;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  String get renderedStem {
    final base = stem.trim();
    if (base.isEmpty) {
      return equations
          .map(_bestEquationText)
          .where((t) => t.isNotEmpty)
          .join(' ')
          .trim();
    }
    return _renderTextWithEquations(base);
  }

  String _bestEquationText(ProblemBankEquation equation) {
    final latex = _stripPotentialWatermarkText(equation.latex);
    if (latex.isNotEmpty) return latex;
    return _stripPotentialWatermarkText(equation.raw);
  }

  String renderChoiceText(ProblemBankChoice choice) {
    return _renderTextWithEquations(choice.text);
  }

  String _renderTextWithEquations(String input) {
    final raw = input.trim();
    if (raw.isEmpty || equations.isEmpty) {
      return _stripPotentialWatermarkText(raw);
    }

    var seq = 0;
    final tokenMap = <String, ProblemBankEquation>{};
    for (final eq in equations) {
      final token = eq.token.trim();
      if (token.isNotEmpty) {
        tokenMap[token] = eq;
      }
    }

    final merged = raw.replaceAllMapped(
      RegExp(r'\[\[PB_EQ_[^\]]+\]\]|\[수식\]'),
      (m) {
        final key = m.group(0) ?? '';
        ProblemBankEquation? target;
        if (tokenMap.containsKey(key)) {
          target = tokenMap[key];
        } else {
          final idxMatch = RegExp(r'^\[\[PB_EQ_\d+_(\d+)\]\]$').firstMatch(key);
          final idxByToken = int.tryParse(idxMatch?.group(1) ?? '');
          if (idxByToken != null &&
              idxByToken >= 0 &&
              idxByToken < equations.length) {
            target = equations[idxByToken];
          }
        }
        if (target == null && seq < equations.length) {
          target = equations[seq];
          seq += 1;
        } else if (seq < equations.length) {
          // token을 직접 매칭한 경우에는 순차 포인터를 보존한다.
        }
        final eqText = target == null ? '' : _bestEquationText(target);
        return eqText.isEmpty ? '[수식]' : eqText;
      },
    );
    return _stripPotentialWatermarkText(merged);
  }

  String get previewEquation {
    if (equations.isNotEmpty) {
      final firstEq = _bestEquationText(equations.first);
      if (firstEq.isNotEmpty) return firstEq;
    }
    final normalizedStem = renderedStem;
    if (normalizedStem.trim().isNotEmpty) {
      final compactStem = normalizedStem.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (compactStem.length <= 54) return compactStem;
      return '${compactStem.substring(0, 54)}...';
    }
    return '-';
  }

  ProblemBankQuestion copyWith({
    String? questionType,
    String? stem,
    List<ProblemBankChoice>? choices,
    bool? allowObjective,
    bool? allowSubjective,
    List<ProblemBankChoice>? objectiveChoices,
    String? objectiveAnswerKey,
    String? subjectiveAnswer,
    bool? objectiveGenerated,
    List<String>? figureRefs,
    List<ProblemBankEquation>? equations,
    bool? isChecked,
    String? reviewerNotes,
    List<String>? flags,
    String? curriculumCode,
    String? sourceTypeCode,
    String? courseLabel,
    String? gradeLabel,
    int? examYear,
    String? semesterLabel,
    String? examTermLabel,
    String? schoolName,
    String? publisherName,
    String? materialName,
    Map<String, dynamic>? classificationDetail,
    Map<String, dynamic>? meta,
  }) {
    return ProblemBankQuestion(
      id: id,
      academyId: academyId,
      documentId: documentId,
      extractJobId: extractJobId,
      sourcePage: sourcePage,
      sourceOrder: sourceOrder,
      questionNumber: questionNumber,
      questionType: questionType ?? this.questionType,
      stem: stem ?? this.stem,
      choices: choices ?? this.choices,
      figureRefs: figureRefs ?? this.figureRefs,
      equations: equations ?? this.equations,
      sourceAnchors: sourceAnchors,
      confidence: confidence,
      flags: flags ?? this.flags,
      isChecked: isChecked ?? this.isChecked,
      reviewerNotes: reviewerNotes ?? this.reviewerNotes,
      allowObjective: allowObjective ?? this.allowObjective,
      allowSubjective: allowSubjective ?? this.allowSubjective,
      objectiveChoices: objectiveChoices ?? this.objectiveChoices,
      objectiveAnswerKey: objectiveAnswerKey ?? this.objectiveAnswerKey,
      subjectiveAnswer: subjectiveAnswer ?? this.subjectiveAnswer,
      objectiveGenerated: objectiveGenerated ?? this.objectiveGenerated,
      curriculumCode: curriculumCode ?? this.curriculumCode,
      sourceTypeCode: sourceTypeCode ?? this.sourceTypeCode,
      courseLabel: courseLabel ?? this.courseLabel,
      gradeLabel: gradeLabel ?? this.gradeLabel,
      examYear: examYear ?? this.examYear,
      semesterLabel: semesterLabel ?? this.semesterLabel,
      examTermLabel: examTermLabel ?? this.examTermLabel,
      schoolName: schoolName ?? this.schoolName,
      publisherName: publisherName ?? this.publisherName,
      materialName: materialName ?? this.materialName,
      classificationDetail: classificationDetail ?? this.classificationDetail,
      meta: meta ?? this.meta,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  factory ProblemBankQuestion.fromMap(Map<String, dynamic> map) {
    final meta = _mapOrEmpty(map['meta']);
    final questionType = '${map['question_type'] ?? ''}';
    final choicesList = _listOrEmpty(map['choices'])
        .map((e) => ProblemBankChoice.fromMap(_mapOrEmpty(e)))
        .toList(growable: false);
    final objectiveChoicesList = _listOrEmpty(map['objective_choices'])
        .map((e) => ProblemBankChoice.fromMap(_mapOrEmpty(e)))
        .toList(growable: false);
    final effectiveObjectiveChoices =
        objectiveChoicesList.isNotEmpty ? objectiveChoicesList : choicesList;
    final objectiveAnswerKey = _normalizeAnswerKey(
      '${map['objective_answer_key'] ?? meta['objective_answer_key'] ?? meta['answer_key'] ?? ''}',
    );
    final subjectiveAnswerRaw = _normalizeAnswerKey(
      '${map['subjective_answer'] ?? meta['subjective_answer'] ?? ''}',
    );
    final shouldMapLegacyObjective =
        questionType.contains('객관식') || choicesList.length >= 2;
    final subjectiveAnswer = subjectiveAnswerRaw.isNotEmpty
        ? (shouldMapLegacyObjective &&
                _looksLikeObjectiveKeyAnswer(subjectiveAnswerRaw)
            ? _objectiveAnswerToSubjective(
                subjectiveAnswerRaw,
                effectiveObjectiveChoices,
              )
            : subjectiveAnswerRaw)
        : _objectiveAnswerToSubjective(
            objectiveAnswerKey,
            effectiveObjectiveChoices,
          );
    final equationsList = _listOrEmpty(map['equations'])
        .map((e) => ProblemBankEquation.fromMap(_mapOrEmpty(e)))
        .toList(growable: false);
    final sourceRaw = _mapOrEmpty(meta['source_classification']);
    final naesin = _mapOrEmpty(sourceRaw['naesin']);
    final privateMaterial = sourceRaw['private_material'] == true;
    final mockPast = sourceRaw['mock_past_exam'] == true;
    final schoolPast = sourceRaw['school_past_exam'] == true;
    final fallbackSourceType = privateMaterial
        ? 'market_book'
        : mockPast
            ? 'mock_past'
            : schoolPast
                ? 'school_past'
                : 'school_past';
    return ProblemBankQuestion(
      id: '${map['id'] ?? ''}',
      academyId: '${map['academy_id'] ?? ''}',
      documentId: '${map['document_id'] ?? ''}',
      extractJobId: '${map['extract_job_id'] ?? ''}',
      sourcePage: _intOrZero(map['source_page']),
      sourceOrder: _intOrZero(map['source_order']),
      questionNumber: '${map['question_number'] ?? ''}',
      questionType: questionType,
      stem: '${map['stem'] ?? ''}',
      choices: choicesList,
      figureRefs: _listOrEmpty(map['figure_refs'])
          .map((e) => '$e')
          .toList(growable: false),
      equations: equationsList,
      sourceAnchors: _mapOrEmpty(map['source_anchors']),
      confidence: _doubleOrZero(map['confidence']),
      flags:
          _listOrEmpty(map['flags']).map((e) => '$e').toList(growable: false),
      isChecked: map['is_checked'] == true,
      reviewerNotes: '${map['reviewer_notes'] ?? ''}',
      allowObjective: map.containsKey('allow_objective')
          ? map['allow_objective'] != false
          : meta['allow_objective'] != false,
      allowSubjective: map.containsKey('allow_subjective')
          ? map['allow_subjective'] != false
          : meta['allow_subjective'] != false,
      objectiveChoices: effectiveObjectiveChoices,
      objectiveAnswerKey: objectiveAnswerKey,
      subjectiveAnswer: subjectiveAnswer,
      objectiveGenerated: map['objective_generated'] == true ||
          meta['objective_generated'] == true,
      curriculumCode: '${map['curriculum_code'] ?? 'rev_2022'}'.trim().isEmpty
          ? 'rev_2022'
          : '${map['curriculum_code']}',
      sourceTypeCode:
          '${map['source_type_code'] ?? fallbackSourceType}'.trim().isEmpty
              ? fallbackSourceType
              : '${map['source_type_code']}',
      courseLabel: '${map['course_label'] ?? ''}'.trim(),
      gradeLabel: '${map['grade_label'] ?? naesin['grade'] ?? ''}'.trim(),
      examYear: _intOrNull(map['exam_year']) ?? _intOrNull(naesin['year']),
      semesterLabel:
          '${map['semester_label'] ?? naesin['semester'] ?? ''}'.trim(),
      examTermLabel:
          '${map['exam_term_label'] ?? naesin['exam_term'] ?? ''}'.trim(),
      schoolName: '${map['school_name'] ?? naesin['school_name'] ?? ''}'.trim(),
      publisherName: '${map['publisher_name'] ?? ''}'.trim(),
      materialName: '${map['material_name'] ?? ''}'.trim(),
      classificationDetail: _mapOrEmpty(map['classification_detail']),
      meta: meta,
      createdAt: _dateTimeOrNull(map['created_at']),
      updatedAt: _dateTimeOrNull(map['updated_at']),
    );
  }
}

String _stripPotentialWatermarkText(String value) {
  var out = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (out.isEmpty) return '';
  out = out
      .replaceAll(RegExp(r'(?:중등|고등)\s*내신기출\s*\d{4}\.\d{2}\.\d{2}'), '')
      .replaceAll(RegExp(r'수식입니다\.?'), '')
      .replaceAll(RegExp(r'무단\s*배포\s*금지'), '')
      .trim();
  out = out
      .replaceAll(
        RegExp(r'^[가-힣]{2,4}[\s\u00A0\u2000-\u200D\u2060]*(?=<\s*보\s*기>)'),
        '',
      )
      .replaceAllMapped(
        RegExp(
          r'(^|[\s\u00A0\u2000-\u200D\u2060])[가-힣]{2,4}[\s\u00A0\u2000-\u200D\u2060]*(?=<\s*보\s*기>)',
        ),
        (m) => m.group(1) ?? '',
      )
      .trim();
  final lead = RegExp(r'^([가-힣]{2,4})\s+(.+)$').firstMatch(out);
  if (lead != null && _isLikelyKoreanPersonName(lead.group(1) ?? '')) {
    final rest = (lead.group(2) ?? '').trim();
    final restLooksMath =
        RegExp(r'([=+\-*/^]|\\|over|\[수식\]|[\[\]{}()0-9])').hasMatch(rest);
    final restLooksMeta = rest.startsWith('[정답]') || rest.startsWith('<보기>');
    final restLooksPrompt = RegExp(r'(다음|옳은|설명|구하|계산|고른|것은)').hasMatch(rest);
    if (restLooksMath || restLooksMeta || restLooksPrompt) {
      out = rest;
    }
  }
  return out.trim();
}

bool _isLikelyKoreanPersonName(String value) {
  final input = value.trim();
  if (input.isEmpty) return false;
  if (RegExp(r'^(남궁|황보|제갈|선우|서문|독고|사공)[가-힣]{1,2}$').hasMatch(input)) {
    return true;
  }
  return RegExp(
    r'^[김이박최정강조윤장임한오서신권황안송류전홍고문양손배백허남심노하곽성차주우구민유나진지엄채원천방공현함변염여추도소석선마길연위표명기반왕금옥육인맹제모][가-힣]{1,2}$',
  ).hasMatch(input);
}

class ProblemBankExportJob {
  const ProblemBankExportJob({
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
    required this.pageCount,
    required this.errorCode,
    required this.errorMessage,
    required this.options,
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
  final int pageCount;
  final String errorCode;
  final String errorMessage;
  final Map<String, dynamic> options;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  bool get isTerminal =>
      status == 'completed' || status == 'failed' || status == 'cancelled';

  factory ProblemBankExportJob.fromMap(Map<String, dynamic> map) {
    return ProblemBankExportJob(
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
      pageCount: _intOrZero(map['page_count']),
      errorCode: '${map['error_code'] ?? ''}',
      errorMessage: '${map['error_message'] ?? ''}',
      options: _mapOrEmpty(map['options']),
      createdAt: _dateTimeOrNull(map['created_at']) ?? DateTime.now(),
      updatedAt: _dateTimeOrNull(map['updated_at']) ?? DateTime.now(),
      startedAt: _dateTimeOrNull(map['started_at']),
      finishedAt: _dateTimeOrNull(map['finished_at']),
    );
  }
}

class ProblemBankDocumentSummary {
  const ProblemBankDocumentSummary({
    required this.document,
    required this.latestExtractJob,
    required this.latestExportJob,
    required this.questionCount,
  });

  final ProblemBankDocument document;
  final ProblemBankExtractJob? latestExtractJob;
  final ProblemBankExportJob? latestExportJob;
  final int questionCount;
}

Map<String, dynamic> _mapOrEmpty(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, dynamic v) => MapEntry('$key', v));
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
  final parsed = int.tryParse('$value');
  return parsed;
}

double _doubleOrZero(dynamic value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return double.tryParse('$value') ?? 0;
}

String _normalizeAnswerKey(String value) {
  return value.trim().replaceAll(RegExp(r'\s+'), ' ');
}

String _objectiveAnswerToSubjective(
  String answerKey,
  List<ProblemBankChoice> choices,
) {
  final normalized = _normalizeAnswerKey(answerKey);
  if (normalized.isEmpty) return '';
  final tokens = normalized
      .split(RegExp(r'\s*[,/]\s*'))
      .map((e) => _normalizeAnswerKey(e))
      .where((e) => e.isNotEmpty)
      .toList(growable: false);
  final source = tokens.isNotEmpty ? tokens : <String>[normalized];
  final out = <String>[];
  for (final token in source) {
    final idx = _answerTokenToChoiceIndex(token);
    if (idx != null && idx >= 0 && idx < choices.length) {
      final text = _normalizeAnswerKey(choices[idx].text);
      if (text.isNotEmpty) {
        out.add(text);
        continue;
      }
    }
    out.add(_tokenToNumeric(token));
  }
  return _normalizeAnswerKey(out.join(', '));
}

bool _looksLikeObjectiveKeyAnswer(String value) {
  final normalized = _normalizeAnswerKey(value);
  if (normalized.isEmpty) return false;
  return RegExp(
    r'^(?:[①②③④⑤⑥⑦⑧⑨⑩]|[1-9]|10)(?:\s*[,/]\s*(?:[①②③④⑤⑥⑦⑧⑨⑩]|[1-9]|10))*$',
  ).hasMatch(normalized);
}

int? _answerTokenToChoiceIndex(String token) {
  final raw = _normalizeAnswerKey(token);
  if (raw.isEmpty) return null;
  const circled = <String>['①', '②', '③', '④', '⑤', '⑥', '⑦', '⑧', '⑨', '⑩'];
  final circledIndex = circled.indexOf(raw);
  if (circledIndex >= 0) return circledIndex;
  final normalized = raw.replaceAll(RegExp(r'[()（）.]'), '').trim();
  final n = int.tryParse(normalized);
  if (n != null && n >= 1) return n - 1;
  return null;
}

String _tokenToNumeric(String token) {
  return token.replaceAllMapped(RegExp(r'[①②③④⑤⑥⑦⑧⑨⑩]'), (m) {
    switch (m.group(0)) {
      case '①':
        return '1';
      case '②':
        return '2';
      case '③':
        return '3';
      case '④':
        return '4';
      case '⑤':
        return '5';
      case '⑥':
        return '6';
      case '⑦':
        return '7';
      case '⑧':
        return '8';
      case '⑨':
        return '9';
      case '⑩':
        return '10';
    }
    return '';
  });
}
