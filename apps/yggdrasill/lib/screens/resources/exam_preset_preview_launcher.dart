import 'package:flutter/material.dart';

import '../../services/learning_problem_bank_service.dart';
import '../learning/models/problem_bank_export_models.dart';
import '../learning/widgets/problem_bank_export_server_preview_dialog.dart';
import 'exam_preset_support.dart';

class ExamPresetPreviewLauncher {
  ExamPresetPreviewLauncher({
    LearningProblemBankService? service,
  }) : _service = service ?? LearningProblemBankService();

  final LearningProblemBankService _service;

  static String _normalizeMathEngine(dynamic raw) {
    final v = '$raw'.trim().toLowerCase();
    if (v == 'mathjax-svg') return 'mathjax-svg';
    if (v == 'xelatex-v2') return 'xelatex-v2';
    return 'xelatex-v2';
  }

  Future<void> openPresetPreview({
    required BuildContext context,
    required String academyId,
    required LearningProblemDocumentExportPreset preset,
  }) async {
    final safeAcademyId = academyId.trim();
    if (safeAcademyId.isEmpty) {
      _showSnack(context, '학원 정보가 없어 프리셋을 열 수 없습니다.');
      return;
    }

    var effectivePreset = preset;
    try {
      final latest = await _service.getExportPresetById(
        academyId: safeAcademyId,
        presetId: preset.id,
      );
      if (latest != null) effectivePreset = latest;
    } catch (_) {}

    final presetUids = effectivePreset.selectedQuestionUids
        .map((u) => u.trim())
        .where((u) => u.isNotEmpty)
        .toList(growable: false);
    if (presetUids.isEmpty) {
      _showSnack(context, '프리셋에 저장된 문항이 없습니다.');
      return;
    }

    List<LearningProblemQuestion> fetched;
    try {
      fetched = await _service.loadQuestionsByQuestionUids(
        academyId: safeAcademyId,
        questionUids: presetUids,
      );
    } catch (e) {
      _showSnack(context, '프리셋 문항 로드 실패: $e');
      return;
    }
    if (fetched.isEmpty) {
      _showSnack(context, '프리셋에 연결된 문항을 찾을 수 없습니다.');
      return;
    }

    final orderIndexByUid = <String, int>{};
    for (var i = 0; i < presetUids.length; i++) {
      orderIndexByUid[presetUids[i]] = i;
    }
    final ordered = List<LearningProblemQuestion>.from(fetched)
      ..sort((a, b) {
        final ai = orderIndexByUid[a.stableQuestionKey.trim()] ??
            orderIndexByUid[a.id.trim()] ??
            1 << 20;
        final bi = orderIndexByUid[b.stableQuestionKey.trim()] ??
            orderIndexByUid[b.id.trim()] ??
            1 << 20;
        return ai.compareTo(bi);
      });

    final session = _PresetPreviewSession(
      service: _service,
      academyId: safeAcademyId,
      preset: effectivePreset,
      questions: ordered,
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
    if (!context.mounted) return;
    _showSnack(
      context,
      '프리셋 적용: ${effectivePreset.displayName} (${ordered.length}문항)',
    );
  }

  void _showSnack(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _PresetPreviewSession {
  _PresetPreviewSession({
    required this.service,
    required this.academyId,
    required this.preset,
    required this.questions,
  }) {
    settings = LearningProblemExportSettings.fromPresetRenderConfig(
      base: LearningProblemExportSettings.initial(),
      renderConfig: preset.renderConfig,
    );
    mathEngine = ExamPresetPreviewLauncher._normalizeMathEngine(
      preset.renderConfig['mathEngine'],
    );
    for (final question in questions) {
      final rawMode = preset.questionModeByQuestionUid[
              question.stableQuestionKey] ??
          preset.questionModeByQuestionUid[question.id];
      if (rawMode == null || rawMode.trim().isEmpty) continue;
      modes[question.id] = normalizeQuestionModeSelection(
        question,
        rawMode,
        fallbackMode: kLearningQuestionModeOriginal,
      );
    }
  }

  final LearningProblemBankService service;
  final String academyId;
  final LearningProblemDocumentExportPreset preset;
  final List<LearningProblemQuestion> questions;
  late LearningProblemExportSettings settings;
  late String mathEngine;
  final Map<String, String> modes = <String, String>{};

  List<String> _orderedUids() {
    return questions
        .map((q) => q.stableQuestionKey.trim())
        .where((uid) => uid.isNotEmpty)
        .toList(growable: false);
  }

  Map<String, dynamic> _renderConfig({
    Map<String, dynamic> patch = const <String, dynamic>{},
  }) {
    final link = naesinLinkKeyOfPreset(preset);
    final base = settings.toRenderConfig(
      selectedQuestionUidsOrdered: _orderedUids(),
      questionModeByQuestionUid: {
        for (final q in questions)
          if (modes[q.id]?.trim().isNotEmpty ?? false)
            q.stableQuestionKey: modes[q.id]!.trim(),
      },
    );
    if (link.isNotEmpty) {
      base[kExamPresetNaesinLinkConfigKey] = link;
    }
    base['mathEngine'] = mathEngine;
    base['disableAutoLabels'] = true;
    return {...base, ...patch};
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
    for (var attempt = 0; attempt < 240; attempt++) {
      if (current.isTerminal) return current;
      await Future<void>.delayed(const Duration(seconds: 2));
      final latest = await service.getExportJob(
        academyId: academyId,
        jobId: current.id,
      );
      if (latest == null) continue;
      current = latest;
      if (current.isTerminal) return current;
    }
    return current;
  }

  Future<void> openPreviewDialog({
    required BuildContext context,
    required LearningProblemExportJob completed,
  }) async {
    final presetRenderConfig = preset.renderConfig;
    dynamic initialPrimary(String key) => presetRenderConfig[key];

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

    await ProblemBankExportServerPreviewDialog.open(
      context,
      pdfUrl: completed.outputUrl.trim(),
      titleText: '서버 PDF 미리보기 (${questions.length}문항)',
      initialSubjectTitle:
          '${initialPrimary('subjectTitleText') ?? '수학 영역'}'.trim().isEmpty
              ? '수학 영역'
              : '${initialPrimary('subjectTitleText')}'.trim(),
      initialTitlePageTopText:
          '${initialPrimary('titlePageTopText') ?? kLearningDefaultTitlePageTopText}'
              .trim()
              .isEmpty
              ? kLearningDefaultTitlePageTopText
              : '${initialPrimary('titlePageTopText')}'.trim(),
      initialTimeLimitText: '${initialPrimary('timeLimitText') ?? ''}'.trim(),
      initialIncludeAcademyLogo: settings.includeAcademyLogo,
      layoutColumns: settings.layoutColumnCount,
      maxQuestionsPerPage: settings.maxQuestionsPerPageCount,
      totalQuestionCount: questions.length,
      initialPageColumnQuestionCounts: _readMapRows(
        initialPrimary('pageColumnQuestionCounts'),
      ),
      initialColumnLabelAnchors: _readMapRows(
        initialPrimary('columnLabelAnchors'),
      ),
      initialTitlePageIndices: _readPositiveIntList(
        initialPrimary('titlePageIndices'),
      ),
      initialTitlePageHeaders: _readMapRows(
        initialPrimary('titlePageHeaders'),
      ),
      initialIncludeCoverPage: _readBool(
        initialPrimary('includeCoverPage'),
        false,
      ),
      initialIncludeAnswerSheet: settings.includeAnswerSheet,
      initialIncludeExplanation: settings.includeExplanation,
      initialIncludeQuestionScore: settings.includeQuestionScore,
      initialMathEngine: mathEngine,
      initialQuestionScoreByQuestionId: preset.questionScoreByQuestionUid,
      questionScoreEntries: scoreEntries,
      initialCoverPageTexts: _readCoverPageTexts(
        initialPrimary('coverPageTexts'),
      ),
      initialEditingPresetId: preset.id,
      initialEditingPresetName: preset.displayName,
      onRefreshRequested: (request) async {
        settings = settings.copyWith(
          includeAcademyLogo: request.includeAcademyLogo,
          timeLimitText: request.timeLimitText.trim(),
          titlePageTopText: request.titlePageTopText.trim().isEmpty
              ? kLearningDefaultTitlePageTopText
              : request.titlePageTopText.trim(),
          includeAnswerSheet: request.includeAnswerSheet,
          includeExplanation: request.includeExplanation,
          includeQuestionScore: request.includeQuestionScore,
          questionScoreByQuestionId: request.questionScoreByQuestionId,
        );
        mathEngine = ExamPresetPreviewLauncher._normalizeMathEngine(
          request.mathEngine,
        );
        final patch = <String, dynamic>{
          'subjectTitleText': request.subjectTitleText.trim().isEmpty
              ? '수학 영역'
              : request.subjectTitleText.trim(),
          'titlePageTopText': request.titlePageTopText.trim().isEmpty
              ? kLearningDefaultTitlePageTopText
              : request.titlePageTopText.trim(),
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
      onSaveSettingsRequested: (request) async {
        settings = settings.copyWith(
          includeAcademyLogo: request.includeAcademyLogo,
          timeLimitText: request.timeLimitText.trim(),
          titlePageTopText: request.titlePageTopText.trim().isEmpty
              ? kLearningDefaultTitlePageTopText
              : request.titlePageTopText.trim(),
          includeAnswerSheet: request.includeAnswerSheet,
          includeExplanation: request.includeExplanation,
          includeQuestionScore: request.includeQuestionScore,
          questionScoreByQuestionId: request.questionScoreByQuestionId,
        );
        mathEngine = ExamPresetPreviewLauncher._normalizeMathEngine(
          request.mathEngine,
        );
        final patch = <String, dynamic>{
          'subjectTitleText': request.subjectTitleText.trim().isEmpty
              ? '수학 영역'
              : request.subjectTitleText.trim(),
          'titlePageTopText': request.titlePageTopText.trim().isEmpty
              ? kLearningDefaultTitlePageTopText
              : request.titlePageTopText.trim(),
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
        final renderConfig = _renderConfig(patch: patch);
        final sourceDocumentId = questions.first.documentId.trim();
        if (sourceDocumentId.isEmpty) return false;
        try {
          final saveResult = await service.saveExportSettingsAsDocument(
            academyId: academyId,
            sourceDocumentId: sourceDocumentId,
            selectedQuestionUidsOrdered: _orderedUids(),
            questionModeByQuestionUid: {
              for (final q in questions)
                if (modes[q.id]?.trim().isNotEmpty ?? false)
                  q.stableQuestionKey: modes[q.id]!.trim(),
            },
            renderConfig: renderConfig,
            templateProfile: settings.templateProfile,
            paperSize: settings.paperLabel,
            includeAnswerSheet: request.includeAnswerSheet,
            includeExplanation: request.includeExplanation,
            displayName: request.presetDisplayName.trim(),
            presetId: request.presetIdToUpdate.trim(),
          );
          return (saveResult.preset?.id ?? request.presetIdToUpdate).isNotEmpty;
        } catch (_) {
          return false;
        }
      },
    );
  }

  static bool _readBool(dynamic raw, bool fallback) {
    if (raw is bool) return raw;
    final text = '$raw'.trim().toLowerCase();
    if (text == 'true' || text == '1') return true;
    if (text == 'false' || text == '0') return false;
    return fallback;
  }

  static List<Map<String, dynamic>> _readMapRows(dynamic raw) {
    if (raw is! List) return const <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((e) => e.map((key, value) => MapEntry('$key', value)))
        .toList(growable: false);
  }

  static List<int> _readPositiveIntList(dynamic raw) {
    if (raw is! List) return const <int>[1];
    final out = raw
        .map((e) => int.tryParse('$e'))
        .whereType<int>()
        .where((e) => e > 0)
        .toList(growable: false);
    return out.isEmpty ? const <int>[1] : out;
  }

  static Map<String, dynamic> _readCoverPageTexts(dynamic raw) {
    if (raw is! Map) return const <String, dynamic>{};
    return raw.map((key, value) => MapEntry('$key', value));
  }
}
