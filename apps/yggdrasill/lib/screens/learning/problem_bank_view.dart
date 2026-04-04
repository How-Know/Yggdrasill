import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../../services/data_manager.dart';
import '../../services/learning_problem_bank_service.dart';
import '../../services/tenant_service.dart';
import '../../widgets/animated_reorderable_grid.dart';
import 'models/problem_bank_export_models.dart';
import 'widgets/problem_bank_bottom_fab_bar.dart';
import 'widgets/problem_bank_export_options_panel.dart';
import 'widgets/problem_bank_export_server_preview_dialog.dart';
import 'widgets/problem_bank_filter_bar.dart';
import 'widgets/problem_bank_manager_preview_paper.dart';
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

  final LearningProblemBankService _service = LearningProblemBankService();

  String? _academyId;
  bool _isInitializing = true;
  bool _isLoadingSchools = false;
  bool _isLoadingQuestions = false;
  bool _isExporting = false;
  bool _isSavingExportLocally = false;
  Timer? _pollTimer;

  String _selectedCurriculumCode = 'rev_2022';
  String _selectedSchoolLevel = '중';
  String _selectedDetailedCourse = '전체';
  String _selectedSourceTypeCode = 'school_past';

  List<String> _courseOptions = const <String>['전체'];
  List<String> _schoolNames = const <String>[];
  String? _selectedSchoolName;

  List<LearningProblemQuestion> _questions = const <LearningProblemQuestion>[];
  final Set<String> _selectedQuestionIds = <String>{};
  final Map<String, String> _selectedQuestionModes = <String, String>{};
  final ScrollController _questionGridScrollCtrl = ScrollController();
  Map<String, Map<String, String>> _questionFigureUrlsByPath =
      const <String, Map<String, String>>{};
  Map<String, String> _questionPreviewUrls = const <String, String>{};
  int _figureLoadVersion = 0;
  LearningProblemExportSettings _exportSettings =
      LearningProblemExportSettings.initial();
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
    if (_selectedSourceTypeCode == 'school_past') {
      await _reloadSchools();
    } else {
      if (mounted) {
        setState(() {
          _schoolNames = const <String>[];
          _selectedSchoolName = null;
        });
      }
    }
    await _reloadQuestions(resetSelection: resetSelection);
  }

  Future<void> _reloadSchools() async {
    if (_academyId == null) return;
    setState(() {
      _isLoadingSchools = true;
    });
    try {
      final schools = await _service.listSchoolsForSchoolPast(
        academyId: _academyId!,
        curriculumCode: _selectedCurriculumCode,
        schoolLevel: _selectedSchoolLevel,
        detailedCourse: _selectedDetailedCourse,
      );
      if (!mounted) return;
      setState(() {
        _schoolNames = schools;
        if (_selectedSchoolName == null ||
            !schools.contains(_selectedSchoolName)) {
          _selectedSchoolName = schools.isNotEmpty ? schools.first : null;
        }
      });
    } catch (e) {
      _showSnack('학교 목록 조회 실패: $e');
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
        schoolName: _selectedSourceTypeCode == 'school_past'
            ? _selectedSchoolName
            : null,
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
        if (resetSelection) {
          _selectedQuestionIds.clear();
        } else {
          _selectedQuestionIds.removeWhere((id) => !aliveIds.contains(id));
        }
      });
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
    final schoolScope = _selectedSourceTypeCode == 'school_past'
        ? (_selectedSchoolName ?? '').trim()
        : '';
    String enc(String value) => Uri.encodeComponent(value.trim());
    return <String>[
      'pb_scope_v1',
      enc(_selectedCurriculumCode),
      enc(_selectedSchoolLevel),
      enc(_selectedDetailedCourse),
      enc(_selectedSourceTypeCode),
      enc(schoolScope),
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
    if (_academyId == null || questions.isEmpty) return;
    if (!_service.hasGateway) return;
    try {
      final ids = questions.map((q) => q.id).toList();
      final urls = await _service.fetchQuestionPreviews(
        academyId: _academyId!,
        questionIds: ids,
      );
      if (!mounted) return;
      if (urls.isNotEmpty) {
        setState(() {
          _questionPreviewUrls = {
            ..._questionPreviewUrls,
            ...urls,
          };
        });
      }
    } catch (_) {
      // preview fetch failures are non-critical
    }
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

  Future<void> _onSchoolSelected(String school) async {
    if (school == _selectedSchoolName) return;
    setState(() {
      _selectedSchoolName = school;
    });
    await _reloadQuestions(resetSelection: true);
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
      out[question.id] = _selectedModeOfQuestion(question);
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

  List<String> _selectedQuestionIdsInCurrentOrder(
    List<LearningProblemQuestion> selectedQuestions,
  ) {
    return selectedQuestions
        .map((q) => q.id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
  }

  Map<String, dynamic> _buildRenderConfigForSelection(
    List<LearningProblemQuestion> selectedQuestions,
  ) {
    final selectedModes = _selectedModeMapForQuestions(selectedQuestions);
    final orderedIds = _selectedQuestionIdsInCurrentOrder(selectedQuestions);
    return _exportSettings.toRenderConfig(
      selectedQuestionIdsOrdered: orderedIds,
      questionModeByQuestionId: selectedModes,
    );
  }

  String _buildRenderHashForSelection(
    List<LearningProblemQuestion> selectedQuestions,
  ) {
    final selectedModes = _selectedModeMapForQuestions(selectedQuestions);
    final orderedIds = _selectedQuestionIdsInCurrentOrder(selectedQuestions);
    return buildLearningRenderHash(
      settings: _exportSettings,
      selectedQuestionIdsOrdered: orderedIds,
      questionModeByQuestionId: selectedModes,
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
  }) async {
    final academyId = _academyId;
    if (academyId == null || academyId.isEmpty) return null;
    if (selectedQuestions.isEmpty) return null;
    final renderHash = _buildRenderHashForSelection(selectedQuestions);
    final renderConfig = <String, dynamic>{
      ..._buildRenderConfigForSelection(selectedQuestions),
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

    final orderedIds = _selectedQuestionIdsInCurrentOrder(selectedQuestions);
    final options = <String, dynamic>{
      ...renderConfig,
      'renderHash': renderHash,
      'previewOnly': previewOnly,
    };
    final job = await _service.createExportJob(
      academyId: academyId,
      documentId: selectedQuestions.first.documentId,
      templateProfile: _exportSettings.templateProfile,
      paperSize: _exportSettings.paperLabel,
      includeAnswerSheet: _exportSettings.includeAnswerSheet,
      includeExplanation: _exportSettings.includeExplanation,
      selectedQuestionIds: orderedIds,
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
      final completed = await _ensureCompletedExportForSelection(
        selectedQuestions: selected,
        previewOnly: true,
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
      await ProblemBankExportServerPreviewDialog.open(
        context,
        pdfUrl: completed.outputUrl,
        titleText: '서버 PDF 미리보기 (${selected.length}문항)',
        initialSubjectTitle: '수학 영역',
        layoutColumns: _exportSettings.layoutColumnCount,
        maxQuestionsPerPage: _exportSettings.maxQuestionsPerPageCount,
        totalQuestionCount: selected.length,
        initialPageColumnQuestionCounts: (() {
          final dynamic raw =
              completed.resultSummary['pageColumnQuestionCounts'];
          final dynamic fallback =
              completed.options['pageColumnQuestionCounts'];
          final dynamic src = raw is List ? raw : fallback;
          if (src is List) {
            return src
                .whereType<Map>()
                .map((e) => e.map(
                      (key, value) => MapEntry('$key', value),
                    ))
                .toList(growable: false);
          }
          return const <Map<String, dynamic>>[];
        })(),
        initialColumnLabelAnchors: (() {
          final dynamic raw = completed.resultSummary['columnLabelAnchors'];
          final dynamic fallback = completed.options['columnLabelAnchors'];
          final dynamic src = raw is List ? raw : fallback;
          if (src is List) {
            return src
                .whereType<Map>()
                .map((e) => e.map(
                      (key, value) => MapEntry('$key', value),
                    ))
                .toList(growable: false);
          }
          return const <Map<String, dynamic>>[];
        })(),
        onRefreshRequested: (request) async {
          final renderPatch = <String, dynamic>{
            'subjectTitleText': request.subjectTitleText.trim().isEmpty
                ? '수학 영역'
                : request.subjectTitleText.trim(),
          };
          if (_exportSettings.layoutColumnCount == 2) {
            renderPatch['layoutMode'] = 'custom_columns';
            renderPatch['pageColumnQuestionCounts'] =
                request.pageColumnQuestionCounts;
            renderPatch['columnLabelAnchors'] = request.columnLabelAnchors;
          }
          final refreshed = await _ensureCompletedExportForSelection(
            selectedQuestions: selected,
            previewOnly: true,
            renderConfigPatch: renderPatch,
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
          final dynamic raw =
              refreshed.resultSummary['pageColumnQuestionCounts'];
          final dynamic fallback =
              refreshed.options['pageColumnQuestionCounts'];
          final dynamic src = raw is List ? raw : fallback;
          final pageCounts = src is List
              ? src
                  .whereType<Map>()
                  .map((e) => e.map((key, value) => MapEntry('$key', value)))
                  .toList(growable: false)
              : const <Map<String, dynamic>>[];
          final dynamic rawAnchors =
              refreshed.resultSummary['columnLabelAnchors'];
          final dynamic fallbackAnchors =
              refreshed.options['columnLabelAnchors'];
          final dynamic srcAnchors =
              rawAnchors is List ? rawAnchors : fallbackAnchors;
          final anchorRows = srcAnchors is List
              ? srcAnchors
                  .whereType<Map>()
                  .map((e) => e.map((key, value) => MapEntry('$key', value)))
                  .toList(growable: false)
              : const <Map<String, dynamic>>[];
          return ProblemBankPreviewRefreshResult(
            pdfUrl: refreshed.outputUrl,
            pageColumnQuestionCounts: pageCounts,
            columnLabelAnchors: anchorRows,
          );
        },
        onGeneratePdfRequested: (request) async {
          final renderPatch = <String, dynamic>{
            'subjectTitleText': request.subjectTitleText.trim().isEmpty
                ? '수학 영역'
                : request.subjectTitleText.trim(),
          };
          if (_exportSettings.layoutColumnCount == 2) {
            renderPatch['layoutMode'] = 'custom_columns';
            renderPatch['pageColumnQuestionCounts'] =
                request.pageColumnQuestionCounts;
            renderPatch['columnLabelAnchors'] = request.columnLabelAnchors;
          }
          final completedPdf = await _ensureCompletedExportForSelection(
            selectedQuestions: selected,
            previewOnly: false,
            renderConfigPatch: renderPatch,
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
                      child: ProblemBankManagerPreviewPaper(
                        question: q,
                        figureUrlsByPath: _questionFigureUrlsByPath[q.id] ??
                            const <String, String>{},
                        expanded: true,
                        scrollable: true,
                        bordered: true,
                        shadow: true,
                        showQuestionNumberPrefix: false,
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
                        if (value == '수능형') {
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
                            selectedSourceTypeCode: _selectedSourceTypeCode,
                            schoolNames: _schoolNames,
                            selectedSchoolName: _selectedSchoolName,
                            onSchoolSelected: _onSchoolSelected,
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
                  child: IgnorePointer(
                      ignoring: false,
                      child: ProblemBankBottomFabBar(
                        selectedCount: _selectedQuestionIds.length,
                        isBusy: exportBusy,
                        onSelectAll: _selectAllQuestions,
                        onClearSelection: _clearQuestionSelection,
                        onPreview: _openExportLayoutPreviewDialog,
                        onCreatePlaceholder: _showCreatePlaceholder,
                      )),
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
        const spacing = 10.0;
        const maxCardWidth = 672.0;
        const cardHeight = 468.0;
        final availableWidth =
            constraints.maxWidth.isFinite ? constraints.maxWidth : maxCardWidth;
        final cols = math.max(
          1,
          ((availableWidth + spacing) / (maxCardWidth + spacing))
              .floor()
              .toInt(),
        );
        final cardWidth = ((availableWidth - ((cols - 1) * spacing)) / cols)
            .clamp(1.0, maxCardWidth)
            .toDouble();
        final gridWidth = (cols * cardWidth) + ((cols - 1) * spacing);
        return Padding(
          padding: const EdgeInsets.fromLTRB(0, 0, 0, 116),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: gridWidth,
              child: AnimatedReorderableGrid<LearningProblemQuestion>(
                items: _questions,
                itemId: (q) => q.id,
                cardWidth: cardWidth,
                cardHeight: cardHeight,
                spacing: spacing,
                columns: cols,
                scrollController: _questionGridScrollCtrl,
                dragAnchorStrategy: pointerDragAnchorStrategy,
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
          ),
        );
      },
    );
  }
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
