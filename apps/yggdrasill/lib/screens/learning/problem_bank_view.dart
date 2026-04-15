import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../../models/education_level.dart';
import '../../services/data_manager.dart';
import '../../services/learning_problem_bank_service.dart';
import '../../services/tenant_service.dart';
import '../../utils/naesin_exam_context.dart';
import '../../widgets/animated_reorderable_grid.dart';
import 'models/problem_bank_export_models.dart';
import 'widgets/problem_bank_bottom_fab_bar.dart';
import 'widgets/problem_bank_export_options_panel.dart';
import 'widgets/problem_bank_export_server_preview_dialog.dart';
import 'widgets/problem_bank_filter_bar.dart';
import 'widgets/problem_bank_question_card.dart';
import 'widgets/problem_bank_school_sheet.dart';

class ProblemBankView extends StatefulWidget {
  const ProblemBankView({super.key});

  @override
  State<ProblemBankView> createState() => _ProblemBankViewState();
}

class _ProblemBankViewState extends State<ProblemBankView> {
  static const _rsBg = Color(0xFF0B1112);
  static const _rsBorder = Color(0xFF223131);
  static const _rsTextPrimary = Color(0xFFEAF2F2);
  static const _rsTextMuted = Color(0xFF9FB3B3);

  static const Map<String, String> _curriculumLabels = <String, String>{
    'legacy_1_6': '1차-6차 포괄',
    'curr_7th_1997': '7차 (1997)',
    'rev_2007': '2007 개정',
    'rev_2009': '2009 개정',
    'rev_2015': '2015 개정',
    'rev_2022': '2022 개정',
  };

  static const Map<String, String> _sourceTypeLabels = <String, String>{
    'private_material': '사설 교재',
    'school_past': '내신 기출',
    'mock_past': '모의고사 기출',
    'self_made': '자작문항',
  };

  static const List<String> _levelOptions = <String>['초', '중', '고'];
  static const String _kNaesinLinkConfigKey = 'naesinLinkKey';
  static const List<String> _kNaesinLinkExamTerms = <String>['중간고사', '기말고사'];
  final LearningProblemBankService _service = LearningProblemBankService();

  String? _academyId;
  bool _isInitializing = true;
  bool _isLoadingSchools = false;
  bool _isLoadingQuestions = false;
  bool _isExporting = false;
  bool _isSavingExportLocally = false;
  Timer? _pollTimer;
  Timer? _previewArtifactPollTimer;

  String _selectedCurriculumCode = 'rev_2022';
  String _selectedSchoolLevel = '중';
  String _selectedDetailedCourse = '전체';
  String _selectedSourceTypeCode = 'school_past';

  List<String> _courseOptions = const <String>['전체'];
  List<LearningProblemDocumentSummary> _sidebarDocuments =
      const <LearningProblemDocumentSummary>[];
  int _sidebarRevision = 0;
  String? _selectedDocumentId;

