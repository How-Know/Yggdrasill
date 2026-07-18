import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../../models/student_flow.dart';
import '../../services/learning_problem_bank_service.dart';
import '../../widgets/app_snackbar.dart';
import '../learning/models/problem_bank_export_models.dart';
import '../learning/widgets/problem_bank_export_server_preview_dialog.dart';

/// 교재 탐색기에서 선택·장바구니 문항으로 문제은행과 동일한 PDF 미리보기를 연다.
class TextbookExplorerExportLauncher {
  TextbookExplorerExportLauncher({
    LearningProblemBankService? service,
  }) : _service = service ?? LearningProblemBankService();

  final LearningProblemBankService _service;

  Future<void> openLayoutPreview({
    required BuildContext context,
    required String academyId,
    required List<String> questionUids,
    required Map<String, String> questionModeByQuestionUid,
    required LearningProblemExportSettings settings,
    VoidCallback? onSelectionReset,
    void Function(LearningProblemExportSettings settings)? onSettingsChanged,
    void Function(LearningProblemExportJob? job)? onActiveJobChanged,
  }) async {
    final safeAcademyId = academyId.trim();
    if (safeAcademyId.isEmpty) {
      _showSnack(context, '학원 정보가 없어 미리보기를 열 수 없습니다.');
      return;
    }
    final orderedUids = questionUids
        .map((u) => u.trim())
        .where((u) => u.isNotEmpty)
        .toList(growable: false);
    if (orderedUids.isEmpty) {
      _showSnack(context, '레이아웃 미리보기할 문항을 먼저 선택해주세요.');
      return;
    }

    List<LearningProblemQuestion> fetched;
    try {
      fetched = await _service.loadQuestionsByQuestionUids(
        academyId: safeAcademyId,
        questionUids: orderedUids,
      );
    } catch (e) {
      if (!context.mounted) return;
      _showSnack(context, '문항 로드 실패: $e');
      return;
    }
    if (fetched.isEmpty) {
      if (!context.mounted) return;
      _showSnack(context, '선택한 문항을 찾을 수 없습니다.');
      return;
    }

    final orderIndexByUid = <String, int>{};
    for (var i = 0; i < orderedUids.length; i++) {
      orderIndexByUid[orderedUids[i]] = i;
    }
    final questions = List<LearningProblemQuestion>.from(fetched)
      ..sort((a, b) {
        final ai = orderIndexByUid[a.stableQuestionKey.trim()] ??
            orderIndexByUid[a.id.trim()] ??
            1 << 20;
        final bi = orderIndexByUid[b.stableQuestionKey.trim()] ??
            orderIndexByUid[b.id.trim()] ??
            1 << 20;
        return ai.compareTo(bi);
      });

    final session = _TbExExportPreviewSession(
      service: _service,
      academyId: safeAcademyId,
      questions: questions,
      questionModeByQuestionUid: questionModeByQuestionUid,
      settings: settings,
      onSelectionReset: onSelectionReset,
      onSettingsChanged: onSettingsChanged,
      onActiveJobChanged: onActiveJobChanged,
    );

    final completed = await session.createPreviewExport();
    if (!context.mounted) return;
    if (completed == null ||
        completed.status != 'completed' ||
        completed.outputUrl.trim().isEmpty) {
      final err = completed?.errorMessage.isNotEmpty == true
          ? completed!.errorMessage
          : (completed?.errorCode ?? completed?.status ?? 'unknown');
      _showSnack(context, '미리보기 생성 실패: $err');
      return;
    }

    await session.openPreviewDialog(
      context: context,
      completed: completed,
    );
  }

  void _showSnack(BuildContext context, String message) {
    showAppSnackBar(context, message);
  }
}

class _TbExExportPreviewSession {
  _TbExExportPreviewSession({
    required this.service,
    required this.academyId,
    required this.questions,
    required this.questionModeByQuestionUid,
    required LearningProblemExportSettings settings,
    this.onSelectionReset,
    this.onSettingsChanged,
    this.onActiveJobChanged,
  }) : settings = settings {
    mathEngine = _normalizeMathEngine('xelatex-v2');
  }

