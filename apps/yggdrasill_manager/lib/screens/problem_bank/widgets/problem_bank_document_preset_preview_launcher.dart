import 'package:flutter/material.dart';
import 'package:yggdrasill_pb_export_ui/yggdrasill_pb_export_ui.dart';

import '../../../services/problem_bank_service.dart';
import '../problem_bank_models.dart';

class ProblemBankDocumentPresetPreviewLauncher {
  const ProblemBankDocumentPresetPreviewLauncher({
    required this.service,
    required this.showSnack,
  });

  final ProblemBankService service;
  final void Function(String message, {bool error}) showSnack;

  Future<void> open({
    required BuildContext context,
    required String academyId,
    required ProblemBankDocument document,
    ProblemBankExportPreset? preset,
  }) async {
    var effectivePreset = preset;
    if (preset != null) {
      effectivePreset = await service.getExportPresetById(
            academyId: academyId,
            presetId: preset.id,
          ) ??
          preset;
    }
    final requestedUids = effectivePreset?.selectedQuestionUids
            .map((uid) => uid.trim())
            .where((uid) => uid.isNotEmpty)
            .toList(growable: false) ??
        const <String>[];
    final questions = requestedUids.isEmpty
        ? await service.listQuestions(
            academyId: academyId,
            documentId: document.id,
          )
        : await service.loadQuestionsByQuestionUids(
            academyId: academyId,
            questionUids: requestedUids,
          );
    if (questions.isEmpty) {
      showSnack('프리셋으로 만들 문항이 없습니다.', error: true);
      return;
    }
    final session = _ManagerPresetPreviewSession(
      service: service,
      academyId: academyId,
      document: document,
      preset: effectivePreset,
      questions: questions,
      showSnack: showSnack,
    );
    final completed = await session.createPreviewExport();
    if (!context.mounted) return;
    if (completed.status != 'completed' || completed.outputUrl.trim().isEmpty) {
      final error = completed.errorMessage.trim().isNotEmpty
          ? completed.errorMessage.trim()
          : completed.errorCode.trim();
      showSnack(
        '미리보기 생성 실패: ${error.isEmpty ? completed.status : error}',
        error: true,
      );
      return;
    }
    await session.openPreviewDialog(context, completed);
  }
}

class _ManagerPresetPreviewSession {
  _ManagerPresetPreviewSession({
    required this.service,
    required this.academyId,
    required this.document,
    required this.preset,
    required this.questions,
    required this.showSnack,
  }) : renderConfig = <String, dynamic>{
          ..._defaultRenderConfig,
          ...?preset?.renderConfig,
        } {
    final sourcePreset = preset;
    final profile =
        '${renderConfig['templateProfile'] ?? 'csat'}'.trim().toLowerCase();
    if (profile == 'csat' || profile == 'mock') {
      // 학습앱에서 모의고사형을 선택할 때와 동일하게 B4를 기본 용지로
      // 적용한다. 초기 매니저 연동에서 잘못 저장된 A4 프리셋도 복구한다.
      renderConfig['paperSize'] = 'B4';
    } else if (sourcePreset != null &&
        !sourcePreset.renderConfig.containsKey('paperSize') &&
        sourcePreset.paperSize.trim().isNotEmpty) {
      renderConfig['paperSize'] = sourcePreset.paperSize.trim();
    }
    final followsOriginalQuestionTypes =
        '${renderConfig['naesinLinkKey'] ?? ''}'.trim().isNotEmpty;
    if (followsOriginalQuestionTypes) {
      renderConfig['naesinOriginalModePolicyVersion'] = 1;
      for (final question in questions) {
        final uid = question.questionUid.trim().isNotEmpty
            ? question.questionUid.trim()
            : question.id.trim();
        if (uid.isNotEmpty) {
          questionModes[uid] = _originalQuestionModeOf(question);
        }
      }
      return;
    }
    final rawModes = renderConfig['questionModeByQuestionUid'] ??
        renderConfig['questionModeByQuestionId'];
    if (rawModes is Map) {
      for (final entry in rawModes.entries) {
        final uid = '${entry.key}'.trim();
        final mode = '${entry.value}'.trim();
        if (uid.isNotEmpty && mode.isNotEmpty) questionModes[uid] = mode;
      }
    }
  }

