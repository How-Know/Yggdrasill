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

  /// 장바구니(선택만 보기) 활성 시 그리드에 선택된 문항만 표시.
  bool _showOnlySelectedQuestions = false;
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
  String _previewMathEngine = 'xelatex';
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
        if (_showOnlySelectedQuestions) {
          if (_selectedQuestionIds.isEmpty ||
              !_questions.any((q) => _selectedQuestionIds.contains(q.id))) {
            _showOnlySelectedQuestions = false;
          }
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
      _markAllPreviewsFailed(
        questions,
        '게이트웨이 연결이 없어 서버 미리보기를 불러올 수 없습니다.',
      );
      return;
    }

    if (mounted) {
      setState(() {
        for (final q in questions) {
          _questionPreviewStatus = {
            ..._questionPreviewStatus,
            q.id: 'rendering',
          };
        }
      });
    }

    final questionIds = questions
        .map((q) => q.questionUid.trim().isNotEmpty
            ? q.questionUid.trim()
            : q.id.trim())
        .where((id) => id.isNotEmpty)
        .toList();
    if (questionIds.isEmpty) return;

    final documentId = _selectedDocumentId?.trim().isNotEmpty == true
        ? _selectedDocumentId!.trim()
        : questions.first.documentId.trim();

    try {
      final urlMap = await _service.batchRenderThumbnails(
        academyId: _academyId!,
        questionIds: questionIds,
        documentId: documentId,
        templateProfile: _exportSettings.templateProfile,
        paperSize: _exportSettings.paperLabel,
        questionModeByQuestionUid: _selectedModeMapForQuestions(questions),
      );
      if (!mounted) return;

      final uidToId = <String, String>{};
      for (final q in questions) {
        final id = q.id.trim();
        final uid = q.questionUid.trim();
        if (id.isNotEmpty) uidToId[id] = id;
        if (uid.isNotEmpty && uid != id) uidToId[uid] = id;
      }

      final nextUrls = <String, String>{..._questionPreviewUrls};
      final nextStatus = <String, String>{..._questionPreviewStatus};
      final nextError = <String, String>{..._questionPreviewError};

      for (final entry in urlMap.entries) {
        final qid = uidToId[entry.key.trim()] ?? entry.key.trim();
        if (qid.isEmpty) continue;
        nextUrls[qid] = entry.value;
        nextStatus[qid] = 'completed';
        nextError.remove(qid);
      }

      for (final q in questions) {
        final id = q.id.trim();
        if (id.isNotEmpty && !nextUrls.containsKey(id)) {
          nextStatus[id] = 'failed';
          nextError[id] = '서버 미리보기 응답에서 누락되었습니다.';
        }
      }

      setState(() {
        _questionPreviewUrls = nextUrls;
        _questionPreviewStatus = nextStatus;
        _questionPreviewError = nextError;
        _pendingPreviewQuestionIds = <String>{};
      });
    } catch (err) {
      if (!mounted) return;
      _markAllPreviewsFailed(questions, err.toString());
    }
  }

  void _markAllPreviewsFailed(
    List<LearningProblemQuestion> questions,
    String message,
  ) {
    if (!mounted) return;
    final safeMsg =
        message.trim().isNotEmpty ? message.trim() : '서버 미리보기에 실패했습니다.';
    setState(() {
      final nextStatus = <String, String>{..._questionPreviewStatus};
      final nextError = <String, String>{..._questionPreviewError};
      for (final q in questions) {
        final id = q.id.trim();
        if (id.isEmpty) continue;
        nextStatus[id] = 'failed';
        nextError[id] = safeMsg;
      }
      _questionPreviewStatus = nextStatus;
      _questionPreviewError = nextError;
      _pendingPreviewQuestionIds = <String>{};
    });
  }

  void _retryQuestionPreview(String questionId) {
    final target = _questions.where((q) => q.id == questionId).toList();
    if (target.isEmpty) return;
    unawaited(_fetchQuestionPreviews(target));
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
      if (_showOnlySelectedQuestions && _selectedQuestionIds.isEmpty) {
        _showOnlySelectedQuestions = false;
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
      if (_showOnlySelectedQuestions) {
        _showOnlySelectedQuestions = false;
      }
    });
  }

  void _onToggleShowOnlySelectedFilter() {
    if (_showOnlySelectedQuestions) {
      setState(() => _showOnlySelectedQuestions = false);
      return;
    }
    if (_selectedQuestionIds.isEmpty) {
      _showSnack('선택된 문항이 없습니다.');
      return;
    }
    setState(() => _showOnlySelectedQuestions = true);
  }

  List<LearningProblemQuestion> get _visibleQuestions {
    if (!_showOnlySelectedQuestions) return _questions;
    return _questions
        .where((q) => _selectedQuestionIds.contains(q.id))
        .toList(growable: false);
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
    final renderConfig = <String, dynamic>{
      ..._buildRenderConfigForSelection(
        selectedQuestions,
        settingsOverride: settings,
      ),
      ...renderConfigPatch,
    };
    final renderHash = buildLearningRenderHashFromConfig(renderConfig);
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

  Future<void> _openExportLayoutPreviewDialog({
    bool skipDocumentPresetPreload = false,
    String editingPresetId = '',
    String editingPresetName = '',
    // 프리셋 카드 탭 → 편집 모드로 들어올 때, 해당 프리셋의 renderConfig 를
    // 최초 렌더의 initialRenderPatch 로 사용해 페이지별 문항수/라벨/헤더/제목 등이
    // 다이얼로그 초기값으로 복원되도록 한다.
    LearningProblemDocumentExportPreset? explicitPreset,
  }) async {
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
        return v == 'mathjax-svg' ? 'mathjax-svg' : 'xelatex';
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
          // 새로고침/PDF 생성 경로에서는 서버의 auto 라벨 생성을 끈다.
          //   (최초 렌더에는 이 패치가 전달되지 않으므로 default auto-gen 동작 유지)
          'disableAutoLabels': request.disableAutoLabels,
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
      final isPresetEditFlow =
          explicitPreset != null || editingPresetId.trim().isNotEmpty;
      var initialRenderPatch = <String, dynamic>{
        'mathEngine': _previewMathEngine,
        // 프리셋 카드에서 들어온 편집 경로는 저장된 라벨을 그대로 복원해야 하므로
        // 최초 렌더부터 서버의 자동 라벨 생성을 막는다.
        if (isPresetEditFlow) 'disableAutoLabels': true,
      };

      // 1) 외부에서 명시적으로 넘겨준 preset (프리셋 카드 탭 경로) 을 우선 적용한다.
      // 2) 그렇지 않고 preload 를 건너뛰지 않을 때는, 선택된 단일 문서의 기본 저장 프리셋을 조회한다.
      LearningProblemDocumentExportPreset? presetToApply = explicitPreset;
      if (presetToApply == null &&
          !skipDocumentPresetPreload &&
          academyId != null &&
          academyId.isNotEmpty &&
          selectedDocumentIds.length == 1) {
        final documentId = selectedDocumentIds.first;
        try {
          presetToApply = await _service.getDocumentExportPreset(
            academyId: academyId,
            documentId: documentId,
          );
        } catch (e) {
          _showSnack('저장된 세팅 조회 실패: $e');
        }
      }
      if (presetToApply != null) {
        final preset = presetToApply;
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
          final rawMode =
              preset.questionModeByQuestionUid[question.stableQuestionKey] ??
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
            // explicitPreset 경로 (applyPresetAndOpenPreview) 는 이미 자체 setState 로
            //   모드 맵을 완전히 덮어썼으므로 그 상태를 그대로 존중한다.
            //   문서 기본 프리셋 preload 경로에서는 기존과 동일한 "사용자 선택 우선" 머지 적용.
            if (explicitPreset == null) {
              final userModes = Map<String, String>.of(_selectedQuestionModes);
              final merged = <String, String>{...presetModeMap};
              for (final entry in userModes.entries) {
                if (entry.value.trim().isNotEmpty) {
                  merged[entry.key] = entry.value;
                }
              }
              _selectedQuestionModes
                ..clear()
                ..addAll(merged);
            }
          });
        }
        final subjectTitle =
            '${preset.renderConfig['subjectTitleText'] ?? ''}'.trim();
        final titlePageTopText =
            '${preset.renderConfig['titlePageTopText'] ?? ''}'.trim();
        final timeLimitText =
            '${preset.renderConfig['timeLimitText'] ?? ''}'.trim();
        initialRenderPatch = <String, dynamic>{
          ...initialRenderPatch,
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
      final presetRenderConfig =
          presetToApply?.renderConfig ?? const <String, dynamic>{};
      dynamic initialPrimary(String key) {
        if (isPresetEditFlow) return presetRenderConfig[key];
        if (presetRenderConfig.containsKey(key)) {
          return presetRenderConfig[key];
        }
        return completed.resultSummary[key];
      }

      dynamic initialFallback(String key) {
        if (isPresetEditFlow) return null;
        if (presetRenderConfig.containsKey(key)) {
          return completed.resultSummary[key] ?? completed.options[key];
        }
        return completed.options[key];
      }

      final initialSubjectTitle =
          '${initialPrimary('subjectTitleText') ?? initialFallback('subjectTitleText') ?? '수학 영역'}'
              .trim();
      final initialTitlePageTopText =
          '${initialPrimary('titlePageTopText') ?? initialFallback('titlePageTopText') ?? kLearningDefaultTitlePageTopText}'
              .trim();
      final initialTimeLimitText =
          '${initialPrimary('timeLimitText') ?? initialFallback('timeLimitText') ?? _exportSettings.timeLimitText}'
              .trim();
      final initialMathEngine = normalizeMathEngineValue(
        initialPrimary('mathEngine') ??
            initialFallback('mathEngine') ??
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
          initialPrimary('includeAcademyLogo'),
          initialFallback('includeAcademyLogo'),
          _exportSettings.includeAcademyLogo,
        ),
        layoutColumns: _exportSettings.layoutColumnCount,
        maxQuestionsPerPage: _exportSettings.maxQuestionsPerPageCount,
        totalQuestionCount: selected.length,
        initialPageColumnQuestionCounts: readMapRows(
          initialPrimary('pageColumnQuestionCounts'),
          initialFallback('pageColumnQuestionCounts'),
        ),
        initialColumnLabelAnchors: readMapRows(
          initialPrimary('columnLabelAnchors'),
          initialFallback('columnLabelAnchors'),
        ),
        initialTitlePageIndices: readPositiveIntList(
          initialPrimary('titlePageIndices'),
          initialFallback('titlePageIndices'),
        ),
        initialTitlePageHeaders: readMapRows(
          initialPrimary('titlePageHeaders'),
          initialFallback('titlePageHeaders'),
        ),
        initialIncludeCoverPage: readBoolFlag(
          initialPrimary('includeCoverPage'),
          initialFallback('includeCoverPage'),
          false,
        ),
        initialIncludeAnswerSheet: readBoolFlag(
          initialPrimary('includeAnswerSheet'),
          initialFallback('includeAnswerSheet'),
          _exportSettings.includeAnswerSheet,
        ),
        initialIncludeExplanation: readBoolFlag(
          initialPrimary('includeExplanation'),
          initialFallback('includeExplanation'),
          _exportSettings.includeExplanation,
        ),
        initialIncludeQuestionScore: readBoolFlag(
          initialPrimary('includeQuestionScore'),
          initialFallback('includeQuestionScore'),
          _exportSettings.includeQuestionScore,
        ),
        initialMathEngine: initialMathEngine,
        initialQuestionScoreByQuestionId: readScoreMap(
          initialPrimary('questionScoreByQuestionUid'),
          initialFallback('questionScoreByQuestionUid') ??
              initialPrimary('questionScoreByQuestionId') ??
              initialFallback('questionScoreByQuestionId'),
        ),
        questionScoreEntries: scoreEntries,
        initialCoverPageTexts: readCoverPageTexts(
          initialPrimary('coverPageTexts'),
          initialFallback('coverPageTexts'),
        ),
        initialEditingPresetId: editingPresetId,
        initialEditingPresetName: editingPresetName,
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
          if (refreshedMathEngine !=
              normalizeMathEngineValue(request.mathEngine)) {
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
          final preservedNaesinLinkKey =
              '${presetToApply?.renderConfig[_kNaesinLinkConfigKey] ?? presetToApply?.naesinLinkKey ?? ''}'
                  .trim();
          if (preservedNaesinLinkKey.isNotEmpty) {
            renderConfig[_kNaesinLinkConfigKey] = preservedNaesinLinkKey;
          }
          final sourceDocumentId = selected.first.documentId.trim();
          if (sourceDocumentId.isEmpty) {
            _showSnack('원본 문서 정보를 찾지 못했습니다.');
            return;
          }
          try {
            final presetIdToUpdate = request.presetIdToUpdate.trim();
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
              presetId: presetIdToUpdate,
            );
            final savedPresetId =
                (saveResult.preset?.id ?? presetIdToUpdate).trim();
            if (savedPresetId.isNotEmpty) {
              await _service.overwriteExportPresetRenderConfig(
                academyId: academyId,
                presetId: savedPresetId,
                renderConfig: renderConfig,
              );
            }
            final count = saveResult.copiedQuestionCount;
            final effectiveCount =
                count > 0 ? count : orderedQuestionUids.length;
            _showSnack(
              presetIdToUpdate.isNotEmpty
                  ? '프리셋 업데이트 완료 ($effectiveCount문항)'
                  : '새 프리셋 저장 완료 ($effectiveCount문항)',
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

        String normalizeMathEngineValue(dynamic raw) {
          final v = '$raw'.trim().toLowerCase();
          return v == 'mathjax-svg' ? 'mathjax-svg' : 'xelatex';
        }

        Future<void> applyPresetAndOpenPreview(
          LearningProblemDocumentExportPreset preset,
          StateSetter setModalState,
        ) async {
          var effectivePreset = preset;
          try {
            final latest = await _service.getExportPresetById(
              academyId: academyId,
              presetId: preset.id,
            );
            if (latest != null) {
              effectivePreset = latest;
            }
          } catch (_) {
            // 목록 카드의 preset 으로 계속 진행한다.
          }
          final presetUids = effectivePreset.selectedQuestionUids
              .map((u) => u.trim())
              .where((u) => u.isNotEmpty)
              .toList(growable: false);
          if (presetUids.isEmpty) {
            _showSnack('프리셋에 저장된 문항이 없습니다.');
            return;
          }
          setModalState(() {
            isWorking = true;
          });
          // 1) 프리셋의 실제 문항을 서비스에서 uid 로 직접 로드한다.
          //    → 현재 사이드바 필터(교육과정/레벨/과정/출처)와 무관하게 가져올 수 있어
          //      프리셋이 다른 문서/필터에서 저장되었어도 정상 복원된다.
          List<LearningProblemQuestion> fetched;
          try {
            fetched = await _service.loadQuestionsByQuestionUids(
              academyId: academyId,
              questionUids: presetUids,
            );
          } catch (e) {
            if (mounted) {
              setModalState(() {
                isWorking = false;
              });
            }
            _showSnack('프리셋 문항 로드 실패: $e');
            return;
          }
          if (fetched.isEmpty) {
            if (mounted) {
              setModalState(() {
                isWorking = false;
              });
            }
            _showSnack('프리셋에 연결된 문항을 찾을 수 없습니다.');
            return;
          }
          // 2) 프리셋 저장 당시의 UID 순서 그대로 정렬.
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
          // 3) 프리셋 설정 / 출제형식 맵 구성.
          final presetSettings =
              LearningProblemExportSettings.fromPresetRenderConfig(
            base: _exportSettings,
            renderConfig: effectivePreset.renderConfig,
          );
          final presetMathEngine = normalizeMathEngineValue(
            effectivePreset.renderConfig['mathEngine'],
          );
          final modeMap = <String, String>{};
          for (final question in ordered) {
            final rawMode = effectivePreset
                    .questionModeByQuestionUid[question.stableQuestionKey] ??
                effectivePreset.questionModeByQuestionUid[question.id];
            if (rawMode == null || rawMode.trim().isEmpty) continue;
            modeMap[question.id] = normalizeQuestionModeSelection(
              question,
              rawMode,
              fallbackMode: kLearningQuestionModeOriginal,
            );
          }
          if (!mounted) return;
          setState(() {
            _questions = ordered;
            _selectedQuestionIds
              ..clear()
              ..addAll(ordered.map((q) => q.id));
            _selectedQuestionModes
              ..clear()
              ..addAll(modeMap);
            _exportSettings = presetSettings;
            _previewMathEngine = presetMathEngine;
            _showOnlySelectedQuestions = false;
            final srcDoc = effectivePreset.sourceDocumentId.trim();
            if (srcDoc.isNotEmpty) {
              _selectedDocumentId = srcDoc;
            }
            _questionFigureUrlsByPath = const <String, Map<String, String>>{};
            _questionPreviewUrls = const <String, String>{};
            _questionPreviewPdfUrls = const <String, String>{};
            _questionPreviewStatus = const <String, String>{};
            _questionPreviewError = const <String, String>{};
            _pendingPreviewQuestionIds = <String>{};
          });
          _previewArtifactPollTimer?.cancel();
          _previewArtifactPollTimer = null;
          unawaited(
            _prefetchFigureSignedUrls(
              ordered,
              loadVersion: ++_figureLoadVersion,
            ),
          );
          unawaited(_fetchQuestionPreviews(ordered));
          // 4) 프리셋 다이얼로그 닫고 서버 PDF 미리보기 열기.
          //    skipDocumentPresetPreload: 방금 명시적으로 적용한 프리셋이
          //    문서 "마지막 저장 프리셋" 에 덮어써지지 않도록 한다.
          if (Navigator.of(dialogContext).canPop()) {
            Navigator.of(dialogContext).pop();
          }
          _showSnack(
            '프리셋 적용: ${effectivePreset.displayName} (${ordered.length}문항)',
          );
          await _openExportLayoutPreviewDialog(
            // 문서 "기본 프리셋" 자동 로드는 건너뛰고,
            //   카드에서 선택한 preset 객체를 명시적으로 전달해
            //   페이지별 문항수/라벨/타이틀이 프리셋 그대로 복원되게 한다.
            skipDocumentPresetPreload: true,
            explicitPreset: effectivePreset,
            editingPresetId: effectivePreset.id,
            editingPresetName: effectivePreset.displayName,
          );
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
            final dialogWidth = math.min(size.width * 0.82, 900.0);
            final dialogHeight = math.min(size.height * 0.82, 680.0);
            // 가용 너비에 따라 1~3단 카드 그리드로 자동 전환 (학습앱 그리드 UX와 통일)
            final gridColumns = dialogWidth >= 820
                ? 3
                : dialogWidth >= 560
                    ? 2
                    : 1;
            return Dialog(
              backgroundColor: _rsBg,
              insetPadding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 32,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: const BorderSide(color: _rsBorder),
              ),
              child: SizedBox(
                width: dialogWidth,
                height: dialogHeight,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 10, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Text(
                            '저장된 프리셋',
                            style: TextStyle(
                              color: _rsTextPrimary,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${presets.length}개',
                            style: const TextStyle(
                              color: _rsTextMuted,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Spacer(),
                          if (isWorking)
                            const Padding(
                              padding: EdgeInsets.only(right: 6),
                              child: SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: _rsTextMuted,
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
                            onPressed: isWorking
                                ? null
                                : () => reloadPresets(setModalState),
                            icon: const Icon(
                              Icons.refresh,
                              color: _rsTextMuted,
                            ),
                          ),
                          IconButton(
                            tooltip: '닫기',
                            onPressed: isWorking
                                ? null
                                : () => Navigator.of(dialogContext).pop(),
                            icon: const Icon(
                              Icons.close,
                              color: _rsTextMuted,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: Text(
                          '카드를 누르면 해당 설정·문항으로 서버 PDF 미리보기를 엽니다.',
                          style: TextStyle(
                            color: _rsTextMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
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
                            : Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: GridView.builder(
                                  padding: const EdgeInsets.only(
                                    top: 2,
                                    bottom: 6,
                                  ),
                                  itemCount: presets.length,
                                  gridDelegate:
                                      SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: gridColumns,
                                    crossAxisSpacing: 10,
                                    mainAxisSpacing: 10,
                                    mainAxisExtent: 146,
                                  ),
                                  itemBuilder: (context, index) {
                                    final preset = presets[index];
                                    return _PresetCardTile(
                                      preset: preset,
                                      disabled: isWorking,
                                      naesinLinkLabel: _naesinLinkSummaryLabel(
                                        '${preset.renderConfig[_kNaesinLinkConfigKey] ?? preset.naesinLinkKey}'
                                            .trim(),
                                      ),
                                      createdAtLabel: _formatDateTimeShort(
                                        preset.createdAt,
                                      ),
                                      onTap: isWorking
                                          ? null
                                          : () => applyPresetAndOpenPreview(
                                                preset,
                                                setModalState,
                                              ),
                                      onLink: isWorking
                                          ? null
                                          : () => linkPresetToNaesinCell(
                                                preset,
                                                setModalState,
                                              ),
                                      onRename: isWorking
                                          ? null
                                          : () => renamePreset(
                                                preset,
                                                setModalState,
                                              ),
                                      onDelete: isWorking
                                          ? null
                                          : () => deletePreset(
                                                preset,
                                                setModalState,
                                              ),
                                    );
                                  },
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
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
                    showOnlySelectedActive: _showOnlySelectedQuestions,
                    isBusy: exportBusy,
                    onSelectAll: _selectAllQuestions,
                    onClearSelection: _clearQuestionSelection,
                    onToggleShowOnlySelected: _onToggleShowOnlySelectedFilter,
                    onPreview: _openExportLayoutPreviewDialog,
                    onCreatePlaceholder: _showCreatePlaceholder,
                    onPreset: _openExportPresetManagerDialog,
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
                  _showOnlySelectedQuestions
                      ? '선택 문항만 표시 · ${_visibleQuestions.length}개 (전체 ${_questions.length}개)'
                      : '문항 ${_questions.length}개 · 선택 ${_selectedQuestionIds.length}개',
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
    if (_showOnlySelectedQuestions && _visibleQuestions.isEmpty) {
      return const Center(
        child: Text(
          '표시할 선택 문항이 없습니다.\n아래 장바구니를 다시 눌러 전체 목록으로 돌아가 주세요.',
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
          final trialWidth = (availableWidth - (cols - 1) * spacing) / cols;
          if (trialWidth >= minCardWidth) break;
          cols -= 1;
        }
        final cardWidth = (availableWidth - (cols - 1) * spacing) / cols;
        return Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: availableWidth,
            child: AnimatedReorderableGrid<LearningProblemQuestion>(
              items: _visibleQuestions,
              itemId: (q) => q.id,
              cardWidth: cardWidth,
              cardHeight: cardHeight,
              spacing: spacing,
              columns: cols,
              scrollController: _questionGridScrollCtrl,
              dragAnchorStrategy: pointerDragAnchorStrategy,
              scrollBottomPadding: 120,
              enableReorder: !_showOnlySelectedQuestions,
              itemBuilder: (context, question) {
                final selected = _selectedQuestionIds.contains(question.id);
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _toggleQuestionSelection(question.id, !selected),
                  child: ProblemBankQuestionCard(
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
                  previewErrorMessage: _questionPreviewError[question.id] ?? '',
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

/// 저장된 프리셋 카드. 탭하면 onTap 으로 "프리셋 적용 + 서버 PDF 미리보기" 흐름을 연다.
class _PresetCardTile extends StatelessWidget {
  const _PresetCardTile({
    required this.preset,
    required this.disabled,
    required this.naesinLinkLabel,
    required this.createdAtLabel,
    required this.onTap,
    required this.onLink,
    required this.onRename,
    required this.onDelete,
  });

  static const _cardBg = Color(0xFF0F171B);
  static const _cardBgHover = Color(0xFF15222A);
  static const _border = Color(0xFF223131);
  static const _textPrimary = Color(0xFFEAF2F2);
  static const _textMuted = Color(0xFF9FB3B3);
  static const _naesin = Color(0xFFAFC2D6);
  static const _danger = Color(0xFFD38E8E);

  final LearningProblemDocumentExportPreset preset;
  final bool disabled;
  final String naesinLinkLabel;
  final String createdAtLabel;
  final VoidCallback? onTap;
  final VoidCallback? onLink;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final profile = preset.templateProfile.toUpperCase();
    final paper = preset.paperSize.trim();
    final metaLine = [
      if (profile.isNotEmpty) profile,
      if (paper.isNotEmpty) paper,
      '${preset.selectedQuestionCount}문항',
      if (createdAtLabel.isNotEmpty) createdAtLabel,
    ].join(' · ');

    return Opacity(
      opacity: disabled ? 0.55 : 1.0,
      child: Material(
        color: _cardBg,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          hoverColor: _cardBgHover,
          splashColor: const Color(0x3326524A),
          child: Ink(
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _border),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 6, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            preset.displayName,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: _textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              height: 1.2,
                            ),
                          ),
                        ),
                      ),
                      _CardIconButton(
                        tooltip: '내신 연결',
                        icon: Icons.link_outlined,
                        onPressed: onLink,
                        color: _textMuted,
                      ),
                      _CardIconButton(
                        tooltip: '이름 수정',
                        icon: Icons.edit_outlined,
                        onPressed: onRename,
                        color: _textMuted,
                      ),
                      _CardIconButton(
                        tooltip: '삭제',
                        icon: Icons.delete_outline,
                        onPressed: onDelete,
                        color: _danger,
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    metaLine,
                    style: const TextStyle(
                      color: _textMuted,
                      fontSize: 11.6,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (naesinLinkLabel.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.link, size: 12, color: _naesin),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            naesinLinkLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: _naesin,
                              fontSize: 11.4,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const Spacer(),
                  Row(
                    children: [
                      const Icon(
                        Icons.picture_as_pdf_outlined,
                        size: 13,
                        color: Color(0xFF7FB8A8),
                      ),
                      const SizedBox(width: 4),
                      const Text(
                        '탭하여 서버 PDF 미리보기',
                        style: TextStyle(
                          color: Color(0xFF7FB8A8),
                          fontSize: 11.4,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      const Icon(
                        Icons.arrow_forward,
                        size: 14,
                        color: _textMuted,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CardIconButton extends StatelessWidget {
  const _CardIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    required this.color,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      color: color,
      splashRadius: 16,
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
    );
  }
}