  final LearningProblemBankService service;
  final String academyId;
  final List<LearningProblemQuestion> questions;
  final Map<String, String> questionModeByQuestionUid;
  LearningProblemExportSettings settings;
  final VoidCallback? onSelectionReset;
  final void Function(LearningProblemExportSettings settings)?
      onSettingsChanged;
  final void Function(LearningProblemExportJob? job)? onActiveJobChanged;
  late String mathEngine;

  void _emitSettings() => onSettingsChanged?.call(settings);

  void _emitJob(LearningProblemExportJob? job) => onActiveJobChanged?.call(job);

  void _showSnack(BuildContext context, String message) {
    showAppSnackBar(context, message);
  }

  List<String> _orderedUids() {
    return questions
        .map((q) => q.stableQuestionKey.trim())
        .where((uid) => uid.isNotEmpty)
        .toList(growable: false);
  }

  Map<String, String> _effectiveQuestionModeMap() {
    return <String, String>{
      for (final question in questions)
        if (question.stableQuestionKey.trim().isNotEmpty)
          question.stableQuestionKey.trim(): normalizeQuestionModeSelection(
            question,
            questionModeByQuestionUid[question.stableQuestionKey.trim()] ??
                questionModeByQuestionUid[question.id.trim()],
            fallbackMode: originalQuestionModeOf(question),
          ),
    };
  }

  Map<String, dynamic> _renderConfig({
    Map<String, dynamic> patch = const <String, dynamic>{},
  }) {
    final orderedUids = _orderedUids();
    final base = settings.toRenderConfig(
      selectedQuestionUidsOrdered: orderedUids,
      questionModeByQuestionUid: _effectiveQuestionModeMap(),
    );
    return <String, dynamic>{
      ...base,
      ...patch,
      'selectedQuestionUidsOrdered': orderedUids,
      'selectedQuestionIdsOrdered': orderedUids,
      'mathEngine': mathEngine,
      'disableAutoLabels': true,
    };
  }

  Future<LearningProblemExportJob?> createPreviewExport({
    Map<String, dynamic> patch = const <String, dynamic>{},
    bool previewOnly = true,
  }) async {
    if (questions.isEmpty) return null;
    final renderConfig = _renderConfig(patch: patch);
    final renderHash = buildLearningRenderHashFromConfig(renderConfig);
    final options = <String, dynamic>{
      ...renderConfig,
      'renderHash': renderHash,
      'previewOnly': previewOnly,
    };
    final job = await service.createExportJob(
      academyId: academyId,
      documentId: questions.first.documentId,
      templateProfile: settings.templateProfile,
      paperSize: settings.paperLabel,
      includeAnswerSheet: settings.includeAnswerSheet,
      includeExplanation: settings.includeExplanation,
      selectedQuestionUids: _orderedUids(),
      renderHash: renderHash,
      previewOnly: previewOnly,
      options: options,
    );
    return _waitForExport(job);
  }

  Future<LearningProblemExportJob?> _waitForExport(
    LearningProblemExportJob initialJob,
  ) async {
    var current = initialJob;
    _emitJob(current);
    for (var attempt = 0; attempt < 240; attempt++) {
      if (current.isTerminal) return current;
      await Future<void>.delayed(const Duration(seconds: 2));
      final latest = await service.getExportJob(
        academyId: academyId,
        jobId: current.id,
      );
      if (latest == null) continue;
      current = latest;
      _emitJob(current);
      if (current.isTerminal) return current;
    }
    return current;
  }

  void _applyRequestSettings(ProblemBankPreviewRefreshRequest request) {
    settings = settings.copyWith(
      includeAcademyLogo: request.includeAcademyLogo,
      timeLimitText: request.timeLimitText.trim(),
      titlePageTopText: request.titlePageTopText.trim().isEmpty
          ? kLearningDefaultTitlePageTopText
          : request.titlePageTopText.trim(),
      titlePageGoalText: request.titlePageGoalText.trim().isEmpty
          ? kLearningDefaultTitlePageGoalText
          : request.titlePageGoalText.trim(),
      includeAnswerSheet: request.includeAnswerSheet,
      includeExplanation: request.includeExplanation,
      includeQuestionScore: request.includeQuestionScore,
      questionScoreByQuestionId: request.questionScoreByQuestionId,
    );
    mathEngine = _normalizeMathEngine(request.mathEngine);
    _emitSettings();
  }