  static String _originalQuestionModeOf(ProblemBankQuestion question) {
    final type = question.questionType.trim();
    if (type.contains('서술')) return 'essay';
    if (type.contains('객관식')) return 'objective';
    if (type.contains('주관식')) return 'subjective';
    if (question.allowObjective && !question.allowSubjective) {
      return 'objective';
    }
    if (!question.allowObjective && question.allowSubjective) {
      return 'subjective';
    }
    return question.choices.length >= 2 ? 'objective' : 'subjective';
  }

  static const Map<String, dynamic> _defaultRenderConfig = <String, dynamic>{
    'renderConfigVersion': 4,
    'templateProfile': 'csat',
    'paperSize': 'B4',
    'font': <String, dynamic>{
      'family': 'KoPubWorldBatangPro',
      'size': 11.0,
    },
    'layoutColumns': 2,
    'maxQuestionsPerPage': 4,
    'layoutMode': 'legacy',
    'pageColumnQuestionCounts': <Map<String, dynamic>>[],
    'columnLabelAnchors': <Map<String, dynamic>>[],
    'titlePageIndices': <int>[1],
    'titlePageHeaders': <Map<String, dynamic>>[
      <String, dynamic>{'page': 1, 'title': '수학 영역', 'subtitle': ''},
    ],
    'titlePageTopText': '2026학년도 대학수학능력시험 문제지',
    'titlePageGoalText': '다시 풀기',
    'subjectTitleText': '수학 영역',
    'includeAcademyLogo': true,
    'includeCoverPage': false,
    'includeAnswerSheet': false,
    'includeExplanation': false,
    'includeQuestionScore': false,
    'mathEngine': 'xelatex-v2',
    'disableAutoLabels': true,
  };

  final ProblemBankService service;
  final String academyId;
  final ProblemBankDocument document;
  ProblemBankExportPreset? preset;
  final List<ProblemBankQuestion> questions;
  final void Function(String message, {bool error}) showSnack;
  final Map<String, String> questionModes = <String, String>{};
  Map<String, dynamic> renderConfig;

  List<String> get orderedUids => questions
      .map((question) => question.questionUid.trim().isNotEmpty
          ? question.questionUid.trim()
          : question.id.trim())
      .where((uid) => uid.isNotEmpty)
      .toList(growable: false);

  String get templateProfile =>
      '${renderConfig['templateProfile'] ?? 'csat'}'.trim();
  String get paperSize => '${renderConfig['paperSize'] ?? 'B4'}'.trim();

  Map<String, dynamic> _patchedConfig(
    ProblemBankPreviewRefreshRequest request,
  ) {
    return <String, dynamic>{
      ...renderConfig,
      'selectedQuestionUidsOrdered': orderedUids,
      'selectedQuestionIdsOrdered': orderedUids,
      'questionModeByQuestionUid': questionModes,
      'questionModeByQuestionId': questionModes,
      'subjectTitleText': request.subjectTitleText,
      'titlePageTopText': request.titlePageTopText,
      'titlePageGoalText': request.titlePageGoalText,
      'timeLimitText': request.timeLimitText,
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
      'columnLabelAnchors': request.columnLabelAnchors,
      'titlePageIndices': request.titlePageIndices,
      'titlePageHeaders': request.titlePageHeaders,
    };
  }

  Future<ProblemBankExportJob> createPreviewExport({
    Map<String, dynamic>? config,
  }) async {
    final nextConfig = config ?? renderConfig;
    final job = await service.createExportJob(
      academyId: academyId,
      documentId: document.id,
      templateProfile:
          '${nextConfig['templateProfile'] ?? templateProfile}'.trim(),
      paperSize: '${nextConfig['paperSize'] ?? paperSize}'.trim(),
      includeAnswerSheet: nextConfig['includeAnswerSheet'] == true,
      includeExplanation: nextConfig['includeExplanation'] == true,
      selectedQuestionUids: orderedUids,
      previewOnly: true,
      options: <String, dynamic>{
        ...nextConfig,
        'previewOnly': true,
      },
    );
    return _waitForExport(job);
  }

