class ProblemBankDocument {
  const ProblemBankDocument({
    required this.id,
    required this.academyId,
    required this.sourceFilename,
    required this.sourceStorageBucket,
    required this.sourceStoragePath,
    required this.status,
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
    this.sourcePdfStorageBucket = '',
    this.sourcePdfStoragePath = '',
    this.sourcePdfFilename = '',
    this.sourcePdfSha256 = '',
    this.sourcePdfSizeBytes = 0,
  });

  final String id;
  final String academyId;
  final String sourceFilename;
  final String sourceStorageBucket;
  final String sourceStoragePath;
  final String status;
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
  final String sourcePdfStorageBucket;
  final String sourcePdfStoragePath;
  final String sourcePdfFilename;
  final String sourcePdfSha256;
  final int sourcePdfSizeBytes;

  bool get hasHwpxSource => sourceStoragePath.trim().isNotEmpty;
  bool get hasPdfSource => sourcePdfStoragePath.trim().isNotEmpty;

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
      sourcePdfStorageBucket:
          '${map['source_pdf_storage_bucket'] ?? ''}'.trim(),
      sourcePdfStoragePath: '${map['source_pdf_storage_path'] ?? ''}'.trim(),
      sourcePdfFilename: '${map['source_pdf_filename'] ?? ''}'.trim(),
      sourcePdfSha256: '${map['source_pdf_sha256'] ?? ''}'.trim(),
      sourcePdfSizeBytes: _intOrNull(map['source_pdf_size_bytes']) ?? 0,
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

  /// 추출 엔진 식별자. 'vlm' | 'hwpx' (이전 데이터에는 없을 수 있어 빈 문자열 가능).
  String get engine {
    final v = resultSummary['engine'];
    if (v is String) return v.trim();
    return '';
  }