  Map<String, dynamic> _renderPatchFromRequest(
    ProblemBankPreviewRefreshRequest request,
  ) {
    final patch = <String, dynamic>{
      'subjectTitleText': request.subjectTitleText.trim().isEmpty
          ? '수학 영역'
          : request.subjectTitleText.trim(),
      'titlePageTopText': request.titlePageTopText.trim().isEmpty
          ? kLearningDefaultTitlePageTopText
          : request.titlePageTopText.trim(),
      'titlePageGoalText': request.titlePageGoalText.trim().isEmpty
          ? kLearningDefaultTitlePageGoalText
          : request.titlePageGoalText.trim(),
      'timeLimitText': request.timeLimitText.trim(),
      'includeAcademyLogo': request.includeAcademyLogo,
      'includeCoverPage': request.includeCoverPage,
      'coverPageTexts': request.coverPageTexts,
      'includeAnswerSheet': request.includeAnswerSheet,
      'includeExplanation': request.includeExplanation,
      'includeQuestionScore': request.includeQuestionScore,
      'questionScoreByQuestionUid': request.questionScoreByQuestionId,
      'questionScoreByQuestionId': request.questionScoreByQuestionId,
      'mathEngine': request.mathEngine,
      'disableAutoLabels': request.disableAutoLabels,
    };
    if (request.pageColumnQuestionCounts.isNotEmpty) {
      patch['pageColumnQuestionCounts'] = request.pageColumnQuestionCounts;
    }
    if (settings.layoutColumnCount == 2) {
      patch['layoutMode'] = 'custom_columns';
      patch['columnLabelAnchors'] = request.columnLabelAnchors;
      patch['titlePageIndices'] = request.titlePageIndices;
      patch['titlePageHeaders'] = request.titlePageHeaders;
    }
    return patch;
  }

  String get _sourceDocumentId =>
      questions.isEmpty ? '' : questions.first.documentId.trim();

  Map<String, dynamic> _generatedAssignmentMetadata(
    String assignmentFlowName,
  ) {
    if (questions.isEmpty) return const <String, dynamic>{};
    final first = questions.first;
    final textbookScope =
        first.meta['textbook_scope'] ?? first.meta['textbookScope'];
    final scope = textbookScope is Map
        ? textbookScope.map((key, value) => MapEntry('$key', value))
        : const <String, dynamic>{};
    final scopedBookName =
        '${scope['book_name'] ?? scope['bookName'] ?? ''}'.trim();
    final bookLabel = scopedBookName.isNotEmpty
        ? scopedBookName
        : (first.materialName.trim().isNotEmpty
            ? first.materialName.trim()
            : (first.schoolName.trim().isNotEmpty
                ? first.schoolName.trim()
                : first.documentId.trim()));
    final scopedCourseLabel =
        '${scope['course_label'] ?? scope['courseLabel'] ?? ''}'.trim();
    final courseLabel = first.courseLabel.trim().isNotEmpty
        ? first.courseLabel.trim()
        : scopedCourseLabel;
    final assignmentBookId =
        '${scope['book_id'] ?? scope['bookId'] ?? first.meta['book_id'] ?? first.meta['bookId'] ?? ''}'
            .trim();
    final assignmentBookGradeLabel =
        '${scope['grade_label'] ?? scope['gradeLabel'] ?? ''}'.trim();
    return <String, dynamic>{
      'presetKind': 'assignment',
      'assignmentLibraryKind': 'generated_assignment',
      'assignmentBookLabel': bookLabel,
      if (assignmentBookId.isNotEmpty) 'assignmentBookId': assignmentBookId,
      if (assignmentBookGradeLabel.isNotEmpty)
        'assignmentBookGradeLabel': assignmentBookGradeLabel,
      'assignmentGradeLabel': first.gradeLabel.trim(),
      'assignmentCourseLabel': courseLabel,
      'assignmentSchoolName': first.schoolName.trim(),
      'assignmentQuestionCount': questions.length,
      if (assignmentFlowName.trim().isNotEmpty)
        'assignmentFlowName': StudentFlow.normalizeName(
          assignmentFlowName.trim(),
        ),
    };
  }

  String _defaultPdfFileName(LearningProblemExportJob job) {
    final sourceName = questions.isEmpty
        ? 'problem_bank'
        : questions.first.documentSourceName.trim();
    final base = (sourceName.isEmpty ? 'problem_bank' : sourceName)
        .replaceAll(RegExp(r'\.[^.]+$'), '')
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final now = DateTime.now();
    final stamp =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    return '${base}_${job.paperSize}_$stamp.pdf';
  }

