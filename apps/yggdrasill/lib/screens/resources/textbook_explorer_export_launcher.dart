import 'package:flutter/material.dart';

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
    required LearningProblemExportSettings settings,
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
      settings: settings,
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
    required LearningProblemExportSettings settings,
    this.onSettingsChanged,
    this.onActiveJobChanged,
  }) : settings = settings {
    mathEngine = _normalizeMathEngine('xelatex-v2');
  }

  final LearningProblemBankService service;
  final String academyId;
  final List<LearningProblemQuestion> questions;
  LearningProblemExportSettings settings;
  final void Function(LearningProblemExportSettings settings)? onSettingsChanged;
  final void Function(LearningProblemExportJob? job)? onActiveJobChanged;
  late String mathEngine;

  void _emitSettings() => onSettingsChanged?.call(settings);

  void _emitJob(LearningProblemExportJob? job) => onActiveJobChanged?.call(job);

  List<String> _orderedUids() {
    return questions
        .map((q) => q.stableQuestionKey.trim())
        .where((uid) => uid.isNotEmpty)
        .toList(growable: false);
  }

  Map<String, dynamic> _renderConfig({
    Map<String, dynamic> patch = const <String, dynamic>{},
  }) {
    final orderedUids = _orderedUids();
    final base = settings.toRenderConfig(
      selectedQuestionUidsOrdered: orderedUids,
      questionModeByQuestionUid: const <String, String>{},
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