  Future<ProblemBankExportJob> _waitForExport(
    ProblemBankExportJob initial,
  ) async {
    var current = initial;
    for (var attempt = 0; attempt < 240 && !current.isTerminal; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      current = await service.getExportJob(
        academyId: academyId,
        jobId: current.id,
      );
    }
    return current;
  }

  Future<void> openPreviewDialog(
    BuildContext context,
    ProblemBankExportJob completed,
  ) async {
    final scoreMap = _doubleMap(
      renderConfig['questionScoreByQuestionUid'] ??
          renderConfig['questionScoreByQuestionId'],
    );
    final scoreEntries = questions.map((question) {
      final uid = question.questionUid.trim().isNotEmpty
          ? question.questionUid.trim()
          : question.id.trim();
      final metaScore =
          question.meta['score_point'] ?? question.meta['scorePoint'];
      final score = scoreMap[uid] ??
          (metaScore is num
              ? metaScore.toDouble()
              : double.tryParse('$metaScore')) ??
          3;
      return ProblemBankPreviewQuestionScoreEntry(
        questionId: uid,
        questionNumber: question.questionNumber.trim().isEmpty
            ? '${questions.indexOf(question) + 1}'
            : question.questionNumber.trim(),
        defaultScore: score,
      );
    }).toList(growable: false);

    await ProblemBankExportServerPreviewDialog.open(
      context,
      pdfUrl: completed.outputUrl.trim(),
      titleText: '서버 PDF 미리보기 (${questions.length}문항)',
      initialSubjectTitle: '${renderConfig['subjectTitleText'] ?? '수학 영역'}',
      initialTitlePageTopText:
          '${renderConfig['titlePageTopText'] ?? '2026학년도 대학수학능력시험 문제지'}',
      initialTitlePageGoalText:
          '${renderConfig['titlePageGoalText'] ?? '다시 풀기'}',
      initialTimeLimitText: '${renderConfig['timeLimitText'] ?? ''}',
      layoutColumns: _readInt(renderConfig['layoutColumns'], 2),
      maxQuestionsPerPage: _readInt(renderConfig['maxQuestionsPerPage'], 4),
      totalQuestionCount: questions.length,
      initialPageColumnQuestionCounts: _mapRowsPreferNonEmpty(
        renderConfig['pageColumnQuestionCounts'],
        completed.resultSummary['pageColumnQuestionCounts'],
      ),
      initialColumnLabelAnchors: _mapRows(
        renderConfig['columnLabelAnchors'],
        completed.resultSummary['columnLabelAnchors'],
      ),
      initialTitlePageIndices: _positiveInts(
        renderConfig['titlePageIndices'],
        completed.resultSummary['titlePageIndices'],
      ),
      initialTitlePageHeaders: _mapRows(
        renderConfig['titlePageHeaders'],
        completed.resultSummary['titlePageHeaders'],
      ),
      initialCoverPageTexts: _stringMap(
        renderConfig['coverPageTexts'],
        completed.resultSummary['coverPageTexts'],
      ),
      initialIncludeAcademyLogo: renderConfig['includeAcademyLogo'] != false,
      initialIncludeCoverPage: renderConfig['includeCoverPage'] == true,
      initialIncludeAnswerSheet: renderConfig['includeAnswerSheet'] == true,
      initialIncludeExplanation: renderConfig['includeExplanation'] == true,
      initialIncludeQuestionScore: renderConfig['includeQuestionScore'] == true,
      initialMathEngine: '${renderConfig['mathEngine'] ?? 'xelatex-v2'}',
      initialQuestionScoreByQuestionId: scoreMap,
      questionScoreEntries: scoreEntries,
      initialEditingPresetId: preset?.id ?? '',
      initialEditingPresetName: preset?.displayName ?? '',
      onRefreshRequested: (request) async {
        renderConfig = _patchedConfig(request);
        final refreshed = await createPreviewExport(config: renderConfig);
        if (refreshed.status != 'completed' ||
            refreshed.outputUrl.trim().isEmpty) {
          return null;
        }
        return ProblemBankPreviewRefreshResult(
          pdfUrl: refreshed.outputUrl.trim(),
          mathEngine: request.mathEngine,
          titlePageTopText: request.titlePageTopText,
          titlePageGoalText: request.titlePageGoalText,
          timeLimitText: request.timeLimitText,
          pageColumnQuestionCounts: _mapRows(
            refreshed.resultSummary['pageColumnQuestionCounts'],
          ),
          columnLabelAnchors:
              _mapRows(refreshed.resultSummary['columnLabelAnchors']),
          titlePageIndices:
              _positiveInts(refreshed.resultSummary['titlePageIndices']),
          titlePageHeaders:
              _mapRows(refreshed.resultSummary['titlePageHeaders']),
          coverPageTexts: _stringMap(refreshed.resultSummary['coverPageTexts']),
          includeAcademyLogo: request.includeAcademyLogo,
          includeCoverPage: request.includeCoverPage,
          includeAnswerSheet: request.includeAnswerSheet,
          includeExplanation: request.includeExplanation,
          includeQuestionScore: request.includeQuestionScore,
          questionScoreByQuestionId: request.questionScoreByQuestionId,
        );
      },
      onSaveSettingsRequested: (request) async {
        renderConfig = _patchedConfig(request);
        try {
          final updated = await service.saveExportSettingsAsPreset(
            academyId: academyId,
            sourceDocumentId: document.id,
            selectedQuestionUidsOrdered: orderedUids,
            questionModeByQuestionUid: questionModes,
            renderConfig: renderConfig,
            templateProfile: templateProfile,
            paperSize: paperSize,
            includeAnswerSheet: request.includeAnswerSheet,
            includeExplanation: request.includeExplanation,
            displayName: request.presetDisplayName,
            presetId: request.presetIdToUpdate,
          );
          if (updated == null) throw Exception('저장된 프리셋 정보가 없습니다.');
          final renderConfigUpdated =
              await service.overwriteExportPresetRenderConfig(
            academyId: academyId,
            presetId: updated.id,
            renderConfig: renderConfig,
          );
          if (renderConfigUpdated == null) {
            throw Exception('프리셋 렌더 설정을 갱신하지 못했습니다.');
          }
          preset = renderConfigUpdated;
          showSnack(
            request.presetIdToUpdate.trim().isEmpty
                ? '새 프리셋 저장 완료'
                : '프리셋 업데이트 완료',
          );
          return true;
        } catch (error) {
          showSnack('프리셋 저장 실패: $error', error: true);
          return false;
        }
      },
    );
  }