  Future<void> _saveCompletedPdf(
    BuildContext context,
    LearningProblemExportJob job,
  ) async {
    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: 'PDF 저장 위치 선택',
      fileName: _defaultPdfFileName(job),
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    if (savePath == null || savePath.trim().isEmpty) {
      if (context.mounted) _showSnack(context, '로컬 저장이 취소되었습니다.');
      return;
    }
    var rawUrl = job.outputUrl.trim();
    if (rawUrl.isEmpty &&
        job.outputStorageBucket.isNotEmpty &&
        job.outputStoragePath.isNotEmpty) {
      rawUrl = await service.createStorageSignedUrl(
        bucket: job.outputStorageBucket,
        path: job.outputStoragePath,
      );
    }
    if (rawUrl.isEmpty) {
      throw Exception('PDF URL을 확보하지 못해 로컬 저장을 진행할 수 없습니다.');
    }
    late final List<int> bytes;
    try {
      bytes = await service.downloadPdfBytesFromUrl(rawUrl);
    } catch (_) {
      if (job.outputStorageBucket.isEmpty || job.outputStoragePath.isEmpty) {
        rethrow;
      }
      final refreshed = await service.createStorageSignedUrl(
        bucket: job.outputStorageBucket,
        path: job.outputStoragePath,
      );
      if (refreshed.trim().isEmpty) rethrow;
      bytes = await service.downloadPdfBytesFromUrl(refreshed);
    }
    final normalizedPath =
        savePath.toLowerCase().endsWith('.pdf') ? savePath : '$savePath.pdf';
    final outFile = File(normalizedPath);
    await outFile.parent.create(recursive: true);
    await outFile.writeAsBytes(bytes, flush: true);
    await OpenFilex.open(normalizedPath);
    if (context.mounted) _showSnack(context, 'PDF 저장 완료: $normalizedPath');
  }