  List<LearningProblemQuestion> _questions = const <LearningProblemQuestion>[];
  final Set<String> _selectedQuestionIds = <String>{};
  final Map<String, String> _selectedQuestionModes = <String, String>{};
  final ScrollController _questionGridScrollCtrl = ScrollController();
  Map<String, Map<String, String>> _questionFigureUrlsByPath =
      const <String, Map<String, String>>{};
  Map<String, String> _questionPreviewUrls = const <String, String>{};
  Map<String, String> _questionPreviewPdfUrls = const <String, String>{};
  Map<String, String> _questionPreviewStatus = const <String, String>{};
  Map<String, String> _questionPreviewError = const <String, String>{};
  Set<String> _pendingPreviewQuestionIds = <String>{};
  int _figureLoadVersion = 0;
  LearningProblemExportSettings _exportSettings =
      LearningProblemExportSettings.initial();
  String _previewMathEngine = 'mathjax-svg';
  LearningProblemExportJob? _activeExportJob;
  _QuestionOrderSaveRequest? _queuedQuestionOrderSave;
  bool _questionOrderSaveInFlight = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _previewArtifactPollTimer?.cancel();
    _questionGridScrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final academyId = await TenantService.instance.getActiveAcademyId() ??
          await TenantService.instance.ensureActiveAcademy();
      if (!mounted) return;
      _academyId = academyId;
      await _loadDetailedCourseOptions(forceResetSelection: true);
      await _reloadSchoolsAndQuestions(resetSelection: true);
    } catch (e) {
      _showSnack('문제은행 초기화 실패: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isInitializing = false;
        });
      }
    }
  }

  Future<void> _loadDetailedCourseOptions({
    bool forceResetSelection = false,
  }) async {
    final labels = <String>[];
    try {
      final rows = await DataManager.instance.loadAnswerKeyGrades();
      for (final row in rows) {
        final raw = '${row['label'] ?? ''}'.trim();
        if (raw.isNotEmpty) labels.add(raw);
      }
    } catch (_) {}

    final resolvedOptions = _resolveCourseOptions(_selectedSchoolLevel, labels);
    if (!mounted) return;
    setState(() {
      _courseOptions = resolvedOptions;
      if (forceResetSelection ||
          !_courseOptions.contains(_selectedDetailedCourse)) {
        _selectedDetailedCourse = _courseOptions.first;
      }
    });
  }

  List<String> _resolveCourseOptions(String level, List<String> labels) {
    final filtered = labels
        .where((label) => _matchesLevelWithText(level, label))
        .toList(growable: false);
    final source =
        filtered.isNotEmpty ? filtered : _fallbackCourseByLevel(level);
    final set = <String>{};
    set.add('전체');
    for (final item in source) {
      final safe = item.trim();
      if (safe.isNotEmpty) set.add(safe);
    }
    return set.toList(growable: false);
  }

  List<String> _fallbackCourseByLevel(String level) {
    if (level == '초') {
      return const <String>[
        '초1-1',
        '초1-2',
        '초2-1',
        '초2-2',
        '초3-1',
        '초3-2',
        '초4-1',
        '초4-2',
        '초5-1',
        '초5-2',
        '초6-1',
        '초6-2',
      ];
    }
    if (level == '고') {
      return const <String>[
        '고1',
        '고2',
        '고3',
        '공통수학1',
        '공통수학2',
        '대수',
        '미적분1',
        '확률과 통계',
        '미적분2',
        '기하',
      ];
    }
    return const <String>[
      '중1-1',
      '중1-2',
      '중2-1',
      '중2-2',
      '중3-1',
      '중3-2',
    ];
  }

  bool _matchesLevelWithText(String level, String text) {
    final merged = text.replaceAll(' ', '');
    if (merged.isEmpty) return true;
    if (level == '초') {
      return merged.contains('초') || RegExp(r'^초?[1-6]-[12]$').hasMatch(merged);
    }
    if (level == '중') {
      return merged.contains('중') || RegExp(r'^중?[1-3]-[12]$').hasMatch(merged);
    }
    if (level == '고') {
      return merged.contains('고') ||
          merged.contains('공통수학') ||
          merged.contains('대수') ||
          merged.contains('미적분') ||
          merged.contains('확률') ||
          merged.contains('기하');
    }
    return true;
  }

  Future<void> _reloadSchoolsAndQuestions({
    required bool resetSelection,
  }) async {
    if (_academyId == null) return;
    if (mounted) {
      setState(() {
        _sidebarRevision++;
      });
    }
    await _reloadSidebarDocuments();
    await _reloadQuestions(resetSelection: resetSelection);
  }

  Future<void> _reloadSidebarDocuments() async {
    if (_academyId == null) return;
    setState(() {
      _isLoadingSchools = true;
    });
    try {
      final docs = await _service.listReadyDocuments(
        academyId: _academyId!,
        curriculumCode: _selectedCurriculumCode,
        schoolLevel: _selectedSchoolLevel,
        detailedCourse: _selectedDetailedCourse,
        sourceTypeCode: _selectedSourceTypeCode,
      );
      if (!mounted) return;
      setState(() {
        _sidebarDocuments = docs;
        if (_selectedDocumentId == null ||
            !docs.any((d) => d.id == _selectedDocumentId)) {
          _selectedDocumentId = docs.isNotEmpty ? docs.first.id : null;
        }
      });
    } catch (e) {
      _showSnack('문서 목록 조회 실패: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingSchools = false;
        });
      }
    }
  }

  Future<void> _reloadQuestions({
    required bool resetSelection,
  }) async {
    if (_academyId == null) return;
    setState(() {
      _isLoadingQuestions = true;
    });
    try {
      final fetched = await _service.searchQuestions(
        academyId: _academyId!,
        curriculumCode: _selectedCurriculumCode,
        schoolLevel: _selectedSchoolLevel,
        detailedCourse: _selectedDetailedCourse,
        sourceTypeCode: _selectedSourceTypeCode,
        documentId: _selectedDocumentId,
      );
      final defaultSorted = _sortedQuestionsByDefaultOrder(fetched);
      final scopeKey = _questionOrderScopeKey();
      final questions = await _applyPersistedQuestionOrder(
        defaultSorted,
        scopeKey: scopeKey,
      );
      if (!mounted) return;
      final aliveIds = questions.map((e) => e.id).toSet();
      final nextQuestionModes = <String, String>{};
      for (final q in questions) {
        nextQuestionModes[q.id] = normalizeQuestionModeSelection(
          q,
          _selectedQuestionModes[q.id],
          fallbackMode: kLearningQuestionModeOriginal,
        );
      }
      final currentFigureLoadVersion = ++_figureLoadVersion;
      setState(() {
        _questions = questions;
        _selectedQuestionModes
          ..clear()
          ..addAll(nextQuestionModes);
        _questionFigureUrlsByPath = const <String, Map<String, String>>{};
        _questionPreviewUrls = const <String, String>{};
        _questionPreviewPdfUrls = const <String, String>{};
        _questionPreviewStatus = const <String, String>{};
        _questionPreviewError = const <String, String>{};
        _pendingPreviewQuestionIds = <String>{};
        if (resetSelection) {
          _selectedQuestionIds.clear();
        } else {
          _selectedQuestionIds.removeWhere((id) => !aliveIds.contains(id));
        }
      });
      _previewArtifactPollTimer?.cancel();
      _previewArtifactPollTimer = null;
      unawaited(
        _prefetchFigureSignedUrls(
          questions,
          loadVersion: currentFigureLoadVersion,
        ),
      );
      unawaited(_fetchQuestionPreviews(questions));
    } catch (e) {
      _showSnack('문항 조회 실패: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingQuestions = false;
        });
      }
    }
  }

  List<LearningProblemQuestion> _sortedQuestionsByDefaultOrder(
    List<LearningProblemQuestion> source,
  ) {
    final sorted = List<LearningProblemQuestion>.from(source);
    sorted.sort(_compareQuestionByDefaultOrder);
    return sorted;
  }

  int _compareQuestionByDefaultOrder(
    LearningProblemQuestion a,
    LearningProblemQuestion b,
  ) {
    int numberOf(LearningProblemQuestion q) {
      final raw = q.questionNumber.trim();
      if (raw.isEmpty) return q.sourceOrder > 0 ? q.sourceOrder : 1 << 20;
      final matched = RegExp(r'\d+').firstMatch(raw);
      if (matched == null) return 1 << 20;
      return int.tryParse(matched.group(0) ?? '') ?? (1 << 20);
    }

    final an = numberOf(a);
    final bn = numberOf(b);
    if (an != bn) return an.compareTo(bn);
    if (a.sourcePage != b.sourcePage) {
      return a.sourcePage.compareTo(b.sourcePage);
    }
    if (a.sourceOrder != b.sourceOrder) {
      return a.sourceOrder.compareTo(b.sourceOrder);
    }
    return a.displayQuestionNumber.compareTo(b.displayQuestionNumber);
  }

  String _questionOrderScopeKey() {
    String enc(String value) => Uri.encodeComponent(value.trim());
    return <String>[
      'pb_scope_v1',
      enc(_selectedCurriculumCode),
      enc(_selectedSchoolLevel),
      enc(_selectedDetailedCourse),
      enc(_selectedSourceTypeCode),
      enc((_selectedDocumentId ?? '').trim()),
    ].join('|');
  }

  Future<List<LearningProblemQuestion>> _applyPersistedQuestionOrder(
    List<LearningProblemQuestion> sortedByDefault, {
    required String scopeKey,
  }) async {
    final academyId = _academyId;
    if (academyId == null ||
        academyId.isEmpty ||
        sortedByDefault.isEmpty ||
        scopeKey.trim().isEmpty) {
      return sortedByDefault;
    }
    final questionIds =
        sortedByDefault.map((q) => q.id).toList(growable: false);
    final persisted = await _service.loadQuestionOrders(
      academyId: academyId,
      scopeKey: scopeKey,
      questionIds: questionIds,
    );
    if (persisted.isEmpty) return sortedByDefault;

    final fallbackRank = <String, int>{};
    for (var i = 0; i < sortedByDefault.length; i += 1) {
      fallbackRank[sortedByDefault[i].id] = i;
    }
    final ordered = List<LearningProblemQuestion>.from(sortedByDefault);
    ordered.sort((a, b) {
      final ai = persisted[a.id];
      final bi = persisted[b.id];
      if (ai != null && bi != null) {
        if (ai != bi) return ai.compareTo(bi);
      } else if (ai != null) {
        return -1;
      } else if (bi != null) {
        return 1;
      }
      final ar = fallbackRank[a.id] ?? 1 << 20;
      final br = fallbackRank[b.id] ?? 1 << 20;
      if (ar != br) return ar.compareTo(br);
      return a.id.compareTo(b.id);
    });
    return ordered;
  }

  Future<void> _prefetchFigureSignedUrls(
    List<LearningProblemQuestion> questions, {
    required int loadVersion,
  }) async {
    final updates = <String, Map<String, String>>{};
    for (final question in questions) {
      final pathMap = <String, String>{};
      for (final asset in question.orderedFigureAssets) {
        final bucket = '${asset['bucket'] ?? ''}'.trim();
        final path = '${asset['path'] ?? ''}'.trim();
        if (bucket.isEmpty || path.isEmpty) continue;
        try {
          final signed = await _service.createStorageSignedUrl(
            bucket: bucket,
            path: path,
            expiresInSeconds: 60 * 60 * 24,
          );
          final safe = signed.trim();
          if (safe.isNotEmpty) {
            pathMap[path] = safe;
          }
        } catch (_) {
          // 그림 preview URL은 실패해도 문항 로딩은 계속 진행한다.
        }
      }
      updates[question.id] = pathMap;
    }
    if (!mounted) return;
    if (loadVersion != _figureLoadVersion) return;
    setState(() {
      _questionFigureUrlsByPath = updates;
    });
  }

  Future<void> _fetchQuestionPreviews(
    List<LearningProblemQuestion> questions,
  ) async {
    if (_academyId == null || _academyId!.isEmpty) return;
    if (questions.isEmpty) return;
    if (!_service.hasGateway) {
      _markQuestionPreviewBatchFailed(
        questions,
        message: '게이트웨이 연결이 없어 서버 미리보기를 불러올 수 없습니다.',
      );
      return;
    }
    final ordered = List<LearningProblemQuestion>.from(questions);
    const visibleFirstBatchSize = 24;
    final firstBatch = ordered.take(visibleFirstBatchSize).toList(growable: false);
    final restBatch = ordered.skip(visibleFirstBatchSize).toList(growable: false);

    await _fetchQuestionPdfArtifactsBatch(
      firstBatch,
      createJobs: true,
    );
    if (restBatch.isNotEmpty) {
      unawaited(_fetchQuestionPdfArtifactsInChunks(restBatch));
    }
  }

  Map<String, dynamic> _buildPdfPreviewRenderConfig(
    List<LearningProblemQuestion> questions,
  ) {
    final base = _buildRenderConfigForSelection(questions);
    return <String, dynamic>{
      ...base,
      'mathEngine': 'xelatex',
      'includeAnswerSheet': false,
      'includeExplanation': false,
      'includeQuestionScore': false,
    };
  }

  Future<void> _fetchQuestionPdfArtifactsInChunks(
    List<LearningProblemQuestion> questions,
  ) async {
    const chunkSize = 18;
    for (var i = 0; i < questions.length; i += chunkSize) {
      if (!mounted) return;
      final end = math.min(i + chunkSize, questions.length);
      final chunk = questions.sublist(i, end);
      await _fetchQuestionPdfArtifactsBatch(
        chunk,
        createJobs: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }

  Future<void> _fetchQuestionPdfArtifactsBatch(
    List<LearningProblemQuestion> batch, {
    required bool createJobs,
  }) async {
    final academyId = _academyId;
    if (academyId == null || academyId.isEmpty) return;
    if (batch.isEmpty || !_service.hasGateway) return;
    try {
      final questionIds = batch
          .map((q) => q.questionUid.trim().isNotEmpty ? q.questionUid.trim() : q.id.trim())
          .where((id) => id.isNotEmpty)
          .toList();
      if (questionIds.isEmpty) return;
      final renderConfig = _buildPdfPreviewRenderConfig(batch);
      final documentId = _selectedDocumentId?.trim().isNotEmpty == true
          ? _selectedDocumentId!.trim()
          : batch.first.documentId.trim();
      final artifacts = await _service.fetchQuestionPdfPreviewArtifacts(
        academyId: academyId,
        documentId: documentId,
        questionIds: questionIds,
        renderConfig: renderConfig,
        templateProfile: _exportSettings.templateProfile,
        paperSize: _exportSettings.paperLabel,
        createJobs: createJobs,
      );
      if (!mounted) return;
      if (artifacts.isEmpty) {
        _markQuestionPreviewBatchFailed(
          batch,
          message: '서버 미리보기 응답이 비어 있습니다. 다시 시도해 주세요.',
        );
        return;
      }
      _applyQuestionPdfArtifacts(artifacts);
      final uidToId = <String, String>{};
      for (final q in batch) {
        final id = q.id.trim();
        final uid = q.questionUid.trim();
        if (id.isNotEmpty) uidToId[id] = id;
        if (uid.isNotEmpty && uid != id) uidToId[uid] = id;
      }
      final returnedIds = <String>{};
      for (final key in artifacts.keys) {
        final mapped = uidToId[key.trim()] ?? key.trim();
        if (mapped.isNotEmpty) returnedIds.add(mapped);
      }
      final missingIds = batch
          .map((q) => q.id.trim())
          .where((id) => id.isNotEmpty && !returnedIds.contains(id))
          .toList(growable: false);
      if (missingIds.isNotEmpty) {
        _markQuestionPreviewIdsFailed(
          missingIds,
          message: '일부 문항의 서버 미리보기 응답이 누락되었습니다.',
        );
      }
    } catch (err) {
      _markQuestionPreviewBatchFailed(
        batch,
        message: _normalizePreviewErrorMessage(err),
      );
    }
  }

  String _normalizePreviewErrorMessage(Object err) {
    final raw = err.toString().trim();
    if (raw.isEmpty) return '서버 미리보기 요청에 실패했습니다.';
    if (raw.length <= 200) return raw;
    return '${raw.substring(0, 200)}...';
  }

  void _markQuestionPreviewBatchFailed(
    List<LearningProblemQuestion> batch, {
    required String message,
  }) {
    _markQuestionPreviewIdsFailed(
      batch.map((q) => q.id.trim()),
      message: message,
    );
  }

  void _markQuestionPreviewIdsFailed(
    Iterable<String> questionIds, {
    required String message,
  }) {
    if (!mounted) return;
    final safeIds = questionIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (safeIds.isEmpty) return;
    final safeMessage = message.trim().isNotEmpty
        ? message.trim()
        : '서버 미리보기에 실패했습니다.';
    setState(() {
      final nextStatus = <String, String>{..._questionPreviewStatus};
      final nextError = <String, String>{..._questionPreviewError};
      final nextPending = <String>{..._pendingPreviewQuestionIds};
      for (final id in safeIds) {
        nextStatus[id] = 'failed';
        nextError[id] = safeMessage;
        nextPending.remove(id);
      }
      _questionPreviewStatus = nextStatus;
      _questionPreviewError = nextError;
      _pendingPreviewQuestionIds = nextPending;
    });
    _ensurePreviewArtifactPolling();
  }

  void _applyQuestionPdfArtifacts(
    Map<String, LearningProblemPdfPreviewArtifact> artifacts,
  ) {
    final uidToId = <String, String>{};
    for (final q in _questions) {
      final uid = q.questionUid.trim();
      final id = q.id.trim();
      if (id.isNotEmpty) uidToId[id] = id;
      if (uid.isNotEmpty && uid != id) uidToId[uid] = id;
    }

    final nextPreviewUrls = <String, String>{..._questionPreviewUrls};
    final nextPdfUrls = <String, String>{..._questionPreviewPdfUrls};
    final nextStatus = <String, String>{..._questionPreviewStatus};
    final nextError = <String, String>{..._questionPreviewError};
    final nextPending = <String>{..._pendingPreviewQuestionIds};

    for (final entry in artifacts.entries) {
      final questionId = uidToId[entry.key.trim()] ?? entry.key.trim();
      if (questionId.isEmpty) continue;
      final artifact = entry.value;
      final status = artifact.status.trim().toLowerCase();
      if (status.isNotEmpty) {
        nextStatus[questionId] = status;
      }
      if (artifact.thumbnailUrl.isNotEmpty) {
        nextPreviewUrls[questionId] = artifact.thumbnailUrl;
      }
      if (artifact.pdfUrl.isNotEmpty) {
        nextPdfUrls[questionId] = artifact.pdfUrl;
      }
      if (artifact.error.isNotEmpty) {
        nextError[questionId] = artifact.error;
      } else {
        nextError.remove(questionId);
      }

      if (artifact.isPending) {
        nextPending.add(questionId);
      } else {
        nextPending.remove(questionId);
      }
    }

    if (!mounted) return;
    setState(() {
      _questionPreviewUrls = nextPreviewUrls;
      _questionPreviewPdfUrls = nextPdfUrls;
      _questionPreviewStatus = nextStatus;
      _questionPreviewError = nextError;
      _pendingPreviewQuestionIds = nextPending;
    });
    _ensurePreviewArtifactPolling();
  }

  void _ensurePreviewArtifactPolling() {
    if (_pendingPreviewQuestionIds.isEmpty) {
      _previewArtifactPollTimer?.cancel();
      _previewArtifactPollTimer = null;
      return;
    }
    if (_previewArtifactPollTimer != null) return;
    _previewArtifactPollTimer =
        Timer.periodic(const Duration(milliseconds: 1800), (_) {
      unawaited(_pollQuestionPreviewArtifacts());
    });
    unawaited(_pollQuestionPreviewArtifacts());
  }

  Future<void> _pollQuestionPreviewArtifacts() async {
    final academyId = _academyId;
    if (academyId == null || academyId.isEmpty) return;
    if (_pendingPreviewQuestionIds.isEmpty) {
      _previewArtifactPollTimer?.cancel();
      _previewArtifactPollTimer = null;
      return;
    }
    final pending = _questions
        .where((q) => _pendingPreviewQuestionIds.contains(q.id))
        .toList(growable: false);
    if (pending.isEmpty) {
      _previewArtifactPollTimer?.cancel();
      _previewArtifactPollTimer = null;
      return;
    }
    await _fetchQuestionPdfArtifactsBatch(
      pending,
      createJobs: false,
    );
  }

  void _retryQuestionPreview(String questionId) {
    LearningProblemQuestion? target;
    for (final question in _questions) {
      if (question.id == questionId) {
        target = question;
        break;
      }
    }
    if (target == null) return;
    setState(() {
      _questionPreviewStatus = {
        ..._questionPreviewStatus,
        questionId: 'queued',
      };
      _questionPreviewError = {
        ..._questionPreviewError,
      }..remove(questionId);
      _pendingPreviewQuestionIds = {
        ..._pendingPreviewQuestionIds,
        questionId,
      };
    });
    _ensurePreviewArtifactPolling();
    unawaited(
      _fetchQuestionPdfArtifactsBatch(
        <LearningProblemQuestion>[target],
        createJobs: true,
      ),
    );
  }

  Future<void> _onCurriculumChanged(String? value) async {
    if (value == null || value == _selectedCurriculumCode) return;
    setState(() {
      _selectedCurriculumCode = value;
    });
    await _reloadSchoolsAndQuestions(resetSelection: true);
  }

  Future<void> _onSchoolLevelChanged(String value) async {
    if (value == _selectedSchoolLevel) return;
    setState(() {
      _selectedSchoolLevel = value;
    });
    await _loadDetailedCourseOptions(forceResetSelection: true);
    await _reloadSchoolsAndQuestions(resetSelection: true);
  }

  Future<void> _onDetailedCourseChanged(String? value) async {
    if (value == null || value == _selectedDetailedCourse) return;
    setState(() {
      _selectedDetailedCourse = value;
    });
    await _reloadSchoolsAndQuestions(resetSelection: true);
  }

  Future<void> _onSourceTypeChanged(String? value) async {
    if (value == null || value == _selectedSourceTypeCode) return;
    setState(() {
      _selectedSourceTypeCode = value;
    });
    await _reloadSchoolsAndQuestions(resetSelection: true);
  }

  Future<void> _onSidebarDocumentSelected(String documentId) async {
    if (documentId == _selectedDocumentId) return;
    setState(() {
      _selectedDocumentId = documentId;
    });
    await _reloadQuestions(resetSelection: true);
  }

  String _fallbackNaesinSchoolFromSelectedDocument() {
    final id = _selectedDocumentId;
    if (id == null) return '';
    for (final d in _sidebarDocuments) {
      if (d.id == id) return d.schoolName.trim();
    }
    return '';
  }

  void _toggleQuestionSelection(String id, bool selected) {
    setState(() {
      if (selected) {
        _selectedQuestionIds.add(id);
      } else {
        _selectedQuestionIds.remove(id);
      }
    });
  }

  void _selectAllQuestions() {
    setState(() {
      _selectedQuestionIds
        ..clear()
        ..addAll(_questions.map((e) => e.id));
    });
  }

  void _clearQuestionSelection() {
    setState(() {
      _selectedQuestionIds.clear();
    });
  }

  void _commitQuestionReorder({
    required String id,
    required int targetIndex,
  }) {
    if (_questions.isEmpty) return;
    final ordered = List<LearningProblemQuestion>.from(_questions);
    final fromIndex = ordered.indexWhere((q) => q.id == id);
    if (fromIndex < 0) return;
    final moved = ordered.removeAt(fromIndex);
    final toIndex = targetIndex.clamp(0, ordered.length).toInt();
    ordered.insert(toIndex, moved);
    _questions = ordered;
  }

  void _requestQuestionOrderSave() {
    final academyId = _academyId;
    if (academyId == null || academyId.isEmpty || _questions.isEmpty) return;
    _queuedQuestionOrderSave = _QuestionOrderSaveRequest(
      academyId: academyId,
      scopeKey: _questionOrderScopeKey(),
      orderedQuestionIds:
          _questions.map((q) => q.id.trim()).where((e) => e.isNotEmpty).toList(
                growable: false,
              ),
    );
    if (_questionOrderSaveInFlight) return;
    unawaited(_flushQuestionOrderSaveQueue());
  }

  Future<void> _flushQuestionOrderSaveQueue() async {
    if (_questionOrderSaveInFlight) return;
    _questionOrderSaveInFlight = true;
    try {
      while (_queuedQuestionOrderSave != null) {
        final pending = _queuedQuestionOrderSave!;
        _queuedQuestionOrderSave = null;
        if (pending.orderedQuestionIds.isEmpty) continue;
        await _service.saveQuestionOrders(
          academyId: pending.academyId,
          scopeKey: pending.scopeKey,
          orderedQuestionIds: pending.orderedQuestionIds,
        );
      }
    } catch (e) {
      _showSnack('문항 순서 저장 실패: $e');
    } finally {
      _questionOrderSaveInFlight = false;
    }
  }

  List<LearningProblemQuestion> get _selectedQuestions {
    if (_selectedQuestionIds.isEmpty || _questions.isEmpty) {
      return const <LearningProblemQuestion>[];
    }
    return _questions
        .where((q) => _selectedQuestionIds.contains(q.id))
        .toList(growable: false);
  }

  String _selectedModeOfQuestion(LearningProblemQuestion question) {
    return normalizeQuestionModeSelection(
      question,
      _selectedQuestionModes[question.id],
      fallbackMode: kLearningQuestionModeOriginal,
    );
  }

  Map<String, String> _selectedModeMapForQuestions(
    List<LearningProblemQuestion> questions,
  ) {
    final out = <String, String>{};
    for (final question in questions) {
      final key = question.stableQuestionKey;
      if (key.isEmpty) continue;
      out[key] = _selectedModeOfQuestion(question);
    }
    return out;
  }

  void _setQuestionModeSelection(String questionId, String selectedMode) {
    LearningProblemQuestion? question;
    for (final candidate in _questions) {
      if (candidate.id == questionId) {
        question = candidate;
        break;
      }
    }
    if (question == null) return;
    final next = normalizeQuestionModeSelection(
      question,
      selectedMode,
      fallbackMode: kLearningQuestionModeOriginal,
    );
    if (_selectedQuestionModes[questionId] == next) return;
    setState(() {
      _selectedQuestionModes[questionId] = next;
    });
  }

  void _setExportLayoutColumns(String value) {
    final options = maxQuestionsPerPageOptionsOf(value);
    final current = _exportSettings.maxQuestionsPerPageLabel.trim();
    final parsed = int.tryParse(current);
    final nextMax = (current == '많이')
        ? '많이'
        : (parsed != null && options.contains(parsed))
            ? '$parsed'
            : '${options.last}';
    setState(() {
      _exportSettings = _exportSettings.copyWith(
        layoutColumnLabel: value,
        maxQuestionsPerPageLabel: nextMax,
      );
    });
  }

  List<String> _selectedQuestionUidsInCurrentOrder(
    List<LearningProblemQuestion> selectedQuestions,
  ) {
    return selectedQuestions
        .map((q) => q.stableQuestionKey)
        .where((uid) => uid.trim().isNotEmpty)
        .toList(growable: false);
  }

  Map<String, dynamic> _buildRenderConfigForSelection(
    List<LearningProblemQuestion> selectedQuestions, {
    LearningProblemExportSettings? settingsOverride,
  }) {
    final selectedModes = _selectedModeMapForQuestions(selectedQuestions);
    final orderedUids = _selectedQuestionUidsInCurrentOrder(selectedQuestions);
    final settings = settingsOverride ?? _exportSettings;
    return settings.toRenderConfig(
      selectedQuestionUidsOrdered: orderedUids,
      questionModeByQuestionUid: selectedModes,
    );
  }

  String _buildRenderHashForSelection(
    List<LearningProblemQuestion> selectedQuestions, {
    LearningProblemExportSettings? settingsOverride,
  }) {
    final selectedModes = _selectedModeMapForQuestions(selectedQuestions);
    final orderedUids = _selectedQuestionUidsInCurrentOrder(selectedQuestions);
    final settings = settingsOverride ?? _exportSettings;
    return buildLearningRenderHash(
      settings: settings,
      selectedQuestionUidsOrdered: orderedUids,
      questionModeByQuestionUid: selectedModes,
    );
  }

  Future<LearningProblemExportJob?> _waitForExportCompletion(
    LearningProblemExportJob initialJob,
  ) async {
    final academyId = _academyId;
    if (academyId == null || academyId.isEmpty) return null;
    var current = initialJob;
    if (mounted) {
      setState(() {
        _activeExportJob = current;
      });
    }
    for (var attempt = 0; attempt < 240; attempt += 1) {
      if (current.isTerminal) return current;
      await Future<void>.delayed(const Duration(seconds: 2));
      final latest = await _service.getExportJob(
        academyId: academyId,
        jobId: current.id,
      );
      if (latest == null) continue;
      current = latest;
      if (mounted) {
        setState(() {
          _activeExportJob = current;
        });
      }
      if (current.isTerminal) return current;
    }
    return current;
  }

  Future<LearningProblemExportJob?> _ensureCompletedExportForSelection({
    required List<LearningProblemQuestion> selectedQuestions,
    required bool previewOnly,
    Map<String, dynamic> renderConfigPatch = const <String, dynamic>{},
    LearningProblemExportSettings? settingsOverride,
  }) async {
    final academyId = _academyId;
    if (academyId == null || academyId.isEmpty) return null;
    if (selectedQuestions.isEmpty) return null;
    final settings = settingsOverride ?? _exportSettings;
    final renderHash = _buildRenderHashForSelection(
      selectedQuestions,
      settingsOverride: settings,
    );
    final renderConfig = <String, dynamic>{
      ..._buildRenderConfigForSelection(
        selectedQuestions,
        settingsOverride: settings,
      ),
      ...renderConfigPatch,
    };
    // Always generate a fresh server render so preview/PDF never picks
    // up stale completed jobs from an older renderer process/version.
    const reusable = null;
    if (reusable != null && reusable.outputUrl.trim().isNotEmpty) {
      if (mounted) {
        setState(() {
          _activeExportJob = reusable;
        });
      }
      return reusable;
    }

    final orderedUids = _selectedQuestionUidsInCurrentOrder(selectedQuestions);
    final options = <String, dynamic>{
      ...renderConfig,
      'renderHash': renderHash,
      'previewOnly': previewOnly,
    };
    final job = await _service.createExportJob(
      academyId: academyId,
      documentId: selectedQuestions.first.documentId,
      templateProfile: settings.templateProfile,
      paperSize: settings.paperLabel,
      includeAnswerSheet: settings.includeAnswerSheet,
      includeExplanation: settings.includeExplanation,
      selectedQuestionUids: orderedUids,
      renderHash: renderHash,
      previewOnly: previewOnly,
      options: options,
    );
    final completed = await _waitForExportCompletion(job);
    return completed;
  }

  Future<void> _openExportLayoutPreviewDialog() async {
    final selected = _selectedQuestions;
    if (selected.isEmpty) {
      _showSnack('레이아웃 미리보기할 문항을 먼저 선택해주세요.');
      return;
    }
    if (_isExporting || _isSavingExportLocally) return;
    setState(() {
      _isExporting = true;
    });
    try {
      bool readBoolFlag(
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

      Map<String, dynamic> readCoverPageTexts(
          dynamic primary, dynamic fallback) {
        final source = primary is Map
            ? primary
            : (fallback is Map ? fallback : const <String, dynamic>{});
        return source.map((key, value) => MapEntry('$key', value));
      }

      List<Map<String, dynamic>> readMapRows(
          dynamic primary, dynamic fallback) {
        final src = primary is List ? primary : fallback;
        if (src is! List) return const <Map<String, dynamic>>[];
        return src
            .whereType<Map>()
            .map((e) => e.map((key, value) => MapEntry('$key', value)))
            .toList(growable: false);
      }

      Map<String, double> readScoreMap(dynamic primary, dynamic fallback) {
        final src = primary is Map
            ? primary
            : (fallback is Map ? fallback : const <String, dynamic>{});
        final out = <String, double>{};
        for (final entry in src.entries) {
          final id = '${entry.key}'.trim();
          if (id.isEmpty) continue;
          final raw = entry.value;
          final score = raw is num ? raw.toDouble() : double.tryParse('$raw');
          if (score == null || !score.isFinite || score < 0) continue;
          out[id] = score;
        }
        return out;
      }

      List<int> readPositiveIntList(
        dynamic primary,
        dynamic fallback, {
        List<int> defaults = const <int>[1],
      }) {
        final src = primary is List ? primary : fallback;
        if (src is! List) return defaults;
        final out = src
            .map((e) => int.tryParse('$e'))
            .whereType<int>()
            .where((e) => e > 0)
            .toList(growable: false);
        return out.isEmpty ? defaults : out;
      }

      double parseDefaultQuestionScore(LearningProblemQuestion question) {
        final rawScore =
            question.meta['score_point'] ?? question.meta['scorePoint'];
        final parsed = rawScore is num
            ? rawScore.toDouble()
            : double.tryParse('$rawScore');
        if (parsed == null || !parsed.isFinite || parsed < 0) return 3;
        return parsed;
      }

      List<ProblemBankPreviewQuestionScoreEntry> buildScoreEntries(
        List<LearningProblemQuestion> questions,
      ) {
        final out = <ProblemBankPreviewQuestionScoreEntry>[];
        final seen = <String>{};
        for (final question in questions) {
          final id = question.stableQuestionKey.trim();
          if (id.isEmpty || seen.contains(id)) continue;
          seen.add(id);
          out.add(
            ProblemBankPreviewQuestionScoreEntry(
              questionId: id,
              questionNumber: question.displayQuestionNumber.trim().isEmpty
                  ? '${out.length + 1}'
                  : question.displayQuestionNumber.trim(),
              defaultScore: parseDefaultQuestionScore(question),
            ),
          );
        }
        return out;
      }

      String normalizeMathEngineValue(dynamic raw) {
        final v = '$raw'.trim().toLowerCase();
        return v == 'xelatex' ? 'xelatex' : 'mathjax-svg';
      }

      Map<String, dynamic> buildRenderPatch(
        ProblemBankPreviewRefreshRequest request,
      ) {
        final topText = request.titlePageTopText.trim();
        final timeLimitText = request.timeLimitText.trim();
        final patch = <String, dynamic>{
          'subjectTitleText': request.subjectTitleText.trim().isEmpty
              ? '수학 영역'
              : request.subjectTitleText.trim(),
          'titlePageTopText':
              topText.isEmpty ? kLearningDefaultTitlePageTopText : topText,
          'timeLimitText': timeLimitText,
          'includeAcademyLogo': request.includeAcademyLogo,
          'includeCoverPage': request.includeCoverPage,
          'coverPageTexts': request.coverPageTexts,
          'includeQuestionScore': request.includeQuestionScore,
          'questionScoreByQuestionUid': request.questionScoreByQuestionId,
          'questionScoreByQuestionId': request.questionScoreByQuestionId,
          'mathEngine': request.mathEngine,
        };
        if (_exportSettings.layoutColumnCount == 2) {
          patch['layoutMode'] = 'custom_columns';
          patch['pageColumnQuestionCounts'] = request.pageColumnQuestionCounts;
          patch['columnLabelAnchors'] = request.columnLabelAnchors;
          patch['titlePageIndices'] = request.titlePageIndices;
          patch['titlePageHeaders'] = request.titlePageHeaders;
        }
        return patch;
      }

      final academyId = _academyId;
      final selectedDocumentIds = selected
          .map((q) => q.documentId.trim())
          .where((id) => id.isNotEmpty)
          .toSet();
      var initialRenderPatch = <String, dynamic>{
        'mathEngine': _previewMathEngine,
      };

      if (academyId != null &&
          academyId.isNotEmpty &&
          selectedDocumentIds.length == 1) {
        final documentId = selectedDocumentIds.first;
        try {
          final preset = await _service.getDocumentExportPreset(
            academyId: academyId,
            documentId: documentId,
          );
          if (preset != null) {
            final presetSettings =
                LearningProblemExportSettings.fromPresetRenderConfig(
              base: _exportSettings,
              renderConfig: preset.renderConfig,
            );
            final presetMathEngine = normalizeMathEngineValue(
              preset.renderConfig['mathEngine'],
            );
            final presetModeMap = <String, String>{};
            for (final question in selected) {
              final rawMode = preset
                      .questionModeByQuestionUid[question.stableQuestionKey] ??
                  preset.questionModeByQuestionUid[question.id];
              if (rawMode == null || rawMode.trim().isEmpty) continue;
              presetModeMap[question.id] = normalizeQuestionModeSelection(
                question,
                rawMode,
                fallbackMode: kLearningQuestionModeOriginal,
              );
            }
            if (mounted) {
              setState(() {
                _exportSettings = presetSettings;
                _previewMathEngine = presetMathEngine;
                _selectedQuestionModes
                  ..clear()
                  ..addAll(presetModeMap);
              });
            }
            final subjectTitle =
                '${preset.renderConfig['subjectTitleText'] ?? ''}'.trim();
            final titlePageTopText =
                '${preset.renderConfig['titlePageTopText'] ?? ''}'.trim();
            final timeLimitText =
                '${preset.renderConfig['timeLimitText'] ?? ''}'.trim();
            initialRenderPatch = <String, dynamic>{
              'subjectTitleText': subjectTitle.isEmpty ? '수학 영역' : subjectTitle,
              'titlePageTopText': titlePageTopText.isEmpty
                  ? kLearningDefaultTitlePageTopText
                  : titlePageTopText,
              'timeLimitText': timeLimitText,
              'mathEngine': presetMathEngine,
              'includeAcademyLogo': readBoolFlag(
                preset.renderConfig['includeAcademyLogo'],
                null,
                false,
              ),
              'includeCoverPage': readBoolFlag(
                preset.renderConfig['includeCoverPage'],
                null,
                false,
              ),
              'includeQuestionScore': readBoolFlag(
                preset.renderConfig['includeQuestionScore'],
                null,
                false,
              ),
              'questionScoreByQuestionId': readScoreMap(
                preset.renderConfig['questionScoreByQuestionUid'],
                preset.renderConfig['questionScoreByQuestionId'],
              ),
              'questionScoreByQuestionUid': readScoreMap(
                preset.renderConfig['questionScoreByQuestionUid'],
                const <String, dynamic>{},
              ),
              'coverPageTexts': readCoverPageTexts(
                preset.renderConfig['coverPageTexts'],
                const <String, dynamic>{},
              ),
            };
            if (presetSettings.layoutColumnCount == 2) {
              initialRenderPatch = <String, dynamic>{
                ...initialRenderPatch,
                'layoutMode': 'custom_columns',
                'pageColumnQuestionCounts': readMapRows(
                  preset.renderConfig['pageColumnQuestionCounts'],
                  const <dynamic>[],
                ),
                'columnLabelAnchors': readMapRows(
                  preset.renderConfig['columnLabelAnchors'],
                  const <dynamic>[],
                ),
                'titlePageIndices': readPositiveIntList(
                  preset.renderConfig['titlePageIndices'],
                  const <dynamic>[],
                ),
                'titlePageHeaders': readMapRows(
                  preset.renderConfig['titlePageHeaders'],
                  const <dynamic>[],
                ),
              };
            }
          }
        } catch (e) {
          _showSnack('저장된 세팅 조회 실패: $e');
        }
      }

      final completed = await _ensureCompletedExportForSelection(
        selectedQuestions: selected,
        previewOnly: true,
        renderConfigPatch: initialRenderPatch,
      );
      if (!mounted || completed == null) return;
      if (completed.status != 'completed' ||
          completed.outputUrl.trim().isEmpty) {
        final err = completed.errorMessage.isNotEmpty
            ? completed.errorMessage
            : completed.errorCode;
        _showSnack(
          '미리보기 생성 실패: ${err.isEmpty ? completed.status : err}',
        );
        return;
      }
      final initialSubjectTitle =
          '${completed.resultSummary['subjectTitleText'] ?? completed.options['subjectTitleText'] ?? '수학 영역'}'
              .trim();
      final initialTitlePageTopText =
          '${completed.resultSummary['titlePageTopText'] ?? completed.options['titlePageTopText'] ?? kLearningDefaultTitlePageTopText}'
              .trim();
      final initialTimeLimitText =
          '${completed.resultSummary['timeLimitText'] ?? completed.options['timeLimitText'] ?? _exportSettings.timeLimitText}'
              .trim();
      final initialMathEngine = normalizeMathEngineValue(
        completed.resultSummary['mathEngine'] ??
            completed.options['mathEngine'] ??
            _previewMathEngine,
      );
      if (mounted) {
        setState(() {
          _previewMathEngine = initialMathEngine;
        });
      }
      final scoreEntries = buildScoreEntries(selected);
      await ProblemBankExportServerPreviewDialog.open(
        context,
        pdfUrl: completed.outputUrl,
        titleText: '서버 PDF 미리보기 (${selected.length}문항)',
        initialSubjectTitle:
            initialSubjectTitle.isEmpty ? '수학 영역' : initialSubjectTitle,
        initialTitlePageTopText: initialTitlePageTopText.isEmpty
            ? kLearningDefaultTitlePageTopText
            : initialTitlePageTopText,
        initialTimeLimitText: initialTimeLimitText,
        initialIncludeAcademyLogo: readBoolFlag(
          completed.resultSummary['includeAcademyLogo'],
          completed.options['includeAcademyLogo'],
          _exportSettings.includeAcademyLogo,
        ),
        layoutColumns: _exportSettings.layoutColumnCount,
        maxQuestionsPerPage: _exportSettings.maxQuestionsPerPageCount,
        totalQuestionCount: selected.length,
        initialPageColumnQuestionCounts: readMapRows(
          completed.resultSummary['pageColumnQuestionCounts'],
          completed.options['pageColumnQuestionCounts'],
        ),
        initialColumnLabelAnchors: readMapRows(
          completed.resultSummary['columnLabelAnchors'],
          completed.options['columnLabelAnchors'],
        ),
        initialTitlePageIndices: readPositiveIntList(
          completed.resultSummary['titlePageIndices'],
          completed.options['titlePageIndices'],
        ),
        initialTitlePageHeaders: readMapRows(
          completed.resultSummary['titlePageHeaders'],
          completed.options['titlePageHeaders'],
        ),
        initialIncludeCoverPage: readBoolFlag(
          completed.resultSummary['includeCoverPage'],
          completed.options['includeCoverPage'],
          false,
        ),
        initialIncludeAnswerSheet: readBoolFlag(
          completed.resultSummary['includeAnswerSheet'],
          completed.options['includeAnswerSheet'],
          _exportSettings.includeAnswerSheet,
        ),
        initialIncludeExplanation: readBoolFlag(
          completed.resultSummary['includeExplanation'],
          completed.options['includeExplanation'],
          _exportSettings.includeExplanation,
        ),
        initialIncludeQuestionScore: readBoolFlag(
          completed.resultSummary['includeQuestionScore'],
          completed.options['includeQuestionScore'],
          _exportSettings.includeQuestionScore,
        ),
        initialMathEngine: initialMathEngine,
        initialQuestionScoreByQuestionId: readScoreMap(
          completed.resultSummary['questionScoreByQuestionUid'],
          completed.options['questionScoreByQuestionUid'] ??
              completed.resultSummary['questionScoreByQuestionId'] ??
              completed.options['questionScoreByQuestionId'],
        ),
        questionScoreEntries: scoreEntries,
        initialCoverPageTexts: readCoverPageTexts(
          completed.resultSummary['coverPageTexts'],
          completed.options['coverPageTexts'],
        ),
        onRefreshRequested: (request) async {
          final nextSettings = _exportSettings.copyWith(
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
          setState(() {
            _exportSettings = nextSettings;
            _previewMathEngine = normalizeMathEngineValue(request.mathEngine);
          });
          final renderPatch = buildRenderPatch(request);
          final refreshed = await _ensureCompletedExportForSelection(
            selectedQuestions: selected,
            previewOnly: true,
            renderConfigPatch: renderPatch,
            settingsOverride: nextSettings,
          );
          if (!mounted || refreshed == null) return null;
          if (refreshed.status != 'completed' ||
              refreshed.outputUrl.trim().isEmpty) {
            final err = refreshed.errorMessage.isNotEmpty
                ? refreshed.errorMessage
                : refreshed.errorCode;
            _showSnack(
              '미리보기 생성 실패: ${err.isEmpty ? refreshed.status : err}',
            );
            return null;
          }
          final refreshedMathEngine = normalizeMathEngineValue(
            refreshed.resultSummary['mathEngine'] ??
                refreshed.options['mathEngine'] ??
                request.mathEngine,
          );
          if (refreshedMathEngine != normalizeMathEngineValue(request.mathEngine)) {
            _showSnack(
              '미리보기 생성 실패: 요청 엔진(${request.mathEngine})과 응답 엔진($refreshedMathEngine)이 다릅니다.',
            );
            return null;
          }
          final includeCoverPage = readBoolFlag(
            refreshed.resultSummary['includeCoverPage'],
            refreshed.options['includeCoverPage'],
            request.includeCoverPage,
          );
          final includeAnswerSheet = readBoolFlag(
            refreshed.resultSummary['includeAnswerSheet'],
            refreshed.options['includeAnswerSheet'],
            request.includeAnswerSheet,
          );
          final includeExplanation = readBoolFlag(
            refreshed.resultSummary['includeExplanation'],
            refreshed.options['includeExplanation'],
            request.includeExplanation,
          );
          final includeQuestionScore = readBoolFlag(
            refreshed.resultSummary['includeQuestionScore'],
            refreshed.options['includeQuestionScore'],
            request.includeQuestionScore,
          );
          final includeAcademyLogo = readBoolFlag(
            refreshed.resultSummary['includeAcademyLogo'],
            refreshed.options['includeAcademyLogo'],
            request.includeAcademyLogo,
          );
          final timeLimitText =
              '${refreshed.resultSummary['timeLimitText'] ?? refreshed.options['timeLimitText'] ?? request.timeLimitText}'
                  .trim();
          final titlePageTopText =
              '${refreshed.resultSummary['titlePageTopText'] ?? refreshed.options['titlePageTopText'] ?? request.titlePageTopText}'
                  .trim();
          final coverPageTexts = readCoverPageTexts(
            refreshed.resultSummary['coverPageTexts'],
            refreshed.options['coverPageTexts'],
          );
          final questionScoreByQuestionId = readScoreMap(
            refreshed.resultSummary['questionScoreByQuestionUid'],
            refreshed.resultSummary['questionScoreByQuestionId'] ??
                refreshed.options['questionScoreByQuestionId'],
          );
          final questionScoreByQuestionUid = readScoreMap(
            refreshed.resultSummary['questionScoreByQuestionUid'],
            refreshed.options['questionScoreByQuestionUid'],
          );
          final mergedQuestionScoreMap = questionScoreByQuestionUid.isNotEmpty
              ? questionScoreByQuestionUid
              : questionScoreByQuestionId;
          return ProblemBankPreviewRefreshResult(
            pdfUrl: refreshed.outputUrl,
            mathEngine: refreshedMathEngine,
            titlePageTopText: titlePageTopText.isEmpty
                ? kLearningDefaultTitlePageTopText
                : titlePageTopText,
            timeLimitText: timeLimitText,
            includeAcademyLogo: includeAcademyLogo,
            pageColumnQuestionCounts: readMapRows(
              refreshed.resultSummary['pageColumnQuestionCounts'],
              refreshed.options['pageColumnQuestionCounts'],
            ),
            columnLabelAnchors: readMapRows(
              refreshed.resultSummary['columnLabelAnchors'],
              refreshed.options['columnLabelAnchors'],
            ),
            titlePageIndices: readPositiveIntList(
              refreshed.resultSummary['titlePageIndices'],
              refreshed.options['titlePageIndices'],
            ),
            titlePageHeaders: readMapRows(
              refreshed.resultSummary['titlePageHeaders'],
              refreshed.options['titlePageHeaders'],
            ),
            coverPageTexts: coverPageTexts,
            includeCoverPage: includeCoverPage,
            includeAnswerSheet: includeAnswerSheet,
            includeExplanation: includeExplanation,
            includeQuestionScore: includeQuestionScore,
            questionScoreByQuestionId: mergedQuestionScoreMap,
          );
        },
        onGeneratePdfRequested: (request) async {
          final nextSettings = _exportSettings.copyWith(
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
          setState(() {
            _exportSettings = nextSettings;
            _previewMathEngine = normalizeMathEngineValue(request.mathEngine);
          });
          final renderPatch = buildRenderPatch(request);
          final completedPdf = await _ensureCompletedExportForSelection(
            selectedQuestions: selected,
            previewOnly: false,
            renderConfigPatch: renderPatch,
            settingsOverride: nextSettings,
          );
          if (!mounted || completedPdf == null) return;
          if (completedPdf.status != 'completed' ||
              completedPdf.outputUrl.trim().isEmpty) {
            final err = completedPdf.errorMessage.isNotEmpty
                ? completedPdf.errorMessage
                : completedPdf.errorCode;
            _showSnack('PDF 생성 실패: ${err.isEmpty ? completedPdf.status : err}');
            return;
          }
          await _saveCompletedExportToLocal(completedPdf);
        },
        onSaveSettingsRequested: (request) async {
          final academyId = _academyId;
          if (academyId == null || academyId.isEmpty) {
            _showSnack('학원 정보가 없어 세팅 저장을 진행할 수 없습니다.');
            return;
          }
          setState(() {
            _exportSettings = _exportSettings.copyWith(
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
            _previewMathEngine = normalizeMathEngineValue(request.mathEngine);
          });
          final orderedQuestionUids =
              _selectedQuestionUidsInCurrentOrder(selected);
          if (orderedQuestionUids.isEmpty) {
            _showSnack('저장할 문항이 없습니다.');
            return;
          }
          final renderPatch = buildRenderPatch(request);
          final renderConfig = <String, dynamic>{
            ..._buildRenderConfigForSelection(selected),
            ...renderPatch,
          };
          final sourceDocumentId = selected.first.documentId.trim();
          if (sourceDocumentId.isEmpty) {
            _showSnack('원본 문서 정보를 찾지 못했습니다.');
            return;
          }
          try {
            final saveResult = await _service.saveExportSettingsAsDocument(
              academyId: academyId,
              sourceDocumentId: sourceDocumentId,
              selectedQuestionUidsOrdered: orderedQuestionUids,
              questionModeByQuestionUid: _selectedModeMapForQuestions(selected),
              renderConfig: renderConfig,
              templateProfile: _exportSettings.templateProfile,
              paperSize: _exportSettings.paperLabel,
              includeAnswerSheet: request.includeAnswerSheet,
              includeExplanation: request.includeExplanation,
              displayName: request.presetDisplayName.trim(),
            );
            final count = saveResult.copiedQuestionCount;
            _showSnack(
              '프리셋 저장 완료 (${count > 0 ? count : orderedQuestionUids.length}문항)',
            );
          } catch (e) {
            _showSnack('세팅 저장 실패: $e');
          }
        },
      );
    } catch (e) {
      _showSnack('서버 미리보기 실패: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isExporting = false;
        });
      }
    }
  }

  void _ensureExportPolling() {
    final job = _activeExportJob;
    if (job == null || job.isTerminal) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(_pollExportJob());
    });
    unawaited(_pollExportJob());
  }

  // ignore: unused_element
  Future<void> _syncLatestExportJob() async {
    final academyId = _academyId;
    if (academyId == null || academyId.isEmpty) return;
    try {
      final jobs = await _service.listExportJobs(
        academyId: academyId,
        limit: 8,
      );
      if (!mounted) return;
      if (jobs.isEmpty) {
        setState(() {
          _activeExportJob = null;
          _isExporting = false;
        });
        return;
      }
      final pending = jobs.where(
        (job) => job.status == 'queued' || job.status == 'rendering',
      );
      final target = pending.isNotEmpty ? pending.first : jobs.first;
      setState(() {
        _activeExportJob = target;
        _isExporting = !target.isTerminal;
      });
      _ensureExportPolling();
    } catch (_) {
      // 과거 export 상태 복원 실패는 초기 화면 진입을 막지 않는다.
    }
  }

  Future<void> _pollExportJob() async {
    final academyId = _academyId;
    final currentJob = _activeExportJob;
    if (academyId == null || academyId.isEmpty || currentJob == null) return;
    if (currentJob.isTerminal) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }
    try {
      final latest = await _service.getExportJob(
        academyId: academyId,
        jobId: currentJob.id,
      );
      if (!mounted || latest == null) return;
      setState(() {
        _activeExportJob = latest;
        _isExporting = !latest.isTerminal;
      });

      if (!latest.isTerminal) return;

      _pollTimer?.cancel();
      _pollTimer = null;
      if (latest.status == 'completed') {
        _showSnack('PDF 생성이 완료되었습니다. 저장 위치를 선택해주세요.');
        await _saveCompletedExportToLocal(latest);
        final refreshed = await _service.getExportJob(
          academyId: academyId,
          jobId: latest.id,
        );
        if (mounted && refreshed != null) {
          setState(() {
            _activeExportJob = refreshed;
          });
        }
      } else if (latest.status == 'failed') {
        final errorText = latest.errorMessage.isEmpty
            ? latest.errorCode
            : latest.errorMessage;
        _showSnack(
            'PDF 생성 실패: ${errorText.isEmpty ? latest.status : errorText}');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isExporting = false;
      });
      _showSnack('export 상태 조회 실패: $e');
    }
  }

  String _defaultExportPdfFileName(LearningProblemExportJob job) {
    final selected = _selectedQuestions;
    final sourceDocs = selected
        .map((q) => q.documentId)
        .where((e) => e.trim().isNotEmpty)
        .toSet();
    final sourceName = sourceDocs.length <= 1 && selected.isNotEmpty
        ? selected.first.documentSourceName.trim()
        : 'problem_set_multi';
    final base = (sourceName.isEmpty ? 'problem_bank' : sourceName)
        .replaceAll(RegExp(r'\.[^.]+$'), '');
    final stamp = _todayStamp();
    return '${base}_${job.paperSize}_$stamp.pdf';
  }

  String _normalizeSavePathWithPdfExtension(String rawPath) {
    final trimmed = rawPath.trim();
    if (trimmed.toLowerCase().endsWith('.pdf')) return trimmed;
    return '$trimmed.pdf';
  }

  Future<void> _saveCompletedExportToLocal(LearningProblemExportJob job) async {
    if (_isSavingExportLocally) return;
    if (!mounted) return;

    setState(() {
      _isSavingExportLocally = true;
    });
    try {
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'PDF 저장 위치 선택',
        fileName: _defaultExportPdfFileName(job),
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
      );
      if (savePath == null || savePath.trim().isEmpty) {
        _showSnack('로컬 저장이 취소되었습니다.');
      } else {
        var rawUrl = job.outputUrl.trim();
        if (rawUrl.isEmpty &&
            job.outputStorageBucket.isNotEmpty &&
            job.outputStoragePath.isNotEmpty) {
          rawUrl = await _service.createStorageSignedUrl(
            bucket: job.outputStorageBucket,
            path: job.outputStoragePath,
          );
        }
        if (rawUrl.isEmpty) {
          throw Exception('PDF URL을 확보하지 못해 로컬 저장을 진행할 수 없습니다.');
        }
        late final List<int> bytes;
        try {
          bytes = await _service.downloadPdfBytesFromUrl(rawUrl);
        } catch (_) {
          if (job.outputStorageBucket.isEmpty ||
              job.outputStoragePath.isEmpty) {
            rethrow;
          }
          final refreshed = await _service.createStorageSignedUrl(
            bucket: job.outputStorageBucket,
            path: job.outputStoragePath,
          );
          if (refreshed.trim().isEmpty) rethrow;
          bytes = await _service.downloadPdfBytesFromUrl(refreshed);
        }
        final normalizedPath = _normalizeSavePathWithPdfExtension(savePath);
        final outFile = File(normalizedPath);
        await outFile.parent.create(recursive: true);
        await outFile.writeAsBytes(bytes, flush: true);
        await OpenFilex.open(normalizedPath);
        _showSnack('PDF 저장 완료: $normalizedPath');
      }
    } catch (e) {
      _showSnack('로컬 저장 실패: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isSavingExportLocally = false;
        });
      }
    }
  }

  // ignore: unused_element
  Future<void> _openPreviewDialog() async {
    final selected = _selectedQuestions;
    if (selected.isEmpty) {
      _showSnack('미리보기할 문항을 먼저 선택해주세요.');
      return;
    }
    final size = MediaQuery.sizeOf(context);
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0B1112),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: Text(
            '선택 문항 미리보기 (${selected.length}개)',
            style: const TextStyle(
              color: _rsTextPrimary,
              fontWeight: FontWeight.w800,
            ),
          ),
          content: SizedBox(
            width: size.width * 0.82,
            height: size.height * 0.72,
            child: ListView.separated(
              itemCount: selected.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final q = selected[index];
                final previewUrl = (_questionPreviewUrls[q.id] ?? '').trim();
                final previewStatus =
                    (_questionPreviewStatus[q.id] ?? '').trim().toLowerCase();
                final previewError = (_questionPreviewError[q.id] ?? '').trim();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${q.displayQuestionNumber}번 문항',
                      style: const TextStyle(
                        color: _rsTextPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: const Color(0xFF0E1518),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: _rsBorder),
                      ),
                      padding: const EdgeInsets.all(8.5),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFFD5D5D5)),
                        ),
                        child: previewUrl.isNotEmpty
                            ? SingleChildScrollView(
                                physics: const ClampingScrollPhysics(),
                                child: Image.network(
                                  previewUrl,
                                  fit: BoxFit.fitWidth,
                                  alignment: Alignment.topCenter,
                                  errorBuilder: (_, __, ___) => const Padding(
                                    padding: EdgeInsets.all(14),
                                    child: Text(
                                      '서버 PDF 썸네일을 불러오지 못했습니다.',
                                      style: TextStyle(
                                        color: Color(0xFF6E7E96),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                              )
                            : Padding(
                                padding: const EdgeInsets.all(14),
                                child: Text(
                                  previewStatus == 'queued' ||
                                          previewStatus == 'running'
                                      ? '서버 PDF 미리보기 생성 중...'
                                      : (previewStatus == 'failed' ||
                                              previewStatus == 'cancelled')
                                          ? (previewError.isNotEmpty
                                              ? previewError
                                              : '서버 PDF 미리보기에 실패했습니다.')
                                          : '서버 PDF 미리보기 대기 중...',
                                  style: const TextStyle(
                                    color: Color(0xFF6E7E96),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                '닫기',
                style: TextStyle(color: _rsTextMuted),
              ),
            ),
          ],
        );
      },
    );
  }

  String _todayStamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}';
  }

  void _showCreatePlaceholder() {
    _showSnack('만들기 기능은 다음 단계에서 구현 예정입니다.');
  }

  String _formatDateTimeShort(DateTime? value) {
    if (value == null) return '날짜 없음';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} ${two(value.hour)}:${two(value.minute)}';
  }

  String _defaultNaesinExamTermByDate(DateTime now) {
    return NaesinExamContext.defaultNaesinExamTermByDate(now);
  }

  int _defaultNaesinYearByDate(DateTime now) {
    final year = now.year;
    const years = NaesinExamContext.linkYears;
    if (years.contains(year)) return year;
    if (year < years.first) return years.first;
    return years.last;
  }

  String _buildNaesinLinkKey({
    required String gradeKey,
    required String courseKey,
    required String examTerm,
    required String school,
    required int year,
  }) {
    return NaesinExamContext.buildNaesinLinkKey(
      gradeKey: gradeKey,
      courseKey: courseKey,
      examTerm: examTerm,
      school: school,
      year: year,
    );
  }

  _NaesinLinkSelection? _parseNaesinLinkKey(String raw) {
    final parsed = NaesinExamContext.parseNaesinLinkKey(raw);
    if (parsed == null) return null;
    return _NaesinLinkSelection(
      gradeKey: parsed.gradeKey,
      courseKey: parsed.courseKey,
      examTerm: parsed.examTerm,
      school: parsed.school,
      year: parsed.year,
    );
  }

  String _naesinLinkSummaryLabel(String rawKey) {
    final parsed = _parseNaesinLinkKey(rawKey);
    if (parsed == null) return '';
    return '${parsed.school} · ${parsed.year} · ${parsed.courseKey} · ${parsed.examTerm}';
  }

  List<_NaesinGradeOption> _naesinGradeOptionsForLevel(String level) {
    final el =
        level.trim() == '고' ? EducationLevel.high : EducationLevel.middle;
    return NaesinExamContext.gradeOptionsForLevel(el)
        .map((e) => _NaesinGradeOption(key: e.key, label: e.label))
        .toList();
  }

  List<_NaesinCourseOption> _naesinCourseOptionsForGrade(String gradeKey) {
    return NaesinExamContext.courseOptionsForGrade(gradeKey)
        .map((e) => _NaesinCourseOption(key: e.key, label: e.label))
        .toList();
  }

  ({String gradeKey, String courseKey}) _deriveNaesinDefaultGradeCourse() {
    final now = DateTime.now();
    final isHigh = _selectedSchoolLevel.trim() == '고';
    final normalizedCourse =
        _selectedDetailedCourse.replaceAll(' ', '').replaceAll('학기', '').trim();
    if (isHigh) {
      if (normalizedCourse.contains('공통수학1')) {
        return (gradeKey: 'H1', courseKey: 'H1-c1');
      }
      if (normalizedCourse.contains('공통수학2')) {
        return (gradeKey: 'H1', courseKey: 'H1-c2');
      }
      if (normalizedCourse.contains('고2')) {
        return (gradeKey: 'H2', courseKey: 'H-algebra');
      }
      if (normalizedCourse.contains('고3')) {
        return (gradeKey: 'H3', courseKey: 'H-algebra');
      }
      final firstSemester = now.month <= 7;
      return (
        gradeKey: 'H1',
        courseKey: firstSemester ? 'H1-c1' : 'H1-c2',
      );
    }
    final matched =
        RegExp(r'([1-3])\s*-\s*([1-2])').firstMatch(normalizedCourse);
    if (matched != null) {
      final grade = matched.group(1)!;
      final semester = matched.group(2)!;
      return (gradeKey: 'M$grade', courseKey: 'M$grade-$semester');
    }
    if (normalizedCourse.contains('중2')) {
      final semester = now.month <= 7 ? '1' : '2';
      return (gradeKey: 'M2', courseKey: 'M2-$semester');
    }
    if (normalizedCourse.contains('중3')) {
      final semester = now.month <= 7 ? '1' : '2';
      return (gradeKey: 'M3', courseKey: 'M3-$semester');
    }
    final semester = now.month <= 7 ? '1' : '2';
    return (gradeKey: 'M1', courseKey: 'M1-$semester');
  }

  Future<void> _openExportPresetManagerDialog() async {
    final academyId = _academyId;
    if (academyId == null || academyId.isEmpty) {
      _showSnack('학원 정보가 없어 프리셋을 불러올 수 없습니다.');
      return;
    }
    List<LearningProblemDocumentExportPreset> initialPresets;
    try {
      initialPresets = await _service.listExportPresets(
        academyId: academyId,
        limit: 300,
      );
    } catch (e) {
      _showSnack('프리셋 목록 조회 실패: $e');
      return;
    }
    if (!mounted) return;

    final size = MediaQuery.sizeOf(context);
    List<LearningProblemDocumentExportPreset> presets = initialPresets;
    bool isWorking = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        Future<void> reloadPresets(StateSetter setModalState) async {
          setModalState(() {
            isWorking = true;
          });
          try {
            final refreshed = await _service.listExportPresets(
              academyId: academyId,
              limit: 300,
            );
            setModalState(() {
              presets = refreshed;
            });
          } catch (e) {
            _showSnack('프리셋 새로고침 실패: $e');
          } finally {
            setModalState(() {
              isWorking = false;
            });
          }
        }

        int readInt(dynamic value) {
          if (value is int) return value;
          if (value is num) return value.toInt();
          return int.tryParse('${value ?? ''}') ?? 0;
        }

        Future<void> runLegacyCloneCleanup(StateSetter setModalState) async {
          setModalState(() {
            isWorking = true;
          });
          Map<String, dynamic> dryRunResult;
          try {
            dryRunResult = await _service.cleanupLegacySavedSettingsClones(
              academyId: academyId,
              dryRun: true,
              limit: 2000,
            );
          } catch (e) {
            _showSnack('레거시 정리(미리보기) 실패: $e');
            setModalState(() {
              isWorking = false;
            });
            return;
          }

          final legacyCount = readInt(dryRunResult['legacyDocumentCount']);
          if (legacyCount <= 0) {
            _showSnack('정리할 레거시 저장 문서가 없습니다.');
            setModalState(() {
              isWorking = false;
            });
            return;
          }
          if (!mounted) return;
          if (!dialogContext.mounted) return;

          final confirmed = await showDialog<bool>(
            context: dialogContext,
            builder: (ctx) {
              return AlertDialog(
                backgroundColor: const Color(0xFF0F171B),
                title: const Text(
                  '레거시 저장문서 정리',
                  style: TextStyle(color: _rsTextPrimary),
                ),
                content: Text(
                  '레거시 복제 문서 $legacyCount개가 감지되었습니다.\n'
                  '참조형 전환 이후에는 불필요하므로 삭제할까요?',
                  style: const TextStyle(color: _rsTextMuted, height: 1.35),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('취소'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF6C2B2B),
                    ),
                    child: const Text('삭제 실행'),
                  ),
                ],
              );
            },
          );
          if (confirmed != true) {
            setModalState(() {
              isWorking = false;
            });
            return;
          }

          try {
            final result = await _service.cleanupLegacySavedSettingsClones(
              academyId: academyId,
              dryRun: false,
              limit: 2000,
            );
            final deletedDocs = readInt(result['deletedDocumentCount']);
            final deletedPresets = readInt(result['deletedPresetCount']);
            _showSnack(
              '레거시 정리 완료: 문서 $deletedDocs개 · 프리셋 $deletedPresets개',
            );
            final refreshed = await _service.listExportPresets(
              academyId: academyId,
              limit: 300,
            );
            if (!mounted) return;
            setModalState(() {
              presets = refreshed;
            });
          } catch (e) {
            _showSnack('레거시 정리 실패: $e');
          } finally {
            setModalState(() {
              isWorking = false;
            });
          }
        }

        Future<void> applyPreset(
          LearningProblemDocumentExportPreset preset,
        ) async {
          final presetSettings =
              LearningProblemExportSettings.fromPresetRenderConfig(
            base: _exportSettings,
            renderConfig: preset.renderConfig,
          );
          final modeMap = <String, String>{};
          final presetUidSet = preset.selectedQuestionUids
              .map((uid) => uid.trim())
              .where((uid) => uid.isNotEmpty)
              .toSet();
          final matchedSelectedIds = <String>{};
          for (final question in _questions) {
            final rawMode =
                preset.questionModeByQuestionUid[question.stableQuestionKey] ??
                    preset.questionModeByQuestionUid[question.id];
            if (rawMode == null || rawMode.trim().isEmpty) continue;
            modeMap[question.id] = normalizeQuestionModeSelection(
              question,
              rawMode,
              fallbackMode: kLearningQuestionModeOriginal,
            );
          }
          if (presetUidSet.isNotEmpty) {
            for (final question in _questions) {
              final key = question.stableQuestionKey.trim();
              if (key.isEmpty) continue;
              if (presetUidSet.contains(key)) {
                matchedSelectedIds.add(question.id);
              }
            }
          }
          if (!mounted) return;
          setState(() {
            _exportSettings = presetSettings;
            _selectedQuestionModes
              ..clear()
              ..addAll(modeMap);
            if (presetUidSet.isNotEmpty) {
              _selectedQuestionIds
                ..clear()
                ..addAll(matchedSelectedIds);
            }
          });
          if (Navigator.of(dialogContext).canPop()) {
            Navigator.of(dialogContext).pop();
          }
          if (presetUidSet.isNotEmpty) {
            _showSnack(
              '프리셋 적용: ${preset.displayName} (선택 ${matchedSelectedIds.length}/${presetUidSet.length}문항)',
            );
          } else {
            _showSnack('프리셋 적용: ${preset.displayName}');
          }
        }

        Future<void> renamePreset(
          LearningProblemDocumentExportPreset preset,
          StateSetter setModalState,
        ) async {
          final controller = TextEditingController(text: preset.displayName);
          final nextName = await showDialog<String>(
            context: dialogContext,
            builder: (ctx) {
              return AlertDialog(
                backgroundColor: const Color(0xFF0F171B),
                title: const Text(
                  '프리셋 이름 수정',
                  style: TextStyle(color: _rsTextPrimary),
                ),
                content: TextField(
                  controller: controller,
                  autofocus: true,
                  style: const TextStyle(color: _rsTextPrimary),
                  decoration: const InputDecoration(
                    hintText: '프리셋 이름을 입력하세요',
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('취소'),
                  ),
                  FilledButton(
                    onPressed: () =>
                        Navigator.of(ctx).pop(controller.text.trim()),
                    child: const Text('저장'),
                  ),
                ],
              );
            },
          );
          controller.dispose();
          final normalized =
              (nextName ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
          if (normalized.isEmpty) return;
          setModalState(() {
            isWorking = true;
          });
          try {
            final renamed = await _service.renameExportPreset(
              academyId: academyId,
              presetId: preset.id,
              displayName: normalized,
            );
            if (renamed != null) {
              final next = presets
                  .map((item) => item.id == preset.id ? renamed : item)
                  .toList(growable: false);
              setModalState(() {
                presets = next;
              });
            } else {
              await reloadPresets(setModalState);
            }
          } catch (e) {
            _showSnack('프리셋 이름 수정 실패: $e');
          } finally {
            setModalState(() {
              isWorking = false;
            });
          }
        }

        Future<void> deletePreset(
          LearningProblemDocumentExportPreset preset,
          StateSetter setModalState,
        ) async {
          final confirmed = await showDialog<bool>(
            context: dialogContext,
            builder: (ctx) {
              return AlertDialog(
                backgroundColor: const Color(0xFF0F171B),
                title: const Text(
                  '프리셋 삭제',
                  style: TextStyle(color: _rsTextPrimary),
                ),
                content: Text(
                  '`${preset.displayName}` 프리셋을 삭제할까요?\n(원본/저장 문서는 유지됩니다.)',
                  style: const TextStyle(color: _rsTextMuted, height: 1.35),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('취소'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF6C2B2B),
                    ),
                    child: const Text('삭제'),
                  ),
                ],
              );
            },
          );
          if (confirmed != true) return;
          setModalState(() {
            isWorking = true;
          });
          try {
            await _service.deleteExportPreset(
              academyId: academyId,
              presetId: preset.id,
            );
            setModalState(() {
              presets = presets
                  .where((item) => item.id != preset.id)
                  .toList(growable: false);
            });
            _showSnack('프리셋 삭제 완료');
          } catch (e) {
            _showSnack('프리셋 삭제 실패: $e');
          } finally {
            setModalState(() {
              isWorking = false;
            });
          }
        }

        Future<void> linkPresetToNaesinCell(
          LearningProblemDocumentExportPreset preset,
          StateSetter setModalState,
        ) async {
          final now = DateTime.now();
          final currentLinkKey =
              '${preset.renderConfig[_kNaesinLinkConfigKey] ?? preset.naesinLinkKey}'
                  .trim();
          final existing = _parseNaesinLinkKey(currentLinkKey);
          final gradeCourse = _deriveNaesinDefaultGradeCourse();
          final levelKey = _selectedSchoolLevel.trim() == '고' ? '고' : '중';
          final gradeOptions = _naesinGradeOptionsForLevel(levelKey);
          if (gradeOptions.isEmpty) {
            _showSnack('내신 연결을 위한 학년 옵션을 불러오지 못했습니다.');
            return;
          }
          var selectedGradeKey = existing?.gradeKey ?? gradeCourse.gradeKey;
          if (!gradeOptions.any((e) => e.key == selectedGradeKey)) {
            selectedGradeKey = gradeOptions.first.key;
          }
          var selectedCourseKey = existing?.courseKey ?? gradeCourse.courseKey;
          var selectedExamTerm =
              existing?.examTerm ?? _defaultNaesinExamTermByDate(now);
          if (!_kNaesinLinkExamTerms.contains(selectedExamTerm)) {
            selectedExamTerm = _kNaesinLinkExamTerms.first;
          }
          final fallbackSchool = _fallbackNaesinSchoolFromSelectedDocument();
          var selectedSchool = existing?.school ?? fallbackSchool;
          if (!NaesinExamContext.middleSchools.contains(selectedSchool)) {
            selectedSchool = NaesinExamContext.middleSchools.first;
          }
          var selectedYear = existing?.year ?? _defaultNaesinYearByDate(now);
          if (!NaesinExamContext.linkYears.contains(selectedYear)) {
            selectedYear = NaesinExamContext.linkYears.last;
          }

          final nextLinkKey = await showDialog<String>(
            context: dialogContext,
            builder: (ctx) {
              return StatefulBuilder(
                builder: (context, setLinkState) {
                  const fieldTextStyle = TextStyle(
                    color: _rsTextPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  );
                  InputDecoration fieldDecoration(String label) {
                    return InputDecoration(
                      labelText: label,
                      labelStyle: const TextStyle(
                        color: _rsTextMuted,
                        fontSize: 12.4,
                        fontWeight: FontWeight.w700,
                      ),
                      filled: true,
                      fillColor: const Color(0xFF141D22),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: _rsBorder),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(
                          color: Color(0xFF3E8A7A),
                          width: 1.2,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 10,
                      ),
                    );
                  }

                  final courseOptions =
                      _naesinCourseOptionsForGrade(selectedGradeKey);
                  if (!courseOptions.any((e) => e.key == selectedCourseKey)) {
                    selectedCourseKey = courseOptions.first.key;
                  }
                  return AlertDialog(
                    backgroundColor: _rsBg,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: const BorderSide(color: _rsBorder),
                    ),
                    title: const Text(
                      '내신 셀 연결',
                      style: TextStyle(
                        color: _rsTextPrimary,
                        fontWeight: FontWeight.w800,
                        fontSize: 17,
                      ),
                    ),
                    content: SizedBox(
                      width: 430,
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              '프리셋과 연결할 내신 셀을 선택하세요.',
                              style: TextStyle(
                                color: _rsTextMuted,
                                fontSize: 12.2,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: DropdownButtonFormField<String>(
                                    value: selectedGradeKey,
                                    decoration: fieldDecoration('학년'),
                                    dropdownColor: const Color(0xFF141D22),
                                    style: fieldTextStyle,
                                    iconEnabledColor: _rsTextMuted,
                                    items: [
                                      for (final option in gradeOptions)
                                        DropdownMenuItem<String>(
                                          value: option.key,
                                          child: Text(
                                            option.label,
                                            style: fieldTextStyle,
                                          ),
                                        ),
                                    ],
                                    onChanged: (value) {
                                      if (value == null || value.isEmpty)
                                        return;
                                      setLinkState(() {
                                        selectedGradeKey = value;
                                      });
                                    },
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: DropdownButtonFormField<String>(
                                    value: selectedCourseKey,
                                    decoration: fieldDecoration('과정'),
                                    dropdownColor: const Color(0xFF141D22),
                                    style: fieldTextStyle,
                                    iconEnabledColor: _rsTextMuted,
                                    items: [
                                      for (final option in courseOptions)
                                        DropdownMenuItem<String>(
                                          value: option.key,
                                          child: Text(
                                            option.label,
                                            style: fieldTextStyle,
                                          ),
                                        ),
                                    ],
                                    onChanged: (value) {
                                      if (value == null || value.isEmpty)
                                        return;
                                      setLinkState(() {
                                        selectedCourseKey = value;
                                      });
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: DropdownButtonFormField<String>(
                                    value: selectedExamTerm,
                                    decoration: fieldDecoration('시험 구분'),
                                    dropdownColor: const Color(0xFF141D22),
                                    style: fieldTextStyle,
                                    iconEnabledColor: _rsTextMuted,
                                    items: [
                                      for (final option
                                          in _kNaesinLinkExamTerms)
                                        DropdownMenuItem<String>(
                                          value: option,
                                          child: Text(
                                            option,
                                            style: fieldTextStyle,
                                          ),
                                        ),
                                    ],
                                    onChanged: (value) {
                                      if (value == null || value.isEmpty)
                                        return;
                                      setLinkState(() {
                                        selectedExamTerm = value;
                                      });
                                    },
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: DropdownButtonFormField<int>(
                                    value: selectedYear,
                                    decoration: fieldDecoration('연도'),
                                    dropdownColor: const Color(0xFF141D22),
                                    style: fieldTextStyle,
                                    iconEnabledColor: _rsTextMuted,
                                    items: [
                                      for (final option
                                          in NaesinExamContext.linkYears)
                                        DropdownMenuItem<int>(
                                          value: option,
                                          child: Text(
                                            '$option',
                                            style: fieldTextStyle,
                                          ),
                                        ),
                                    ],
                                    onChanged: (value) {
                                      if (value == null) return;
                                      setLinkState(() {
                                        selectedYear = value;
                                      });
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<String>(
                              value: selectedSchool,
                              decoration: fieldDecoration('학교'),
                              dropdownColor: const Color(0xFF141D22),
                              style: fieldTextStyle,
                              iconEnabledColor: _rsTextMuted,
                              items: [
                                for (final option
                                    in NaesinExamContext.middleSchools)
                                  DropdownMenuItem<String>(
                                    value: option,
                                    child: Text(
                                      option,
                                      style: fieldTextStyle,
                                    ),
                                  ),
                              ],
                              onChanged: (value) {
                                if (value == null || value.isEmpty) return;
                                setLinkState(() {
                                  selectedSchool = value;
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    actions: [
                      if (currentLinkKey.isNotEmpty)
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(''),
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFFD38E8E),
                          ),
                          child: const Text('연결 해제'),
                        ),
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        style: TextButton.styleFrom(
                          foregroundColor: _rsTextMuted,
                        ),
                        child: const Text('취소'),
                      ),
                      FilledButton(
                        onPressed: () {
                          Navigator.of(ctx).pop(
                            _buildNaesinLinkKey(
                              gradeKey: selectedGradeKey,
                              courseKey: selectedCourseKey,
                              examTerm: selectedExamTerm,
                              school: selectedSchool,
                              year: selectedYear,
                            ),
                          );
                        },
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF2E7366),
                          foregroundColor: _rsTextPrimary,
                        ),
                        child: const Text('저장'),
                      ),
                    ],
                  );
                },
              );
            },
          );
          if (nextLinkKey == null) return;
          setModalState(() {
            isWorking = true;
          });
          try {
            final updated = await _service.updateExportPresetNaesinLink(
              academyId: academyId,
              presetId: preset.id,
              naesinLinkKey: nextLinkKey.isEmpty ? null : nextLinkKey,
            );
            if (updated != null) {
              final next = presets
                  .map((item) => item.id == preset.id ? updated : item)
                  .toList(growable: false);
              setModalState(() {
                presets = next;
              });
            } else {
              await reloadPresets(setModalState);
            }
            _showSnack(nextLinkKey.isEmpty ? '내신 연결 해제 완료' : '내신 연결 저장 완료');
          } catch (e) {
            _showSnack('내신 연결 저장 실패: $e');
          } finally {
            setModalState(() {
              isWorking = false;
            });
          }
        }

        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF0B1112),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              title: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '저장된 프리셋',
                      style: TextStyle(
                        color: _rsTextPrimary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '레거시 정리',
                    onPressed: isWorking
                        ? null
                        : () => runLegacyCloneCleanup(setModalState),
                    icon: const Icon(
                      Icons.cleaning_services_outlined,
                      color: _rsTextMuted,
                    ),
                  ),
                  IconButton(
                    tooltip: '새로고침',
                    onPressed:
                        isWorking ? null : () => reloadPresets(setModalState),
                    icon: const Icon(Icons.refresh, color: _rsTextMuted),
                  ),
                ],
              ),
              content: SizedBox(
                width: math.min(size.width * 0.75, 860.0),
                height: math.min(size.height * 0.7, 560.0),
                child: presets.isEmpty
                    ? const Center(
                        child: Text(
                          '저장된 프리셋이 없습니다.',
                          style: TextStyle(
                            color: _rsTextMuted,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: presets.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final preset = presets[index];
                          final profile = preset.templateProfile.toUpperCase();
                          final paper = preset.paperSize.trim();
                          final rawNaesinLinkKey =
                              '${preset.renderConfig[_kNaesinLinkConfigKey] ?? preset.naesinLinkKey}'
                                  .trim();
                          final naesinLinkLabel =
                              _naesinLinkSummaryLabel(rawNaesinLinkKey);
                          final metaLine = [
                            if (profile.isNotEmpty) profile,
                            if (paper.isNotEmpty) paper,
                            '${preset.selectedQuestionCount}문항',
                            _formatDateTimeShort(preset.createdAt),
                          ].join(' · ');
                          return Container(
                            padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0F171B),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: _rsBorder),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  preset.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: _rsTextPrimary,
                                    fontSize: 13.2,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  metaLine,
                                  style: const TextStyle(
                                    color: _rsTextMuted,
                                    fontSize: 11.8,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (naesinLinkLabel.isNotEmpty) ...[
                                  const SizedBox(height: 3),
                                  Text(
                                    '내신 연결: $naesinLinkLabel',
                                    style: const TextStyle(
                                      color: Color(0xFFAFC2D6),
                                      fontSize: 11.4,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    TextButton.icon(
                                      onPressed: isWorking
                                          ? null
                                          : () => applyPreset(preset),
                                      icon: const Icon(Icons.playlist_add_check,
                                          size: 16),
                                      label: const Text('적용'),
                                    ),
                                    const SizedBox(width: 4),
                                    TextButton.icon(
                                      onPressed: isWorking
                                          ? null
                                          : () => linkPresetToNaesinCell(
                                              preset, setModalState),
                                      icon: const Icon(
                                        Icons.link_outlined,
                                        size: 16,
                                      ),
                                      label: const Text('내신 연결'),
                                    ),
                                    const SizedBox(width: 4),
                                    IconButton(
                                      tooltip: '이름 수정',
                                      onPressed: isWorking
                                          ? null
                                          : () => renamePreset(
                                              preset, setModalState),
                                      icon: const Icon(Icons.edit_outlined,
                                          size: 18),
                                      color: _rsTextMuted,
                                    ),
                                    IconButton(
                                      tooltip: '삭제',
                                      onPressed: isWorking
                                          ? null
                                          : () => deletePreset(
                                              preset, setModalState),
                                      icon: const Icon(Icons.delete_outline,
                                          size: 18),
                                      color: const Color(0xFFD38E8E),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
              actions: [
                TextButton(
                  onPressed: isWorking
                      ? null
                      : () => Navigator.of(dialogContext).pop(),
                  child: const Text(
                    '닫기',
                    style: TextStyle(color: _rsTextMuted),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final busy = _isInitializing || _isLoadingQuestions || _isLoadingSchools;
    final exportBusy = _isExporting || _isSavingExportLocally;
    return Container(
      color: _rsBg,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 13,
                  child: ProblemBankFilterBar(
                    selectedCurriculumCode: _selectedCurriculumCode,
                    curriculumLabels: _curriculumLabels,
                    onCurriculumChanged: _onCurriculumChanged,
                    selectedLevel: _selectedSchoolLevel,
                    levelOptions: _levelOptions,
                    onLevelChanged: _onSchoolLevelChanged,
                    selectedCourse: _selectedDetailedCourse,
                    courseOptions: _courseOptions,
                    onCourseChanged: _onDetailedCourseChanged,
                    selectedSourceTypeCode: _selectedSourceTypeCode,
                    sourceTypeLabels: _sourceTypeLabels,
                    onSourceTypeChanged: _onSourceTypeChanged,
                    isBusy: busy || exportBusy,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 12,
                  child: ProblemBankExportOptionsPanel(
                    settings: _exportSettings,
                    selectedCount: _selectedQuestionIds.length,
                    isBusy: _isExporting,
                    isSavingLocally: _isSavingExportLocally,
                    activeJob: _activeExportJob,
                    onPresetPressed: _openExportPresetManagerDialog,
                    onTemplateChanged: (value) {
                      setState(() {
                        if (value == '모의고사형' || value == '수능형') {
                          _exportSettings = _exportSettings.copyWith(
                            templateLabel: value,
                            paperLabel: 'B4',
                            layoutColumnLabel: '2단',
                            maxQuestionsPerPageLabel: '4',
                          );
                        } else {
                          _exportSettings = _exportSettings.copyWith(
                            templateLabel: value,
                          );
                        }
                      });
                    },
                    onPaperChanged: (value) {
                      setState(() {
                        _exportSettings = _exportSettings.copyWith(
                          paperLabel: value,
                        );
                      });
                    },
                    onQuestionModeChanged: (value) {
                      setState(() {
                        _exportSettings = _exportSettings.copyWith(
                          questionModeLabel: value,
                        );
                      });
                    },
                    onLayoutColumnsChanged: _setExportLayoutColumns,
                    onMaxQuestionsPerPageChanged: (value) {
                      setState(() {
                        _exportSettings = _exportSettings.copyWith(
                          maxQuestionsPerPageLabel: value,
                        );
                      });
                    },
                    onFontFamilyChanged: (value) {
                      setState(() {
                        _exportSettings = _exportSettings.copyWith(
                          fontFamilyLabel: value,
                        );
                      });
                    },
                    onFontSizeChanged: (value) {
                      setState(() {
                        _exportSettings = _exportSettings.copyWith(
                          fontSizeLabel: value,
                        );
                      });
                    },
                    onIncludeAnswerSheetChanged: (value) {
                      setState(() {
                        _exportSettings = _exportSettings.copyWith(
                          includeAnswerSheet: value,
                        );
                      });
                    },
                    onIncludeExplanationChanged: (value) {
                      setState(() {
                        _exportSettings = _exportSettings.copyWith(
                          includeExplanation: value,
                        );
                      });
                    },
                    onPageMarginChanged: (value) {
                      setState(() {
                        _exportSettings = _exportSettings.copyWith(
                          layoutTuning: _exportSettings.layoutTuning.copyWith(
                            pageMargin: value,
                          ),
                        );
                      });
                    },
                    onColumnGapChanged: (value) {
                      setState(() {
                        _exportSettings = _exportSettings.copyWith(
                          layoutTuning: _exportSettings.layoutTuning.copyWith(
                            columnGap: value,
                          ),
                        );
                      });
                    },
                    onQuestionGapChanged: (value) {
                      setState(() {
                        _exportSettings = _exportSettings.copyWith(
                          layoutTuning: _exportSettings.layoutTuning.copyWith(
                            questionGap: value,
                          ),
                        );
                      });
                    },
                    onNumberLaneWidthChanged: (value) {
                      setState(() {
                        _exportSettings = _exportSettings.copyWith(
                          layoutTuning: _exportSettings.layoutTuning.copyWith(
                            numberLaneWidth: value,
                          ),
                        );
                      });
                    },
                    onNumberGapChanged: (value) {
                      setState(() {
                        _exportSettings = _exportSettings.copyWith(
                          layoutTuning: _exportSettings.layoutTuning.copyWith(
                            numberGap: value,
                          ),
                        );
                      });
                    },
                    onHangingIndentChanged: (value) {
                      setState(() {
                        _exportSettings = _exportSettings.copyWith(
                          layoutTuning: _exportSettings.layoutTuning.copyWith(
                            hangingIndent: value,
                          ),
                        );
                      });
                    },
                    onLineHeightChanged: (value) {
                      setState(() {
                        _exportSettings = _exportSettings.copyWith(
                          layoutTuning: _exportSettings.layoutTuning.copyWith(
                            lineHeight: value,
                          ),
                        );
                      });
                    },
                    onChoiceSpacingChanged: (value) {
                      setState(() {
                        _exportSettings = _exportSettings.copyWith(
                          layoutTuning: _exportSettings.layoutTuning.copyWith(
                            choiceSpacing: value,
                          ),
                        );
                      });
                    },
                    onTargetDpiChanged: (value) {
                      setState(() {
                        _exportSettings = _exportSettings.copyWith(
                          figureQuality: _exportSettings.figureQuality.copyWith(
                            targetDpi: value,
                            minDpi: math.min(
                              _exportSettings.figureQuality.minDpi,
                              value,
                            ),
                          ),
                        );
                      });
                    },
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Row(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
                        child: SizedBox(
                          width: 260,
                          child: ProblemBankSchoolSheet(
                            sidebarRevision: _sidebarRevision,
                            selectedSourceTypeCode: _selectedSourceTypeCode,
                            documents: _sidebarDocuments,
                            selectedDocumentId: _selectedDocumentId,
                            onDocumentSelected: _onSidebarDocumentSelected,
                            isLoading: _isLoadingSchools,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 0, 12, 0),
                          child: _buildQuestionPanel(),
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 16,
                  child: ProblemBankBottomFabBar(
                    selectedCount: _selectedQuestionIds.length,
                    isBusy: exportBusy,
                    onSelectAll: _selectAllQuestions,
                    onClearSelection: _clearQuestionSelection,
                    onPreview: _openExportLayoutPreviewDialog,
                    onCreatePlaceholder: _showCreatePlaceholder,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuestionPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 12, 6, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '문항 ${_questions.length}개 · 선택 ${_selectedQuestionIds.length}개',
                  style: const TextStyle(
                    fontSize: 14,
                    color: _rsTextMuted,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (_isLoadingQuestions || _isInitializing)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ),
        Expanded(
          child: _buildQuestionBody(),
        ),
      ],
    );
  }

  Widget _buildQuestionBody() {
    if (_isInitializing || _isLoadingQuestions) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (_questions.isEmpty) {
      return const Center(
        child: Text(
          '조건에 맞는 문항이 없습니다.\n필터나 학교를 변경해 주세요.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _rsTextMuted,
            fontWeight: FontWeight.w700,
            height: 1.5,
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 8.0;
        // 그리드: 기본 5열, 카드당 최소 너비 미만이면 열 수만 줄임. 높이 고정(워커와 무관, UI 전용).
        const defaultGridColumns = 5;
        const minCardWidth = 252.0;
        const cardHeight = 432.0;
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : (minCardWidth * defaultGridColumns +
                (defaultGridColumns - 1) * spacing);
        var cols = defaultGridColumns;
        while (cols > 1) {
          final trialWidth =
              (availableWidth - (cols - 1) * spacing) / cols;
          if (trialWidth >= minCardWidth) break;
          cols -= 1;
        }
        final cardWidth =
            (availableWidth - (cols - 1) * spacing) / cols;
        return Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: availableWidth,
            child: AnimatedReorderableGrid<LearningProblemQuestion>(
              items: _questions,
              itemId: (q) => q.id,
              cardWidth: cardWidth,
              cardHeight: cardHeight,
              spacing: spacing,
              columns: cols,
              scrollController: _questionGridScrollCtrl,
              dragAnchorStrategy: pointerDragAnchorStrategy,
              scrollBottomPadding: 120,
              itemBuilder: (context, question) {
                final selected = _selectedQuestionIds.contains(question.id);
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () =>
                      _toggleQuestionSelection(question.id, !selected),
                  child: ProblemBankQuestionCard(
                    question: question,
                    selected: selected,
                    selectedMode: _selectedModeOfQuestion(question),
                    figureUrlsByPath:
                        _questionFigureUrlsByPath[question.id] ??
                            const <String, String>{},
                    previewImageUrl: _questionPreviewUrls[question.id],
                    previewStatus: _questionPreviewStatus[question.id] ?? '',
                    previewErrorMessage:
                        _questionPreviewError[question.id] ?? '',
                    onRetryPreview: () => _retryQuestionPreview(question.id),
                    onSelectedChanged: (next) {
                      _toggleQuestionSelection(question.id, next);
                    },
                    onModeSelected: (mode) {
                      _setQuestionModeSelection(question.id, mode);
                    },
                  ),
                );
              },
              feedbackBuilder: (context, question) {
                final selected = _selectedQuestionIds.contains(question.id);
                return ProblemBankQuestionCard(
                  question: question,
                  selected: selected,
                  selectedMode: _selectedModeOfQuestion(question),
                  figureUrlsByPath: _questionFigureUrlsByPath[question.id] ??
                      const <String, String>{},
                  previewImageUrl: _questionPreviewUrls[question.id],
                  previewStatus: _questionPreviewStatus[question.id] ?? '',
                  previewErrorMessage:
                      _questionPreviewError[question.id] ?? '',
                  onRetryPreview: () => _retryQuestionPreview(question.id),
                  onSelectedChanged: (_) {},
                  onModeSelected: null,
                );
              },
              onReorder: (question, targetIndex) {
                setState(() {
                  _commitQuestionReorder(
                    id: question.id,
                    targetIndex: targetIndex,
                  );
                });
                _requestQuestionOrderSave();
              },
            ),
          ),
        );
      },
    );
  }
}

class _NaesinLinkSelection {
  const _NaesinLinkSelection({
    required this.gradeKey,
    required this.courseKey,
    required this.examTerm,
    required this.school,
    required this.year,
  });

  final String gradeKey;
  final String courseKey;
  final String examTerm;
  final String school;
  final int year;
}

class _NaesinGradeOption {
  const _NaesinGradeOption({required this.key, required this.label});

  final String key;
  final String label;
}

class _NaesinCourseOption {
  const _NaesinCourseOption({required this.key, required this.label});

  final String key;
  final String label;
}

class _QuestionOrderSaveRequest {
  const _QuestionOrderSaveRequest({
    required this.academyId,
    required this.scopeKey,
    required this.orderedQuestionIds,
  });

  final String academyId;
  final String scopeKey;
  final List<String> orderedQuestionIds;
}