  static int _readInt(dynamic value, int fallback) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? fallback;

  static List<Map<String, dynamic>> _mapRows(
    dynamic value, [
    dynamic fallback,
  ]) {
    final source = value is List ? value : fallback;
    if (source is! List) return const <Map<String, dynamic>>[];
    return source
        .whereType<Map>()
        .map((row) => row.map((key, value) => MapEntry('$key', value)))
        .toList(growable: false);
  }

  static List<Map<String, dynamic>> _mapRowsPreferNonEmpty(
    dynamic value,
    dynamic fallback,
  ) {
    final primary = _mapRows(value);
    return primary.isNotEmpty ? primary : _mapRows(fallback);
  }

  static List<int> _positiveInts(dynamic value, [dynamic fallback]) {
    final source = value is List ? value : fallback;
    if (source is! List) return const <int>[1];
    final values = source
        .map((item) => item is num ? item.toInt() : int.tryParse('$item'))
        .whereType<int>()
        .where((item) => item > 0)
        .toList(growable: false);
    return values.isEmpty ? const <int>[1] : values;
  }

  static Map<String, dynamic> _stringMap(
    dynamic value, [
    dynamic fallback,
  ]) {
    final source = value is Map ? value : fallback;
    if (source is! Map) return const <String, dynamic>{};
    return source.map((key, value) => MapEntry('$key', value));
  }

  static Map<String, double> _doubleMap(dynamic value) {
    if (value is! Map) return const <String, double>{};
    final output = <String, double>{};
    for (final entry in value.entries) {
      final parsed = entry.value is num
          ? (entry.value as num).toDouble()
          : double.tryParse('${entry.value}');
      if (parsed != null && parsed.isFinite && parsed >= 0) {
        output['${entry.key}'] = parsed;
      }
    }
    return output;
  }
}