  Future<void> openPreviewDialog({
    required BuildContext context,
    required LearningProblemExportJob completed,
  }) async {
    dynamic initialPrimary(String key) => completed.resultSummary[key];
    dynamic initialFallback(String key) => completed.options[key];

    final scoreEntries = <ProblemBankPreviewQuestionScoreEntry>[];
    final seen = <String>{};
    for (final question in questions) {
      final id = question.stableQuestionKey.trim();
      if (id.isEmpty || seen.contains(id)) continue;
      seen.add(id);
      final rawScore =
          question.meta['score_point'] ?? question.meta['scorePoint'];
      final parsed =
          rawScore is num ? rawScore.toDouble() : double.tryParse('$rawScore');
      scoreEntries.add(
        ProblemBankPreviewQuestionScoreEntry(
          questionId: id,
          questionNumber: question.displayQuestionNumber.trim().isEmpty
              ? '${scoreEntries.length + 1}'
              : question.displayQuestionNumber.trim(),
          defaultScore:
              parsed == null || !parsed.isFinite || parsed < 0 ? 3 : parsed,
        ),
      );
    }
    final currentQuestionScoreByUid = <String, double>{
      for (final entry in scoreEntries) entry.questionId: entry.defaultScore,
    };

    final initialTimeLimitText =
        '${initialPrimary('timeLimitText') ?? initialFallback('timeLimitText') ?? settings.timeLimitText}'
            .trim();

    await ProblemBankExportServerPreviewDialog.open(
      context,
      pdfUrl: completed.outputUrl.trim(),
      titleText: '서버 PDF 미리보기 (${questions.length}문항)',
      initialSubjectTitle:
          '${initialPrimary('subjectTitleText') ?? initialFallback('subjectTitleText') ?? '수학 영역'}'
                  .trim()
                  .isEmpty
              ? '수학 영역'
              : '${initialPrimary('subjectTitleText') ?? initialFallback('subjectTitleText')}'
                  .trim(),
      initialTitlePageTopText:
          '${initialPrimary('titlePageTopText') ?? initialFallback('titlePageTopText') ?? kLearningDefaultTitlePageTopText}'
                  .trim()
                  .isEmpty
              ? kLearningDefaultTitlePageTopText
              : '${initialPrimary('titlePageTopText') ?? initialFallback('titlePageTopText')}'
                  .trim(),
      initialTitlePageGoalText:
          '${initialPrimary('titlePageGoalText') ?? initialFallback('titlePageGoalText') ?? kLearningDefaultTitlePageGoalText}'
                  .trim()
                  .isEmpty
              ? kLearningDefaultTitlePageGoalText
              : '${initialPrimary('titlePageGoalText') ?? initialFallback('titlePageGoalText')}'
                  .trim(),
      isAssignmentTemplate: settings.templateProfile == 'assignment',
      initialTimeLimitText: initialTimeLimitText,
      initialIncludeAcademyLogo: _readBoolFlag(
        initialPrimary('includeAcademyLogo'),
        initialFallback('includeAcademyLogo'),
        settings.includeAcademyLogo,
      ),
      layoutColumns: settings.layoutColumnCount,
      maxQuestionsPerPage: settings.maxQuestionsPerPageCount,
      totalQuestionCount: questions.length,
      initialPageColumnQuestionCounts: _readMapRows(
        initialPrimary('pageColumnQuestionCounts'),
        initialFallback('pageColumnQuestionCounts'),
      ),
      initialColumnLabelAnchors: _readMapRows(
        initialPrimary('columnLabelAnchors'),
        initialFallback('columnLabelAnchors'),
      ),
      initialTitlePageIndices: _readPositiveIntList(
        initialPrimary('titlePageIndices'),
        initialFallback('titlePageIndices'),
      ),
      initialTitlePageHeaders: _readMapRows(
        initialPrimary('titlePageHeaders'),
        initialFallback('titlePageHeaders'),
      ),
      initialIncludeCoverPage: _readBoolFlag(
        initialPrimary('includeCoverPage'),
        initialFallback('includeCoverPage'),
        false,
      ),
      initialIncludeAnswerSheet: settings.includeAnswerSheet,
      initialIncludeExplanation: settings.includeExplanation,
      initialIncludeQuestionScore: settings.includeQuestionScore,
      initialMathEngine: mathEngine,
      initialQuestionScoreByQuestionId: currentQuestionScoreByUid,
      questionScoreEntries: scoreEntries,
      initialCoverPageTexts: _readCoverPageTexts(
        initialPrimary('coverPageTexts'),
        initialFallback('coverPageTexts'),
      ),
      assignmentFlowNames: StudentFlow.defaultNames,
      onRefreshRequested: (request) async {
        settings = settings.copyWith(
          includeAcademyLogo: request.includeAcademyLogo,
          timeLimitText: request.timeLimitText.trim(),
          titlePageTopText: request.titlePageTopText.trim().isEmpty
              ? kLearningDefaultTitlePageTopText
              : request.titlePageTopText.trim(),
          titlePageGoalText: request.titlePageGoalText.trim().isEmpty
              ? kLearningDefaultTitlePageGoalText
              : request.titlePageGoalText.trim(),
          includeAnswerSheet: request.includeAnswerSheet,
          includeExplanation: request.includeExplanation,
          includeQuestionScore: request.includeQuestionScore,
          questionScoreByQuestionId: request.questionScoreByQuestionId,
        );
        mathEngine = _normalizeMathEngine(request.mathEngine);
        _emitSettings();
        final patch = <String, dynamic>{
          'subjectTitleText': request.subjectTitleText.trim().isEmpty
              ? '수학 영역'
              : request.subjectTitleText.trim(),
          'titlePageTopText': request.titlePageTopText.trim().isEmpty
              ? kLearningDefaultTitlePageTopText
              : request.titlePageTopText.trim(),
          'titlePageGoalText': request.titlePageGoalText.trim().isEmpty
              ? kLearningDefaultTitlePageGoalText
              : request.titlePageGoalText.trim(),
          'timeLimitText': request.timeLimitText.trim(),
          'includeAcademyLogo': request.includeAcademyLogo,
          'includeCoverPage': request.includeCoverPage,
          'coverPageTexts': request.coverPageTexts,
          'includeAnswerSheet': request.includeAnswerSheet,
          'includeExplanation': request.includeExplanation,
          'includeQuestionScore': request.includeQuestionScore,
          'questionScoreByQuestionUid': request.questionScoreByQuestionId,
          'questionScoreByQuestionId': request.questionScoreByQuestionId,
          'mathEngine': request.mathEngine,
          'disableAutoLabels': request.disableAutoLabels,
          'pageColumnQuestionCounts': request.pageColumnQuestionCounts,
        };
        if (settings.layoutColumnCount == 2) {
          patch['layoutMode'] = 'custom_columns';
          patch['columnLabelAnchors'] = request.columnLabelAnchors;
          patch['titlePageIndices'] = request.titlePageIndices;
          patch['titlePageHeaders'] = request.titlePageHeaders;
        }
        final refreshed = await createPreviewExport(patch: patch);
        if (refreshed == null ||
            refreshed.status != 'completed' ||
            refreshed.outputUrl.trim().isEmpty) {
          return null;
        }
        return ProblemBankPreviewRefreshResult(
          pdfUrl: refreshed.outputUrl.trim(),
          mathEngine: mathEngine,
          titlePageTopText: settings.titlePageTopText,
          titlePageGoalText: settings.titlePageGoalText,
          timeLimitText: settings.timeLimitText,
          includeAcademyLogo: settings.includeAcademyLogo,
          pageColumnQuestionCounts: _readMapRows(
            refreshed.resultSummary['pageColumnQuestionCounts'],
          ),
          columnLabelAnchors: _readMapRows(
            refreshed.resultSummary['columnLabelAnchors'],
          ),
          titlePageIndices: _readPositiveIntList(
            refreshed.resultSummary['titlePageIndices'],
          ),
          titlePageHeaders: _readMapRows(
            refreshed.resultSummary['titlePageHeaders'],
          ),
          coverPageTexts: _readCoverPageTexts(
            refreshed.resultSummary['coverPageTexts'],
          ),
          includeCoverPage: _readBool(
            refreshed.resultSummary['includeCoverPage'],
            false,
          ),
          includeAnswerSheet: settings.includeAnswerSheet,
          includeExplanation: settings.includeExplanation,
          includeQuestionScore: settings.includeQuestionScore,
          questionScoreByQuestionId: request.questionScoreByQuestionId,
        );
      },
      onGeneratePdfRequested: (request) async {
        _applyRequestSettings(request);
        try {
          final completedPdf = await createPreviewExport(
            patch: _renderPatchFromRequest(request),
            previewOnly: false,
          );
          if (!context.mounted) return;
          if (completedPdf == null ||
              completedPdf.status != 'completed' ||
              completedPdf.outputUrl.trim().isEmpty) {
            final err = completedPdf?.errorMessage.isNotEmpty == true
                ? completedPdf!.errorMessage
                : (completedPdf?.errorCode ??
                    completedPdf?.status ??
                    'unknown');
            _showSnack(context, 'PDF 생성 실패: $err');
            return;
          }
          await _saveCompletedPdf(context, completedPdf);
        } catch (e) {
          if (context.mounted) _showSnack(context, 'PDF 생성 실패: $e');
        }
      },
      onSaveSettingsRequested: (request) async {
        final orderedUids = _orderedUids();
        final sourceDocumentId = _sourceDocumentId;
        if (orderedUids.isEmpty || sourceDocumentId.isEmpty) {
          _showSnack(context, '저장할 문항 또는 원본 문서 정보가 없습니다.');
          return false;
        }
        _applyRequestSettings(request);
        final renderConfig = _renderConfig(
          patch: _renderPatchFromRequest(request),
        );
        try {
          final presetIdToUpdate = request.presetIdToUpdate.trim();
          final result = await service.saveExportSettingsAsDocument(
            academyId: academyId,
            sourceDocumentId: sourceDocumentId,
            selectedQuestionUidsOrdered: orderedUids,
            questionModeByQuestionUid: _effectiveQuestionModeMap(),
            renderConfig: renderConfig,
            templateProfile: settings.templateProfile,
            paperSize: settings.paperLabel,
            includeAnswerSheet: request.includeAnswerSheet,
            includeExplanation: request.includeExplanation,
            displayName: request.presetDisplayName.trim(),
            presetId: presetIdToUpdate,
          );
          final savedPresetId = (result.preset?.id ?? presetIdToUpdate).trim();
          if (savedPresetId.isNotEmpty) {
            await service.overwriteExportPresetRenderConfig(
              academyId: academyId,
              presetId: savedPresetId,
              renderConfig: renderConfig,
            );
          }
          if (!context.mounted) return false;
          _showSnack(
            context,
            presetIdToUpdate.isEmpty
                ? '새 프리셋 저장 완료 (${orderedUids.length}문항)'
                : '프리셋 업데이트 완료 (${orderedUids.length}문항)',
          );
          if (presetIdToUpdate.isEmpty) onSelectionReset?.call();
          return true;
        } catch (e) {
          if (context.mounted) _showSnack(context, '세팅 저장 실패: $e');
          return false;
        }
      },
      onCreateAssignmentRequested: (request) async {
        final orderedUids = _orderedUids();
        final sourceDocumentId = _sourceDocumentId;
        if (orderedUids.isEmpty || sourceDocumentId.isEmpty) {
          _showSnack(context, '과제로 저장할 문항 또는 원본 문서 정보가 없습니다.');
          return false;
        }
        _applyRequestSettings(request);
        final renderConfig = <String, dynamic>{
          ..._renderConfig(patch: _renderPatchFromRequest(request)),
          ..._generatedAssignmentMetadata(request.assignmentFlowName),
        };
        try {
          final result = await service.createGeneratedAssignmentPreset(
            academyId: academyId,
            sourceDocumentId: sourceDocumentId,
            selectedQuestionUidsOrdered: orderedUids,
            questionModeByQuestionUid: _effectiveQuestionModeMap(),
            renderConfig: renderConfig,
            templateProfile: settings.templateProfile,
            paperSize: settings.paperLabel,
            includeAnswerSheet: request.includeAnswerSheet,
            includeExplanation: request.includeExplanation,
            displayName: request.presetDisplayName.trim(),
          );
          if (!context.mounted) return false;
          final count = result.selectedQuestionUids.isNotEmpty
              ? result.selectedQuestionUids.length
              : orderedUids.length;
          _showSnack(context, '미리 만든 과제 생성 완료 ($count문항)');
          onSelectionReset?.call();
          return true;
        } catch (e) {
          if (context.mounted) _showSnack(context, '과제 생성 실패: $e');
          return false;
        }
      },
    );
  }