  /// 엔진 라벨 (매니저 UI 배지용). 'vlm' → 'VLM (PDF)', 'hwpx' → 'HWPX (XML)'.
  /// 이전 버전에서 저장된 잡은 engine 필드가 비어 있으므로 빈 문자열로 돌려준다.
  String get engineLabel {
    switch (engine) {
      case 'vlm':
        return 'VLM (PDF)';
      case 'hwpx':
        return 'HWPX (XML)';
      default:
        return '';
    }
  }

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
    required this.questionUid,
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
  final String questionUid;
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
      questionUid: questionUid,
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
    final rawId = '${map['id'] ?? ''}';
    return ProblemBankQuestion(
      id: rawId,
      questionUid: '${map['question_uid'] ?? map['questionUid'] ?? rawId}',
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
  var out = _normalizeMultilineWhitespace(value);
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
  return _normalizeMultilineWhitespace(out);
}

String _normalizeMultilineWhitespace(String value) {
  final lines = value
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
  return lines.join('\n');
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

List<String> _objectiveAnswerTokens(String value) {
  final raw = _normalizeAnswerKey(value);
  if (raw.isEmpty) return const <String>[];
  final circled = RegExp(r'[①②③④⑤⑥⑦⑧⑨⑩]')
      .allMatches(raw)
      .map((m) => m.group(0)!)
      .toList(growable: false);
  if (circled.isNotEmpty) {
    final leftover = raw
        .replaceAll(RegExp(r'[①②③④⑤⑥⑦⑧⑨⑩]'), '')
        .replaceAll(RegExp(r'[,\s/，、ㆍ·()（）.]'), '')
        .replaceAll(RegExp(r'(번|와|과|및|그리고|또는)'), '');
    if (leftover.trim().isEmpty) {
      return circled.toSet().toList(growable: false);
    }
  }

  final normalized = raw
      .replaceAll(RegExp(r'[，、ㆍ·/]'), ',')
      .replaceAll(RegExp(r'\s*(와|과|및|그리고|또는)\s*'), ',');
  final parts = normalized.contains(',')
      ? normalized.split(',')
      : RegExp(r'^(10|[1-9])(?:\s+(10|[1-9]))+$').hasMatch(normalized)
          ? normalized.split(RegExp(r'\s+'))
          : <String>[normalized];
  final out = <String>[];
  for (final part in parts) {
    final clean =
        part.replaceAll(RegExp(r'[()（）.]'), '').replaceAll('번', '').trim();
    final n = int.tryParse(clean);
    if (n == null || n < 1 || n > 10) continue;
    out.add(_choiceLabelByNumber(n));
  }
  return out.toSet().toList(growable: false);
}

String _choiceLabelByNumber(int n) {
  const labels = <String>['①', '②', '③', '④', '⑤', '⑥', '⑦', '⑧', '⑨', '⑩'];
  if (n < 1 || n > labels.length) return '$n';
  return labels[n - 1];
}

String _objectiveAnswerToSubjective(
  String answerKey,
  List<ProblemBankChoice> choices,
) {
  final normalized = _normalizeAnswerKey(answerKey);
  if (normalized.isEmpty) return '';
  final tokens = _objectiveAnswerTokens(normalized);
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
  return _objectiveAnswerTokens(normalized).isNotEmpty;
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

/// 세트형 답 파서.
///
/// 답 문자열(예: "(1) 12 (2) ㄱ, ㄷ")을 [{sub, value}] 리스트로 쪼갠다.
/// 단일 답(부분 번호가 0~1개)이거나 선두에 답 외 본문이 섞여 있으면 `null`을 반환한다.
///
/// 매칭 규칙은 gateway 쪽 `parseAnswerParts`와 동일하게 유지한다:
///   - 라벨 패턴: `(N)`, `（N）`, `N)`, `N.`, `①~⑩`
///   - 라벨 뒤에는 공백 또는 문자열 끝이 와야 한다
///     (숫자만 있는 답이 `1)`로 오인되는 것을 막기 위함)
List<AnswerPart>? parseAnswerParts(String? answer) {
  // 워커가 단락 구분용으로 넣어둔 `[문단]` 마커는 파싱 전에 공백으로 치환한다.
  final cleaned = _normalizeAnswerKey(
    (answer ?? '').replaceAll('[문단]', ' '),
  );
  if (cleaned.isEmpty) return null;
  final labelRegex = RegExp(
    r'(?:[(（]\s*(\d{1,2})\s*[)）]|(\d{1,2})\s*[)．.]|([①②③④⑤⑥⑦⑧⑨⑩]))(?=\s|$)',
  );
  final matches = labelRegex.allMatches(cleaned).toList(growable: false);
  if (matches.length < 2) return null;
  final lead = cleaned.substring(0, matches.first.start).trim();
  if (lead.isNotEmpty) return null;

  final parts = <AnswerPart>[];
  for (var i = 0; i < matches.length; i += 1) {
    final cur = matches[i];
    final subRaw = cur.group(1) ?? cur.group(2) ?? cur.group(3) ?? '';
    if (subRaw.isEmpty) continue;
    final sub = RegExp(r'[①②③④⑤⑥⑦⑧⑨⑩]').hasMatch(subRaw)
        ? _tokenToNumeric(subRaw)
        : subRaw;
    if (sub.isEmpty) continue;
    final end = i + 1 < matches.length ? matches[i + 1].start : cleaned.length;
    var value = cleaned.substring(cur.end, end).trim();
    value = value
        .replaceFirst(RegExp(r'^[,、]\s*'), '')
        .replaceFirst(RegExp(r'[,、]\s*$'), '')
        .trim();
    if (value.isEmpty) continue;
    parts.add(AnswerPart(sub: sub, value: value));
  }
  if (parts.length < 2) return null;
  return parts;
}

/// `[{sub, value}]` 를 `"(1) 12 (2) ㄱ, ㄷ"` 형식 display 문자열로 포맷.
String formatAnswerPartsDisplay(List<AnswerPart>? parts) {
  if (parts == null || parts.isEmpty) return '';
  return parts
      .map((p) {
        final sub = p.sub.trim();
        final value = p.value.trim();
        if (sub.isEmpty || value.isEmpty) return '';
        return '($sub) $value';
      })
      .where((s) => s.isNotEmpty)
      .join(' ');
}

/// `meta['answer_parts']` JSON 배열을 [AnswerPart] 리스트로 변환한다.
/// 형식이 잘못되었거나 비어 있으면 `null`.
List<AnswerPart>? answerPartsFromMetaRaw(dynamic raw) {
  if (raw is! List) return null;
  final out = <AnswerPart>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final sub = '${item['sub'] ?? ''}'.trim();
    final value = '${item['value'] ?? ''}'.trim();
    if (sub.isEmpty || value.isEmpty) continue;
    out.add(AnswerPart(sub: sub, value: value));
  }
  return out.isEmpty ? null : out;
}

/// [AnswerPart] 리스트를 DB 저장용 JSON 배열로 변환한다.
List<Map<String, String>> answerPartsToMetaRaw(List<AnswerPart> parts) {
  return parts
      .map((p) => <String, String>{'sub': p.sub, 'value': p.value})
      .toList(growable: false);
}

/// 세트형 문항의 부분 답 하나.
class AnswerPart {
  const AnswerPart({required this.sub, required this.value});

  /// 하위 문항 번호. 원 번호(①)는 숫자 문자열("1")로 정규화해서 들어간다.
  final String sub;

  /// 해당 하위 문항의 답 값.
  final String value;

  AnswerPart copyWith({String? sub, String? value}) {
    return AnswerPart(sub: sub ?? this.sub, value: value ?? this.value);
  }

  @override
  String toString() => '($sub) $value';
}

/// [ProblemBankQuestion] 편의 확장. `meta`에 저장된 세트형 관련 정보를 바로 읽는다.
extension ProblemBankQuestionSetExtension on ProblemBankQuestion {
  /// 워커가 추출 단계에서 세트형으로 판정했는지 (`meta['is_set_question'] == true`).
  /// 모델 직접 저장 필드로 승격하지 않은 이유는 과거 데이터 호환이다.
  bool get isSetQuestion => meta['is_set_question'] == true;

  /// `meta['answer_parts']` 의 구조화된 답. 세트형이 아니거나 미저장이면 `null`.
  List<AnswerPart>? get answerParts =>
      answerPartsFromMetaRaw(meta['answer_parts']);

  /// `meta['score_parts']` 의 하위문항별 배점. 세트형이 아니거나 미저장이면 `null`.
  /// 있을 경우, 카드의 배점 표시는 이들의 합(=총점)을 보여주고,
  /// 편집은 답안 편집과 동일한 하위문항별 다이얼로그로 한다.
  List<ScorePart>? get scoreParts => scorePartsFromMetaRaw(meta['score_parts']);
}

/// 세트형 문항의 하위문항별 배점 하나.
class ScorePart {
  const ScorePart({required this.sub, required this.value});

  /// 하위 문항 번호 ("1", "2" …). 원번호나 (1) 표기는 모두 숫자 문자열로 정규화.
  final String sub;

  /// 해당 하위 문항의 배점. 소수도 허용(예: 2.5점).
  final double value;

  ScorePart copyWith({String? sub, double? value}) {
    return ScorePart(sub: sub ?? this.sub, value: value ?? this.value);
  }

  @override
  String toString() => '($sub) $value';
}

/// `meta['score_parts']` 에 저장된 raw 배열을 파싱.
/// - 원소는 `{sub: "1", value: 4}` 혹은 `{sub: "1", value: "4"}` 형태.
/// - 값이 숫자가 아니거나 0 이하이면 해당 원소는 무시한다.
/// - 유효 원소가 하나도 없으면 `null` 을 반환한다.
List<ScorePart>? scorePartsFromMetaRaw(dynamic raw) {
  if (raw is! List) return null;
  final out = <ScorePart>[];
  for (final e in raw) {
    if (e is! Map) continue;
    final sub = '${e['sub'] ?? ''}'.trim();
    final rawValue = e['value'];
    double? parsed;
    if (rawValue is num) {
      parsed = rawValue.toDouble();
    } else {
      parsed = double.tryParse('$rawValue');
    }
    if (sub.isEmpty || parsed == null || !parsed.isFinite || parsed <= 0) {
      continue;
    }
    out.add(ScorePart(sub: sub, value: parsed));
  }
  if (out.isEmpty) return null;
  return out;
}

/// `meta['score_parts']` 에 저장할 raw 배열로 변환.
List<Map<String, dynamic>> scorePartsToMetaRaw(List<ScorePart> parts) {
  return parts
      .map(
        (p) => <String, dynamic>{
          'sub': p.sub,
          // 정수이면 int, 아니면 double 로 저장해 JSON 표현을 깔끔하게.
          'value':
              p.value == p.value.roundToDouble() ? p.value.toInt() : p.value,
        },
      )
      .toList(growable: false);
}

/// 하위 배점들의 합(=세트형 총점). 파트가 비어있으면 0.
double sumScoreParts(List<ScorePart> parts) {
  double total = 0;
  for (final p in parts) {
    total += p.value;
  }
  return total;
}

// ---------------------------------------------------------------------------
// 문항 수정 이력(학습 데이터 적립) — pb_question_revisions
// ---------------------------------------------------------------------------
//
// `pb_questions` 에 UPDATE 가 가해지면 DB trigger 가 자동으로 before/after
// 스냅샷과 diff 를 `pb_question_revisions` 에 한 줄 적립한다. 매니저는 저장
// 직후 가장 최근 revision 행에 `reason_tags` / `reason_note` 를 붙여 넣어
// "왜 고쳤는가" 라벨을 추가한다. 라벨이 없어도 diff 자체는 항상 보존된다.

/// 검수자가 수정 의도를 표시할 때 고르는 태그.
/// 신규 태그는 DB 차원 constraint 가 없으므로 여기에서 추가하면 즉시 쓸 수 있으나,
/// 통계 분석의 어휘가 되기 때문에 신중히 늘린다.
enum ProblemBankRevisionReasonTag {
  stemText('stem_text', '본문 텍스트/오타'),
  stemMath('stem_math', '본문 수식'),
  stemParagraph('stem_paragraph', '본문 단락/줄바꿈'),
  choices('choices', '선택지 내용'),
  answerObjective('answer_objective', '객관식 정답'),
  answerSubjective('answer_subjective', '주관식 정답'),
  autoObjectiveGenerated('auto_objective_generated', '자동 객관식 생성 품질'),
  figureMapping('figure_mapping', '그림↔문항 매핑'),
  figureLayout('figure_layout', '그림 배치/크기'),
  tableStructure('table_structure', '표 구조'),
  boxType('box_type', '박스 종류'),
  setQuestion('set_question', '세트형 분리'),
  metadataClassification('metadata_classification', '과목/단원/출처'),
  metadataScore('metadata_score', '배점'),
  other('other', '기타 (메모 필수)');

  const ProblemBankRevisionReasonTag(this.key, this.label);

  final String key;
  final String label;

  static ProblemBankRevisionReasonTag? fromKey(String? key) {
    if (key == null) return null;
    for (final t in values) {
      if (t.key == key) return t;
    }
    return null;
  }
}

/// pb_question_revisions 한 행의 매니저 측 표현. UI/서비스 계층 공용.
class ProblemBankQuestionRevision {
  const ProblemBankQuestionRevision({
    required this.id,
    required this.academyId,
    required this.documentId,
    required this.questionId,
    required this.engine,
    required this.engineModel,
    required this.revisedAt,
    required this.editedFields,
    required this.reasonTags,
    required this.reasonNote,
    required this.diff,
  });

  final String id;
  final String academyId;
  final String documentId;
  final String questionId;
  final String engine; // 'vlm' | 'hwpx' | 'unknown'
  final String engineModel;
  final DateTime revisedAt;
  final List<String> editedFields;
  final List<ProblemBankRevisionReasonTag> reasonTags;
  final String reasonNote;
  final Map<String, dynamic> diff;

  factory ProblemBankQuestionRevision.fromMap(Map<String, dynamic> map) {
    final rawTags = map['reason_tags'];
    final tags = <ProblemBankRevisionReasonTag>[];
    if (rawTags is List) {
      for (final r in rawTags) {
        final t = ProblemBankRevisionReasonTag.fromKey(r?.toString());
        if (t != null) tags.add(t);
      }
    }
    final rawEdited = map['edited_fields'];
    final edited = <String>[];
    if (rawEdited is List) {
      for (final r in rawEdited) {
        final s = r?.toString() ?? '';
        if (s.isNotEmpty) edited.add(s);
      }
    }
    return ProblemBankQuestionRevision(
      id: (map['id'] ?? '').toString(),
      academyId: (map['academy_id'] ?? '').toString(),
      documentId: (map['document_id'] ?? '').toString(),
      questionId: (map['question_id'] ?? '').toString(),
      engine: (map['engine'] ?? 'unknown').toString(),
      engineModel: (map['engine_model'] ?? '').toString(),
      revisedAt:
          DateTime.tryParse((map['revised_at'] ?? '').toString())?.toLocal() ??
              DateTime.now(),
      editedFields: edited,
      reasonTags: tags,
      reasonNote: (map['reason_note'] ?? '').toString(),
      diff: map['diff'] is Map<String, dynamic>
          ? Map<String, dynamic>.from(map['diff'] as Map<String, dynamic>)
          : <String, dynamic>{},
    );
  }
}