  static String _normalizeMathEngine(dynamic raw) {
    final v = '$raw'.trim().toLowerCase();
    if (v == 'mathjax-svg') return 'mathjax-svg';
    if (v == 'xelatex-v2') return 'xelatex-v2';
    return 'xelatex-v2';
  }

  static bool _readBool(dynamic raw, bool fallback) {
    if (raw is bool) return raw;
    final text = '$raw'.trim().toLowerCase();
    if (text == 'true' || text == '1') return true;
    if (text == 'false' || text == '0') return false;
    return fallback;
  }

  static bool _readBoolFlag(
    dynamic primary,
    dynamic fallback,
    bool defaultValue,
  ) {
    dynamic value = primary;
    value ??= fallback;
    if (value is bool) return value;
    final text = '$value'.trim().toLowerCase();
    if (text == 'true' || text == '1' || text == 'yes' || text == 'y') {
      return true;
    }
    if (text == 'false' || text == '0' || text == 'no' || text == 'n') {
      return false;
    }
    return defaultValue;
  }

  static List<Map<String, dynamic>> _readMapRows(
    dynamic raw, [
    dynamic fallback,
  ]) {
    final source = raw is List ? raw : fallback;
    if (source is! List) return const <Map<String, dynamic>>[];
    return source
        .whereType<Map>()
        .map((e) => e.map((key, value) => MapEntry('$key', value)))
        .toList(growable: false);
  }

  static List<int> _readPositiveIntList(
    dynamic raw, [
    dynamic fallback,
  ]) {
    final source = raw is List ? raw : fallback;
    if (source is! List) return const <int>[1];
    final out = source
        .map((e) => int.tryParse('$e'))
        .whereType<int>()
        .where((e) => e > 0)
        .toList(growable: false);
    return out.isEmpty ? const <int>[1] : out;
  }

  static Map<String, dynamic> _readCoverPageTexts(
    dynamic raw, [
    dynamic fallback,
  ]) {
    final source = raw is Map ? raw : fallback;
    if (source is! Map) return const <String, dynamic>{};
    return source.map((key, value) => MapEntry('$key', value));
  }
}
