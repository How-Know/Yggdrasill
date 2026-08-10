import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../services/data_manager.dart';
import '../services/tenant_service.dart';
import '../services/homework_store.dart';
import '../services/homework_grading_state_codec.dart';
import '../services/homework_departure_draft_service.dart';
import '../services/homework_session_plan_service.dart';
import '../services/homework_batch_confirm_service.dart';
import '../services/homework_test_grading_result_service.dart';
import '../services/homework_time_defaults_service.dart';
import '../services/student_flow_store.dart';
import '../services/homework_assignment_store.dart';
import '../services/learning_problem_bank_service.dart';
import '../services/next_class_start_resolver.dart';
import '../services/print_routing_service.dart';
import '../services/right_sheet_answer_preload_service.dart';
import '../services/resource_service.dart';
import '../services/textbook_pdf_service.dart';
import '../utils/naesin_exam_context.dart';
import '../models/attendance_record.dart';
import '../models/session_override.dart';
import '../models/student_flow.dart';
import 'learning/homework_quick_add_proxy_dialog.dart';
import '../services/tag_preset_service.dart';
import '../services/tag_store.dart';
import 'learning/tag_preset_dialog.dart';
import 'learning/homework_edit_dialog.dart';
import 'learning/models/problem_bank_export_models.dart'
    show kLearningQuestionModeObjective, previewAnswerForMode;
import 'design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import '../widgets/dialog_tokens.dart';
import '../widgets/app_snackbar.dart';
import '../theme/ygg_semantic_colors.dart';
import '../widgets/homework_assign_dialog.dart';
import '../app_overlays.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';
import '../widgets/flow_setup_dialog.dart';
import '../widgets/utility_glass_dialog_shell.dart';
import '../widgets/pdf/homework_answer_viewer_dialog.dart';
import '../widgets/latex_text_renderer.dart';
import '../widgets/fab_style_home_screen_header.dart';
import '../widgets/attendance_rank_dialog.dart';
import '../services/student_textbook_report_service.dart';
import '../widgets/textbook_report_review_dialog.dart';
import '../utils/homework_page_text.dart';
import 'class_content/grading_mode_page.dart';

const double _homeworkDraftExtensionWidth = 280;

class ClassContentPrintController extends ChangeNotifier {
  Future<void> Function()? _startPrintFlow;
  bool Function()? _isPrintPickMode;

  bool get isPrintPickMode => _isPrintPickMode?.call() ?? false;

  Future<void> startPrintFlow() async {
    final action = _startPrintFlow;
    if (action == null) return;
    await action();
  }

  void _attach({
    required Future<void> Function() startPrintFlow,
    required bool Function() isPrintPickMode,
  }) {
    _startPrintFlow = startPrintFlow;
    _isPrintPickMode = isPrintPickMode;
    notifyListeners();
  }

  void _detach() {
    _startPrintFlow = null;
    _isPrintPickMode = null;
    notifyListeners();
  }

  void _notifyStateChanged() => notifyListeners();
}

/// 수업 내용 관리 6번째 페이지 (구조만 정의, 기능 미구현)
class ClassContentScreen extends StatefulWidget {
  final ClassContentPrintController? printController;

  const ClassContentScreen({super.key, this.printController});

  static const double _attendingCardHeight = 120;
  static const double _attendingCardWidth = 320; // 고정 폭으로 내부 우측 정렬 보장
  static const double _studentColumnWidth = 560 * 2 / 3;
  static const double _studentColumnContentWidth = 520 * 2 / 3;
  static const double _studentNameStartInset = 34;

  @override
  State<ClassContentScreen> createState() => _ClassContentScreenState();
}

class _ClassContentScreenState extends State<ClassContentScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _uiAnimController;
  late final Timer _clockTimer;
  DateTime _now = DateTime.now();
  bool _isGradingMode = false;
  bool _printPickMode = false;
  final List<_HomePrintQueueItem> _homePrintQueue = <_HomePrintQueueItem>[];
  bool _homePrintQueueRunning = false;
  bool _homePrintQueuePanelDismissed = false;
  int _homePrintQueueSeq = 0;
  final HomeworkBatchConfirmService _batchConfirmService =
      HomeworkBatchConfirmService.instance;
  final Set<String> _expandedHomeworkIds = {};
  String? _expandedHomeworkDraftStudentId;
  final Set<String> _homeworkDraftVisuallyOpenStudentIds = <String>{};
  final Map<String, _HomeworkDraftEditorController> _homeworkDraftEditors =
      <String, _HomeworkDraftEditorController>{};
  bool _pendingConfirmFabSyncScheduled = false;
  final Map<String, String> _favoriteTemplateBookNameById = <String, String>{};
  final LearningProblemBankService _problemBankService =
      LearningProblemBankService();
  final HomeworkTestGradingResultService _gradingResultService =
      HomeworkTestGradingResultService.instance;
  final Map<String, Map<String, HomeworkAnswerCellState>>
      _testGradingDraftStatesByHomeworkId =
      <String, Map<String, HomeworkAnswerCellState>>{};
  final Map<String, List<Map<String, dynamic>>>
      _testGradingSerializedDraftByHomeworkId =
      <String, List<Map<String, dynamic>>>{};
  final Set<String> _testGradingSavedHomeworkIds = <String>{};
  final Set<({String studentId, String itemId})>
      _directStructuredHomeworkCheckKeys =
      <({String studentId, String itemId})>{};
  final Set<({String studentId, String itemId})> _structuredPendingConfirmKeys =
      <({String studentId, String itemId})>{};
  Timer? _rightSheetPreloadDebounce;
  String _lastRightSheetPreloadKey = '';
  bool? _memoFloatingHiddenBeforeGrading;
  final FabStyleScreenTabBarOverlay _homeTabOverlay =
      FabStyleScreenTabBarOverlay();
  int _openTextbookReportCount = 0;
  Timer? _textbookReportCountTimer;

  Map<({String studentId, String itemId}), bool> get _pendingConfirms =>
      _batchConfirmService.pending;

  @override
  void initState() {
    super.initState();
    widget.printController?._attach(
      startPrintFlow: _startExternalPrintFlow,
      isPrintPickMode: () => _printPickMode,
    );
    DataManager.instance.loadDeviceBindings();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      gradingModeActive.value = _isGradingMode;
      homeBatchConfirmFabVisible.value = true;
      _batchConfirmService.syncPendingCount();
      _scheduleRightSheetAnswerPreload();
    });
    HomeworkStore.instance.revision
        .addListener(_onHomeworkStoreRevisionChanged);
    rightSideSheetPdfPanelSession.addListener(_onPdfPanelSessionChanged);
    _uiAnimController = AnimationController(
        duration: const Duration(milliseconds: 1800), vsync: this)
      ..repeat();
    _clockTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted) return;
      setState(() {
        _now = DateTime.now();
      });
    });
    unawaited(_refreshTextbookReportCount());
    _textbookReportCountTimer = Timer.periodic(
      const Duration(minutes: 3),
      (_) => unawaited(_refreshTextbookReportCount()),
    );
  }

  Future<void> _refreshTextbookReportCount() async {
    try {
      final count =
          await StudentTextbookReportService.instance.openReportCount();
      if (!mounted || count == _openTextbookReportCount) return;
      setState(() => _openTextbookReportCount = count);
    } catch (_) {
      // 네트워크 오류 등은 무시하고 다음 주기에 재시도
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncHomeTabOverlay();
    });
  }

  @override
  void dispose() {
    widget.printController?._detach();
    _homeTabOverlay.dispose();
    homeGradingHistoryAction = null;
    _restoreMemoFloatingAfterGrading();
    final testGradingSessionToClear = rightSideSheetTestGradingSession.value;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      homeBatchConfirmFabVisible.value = false;
      if (identical(
        rightSideSheetTestGradingSession.value,
        testGradingSessionToClear,
      )) {
        rightSideSheetTestGradingSession.value = null;
      }
    });
    _rightSheetPreloadDebounce?.cancel();
    HomeworkStore.instance.revision.removeListener(
      _onHomeworkStoreRevisionChanged,
    );
    rightSideSheetPdfPanelSession.removeListener(_onPdfPanelSessionChanged);
    _uiAnimController.dispose();
    _clockTimer.cancel();
    _textbookReportCountTimer?.cancel();
    for (final editor in _homeworkDraftEditors.values) {
      editor.dispose();
    }
    super.dispose();
  }

  void _onPdfPanelSessionChanged() {
    if (!mounted) return;
    _syncHomeTabOverlay();
  }

  void _syncMemoFloatingForGradingMode(bool active) {
    if (active) {
      _memoFloatingHiddenBeforeGrading ??= hideGlobalMemoFloatingBanners.value;
      hideGlobalMemoFloatingBanners.value = true;
      return;
    }
    _restoreMemoFloatingAfterGrading();
  }

  void _restoreMemoFloatingAfterGrading() {
    final previous = _memoFloatingHiddenBeforeGrading;
    if (previous == null) return;
    hideGlobalMemoFloatingBanners.value = previous;
    _memoFloatingHiddenBeforeGrading = null;
  }

  void _setGradingMode(bool value) {
    if (_isGradingMode == value) return;
    setState(() {
      _isGradingMode = value;
      if (!value) {
        _batchConfirmService.clearPending();
        _structuredPendingConfirmKeys.clear();
      }
    });
    gradingModeActive.value = value;
    _syncMemoFloatingForGradingMode(value);
    if (value) {
      blockRightSideSheetOpen.value = false;
      _scheduleRightSheetAnswerPreload();
    } else {
      blockRightSideSheetOpen.value = true;
      _rightSheetPreloadDebounce?.cancel();
      _lastRightSheetPreloadKey = '';
      final closeAction = closeRightSideSheetAction;
      if (closeAction != null) {
        unawaited(closeAction());
      }
    }
    _syncHomeTabOverlay();
  }

  void _syncHomeTabOverlay() {
    // 왼쪽 정답 PDF 패널이 열려 있으면 공용 FAB 탭바를 숨긴다.
    if (rightSideSheetPdfPanelSession.value != null) {
      _homeTabOverlay.dispose();
      return;
    }
    _homeTabOverlay.sync(
      context,
      selectedIndex: _isGradingMode ? 1 : 0,
      tabs: const ['현황', '채점'],
      onTabSelected: (index) => _setGradingMode(index == 1),
    );
  }

  void _syncHomeGradingHistoryAction({
    required List<String> attendingStudentIds,
    required Map<String, String> studentNamesById,
  }) {
    if (!_isGradingMode) {
      homeGradingHistoryAction = null;
      return;
    }
    homeGradingHistoryAction = () async {
      if (!mounted) return;
      await _showGradingHistoryDialog(
        context: context,
        attendingStudentIds: attendingStudentIds,
        studentNamesById: studentNamesById,
      );
    };
  }

  void _scheduleHomeBatchConfirmFabSync() {
    if (_pendingConfirmFabSyncScheduled) return;
    _pendingConfirmFabSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingConfirmFabSyncScheduled = false;
      if (!mounted) return;
      homeBatchConfirmFabVisible.value = true;
      _batchConfirmService.syncPendingCount();
    });
  }

  void _onHomeworkStoreRevisionChanged() {
    _scheduleRightSheetAnswerPreload();
  }

  void _scheduleRightSheetAnswerPreload() {
    if (!_isGradingMode) return;
    _rightSheetPreloadDebounce?.cancel();
    _rightSheetPreloadDebounce = Timer(const Duration(milliseconds: 900), () {
      if (!mounted || !_isGradingMode) return;
      unawaited(_runRightSheetAnswerPreload());
    });
  }

  String _rightSheetSessionPayloadCacheKey({
    required String studentId,
    required HomeworkItem hw,
  }) {
    return 'student:${studentId.trim()}|right_sheet_session:${hw.id.trim()}';
  }

  Future<void> _runRightSheetAnswerPreload() async {
    final candidates = <({String studentId, HomeworkItem hw})>[];
    final seen = <String>{};
    for (final row in DataManager.instance.students) {
      final studentId = row.student.id.trim();
      if (studentId.isEmpty) continue;
      for (final hw in HomeworkStore.instance.items(studentId)) {
        if (!_isSubmittedHomeworkForGradingSearch(hw)) continue;
        final uniqueKey = '$studentId:${hw.id}';
        if (!seen.add(uniqueKey)) continue;
        candidates.add((studentId: studentId, hw: hw));
      }
    }
    candidates.sort((a, b) {
      DateTime stamp(HomeworkItem hw) =>
          hw.submittedAt ?? hw.updatedAt ?? hw.createdAt ?? DateTime(1970);
      return stamp(b.hw).compareTo(stamp(a.hw));
    });
    final selected = candidates.take(10).toList(growable: false);
    final preloadKey = selected
        .map((e) =>
            '${e.studentId}:${e.hw.id}:${e.hw.updatedAt?.millisecondsSinceEpoch ?? 0}')
        .join('|');
    if (preloadKey.isEmpty || preloadKey == _lastRightSheetPreloadKey) return;
    _lastRightSheetPreloadKey = preloadKey;

    final academyId = await _resolveAcademyIdForPrint();
    if (!mounted || academyId.trim().isEmpty) return;
    final sessions = <RightSideSheetTestGradingSession>[];
    for (final candidate in selected) {
      if (!mounted || !_isGradingMode) return;
      final session = await _buildRightSheetPreloadSession(
        studentId: candidate.studentId,
        hw: candidate.hw,
      );
      if (session == null) continue;
      sessions.add(session);
    }
    if (sessions.isEmpty) return;
    RightSheetAnswerPreloadService.instance.schedulePreloadSessions(
      academyId: academyId,
      sessions: sessions,
      maxAssignments: 10,
      maxQuestionsPerAssignment: 60,
    );
  }

  Future<RightSideSheetTestGradingSession?> _buildRightSheetPreloadSession({
    required String studentId,
    required HomeworkItem hw,
    List<({String studentId, String itemId})>? targetKeys,
  }) async {
    final keys = targetKeys == null || targetKeys.isEmpty
        ? <({String studentId, String itemId})>[
            (studentId: studentId, itemId: hw.id),
          ]
        : targetKeys;
    final overlayEntries = _buildOverlayEntriesForPendingKeys(
      keys: keys,
      fallbackHomework: hw,
    );
    final hasPbCandidate = (hw.pbPresetId ?? '').trim().isNotEmpty;
    if (hasPbCandidate) {
      final payload = await _resolveTestPbGradingViewerPayload(
        seedHomework: hw,
        keys: keys,
      );
      if (payload != null) {
        final rawLinks = await _rawRightSheetAnswerViewerLinks(
          studentId: studentId,
          hw: hw,
        );
        final resolvedLinks = await _resolveRightSheetAnswerViewerLinks(
          studentId: studentId,
          hw: hw,
        );
        final cacheKey = payload.answerViewerCacheKey.trim().isNotEmpty
            ? payload.answerViewerCacheKey.trim()
            : (rawLinks['cacheKey'] ?? '').trim();
        final rawAnswerPath = payload.answerPathRaw.trim().isNotEmpty
            ? payload.answerPathRaw.trim()
            : (rawLinks['answerPathRaw'] ?? '').trim();
        final rawSolutionPath = payload.solutionPathRaw.trim().isNotEmpty
            ? payload.solutionPathRaw.trim()
            : (rawLinks['solutionPathRaw'] ?? '').trim();
        final resolvedAnswerPath =
            (resolvedLinks['answerPathRaw'] ?? '').trim();
        final resolvedSolutionPath =
            (resolvedLinks['solutionPathRaw'] ?? '').trim();
        if (cacheKey.isNotEmpty && resolvedAnswerPath.isNotEmpty) {
          RightSheetAnswerPreloadService.instance.putPdfLinks(
            cacheKey: cacheKey,
            answerPath: resolvedAnswerPath,
            solutionPath: resolvedSolutionPath,
          );
        }
        final overlayMaps = overlayEntries
            .map(
              (entry) => <String, String>{
                'title': entry.title,
                'page': entry.page,
                'memo': entry.memo,
              },
            )
            .toList(growable: false);
        final preloadedPayload = RightSheetPreloadedSessionPayload(
          sessionId: 'student:$studentId|test_pb_grade:${payload.homeworkId}',
          homeworkId: payload.homeworkId,
          title: payload.title,
          studentName: _resolveHomeworkPrintStudentName(studentId),
          groupHomeworkTitle: _resolveGradingGroupTitleForPending(
            keys: keys,
            fallbackHomework: hw,
            payloadTitle: payload.title,
          ),
          assignmentCode: _safeAssignmentCodeForGrading(hw),
          gradingPages: payload.gradingPages,
          scoreByQuestionKey: payload.scoreByQuestionKey,
          overlayEntries: overlayMaps,
          answerPathRaw: rawAnswerPath,
          solutionPathRaw: rawSolutionPath,
          answerViewerCacheKey: cacheKey,
        );
        RightSheetAnswerPreloadService.instance.putSessionPayload(
          cacheKey: _rightSheetSessionPayloadCacheKey(
            studentId: studentId,
            hw: hw,
          ),
          payload: preloadedPayload,
        );
        return RightSideSheetTestGradingSession(
          sessionId: 'preload:${preloadedPayload.sessionId}',
          title: preloadedPayload.title,
          studentName: preloadedPayload.studentName,
          groupHomeworkTitle: preloadedPayload.groupHomeworkTitle,
          assignmentCode: preloadedPayload.assignmentCode,
          gradingPages: _toRightSheetGradingPages(
            preloadedPayload.gradingPages,
          ),
          scoreByQuestionKey: preloadedPayload.scoreByQuestionKey,
          overlayEntries: preloadedPayload.overlayEntries,
          answerPathRaw: preloadedPayload.answerPathRaw,
          solutionPathRaw: preloadedPayload.solutionPathRaw,
          answerViewerCacheKey: preloadedPayload.answerViewerCacheKey,
        );
      }
    }

    final textbookPayload = await _resolveTextbookProblemGradingPayload(
      seedHomework: hw,
      keys: keys,
    );
    if (textbookPayload == null) return null;
    final cacheKey = textbookPayload.answerViewerCacheKey.trim();
    final answerPath = textbookPayload.answerPathRaw.trim();
    final solutionPath = textbookPayload.solutionPathRaw.trim();
    // 백그라운드 프리로드에서는 로컬 resolve까지 끝내 두고,
    // 세션 payload에는 raw path를 유지해 시트 오픈과 cacheKey를 맞춘다.
    final textbookLinks = await _resolveHomeworkPdfLinks(
      hw,
      allowFlowFallback: true,
    );
    final resolvedPaths = await Future.wait<String>([
      _resolveTextbookPdfPathForRightSheet(
        textbookLinks: textbookLinks,
        kind: 'ans',
      ),
      _resolveTextbookPdfPathForRightSheet(
        textbookLinks: textbookLinks,
        kind: 'sol',
      ),
    ]);
    if (cacheKey.isNotEmpty && resolvedPaths[0].trim().isNotEmpty) {
      RightSheetAnswerPreloadService.instance.putPdfLinks(
        cacheKey: cacheKey,
        answerPath: resolvedPaths[0],
        solutionPath: resolvedPaths[1],
      );
    }
    final overlayMaps = overlayEntries
        .map(
          (entry) => <String, String>{
            'title': entry.title,
            'page': entry.page,
            'memo': entry.memo,
          },
        )
        .toList(growable: false);
    final preloadedPayload = RightSheetPreloadedSessionPayload(
      sessionId:
          'student:$studentId|textbook_problem_grade:${textbookPayload.homeworkId}',
      homeworkId: textbookPayload.homeworkId,
      title: textbookPayload.title,
      studentName: _resolveHomeworkPrintStudentName(studentId),
      groupHomeworkTitle: _resolveGradingGroupTitleForPending(
        keys: keys,
        fallbackHomework: hw,
        payloadTitle: textbookPayload.title,
      ),
      assignmentCode: _safeAssignmentCodeForGrading(hw),
      gradingPages: textbookPayload.gradingPages,
      scoreByQuestionKey: textbookPayload.scoreByQuestionKey,
      overlayEntries: overlayMaps,
      answerPathRaw: answerPath,
      solutionPathRaw: solutionPath,
      answerViewerCacheKey: cacheKey,
    );
    RightSheetAnswerPreloadService.instance.putSessionPayload(
      cacheKey: _rightSheetSessionPayloadCacheKey(
        studentId: studentId,
        hw: hw,
      ),
      payload: preloadedPayload,
    );
    return RightSideSheetTestGradingSession(
      sessionId: 'preload:${preloadedPayload.sessionId}',
      title: preloadedPayload.title,
      studentName: preloadedPayload.studentName,
      groupHomeworkTitle: preloadedPayload.groupHomeworkTitle,
      assignmentCode: preloadedPayload.assignmentCode,
      gradingPages: _toRightSheetGradingPages(preloadedPayload.gradingPages),
      scoreByQuestionKey: preloadedPayload.scoreByQuestionKey,
      overlayEntries: preloadedPayload.overlayEntries,
      answerPathRaw: preloadedPayload.answerPathRaw,
      solutionPathRaw: preloadedPayload.solutionPathRaw,
      answerViewerCacheKey: preloadedPayload.answerViewerCacheKey,
    );
  }

  bool _isSubmittedHomeworkForGradingSearch(HomeworkItem hw) {
    return hw.status != HomeworkStatus.completed &&
        hw.phase == 3 &&
        hw.completedAt == null;
  }

  String _normalizeAssignmentSearchToken(String raw) {
    return raw.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
  }

  int? _assignmentCodeMatchPriority({
    required String normalizedCode,
    required String normalizedQuery,
  }) {
    if (normalizedCode.isEmpty || normalizedQuery.isEmpty) return null;
    if (normalizedCode == normalizedQuery) return 0;
    final numeric4 = RegExp(r'^[0-9]{1,4}$');
    if (numeric4.hasMatch(normalizedQuery) &&
        normalizedCode.endsWith(normalizedQuery)) {
      return 1;
    }
    if (normalizedCode.startsWith(normalizedQuery)) return 2;
    if (normalizedCode.contains(normalizedQuery)) return 3;
    return null;
  }

  Future<List<RightSheetGradingSearchResult>> _runRightSheetGradingSearch(
    String query,
  ) async {
    final rawQuery = query.trim();
    if (rawQuery.isEmpty) return const <RightSheetGradingSearchResult>[];
    final normalizedQuery = _normalizeAssignmentSearchToken(rawQuery);
    final lowerQuery = rawQuery.toLowerCase();
    final ranked = <({
      RightSheetGradingSearchResult result,
      int score,
      DateTime updatedAt
    })>[];
    final seen = <String>{};
    final homeworkStore = HomeworkStore.instance;

    for (final row in DataManager.instance.students) {
      final studentId = row.student.id.trim();
      if (studentId.isEmpty) continue;
      final studentName =
          row.student.name.trim().isEmpty ? '학생' : row.student.name.trim();
      final items = homeworkStore.items(studentId);
      for (final hw in items) {
        if (hw.status == HomeworkStatus.completed) continue;
        final uniqueKey = '$studentId:${hw.id}';
        if (!seen.add(uniqueKey)) continue;

        final assignmentCode = _formatHomeworkAssignmentCode(
          hw.assignmentCode,
          fallback: '',
        );
        final normalizedCode = _normalizeAssignmentSearchToken(assignmentCode);
        final groupId = (homeworkStore.groupIdOfItem(hw.id) ?? '').trim();
        final groupTitle = groupId.isEmpty
            ? ''
            : (homeworkStore.groupById(studentId, groupId)?.title ?? '').trim();
        final resolvedGroupTitle = groupTitle.isEmpty
            ? (hw.title.trim().isEmpty ? '그룹 과제' : hw.title.trim())
            : groupTitle;
        final homeworkTitle = hw.title.trim().isEmpty ? '과제' : hw.title.trim();

        var score = _assignmentCodeMatchPriority(
          normalizedCode: normalizedCode,
          normalizedQuery: normalizedQuery,
        );
        if (score == null) {
          final searchableText =
              '$studentName $resolvedGroupTitle $homeworkTitle'.toLowerCase();
          if (!searchableText.contains(lowerQuery)) continue;
          score = 50;
        }

        ranked.add(
          (
            result: RightSheetGradingSearchResult(
              studentId: studentId,
              homeworkItemId: hw.id,
              assignmentCode: assignmentCode,
              studentName: studentName,
              groupHomeworkTitle: resolvedGroupTitle,
              homeworkTitle: homeworkTitle,
              hasTextbookLink: _hasDirectHomeworkTextbookLink(hw),
              isTestHomework: _isTestHomeworkItem(hw),
              isSubmitted: _isSubmittedHomeworkForGradingSearch(hw),
            ),
            score: score,
            updatedAt: hw.updatedAt ?? hw.createdAt ?? DateTime(1970),
          ),
        );
      }
    }

    ranked.sort((a, b) {
      final scoreCmp = a.score.compareTo(b.score);
      if (scoreCmp != 0) return scoreCmp;
      final updatedCmp = b.updatedAt.compareTo(a.updatedAt);
      if (updatedCmp != 0) return updatedCmp;
      return a.result.assignmentCode.compareTo(b.result.assignmentCode);
    });

    const maxResults = 50;
    return ranked
        .take(maxResults)
        .map((entry) => entry.result)
        .toList(growable: false);
  }

  Future<void> _openHomeworkAnswerShortcutFromSearch({
    required String studentId,
    required HomeworkItem hw,
  }) async {
    final resolved = await _resolveHomeworkPdfLinks(
      hw,
      allowFlowFallback: true,
    );
    if (!mounted) return;
    final answerRaw = resolved.answerPathRaw.trim();
    if (answerRaw.isEmpty) {
      _showHomeworkChipSnackBar(context, '연결된 답지 파일을 찾을 수 없습니다.');
      return;
    }
    final answerIsUrl = _isWebUrl(answerRaw);
    final answerPath =
        answerIsUrl ? answerRaw : _toLocalFilePath(answerRaw).trim();
    if (answerPath.isEmpty) {
      _showHomeworkChipSnackBar(context, '연결된 답지 파일을 찾을 수 없습니다.');
      return;
    }
    if (!answerIsUrl) {
      if (!answerPath.toLowerCase().endsWith('.pdf') ||
          !await File(answerPath).exists()) {
        if (!mounted) return;
        _showHomeworkChipSnackBar(context, '답지 PDF 파일이 존재하지 않습니다.');
        return;
      }
    }

    String? solutionPath;
    final solutionRaw = resolved.solutionPathRaw.trim();
    if (_isWebUrl(solutionRaw)) {
      solutionPath = solutionRaw;
    } else if (solutionRaw.isNotEmpty) {
      final candidate = _toLocalFilePath(solutionRaw).trim();
      if (candidate.isNotEmpty &&
          candidate.toLowerCase().endsWith('.pdf') &&
          await File(candidate).exists()) {
        solutionPath = candidate;
      }
    }

    final closeAction = closeRightSideSheetAction;
    if (closeAction != null) {
      await closeAction();
    }
    if (!mounted) return;
    await openHomeworkAnswerViewerPage(
      context,
      filePath: answerPath,
      title: hw.title.trim().isEmpty ? '답지 확인' : hw.title.trim(),
      solutionFilePath: solutionPath,
      cacheKey: 'student:$studentId|grading_search_answer:$answerPath',
      enableConfirm: false,
    );
  }

  Future<void> _openRightSheetGradingSearchResult(
    RightSheetGradingSearchResult result,
  ) async {
    if (!mounted) return;
    final studentId = result.studentId.trim();
    final itemId = result.homeworkItemId.trim();
    if (studentId.isEmpty || itemId.isEmpty) return;

    final homeworkStore = HomeworkStore.instance;
    var hw = homeworkStore.getById(studentId, itemId);
    if (hw == null) {
      await homeworkStore.reloadStudentHomework(studentId);
      if (!mounted) return;
      hw = homeworkStore.getById(studentId, itemId);
    }
    if (hw == null) {
      _showHomeworkChipSnackBar(context, '해당 과제를 찾지 못했습니다.');
      return;
    }

    if ((hw.pbPresetId ?? '').trim().isNotEmpty) {
      if (!_isSubmittedHomeworkForGradingSearch(hw)) {
        await homeworkStore.submit(studentId, hw.id);
        await HomeworkAssignmentStore.instance.clearActiveAssignmentsForItems(
          studentId,
          [hw.id],
        );
        if (!mounted) return;
        final refreshed = homeworkStore.getById(studentId, hw.id);
        if (refreshed != null) {
          hw = refreshed;
        }
      }
      await _handleSubmittedChipTapForPending(
        context: context,
        studentId: studentId,
        hw: hw,
        targetKeys: [
          (studentId: studentId, itemId: hw.id),
        ],
      );
      return;
    }

    if (_hasDirectHomeworkTextbookLink(hw)) {
      await _openHomeworkAnswerShortcutFromSearch(studentId: studentId, hw: hw);
      return;
    }

    _showHomeworkChipSnackBar(
      context,
      '교재가 등록되지 않은 과제라 바로가기를 제공하지 않습니다.',
    );
  }

  Widget _buildFloatingHomeHeader({
    required BuildContext context,
    required DateTime headerDateTime,
    required DateTime anchorDate,
    required int attendingCount,
    required int submittedCount,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: FabStyleHomeScreenHeader(
        dateTimeText: _isGradingMode
            ? _formatDateWithWeekdayShort(headerDateTime)
            : _formatDateWithWeekdayAndTime(headerDateTime),
        statsText: _isGradingMode ? '제출 $submittedCount' : '등원 $attendingCount',
        secondaryText:
            _isGradingMode ? _formatHourMinute(headerDateTime) : null,
        gradingStats: _isGradingMode,
        showAnchorDateHint: !isAttendanceAnchorToday(anchorDate),
        trailing: [
          if (!_isGradingMode) ...[
            Tooltip(
              message: '출석 순위',
              child: FabStyleActionButton(
                size: 48,
                icon: Icons.leaderboard_rounded,
                onPressed: () => unawaited(showAttendanceRankDialog(context)),
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: 'M5 바인딩 이력',
              child: FabStyleActionButton(
                size: 48,
                icon: Icons.link_rounded,
                onPressed: () => unawaited(
                  _showM5BindingHistoryDialog(context: context),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: '문항 신고',
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  FabStyleActionButton(
                    size: 48,
                    icon: Icons.flag_rounded,
                    onPressed: () => unawaited(
                      _openTextbookReportReviewDialog(context),
                    ),
                  ),
                  if (_openTextbookReportCount > 0)
                    Positioned(
                      right: -3,
                      top: -3,
                      child: IgnorePointer(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          constraints: const BoxConstraints(minWidth: 20),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE5484D),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            _openTextbookReportCount > 99
                                ? '99+'
                                : '$_openTextbookReportCount',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w900,
                              height: 1.2,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _openTextbookReportReviewDialog(BuildContext context) async {
    await showTextbookReportReviewDialog(context);
    unawaited(_refreshTextbookReportCount());
  }

  double _homeStatusContentTopPadding(BuildContext context) {
    const headerTopPadding = 8.0;
    const headerPanelVerticalPadding = 12.0 * 2;
    const headerBottomGap = 16.0;
    const headerLineHeight =
        FabTabBarTokens.previewAcademyMainTitleFontSize * 1.15;
    return MediaQuery.paddingOf(context).top +
        headerTopPadding +
        headerPanelVerticalPadding +
        headerLineHeight +
        headerBottomGap;
  }

  @override
  Widget build(BuildContext context) {
    _scheduleHomeBatchConfirmFabSync();
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (_printPickMode && (event.buttons & kSecondaryMouseButton) != 0) {
          _exitHomePrintPickMode();
        }
      },
      child: Stack(
        children: [
          Container(
            color: context.yggSurfaceBase,
            width: double.infinity,
            child: ValueListenableBuilder<List<AttendanceRecord>>(
              valueListenable: DataManager.instance.attendanceRecordsNotifier,
              builder: (context, _records, __) {
                return ValueListenableBuilder<DateTime>(
                  valueListenable: attendanceAnchorDateNotifier,
                  builder: (context, anchorDate, ___) {
                    // sessionOverrides 변화도 함께 트리거
                    final _ =
                        DataManager.instance.sessionOverridesNotifier.value;
                    final list = _computeAttendingStudentsForDate(anchorDate);
                    final headerDateTime = _headerDisplayDateTime(anchorDate);
                    final attendingStudentIds =
                        list.map((s) => s.id).toList(growable: false);
                    final studentNamesById = <String, String>{
                      for (final s in list) s.id: s.name,
                    };
                    _syncHomeGradingHistoryAction(
                      attendingStudentIds: attendingStudentIds,
                      studentNamesById: studentNamesById,
                    );
                    return ValueListenableBuilder<int>(
                      valueListenable: HomeworkStore.instance.revision,
                      builder: (context, homeworkRevision, _) {
                        final submittedCount = _isGradingMode
                            ? _countSubmittedHomeworkItems(list)
                            : 0;
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            Positioned.fill(
                              child: _isGradingMode
                                  ? GradingModePage(
                                      attendingStudentIds: attendingStudentIds,
                                      studentNamesById: studentNamesById,
                                      headerDateText:
                                          _formatDateWithWeekdayShort(
                                        headerDateTime,
                                      ),
                                      headerTimeText:
                                          _formatHourMinute(headerDateTime),
                                      headerSubmittedText: '제출 $submittedCount',
                                      showAnchorDateHint:
                                          !isAttendanceAnchorToday(anchorDate),
                                      pendingConfirms: _pendingConfirms,
                                      onSubmittedCardTap: (studentId, group,
                                          summary, children) async {
                                        final submittedChildren = children
                                            .where(
                                              (e) =>
                                                  e.status !=
                                                      HomeworkStatus
                                                          .completed &&
                                                  e.phase == 3 &&
                                                  e.completedAt == null,
                                            )
                                            .toList(growable: false);
                                        if (submittedChildren.isEmpty) {
                                          return;
                                        }
                                        final pendingKeys = submittedChildren
                                            .map(
                                              (e) => (
                                                studentId: studentId,
                                                itemId: e.id,
                                              ),
                                            )
                                            .toList(growable: false);
                                        if (submittedChildren.length == 1) {
                                          return _handleSubmittedChipTapForPending(
                                            context: context,
                                            studentId: studentId,
                                            hw: submittedChildren.first,
                                            targetKeys: pendingKeys,
                                          );
                                        }
                                        HomeworkItem answerSeed =
                                            submittedChildren.first;
                                        for (final child in submittedChildren) {
                                          if (_hasDirectHomeworkTextbookLink(
                                              child)) {
                                            answerSeed = child;
                                            break;
                                          }
                                        }
                                        return _handleSubmittedChipTapForPending(
                                          context: context,
                                          studentId: studentId,
                                          hw: answerSeed,
                                          targetKeys: pendingKeys,
                                        );
                                      },
                                      onHomeworkCardTap: (studentId, group,
                                          summary, children) async {
                                        if (_printPickMode) {
                                          if (group != null) {
                                            return _handleHomeworkGroupPrintPick(
                                              context: context,
                                              studentId: studentId,
                                              group: group,
                                              summary: summary,
                                              children: children,
                                            );
                                          }
                                          return _handleHomeworkPrintPick(
                                            context: context,
                                            studentId: studentId,
                                            hw: summary,
                                          );
                                        }
                                        await _handleHomeworkInspectionTap(
                                          context: context,
                                          studentId: studentId,
                                          group: group,
                                          summary: summary,
                                          children: children,
                                        );
                                      },
                                      onTogglePending: (studentId, itemId) {
                                        setState(() {
                                          final key = (
                                            studentId: studentId,
                                            itemId: itemId
                                          );
                                          if (_pendingConfirms
                                              .containsKey(key)) {
                                            _pendingConfirms.remove(key);
                                          } else {
                                            _pendingConfirms[key] = false;
                                          }
                                        });
                                      },
                                    )
                                  : ListView.separated(
                                      scrollDirection: Axis.horizontal,
                                      padding: EdgeInsets.fromLTRB(
                                        24,
                                        _homeStatusContentTopPadding(context),
                                        24,
                                        0,
                                      ),
                                      itemCount: list.length,
                                      separatorBuilder: (_, __) => SizedBox(
                                        width: 14.4,
                                        child: Align(
                                          alignment: Alignment.topCenter,
                                          child: Container(
                                            width: 1,
                                            height: ClassContentScreen
                                                ._attendingCardHeight,
                                            decoration: BoxDecoration(
                                              color: Theme.of(context)
                                                          .brightness ==
                                                      Brightness.dark
                                                  ? const Color(0xFF223131)
                                                  : const Color(0xFFE3E6E6),
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                            ),
                                          ),
                                        ),
                                      ),
                                      itemBuilder: (ctx, i) {
                                        return _buildStudentColumn(
                                          context,
                                          list[i],
                                        );
                                      },
                                    ),
                            ),
                            if (!_isGradingMode)
                              Positioned(
                                top: 0,
                                left: 0,
                                right: 0,
                                child: SafeArea(
                                  bottom: false,
                                  child: _buildFloatingHomeHeader(
                                    context: context,
                                    headerDateTime: headerDateTime,
                                    anchorDate: anchorDate,
                                    attendingCount: list.length,
                                    submittedCount: submittedCount,
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
          if (_printPickMode)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 72,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: _homePrintPickPanelBg,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: _homePrintPickAccent.withValues(alpha: 0.8)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 10,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.print,
                        size: 16,
                        color: _homePrintPickAccent,
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        '인쇄할 과제를 고르세요',
                        style: TextStyle(
                          color: _homePrintPickText,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () => _setHomePrintPickMode(false),
                        borderRadius: BorderRadius.circular(999),
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.25),
                            shape: BoxShape.circle,
                            border: Border.all(color: _homePrintPickBorder),
                          ),
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.close,
                            size: 12,
                            color: _homePrintPickTextSub,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          _buildHomePrintQueuePanel(),
        ],
      ),
    );
  }

  Widget _buildHomePrintQueuePanel() {
    if (_homePrintQueue.isEmpty || _homePrintQueuePanelDismissed) {
      return const SizedBox.shrink();
    }
    final queued = _homePrintQueue
        .where((item) => item.status == _HomePrintQueueStatus.queued)
        .length;
    final printing = _homePrintQueue
        .where((item) => item.status == _HomePrintQueueStatus.printing)
        .length;
    final completed = _homePrintQueue
        .where((item) => item.status == _HomePrintQueueStatus.completed)
        .length;
    final failed = _homePrintQueue
        .where((item) => item.status == _HomePrintQueueStatus.failed)
        .length;
    final allDone = _homePrintQueue.isNotEmpty && queued == 0 && printing == 0;
    final visibleQueueItems = _homePrintQueue.take(3).toList(growable: false);
    final hiddenQueueItemCount =
        _homePrintQueue.length - visibleQueueItems.length;
    final statusText = allDone
        ? (failed > 0 ? '완료 $completed · 실패 $failed' : '모두 완료 $completed')
        : '대기 $queued · 인쇄 중 $printing · 완료 $completed';

    return Positioned(
      left: 24,
      bottom: 24,
      child: Material(
        color: Colors.transparent,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          width: allDone ? 260 : 380,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: _homePrintPickPanelBg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: allDone
                  ? _homePrintPickBorder
                  : _homePrintPickAccent.withValues(alpha: 0.75),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 14,
                offset: const Offset(0, 7),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    allDone ? Icons.check_circle_rounded : Icons.print_rounded,
                    size: 18,
                    color: allDone
                        ? const Color(0xFF8BCDAF)
                        : _homePrintPickAccent,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      allDone ? '인쇄 작업 완료' : '인쇄 대기열',
                      style: const TextStyle(
                        color: _homePrintPickText,
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  if (allDone)
                    InkWell(
                      onTap: _dismissHomePrintQueuePanel,
                      borderRadius: BorderRadius.circular(999),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.22),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: _homePrintPickBorder),
                        ),
                        child: const Text(
                          '닫기',
                          style: TextStyle(
                            color: _homePrintPickTextSub,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                statusText,
                style: const TextStyle(
                  color: _homePrintPickTextSub,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (!allDone && visibleQueueItems.isNotEmpty) ...[
                const SizedBox(height: 8),
                ...visibleQueueItems.map(
                  (item) => Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          margin: const EdgeInsets.only(top: 6, right: 7),
                          decoration: BoxDecoration(
                            color: _homePrintQueueStatusColor(item),
                            shape: BoxShape.circle,
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                item.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: _homePrintPickText,
                                  fontSize: 12.3,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                '${_homePrintQueueStatusLabel(item)} · ${item.message}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: _homePrintPickTextSub,
                                  fontSize: 11.2,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (hiddenQueueItemCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      '+ $hiddenQueueItemCount개 더 있습니다',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _homePrintPickTextSub,
                        fontSize: 11.2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
              if (allDone && failed > 0) ...[
                const SizedBox(height: 7),
                Text(
                  _homePrintQueue
                          .firstWhere(
                            (item) =>
                                item.status == _HomePrintQueueStatus.failed,
                          )
                          .error ??
                      '일부 인쇄가 실패했습니다.',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFE6A0A0),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHomeworkDraftButton({
    required String attendanceId,
    required bool expanded,
    required Color inactiveColor,
    required VoidCallback onPressed,
  }) {
    if (attendanceId.isEmpty) {
      return SizedBox(
        width: 58,
        height: 58,
        child: IconButton(
          onPressed: onPressed,
          tooltip: '수업 계획',
          icon: const Icon(Icons.event_note_outlined),
          iconSize: 25,
          color: inactiveColor.withValues(alpha: 0.45),
          splashRadius: 29,
        ),
      );
    }
    return ValueListenableBuilder<int>(
      valueListenable: HomeworkDepartureDraftService.instance.revision,
      builder: (context, _, __) {
        return FutureBuilder<HomeworkDepartureDraft?>(
          future: HomeworkDepartureDraftService.instance.load(attendanceId),
          initialData:
              HomeworkDepartureDraftService.instance.peek(attendanceId),
          builder: (context, snapshot) {
            final draft = snapshot.data;
            final saved = draft?.isSaved == true;
            final hasPlan = draft?.hasPlanClassification == true;
            final count = draft?.planBadgeGroupCount ?? 0;
            final active = expanded || saved || (hasPlan && count > 0);
            final tooltip = count > 0
                ? (saved
                    ? '수업 계획 저장됨 · 숙제+오늘 $count그룹'
                    : '수업 계획 · 숙제+오늘 $count그룹')
                : '수업 계획';
            return Tooltip(
              message: tooltip,
              child: SizedBox(
                width: 58,
                height: 58,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: IconButton(
                        onPressed: onPressed,
                        icon: Icon(
                          expanded
                              ? Icons.event_note_rounded
                              : Icons.event_note_outlined,
                        ),
                        iconSize: 25,
                        color: active ? kDlgAccent : inactiveColor,
                        splashRadius: 29,
                      ),
                    ),
                    if (count > 0 && (saved || hasPlan))
                      Positioned(
                        right: 4,
                        top: 4,
                        child: Container(
                          constraints: const BoxConstraints(
                            minWidth: 20,
                            minHeight: 20,
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: kDlgAccent,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: kDlgBg),
                          ),
                          child: Text(
                            '$count',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  _HomeworkDraftEditorController _draftEditorFor({
    required String studentId,
    required String attendanceId,
    required DateTime anchorTime,
  }) {
    return _homeworkDraftEditors.putIfAbsent(
      attendanceId,
      () => _HomeworkDraftEditorController(
        studentId: studentId,
        attendanceId: attendanceId,
        anchorTime: anchorTime,
      )..load(),
    );
  }

  Widget _buildHomeworkDraftPlanSummary(
    _HomeworkDraftEditorController editor,
  ) {
    return AnimatedBuilder(
      animation: editor,
      builder: (context, _) {
        final todayTotal = editor.totalForTodayPlan();
        final elapsedMinutes = editor.elapsedMinutesForToday();
        final remainingMinutes =
            (todayTotal.minutes - elapsedMinutes).clamp(0, 1 << 30).toInt();
        final todayPlanLabel = todayTotal.minutes <= 0
            ? (todayTotal.hasUnestimated ? '미산정' : '0분')
            : '${_formatRecommendedMinutesCompact(todayTotal.minutes)}'
                '${todayTotal.hasUnestimated ? '+' : ''}';
        final homeworkTotal = editor.totalFor(HomeworkPlanDestination.homework);
        final homeworkLabel = homeworkTotal.minutes <= 0
            ? '숙제 ${homeworkTotal.hasUnestimated ? '미산정' : '0분'}'
            : '숙제 ${_formatRecommendedMinutesCompact(homeworkTotal.minutes)}'
                '${homeworkTotal.hasUnestimated ? '+' : ''}';

        // 학생카드 우측 메타와 동일: 14pt / height 1.2 / 72 높이 3줄 spaceBetween.
        final brightness = Theme.of(context).brightness;
        final isDark = brightness == Brightness.dark;
        final panelStyle =
            FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
        const infoFontSize = 14.0;
        final primaryStyle = TextStyle(
          color: panelStyle.label,
          fontSize: infoFontSize,
          height: 1.2,
          fontWeight: FontWeight.w600,
        );
        final secondaryStyle = TextStyle(
          color: isDark ? Colors.white54 : const Color(0xFF8E8E93),
          fontSize: infoFontSize,
          height: 1.2,
          fontWeight: FontWeight.w600,
        );

        return SizedBox(
          width: _homeworkDraftExtensionWidth,
          height: ClassContentScreen._attendingCardHeight,
          child: Center(
            child: SizedBox(
              height: 72,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '계획 $todayPlanLabel',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: primaryStyle,
                    ),
                    Text(
                      '진행 ${_formatRecommendedMinutesCompact(elapsedMinutes)}'
                      ' · 남은 ${_formatRecommendedMinutesCompact(remainingMinutes)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: secondaryStyle,
                    ),
                    Text(
                      homeworkLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: secondaryStyle,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHomeworkDraftSaveButton(
    _HomeworkDraftEditorController editor,
  ) {
    return AnimatedBuilder(
      animation: editor,
      builder: (context, _) {
        final busy = editor.loading || editor.saving;
        // 과제카드 2번째 줄(metaStyle)과 동일 타이포.
        final labelStyle = _HomeworkCardTheme.of(context).metaStyle;
        final Color fg = busy ? kDlgTextSub : kDlgText;
        return SizedBox(
          width: _homeworkDraftExtensionWidth,
          height: 58,
          child: Center(
            child: Material(
              color: busy ? kDlgFieldBg.withValues(alpha: 0.72) : kDlgFieldBg,
              shape: const StadiumBorder(
                side: BorderSide(color: kDlgBorder),
              ),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: busy
                    ? null
                    : () async {
                        try {
                          await editor.save();
                          if (!context.mounted) return;
                          _showHomeworkChipSnackBar(
                            context,
                            '오늘 목표를 학생에게 제시했어요.',
                          );
                        } catch (_) {
                          if (!context.mounted) return;
                          _showHomeworkChipSnackBar(
                            context,
                            '목표 제시에 실패했습니다.',
                          );
                        }
                      },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.assignment_turned_in_rounded,
                        size: 18,
                        color: fg,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        editor.saving ? '저장 중' : '계획 저장',
                        style: labelStyle.copyWith(
                          color: fg,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStudentColumn(BuildContext context, _AttendingStudent student) {
    final isHomeworkDraftExpanded =
        _expandedHomeworkDraftStudentId == student.id;
    final attendanceId = (student.record.id ?? '').trim();
    final draftEditor = isHomeworkDraftExpanded
        ? _draftEditorFor(
            studentId: student.id,
            attendanceId: attendanceId,
            anchorTime: student.record.classDateTime,
          )
        : _homeworkDraftEditors[attendanceId];
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(
      Theme.of(context).brightness,
    );
    final studentActionIconColor = panelStyle.icon;
    void toggleHomeworkDraftPanel() {
      if (attendanceId.isEmpty) {
        _showHomeworkChipSnackBar(context, '현재 출석 회차 정보를 찾을 수 없습니다.');
        return;
      }
      setState(() {
        if (isHomeworkDraftExpanded) {
          _expandedHomeworkDraftStudentId = null;
        } else {
          _expandedHomeworkDraftStudentId = student.id;
          _homeworkDraftVisuallyOpenStudentIds.add(student.id);
        }
      });
    }

    // ── 수업 계획 패널 확장 설계 ────────────────────────────────────
    // 학생카드/액션 줄의 왼쪽 baseW 레이아웃은 펼침 중에도 절대 바꾸지 않는다.
    // 바깥 폭·확장 영역 widthFactor만 애니메이션한다.
    const double baseW = ClassContentScreen._studentColumnWidth;
    const double contentW = ClassContentScreen._studentColumnContentWidth;
    const double extW = _homeworkDraftExtensionWidth;
    // 과제카드 확장과 같은 시작선 (칩 left inset + contentW).
    const double extensionLeft = _homeworkChipOuterLeftInset + contentW;
    final bool draftActive = draftEditor != null &&
        (isHomeworkDraftExpanded ||
            _homeworkDraftVisuallyOpenStudentIds.contains(student.id));

    Widget buildActionButtons() {
      return Padding(
        padding: const EdgeInsets.only(
          left: _homeworkChipOuterLeftInset,
        ),
        child: SizedBox(
          width: contentW,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.max,
            children: [
              SizedBox(
                width: 58,
                height: 58,
                child: IconButton(
                  onPressed: () => _onAddHomework(
                    context,
                    student.id,
                    attendanceId: attendanceId,
                  ),
                  icon: const Icon(Icons.add_rounded),
                  iconSize: 28,
                  color: studentActionIconColor,
                  splashRadius: 29,
                ),
              ),
              const SizedBox(width: 4),
              _buildHomeworkDraftButton(
                attendanceId: attendanceId,
                expanded: isHomeworkDraftExpanded,
                inactiveColor: studentActionIconColor,
                onPressed: toggleHomeworkDraftPanel,
              ),
              const SizedBox(width: 4),
              Tooltip(
                message: '과제 현황',
                child: SizedBox(
                  width: 58,
                  height: 58,
                  child: IconButton(
                    onPressed: () => _showHomeworkOverviewDialog(
                      context,
                      student.id,
                    ),
                    icon: const Icon(Icons.assignment_rounded),
                    iconSize: 25,
                    color: studentActionIconColor,
                    splashRadius: 29,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              SizedBox(
                width: 58,
                height: 58,
                child: IconButton(
                  onPressed: () => _onDepartFromHome(
                    context,
                    student,
                  ),
                  icon: const Icon(Icons.logout_rounded),
                  iconSize: 26,
                  color: const Color(0xFFE57373),
                  splashRadius: 29,
                ),
              ),
            ],
          ),
        ),
      );
    }

    Widget buildStudentCard() {
      return _AttendingButton(
        studentId: student.id,
        name: student.name,
        color: student.color,
        arrivalTime: student.record.arrivalTime,
        onTap: toggleHomeworkDraftPanel,
        showHorizontalDivider: false,
        width: contentW,
        margin: EdgeInsets.zero,
      );
    }

    Widget buildChips(double reveal) {
      return AnimatedBuilder(
        animation: _uiAnimController,
        builder: (context, __) {
          final tick = _uiAnimController.value; // 0..1
          // 패널을 닫아도 에디터/초안에 남은 스냅샷으로 '+' 판정한다.
          final persistedEditor = _homeworkDraftEditors[attendanceId];
          final draftSnap =
              HomeworkDepartureDraftService.instance.peek(attendanceId);
          final snapshotIds = <String>{
            ...?persistedEditor?.goalSnapshotItemIds,
            ...?draftSnap?.planSnapshotItemIds,
          };
          final snapshotReady = persistedEditor?.hasGoalSnapshot == true ||
              draftSnap?.hasGoalSnapshot == true;
          return ValueListenableBuilder<int>(
            valueListenable: HomeworkDepartureDraftService.instance.revision,
            builder: (context, _, __) {
              final liveDraft =
                  HomeworkDepartureDraftService.instance.peek(attendanceId);
              final liveIds = <String>{
                ...snapshotIds,
                ...?liveDraft?.planSnapshotItemIds,
              };
              final liveReady =
                  snapshotReady || liveDraft?.hasGoalSnapshot == true;
              return _buildHomeworkChipsReactiveForStudent(
                student.id,
                tick,
                homeworkDraftEditor: draftActive ? draftEditor : null,
                homeworkDraftReveal: draftActive ? reveal : 0.0,
                goalSnapshotItemIds: liveIds,
                hasGoalSnapshot: liveReady,
                pendingConfirms: _pendingConfirms,
                onPhase3Tap: _handleSubmittedChipTapForPending,
                onHomeworkCheckTap: ({
                  required context,
                  required studentId,
                  required group,
                  required summary,
                  required children,
                }) =>
                    _handleHomeworkInspectionTap(
                  context: context,
                  studentId: studentId,
                  group: group,
                  summary: summary,
                  children: children,
                ),
                onGroupSubmittedDoubleTap: (sid, submittedItems) {
                  final keys = submittedItems
                      .map((e) => (studentId: sid, itemId: e.id))
                      .toList(growable: false);
                  final allSelected = keys.isNotEmpty &&
                      keys.every(_pendingConfirms.containsKey);
                  if (allSelected &&
                      keys.any(_structuredPendingConfirmKeys.contains)) {
                    unawaited(
                      _cancelPendingStructuredGrading(
                        context: context,
                        keys: keys,
                      ),
                    );
                    return;
                  }
                  setState(() {
                    if (allSelected) {
                      for (final key in keys) {
                        _pendingConfirms.remove(key);
                      }
                    } else {
                      for (final key in keys) {
                        _pendingConfirms.putIfAbsent(key, () => false);
                      }
                    }
                  });
                },
                printPickMode: _printPickMode,
                onPrintPickTap: _handleHomeworkPrintPick,
                onGroupPrintPickTap: _handleHomeworkGroupPrintPick,
                onPrintPickLongPress: _handleHomeworkPrintPickWithSettings,
                onGroupPrintPickLongPress:
                    _handleHomeworkGroupPrintPickWithSettings,
                onPrintPickSecondaryTap: _exitHomePrintPickMode,
                onSlideDownComplete: (key) {
                  setState(() => _pendingConfirms[key] = true);
                },
                expandedHomeworkIds: _expandedHomeworkIds,
                onToggleExpand: (id) {
                  setState(() {
                    if (_expandedHomeworkIds.contains(id)) {
                      _expandedHomeworkIds.remove(id);
                    } else {
                      _expandedHomeworkIds
                        ..clear()
                        ..add(id);
                    }
                  });
                },
              );
            },
          );
        },
      );
    }

    final Widget column = TweenAnimationBuilder<double>(
      tween: Tween<double>(end: isHomeworkDraftExpanded ? 1 : 0),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInOutCubic,
      onEnd: () {
        if (_expandedHomeworkDraftStudentId != student.id &&
            _homeworkDraftVisuallyOpenStudentIds.contains(student.id)) {
          setState(
            () => _homeworkDraftVisuallyOpenStudentIds.remove(student.id),
          );
        }
      },
      builder: (context, reveal, _) {
        final extensionRevealW = extW * reveal;
        final outerWidth = math.max(baseW, extensionLeft + extensionRevealW);
        return SizedBox(
          width: outerWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: outerWidth,
                height: ClassContentScreen._attendingCardHeight,
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    Positioned(
                      left: 0,
                      top: 0,
                      width: baseW,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: buildStudentCard(),
                      ),
                    ),
                    if (draftActive && reveal > 0)
                      Positioned(
                        left: extensionLeft,
                        top: 0,
                        child: ClipRect(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            widthFactor: reveal,
                            child: _buildHomeworkDraftPlanSummary(draftEditor),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 0),
              SizedBox(
                width: outerWidth,
                height: 58,
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    Positioned(
                      left: 0,
                      top: 0,
                      width: baseW,
                      height: 58,
                      child: buildActionButtons(),
                    ),
                    if (draftActive && reveal > 0)
                      Positioned(
                        left: extensionLeft,
                        top: 0,
                        child: ClipRect(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            widthFactor: reveal,
                            child: _buildHomeworkDraftSaveButton(draftEditor),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Expanded(child: buildChips(reveal)),
            ],
          ),
        );
      },
    );

    if (_isGradingMode) {
      return TapRegion(
        onTapOutside: (_) {
          if (_expandedHomeworkDraftStudentId == student.id) {
            setState(() => _expandedHomeworkDraftStudentId = null);
          }
        },
        child: column,
      );
    }
    return TapRegion(
      onTapOutside: (_) {
        if (_expandedHomeworkDraftStudentId == student.id) {
          setState(() => _expandedHomeworkDraftStudentId = null);
        }
      },
      child: DragTarget<HomeworkRecentTemplate>(
        onWillAcceptWithDetails: (details) {
          return details.data.parts.isNotEmpty;
        },
        onAcceptWithDetails: (details) {
          unawaited(
            _handleFavoriteTemplateDrop(
              context: context,
              student: student,
              template: details.data,
            ),
          );
        },
        builder: (context, candidateData, rejectedData) {
          final highlight = candidateData.isNotEmpty;
          return Stack(
            children: [
              column,
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 120),
                    curve: Curves.easeOutCubic,
                    opacity: highlight ? 1.0 : 0.0,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: kDlgAccent.withOpacity(0.85),
                          width: 1.4,
                        ),
                        color: const Color(0x221B6B63),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildReservedHomeworkSlidePanel({
    required BuildContext context,
    required String studentId,
    required double tick,
    bool showContent = true,
  }) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0xFF151A1C),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
        child: showContent
            ? _buildReservedHomeworkChipsReactiveForStudent(
                context,
                studentId,
                tick,
              )
            : const SizedBox.shrink(),
      ),
    );
  }

  DateTime _headerDisplayDateTime(DateTime anchorDate) {
    if (isAttendanceAnchorToday(anchorDate)) return _now;
    return DateTime(
      anchorDate.year,
      anchorDate.month,
      anchorDate.day,
      23,
      59,
    );
  }

  // 슬라이드시트와 동일 기준일: 등원·미하원 학생
  List<_AttendingStudent> _computeAttendingStudentsForDate(
      DateTime anchorDate) {
    final _ = DataManager.instance.attendanceRecordsNotifier.value;
    final __ = DataManager.instance.sessionOverridesNotifier.value;
    return _computeAttendingStudentsStatic(anchorDate);
  }

  int _countSubmittedHomeworkItems(List<_AttendingStudent> attendingStudents) {
    int submittedItemCount = 0;
    for (final student in attendingStudents) {
      submittedItemCount += HomeworkStore.instance
          .items(student.id)
          .where(
            (hw) => hw.status != HomeworkStatus.completed && hw.phase == 3,
          )
          .length;
    }
    return submittedItemCount;
  }

  List<_AttendingStudent> _computeAttendingStudentsStatic(DateTime anchorDate) {
    final List<_AttendingStudent> result = [];
    final anchor = attendanceDateOnly(anchorDate);
    bool sameDay(DateTime a, DateTime b) =>
        a.year == b.year && a.month == b.month && a.day == b.day;
    final students =
        DataManager.instance.students.map((e) => e.student).toList();
    // 슬라이드 시트와 동일 정렬: 등원 시간 asc
    final records = DataManager.instance.attendanceRecords
        .where((rec) =>
            rec.isPresent &&
            rec.arrivalTime != null &&
            rec.departureTime == null &&
            sameDay(rec.classDateTime, anchor))
        .toList()
      ..sort((a, b) => a.arrivalTime!.compareTo(b.arrivalTime!));

    for (final rec in records) {
      final idx = students.indexWhere((x) => x.id == rec.studentId);
      if (idx == -1) continue;
      final name = students[idx].name;
      // 홈 메뉴 학생카드 테두리는 앱 기본 포인트 컬러(초록)로 통일
      result.add(_AttendingStudent(
        id: rec.studentId,
        name: name,
        color: kDlgAccent,
        record: rec,
      ));
    }
    // 중복 제거
    final seen = <String>{};
    return result.where((e) => seen.add(e.id)).toList();
  }

  String? _inferSetIdForStudent(String studentId) {
    final now = DateTime.now();
    final todayIdx = now.weekday - 1;
    final blocks = DataManager.instance.studentTimeBlocks
        .where((b) => b.studentId == studentId && b.dayIndex == todayIdx)
        .toList();
    if (blocks.isEmpty) return null;
    int nowMin = now.hour * 60 + now.minute;
    String? bestSet;
    int bestScore = 1 << 30;
    for (final b in blocks) {
      if (b.setId == null || b.setId!.isEmpty) continue;
      final start = b.startHour * 60 + b.startMinute;
      final end = start + b.duration.inMinutes;
      int score;
      if (nowMin >= start && nowMin <= end) {
        score = 0; // in-progress preferred
      } else {
        score = (nowMin - start).abs();
      }
      if (score < bestScore) {
        bestScore = score;
        bestSet = b.setId;
      }
    }
    return bestSet;
  }

  Future<void> _handleFavoriteTemplateDrop({
    required BuildContext context,
    required _AttendingStudent student,
    required HomeworkRecentTemplate template,
  }) async {
    if (template.parts.isEmpty) return;
    final studentId = student.id;
    final isProblemBankAssignmentTemplate = template.parts.any(
      (part) =>
          (part.pbPresetId ?? '').trim().isNotEmpty ||
          (part.sourceUnitLevel ?? '').trim() == 'problem_bank_assignment',
    );
    var resolvedFlowId = (template.flowId ?? '').trim();
    final preferredFlowId = await _resolveTemplatePreferredFlowId(
      studentId: studentId,
      template: template,
    );
    if (!context.mounted) return;
    if (isProblemBankAssignmentTemplate) {
      // 미리 만든 과제는 생성한 학생의 flowId가 저장되어 있을 수 있으므로,
      // 드롭 대상 학생의 플로우 이름으로 다시 매칭한 값을 우선 사용한다.
      resolvedFlowId = preferredFlowId;
    } else if (resolvedFlowId.isEmpty) {
      resolvedFlowId = preferredFlowId;
    }
    final bookId = template.primaryBookId;
    final gradeLabel = template.primaryGradeLabel;
    if (!isProblemBankAssignmentTemplate &&
        bookId.isNotEmpty &&
        gradeLabel.isNotEmpty) {
      final linkStatus = await _checkFavoriteTemplateLinkStatus(
        studentId: studentId,
        templateFlowId: resolvedFlowId,
        bookId: bookId,
        gradeLabel: gradeLabel,
      );
      if (!context.mounted) return;
      if (!linkStatus.linked) {
        final bookName = await _resolveFavoriteTemplateBookName(bookId);
        if (!context.mounted) return;
        await _confirmFavoriteTemplateLink(
          context: context,
          bookName: bookName,
          gradeLabel: gradeLabel,
        );
        // 빠른 등록에서는 교재 미연결 시 안내만 하고 종료한다.
        return;
      } else {
        final linkedFlowId = linkStatus.flowId.trim();
        if (linkedFlowId.isNotEmpty) {
          resolvedFlowId = linkedFlowId;
        }
      }
    }

    final mode = await _askFavoriteIssueMode(
      context: context,
      template: template,
      studentName: student.name,
    );
    if (!context.mounted || mode == null) return;
    final createdCount = await _issueFavoriteTemplateToStudent(
      studentId: studentId,
      template: template,
      forceFlowId: resolvedFlowId,
      mode: mode,
    );
    if (!context.mounted) return;
    if (createdCount <= 0) {
      _showHomeworkChipSnackBar(context, '즐겨찾기 과제 출제에 실패했습니다.');
      return;
    }
    _showHomeworkChipSnackBar(
      context,
      '${student.name}에게 과제 ${createdCount}개를 추가했어요.',
    );
  }

  Future<String> _resolveTemplatePreferredFlowId({
    required String studentId,
    required HomeworkRecentTemplate template,
  }) async {
    String normalizeFlowName(String raw) {
      var value = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (value.endsWith('플로우')) {
        value = value.substring(0, value.length - '플로우'.length).trim();
      }
      return StudentFlow.normalizeName(value);
    }

    final preferredName = normalizeFlowName(template.primaryPreferredFlowName);
    if (preferredName.trim().isEmpty) return '';
    final flows = await StudentFlowStore.instance.loadForStudent(studentId);
    for (final flow in flows) {
      if (!flow.enabled) continue;
      if (normalizeFlowName(flow.name) == preferredName) {
        return flow.id.trim();
      }
    }
    return '';
  }

  Future<_FavoriteTemplateLinkStatus> _checkFavoriteTemplateLinkStatus({
    required String studentId,
    required String templateFlowId,
    required String bookId,
    required String gradeLabel,
  }) async {
    bool hasMatch(List<Map<String, dynamic>> rows) {
      for (final row in rows) {
        final rowBookId = '${row['book_id'] ?? ''}'.trim();
        final rowGrade = '${row['grade_label'] ?? ''}'.trim();
        if (rowBookId == bookId && rowGrade == gradeLabel) {
          return true;
        }
      }
      return false;
    }

    final flows = await StudentFlowStore.instance.loadForStudent(studentId);
    final enabledFlows = flows.where((f) => f.enabled).toList(growable: false);
    final preferredFlowId = templateFlowId.trim();
    // "해당 학생" 기준으로만 교재 연결 여부를 판정한다.
    // 템플릿 출처 학생의 flowId가 들어와도 대상 학생에 없으면 무시한다.
    if (preferredFlowId.isNotEmpty &&
        enabledFlows.any((f) => f.id == preferredFlowId)) {
      try {
        final rows =
            await DataManager.instance.loadFlowTextbookLinks(preferredFlowId);
        if (hasMatch(rows)) {
          return _FavoriteTemplateLinkStatus(
            linked: true,
            flowId: preferredFlowId,
          );
        }
      } catch (_) {}
    }
    for (final flow in enabledFlows) {
      if (flow.id == preferredFlowId) continue;
      try {
        final rows = await DataManager.instance.loadFlowTextbookLinks(flow.id);
        if (hasMatch(rows)) {
          return _FavoriteTemplateLinkStatus(linked: true, flowId: flow.id);
        }
      } catch (_) {}
    }
    return const _FavoriteTemplateLinkStatus(linked: false, flowId: '');
  }

  Future<bool> _confirmFavoriteTemplateLink({
    required BuildContext context,
    required String bookName,
    required String gradeLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: kDlgBg,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text(
            '교재 연결 필요',
            style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
          ),
          content: Text(
            '$bookName ($gradeLabel)이(가) 연결되지 않은 학생입니다.\n해당 학생에 교재를 연결한 뒤 다시 시도해 주세요.',
            style: const TextStyle(color: kDlgTextSub, height: 1.35),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
              child: const Text('확인'),
            ),
          ],
        );
      },
    );
    return result == true;
  }

  Future<String?> _linkFavoriteTemplateBookToFlow({
    required BuildContext context,
    required String studentId,
    required String bookId,
    required String gradeLabel,
    required String bookName,
    required String preferredFlowId,
  }) async {
    final enabledFlows =
        await ensureEnabledFlowsForHomework(context, studentId);
    if (!context.mounted) return null;
    if (enabledFlows.isEmpty) {
      _showHomeworkChipSnackBar(context, '활성 플로우가 없어 교재를 연결할 수 없습니다.');
      return null;
    }
    final selectedFlow = await _pickFavoriteFlowForLink(
      context: context,
      enabledFlows: enabledFlows,
      preferredFlowId: preferredFlowId,
    );
    if (!context.mounted || selectedFlow == null) return null;

    final rows =
        await DataManager.instance.loadFlowTextbookLinks(selectedFlow.id);
    if (!context.mounted) return null;
    final merged = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final row in rows) {
      final existingBookId = '${row['book_id'] ?? ''}'.trim();
      final existingGrade = '${row['grade_label'] ?? ''}'.trim();
      if (existingBookId.isEmpty || existingGrade.isEmpty) continue;
      final key = '$existingBookId|$existingGrade';
      if (!seen.add(key)) continue;
      merged.add({
        'book_id': existingBookId,
        'grade_label': existingGrade,
        'book_name': '${row['book_name'] ?? ''}'.trim(),
      });
    }
    final droppedKey = '$bookId|$gradeLabel';
    if (seen.add(droppedKey)) {
      merged.add({
        'book_id': bookId,
        'grade_label': gradeLabel,
        'book_name': bookName,
      });
      await DataManager.instance.saveFlowTextbookLinks(selectedFlow.id, merged);
    }
    if (!context.mounted) return null;
    _showHomeworkChipSnackBar(
      context,
      '${bookName.isEmpty ? '선택한 교재' : bookName}를 ${selectedFlow.name} 플로우에 연결했어요.',
    );
    return selectedFlow.id;
  }

  Future<StudentFlow?> _pickFavoriteFlowForLink({
    required BuildContext context,
    required List<StudentFlow> enabledFlows,
    required String preferredFlowId,
  }) async {
    if (enabledFlows.isEmpty) return null;
    StudentFlow selected = enabledFlows.first;
    final preferred = preferredFlowId.trim();
    if (preferred.isNotEmpty) {
      final matched = enabledFlows.where((f) => f.id == preferred);
      if (matched.isNotEmpty) selected = matched.first;
    }
    if (enabledFlows.length == 1) return selected;
    return showDialog<StudentFlow>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocalState) {
            return AlertDialog(
              backgroundColor: kDlgBg,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: const Text(
                '플로우 선택',
                style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
              ),
              content: SizedBox(
                width: 440,
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: enabledFlows.length,
                  separatorBuilder: (_, __) =>
                      const Divider(color: kDlgBorder, height: 1),
                  itemBuilder: (ctx, i) {
                    final flow = enabledFlows[i];
                    return RadioListTile<String>(
                      value: flow.id,
                      groupValue: selected.id,
                      onChanged: (v) {
                        if (v == null) return;
                        setLocalState(() => selected = flow);
                      },
                      activeColor: kDlgAccent,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 2),
                      title: Text(
                        flow.name,
                        style: const TextStyle(
                          color: kDlgText,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(null),
                  style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
                  child: const Text('취소'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(selected),
                  style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
                  child: const Text('선택'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<_FavoriteIssueMode?> _askFavoriteIssueMode({
    required BuildContext context,
    required HomeworkRecentTemplate template,
    required String studentName,
  }) async {
    final result = await showDialog<_FavoriteIssueMode>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: kDlgBg,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text(
            '출제 방식 선택',
            style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
          ),
          content: Text(
            '$studentName에게 "${template.title.trim().isEmpty ? '(제목 없음)' : template.title.trim()}"를 어떤 방식으로 낼까요?',
            style: const TextStyle(color: kDlgTextSub, height: 1.35),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(_FavoriteIssueMode.immediate),
              style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
              child: const Text('바로 내기'),
            ),
          ],
        );
      },
    );
    return result;
  }

  Future<int> _issueFavoriteTemplateToStudent({
    required String studentId,
    required HomeworkRecentTemplate template,
    required String forceFlowId,
    required _FavoriteIssueMode mode,
  }) async {
    final normalizedFlowId = forceFlowId.trim().isNotEmpty
        ? forceFlowId.trim()
        : (template.flowId ?? '').trim();
    final hasTestParts = template.parts.any(
      (part) => _isTestHomeworkTypeLabel(part.type),
    );
    String? testFlowId;
    if (hasTestParts) {
      testFlowId = await _ensureTestFlowIdForStudent(studentId);
      if (testFlowId == null || testFlowId.isEmpty) {
        return 0;
      }
    }
    final splitMap = <String, int>{};
    final createdItems = <HomeworkItem>[];

    if (template.isGroup || template.parts.length > 1) {
      final rows = <Map<String, dynamic>>[];
      for (final part in template.parts) {
        final partType = (part.type ?? '').trim();
        final isTestPart = _isTestHomeworkTypeLabel(partType);
        final isProblemBankPart = (part.pbPresetId ?? '').trim().isNotEmpty ||
            (part.sourceUnitLevel ?? '').trim() == 'problem_bank_assignment';
        final fallbackOrigin = (part.flowId ?? '').trim();
        final resolvedOriginFlowId = (part.testOriginFlowId ?? '')
                .trim()
                .isNotEmpty
            ? part.testOriginFlowId!.trim()
            : (normalizedFlowId.isNotEmpty ? normalizedFlowId : fallbackOrigin);
        rows.add({
          'title': part.title,
          'body': part.body,
          'color': part.color,
          'flowId': isTestPart
              ? testFlowId
              : (isProblemBankPart
                  ? (normalizedFlowId.isEmpty ? null : normalizedFlowId)
                  : ((part.flowId ?? '').trim().isEmpty ? null : part.flowId)),
          'testOriginFlowId':
              isTestPart ? resolvedOriginFlowId : part.testOriginFlowId,
          'type': isTestPart ? '프린트' : partType,
          'page': part.page,
          'count': part.count,
          'timeLimitMinutes': part.timeLimitMinutes,
          'memo': part.memo,
          'content': part.content,
          'pbPresetId': part.pbPresetId,
          'bookId': part.bookId,
          'gradeLabel': part.gradeLabel,
          'sourceUnitLevel': part.sourceUnitLevel,
          'sourceUnitPath': part.sourceUnitPath,
          'unitMappings': part.unitMappings == null
              ? null
              : List<Map<String, dynamic>>.from(
                  part.unitMappings!.map((e) => Map<String, dynamic>.from(e)),
                ),
          'splitParts': part.defaultSplitParts.clamp(1, 4).toInt(),
        });
      }
      final generated =
          await HomeworkStore.instance.createGroupWithWaitingItems(
        studentId: studentId,
        groupTitle:
            template.title.trim().isEmpty ? '그룹 과제' : template.title.trim(),
        flowId: normalizedFlowId.isEmpty ? null : normalizedFlowId,
        items: rows,
        reserveAssignments: mode == _FavoriteIssueMode.reserve,
      );
      createdItems.addAll(generated);
      for (final item in generated) {
        splitMap[item.id] = item.defaultSplitParts.clamp(1, 4).toInt();
      }
    } else {
      final part = template.parts.first;
      final isProblemBankPart = (part.pbPresetId ?? '').trim().isNotEmpty ||
          (part.sourceUnitLevel ?? '').trim() == 'problem_bank_assignment';
      final fallbackFlowId =
          isProblemBankPart ? '' : (part.flowId ?? '').trim();
      final isTestPart = _isTestHomeworkTypeLabel(part.type);
      final resolvedFlowId = isTestPart
          ? testFlowId
          : (normalizedFlowId.isEmpty ? fallbackFlowId : normalizedFlowId);
      final resolvedTestOriginFlowId = isTestPart
          ? ((part.testOriginFlowId ?? '').trim().isNotEmpty
              ? part.testOriginFlowId!.trim()
              : (normalizedFlowId.isNotEmpty
                  ? normalizedFlowId
                  : fallbackFlowId))
          : part.testOriginFlowId;
      final reserveSingle = mode == _FavoriteIssueMode.reserve;
      final created = HomeworkStore.instance.add(
        studentId,
        title: part.title,
        body: part.body,
        color: part.color,
        flowId: resolvedFlowId,
        testOriginFlowId: resolvedTestOriginFlowId,
        type: isTestPart ? '프린트' : part.type,
        page: part.page,
        count: part.count,
        timeLimitMinutes: part.timeLimitMinutes,
        memo: part.memo,
        content: part.content,
        pbPresetId: part.pbPresetId,
        bookId: part.bookId,
        gradeLabel: part.gradeLabel,
        sourceUnitLevel: part.sourceUnitLevel,
        sourceUnitPath: part.sourceUnitPath,
        unitMappings: part.unitMappings == null
            ? null
            : List<Map<String, dynamic>>.from(
                part.unitMappings!.map((e) => Map<String, dynamic>.from(e)),
              ),
        defaultSplitParts: part.defaultSplitParts.clamp(1, 4).toInt(),
        deferBump: reserveSingle,
        deferPersist: reserveSingle,
      );
      createdItems.add(created);
      splitMap[created.id] = created.defaultSplitParts.clamp(1, 4).toInt();
    }

    if (createdItems.isEmpty) return 0;
    if (mode == _FavoriteIssueMode.reserve) {
      final groupReserved = template.isGroup || template.parts.length > 1;
      if (!groupReserved) {
        HomeworkAssignmentStore.instance.applyOptimisticReservedAssignments(
          studentId,
          createdItems,
        );
        HomeworkStore.instance.bumpRevision();
        final ok = await HomeworkStore.instance.commitReservedHomeworkBundleRpc(
          studentId: studentId,
          group: null,
          items: createdItems,
          splitPartsByItem: splitMap,
        );
        if (!ok) {
          for (final hw in createdItems.reversed) {
            HomeworkStore.instance.remove(studentId, hw.id);
          }
          HomeworkAssignmentStore.instance
              .revertOptimisticReservedAssignmentsForItems(
            studentId,
            createdItems.map((e) => e.id),
          );
          HomeworkStore.instance.bumpRevision();
          return 0;
        }
      }
    } else {
      HomeworkStore.instance.restoreItemsToWaiting(
        studentId,
        createdItems.map((e) => e.id).toList(growable: false),
      );
    }
    return createdItems.length;
  }

  Future<String> _resolveFavoriteTemplateBookName(String bookId) async {
    final key = bookId.trim();
    if (key.isEmpty) return '교재 없음';
    final cached = (_favoriteTemplateBookNameById[key] ?? '').trim();
    if (cached.isNotEmpty) return cached;
    try {
      final rows = await DataManager.instance.loadTextbooksWithMetadata();
      for (final row in rows) {
        final id = '${row['book_id'] ?? ''}'.trim();
        final name = '${row['book_name'] ?? ''}'.trim();
        if (id.isEmpty || name.isEmpty) continue;
        _favoriteTemplateBookNameById[id] = name;
      }
    } catch (_) {}
    final resolved = (_favoriteTemplateBookNameById[key] ?? '').trim();
    if (resolved.isNotEmpty) return resolved;
    return '교재 정보 없음';
  }

  bool _isTestHomeworkTypeLabel(String? typeLabel) =>
      (typeLabel ?? '').trim() == '테스트';

  Future<String?> _ensureTestFlowIdForStudent(String studentId) async {
    try {
      final flow = await StudentFlowStore.instance.ensureTestFlowForStudent(
        studentId,
      );
      final flowId = (flow?.id ?? '').trim();
      return flowId.isEmpty ? null : flowId;
    } catch (_) {
      return null;
    }
  }

  Future<void> _applyQuickAddPlanDestination({
    required String attendanceId,
    required String studentId,
    required List<HomeworkItem> items,
    required String? destination,
  }) async {
    if (items.isEmpty) return;
    final planDestination = switch (destination) {
      'homework' => HomeworkPlanDestination.homework,
      'next_session' || 'next' => HomeworkPlanDestination.nextSession,
      _ => HomeworkPlanDestination.inClass,
    };
    final attendanceKey = attendanceId.trim();
    if (attendanceKey.isNotEmpty) {
      final itemsByGroupId = <String, List<HomeworkItem>>{};
      for (final item in items) {
        final groupId =
            (HomeworkStore.instance.groupIdOfItem(item.id) ?? '').trim();
        if (groupId.isEmpty) continue;
        itemsByGroupId.putIfAbsent(groupId, () => <HomeworkItem>[]).add(item);
      }
      // 숙제/다음은 수업 계획 패널과 동일하게 Dart 다음 수업 시각을 명시 전달한다.
      // (미전달 시 SQL이 당일 후속 블록·자정 planned 출석을 고를 수 있음)
      DateTime? targetClassAt;
      if (planDestination == HomeworkPlanDestination.homework ||
          planDestination == HomeworkPlanDestination.nextSession) {
        AttendanceRecord? attendance;
        for (final record in DataManager.instance.attendanceRecords) {
          if ((record.id ?? '').trim() == attendanceKey) {
            attendance = record;
            break;
          }
        }
        final anchor = attendance?.classDateTime ??
            attendance?.arrivalTime ??
            DateTime.now();
        targetClassAt = NextClassStartResolver.next(
          studentId,
          after: anchor,
        );
      }
      if (itemsByGroupId.isNotEmpty) {
        try {
          for (final entry in itemsByGroupId.entries) {
            await HomeworkSessionPlanService.instance.setGroupDestination(
              attendanceId: attendanceKey,
              studentId: studentId,
              groupId: entry.key,
              itemIds: entry.value.map((item) => item.id),
              destination: planDestination,
              origin: planDestination == HomeworkPlanDestination.homework
                  ? HomeworkPlanOrigin.directHomework
                  : HomeworkPlanOrigin.plannedToday,
              targetClassAt: targetClassAt,
            );
          }
          HomeworkDepartureDraftService.instance.invalidate(attendanceKey);
          // 열려 있는 수업계획 에디터가 기본값(오늘)에 머무르지 않도록
          // destination을 즉시 반영한 뒤 서버 계획으로 재로드한다.
          final editor = _homeworkDraftEditors[attendanceKey];
          if (editor != null) {
            for (final item in items) {
              editor.destinationByItemId[item.id] = planDestination;
              editor.originByItemId[item.id] =
                  planDestination == HomeworkPlanDestination.homework
                      ? HomeworkPlanOrigin.directHomework
                      : HomeworkPlanOrigin.plannedToday;
            }
            editor.notifyListeners();
            unawaited(editor.load());
          }
        } catch (error) {
          debugPrint('[HW][quick-add-plan] save failed: $error');
          rethrow;
        }
      }
    }

    if (planDestination == HomeworkPlanDestination.homework) {
      for (final item in items) {
        item.status = HomeworkStatus.homework;
      }
      HomeworkStore.instance.bumpRevision();
    }
  }

  Future<void> _onAddHomework(
    BuildContext context,
    String studentId, {
    required String attendanceId,
  }) async {
    final enabledFlows =
        await ensureEnabledFlowsForHomework(context, studentId);
    if (enabledFlows.isEmpty) return;
    final item = await showDialog<dynamic>(
      context: context,
      builder: (ctx) => HomeworkQuickAddProxyDialog(
        studentId: studentId,
        flows: enabledFlows,
        initialFlowId: enabledFlows.first.id,
        initialTitle: '',
        initialColor: const Color(0xFF1976D2),
        requirePlanDestination: true,
      ),
    );
    if (item is Map<String, dynamic>) {
      if (item['studentId'] == studentId) {
        final action = (item['action'] as String?)?.trim() ?? 'add';
        final isReserve = action == 'reserve';
        final planDestination = (item['planDestination'] as String?)?.trim();
        final groupMode = item['groupMode'] == true;
        if (groupMode) {
          final rawItems = item['items'];
          final entries = <Map<String, dynamic>>[];
          if (rawItems is List) {
            for (final e in rawItems) {
              if (e is Map<String, dynamic>) {
                entries.add(Map<String, dynamic>.from(e));
              } else if (e is Map) {
                entries.add(Map<String, dynamic>.from(e));
              }
            }
          }
          if (entries.isEmpty) {
            _showHomeworkChipSnackBar(context, '하위 과제를 1개 이상 추가하세요.');
            return;
          }
          final selectedFlowId = (item['flowId'] as String?)?.trim();
          final hasTestEntries = entries.any(_isTestHomeworkEntry);
          if (hasTestEntries) {
            final testFlowId = await _ensureTestFlowIdForStudent(studentId);
            if (testFlowId == null || testFlowId.isEmpty) {
              if (!context.mounted) return;
              _showHomeworkChipSnackBar(context, '테스트 플로우를 준비하지 못했습니다.');
              return;
            }
            for (final entry in entries) {
              if (!_isTestHomeworkEntry(entry)) continue;
              entry['flowId'] = testFlowId;
              entry['type'] = '프린트';
              final existingOrigin =
                  (entry['testOriginFlowId'] as String?)?.trim() ?? '';
              if (existingOrigin.isEmpty &&
                  selectedFlowId != null &&
                  selectedFlowId.isNotEmpty) {
                entry['testOriginFlowId'] = selectedFlowId;
              }
            }
          }
          final createdItems =
              await HomeworkStore.instance.createGroupWithWaitingItems(
            studentId: studentId,
            groupTitle: (item['groupTitle'] as String?)?.trim() ?? '',
            flowId: selectedFlowId,
            items: entries,
            reserveAssignments: isReserve,
          );
          if (createdItems.isEmpty) {
            if (!context.mounted) return;
            _showHomeworkChipSnackBar(context, '그룹 과제 생성에 실패했어요.');
            return;
          }
          if (!isReserve) {
            await _applyQuickAddPlanDestination(
              attendanceId: attendanceId,
              studentId: studentId,
              items: createdItems,
              destination: planDestination,
            );
          }
          if (!context.mounted) return;
          final childCount = createdItems.length;
          final msg = isReserve
              ? '그룹 예약 과제(하위 ${childCount}개)를 추가했어요.'
              : '그룹 과제(하위 ${childCount}개)를 추가했어요.';
          _showHomeworkChipSnackBar(context, msg);
          return;
        }
        final flowId = item['flowId'] as String?;
        final dynamic multiRaw = item['items'];
        final entries = <Map<String, dynamic>>[];
        final createdItems = <HomeworkItem>[];
        if (multiRaw is List) {
          for (final e in multiRaw) {
            if (e is Map<String, dynamic>) entries.add(e);
          }
        } else {
          entries.add(item);
        }
        final hasTestEntries = entries.any(_isTestHomeworkEntry);
        String? testFlowId;
        if (hasTestEntries) {
          testFlowId = await _ensureTestFlowIdForStudent(studentId);
          if (testFlowId == null || testFlowId.isEmpty) {
            if (!context.mounted) return;
            _showHomeworkChipSnackBar(context, '테스트 플로우를 준비하지 못했습니다.');
            return;
          }
        }
        int parseSplitParts(dynamic value) {
          if (value is int) return value.clamp(1, 4).toInt();
          if (value is num) return value.toInt().clamp(1, 4).toInt();
          if (value is String) {
            return (int.tryParse(value) ?? 1).clamp(1, 4).toInt();
          }
          return 1;
        }

        int? parsePositiveInt(dynamic value) {
          if (value is int) return value > 0 ? value : null;
          if (value is num) {
            final parsed = value.toInt();
            return parsed > 0 ? parsed : null;
          }
          if (value is String) {
            final parsed = int.tryParse(value.trim());
            return (parsed != null && parsed > 0) ? parsed : null;
          }
          return null;
        }

        for (final entry in entries) {
          final splitParts =
              parseSplitParts(entry['splitParts'] ?? item['splitParts']);
          final bool isTestCard = _isTestHomeworkEntry(entry);
          final typeLabel =
              isTestCard ? '프린트' : (entry['type'] as String?)?.trim();
          final resolvedFlowId = isTestCard ? testFlowId : flowId;
          final existingOrigin =
              (entry['testOriginFlowId'] as String?)?.trim() ?? '';
          final resolvedTestOriginFlowId = isTestCard
              ? (existingOrigin.isNotEmpty ? existingOrigin : flowId?.trim())
              : null;
          final created = HomeworkStore.instance.add(
            item['studentId'],
            title: (entry['title'] as String?) ?? '',
            body: (entry['body'] as String?) ?? '',
            color: (entry['color'] as Color?) ?? const Color(0xFF1976D2),
            flowId: resolvedFlowId,
            testOriginFlowId: resolvedTestOriginFlowId,
            type: typeLabel,
            page: (entry['page'] as String?)?.trim(),
            count: parsePositiveInt(entry['count']),
            timeLimitMinutes: parsePositiveInt(entry['timeLimitMinutes']),
            content: (entry['content'] as String?)?.trim(),
            pbPresetId: (entry['pbPresetId'] as String?)?.trim(),
            bookId: (entry['bookId'] as String?)?.trim(),
            gradeLabel: (entry['gradeLabel'] as String?)?.trim(),
            sourceUnitLevel: (entry['sourceUnitLevel'] as String?)?.trim(),
            sourceUnitPath: (entry['sourceUnitPath'] as String?)?.trim(),
            unitMappings: (entry['unitMappings'] is List)
                ? List<Map<String, dynamic>>.from(
                    (entry['unitMappings'] as List)
                        .whereType<Map>()
                        .map((e) => Map<String, dynamic>.from(e)),
                  )
                : null,
            defaultSplitParts: splitParts,
            deferBump: isReserve,
            deferPersist: isReserve,
          );
          createdItems.add(created);
        }
        if (isReserve && createdItems.isNotEmpty) {
          HomeworkAssignmentStore.instance.applyOptimisticReservedAssignments(
            studentId,
            createdItems,
          );
          HomeworkStore.instance.bumpRevision();
          final ok =
              await HomeworkStore.instance.commitReservedHomeworkBundleRpc(
            studentId: studentId,
            group: null,
            items: createdItems,
            splitPartsByItem: <String, int>{
              for (final hw in createdItems)
                hw.id: hw.defaultSplitParts.clamp(1, 4).toInt(),
            },
          );
          if (!ok) {
            for (final hw in createdItems.reversed) {
              HomeworkStore.instance.remove(studentId, hw.id);
            }
            HomeworkAssignmentStore.instance
                .revertOptimisticReservedAssignmentsForItems(
              studentId,
              createdItems.map((e) => e.id),
            );
            HomeworkStore.instance.bumpRevision();
            if (!context.mounted) return;
            _showHomeworkChipSnackBar(context, '예약 과제 저장에 실패했어요.');
            return;
          }
        }
        if (!isReserve) {
          await _applyQuickAddPlanDestination(
            attendanceId: attendanceId,
            studentId: studentId,
            items: createdItems,
            destination: planDestination,
          );
        }
        final String msg = isReserve
            ? (entries.length > 1
                ? '예약 과제를 ${entries.length}개 추가했어요.'
                : '예약 과제를 추가했어요.')
            : (entries.length > 1
                ? '과제를 ${entries.length}개 추가했어요.'
                : '과제를 추가했어요.');
        _showHomeworkChipSnackBar(context, msg);
      }
    }
  }

  Future<void> _showHomeworkOverviewDialog(
    BuildContext context,
    String studentId,
  ) async {
    try {
      var activeAssignments = await HomeworkAssignmentStore.instance
          .loadActiveAssignments(studentId);
      var reservedItemIds = activeAssignments
          .where(_isReservationAssignment)
          .map((assignment) => assignment.homeworkItemId.trim())
          .where((itemId) => itemId.isNotEmpty)
          .toSet();
      var visibleAssignments = activeAssignments
          .where((assignment) => !_isReservationAssignment(assignment))
          .toList(growable: false);
      var checksByItem = await HomeworkAssignmentStore.instance
          .loadChecksForStudent(studentId);
      var assignmentsByItem = await HomeworkAssignmentStore.instance
          .loadAssignmentsForStudent(studentId);
      await StudentFlowStore.instance.loadForStudent(studentId);
      if (!context.mounted) return;

      final flowNameById = <String, String>{
        for (final f in StudentFlowStore.instance.cached(studentId))
          f.id: f.name,
      };
      String homeworkOverviewFlowLabel(String itemId) {
        final hw = HomeworkStore.instance.getById(studentId, itemId);
        final fid = (hw?.flowId ?? '').trim();
        if (fid.isEmpty) return '플로우 미지정';
        final name = (flowNameById[fid] ?? '').trim();
        return name.isEmpty ? '플로우 미지정' : name;
      }

      final today = _dateOnly(DateTime.now());
      bool isToday(DateTime dt) => _dateOnly(dt) == today;

      List<_HomeworkOverviewEntry> buildOverviewEntries() {
        final itemRows = <({
          String itemId,
          String title,
          String? assignmentGroupId,
          String? assignmentGroupTitle,
          DateTime assignedAt,
          DateTime? dueDate,
          bool checkedToday,
          DateTime? checkedAt,
          int progress,
          bool isActive,
          List<HomeworkAssignmentCheck> checks,
        })>[];
        final seenItemIds = <String>{};

        for (final assignment in visibleAssignments) {
          final itemId = assignment.homeworkItemId.trim();
          if (itemId.isEmpty) continue;
          final checks = List<HomeworkAssignmentCheck>.from(
            checksByItem[itemId] ?? const <HomeworkAssignmentCheck>[],
          )..sort((a, b) => a.checkedAt.compareTo(b.checkedAt));
          final todayChecks =
              checks.where((c) => isToday(c.checkedAt)).toList();
          final latestTodayCheck =
              todayChecks.isEmpty ? null : todayChecks.last;
          // 다음 수업 검사일(미래 due) 활성 숙제는 이 목록에서 제외한다.
          // 오늘 이미 검사했거나, 검사일이 오늘/과거이거나, 당일 이월(carried)인 경우만 포함.
          final dueDay = assignment.dueDate == null
              ? null
              : _dateOnly(assignment.dueDate!);
          final dueForCheckDay = assignment.dueForCheckAt == null
              ? null
              : _dateOnly(assignment.dueForCheckAt!);
          final effectiveDueDay = dueForCheckDay ?? dueDay;
          final isFutureHomework = effectiveDueDay != null &&
              effectiveDueDay.isAfter(today) &&
              assignment.status != 'carried_to_class';
          if (latestTodayCheck == null && isFutureHomework) {
            continue;
          }
          final fallbackTitle =
              HomeworkStore.instance.getById(studentId, itemId)?.title.trim() ??
                  '';
          final titleRaw = assignment.title.trim().isNotEmpty
              ? assignment.title.trim()
              : fallbackTitle;
          itemRows.add(
            (
              itemId: itemId,
              title: titleRaw.isEmpty ? '(제목 없음)' : titleRaw,
              assignmentGroupId: (assignment.groupId ?? '').trim().isEmpty
                  ? null
                  : assignment.groupId!.trim(),
              assignmentGroupTitle:
                  (assignment.groupTitleSnapshot ?? '').trim().isEmpty
                      ? null
                      : assignment.groupTitleSnapshot!.trim(),
              assignedAt: assignment.assignedAt,
              dueDate: assignment.dueDate,
              checkedToday: latestTodayCheck != null,
              checkedAt: latestTodayCheck?.checkedAt,
              progress: latestTodayCheck?.progress ?? assignment.progress,
              isActive: true,
              checks: checks,
            ),
          );
          seenItemIds.add(itemId);
        }

        for (final entry in checksByItem.entries) {
          final itemId = entry.key.trim();
          if (itemId.isEmpty ||
              seenItemIds.contains(itemId) ||
              reservedItemIds.contains(itemId)) {
            continue;
          }
          final checks = List<HomeworkAssignmentCheck>.from(entry.value)
            ..sort((a, b) => a.checkedAt.compareTo(b.checkedAt));
          final todayChecks =
              checks.where((c) => isToday(c.checkedAt)).toList();
          if (todayChecks.isEmpty) continue;
          final latestTodayCheck = todayChecks.last;

          final briefs = List<HomeworkAssignmentBrief>.from(
            assignmentsByItem[itemId] ?? const <HomeworkAssignmentBrief>[],
          )..sort((a, b) => b.assignedAt.compareTo(a.assignedAt));
          final latestBrief = briefs.isEmpty ? null : briefs.first;
          final fallbackTitle =
              HomeworkStore.instance.getById(studentId, itemId)?.title.trim() ??
                  '';
          itemRows.add(
            (
              itemId: itemId,
              title: fallbackTitle.isEmpty ? '(제목 없음)' : fallbackTitle,
              assignmentGroupId: null,
              assignmentGroupTitle: null,
              assignedAt: latestBrief?.assignedAt ?? latestTodayCheck.checkedAt,
              dueDate: latestBrief?.dueDate,
              checkedToday: true,
              checkedAt: latestTodayCheck.checkedAt,
              progress: latestTodayCheck.progress,
              isActive: false,
              checks: checks,
            ),
          );
        }

        final grouped = <String,
            List<
                ({
                  String itemId,
                  String title,
                  String? assignmentGroupId,
                  String? assignmentGroupTitle,
                  DateTime assignedAt,
                  DateTime? dueDate,
                  bool checkedToday,
                  DateTime? checkedAt,
                  int progress,
                  bool isActive,
                  List<HomeworkAssignmentCheck> checks,
                })>>{};
        for (final row in itemRows) {
          final storeGroupId =
              (HomeworkStore.instance.groupIdOfItem(row.itemId) ?? '').trim();
          final groupKey = (row.assignmentGroupId ?? '').trim().isNotEmpty
              ? row.assignmentGroupId!.trim()
              : (storeGroupId.isNotEmpty ? storeGroupId : 'item:${row.itemId}');
          grouped.putIfAbsent(groupKey, () => []).add(row);
        }

        final entries = <_HomeworkOverviewEntry>[];
        for (final groupEntry in grouped.entries) {
          final children = List.of(groupEntry.value)
            ..sort((a, b) {
              if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
              final left = a.checkedAt ?? a.assignedAt;
              final right = b.checkedAt ?? b.assignedAt;
              return right.compareTo(left);
            });
          if (children.isEmpty) continue;

          final representative = children.first;
          final group = groupEntry.key.startsWith('item:')
              ? null
              : HomeworkStore.instance.groupById(studentId, groupEntry.key);
          final groupTitle = () {
            final fromAssignment = children
                .map((c) => (c.assignmentGroupTitle ?? '').trim())
                .firstWhere((t) => t.isNotEmpty, orElse: () => '');
            if (fromAssignment.isNotEmpty) return fromAssignment;
            final fromGroup = (group?.title ?? '').trim();
            if (fromGroup.isNotEmpty) return fromGroup;
            return representative.title;
          }();

          DateTime? earliestDue;
          DateTime earliestAssigned = representative.assignedAt;
          DateTime? latestCheckedAt;
          var progress = 0;
          var checkedTodayCount = 0;
          var totalChecks = 0;
          for (final child in children) {
            if (child.dueDate != null &&
                (earliestDue == null || child.dueDate!.isBefore(earliestDue))) {
              earliestDue = child.dueDate;
            }
            if (child.assignedAt.isBefore(earliestAssigned)) {
              earliestAssigned = child.assignedAt;
            }
            if (child.checkedAt != null &&
                (latestCheckedAt == null ||
                    child.checkedAt!.isAfter(latestCheckedAt))) {
              latestCheckedAt = child.checkedAt;
            }
            if (child.progress > progress) progress = child.progress;
            if (child.checkedToday) checkedTodayCount += 1;
            totalChecks += child.checks.length;
          }

          final childItems = <HomeworkItem>[];
          for (final child in children) {
            final hw = HomeworkStore.instance.getById(studentId, child.itemId);
            if (hw != null) childItems.add(hw);
          }
          final pageSummary = childItems.isEmpty
              ? '-'
              : () {
                  final merged = mergeHomeworkItemPageRanges(
                    childItems.map(
                      (item) => (
                        page: item.page,
                        unitMappings: item.unitMappings,
                      ),
                    ),
                  );
                  return merged.isEmpty ? '-' : 'p.$merged';
                }();
          var totalCount = 0;
          for (final hw in childItems) {
            final count = hw.count ?? 0;
            if (count > 0) totalCount += count;
          }
          final bookLabel = childItems.isEmpty
              ? '-'
              : () {
                  for (final hw in childItems) {
                    final label = _homeworkBookCourseLabel(hw);
                    if (label != '-') return label;
                  }
                  return '-';
                }();

          entries.add(
            _HomeworkOverviewEntry(
              entryKey: groupEntry.key,
              homeworkItemId: representative.itemId,
              itemIds: [
                for (final child in children) child.itemId,
              ],
              title: groupTitle.isEmpty ? '(제목 없음)' : groupTitle,
              assignedAt: earliestAssigned,
              dueDate: earliestDue,
              checkedToday: checkedTodayCount > 0,
              checkedAt: latestCheckedAt,
              progress: progress,
              isActive: children.any((c) => c.isActive),
              childCount: children.length,
              flowLabel: homeworkOverviewFlowLabel(representative.itemId),
              overviewLine1Left: bookLabel,
              expandLine4Left: pageSummary,
              expandLine4Right: totalCount > 0 ? '총 ${totalCount}문항' : '-',
              expandLine5Left:
                  '오늘 검사 $checkedTodayCount/${children.length} · 검사 ${totalChecks}회',
              expandLine5Right: _formatDateTime(earliestAssigned),
              expandChildren: [
                for (var i = 0; i < children.length; i++)
                  _HomeworkOverviewCompletedChildEntry(
                    title: '${i + 1}. ${children[i].title}',
                    pageCount: () {
                      final child = children[i];
                      final page = (HomeworkStore.instance
                                  .getById(studentId, child.itemId)
                                  ?.page ??
                              '')
                          .trim();
                      return [
                        if (child.checkedToday) '오늘 검사',
                        if (!child.checkedToday) '미검사',
                        '진행 ${child.progress}%',
                        if (page.isNotEmpty) 'p.$page',
                      ].join(' · ');
                    }(),
                    memo: '',
                  ),
              ],
            ),
          );
        }

        entries.sort((a, b) {
          if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
          final leftTs = a.checkedAt ?? a.assignedAt;
          final rightTs = b.checkedAt ?? b.assignedAt;
          return rightTs.compareTo(leftTs);
        });
        return entries;
      }

      var entries = buildOverviewEntries();
      final allClassRecords = DataManager.instance
          .getAttendanceRecordsForStudent(studentId)
          .where((record) => record.isPresent)
          .toList(growable: false)
        ..sort((a, b) => b.classDateTime.compareTo(a.classDateTime));
      final classRecordsForFilter =
          allClassRecords.take(30).toList(growable: false);
      final sessionFilterOptions = <_HomeworkOverviewSessionFilterOption>[
        _HomeworkOverviewSessionFilterOption(
          id: '__all_sessions__',
          label: classRecordsForFilter.isEmpty
              ? '전체 수업'
              : '전체 수업 (최근 ${classRecordsForFilter.length}회차)',
          targetDay: null,
          from: null,
          to: null,
        ),
        ...classRecordsForFilter.map((record) {
          final start = record.classDateTime;
          final end = record.classEndTime.isAfter(start)
              ? record.classEndTime
              : start.add(const Duration(hours: 2));
          final filterFrom = start.subtract(const Duration(minutes: 20));
          final filterTo = end.add(const Duration(minutes: 40));
          final idBase = (record.id ?? '').trim();
          final id = idBase.isNotEmpty
              ? idBase
              : '${record.classDateTime.toIso8601String()}|${record.sessionOrder ?? record.cycle ?? 0}';
          return _HomeworkOverviewSessionFilterOption(
            id: id,
            label: _formatHomeworkOverviewSessionLabel(record),
            targetDay: _dateOnly(start),
            from: filterFrom,
            to: filterTo,
          );
        }),
      ];

      String studentName = '학생';
      for (final row in DataManager.instance.students) {
        if (row.student.id == studentId) {
          final name = row.student.name.trim();
          studentName = name.isEmpty ? '학생' : name;
          break;
        }
      }
      final expandedCompletedGroupIds = <String>{};
      final expandedHomeworkOverviewItemIds = <String>{};
      String selectedSessionFilterId = sessionFilterOptions.first.id;

      await showDialog<void>(
        context: context,
        barrierColor: Colors.black54,
        builder: (ctx) {
          final media = MediaQuery.of(ctx).size;
          final dialogWidth = math.min(media.width - 48, 1080.0);
          final dialogHeight = math.min(media.height - 48, 760.0);
          return Dialog(
            backgroundColor: Colors.transparent,
            elevation: 0,
            insetPadding: const EdgeInsets.all(24),
            child: UtilityGlassDialogShell(
              title: '$studentName 과제 현황',
              icon: Icons.assignment_rounded,
              preferredWidth: dialogWidth,
              maxWidth: dialogWidth,
              maxHeight: dialogHeight,
              child: StatefulBuilder(
                builder: (dialogContext, setDialogState) {
                  final selectedFilter = sessionFilterOptions.firstWhere(
                    (opt) => opt.id == selectedSessionFilterId,
                    orElse: () => sessionFilterOptions.first,
                  );
                  final completedGroupEntries =
                      _collectRecentCompletedHomeworkGroups(
                    studentId,
                    assignmentsByItem: assignmentsByItem,
                    checksByItem: checksByItem,
                    targetDay: selectedFilter.targetDay,
                    windowStart: selectedFilter.from,
                    windowEnd: selectedFilter.to,
                    limit: 16,
                  );
                  Future<void> refreshOverview() async {
                    final reloadedActive = await HomeworkAssignmentStore
                        .instance
                        .loadActiveAssignments(studentId);
                    activeAssignments = reloadedActive;
                    reservedItemIds = reloadedActive
                        .where(_isReservationAssignment)
                        .map((assignment) => assignment.homeworkItemId.trim())
                        .where((itemId) => itemId.isNotEmpty)
                        .toSet();
                    visibleAssignments = reloadedActive
                        .where((assignment) =>
                            !_isReservationAssignment(assignment))
                        .toList(growable: false);
                    checksByItem = await HomeworkAssignmentStore.instance
                        .loadChecksForStudent(studentId);
                    assignmentsByItem = await HomeworkAssignmentStore.instance
                        .loadAssignmentsForStudent(studentId);
                    final rebuilt = buildOverviewEntries();
                    if (!dialogContext.mounted) return;
                    setDialogState(() {
                      entries = rebuilt;
                    });
                  }

                  Future<bool> confirmDeleteActiveOverviewEntry(
                    _HomeworkOverviewEntry entry,
                  ) async {
                    if (!entry.isActive || entry.itemIds.isEmpty) return false;
                    final confirmed = await showDialog<bool>(
                      context: dialogContext,
                      barrierColor: Colors.black54,
                      builder: (ctx) => Dialog(
                        backgroundColor: Colors.transparent,
                        elevation: 0,
                        child: UtilityGlassDialogShell(
                          title: '활성 숙제 삭제',
                          icon: Icons.delete_outline_rounded,
                          preferredWidth: 420,
                          maxWidth: 420,
                          maxHeight: 260,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  child: Text(
                                    entry.childCount > 1
                                        ? '‘${entry.title}’ 활성 숙제 ${entry.childCount}개를 현황 목록에서 제거할까요?'
                                        : '‘${entry.title}’ 활성 숙제를 현황 목록에서 제거할까요?',
                                    style: const TextStyle(
                                      color: kDlgTextSub,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      height: 1.35,
                                    ),
                                  ),
                                ),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextButton(
                                        onPressed: () =>
                                            Navigator.of(ctx).pop(false),
                                        style: TextButton.styleFrom(
                                          foregroundColor: kDlgTextSub,
                                        ),
                                        child: const Text('취소'),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: FilledButton(
                                        onPressed: () =>
                                            Navigator.of(ctx).pop(true),
                                        style: FilledButton.styleFrom(
                                          backgroundColor:
                                              const Color(0xFFE57373),
                                        ),
                                        child: const Text('삭제'),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                    if (confirmed != true || !dialogContext.mounted)
                      return false;
                    await HomeworkAssignmentStore.instance
                        .clearActiveAssignmentsForItems(
                      studentId,
                      entry.itemIds,
                      fromStatuses: const [
                        'assigned',
                        'in_progress',
                        'carried_to_class',
                      ],
                    );
                    return dialogContext.mounted;
                  }

                  Future<void> onAddExtraCheck() async {
                    // 후보는 홈 메뉴 과제 리스트와 동일하게 HomeworkStore의 그룹/미완료
                    // item을 기준으로 만든다(assignment 행이 아직 없는 과제도 포함).
                    final hiddenItemIds = <String>{...reservedItemIds};
                    hiddenItemIds.addAll(
                      HomeworkAssignmentStore.instance
                          .peekPendingReservedHomeworkItemIds(studentId),
                    );
                    final dueByItem = <String, DateTime>{};
                    final assignedTodayItems = <String>{};
                    for (final a in activeAssignments) {
                      if (_isReservationAssignment(a)) continue;
                      final iid = a.homeworkItemId.trim();
                      if (iid.isEmpty) continue;
                      if (a.dueDate != null) {
                        final d = _dateOnly(a.dueDate!);
                        final prev = dueByItem[iid];
                        if (prev == null || d.isBefore(prev)) {
                          dueByItem[iid] = d;
                        }
                      }
                      if (_dateOnly(a.assignedAt) == today) {
                        assignedTodayItems.add(iid);
                      }
                    }
                    final candidateGroups = <_ExtraCheckGroupCandidate>[];
                    for (final group
                        in HomeworkStore.instance.groups(studentId)) {
                      final children = HomeworkStore.instance
                          .itemsInGroup(studentId, group.id)
                          .where((e) => e.status != HomeworkStatus.completed)
                          .where((e) => !hiddenItemIds.contains(e.id))
                          .toList(growable: false);
                      if (children.isEmpty) continue;
                      DateTime? groupDue;
                      bool anyAssignedToday = false;
                      int progress = 0;
                      for (final c in children) {
                        final d = dueByItem[c.id];
                        if (d != null &&
                            (groupDue == null || d.isBefore(groupDue))) {
                          groupDue = d;
                        }
                        if (assignedTodayItems.contains(c.id)) {
                          anyAssignedToday = true;
                        }
                        final checks = checksByItem[c.id] ??
                            const <HomeworkAssignmentCheck>[];
                        for (final ck in checks) {
                          if (ck.progress > progress) progress = ck.progress;
                        }
                      }
                      final dueToday = groupDue != null && groupDue == today;
                      // 이전에 내줘서 오늘이 정규 검사예정인 그룹만 제외하고,
                      // 오늘 추가된 그룹은 미리 검사 대상으로 포함한다.
                      if (dueToday && !anyAssignedToday) continue;
                      final title = group.title.trim().isNotEmpty
                          ? group.title.trim()
                          : children.first.title.trim();
                      candidateGroups.add(
                        _ExtraCheckGroupCandidate(
                          group: group,
                          summary: children.first,
                          children: children,
                          title: title.isEmpty ? '그룹 과제' : title,
                          flowLabel:
                              homeworkOverviewFlowLabel(children.first.id),
                          bookAndCourse:
                              _homeworkBookCourseLabel(children.first),
                          dueDate: groupDue,
                          progress: progress,
                        ),
                      );
                    }
                    final recorded = await _showExtraHomeworkCheckPicker(
                      context: dialogContext,
                      studentId: studentId,
                      candidateGroups: candidateGroups,
                    );
                    if (recorded) await refreshOverview();
                  }

                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                          decoration: BoxDecoration(
                            color: kDlgPanelBg,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: kDlgBorder),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.filter_alt_rounded,
                                size: 16,
                                color: kDlgTextSub,
                              ),
                              const SizedBox(width: 8),
                              const Text(
                                '수업기록 필터',
                                style: TextStyle(
                                  color: kDlgTextSub,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<String>(
                                    isExpanded: true,
                                    value: selectedSessionFilterId,
                                    dropdownColor: kDlgPanelBg,
                                    style: const TextStyle(
                                      color: kDlgText,
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                    items: sessionFilterOptions
                                        .map(
                                          (opt) => DropdownMenuItem<String>(
                                            value: opt.id,
                                            child: Text(
                                              opt.label,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        )
                                        .toList(growable: false),
                                    onChanged: (value) {
                                      if (value == null) return;
                                      setDialogState(() {
                                        selectedSessionFilterId = value;
                                        expandedCompletedGroupIds.clear();
                                        expandedHomeworkOverviewItemIds.clear();
                                      });
                                    },
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    const YggDialogSectionHeader(
                                      icon: Icons.task_alt_rounded,
                                      title: '완료 그룹과제',
                                    ),
                                    Expanded(
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: kDlgPanelBg,
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          border: Border.all(color: kDlgBorder),
                                        ),
                                        clipBehavior: Clip.antiAlias,
                                        child: completedGroupEntries.isEmpty
                                            ? const Center(
                                                child: Padding(
                                                  padding: EdgeInsets.all(16),
                                                  child: Text(
                                                    '선택한 수업에서 완료한 그룹과제가 없습니다.',
                                                    textAlign: TextAlign.center,
                                                    style: TextStyle(
                                                      color: kDlgTextSub,
                                                      fontSize: 13.5,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                ),
                                              )
                                            : ListView.separated(
                                                padding:
                                                    const EdgeInsets.all(10),
                                                itemCount: completedGroupEntries
                                                    .length,
                                                separatorBuilder: (_, __) =>
                                                    const SizedBox(height: 8),
                                                itemBuilder: (context, index) {
                                                  final entry =
                                                      completedGroupEntries[
                                                          index];
                                                  final isExpanded =
                                                      expandedCompletedGroupIds
                                                          .contains(
                                                              entry.groupId);
                                                  return _buildCompletedGroupOverviewCard(
                                                    entry,
                                                    isExpanded: isExpanded,
                                                    onTap: () {
                                                      setDialogState(() {
                                                        if (isExpanded) {
                                                          expandedCompletedGroupIds
                                                              .remove(entry
                                                                  .groupId);
                                                        } else {
                                                          expandedCompletedGroupIds
                                                              .add(entry
                                                                  .groupId);
                                                        }
                                                      });
                                                    },
                                                  );
                                                },
                                              ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              const VerticalDivider(
                                width: 1,
                                thickness: 1,
                                color: UtilityGlassDialogTokens.dividerColor,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Row(
                                      children: [
                                        const Expanded(
                                          child: YggDialogSectionHeader(
                                            icon: Icons.playlist_play_rounded,
                                            title: '활성/오늘 검사 현황',
                                          ),
                                        ),
                                        IconButton(
                                          onPressed: onAddExtraCheck,
                                          icon: const Icon(Icons.add_rounded),
                                          iconSize: 20,
                                          color: kDlgAccent,
                                          tooltip: '추가로 해온 숙제 검사',
                                          visualDensity: VisualDensity.compact,
                                          splashRadius: 20,
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(
                                            minWidth: 32,
                                            minHeight: 32,
                                          ),
                                        ),
                                      ],
                                    ),
                                    Expanded(
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: kDlgPanelBg,
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          border: Border.all(color: kDlgBorder),
                                        ),
                                        clipBehavior: Clip.antiAlias,
                                        child: entries.isEmpty
                                            ? const Center(
                                                child: Padding(
                                                  padding: EdgeInsets.all(16),
                                                  child: Text(
                                                    '활성 숙제와 오늘 검사 항목이 없습니다.',
                                                    textAlign: TextAlign.center,
                                                    style: TextStyle(
                                                      color: kDlgTextSub,
                                                      fontSize: 13.5,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                ),
                                              )
                                            : ListView.separated(
                                                padding:
                                                    const EdgeInsets.all(10),
                                                itemCount: entries.length,
                                                separatorBuilder: (_, __) =>
                                                    const SizedBox(height: 8),
                                                itemBuilder: (context, index) {
                                                  final e = entries[index];
                                                  final isOvEx =
                                                      expandedHomeworkOverviewItemIds
                                                          .contains(e.entryKey);
                                                  void toggleExpand() {
                                                    setDialogState(() {
                                                      if (isOvEx) {
                                                        expandedHomeworkOverviewItemIds
                                                            .remove(e.entryKey);
                                                      } else {
                                                        expandedHomeworkOverviewItemIds
                                                            .add(e.entryKey);
                                                      }
                                                    });
                                                  }

                                                  final card =
                                                      _buildHomeworkOverviewCard(
                                                    e,
                                                    isExpanded: isOvEx,
                                                    onTap: toggleExpand,
                                                  );
                                                  if (!e.isActive) return card;
                                                  final deleteSnack = e
                                                              .childCount >
                                                          1
                                                      ? '활성 숙제 ${e.childCount}개를 목록에서 제거했어요.'
                                                      : '활성 숙제를 목록에서 제거했어요.';
                                                  return _OverviewSwipeToDelete(
                                                    key: ValueKey(
                                                      'overview_slide_${e.entryKey}',
                                                    ),
                                                    onDeleteConfirmed:
                                                        () async {
                                                      final ok =
                                                          await confirmDeleteActiveOverviewEntry(
                                                        e,
                                                      );
                                                      if (!ok) return false;
                                                      await refreshOverview();
                                                      if (!dialogContext
                                                          .mounted) {
                                                        return true;
                                                      }
                                                      _showHomeworkChipSnackBar(
                                                        dialogContext,
                                                        deleteSnack,
                                                      );
                                                      return true;
                                                    },
                                                    child: card,
                                                  );
                                                },
                                              ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          );
        },
      );
    } catch (_) {
      if (!context.mounted) return;
      _showHomeworkChipSnackBar(context, '숙제 목록을 불러오지 못했습니다.');
    }
  }

  Future<void> _onDepartFromHome(
    BuildContext context,
    _AttendingStudent student,
  ) async {
    final now = DateTime.now();
    final studentId = student.id;
    HomeworkDepartureDraft? departureDraft;
    final attendanceId = (student.record.id ?? '').trim();
    if (attendanceId.isNotEmpty) {
      try {
        departureDraft = await HomeworkDepartureDraftService.instance.load(
          attendanceId,
          force: true,
        );
      } catch (_) {
        departureDraft = null;
      }
    }
    if (!context.mounted) return;
    final hasHomeworkItems = HomeworkStore.instance.items(studentId).isNotEmpty;
    final HomeworkAssignSelection? selection = hasHomeworkItems
        ? await showHomeworkAssignDialog(
            context,
            studentId,
            anchorTime: student.record.classDateTime,
            initialSelectedGroupIds: departureDraft?.isSaved == true
                ? departureDraft!.groupIds
                : null,
            initialSelectedItemIds:
                departureDraft?.hasPlanClassification == true
                    ? departureDraft!.planHomeworkItemIds
                    : null,
            excludedItemIds:
                departureDraft?.autoManagedPlanItemIds ?? const <String>{},
            additionalHomeworkIds:
                departureDraft?.autoRolloverToHomeworkItemIds ??
                    const <String>{},
            initialDueDateByGroupId: departureDraft?.isSaved == true
                ? departureDraft!.dueDateByGroupId
                : const <String, DateTime>{},
          )
        : const HomeworkAssignSelection(itemIds: [], dueDate: null);
    if (selection == null) return;

    try {
      final record = DataManager.instance
              .getAttendanceRecord(studentId, student.record.classDateTime) ??
          student.record;
      final arrival = record.arrivalTime ?? now;
      await DataManager.instance.saveOrUpdateAttendance(
        studentId: studentId,
        classDateTime: record.classDateTime,
        classEndTime: record.classEndTime,
        className: record.className.isNotEmpty ? record.className : '수업',
        isPresent: true,
        arrivalTime: arrival,
        departureTime: now,
        setId: record.setId,
        sessionTypeId: record.sessionTypeId,
        cycle: record.cycle,
        sessionOrder: record.sessionOrder,
        isPlanned: record.isPlanned,
        snapshotId: record.snapshotId,
        batchSessionId: record.batchSessionId,
      );
      if (attendanceId.isNotEmpty) {
        await HomeworkSessionPlanService.instance.finalizeDeparture(
          attendanceId: attendanceId,
        );
      }
      if (selection.itemIds.isNotEmpty) {
        final planItemIds = selection.planHomeworkItemIds.toSet();
        final selectedItemIds = selection.itemIds
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toSet()
            .toList(growable: false);
        for (final itemId in selectedItemIds) {
          if (planItemIds.contains(itemId)) continue;
          HomeworkStore.instance.markItemsAsHomework(
            studentId,
            <String>[itemId],
            dueDate: selection.dueDateByItemId[itemId] ?? selection.dueDate,
            cloneCompletedItems: true,
          );
        }
      }
      if (attendanceId.isNotEmpty && selection.planHomeworkItemIds.isNotEmpty) {
        await HomeworkSessionPlanService.instance.confirmDepartureHomework(
          attendanceId: attendanceId,
          homeworkItemIds: selection.planHomeworkItemIds,
        );
      }
      final selectedIds = selection.itemIds
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toSet();
      final selectableIds = selection.selectableItemIds
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toSet();
      final unselectedIds = selectableIds
          .where((id) => !selectedIds.contains(id))
          .toList(growable: false);
      if (unselectedIds.isNotEmpty) {
        HomeworkStore.instance.restoreItemsToWaiting(
          studentId,
          unselectedIds,
        );
      }
      HomeworkStore.instance.convertAllTestCardsToPrintForDeparture(studentId);
      if (selection.printTodoOnConfirm) {
        try {
          await printHomeworkTodoSheet(
            studentId: studentId,
            studentName: student.name,
            classDateTime: record.classDateTime,
            arrivalTime: arrival,
            departureTime: now,
            selectedHomeworkIds: selection.itemIds,
            additionalHomeworkIds:
                (departureDraft?.autoRolloverToHomeworkItemIds ??
                        const <String>{})
                    .toList(growable: false),
            selectedBehaviorIds: selection.selectedBehaviorIds,
            irregularBehaviorCounts: selection.irregularBehaviorCounts,
            dueDate: selection.dueDate,
            className: record.className,
            classEndTime: record.classEndTime,
            setId: record.setId,
          );
        } catch (e) {
          if (!context.mounted) return;
          _showHomeworkChipSnackBar(context, '알림장 인쇄에 실패했어요: $e');
        }
      }
      if (!context.mounted) return;
      _showHomeworkChipSnackBar(context, '${student.name} 하원 처리되었습니다.');
    } catch (e) {
      if (!context.mounted) return;
      _showHomeworkChipSnackBar(context, '하원 처리 실패: $e');
    }
  }

  Future<void> _onAddTag(BuildContext context, String studentId) async {
    final setId = _inferSetIdForStudent(studentId);
    if (setId == null) {
      _showHomeworkChipSnackBar(context, '현재 수업 세트를 찾지 못했습니다. 시간표를 확인하세요.');
      return;
    }
    await _openClassTagDialogLikeSideSheet(context, setId, studentId);
  }

  Future<String?> _openRecordNoteDialog(BuildContext context) async {
    final controller = ImeAwareTextEditingController();
    return showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kDlgBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('기록 입력',
            style: TextStyle(color: Colors.white, fontSize: 20)),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            maxLines: 3,
            decoration: const InputDecoration(
                hintText: '간단히 적어주세요',
                hintStyle: TextStyle(color: Colors.white38),
                filled: true,
                fillColor: Color(0xFF2A2A2A),
                border: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24)),
                enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFF1976D2)))),
            style: const TextStyle(color: Colors.white),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('취소', style: TextStyle(color: Colors.white70))),
          ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1976D2),
                  foregroundColor: Colors.white),
              child: const Text('추가')),
        ],
      ),
    );
  }

  List<HomeworkAnswerOverlayEntry> _buildOverlayEntriesForPendingKeys({
    required List<({String studentId, String itemId})> keys,
    required HomeworkItem fallbackHomework,
  }) {
    final seenItemIds = <String>{};
    final overlayEntries = <HomeworkAnswerOverlayEntry>[];
    for (final key in keys) {
      final item = HomeworkStore.instance.getById(key.studentId, key.itemId);
      if (item == null) continue;
      if (!seenItemIds.add(item.id)) continue;
      final title = item.title.trim().isEmpty ? '(제목 없음)' : item.title.trim();
      final pageRaw = (item.page ?? '').trim();
      final pageText = pageRaw.isEmpty ? '-' : 'p.$pageRaw';
      final memoRaw = (item.memo ?? '').trim();
      final memoText = memoRaw.isEmpty ? '-' : memoRaw;
      overlayEntries.add(
        HomeworkAnswerOverlayEntry(
          title: title,
          page: pageText,
          memo: memoText,
        ),
      );
    }
    if (overlayEntries.isEmpty) {
      final fallbackPage = (fallbackHomework.page ?? '').trim();
      final fallbackMemo = (fallbackHomework.memo ?? '').trim();
      overlayEntries.add(
        HomeworkAnswerOverlayEntry(
          title: fallbackHomework.title.trim().isEmpty
              ? '(제목 없음)'
              : fallbackHomework.title.trim(),
          page: fallbackPage.isEmpty ? '-' : 'p.$fallbackPage',
          memo: fallbackMemo.isEmpty ? '-' : fallbackMemo,
        ),
      );
    }
    return overlayEntries;
  }

  List<Map<String, dynamic>> _serializeTestGradingDraftRows({
    required String homeworkId,
    required List<HomeworkAnswerGradingPage> gradingPages,
    required Map<String, HomeworkAnswerCellState> states,
  }) {
    final rows = <Map<String, dynamic>>[];
    for (final page in gradingPages) {
      for (final cell in page.cells) {
        rows.add(<String, dynamic>{
          'homeworkId': homeworkId,
          'page': page.pageNumber,
          'questionIndex': cell.questionIndex,
          'state': _encodeTestGradingState(
            states[cell.key] ?? HomeworkAnswerCellState.correct,
          ),
        });
      }
    }
    return rows;
  }

  String _encodeTestGradingState(HomeworkAnswerCellState state) {
    return encodeHomeworkGradingUiState(state);
  }

  HomeworkAnswerCellState _decodeTestGradingState(String? raw) {
    return decodeHomeworkGradingUiState(raw);
  }

  Map<String, String> _toRightSheetStateMap(
    Map<String, HomeworkAnswerCellState> states,
  ) {
    final out = <String, String>{};
    states.forEach((key, value) {
      out[key] = _encodeTestGradingState(value);
    });
    return out;
  }

  Map<String, HomeworkAnswerCellState> _fromRightSheetStateMap(
    Map<String, String> states,
  ) {
    final out = <String, HomeworkAnswerCellState>{};
    states.forEach((key, value) {
      out[key] = _decodeTestGradingState(value);
    });
    return out;
  }

  Map<String, HomeworkAnswerCellState> _retryBaselineStates(
    HomeworkTestSavedGradingSession? session,
  ) {
    if (session == null) return const <String, HomeworkAnswerCellState>{};
    final out = <String, HomeworkAnswerCellState>{};
    session.states.forEach((key, state) {
      if (isHomeworkGradingRetryState(state)) {
        out[key] = state;
      }
    });
    return out;
  }

  List<Map<String, dynamic>> _toRightSheetGradingPages(
    List<HomeworkAnswerGradingPage> pages,
  ) {
    return pages
        .map(
          (page) => <String, dynamic>{
            'pageNumber': page.pageNumber,
            'cells': page.cells
                .map(
                  (cell) => <String, dynamic>{
                    'key': cell.key,
                    'questionIndex': cell.questionIndex,
                    if (cell.questionLabel.trim().isNotEmpty)
                      'questionLabel': cell.questionLabel.trim(),
                    if (cell.questionCategory.trim().isNotEmpty)
                      'questionCategory': cell.questionCategory.trim(),
                    'answer': cell.answer,
                    'answerMode': cell.answerMode,
                    if (cell.answerImageUrl.trim().isNotEmpty)
                      'answerImageUrl': cell.answerImageUrl.trim(),
                    if (cell.answerImageWidth != null)
                      'answerImageWidth': cell.answerImageWidth,
                    if (cell.answerImageHeight != null)
                      'answerImageHeight': cell.answerImageHeight,
                    if (cell.answerImagePixelRatio != null)
                      'answerImagePixelRatio': cell.answerImagePixelRatio,
                    if (cell.answerRenderPolicy.trim().isNotEmpty)
                      'answerRenderPolicy': cell.answerRenderPolicy.trim(),
                    if (cell.answerSourceKind.trim().isNotEmpty)
                      'answerSourceKind': cell.answerSourceKind.trim(),
                    if (cell.answerSourceId.trim().isNotEmpty)
                      'answerSourceId': cell.answerSourceId.trim(),
                    if (cell.answerAssetKind.trim().isNotEmpty)
                      'answerAssetKind': cell.answerAssetKind.trim(),
                    if (cell.answerRenderStyleVersion.trim().isNotEmpty)
                      'answerRenderStyleVersion':
                          cell.answerRenderStyleVersion.trim(),
                    if (cell.answerPageNumber != null)
                      'answerPageNumber': cell.answerPageNumber,
                    if (cell.answerRect1k.length >= 4)
                      'answerRect1k': cell.answerRect1k.take(4).toList(),
                    if (cell.focusRect1k.length >= 4)
                      'focusRect1k': cell.focusRect1k.take(4).toList(),
                    if (cell.answerPathRaw.trim().isNotEmpty)
                      'answerPathRaw': cell.answerPathRaw.trim(),
                    if (cell.solutionPathRaw.trim().isNotEmpty)
                      'solutionPathRaw': cell.solutionPathRaw.trim(),
                    if (cell.solutionPageNumber != null)
                      'solutionPageNumber': cell.solutionPageNumber,
                    if (cell.solutionRect1k.length >= 4)
                      'solutionRect1k': cell.solutionRect1k.take(4).toList(),
                    if (cell.sourceInfo.isNotEmpty)
                      'sourceInfo': Map<String, String>.from(cell.sourceInfo),
                  },
                )
                .toList(growable: false),
          },
        )
        .toList(growable: false);
  }

  Future<
      ({
        String homeworkId,
        String title,
        List<HomeworkAnswerGradingPage> gradingPages,
        Map<String, double> scoreByQuestionKey,
        String answerPathRaw,
        String solutionPathRaw,
        String answerViewerCacheKey,
      })?> _resolveTestPbGradingViewerPayload({
    required HomeworkItem seedHomework,
    required List<({String studentId, String itemId})> keys,
  }) async {
    final seenItemIds = <String>{};
    final allItems = <HomeworkItem>[];
    for (final key in keys) {
      final item = HomeworkStore.instance.getById(key.studentId, key.itemId);
      if (item == null) continue;
      if (!seenItemIds.add(item.id)) continue;
      allItems.add(item);
    }
    if (allItems.isEmpty) {
      allItems.add(seedHomework);
    }
    final pbItems = allItems
        .where(
          (item) => (item.pbPresetId ?? '').trim().isNotEmpty,
        )
        .toList(growable: false);
    if (pbItems.isEmpty) return null;

    final baseItem = pbItems.firstWhere(
      (item) => item.id == seedHomework.id,
      orElse: () => pbItems.first,
    );
    final presetId = (baseItem.pbPresetId ?? '').trim();
    if (presetId.isEmpty) return null;

    final academyId = await _resolveAcademyIdForPrint();
    if (academyId.isEmpty) return null;
    final preset = await _problemBankService.getExportPresetById(
      academyId: academyId,
      presetId: presetId,
    );
    if (preset == null) return null;
    // 인쇄 경로와 동일하게 renderConfig 폴백을 포함해 UID를 모은다.
    var selectedUids = _extractSelectedQuestionUidsFromPreset(preset);
    if (selectedUids.isEmpty) return null;

    final activeSnapshots =
        await ResourceService.instance.loadHomeworkItemProblemSnapshots(
      homeworkItemIds: <String>[baseItem.id],
    );
    final activeQuestionUids = activeSnapshots
        .map((row) => '${row['pb_question_uid'] ?? ''}'.trim())
        .where((uid) => uid.isNotEmpty)
        .toSet();
    if (activeQuestionUids.isNotEmpty) {
      final filtered = selectedUids
          .where(activeQuestionUids.contains)
          .toList(growable: false);
      if (filtered.isEmpty) return null;
      // 스냅샷이 preset보다 현저히 적으면(부분 동기화/미생성) 전체 preset을 쓴다.
      // 그렇지 않으면 제외된 문항 반영을 위해 교집합을 유지한다.
      final snapshotLooksTruncated = filtered.length < selectedUids.length &&
          filtered.length * 2 <= selectedUids.length;
      if (!snapshotLooksTruncated) {
        selectedUids = filtered;
      } else {
        debugPrint(
          '[HW_GRADE][snapshot_truncated] preset=${selectedUids.length} '
          'snapshot=${filtered.length} item=${baseItem.id} — using preset',
        );
      }
    }

    final questions = await _problemBankService.loadQuestionsByQuestionUids(
      academyId: academyId,
      questionUids: selectedUids,
    );
    if (questions.isEmpty) return null;
    final questionByKey = <String, LearningProblemQuestion>{};
    for (final question in questions) {
      final stableKey = question.stableQuestionKey.trim();
      if (stableKey.isNotEmpty) {
        questionByKey.putIfAbsent(stableKey, () => question);
      }
      final uid = question.questionUid.trim();
      if (uid.isNotEmpty) {
        questionByKey.putIfAbsent(uid, () => question);
      }
      final id = question.id.trim();
      if (id.isNotEmpty) {
        questionByKey.putIfAbsent(id, () => question);
      }
    }
    final modeByUid = preset.questionModeByQuestionUid;
    String answerRenderKindForMode(String mode) {
      final normalized = mode.trim().toLowerCase();
      if (normalized == 'essay' || normalized.contains('서술')) return 'essay';
      return 'subjective';
    }

    final sourceIdsByRenderKind = <String, Set<String>>{};
    for (final uid in selectedUids) {
      final question = questionByKey[uid];
      if (question == null) continue;
      final answerMode = (modeByUid[uid] ?? '').trim().toLowerCase();
      if (answerMode == kLearningQuestionModeObjective) continue;
      sourceIdsByRenderKind
          .putIfAbsent(answerRenderKindForMode(answerMode), () => <String>{})
          .add(question.id);
    }
    final answerRenderByQuestionIdByKind =
        <String, Map<String, LearningProblemAnswerRender>>{};
    for (final entry in sourceIdsByRenderKind.entries) {
      answerRenderByQuestionIdByKind[entry.key] =
          await _problemBankService.loadUnifiedAnswerRenderAssets(
        academyId: academyId,
        sourceKind: 'pb_question',
        answerKind: entry.key,
        sourceIds: entry.value,
        styleVersion: kUnifiedAnswerRenderStyleVersionV11,
        fallbackStyleVersions: const <String>[kUnifiedAnswerRenderStyleVersion],
      );
    }
    final textbookSourceContext = await _loadProblemBankTextbookSourceContext(
      questions: questions,
      homeworkId: baseItem.id,
    );

    final presetScoreByUid = preset.questionScoreByQuestionUid;

    // 프리셋(renderConfig)에 저장된 페이지별 문항 수 레이아웃을 우선 사용한다.
    // 저장 포맷: `[{pageIndex: 1, left: N, right: M}, ...]` (1-based pageIndex).
    // 총 문항 = left + right. 없거나 비어있으면 question.sourcePage 로 폴백.
    final pageCapacityByPage = <int, int>{};
    final rawPageRows = preset.renderConfig['pageColumnQuestionCounts'];
    if (rawPageRows is List) {
      for (final row in rawPageRows) {
        if (row is! Map) continue;
        final map = Map<String, dynamic>.from(row);
        final pageIdx = int.tryParse(
              '${map['pageIndex'] ?? map['page'] ?? map['pageNo'] ?? ''}',
            ) ??
            0;
        final left = int.tryParse(
              '${map['left'] ?? map['leftCount'] ?? map['col1'] ?? 0}',
            ) ??
            0;
        final right = int.tryParse(
              '${map['right'] ?? map['rightCount'] ?? map['col2'] ?? 0}',
            ) ??
            0;
        if (pageIdx <= 0) continue;
        final int capacity = (left < 0 ? 0 : left) + (right < 0 ? 0 : right);
        if (capacity <= 0) continue;
        pageCapacityByPage[pageIdx] = capacity;
      }
    }
    final orderedPageNumbers = pageCapacityByPage.keys.toList()..sort();

    final cellsByPage = <int, List<HomeworkAnswerGradingCell>>{};
    final scoreByQuestionKey = <String, double>{};
    var fallbackIndex = 0;
    var layoutCursor = 0; // orderedPageNumbers 인덱스
    var layoutRemaining = orderedPageNumbers.isEmpty
        ? 0
        : pageCapacityByPage[orderedPageNumbers.first]!;
    for (final uid in selectedUids) {
      final question = questionByKey[uid];
      if (question == null) continue;
      fallbackIndex += 1;
      final questionIndex = fallbackIndex;
      final rawIndex = int.tryParse(question.displayQuestionNumber.trim());
      final originalQuestionIndex = rawIndex != null && rawIndex > 0
          ? rawIndex
          : (question.sourceOrder > 0 ? question.sourceOrder : fallbackIndex);
      final answerMode = (modeByUid[uid] ?? '').trim().toLowerCase();
      final answer = previewAnswerForMode(question, answerMode).trim();
      final answerRenderKind = answerRenderKindForMode(answerMode);
      final answerRender =
          answerRenderByQuestionIdByKind[answerRenderKind]?[question.id.trim()];
      final textbookSourceRow =
          textbookSourceContext.rowsByQuestionId[question.id.trim()];

      int pageNumber;
      if (orderedPageNumbers.isNotEmpty) {
        while (
            layoutCursor < orderedPageNumbers.length && layoutRemaining <= 0) {
          layoutCursor += 1;
          if (layoutCursor < orderedPageNumbers.length) {
            layoutRemaining =
                pageCapacityByPage[orderedPageNumbers[layoutCursor]] ?? 0;
          }
        }
        if (layoutCursor < orderedPageNumbers.length) {
          pageNumber = orderedPageNumbers[layoutCursor];
          layoutRemaining -= 1;
        } else {
          pageNumber = orderedPageNumbers.last;
        }
      } else {
        pageNumber = question.sourcePage > 0 ? question.sourcePage : 1;
      }

      final key = '${baseItem.id}|pb|$uid';
      final uidScore = question.totalScorePoint ?? presetScoreByUid[uid];
      if (uidScore != null && uidScore.isFinite && uidScore > 0) {
        scoreByQuestionKey[key] = uidScore;
      }
      cellsByPage
          .putIfAbsent(pageNumber, () => <HomeworkAnswerGradingCell>[])
          .add(
            HomeworkAnswerGradingCell(
              key: key,
              questionIndex: questionIndex,
              answer: answer.isEmpty ? '-' : answer,
              answerMode: answerMode,
              answerImageUrl: answerRender?.url ?? '',
              answerImageWidth: answerRender?.width,
              answerImageHeight: answerRender?.height,
              answerImagePixelRatio: answerRender?.pixelRatio,
              answerSourceKind: 'pb_question',
              answerSourceId: question.id.trim(),
              answerRenderPolicy: answerRenderKind,
              answerAssetKind:
                  answerRender == null ? '' : 'unified_answer_render',
              answerRenderStyleVersion: answerRender?.styleVersion ?? '',
              answerPathRaw: textbookSourceContext
                      .pdfPathsByQuestionId[question.id.trim()]?['answer'] ??
                  '',
              solutionPathRaw: textbookSourceContext
                      .pdfPathsByQuestionId[question.id.trim()]?['solution'] ??
                  '',
              solutionPageNumber:
                  _intFromDynamic(textbookSourceRow?['solution_raw_page']) ??
                      _intFromDynamic(
                        textbookSourceRow?['solution_display_page'],
                      ),
              solutionRect1k: _intListFromDynamic(
                textbookSourceRow?['solution_number_region_1k'] ??
                    textbookSourceRow?['solution_content_region_1k'],
              ),
              sourceInfo: _problemBankQuestionSourceInfo(
                question,
                textbookRow: textbookSourceRow,
                originalQuestionIndex: originalQuestionIndex,
              ),
            ),
          );
    }
    if (cellsByPage.isEmpty) return null;
    final gradingPages = cellsByPage.entries
        .map(
          (entry) => HomeworkAnswerGradingPage(
            pageNumber: entry.key,
            cells: entry.value
              ..sort((a, b) => a.questionIndex.compareTo(b.questionIndex)),
          ),
        )
        .toList(growable: false)
      ..sort((a, b) => a.pageNumber.compareTo(b.pageNumber));

    final title =
        baseItem.title.trim().isEmpty ? '답지 확인' : baseItem.title.trim();
    return (
      homeworkId: baseItem.id,
      title: title,
      gradingPages: gradingPages,
      scoreByQuestionKey: scoreByQuestionKey,
      answerPathRaw: textbookSourceContext.answerPathRaw,
      solutionPathRaw: textbookSourceContext.solutionPathRaw,
      answerViewerCacheKey: textbookSourceContext.answerViewerCacheKey,
    );
  }

  int? _intFromDynamic(dynamic raw) {
    if (raw == null) return null;
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse('$raw'.trim());
  }

  double? _doubleFromDynamic(dynamic raw) {
    if (raw == null) return null;
    if (raw is num) return raw.toDouble();
    return double.tryParse('$raw'.trim());
  }

  List<int> _intListFromDynamic(dynamic raw) {
    dynamic source = raw;
    if (source is String) {
      try {
        source = jsonDecode(source);
      } catch (_) {
        source = source
            .split(RegExp(r'[, ]+'))
            .where((part) => part.trim().isNotEmpty)
            .toList();
      }
    }
    if (source is! List) return const <int>[];
    final values = source
        .map((entry) => entry is int ? entry : int.tryParse('$entry'.trim()))
        .whereType<int>()
        .toList(growable: false);
    return values.length >= 4 ? values.take(4).toList() : const <int>[];
  }

  String _trimDynamic(dynamic raw) => '${raw ?? ''}'.trim();

  Map<String, dynamic> _mapFromDynamic(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return raw.map((key, value) => MapEntry('$key', value));
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return decoded.map((key, value) => MapEntry('$key', value));
        }
      } catch (_) {}
    }
    return const <String, dynamic>{};
  }

  Map<String, String> _problemBankQuestionSourceInfo(
    LearningProblemQuestion question, {
    Map<String, dynamic>? textbookRow,
    int? originalQuestionIndex,
  }) {
    String firstNonEmpty(Iterable<dynamic> values) {
      for (final value in values) {
        final text = _trimDynamic(value);
        if (text.isNotEmpty) return text;
      }
      return '';
    }

    final sourceType = question.sourceTypeCode.trim().toLowerCase();
    final cropPage = _mapFromDynamic(
      question.meta['textbook_crop_page'] ?? question.meta['textbookCropPage'],
    );
    final crop = _mapFromDynamic(
      question.meta['textbook_crop'] ?? question.meta['textbookCrop'],
    );
    final contentGroup = _mapFromDynamic(
      textbookRow?['content_group'] ??
          question.meta['textbook_content_group'] ??
          cropPage['content_group'] ??
          crop['contentGroup'],
    );
    final looksLikeExam = sourceType.contains('hwpx') ||
        sourceType.contains('exam') ||
        question.schoolName.trim().isNotEmpty ||
        question.examYear != null ||
        question.examTermLabel.trim().isNotEmpty;
    final originalQuestionNumber =
        originalQuestionIndex != null && originalQuestionIndex > 0
            ? '$originalQuestionIndex'
            : question.displayQuestionNumber;
    final sourceInfo = <String, String>{
      'sourceKind': looksLikeExam ? 'exam' : 'textbook',
      if (looksLikeExam) ...{
        'schoolName': question.schoolName.trim(),
        'year': question.examYear == null ? '' : '${question.examYear}',
        'examName': firstNonEmpty([
          [
            question.semesterLabel.trim(),
            question.examTermLabel.trim(),
          ].where((part) => part.isNotEmpty).join(' '),
          question.documentSourceName,
        ]),
        'originalQuestionNumber': originalQuestionNumber,
      } else ...{
        'bookName': firstNonEmpty([
          question.materialName,
          question.documentSourceName,
          question.publisherName,
        ]),
        'originalQuestionNumber': originalQuestionNumber,
        'difficulty': firstNonEmpty([
          textbookRow?['label'],
          textbookRow?['difficulty_label'],
          textbookRow?['textbook_difficulty_label'],
          question.meta['difficulty_label'],
          question.meta['difficultyLabel'],
          question.meta['textbook_difficulty_label'],
          question.meta['difficulty'],
          question.meta['level'],
          crop['difficulty_label'],
          crop['difficultyLabel'],
          crop['label'],
          cropPage['difficulty_label'],
          cropPage['difficultyLabel'],
          cropPage['label'],
        ]),
        'typeName': firstNonEmpty([
          question.questionType,
          question.meta['type_name'],
          question.meta['problem_type'],
          question.meta['unit_label'],
          textbookRow?['type_group_label'],
          textbookRow?['content_group_label'],
          textbookRow?['content_group_title'],
          contentGroup['label'],
          contentGroup['title'],
          question.courseLabel,
        ]),
      },
    };
    sourceInfo.removeWhere((_, value) => value.trim().isEmpty);
    return sourceInfo;
  }

  ({String bookId, String gradeLabel, String cropId})?
      _problemBankQuestionTextbookRef(LearningProblemQuestion question) {
    String firstNonEmpty(Iterable<dynamic> values) {
      for (final value in values) {
        final text = _trimDynamic(value);
        if (text.isNotEmpty) return text;
      }
      return '';
    }

    final meta = question.meta;
    final cropPage =
        _mapFromDynamic(meta['textbook_crop_page'] ?? meta['textbookCropPage']);
    final crop = _mapFromDynamic(meta['textbook_crop'] ?? meta['textbookCrop']);
    final scope =
        _mapFromDynamic(meta['textbook_scope'] ?? meta['textbookScope']);
    final bookId = firstNonEmpty([
      cropPage['book_id'],
      cropPage['bookId'],
      crop['book_id'],
      crop['bookId'],
      scope['book_id'],
      scope['bookId'],
      meta['book_id'],
      meta['bookId'],
    ]);
    final gradeLabel = firstNonEmpty([
      cropPage['grade_label'],
      cropPage['gradeLabel'],
      crop['grade_label'],
      crop['gradeLabel'],
      scope['grade_label'],
      scope['gradeLabel'],
      meta['grade_label'],
      meta['gradeLabel'],
    ]);
    if (bookId.isEmpty || gradeLabel.isEmpty) return null;
    final cropId = firstNonEmpty([
      cropPage['crop_id'],
      cropPage['cropId'],
      cropPage['id'],
      crop['crop_id'],
      crop['cropId'],
      crop['id'],
      meta['textbook_crop_id'],
      meta['textbookCropId'],
    ]);
    return (bookId: bookId, gradeLabel: gradeLabel, cropId: cropId);
  }

  Future<
      ({
        Map<String, Map<String, dynamic>> rowsByQuestionId,
        Map<String, Map<String, String>> pdfPathsByQuestionId,
        String answerPathRaw,
        String solutionPathRaw,
        String answerViewerCacheKey,
      })> _loadProblemBankTextbookSourceContext({
    required List<LearningProblemQuestion> questions,
    required String homeworkId,
  }) async {
    final refsByQuestionId =
        <String, ({String bookId, String gradeLabel, String cropId})>{};
    final cropIdsByBookGrade = <String, Set<String>>{};
    for (final question in questions) {
      final ref = _problemBankQuestionTextbookRef(question);
      if (ref == null) continue;
      final questionId = question.id.trim();
      if (questionId.isNotEmpty) refsByQuestionId[questionId] = ref;
      if (ref.cropId.isNotEmpty) {
        cropIdsByBookGrade
            .putIfAbsent('${ref.bookId}|${ref.gradeLabel}', () => <String>{})
            .add(ref.cropId);
      }
    }

    final rowsByCropId = <String, Map<String, dynamic>>{};
    for (final entry in cropIdsByBookGrade.entries) {
      final parts = entry.key.split('|');
      if (parts.length < 2 || entry.value.isEmpty) continue;
      final rows =
          await DataManager.instance.loadTextbookProblemRegionsForGrading(
        bookId: parts[0],
        gradeLabel: parts.sublist(1).join('|'),
        cropIds: entry.value,
      );
      for (final row in rows) {
        final cropId = _trimDynamic(row['id']);
        if (cropId.isNotEmpty) rowsByCropId[cropId] = row;
      }
    }

    final rowsByQuestionId = <String, Map<String, dynamic>>{};
    refsByQuestionId.forEach((questionId, ref) {
      final row = rowsByCropId[ref.cropId];
      if (row != null) rowsByQuestionId[questionId] = row;
    });

    var answerPathRaw = '';
    var solutionPathRaw = '';
    var cacheKey = '';
    final pdfPathsByBookGrade = <String, Map<String, String>>{};
    for (final ref in refsByQuestionId.values) {
      final key = '${ref.bookId}|${ref.gradeLabel}';
      if (pdfPathsByBookGrade.containsKey(key)) continue;
      final links = await _resolveTextbookPdfLinksForBookGrade(
        bookId: ref.bookId,
        gradeLabel: ref.gradeLabel,
      );
      final resolvedPaths = await Future.wait<String>([
        _resolveTextbookPdfPathForRightSheet(
          textbookLinks: links,
          kind: 'ans',
        ),
        _resolveTextbookPdfPathForRightSheet(
          textbookLinks: links,
          kind: 'sol',
        ),
      ]);
      final answerPath = resolvedPaths[0];
      final solutionPath = resolvedPaths[1];
      pdfPathsByBookGrade[key] = <String, String>{
        'answer': answerPath,
        'solution': solutionPath,
      };
    }
    final pdfPathsByQuestionId = <String, Map<String, String>>{};
    refsByQuestionId.forEach((questionId, ref) {
      final paths = pdfPathsByBookGrade['${ref.bookId}|${ref.gradeLabel}'];
      if (paths != null) pdfPathsByQuestionId[questionId] = paths;
    });
    if (pdfPathsByBookGrade.isNotEmpty) {
      final paths = pdfPathsByBookGrade.values.first;
      answerPathRaw = paths['answer'] ?? '';
      solutionPathRaw = paths['solution'] ?? '';
      cacheKey =
          'test_pb_textbook:$homeworkId|right_sheet_answer:$answerPathRaw';
    }

    return (
      rowsByQuestionId: rowsByQuestionId,
      pdfPathsByQuestionId: pdfPathsByQuestionId,
      answerPathRaw: answerPathRaw,
      solutionPathRaw: solutionPathRaw,
      answerViewerCacheKey: cacheKey,
    );
  }

  Set<String> _textbookProblemCropIdsFromItem(HomeworkItem item) {
    final out = <String>{};
    for (final rawMapping
        in item.unitMappings ?? const <Map<String, dynamic>>[]) {
      final mapping = Map<String, dynamic>.from(rawMapping);
      final crops = mapping['problemCrops'];
      if (crops is! List) continue;
      for (final rawCrop in crops) {
        if (rawCrop is! Map) continue;
        final cropId = _trimDynamic(rawCrop['cropId']);
        if (cropId.isNotEmpty) out.add(cropId);
      }
    }
    return out;
  }

  Set<int> _textbookProblemPagesFromItem(HomeworkItem item) {
    return homeworkItemDisplayPages(
      page: item.page,
      unitMappings: item.unitMappings,
    );
  }

  int _textbookQuestionIndexFromRow(
    Map<String, dynamic> row,
    int fallbackIndex,
  ) {
    final raw = _trimDynamic(row['problem_number']);
    final exact = int.tryParse(raw);
    if (exact != null && exact > 0) return exact;
    final match = RegExp(r'\d+').firstMatch(raw);
    final parsed = match == null ? null : int.tryParse(match.group(0)!);
    return parsed != null && parsed > 0 ? parsed : fallbackIndex;
  }

  String _textbookQuestionLabelFromRow(Map<String, dynamic> row) {
    final raw = _trimDynamic(row['problem_number']);
    if (raw.isNotEmpty) return raw;
    final questionLabel = _trimDynamic(row['question_label']);
    if (questionLabel.isNotEmpty) return questionLabel;
    return '-';
  }

  /// 개념원리류 교재의 문항 종류 짧은 라벨 (item_name 기반).
  /// 알려진 다섯 종류만 노출하고 그 외에는 빈 문자열.
  String _textbookQuestionCategoryFromRow(Map<String, dynamic> row) {
    final itemName = _trimDynamic(row['item_name']);
    if (itemName.isEmpty) return '';
    if (itemName.contains('개념원리')) return '개념';
    if (itemName.contains('필수')) return '필수';
    if (itemName.contains('확인')) return '확인';
    if (itemName.contains('연습')) return '연습';
    if (itemName.contains('특강')) return '특강';
    return '';
  }

  String _textbookProblemNumberKey(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    final exact = RegExp(r'^\d+$');
    if (!exact.hasMatch(trimmed)) return '';
    final parsed = int.tryParse(trimmed);
    return parsed == null || parsed <= 0 ? '' : '$parsed';
  }

  Set<String> _textbookProblemNumberKeysFromItem(HomeworkItem item) {
    final out = <String>{};
    void collectText(String raw) {
      final marker = RegExp(r'(?:문항|문제)\s*[:：]\s*([^\n\r]+)').firstMatch(raw);
      if (marker == null) return;
      final target = marker.group(1) ?? '';
      for (final match in RegExp(r'\d+').allMatches(target)) {
        final key = _textbookProblemNumberKey(match.group(0) ?? '');
        if (key.isNotEmpty) out.add(key);
      }
    }

    collectText(item.content ?? '');
    for (final rawMapping
        in item.unitMappings ?? const <Map<String, dynamic>>[]) {
      final mapping = Map<String, dynamic>.from(rawMapping);
      final crops = mapping['problemCrops'];
      if (crops is! List) continue;
      for (final rawCrop in crops) {
        if (rawCrop is! Map) continue;
        final crop = Map<String, dynamic>.from(rawCrop);
        final key = _textbookProblemNumberKey('${crop['problemNumber'] ?? ''}');
        if (key.isNotEmpty) out.add(key);
      }
    }
    return out;
  }

  bool _textbookBoolFromDynamic(dynamic raw) {
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    final text = _trimDynamic(raw).toLowerCase();
    return text == 'true' || text == 't' || text == '1' || text == 'yes';
  }

  Future<List<Map<String, dynamic>>> _loadAssignedTextbookProblemRows({
    required List<HomeworkItem> textbookItems,
    required String bookId,
    required String gradeLabel,
  }) async {
    final itemIds = <String>[];
    for (final item in textbookItems) {
      if ((item.bookId ?? '').trim() != bookId ||
          (item.gradeLabel ?? '').trim() != gradeLabel) {
        continue;
      }
      final itemId = item.id.trim();
      if (itemId.isNotEmpty) itemIds.add(itemId);
    }
    if (itemIds.isEmpty) return const <Map<String, dynamic>>[];
    final rows = await DataManager.instance.loadHomeworkItemProblemSnapshots(
      homeworkItemIds: itemIds,
    );
    final out = <Map<String, dynamic>>[];
    for (final row in rows) {
      final cropId = _trimDynamic(row['crop_id']);
      if (cropId.isEmpty) continue;
      out.add(row);
    }
    out.sort((a, b) {
      final itemCompare = _trimDynamic(a['homework_item_id'])
          .compareTo(_trimDynamic(b['homework_item_id']));
      if (itemCompare != 0) return itemCompare;
      final byOrder = (_intFromDynamic(a['sort_order']) ?? 0)
          .compareTo(_intFromDynamic(b['sort_order']) ?? 0);
      if (byOrder != 0) return byOrder;
      return _trimDynamic(a['problem_number'])
          .compareTo(_trimDynamic(b['problem_number']));
    });
    return out;
  }

  String _textbookAnswerModeFromRow(Map<String, dynamic> row) {
    final kind = _trimDynamic(row['answer_kind']).toLowerCase();
    if (kind == 'objective') return 'objective';
    if (kind == 'subjective') return 'subjective';
    if (kind == 'image') return 'image';
    return '';
  }

  String _textbookAnswerTextFromRow(Map<String, dynamic> row) {
    final mode = _textbookAnswerModeFromRow(row);
    if (mode == 'image') {
      final answerText = _trimDynamic(row['answer_text']);
      return answerText.isEmpty ? '[그림]' : answerText;
    }
    if (mode == 'subjective') {
      final latex2d = _trimDynamic(row['answer_latex_2d']);
      if (latex2d.isNotEmpty) return latex2d;
    }
    final answerText = _trimDynamic(row['answer_text']);
    if (answerText.isNotEmpty) return answerText;
    final fallbackLatex = _trimDynamic(row['answer_latex_2d']);
    return fallbackLatex.isEmpty ? '-' : fallbackLatex;
  }

  Map<String, String> _textbookSourceInfoFromRow(
    Map<String, dynamic> row, {
    required HomeworkItem baseItem,
  }) {
    String firstNonEmpty(Iterable<dynamic> values) {
      for (final value in values) {
        final text = _trimDynamic(value);
        if (text.isNotEmpty) return text;
      }
      return '';
    }

    final contentGroupRaw = row['content_group'];
    final contentGroup = contentGroupRaw is Map
        ? Map<String, dynamic>.from(contentGroupRaw)
        : const <String, dynamic>{};
    final cropSnapshot = _mapFromDynamic(row['crop_snapshot']);
    final bookName = _extractHomeworkBookName(baseItem);
    final sourceInfo = <String, String>{
      'sourceKind': 'textbook',
      'bookName': bookName == '-' ? '' : bookName,
      'originalQuestionNumber': firstNonEmpty([
        row['problem_number'],
        row['question_label'],
      ]),
      'difficulty': firstNonEmpty([
        row['label'],
        row['difficulty_label'],
        row['textbook_difficulty_label'],
        row['difficultyLabel'],
        cropSnapshot['label'],
        cropSnapshot['difficulty_label'],
        cropSnapshot['difficultyLabel'],
      ]),
      'typeName': firstNonEmpty([
        row['type_group_label'],
        row['type_name'],
        row['problem_type_name'],
        row['content_group_label'],
        contentGroup['label'],
        cropSnapshot['typeGroupLabel'],
        cropSnapshot['contentGroupLabel'],
        row['content_group_title'],
        contentGroup['title'],
        cropSnapshot['contentGroupTitle'],
      ]),
    };
    sourceInfo.removeWhere((_, value) => value.trim().isEmpty);
    return sourceInfo;
  }

  Future<
      ({
        String homeworkId,
        String title,
        List<HomeworkAnswerGradingPage> gradingPages,
        Map<String, double> scoreByQuestionKey,
        String answerPathRaw,
        String solutionPathRaw,
        String answerViewerCacheKey,
      })?> _resolveTextbookProblemGradingPayload({
    required HomeworkItem seedHomework,
    required List<({String studentId, String itemId})> keys,
  }) async {
    final seenItemIds = <String>{};
    final allItems = <HomeworkItem>[];
    for (final key in keys) {
      final item = HomeworkStore.instance.getById(key.studentId, key.itemId);
      if (item == null) continue;
      if (!seenItemIds.add(item.id)) continue;
      allItems.add(item);
    }
    if (allItems.isEmpty) {
      allItems.add(seedHomework);
    }
    final textbookItems =
        allItems.where(_hasDirectHomeworkTextbookLink).toList(growable: false);
    if (textbookItems.isEmpty) return null;

    final baseItem = textbookItems.firstWhere(
      (item) => item.id == seedHomework.id,
      orElse: () => textbookItems.first,
    );
    final bookId = (baseItem.bookId ?? '').trim();
    final gradeLabel = (baseItem.gradeLabel ?? '').trim();
    if (bookId.isEmpty || gradeLabel.isEmpty) return null;
    final textbookLinks = await _resolveHomeworkPdfLinks(
      baseItem,
      allowFlowFallback: true,
    );
    // 시트 오픈을 PDF 다운로드/resolve에 묶지 않는다.
    // 실제 로컬 변환은 시트 자동 오픈(_openSessionAnswerSheet)에서 한다.
    final answerPathRaw = textbookLinks.answerPathRaw.trim();
    final solutionPathRaw = textbookLinks.solutionPathRaw.trim();

    final assignedRows = await _loadAssignedTextbookProblemRows(
      textbookItems: textbookItems,
      bookId: bookId,
      gradeLabel: gradeLabel,
    );
    final assignedRowsByCropId = <String, Map<String, dynamic>>{};
    for (final row in assignedRows) {
      final cropId = _trimDynamic(row['crop_id']);
      if (cropId.isNotEmpty) assignedRowsByCropId[cropId] = row;
    }

    final cropIds = <String>{};
    final displayPages = <int>{};
    final problemNumberKeys = <String>{};
    if (assignedRowsByCropId.isNotEmpty) {
      cropIds.addAll(assignedRowsByCropId.keys);
    } else {
      for (final item in textbookItems) {
        if ((item.bookId ?? '').trim() != bookId ||
            (item.gradeLabel ?? '').trim() != gradeLabel) {
          continue;
        }
        problemNumberKeys.addAll(_textbookProblemNumberKeysFromItem(item));
        final itemCropIds = _textbookProblemCropIdsFromItem(item);
        if (itemCropIds.isNotEmpty) {
          cropIds.addAll(itemCropIds);
        } else {
          displayPages.addAll(_textbookProblemPagesFromItem(item));
        }
      }
    }
    if (cropIds.isEmpty && displayPages.isEmpty) return null;

    final rowsByCropId = <String, Map<String, dynamic>>{};
    if (cropIds.isNotEmpty) {
      final rows =
          await DataManager.instance.loadTextbookProblemRegionsForGrading(
        bookId: bookId,
        gradeLabel: gradeLabel,
        cropIds: cropIds,
      );
      for (final row in rows) {
        final cropId = _trimDynamic(row['id']);
        if (cropId.isNotEmpty) {
          final assigned = assignedRowsByCropId[cropId];
          if (assigned != null) {
            row.addAll(assigned);
            row['id'] = cropId;
            row['display_page'] = assigned['display_page'] ??
                assigned['page_number'] ??
                row['display_page'];
            row['raw_page'] = assigned['raw_page'] ?? row['raw_page'];
            row['pb_question_uid'] =
                _trimDynamic(assigned['pb_question_uid']).isNotEmpty
                    ? assigned['pb_question_uid']
                    : row['pb_question_uid'];
          }
          rowsByCropId[cropId] = row;
        }
      }
    }
    if (displayPages.isNotEmpty) {
      final rows =
          await DataManager.instance.loadTextbookProblemRegionsForGrading(
        bookId: bookId,
        gradeLabel: gradeLabel,
        displayPages: displayPages,
      );
      for (final row in rows) {
        if (problemNumberKeys.isNotEmpty) {
          final numberKey =
              _textbookProblemNumberKey(_trimDynamic(row['problem_number']));
          if (!problemNumberKeys.contains(numberKey)) continue;
        }
        final cropId = _trimDynamic(row['id']);
        if (cropId.isNotEmpty) rowsByCropId.putIfAbsent(cropId, () => row);
      }
    }
    if (rowsByCropId.isEmpty) return null;

    final rows = rowsByCropId.values.toList(growable: false)
      ..sort((a, b) {
        final aOrder = _intFromDynamic(a['sort_order']);
        final bOrder = _intFromDynamic(b['sort_order']);
        if (aOrder != null && bOrder != null && aOrder != bOrder) {
          return aOrder.compareTo(bOrder);
        }
        final byPage = (_intFromDynamic(a['display_page']) ??
                _intFromDynamic(a['raw_page']) ??
                0)
            .compareTo(_intFromDynamic(b['display_page']) ??
                _intFromDynamic(b['raw_page']) ??
                0);
        if (byPage != 0) return byPage;
        return _trimDynamic(a['problem_number'])
            .compareTo(_trimDynamic(b['problem_number']));
      });

    final cellsByPage = <int, List<HomeworkAnswerGradingCell>>{};
    var fallbackIndex = 0;
    for (final row in rows) {
      fallbackIndex += 1;
      if (_textbookBoolFromDynamic(row['is_set_header'])) continue;
      final pageNumber = _intFromDynamic(row['display_page']) ??
          _intFromDynamic(row['raw_page']);
      if (pageNumber == null || pageNumber <= 0) continue;
      final cropId = _trimDynamic(row['id']);
      if (cropId.isEmpty) continue;
      final questionIndex = _textbookQuestionIndexFromRow(row, fallbackIndex);
      final questionUid = _trimDynamic(row['pb_question_uid']).isNotEmpty
          ? _trimDynamic(row['pb_question_uid'])
          : cropId;
      final key = '${baseItem.id}|$pageNumber|$questionIndex|$questionUid';
      final answerKind = _trimDynamic(row['answer_kind']).toLowerCase();
      final renderStyleVersion =
          _trimDynamic(row['answer_render_style_version']);
      cellsByPage
          .putIfAbsent(pageNumber, () => <HomeworkAnswerGradingCell>[])
          .add(
            HomeworkAnswerGradingCell(
              key: key,
              questionIndex: questionIndex,
              questionLabel: _textbookQuestionLabelFromRow(row),
              questionCategory: _textbookQuestionCategoryFromRow(row),
              answer: _textbookAnswerTextFromRow(row),
              answerMode: _textbookAnswerModeFromRow(row),
              answerImageUrl: _trimDynamic(row['answer_image_url']),
              answerImageWidth: _intFromDynamic(row['answer_image_width_px']),
              answerImageHeight: _intFromDynamic(row['answer_image_height_px']),
              answerImagePixelRatio:
                  _doubleFromDynamic(row['answer_render_pixel_ratio']),
              answerSourceKind: 'textbook_crop',
              answerSourceId: cropId,
              answerAssetKind: answerKind == 'image'
                  ? 'raw_answer_image'
                  : (renderStyleVersion.isEmpty ? '' : 'unified_answer_render'),
              answerRenderStyleVersion: renderStyleVersion,
              answerPageNumber: _intFromDynamic(row['answer_raw_page']) ??
                  _intFromDynamic(row['answer_display_page']),
              answerRect1k: _intListFromDynamic(row['answer_bbox_1k']),
              focusRect1k: _intListFromDynamic(
                row['item_region_1k'] ?? row['bbox_1k'],
              ),
              solutionPageNumber: _intFromDynamic(row['solution_raw_page']) ??
                  _intFromDynamic(row['solution_display_page']),
              solutionRect1k: _intListFromDynamic(
                row['solution_number_region_1k'] ??
                    row['solution_content_region_1k'],
              ),
              sourceInfo: _textbookSourceInfoFromRow(
                row,
                baseItem: baseItem,
              ),
            ),
          );
    }
    if (cellsByPage.isEmpty) return null;

    final gradingPages = cellsByPage.entries
        .map(
          (entry) => HomeworkAnswerGradingPage(
            pageNumber: entry.key,
            cells: entry.value
              ..sort((a, b) => a.questionIndex.compareTo(b.questionIndex)),
          ),
        )
        .toList(growable: false)
      ..sort((a, b) => a.pageNumber.compareTo(b.pageNumber));
    final title =
        baseItem.title.trim().isEmpty ? '교재 문항 채점' : baseItem.title.trim();
    return (
      homeworkId: baseItem.id,
      title: title,
      gradingPages: gradingPages,
      scoreByQuestionKey: const <String, double>{},
      answerPathRaw: answerPathRaw,
      solutionPathRaw: solutionPathRaw,
      answerViewerCacheKey:
          'textbook_problem:${baseItem.id}|right_sheet_answer:$answerPathRaw',
    );
  }

  String _resolveGradingGroupTitleForPending({
    required List<({String studentId, String itemId})> keys,
    required HomeworkItem fallbackHomework,
    required String payloadTitle,
  }) {
    final homeworkStore = HomeworkStore.instance;
    for (final key in keys) {
      final item = homeworkStore.getById(key.studentId, key.itemId);
      if (item == null) continue;
      final groupId = (homeworkStore.groupIdOfItem(item.id) ?? '').trim();
      if (groupId.isEmpty) continue;
      final group = homeworkStore.groupById(key.studentId, groupId);
      final title = (group?.title ?? '').trim();
      if (title.isNotEmpty) return title;
    }
    final fallbackGroupId =
        (homeworkStore.groupIdOfItem(fallbackHomework.id) ?? '').trim();
    if (fallbackGroupId.isNotEmpty) {
      final group = homeworkStore.groupById(
        keys.isNotEmpty ? keys.first.studentId : '',
        fallbackGroupId,
      );
      final title = (group?.title ?? '').trim();
      if (title.isNotEmpty) return title;
    }
    final fallbackTitle = fallbackHomework.title.trim();
    if (fallbackTitle.isNotEmpty) return fallbackTitle;
    final safePayloadTitle = payloadTitle.trim();
    return safePayloadTitle.isEmpty ? '그룹 과제' : safePayloadTitle;
  }

  String _safeAssignmentCodeForGrading(HomeworkItem homework) {
    final normalizedAssignmentCode = (homework.assignmentCode ?? '')
        .trim()
        .toUpperCase()
        .replaceAll(RegExp(r'[^A-Z0-9]'), '');
    return RegExp(r'^(CL|PL|FL|EL)[A-Z]{2}[0-9]{4}$')
            .hasMatch(normalizedAssignmentCode)
        ? normalizedAssignmentCode
        : '';
  }

  Future<_ResolvedHomeworkPdfLinks> _resolveTextbookPdfLinksForBookGrade({
    required String bookId,
    required String gradeLabel,
  }) async {
    final safeBookId = bookId.trim();
    final safeGradeLabel = gradeLabel.trim();
    if (safeBookId.isEmpty || safeGradeLabel.isEmpty) {
      return const _ResolvedHomeworkPdfLinks(
        bookId: '',
        gradeLabel: '',
        bodyPathRaw: '',
        answerPathRaw: '',
        solutionPathRaw: '',
      );
    }
    try {
      final links =
          await DataManager.instance.loadResourceFileLinks(safeBookId);
      return _ResolvedHomeworkPdfLinks(
        bookId: safeBookId,
        gradeLabel: safeGradeLabel,
        bodyPathRaw: (links['$safeGradeLabel#body'] ?? '').trim(),
        answerPathRaw: (links['$safeGradeLabel#ans'] ?? '').trim(),
        solutionPathRaw: (links['$safeGradeLabel#sol'] ?? '').trim(),
      );
    } catch (_) {
      return _ResolvedHomeworkPdfLinks(
        bookId: safeBookId,
        gradeLabel: safeGradeLabel,
        bodyPathRaw: '',
        answerPathRaw: '',
        solutionPathRaw: '',
      );
    }
  }

  Future<Map<String, String>> _rawRightSheetAnswerViewerLinks({
    required String studentId,
    required HomeworkItem hw,
  }) async {
    final textbookLinks = await _resolveHomeworkPdfLinks(
      hw,
      allowFlowFallback: true,
    );
    final answerPathRaw = textbookLinks.answerPathRaw.trim();
    final solutionPathRaw = textbookLinks.solutionPathRaw.trim();
    return <String, String>{
      'answerPathRaw': answerPathRaw,
      'solutionPathRaw': solutionPathRaw,
      'cacheKey': 'student:$studentId|right_sheet_answer:$answerPathRaw',
    };
  }

  Future<Map<String, String>> _resolveRightSheetAnswerViewerLinks({
    required String studentId,
    required HomeworkItem hw,
  }) async {
    final textbookLinks = await _resolveHomeworkPdfLinks(
      hw,
      allowFlowFallback: true,
    );
    final resolvedPaths = await Future.wait<String>([
      _resolveTextbookPdfPathForRightSheet(
        textbookLinks: textbookLinks,
        kind: 'ans',
      ),
      _resolveTextbookPdfPathForRightSheet(
        textbookLinks: textbookLinks,
        kind: 'sol',
      ),
    ]);
    final answerPathRaw = resolvedPaths[0];
    final solutionPathRaw = resolvedPaths[1];
    final rawAnswerPath = textbookLinks.answerPathRaw.trim();
    // 시트/세션 cacheKey는 raw storage key 기준으로 통일하고,
    // putPdfLinks 값만 로컬 경로로 채워 이후 오픈이 바로 히트되게 한다.
    return <String, String>{
      'answerPathRaw': answerPathRaw,
      'solutionPathRaw': solutionPathRaw,
      'cacheKey': 'student:$studentId|right_sheet_answer:$rawAnswerPath',
      'rawAnswerPathRaw': rawAnswerPath,
      'rawSolutionPathRaw': textbookLinks.solutionPathRaw.trim(),
    };
  }

  Future<String> _resolveTextbookPdfPathForRightSheet({
    required _ResolvedHomeworkPdfLinks textbookLinks,
    required String kind,
  }) async {
    final normalizedKind = kind.trim().toLowerCase();
    final raw = normalizedKind == 'sol'
        ? textbookLinks.solutionPathRaw.trim()
        : textbookLinks.answerPathRaw.trim();
    if (raw.isEmpty || _isWebUrl(raw)) return raw;
    try {
      final source = await TextbookPdfService.instance.resolve(
        TextbookPdfRef(
          fileId: textbookLinks.bookId,
          gradeLabel: textbookLinks.gradeLabel,
          kind: normalizedKind == 'sol' ? 'sol' : 'ans',
          storageKey: _textbookStorageKeyFromRaw(raw),
        ),
      );
      return (source.localPath ?? source.url ?? '').trim();
    } catch (_) {
      return raw;
    }
  }

  Future<bool> _openPreloadedRightSheetSession({
    required BuildContext context,
    required String studentId,
    required HomeworkItem hw,
    required List<({String studentId, String itemId})> keys,
    required RightSheetPreloadedSessionPayload payload,
  }) async {
    final cachedStates =
        _testGradingDraftStatesByHomeworkId[payload.homeworkId] ??
            const <String, HomeworkAnswerCellState>{};
    final savedSession =
        await _gradingResultService.loadLatestSavedSessionForHomework(
      homeworkItemId: payload.homeworkId,
    );
    final baselineSession =
        await _gradingResultService.loadFirstSavedSessionForHomework(
      homeworkItemId: payload.homeworkId,
    );
    if (!context.mounted || !mounted) return true;
    final initialStates = savedSession?.states.isNotEmpty == true
        ? savedSession!.states
        : cachedStates;
    final hasSavedGrading = savedSession != null ||
        _testGradingSavedHomeworkIds.contains(payload.homeworkId);
    final baselineStates = _retryBaselineStates(baselineSession);

    rightSideSheetTestGradingSession.value = RightSideSheetTestGradingSession(
      sessionId: payload.sessionId,
      title: payload.title,
      studentName: payload.studentName,
      groupHomeworkTitle: payload.groupHomeworkTitle,
      assignmentCode: payload.assignmentCode,
      gradingPages: _toRightSheetGradingPages(payload.gradingPages),
      scoreByQuestionKey: payload.scoreByQuestionKey,
      overlayEntries: payload.overlayEntries,
      answerPathRaw: payload.answerPathRaw,
      solutionPathRaw: payload.solutionPathRaw,
      answerViewerCacheKey: payload.answerViewerCacheKey,
      initialStates: _toRightSheetStateMap(initialStates),
      initialCorrectionStates:
          savedSession?.correctionStates ?? const <String, String>{},
      correctionAttemptNumbers:
          savedSession?.correctionAttemptNumbers ?? const <String, int>{},
      baselineAttemptId: baselineSession?.attempt.id ?? '',
      baselineStates: _toRightSheetStateMap(baselineStates),
      // 재검사: 틀린것만 보기 ON. OFF면 gradingPages 전체(이전 정답 포함)가 다시 보인다.
      wrongOnlyDefault: hasSavedGrading && baselineStates.isNotEmpty,
      gradingLocked: hasSavedGrading,
      smartConfirmAction: true,
      showSearchChrome: false,
      onRequestEditReset: () async {
        final reset = await _gradingResultService.resetAttemptsForHomework(
          homeworkItemId: payload.homeworkId,
        );
        if (!mounted) return false;
        if (!reset) {
          _showHomeworkChipSnackBar(this.context, '기존 채점 결과 리셋에 실패했습니다.');
          return false;
        }
        _testGradingDraftStatesByHomeworkId.remove(payload.homeworkId);
        _testGradingSerializedDraftByHomeworkId.remove(payload.homeworkId);
        _testGradingSavedHomeworkIds.remove(payload.homeworkId);
        _showHomeworkChipSnackBar(
          this.context,
          '기존 채점 결과를 리셋했습니다. 다시 확인하면 새 결과로 저장됩니다.',
        );
        return true;
      },
      onStatesChanged: (states) {
        final decoded = _fromRightSheetStateMap(states);
        _testGradingDraftStatesByHomeworkId[payload.homeworkId] =
            Map<String, HomeworkAnswerCellState>.from(decoded);
        _testGradingSerializedDraftByHomeworkId[payload.homeworkId] =
            _serializeTestGradingDraftRows(
          homeworkId: payload.homeworkId,
          gradingPages: payload.gradingPages,
          states: decoded,
        );
      },
      onAction: (action, states, correctionStates) async {
        if (!mounted) return;
        final decoded = _fromRightSheetStateMap(states);
        _testGradingDraftStatesByHomeworkId[payload.homeworkId] =
            Map<String, HomeworkAnswerCellState>.from(decoded);
        _testGradingSerializedDraftByHomeworkId[payload.homeworkId] =
            _serializeTestGradingDraftRows(
          homeworkId: payload.homeworkId,
          gradingPages: payload.gradingPages,
          states: decoded,
        );
        var savedGrading = true;
        if (action == 'complete' || action == 'confirm') {
          final targetItem = HomeworkStore.instance.getById(
                studentId,
                payload.homeworkId,
              ) ??
              hw;
          final saved = await _gradingResultService.saveAttemptFromSession(
            studentId: studentId,
            homeworkItem: targetItem,
            action: action,
            states: decoded,
            gradingPages: payload.gradingPages,
            scoreByQuestionKey: payload.scoreByQuestionKey,
            groupHomeworkTitleSnapshot: payload.groupHomeworkTitle,
            baselineAttemptId: baselineSession?.attempt.id ?? '',
            baselineStates: baselineStates,
            correctionStates: correctionStates,
          );
          if (!mounted) return;
          if (!saved) {
            savedGrading = false;
            _showHomeworkChipSnackBar(this.context, '채점 결과 저장에 실패했습니다.');
          } else {
            _testGradingSavedHomeworkIds.add(payload.homeworkId);
            _gradingProgressRevisionByStudent.remove(studentId);
            _gradingProgressFutureByStudent.remove(studentId);
          }
        }
        if (savedGrading && (action == 'complete' || action == 'confirm')) {
          savedGrading = await _finalizeDirectStructuredHomeworkCheck(
            studentId: studentId,
            keys: keys,
            states: decoded,
            gradingPages: payload.gradingPages,
            onCheckRecorded: () => _markPendingConfirms(
              keys: keys,
              action: action,
              structuredGrading: true,
            ),
          );
          if (!savedGrading && mounted) {
            _showHomeworkChipSnackBar(
              this.context,
              '숙제 검사 이력 저장에 실패했습니다.',
            );
          }
        }
        if (!mounted || !savedGrading) return;
        _markPendingConfirms(keys: keys, action: action);
      },
    );
    blockRightSideSheetOpen.value = false;
    if (!rightSideSheetOpen.value) {
      final toggleAction = toggleRightSideSheetAction;
      if (toggleAction != null) {
        await toggleAction();
      }
    }
    return true;
  }

  Future<void> _handleSubmittedChipTapForPending({
    required BuildContext context,
    required String studentId,
    required HomeworkItem hw,
    List<({String studentId, String itemId})>? targetKeys,
  }) async {
    final keys = (targetKeys == null || targetKeys.isEmpty)
        ? <({String studentId, String itemId})>[
            (studentId: studentId, itemId: hw.id),
          ]
        : targetKeys;
    if (keys.isEmpty) return;
    final allSelected = keys.every(_pendingConfirms.containsKey);
    if (allSelected) {
      if (keys.any(_structuredPendingConfirmKeys.contains)) {
        await _cancelPendingStructuredGrading(
          context: context,
          keys: keys,
        );
        return;
      }
      setState(() {
        for (final key in keys) {
          _pendingConfirms.remove(key);
        }
      });
      return;
    }

    if (keys.length == 1) {
      final preloadedPayload =
          RightSheetAnswerPreloadService.instance.getSessionPayload(
        _rightSheetSessionPayloadCacheKey(studentId: studentId, hw: hw),
      );
      if (preloadedPayload != null) {
        final opened = await _openPreloadedRightSheetSession(
          context: context,
          studentId: studentId,
          hw: hw,
          keys: keys,
          payload: preloadedPayload,
        );
        if (opened) return;
      }
    }

    final overlayEntries = _buildOverlayEntriesForPendingKeys(
      keys: keys,
      fallbackHomework: hw,
    );
    final hasPbCandidate = keys.any((key) {
      final item = HomeworkStore.instance.getById(key.studentId, key.itemId);
      if (item == null) return false;
      return (item.pbPresetId ?? '').trim().isNotEmpty;
    });
    if (hasPbCandidate) {
      final payload = await _resolveTestPbGradingViewerPayload(
        seedHomework: hw,
        keys: keys,
      );
      if (!context.mounted) return;
      if (payload != null) {
        final cachedStates =
            _testGradingDraftStatesByHomeworkId[payload.homeworkId] ??
                const <String, HomeworkAnswerCellState>{};
        final savedSession =
            await _gradingResultService.loadLatestSavedSessionForHomework(
          homeworkItemId: payload.homeworkId,
        );
        final baselineSession =
            await _gradingResultService.loadFirstSavedSessionForHomework(
          homeworkItemId: payload.homeworkId,
        );
        if (!context.mounted) return;
        final initialStates = savedSession?.states.isNotEmpty == true
            ? savedSession!.states
            : cachedStates;
        final hasSavedGrading = savedSession != null ||
            _testGradingSavedHomeworkIds.contains(payload.homeworkId);
        final baselineStates = _retryBaselineStates(baselineSession);
        final homeworkStore = HomeworkStore.instance;
        final studentName = _resolveHomeworkPrintStudentName(studentId);
        final groupHomeworkTitle = () {
          for (final key in keys) {
            final item = homeworkStore.getById(key.studentId, key.itemId);
            if (item == null) continue;
            final groupId = (homeworkStore.groupIdOfItem(item.id) ?? '').trim();
            if (groupId.isEmpty) continue;
            final group = homeworkStore.groupById(key.studentId, groupId);
            final title = (group?.title ?? '').trim();
            if (title.isNotEmpty) return title;
          }
          final fallbackGroupId =
              (homeworkStore.groupIdOfItem(hw.id) ?? '').trim();
          if (fallbackGroupId.isNotEmpty) {
            final group = homeworkStore.groupById(studentId, fallbackGroupId);
            final title = (group?.title ?? '').trim();
            if (title.isNotEmpty) return title;
          }
          final fallbackTitle = hw.title.trim();
          if (fallbackTitle.isNotEmpty) return fallbackTitle;
          final payloadTitle = payload.title.trim();
          return payloadTitle.isEmpty ? '그룹 과제' : payloadTitle;
        }();
        final rawAssignmentCode = (hw.assignmentCode ?? '').trim();
        final normalizedAssignmentCode = rawAssignmentCode
            .toUpperCase()
            .replaceAll(RegExp(r'[^A-Z0-9]'), '');
        final safeAssignmentCode = RegExp(r'^(CL|PL|FL|EL)[A-Z]{2}[0-9]{4}$')
                .hasMatch(normalizedAssignmentCode)
            ? normalizedAssignmentCode
            : '';
        // PDF 로컬 resolve는 시트 오픈 뒤에 맡긴다.
        final gradingPdfLinks = await _rawRightSheetAnswerViewerLinks(
          studentId: studentId,
          hw: hw,
        );
        if (!mounted) return;
        rightSideSheetTestGradingSession.value =
            RightSideSheetTestGradingSession(
          sessionId: 'student:$studentId|test_pb_grade:${payload.homeworkId}',
          title: payload.title,
          studentName: studentName,
          groupHomeworkTitle: groupHomeworkTitle,
          assignmentCode: safeAssignmentCode,
          gradingPages: _toRightSheetGradingPages(payload.gradingPages),
          scoreByQuestionKey: payload.scoreByQuestionKey,
          overlayEntries: overlayEntries
              .map(
                (entry) => <String, String>{
                  'title': entry.title,
                  'page': entry.page,
                  'memo': entry.memo,
                },
              )
              .toList(growable: false),
          answerPathRaw: payload.answerPathRaw.trim().isNotEmpty
              ? payload.answerPathRaw
              : (gradingPdfLinks['answerPathRaw'] ?? ''),
          solutionPathRaw: payload.solutionPathRaw.trim().isNotEmpty
              ? payload.solutionPathRaw
              : (gradingPdfLinks['solutionPathRaw'] ?? ''),
          answerViewerCacheKey: payload.answerViewerCacheKey.trim().isNotEmpty
              ? payload.answerViewerCacheKey
              : (gradingPdfLinks['cacheKey'] ?? ''),
          initialStates: _toRightSheetStateMap(initialStates),
          initialCorrectionStates:
              savedSession?.correctionStates ?? const <String, String>{},
          correctionAttemptNumbers:
              savedSession?.correctionAttemptNumbers ?? const <String, int>{},
          baselineAttemptId: baselineSession?.attempt.id ?? '',
          baselineStates: _toRightSheetStateMap(baselineStates),
          // 재검사: 틀린것만 보기 ON. OFF면 gradingPages 전체(이전 정답 포함)가 다시 보인다.
          wrongOnlyDefault: hasSavedGrading && baselineStates.isNotEmpty,
          gradingLocked: hasSavedGrading,
          smartConfirmAction: true,
          showSearchChrome: false,
          onRequestEditReset: () async {
            final reset = await _gradingResultService.resetAttemptsForHomework(
              homeworkItemId: payload.homeworkId,
            );
            if (!mounted) return false;
            if (!reset) {
              _showHomeworkChipSnackBar(this.context, '기존 채점 결과 리셋에 실패했습니다.');
              return false;
            }
            _testGradingDraftStatesByHomeworkId.remove(payload.homeworkId);
            _testGradingSerializedDraftByHomeworkId.remove(payload.homeworkId);
            _testGradingSavedHomeworkIds.remove(payload.homeworkId);
            _showHomeworkChipSnackBar(
              this.context,
              '기존 채점 결과를 리셋했습니다. 다시 확인하면 새 결과로 저장됩니다.',
            );
            return true;
          },
          onStatesChanged: (states) {
            final decoded = _fromRightSheetStateMap(states);
            _testGradingDraftStatesByHomeworkId[payload.homeworkId] =
                Map<String, HomeworkAnswerCellState>.from(decoded);
            _testGradingSerializedDraftByHomeworkId[payload.homeworkId] =
                _serializeTestGradingDraftRows(
              homeworkId: payload.homeworkId,
              gradingPages: payload.gradingPages,
              states: decoded,
            );
          },
          onAction: (action, states, correctionStates) async {
            if (!mounted) return;
            final decoded = _fromRightSheetStateMap(states);
            _testGradingDraftStatesByHomeworkId[payload.homeworkId] =
                Map<String, HomeworkAnswerCellState>.from(decoded);
            _testGradingSerializedDraftByHomeworkId[payload.homeworkId] =
                _serializeTestGradingDraftRows(
              homeworkId: payload.homeworkId,
              gradingPages: payload.gradingPages,
              states: decoded,
            );
            var savedGrading = true;
            if (action == 'complete' || action == 'confirm') {
              final targetItem = HomeworkStore.instance.getById(
                    studentId,
                    payload.homeworkId,
                  ) ??
                  hw;
              final saved = await _gradingResultService.saveAttemptFromSession(
                studentId: studentId,
                homeworkItem: targetItem,
                action: action,
                states: decoded,
                gradingPages: payload.gradingPages,
                scoreByQuestionKey: payload.scoreByQuestionKey,
                groupHomeworkTitleSnapshot: groupHomeworkTitle,
                baselineAttemptId: baselineSession?.attempt.id ?? '',
                baselineStates: baselineStates,
                correctionStates: correctionStates,
              );
              if (!mounted) return;
              if (!saved) {
                savedGrading = false;
                _showHomeworkChipSnackBar(this.context, '채점 결과 저장에 실패했습니다.');
              } else {
                _testGradingSavedHomeworkIds.add(payload.homeworkId);
                _gradingProgressRevisionByStudent.remove(studentId);
                _gradingProgressFutureByStudent.remove(studentId);
              }
            }
            if (savedGrading && (action == 'complete' || action == 'confirm')) {
              savedGrading = await _finalizeDirectStructuredHomeworkCheck(
                studentId: studentId,
                keys: keys,
                states: decoded,
                gradingPages: payload.gradingPages,
                onCheckRecorded: () => _markPendingConfirms(
                  keys: keys,
                  action: action,
                  structuredGrading: true,
                ),
              );
              if (!savedGrading && mounted) {
                _showHomeworkChipSnackBar(
                  this.context,
                  '숙제 검사 이력 저장에 실패했습니다.',
                );
              }
            }
            if (!mounted || !savedGrading) return;
            _markPendingConfirms(keys: keys, action: action);
          },
        );
        blockRightSideSheetOpen.value = false;
        if (!rightSideSheetOpen.value) {
          final toggleAction = toggleRightSideSheetAction;
          if (toggleAction != null) {
            await toggleAction();
          }
        }
        return;
      }
      _showHomeworkChipSnackBar(context, '테스트 답안 매핑에 실패해 기본 답지 흐름으로 전환했어요.');
    }

    final textbookProblemPayload = await _resolveTextbookProblemGradingPayload(
      seedHomework: hw,
      keys: keys,
    );
    if (!context.mounted) return;
    if (textbookProblemPayload != null) {
      final cachedStates = _testGradingDraftStatesByHomeworkId[
              textbookProblemPayload.homeworkId] ??
          const <String, HomeworkAnswerCellState>{};
      final savedSession =
          await _gradingResultService.loadLatestSavedSessionForHomework(
        homeworkItemId: textbookProblemPayload.homeworkId,
      );
      final baselineSession =
          await _gradingResultService.loadFirstSavedSessionForHomework(
        homeworkItemId: textbookProblemPayload.homeworkId,
      );
      if (!context.mounted) return;
      final initialStates = savedSession?.states.isNotEmpty == true
          ? savedSession!.states
          : cachedStates;
      final hasSavedGrading = savedSession != null ||
          _testGradingSavedHomeworkIds
              .contains(textbookProblemPayload.homeworkId);
      final baselineStates = _retryBaselineStates(baselineSession);
      final studentName = _resolveHomeworkPrintStudentName(studentId);
      final groupHomeworkTitle = _resolveGradingGroupTitleForPending(
        keys: keys,
        fallbackHomework: hw,
        payloadTitle: textbookProblemPayload.title,
      );
      if (!mounted) return;
      rightSideSheetTestGradingSession.value = RightSideSheetTestGradingSession(
        sessionId:
            'student:$studentId|textbook_problem_grade:${textbookProblemPayload.homeworkId}',
        title: textbookProblemPayload.title,
        studentName: studentName,
        groupHomeworkTitle: groupHomeworkTitle,
        assignmentCode: _safeAssignmentCodeForGrading(hw),
        gradingPages: _toRightSheetGradingPages(
          textbookProblemPayload.gradingPages,
        ),
        scoreByQuestionKey: textbookProblemPayload.scoreByQuestionKey,
        overlayEntries: overlayEntries
            .map(
              (entry) => <String, String>{
                'title': entry.title,
                'page': entry.page,
                'memo': entry.memo,
              },
            )
            .toList(growable: false),
        answerPathRaw: textbookProblemPayload.answerPathRaw,
        solutionPathRaw: textbookProblemPayload.solutionPathRaw,
        answerViewerCacheKey: textbookProblemPayload.answerViewerCacheKey,
        initialStates: _toRightSheetStateMap(initialStates),
        initialCorrectionStates:
            savedSession?.correctionStates ?? const <String, String>{},
        correctionAttemptNumbers:
            savedSession?.correctionAttemptNumbers ?? const <String, int>{},
        baselineAttemptId: baselineSession?.attempt.id ?? '',
        baselineStates: _toRightSheetStateMap(baselineStates),
        // 재검사: 틀린것만 보기 ON. OFF면 gradingPages 전체(이전 정답 포함)가 다시 보인다.
        wrongOnlyDefault: hasSavedGrading && baselineStates.isNotEmpty,
        gradingLocked: hasSavedGrading,
        smartConfirmAction: true,
        showSearchChrome: false,
        onRequestEditReset: () async {
          final reset = await _gradingResultService.resetAttemptsForHomework(
            homeworkItemId: textbookProblemPayload.homeworkId,
          );
          if (!mounted) return false;
          if (!reset) {
            _showHomeworkChipSnackBar(this.context, '기존 채점 결과 리셋에 실패했습니다.');
            return false;
          }
          _testGradingDraftStatesByHomeworkId.remove(
            textbookProblemPayload.homeworkId,
          );
          _testGradingSerializedDraftByHomeworkId.remove(
            textbookProblemPayload.homeworkId,
          );
          _testGradingSavedHomeworkIds
              .remove(textbookProblemPayload.homeworkId);
          _showHomeworkChipSnackBar(
            this.context,
            '기존 채점 결과를 리셋했습니다. 다시 확인하면 새 결과로 저장됩니다.',
          );
          return true;
        },
        onStatesChanged: (states) {
          final decoded = _fromRightSheetStateMap(states);
          _testGradingDraftStatesByHomeworkId[textbookProblemPayload
              .homeworkId] = Map<String, HomeworkAnswerCellState>.from(decoded);
          _testGradingSerializedDraftByHomeworkId[textbookProblemPayload
              .homeworkId] = _serializeTestGradingDraftRows(
            homeworkId: textbookProblemPayload.homeworkId,
            gradingPages: textbookProblemPayload.gradingPages,
            states: decoded,
          );
        },
        onAction: (action, states, correctionStates) async {
          if (!mounted) return;
          final decoded = _fromRightSheetStateMap(states);
          _testGradingDraftStatesByHomeworkId[textbookProblemPayload
              .homeworkId] = Map<String, HomeworkAnswerCellState>.from(decoded);
          _testGradingSerializedDraftByHomeworkId[textbookProblemPayload
              .homeworkId] = _serializeTestGradingDraftRows(
            homeworkId: textbookProblemPayload.homeworkId,
            gradingPages: textbookProblemPayload.gradingPages,
            states: decoded,
          );
          var savedGrading = true;
          if (action == 'complete' || action == 'confirm') {
            final targetItem = HomeworkStore.instance.getById(
                  studentId,
                  textbookProblemPayload.homeworkId,
                ) ??
                hw;
            final saved = await _gradingResultService.saveAttemptFromSession(
              studentId: studentId,
              homeworkItem: targetItem,
              action: action,
              states: decoded,
              gradingPages: textbookProblemPayload.gradingPages,
              scoreByQuestionKey: textbookProblemPayload.scoreByQuestionKey,
              groupHomeworkTitleSnapshot: groupHomeworkTitle,
              baselineAttemptId: baselineSession?.attempt.id ?? '',
              baselineStates: baselineStates,
              correctionStates: correctionStates,
            );
            if (!mounted) return;
            if (!saved) {
              savedGrading = false;
              _showHomeworkChipSnackBar(this.context, '채점 결과 저장에 실패했습니다.');
            } else {
              _testGradingSavedHomeworkIds
                  .add(textbookProblemPayload.homeworkId);
              _gradingProgressRevisionByStudent.remove(studentId);
              _gradingProgressFutureByStudent.remove(studentId);
            }
          }
          if (savedGrading && (action == 'complete' || action == 'confirm')) {
            savedGrading = await _finalizeDirectStructuredHomeworkCheck(
              studentId: studentId,
              keys: keys,
              states: decoded,
              gradingPages: textbookProblemPayload.gradingPages,
              onCheckRecorded: () => _markPendingConfirms(
                keys: keys,
                action: action,
                structuredGrading: true,
              ),
            );
            if (!savedGrading && mounted) {
              _showHomeworkChipSnackBar(
                this.context,
                '숙제 검사 이력 저장에 실패했습니다.',
              );
            }
          }
          if (!mounted || !savedGrading) return;
          _markPendingConfirms(keys: keys, action: action);
        },
      );
      blockRightSideSheetOpen.value = false;
      if (!rightSideSheetOpen.value) {
        final toggleAction = toggleRightSideSheetAction;
        if (toggleAction != null) {
          await toggleAction();
        }
      }
      return;
    }
    rightSideSheetTestGradingSession.value = null;

    var hasLinkedTextbook = _hasDirectHomeworkTextbookLink(hw);
    if (!hasLinkedTextbook) {
      for (final key in keys) {
        final item = HomeworkStore.instance.getById(key.studentId, key.itemId);
        if (item != null && _hasDirectHomeworkTextbookLink(item)) {
          hasLinkedTextbook = true;
          break;
        }
      }
    }
    if (!hasLinkedTextbook) {
      Widget actionPill({
        required String label,
        required IconData icon,
        required VoidCallback onTap,
        bool filled = false,
      }) {
        return Material(
          color: filled ? kDlgAccent : kDlgPanelBg.withValues(alpha: 0.92),
          shape: StadiumBorder(
            side:
                filled ? BorderSide.none : const BorderSide(color: kDlgBorder),
          ),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 28,
                    color: filled ? Colors.white : kDlgText,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    label,
                    style: TextStyle(
                      color: filled ? Colors.white : kDlgText,
                      fontWeight: FontWeight.w800,
                      fontSize: 20,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }

      final action = await showDialog<HomeworkAnswerViewerAction>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: kDlgBg,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: const Text(
            '처리 선택',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          content: const Text(
            '처리할 상태를 선택해 주세요.',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
          actions: [
            actionPill(
              label: '취소',
              icon: Icons.close_rounded,
              onTap: () => Navigator.of(ctx).pop(),
            ),
            actionPill(
              label: '완료',
              icon: Icons.task_alt_rounded,
              onTap: () => Navigator.of(ctx).pop(
                HomeworkAnswerViewerAction.complete,
              ),
            ),
            actionPill(
              label: '확인',
              icon: Icons.check_rounded,
              filled: true,
              onTap: () =>
                  Navigator.of(ctx).pop(HomeworkAnswerViewerAction.confirm),
            ),
          ],
        ),
      );
      if (!context.mounted || action == null) return;
      setState(() {
        for (final key in keys) {
          _pendingConfirms[key] = action == HomeworkAnswerViewerAction.complete;
        }
      });
      _batchConfirmService.syncPendingCount();
      return;
    }

    final resolved = await _resolveHomeworkPdfLinks(
      hw,
      allowFlowFallback: true,
    );
    if (!context.mounted) return;

    final answerRaw = resolved.answerPathRaw;
    if (answerRaw.isEmpty) {
      setState(() {
        for (final key in keys) {
          _pendingConfirms[key] = false;
        }
      });
      return;
    }
    final answerIsUrl = _isWebUrl(answerRaw);
    final answerPath =
        answerIsUrl ? answerRaw.trim() : _toLocalFilePath(answerRaw);
    if (answerPath.isEmpty ||
        (!answerIsUrl && !answerPath.toLowerCase().endsWith('.pdf'))) {
      setState(() {
        for (final key in keys) {
          _pendingConfirms[key] = false;
        }
      });
      return;
    }
    if (!answerIsUrl && !await File(answerPath).exists()) {
      if (!context.mounted) return;
      setState(() {
        for (final key in keys) {
          _pendingConfirms[key] = false;
        }
      });
      return;
    }

    String? solutionPath;
    final solutionRaw = resolved.solutionPathRaw;
    if (_isWebUrl(solutionRaw)) {
      solutionPath = solutionRaw.trim();
    } else if (solutionRaw.isNotEmpty) {
      final candidate = _toLocalFilePath(solutionRaw);
      if (candidate.isNotEmpty &&
          candidate.toLowerCase().endsWith('.pdf') &&
          await File(candidate).exists()) {
        solutionPath = candidate;
      }
    }

    final closeAction = closeRightSideSheetAction;
    if (closeAction != null) {
      await closeAction();
    }
    final action = await openHomeworkAnswerViewerPage(
      context,
      filePath: answerPath,
      title: hw.title.trim().isEmpty ? '답지 확인' : hw.title.trim(),
      solutionFilePath: solutionPath,
      cacheKey: 'student:$studentId|answer:$answerPath',
      enableConfirm: true,
      overlayEntries: overlayEntries,
    );
    if (!context.mounted) return;
    if (action == HomeworkAnswerViewerAction.complete) {
      setState(() {
        for (final key in keys) {
          _pendingConfirms[key] = true;
        }
      });
      _batchConfirmService.syncPendingCount();
    } else if (action == HomeworkAnswerViewerAction.confirm) {
      setState(() {
        for (final key in keys) {
          _pendingConfirms[key] = false;
        }
      });
      _batchConfirmService.syncPendingCount();
    }
  }

  Future<void> _openGradingAfterHomeworkCheck({
    required BuildContext context,
    required String studentId,
    required _HomeworkCheckResult? checkResult,
  }) async {
    if (checkResult == null ||
        !checkResult.saved ||
        !checkResult.startGrading) {
      return;
    }
    final itemIds = checkResult.itemIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (itemIds.isEmpty) return;

    final pendingKeys = itemIds
        .map((itemId) => (studentId: studentId, itemId: itemId))
        .toList(growable: false);
    final latestById = <String, HomeworkItem>{};
    for (final itemId in itemIds) {
      final latest = HomeworkStore.instance.getById(studentId, itemId);
      if (latest != null) latestById[itemId] = latest;
    }
    final submittedChildren = itemIds
        .map((itemId) => latestById[itemId])
        .whereType<HomeworkItem>()
        .where(
          (item) =>
              item.status != HomeworkStatus.completed &&
              item.phase == 3 &&
              item.completedAt == null,
        )
        .toList(growable: false);
    if (submittedChildren.isEmpty || !context.mounted) return;

    var answerSeed = submittedChildren.first;
    for (final child in submittedChildren) {
      if (_hasDirectHomeworkTextbookLink(child)) {
        answerSeed = child;
        break;
      }
    }
    await _handleSubmittedChipTapForPending(
      context: context,
      studentId: studentId,
      hw: answerSeed,
      targetKeys: pendingKeys,
    );
  }

  Future<void> _handleHomeworkInspectionTap({
    required BuildContext context,
    required String studentId,
    required HomeworkGroup? group,
    required HomeworkItem summary,
    required List<HomeworkItem> children,
  }) async {
    final activeChildren = children
        .where((item) => item.status != HomeworkStatus.completed)
        .toList(growable: false);
    if (activeChildren.isEmpty) return;
    final assignments =
        await HomeworkAssignmentStore.instance.loadActiveAssignments(studentId);
    if (!context.mounted) return;
    final ids = activeChildren.map((item) => item.id).toSet();
    final targets = assignments
        .where((assignment) => ids.contains(assignment.homeworkItemId));
    DateTime? dueDate;
    DateTime? dueForCheckAt;
    var absenceCarryover = false;
    for (final target in targets) {
      final candidate = target.originalDueDate ?? target.dueDate;
      if (candidate != null &&
          (dueDate == null || candidate.isBefore(dueDate))) {
        dueDate = candidate;
      }
      final checkAt = target.dueForCheckAt;
      if (checkAt != null &&
          (dueForCheckAt == null || checkAt.isAfter(dueForCheckAt))) {
        dueForCheckAt = checkAt;
      }
      absenceCarryover = absenceCarryover || target.absenceCarryover;
    }
    final title = (group?.title ?? '').trim().isNotEmpty
        ? group!.title.trim()
        : summary.title.trim();
    final choice = await _showHomeworkInspectionChoiceDialog(
      context: context,
      title: title,
      dueDate: dueDate,
      absenceCarryover: absenceCarryover,
      missedInspection: !absenceCarryover &&
          _isHomeworkInspectionDeferred(
            originalDue: dueDate,
            dueForCheckAt: dueForCheckAt,
          ),
    );
    if (choice == null || !context.mounted) return;

    if (choice == _HomeworkInspectionChoice.grade) {
      final opened = await _tryOpenStructuredHomeworkCheck(
        context: context,
        studentId: studentId,
        summary: summary,
        children: activeChildren,
      );
      if (opened || !context.mounted) return;
      final checkResult = await _runHomeworkCheckDialogForGroup(
        context: context,
        studentId: studentId,
        group: group,
        summary: summary,
        children: activeChildren,
      );
      if (!context.mounted) return;
      await _openGradingAfterHomeworkCheck(
        context: context,
        studentId: studentId,
        checkResult: checkResult,
      );
      return;
    }

    final groupId = (group?.id ??
            HomeworkStore.instance.groupIdOfItem(activeChildren.first.id) ??
            '')
        .trim();
    final outcome = choice == _HomeworkInspectionChoice.leftBehind
        ? HomeworkAssignmentOutcome.leftBehind
        : HomeworkAssignmentOutcome.notDone;
    final result = await HomeworkAssignmentStore.instance.recordGroupOutcome(
      studentId: studentId,
      groupId: groupId,
      homeworkItemIds: activeChildren.map((item) => item.id),
      outcome: outcome,
    );
    if (!context.mounted) return;
    if (result == null) {
      _showHomeworkChipSnackBar(context, '미제출 처리에 실패했습니다.');
      return;
    }
    for (final item in activeChildren) {
      item.status = HomeworkStatus.homework;
      item.phase = 1;
      item.runStart = null;
    }
    HomeworkStore.instance.bumpRevision();
    final nextLabel = result.nextDueAt == null
        ? '다음 수업'
        : _formatDateWithWeekdayAndTime(result.nextDueAt!);
    final reasonLabel =
        choice == _HomeworkInspectionChoice.leftBehind ? '두고 옴' : '숙제 안 함';
    _showHomeworkChipSnackBar(
      context,
      '$reasonLabel 0% 기록 · $nextLabel까지 연기했습니다.',
    );
  }

  Future<bool> _tryOpenStructuredHomeworkCheck({
    required BuildContext context,
    required String studentId,
    required HomeworkItem summary,
    required List<HomeworkItem> children,
  }) async {
    final targetChildren = children
        .where((item) => item.status != HomeworkStatus.completed)
        .toList(growable: false);
    if (targetChildren.isEmpty) return false;
    var answerSeed = targetChildren.first;
    for (final child in targetChildren) {
      if ((child.pbPresetId ?? '').trim().isNotEmpty ||
          _hasDirectHomeworkTextbookLink(child)) {
        answerSeed = child;
        break;
      }
    }
    final keys = targetChildren
        .map((item) => (studentId: studentId, itemId: item.id))
        .toList(growable: false);
    final structuredSession = await _buildRightSheetPreloadSession(
      studentId: studentId,
      hw: answerSeed,
      targetKeys: keys,
    );
    if (structuredSession == null || !context.mounted) return false;

    _directStructuredHomeworkCheckKeys.addAll(keys);
    await _handleSubmittedChipTapForPending(
      context: context,
      studentId: studentId,
      hw: answerSeed,
      targetKeys: keys,
    );
    return true;
  }

  int _structuredHomeworkProgress({
    required Map<String, HomeworkAnswerCellState> states,
    required List<HomeworkAnswerGradingPage> gradingPages,
  }) {
    final keys = gradingPages
        .expand((page) => page.cells)
        .map((cell) => cell.key)
        .toSet();
    if (keys.isEmpty) return 0;
    final effectiveKeys = keys.where((key) {
      final state = states[key] ?? HomeworkAnswerCellState.correct;
      return state != HomeworkAnswerCellState.abandoned;
    }).toList(growable: false);
    if (effectiveKeys.isEmpty) return 0;
    final performed = effectiveKeys.where((key) {
      final state = states[key] ?? HomeworkAnswerCellState.correct;
      return state != HomeworkAnswerCellState.notPerformed;
    }).length;
    return ((performed * 100) / effectiveKeys.length).round().clamp(0, 100);
  }

  /// 채점 화면을 어떤 경로로 열었든, 활성 숙제가 있는 문항은 채점 결과를 검사
  /// 진행률로 반영한다. 이 동기화가 없으면 알림장이 0%로 남는다.
  Future<void> _syncStructuredGradingProgress({
    required List<({String studentId, String itemId})> keys,
    required Map<String, HomeworkAnswerCellState> states,
    required List<HomeworkAnswerGradingPage> gradingPages,
  }) async {
    final pendingKeys = keys
        .where((key) => !_directStructuredHomeworkCheckKeys.contains(key))
        .toList(growable: false);
    if (pendingKeys.isEmpty) return;

    final progress = _structuredHomeworkProgress(
      states: states,
      gradingPages: gradingPages,
    );
    for (final key in pendingKeys) {
      final target = await _resolveHomeworkCheckTarget(
        key.studentId,
        key.itemId,
        // 검사 직후 assignment가 완료/해제돼도 오늘 검사 이력을 갱신해야 한다.
        includeHistory: true,
      );
      if (target == null) continue;
      await HomeworkAssignmentStore.instance.syncCheckProgressFromGrading(
        studentId: key.studentId,
        homeworkItemId: key.itemId,
        assignmentId: target.assignmentId,
        progress: progress,
      );
    }
  }

  void _markPendingConfirms({
    required List<({String studentId, String itemId})> keys,
    required String action,
    bool structuredGrading = false,
  }) {
    if (!mounted) return;
    if (structuredGrading) {
      _structuredPendingConfirmKeys.addAll(keys);
    }
    final value = action == 'complete';
    if (keys.every((key) => _pendingConfirms[key] == value)) return;
    setState(() {
      for (final key in keys) {
        _pendingConfirms[key] = value;
      }
    });
    _batchConfirmService.syncPendingCount();
  }

  Future<void> _cancelPendingStructuredGrading({
    required BuildContext context,
    required List<({String studentId, String itemId})> keys,
  }) async {
    if (keys.isEmpty) return;
    final studentIds = keys.map((key) => key.studentId).toSet();
    if (studentIds.length != 1) return;
    final studentId = studentIds.single;

    var rollbackOk = true;
    var restoredCount = 0;
    final keysByGroup = <String, List<({String studentId, String itemId})>>{};
    final fallbackKeys = <({String studentId, String itemId})>[];
    for (final key in keys) {
      HomeworkStore.instance.clearAutoCompleteOnNextWaiting(key.itemId);
      final groupId =
          (HomeworkStore.instance.groupIdOfItem(key.itemId) ?? '').trim();
      if (groupId.isEmpty) {
        fallbackKeys.add(key);
      } else {
        keysByGroup.putIfAbsent(groupId, () => []).add(key);
      }
    }

    for (final entry in keysByGroup.entries) {
      final rolledBack =
          await HomeworkAssignmentStore.instance.rollbackStructuredGroupGrading(
        studentId: studentId,
        groupId: entry.key,
        homeworkItemIds: entry.value.map((key) => key.itemId),
      );
      if (rolledBack == null) {
        // 타임아웃 뒤 서버 트랜잭션이 커밋됐을 수 있으므로 이 경로에서는
        // 오래된 검사 이력을 임의로 지우는 클라이언트 폴백을 실행하지 않는다.
        rollbackOk = false;
      } else {
        restoredCount += rolledBack;
      }
    }

    for (final key in fallbackKeys) {
      final checkRollback =
          await HomeworkAssignmentStore.instance.rollbackLatestCheckForItem(
        studentId: key.studentId,
        homeworkItemId: key.itemId,
        includeConfirmIncrement: false,
      );
      final attemptRollback =
          await _gradingResultService.rollbackLatestAttemptForHomework(
        homeworkItemId: key.itemId,
      );
      if (checkRollback == null || !attemptRollback) rollbackOk = false;
    }
    if (fallbackKeys.isNotEmpty) {
      restoredCount +=
          await HomeworkStore.instance.restoreItemsAfterGradingCancel(
        studentId,
        fallbackKeys.map((key) => key.itemId).toList(growable: false),
      );
    } else {
      await HomeworkStore.instance.reloadStudentHomework(studentId);
    }
    if (!mounted || !context.mounted) return;
    if (!rollbackOk || restoredCount == 0) {
      _showHomeworkChipSnackBar(
        context,
        '채점 취소를 완료하지 못했습니다. 다시 시도해 주세요.',
      );
      return;
    }

    setState(() {
      for (final key in keys) {
        _pendingConfirms.remove(key);
        _structuredPendingConfirmKeys.remove(key);
        _testGradingDraftStatesByHomeworkId.remove(key.itemId);
        _testGradingSerializedDraftByHomeworkId.remove(key.itemId);
        _testGradingSavedHomeworkIds.remove(key.itemId);
      }
    });
    _batchConfirmService.syncPendingCount();
    _gradingProgressRevisionByStudent.remove(studentId);
    _gradingProgressFutureByStudent.remove(studentId);
    _showHomeworkChipSnackBar(
      context,
      '채점과 검사 기록을 취소하고 대기 상태로 되돌렸어요.',
    );
  }

  Future<bool> _finalizeDirectStructuredHomeworkCheck({
    required String studentId,
    required List<({String studentId, String itemId})> keys,
    required Map<String, HomeworkAnswerCellState> states,
    required List<HomeworkAnswerGradingPage> gradingPages,
    VoidCallback? onCheckRecorded,
  }) async {
    await _syncStructuredGradingProgress(
      keys: keys,
      states: states,
      gradingPages: gradingPages,
    );
    final allItemIds = keys
        .map((key) => key.itemId.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    final directKeys = keys
        .where(_directStructuredHomeworkCheckKeys.contains)
        .toList(growable: false);

    if (directKeys.isNotEmpty) {
      final progress = _structuredHomeworkProgress(
        states: states,
        gradingPages: gradingPages,
      );
      final itemIdsByGroup = <String, List<String>>{};
      final orphanItemIds = <String>[];
      final atomicallyFinalizedItemIds = <String>{};
      final legacyFinalizeItemIds = <String>[];
      for (final key in directKeys) {
        final groupId =
            (HomeworkStore.instance.groupIdOfItem(key.itemId) ?? '').trim();
        if (groupId.isEmpty) {
          orphanItemIds.add(key.itemId);
          continue;
        }
        itemIdsByGroup.putIfAbsent(groupId, () => <String>[]).add(key.itemId);
      }
      for (final entry in itemIdsByGroup.entries) {
        final requestId = const Uuid().v4();
        final atomicSaved =
            await HomeworkAssignmentStore.instance.recordStructuredGroupGrading(
          studentId: studentId,
          groupId: entry.key,
          homeworkItemIds: entry.value,
          progress: progress,
          idempotencyKey: requestId,
        );
        if (atomicSaved != null) {
          atomicallyFinalizedItemIds.addAll(entry.value);
          HomeworkStore.instance.applyStructuredGradingSubmittedLocally(
            studentId,
            entry.value,
          );
          continue;
        }

        // RPC 미배포/일시 실패 환경에서는 기존 검증된 경로로 폴백한다.
        final saved = await HomeworkAssignmentStore.instance.recordGroupOutcome(
          studentId: studentId,
          groupId: entry.key,
          homeworkItemIds: entry.value,
          outcome: HomeworkAssignmentOutcome.graded,
          progress: progress,
          idempotencyKey: requestId,
        );
        if (saved == null) {
          // 활성 assignment가 없으면 outcome RPC가 실패한다. history 동기화로 오늘
          // 검사 이력만이라도 남겨 과제현황/알림장이 비지 않게 한다.
          for (final itemId in entry.value) {
            final target = await _resolveHomeworkCheckTarget(
              studentId,
              itemId,
              includeHistory: true,
            );
            if (target == null) continue;
            await HomeworkAssignmentStore.instance.syncCheckProgressFromGrading(
              studentId: studentId,
              homeworkItemId: itemId,
              assignmentId: target.assignmentId,
              progress: progress,
            );
          }
        } else {
          legacyFinalizeItemIds.addAll(entry.value);
        }
      }
      for (final itemId in orphanItemIds) {
        final target = await _resolveHomeworkCheckTarget(
          studentId,
          itemId,
          includeHistory: true,
        );
        if (target == null) continue;
        await HomeworkAssignmentStore.instance.syncCheckProgressFromGrading(
          studentId: studentId,
          homeworkItemId: itemId,
          assignmentId: target.assignmentId,
          progress: progress,
        );
      }
      // 검사 결과가 서버에 기록된 시점에 체크 UI를 먼저 갱신한다.
      // 아래 활성 순서 조정·제출·assignment 정리는 후속 정합 작업이다.
      onCheckRecorded?.call();
      onCheckRecorded = null;
      for (final itemId in legacyFinalizeItemIds) {
        await HomeworkStore.instance.placeItemAtActiveTail(
          studentId,
          itemId,
          activateFromHomework: true,
        );
      }
      await HomeworkStore.instance.submitBatch(
        studentId,
        legacyFinalizeItemIds,
      );

      // 원자적 RPC가 처리한 항목은 assignment도 이미 completed 상태다.
      allItemIds.removeWhere(atomicallyFinalizedItemIds.contains);
    }

    onCheckRecorded?.call();
    // 채점 저장 후에는 검사 대상 칩/다이얼로그가 다시 뜨지 않도록 활성 assignment를 해제한다.
    if (allItemIds.isNotEmpty) {
      await HomeworkAssignmentStore.instance.clearActiveAssignmentsForItems(
        studentId,
        allItemIds,
        fromStatuses: const ['assigned', 'in_progress', 'carried_to_class'],
      );
    }
    _directStructuredHomeworkCheckKeys.removeAll(keys);
    _gradingProgressRevisionByStudent.remove(studentId);
    _gradingProgressFutureByStudent.remove(studentId);
    return true;
  }

  Future<void> _handleHomeworkCardTapForPending({
    required BuildContext context,
    required String studentId,
    required HomeworkItem hw,
  }) async {
    final key = (studentId: studentId, itemId: hw.id);
    if (_pendingConfirms.containsKey(key)) {
      if (_structuredPendingConfirmKeys.contains(key)) {
        await _cancelPendingStructuredGrading(
          context: context,
          keys: [key],
        );
        return;
      }
      setState(() => _pendingConfirms.remove(key));
      return;
    }

    final latest = HomeworkStore.instance.getById(studentId, hw.id);
    if (latest == null) return;

    final target = await _resolveHomeworkCheckTarget(
      studentId,
      hw.id,
      includeHistory: false,
    );
    if (!context.mounted) return;
    if (target == null) {
      setState(() => _pendingConfirms[key] = false);
      return;
    }

    final checks = await HomeworkAssignmentStore.instance
        .loadChecksForItem(studentId, hw.id);
    checks.sort((a, b) => a.checkedAt.compareTo(b.checkedAt));
    final previousProgress = checks.isEmpty ? 0 : checks.last.progress;
    final minProgress =
        math.max(previousProgress, target.progress).clamp(0, 150);

    if (!context.mounted) return;
    final draft = await _showHomeworkItemCheckDialog(
      context: context,
      hw: latest,
      target: target,
      minProgress: minProgress,
      studentId: studentId,
    );
    if (!context.mounted || draft == null) return;

    setState(() => _pendingConfirms[key] = false);
  }

  void _setHomePrintPickMode(bool value) {
    if (_printPickMode == value) return;
    if (!mounted) {
      _printPickMode = value;
      widget.printController?._notifyStateChanged();
      return;
    }
    setState(() => _printPickMode = value);
    widget.printController?._notifyStateChanged();
  }

  Future<void> _startExternalPrintFlow() async {
    final attendingStudents = _computeAttendingStudentsForDate(
      attendanceAnchorDateNotifier.value,
    );
    await _openHeaderHomeworkPrintFlow(attendingStudents: attendingStudents);
  }

  Future<void> _openHeaderHomeworkPrintFlow({
    required List<_AttendingStudent> attendingStudents,
  }) async {
    if (_printPickMode) {
      _setHomePrintPickMode(false);
      return;
    }
    final waitingCandidates = <({String studentId, HomeworkItem hw})>[];
    for (final student in attendingStudents) {
      waitingCandidates.addAll(
        HomeworkStore.instance
            .items(student.id)
            .where((hw) => hw.status != HomeworkStatus.completed)
            .map((hw) => (studentId: student.id, hw: hw)),
      );
    }
    if (waitingCandidates.isEmpty) {
      if (mounted) {
        _showHomeworkChipSnackBar(context, '인쇄 가능한 과제가 없습니다.');
      }
      return;
    }

    final assignmentByStudent =
        <String, Map<String, HomeworkAssignmentDetail>>{};
    var hasPrintableSource = false;
    for (final candidate in waitingCandidates) {
      try {
        final studentId = candidate.studentId;
        final assignmentByItemId = assignmentByStudent[studentId] ??
            await _loadActiveAssignmentByItemId(studentId);
        assignmentByStudent[studentId] = assignmentByItemId;
        final canPrint = await _canPrintHomeworkByResolvedSource(
          studentId: studentId,
          hw: candidate.hw,
          assignmentByItemId: assignmentByItemId,
        );
        if (!canPrint) continue;
        hasPrintableSource = true;
        break;
      } catch (_) {}
    }
    if (!mounted) return;
    if (!hasPrintableSource) {
      _showHomeworkChipSnackBar(context, '인쇄 가능한 문제은행/교재 PDF가 없습니다.');
      return;
    }
    _setHomePrintPickMode(true);
  }

  Future<Map<String, HomeworkAssignmentDetail>> _loadActiveAssignmentByItemId(
    String studentId,
  ) async {
    try {
      final rows = await HomeworkAssignmentStore.instance
          .loadActiveAssignments(studentId);
      final out = <String, HomeworkAssignmentDetail>{};
      for (final row in rows) {
        final itemId = row.homeworkItemId.trim();
        if (itemId.isEmpty || out.containsKey(itemId)) continue;
        out[itemId] = row;
      }
      return out;
    } catch (_) {
      return const <String, HomeworkAssignmentDetail>{};
    }
  }

  Future<bool> _canPrintHomeworkByResolvedSource({
    required String studentId,
    required HomeworkItem hw,
    Map<String, HomeworkAssignmentDetail>? assignmentByItemId,
  }) async {
    try {
      final resolvedAssignments =
          assignmentByItemId ?? await _loadActiveAssignmentByItemId(studentId);
      final assignment = resolvedAssignments[hw.id.trim()];
      if (_isPbPrintTarget(hw: hw, assignment: assignment)) {
        final pbSource = await _resolvePbPrintSource(
          hw,
          assignment: assignment,
        );
        if (pbSource != null &&
            await _isPrintableResolvedHomeworkPrintSource(pbSource)) {
          return true;
        }
        return _canCreatePbPrintFromTarget(hw: hw, assignment: assignment);
      }
      final textbookSource = await _resolveTextbookPrintSource(
        hw,
        allowFlowFallback: true,
      );
      return _isPrintableResolvedHomeworkPrintSource(textbookSource);
    } catch (_) {
      return false;
    }
  }

  String _homePrintQueueTitleFor({
    required String studentId,
    required HomeworkItem hw,
    HomeworkGroup? group,
    HomeworkItem? summary,
  }) {
    final studentName = _resolveHomeworkPrintStudentName(studentId);
    final rawTitle = (summary?.title ?? group?.title ?? hw.title).trim();
    final title = rawTitle.isEmpty ? '(제목 없음)' : rawTitle;
    return '$studentName · $title';
  }

  String _homePrintQueueStatusLabel(_HomePrintQueueItem item) {
    switch (item.status) {
      case _HomePrintQueueStatus.queued:
        return '대기';
      case _HomePrintQueueStatus.printing:
        return '인쇄 중';
      case _HomePrintQueueStatus.completed:
        return '완료';
      case _HomePrintQueueStatus.failed:
        return '실패';
    }
  }

  Color _homePrintQueueStatusColor(_HomePrintQueueItem item) {
    switch (item.status) {
      case _HomePrintQueueStatus.queued:
        return _homePrintPickTextSub;
      case _HomePrintQueueStatus.printing:
        return _homePrintPickAccent;
      case _HomePrintQueueStatus.completed:
        return const Color(0xFF8BCDAF);
      case _HomePrintQueueStatus.failed:
        return const Color(0xFFE6A0A0);
    }
  }

  void _enqueueHomePrintQueueItem(_HomePrintQueueItem item) {
    if (!mounted) return;
    setState(() {
      _homePrintQueuePanelDismissed = false;
      _homePrintQueue.add(item);
    });
    unawaited(_pumpHomePrintQueue());
  }

  Future<void> _pumpHomePrintQueue() async {
    if (_homePrintQueueRunning) return;
    _homePrintQueueRunning = true;
    try {
      while (mounted) {
        final nextIndex = _homePrintQueue.indexWhere(
          (item) => item.status == _HomePrintQueueStatus.queued,
        );
        if (nextIndex < 0) break;
        final item = _homePrintQueue[nextIndex];
        setState(() {
          item.status = _HomePrintQueueStatus.printing;
          item.message = '인쇄 준비 중';
          item.error = null;
        });
        try {
          await _runHomePrintQueueItem(item);
          if (!mounted) return;
          setState(() {
            item.status = _HomePrintQueueStatus.completed;
            item.message = '완료';
          });
        } catch (e) {
          if (!mounted) return;
          setState(() {
            item.status = _HomePrintQueueStatus.failed;
            item.error = _messageFromPrintError(e);
            item.message = '실패';
          });
        }
      }
    } finally {
      _homePrintQueueRunning = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _runHomePrintQueueItem(_HomePrintQueueItem item) async {
    final progressText = ValueNotifier<String>('인쇄 준비 중');
    void syncProgress() {
      if (!mounted) return;
      setState(() => item.message = progressText.value);
    }

    progressText.addListener(syncProgress);
    try {
      if (item.group != null && item.summary != null) {
        final request = await _buildHomeworkGroupPrintRequest(
          studentId: item.studentId,
          group: item.group!,
          summary: item.summary!,
          children: item.children,
        );
        if ((request.warning ?? '').isNotEmpty && mounted) {
          _showHomeworkChipSnackBar(context, request.warning!);
        }
        if ((request.error ?? '').isNotEmpty) {
          throw StateError(request.error!);
        }
        final result = await _runHomeworkPrintWithDefaultSettings(
          studentId: item.studentId,
          hw: request.seed,
          initialRangeOverride: request.initialRange,
          selectableGroupChildren: request.eligibleChildren,
          groupChildPrintableById: request.printableById,
          groupInitialSelectionById: request.initialSelectedById,
          assignmentByItemId: request.assignmentByItemId,
          preResolvedSourceByItemId: request.sourceByItemId,
          progressText: progressText,
        );
        if ((result.error ?? '').isNotEmpty) throw StateError(result.error!);
        return;
      }

      final latest =
          HomeworkStore.instance.getById(item.studentId, item.hw.id) ?? item.hw;
      if (latest.status == HomeworkStatus.completed) {
        throw StateError('완료된 과제는 인쇄할 수 없습니다.');
      }
      final result = await _runHomeworkPrintWithDefaultSettings(
        studentId: item.studentId,
        hw: latest,
        progressText: progressText,
      );
      if ((result.error ?? '').isNotEmpty) throw StateError(result.error!);
    } finally {
      progressText.removeListener(syncProgress);
      progressText.dispose();
    }
  }

  void _dismissHomePrintQueuePanel() {
    if (!mounted) return;
    setState(() {
      _homePrintQueuePanelDismissed = true;
      _homePrintQueue.removeWhere((item) => item.isTerminal);
    });
  }

  void _exitHomePrintPickMode() {
    if (!mounted || !_printPickMode) return;
    _setHomePrintPickMode(false);
  }

  Future<void> _handleHomeworkPrintPick({
    required BuildContext context,
    required String studentId,
    required HomeworkItem hw,
  }) async {
    if (!_printPickMode) return;
    final latest = HomeworkStore.instance.getById(studentId, hw.id);
    if (latest == null) return;
    if (latest.status == HomeworkStatus.completed) return;
    _enqueueHomePrintQueueItem(
      _HomePrintQueueItem(
        id: ++_homePrintQueueSeq,
        studentId: studentId,
        title: _homePrintQueueTitleFor(studentId: studentId, hw: latest),
        hw: latest,
      ),
    );
  }

  Future<void> _handleHomeworkPrintPickWithSettings({
    required BuildContext context,
    required String studentId,
    required HomeworkItem hw,
  }) async {
    if (!_printPickMode) return;
    final latest = HomeworkStore.instance.getById(studentId, hw.id);
    if (latest == null) return;
    if (latest.status == HomeworkStatus.completed) return;
    await _handleWaitingChipLongPressPrint(
      context: context,
      studentId: studentId,
      hw: latest,
    );
  }

  Future<void> _handleHomeworkGroupPrintPick({
    required BuildContext context,
    required String studentId,
    required HomeworkGroup group,
    required HomeworkItem summary,
    required List<HomeworkItem> children,
  }) async {
    if (!_printPickMode) return;
    final latestChildren = children
        .map((e) => HomeworkStore.instance.getById(studentId, e.id) ?? e)
        .toList(growable: false);
    if (latestChildren
        .where((e) => e.status != HomeworkStatus.completed)
        .isEmpty) {
      _showHomeworkChipSnackBar(context, '인쇄 가능한 하위 과제가 없습니다.');
      return;
    }
    _enqueueHomePrintQueueItem(
      _HomePrintQueueItem(
        id: ++_homePrintQueueSeq,
        studentId: studentId,
        title: _homePrintQueueTitleFor(
          studentId: studentId,
          hw: summary,
          group: group,
          summary: summary,
        ),
        hw: summary,
        group: group,
        summary: summary,
        children: latestChildren,
      ),
    );
  }

  Future<void> _handleHomeworkGroupPrintPickWithSettings({
    required BuildContext context,
    required String studentId,
    required HomeworkGroup group,
    required HomeworkItem summary,
    required List<HomeworkItem> children,
  }) async {
    if (!_printPickMode) return;
    final request = await _buildHomeworkGroupPrintRequest(
      studentId: studentId,
      group: group,
      summary: summary,
      children: children,
    );
    if (!mounted) return;
    if ((request.warning ?? '').isNotEmpty) {
      _showHomeworkChipSnackBar(context, request.warning!);
    }
    if ((request.error ?? '').isNotEmpty) {
      _showHomeworkChipSnackBar(context, request.error!);
      return;
    }
    await _handleWaitingChipLongPressPrint(
      context: context,
      studentId: studentId,
      hw: request.seed,
      initialRangeOverride: request.initialRange,
      dialogTitleOverride: request.dialogTitle,
      selectableGroupChildren: request.eligibleChildren,
      groupChildPrintableById: request.printableById,
      groupInitialSelectionById: request.initialSelectedById,
      groupChildPageRangeById: request.childPageRangeById,
      assignmentByItemId: request.assignmentByItemId,
      preResolvedSourceByItemId: request.sourceByItemId,
    );
  }
}

enum _FavoriteIssueMode { reserve, immediate }

class _FavoriteTemplateLinkStatus {
  final bool linked;
  final String flowId;

  const _FavoriteTemplateLinkStatus({
    required this.linked,
    required this.flowId,
  });
}

Future<String?> _openRecordNoteDialogGlobal(BuildContext context) async {
  final controller = ImeAwareTextEditingController();
  return showDialog<String?>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kDlgBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: const Text('기록 입력',
          style: TextStyle(color: Colors.white, fontSize: 20)),
      content: SizedBox(
        width: 520,
        child: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(
              hintText: '간단히 적어주세요',
              hintStyle: TextStyle(color: Colors.white38),
              filled: true,
              fillColor: Color(0xFF2A2A2A),
              border: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24)),
              enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white24)),
              focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF1976D2)))),
          style: const TextStyle(color: Colors.white),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('취소', style: TextStyle(color: Colors.white70))),
        ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1976D2),
                foregroundColor: Colors.white),
            child: const Text('추가')),
      ],
    ),
  );
}

Future<void> _openClassTagDialogLikeSideSheet(
    BuildContext context, String setId, String studentId) async {
  final presets = await TagPresetService.instance.loadPresets();
  List<TagEvent> applied =
      List<TagEvent>.from(TagStore.instance.getEventsForSet(setId));
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          Future<void> handleTagPressed(
              String name, Color color, IconData icon) async {
            final now = DateTime.now();
            String? note;
            if (name == '기록') {
              note = await _openRecordNoteDialogGlobal(context);
              if (note == null || note.trim().isEmpty) return;
            }
            setLocal(() {
              applied.add(TagEvent(
                  tagName: name,
                  colorValue: color.value,
                  iconCodePoint: icon.codePoint,
                  timestamp: now,
                  note: note?.trim()));
            });
            TagStore.instance.appendEvent(
                setId,
                studentId,
                TagEvent(
                    tagName: name,
                    colorValue: color.value,
                    iconCodePoint: icon.codePoint,
                    timestamp: now,
                    note: note?.trim()));
          }

          return AlertDialog(
            backgroundColor: kDlgBg,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            title: const Text('수업 태그',
                style: TextStyle(color: Colors.white, fontSize: 20)),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('적용된 태그',
                        style: TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    if (applied.isEmpty)
                      const Text('아직 추가된 태그가 없습니다.',
                          style: TextStyle(color: Colors.white38))
                    else
                      Column(
                        children: [
                          for (int i = applied.length - 1; i >= 0; i--) ...[
                            Builder(builder: (context) {
                              final e = applied[i];
                              return Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 8),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF22262C),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                      color:
                                          Color(e.colorValue).withOpacity(0.35),
                                      width: 1),
                                ),
                                child: Row(
                                  children: [
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                            IconData(e.iconCodePoint,
                                                fontFamily: 'MaterialIcons'),
                                            color: Color(e.colorValue),
                                            size: 18),
                                        const SizedBox(width: 8),
                                        Text(e.tagName,
                                            style: const TextStyle(
                                                color: Colors.white70)),
                                        if (e.note != null &&
                                            e.note!.isNotEmpty) ...[
                                          const SizedBox(width: 8),
                                          Text(e.note!,
                                              style: const TextStyle(
                                                  color: Colors.white54,
                                                  fontSize: 12)),
                                        ],
                                      ],
                                    ),
                                    const Spacer(),
                                    Text(_formatDateTime(e.timestamp),
                                        style: const TextStyle(
                                            color: Colors.white54,
                                            fontSize: 12)),
                                  ],
                                ),
                              );
                            }),
                          ],
                        ],
                      ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Text('추가 가능한 태그',
                            style: TextStyle(
                                color: Colors.white70,
                                fontWeight: FontWeight.bold)),
                        const Spacer(),
                        IconButton(
                          tooltip: '태그 관리',
                          onPressed: () async {
                            await showDialog(
                                context: context,
                                builder: (_) => const TagPresetDialog());
                          },
                          icon: const Icon(Icons.style, color: Colors.white70),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final p in presets)
                          ActionChip(
                            onPressed: () =>
                                handleTagPressed(p.name, p.color, p.icon),
                            backgroundColor: const Color(0xFF2A2A2A),
                            label: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(p.icon, color: p.color, size: 18),
                                const SizedBox(width: 6),
                                Text(p.name,
                                    style:
                                        const TextStyle(color: Colors.white70)),
                              ],
                            ),
                            shape: StadiumBorder(
                                side: BorderSide(
                                    color: p.color.withOpacity(0.6),
                                    width: 1.0)),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('닫기',
                      style: TextStyle(color: Colors.white70))),
            ],
          );
        },
      );
    },
  );
}

DateTime _dateOnly(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

String _formatDateShort(DateTime dt) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(dt.month)}.${two(dt.day)}';
}

/// 원래 검사일이 이번 검사 시점보다 이전이면 이월(미검사/결석)로 본다.
bool _isHomeworkInspectionDeferred({
  required DateTime? originalDue,
  required DateTime? dueForCheckAt,
}) {
  if (originalDue == null) return false;
  final cutoff = dueForCheckAt ?? DateTime.now();
  return originalDue.isBefore(cutoff);
}

String _homeworkCarriedCheckChipLabel({
  required DateTime? originalDue,
  required DateTime? dueForCheckAt,
  required bool absenceCarryover,
}) {
  if (originalDue == null) return '오늘 검사';
  if (!_isHomeworkInspectionDeferred(
    originalDue: originalDue,
    dueForCheckAt: dueForCheckAt,
  )) {
    return '오늘 검사';
  }
  final day = _formatDateShort(originalDue);
  return absenceCarryover ? '$day 결석' : '$day 미검사';
}

String _formatDateWithWeekdayShort(DateTime dt) {
  const week = ['월', '화', '수', '목', '금', '토', '일'];
  return '${_formatDateShort(dt)} (${week[dt.weekday - 1]})';
}

String _formatHourMinute(DateTime dt) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(dt.hour)}:${two(dt.minute)}';
}

String _formatDateRange(DateTime start, DateTime? end) {
  final left = _formatDateShort(start);
  if (end == null) return '$left ~ 미정';
  return '$left ~ ${_formatDateShort(end)}';
}

class _HomeworkCheckTarget {
  final String assignmentId;
  final DateTime assignedAt;
  final DateTime? dueDate;
  final int progress;
  final String? issueType;
  final String? issueNote;

  const _HomeworkCheckTarget({
    required this.assignmentId,
    required this.assignedAt,
    required this.dueDate,
    required this.progress,
    required this.issueType,
    required this.issueNote,
  });
}

class _HomeworkCheckDraft {
  final int progress;
  final String? issueType;
  final String? issueNote;
  final bool startGrading;

  const _HomeworkCheckDraft({
    required this.progress,
    required this.issueType,
    required this.issueNote,
    this.startGrading = true,
  });
}

class _HomeworkCheckResult {
  final List<String> itemIds;
  final bool startGrading;

  const _HomeworkCheckResult({
    required this.itemIds,
    required this.startGrading,
  });

  bool get saved => itemIds.isNotEmpty;
}

enum _HomeworkInspectionChoice {
  grade,
  notDone,
  leftBehind,
}

Future<_HomeworkInspectionChoice?> _showHomeworkInspectionChoiceDialog({
  required BuildContext context,
  required String title,
  required DateTime? dueDate,
  required bool absenceCarryover,
  bool missedInspection = false,
}) {
  final dueLabel =
      dueDate == null ? '검사일 미정' : '${_formatDateWithWeekdayShort(dueDate)} 검사';
  final dueMetaLabel = absenceCarryover
      ? '$dueLabel · 결석 이월'
      : (missedInspection ? '$dueLabel · 미검사 이월' : dueLabel);
  final homeworkTitle = title.trim().isEmpty ? '그룹 숙제' : title.trim();
  return showModalBottomSheet<_HomeworkInspectionChoice>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.18),
    builder: (dialogContext) {
      final dlg = YggDialogColors.of(dialogContext);

      Widget actionCard({
        required String label,
        required String description,
        required _HomeworkInspectionChoice value,
        required IconData icon,
      }) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _HomeworkCheckCard(
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => Navigator.of(dialogContext).pop(value),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(icon, color: kDlgAccent, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label,
                            style: TextStyle(
                              color: dlg.text,
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            description,
                            style: TextStyle(
                              color: dlg.textSub,
                              fontSize: 13,
                              height: 1.25,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: dlg.textSub,
                      size: 22,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }

      return _HomeworkCheckGlassPanel(
        icon: Icons.fact_check_outlined,
        title: '숙제 검사 대상입니다',
        shrinkWrap: true,
        onClose: () => Navigator.of(dialogContext).pop(),
        actions: const <Widget>[],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              homeworkTitle,
              style: TextStyle(
                color: dlg.text,
                fontSize: 18,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              dueMetaLabel,
              style: TextStyle(
                color: dlg.textSub,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 18),
            actionCard(
              label: '채점 시작',
              description: '제출한 숙제를 채점하고 원래 숙제를 종료합니다.',
              value: _HomeworkInspectionChoice.grade,
              icon: Icons.fact_check_outlined,
            ),
            actionCard(
              label: '숙제 안 함',
              description: '0%로 기록하고 그룹 전체를 다음 수업으로 연기합니다.',
              value: _HomeworkInspectionChoice.notDone,
              icon: Icons.assignment_late_outlined,
            ),
            actionCard(
              label: '두고 옴',
              description: '안 함과 동일하게 처리하고 알림장에 사유를 표시합니다.',
              value: _HomeworkInspectionChoice.leftBehind,
              icon: Icons.inventory_2_outlined,
            ),
          ],
        ),
        bottomChild: Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(
                _homeworkCheckActionButtonHeight / 2,
              ),
              onTap: () => Navigator.of(dialogContext).pop(),
              child: Container(
                height: _homeworkCheckActionButtonHeight,
                padding: const EdgeInsets.symmetric(horizontal: 18),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: dlg.chipBg,
                  borderRadius: BorderRadius.circular(
                    _homeworkCheckActionButtonHeight / 2,
                  ),
                ),
                child: Text(
                  '취소',
                  style: TextStyle(
                    color: dlg.chipText,
                    fontSize: FabTabBarTokens.fabBarLabelFontSize,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

Future<_HomeworkCheckTarget?> _resolveHomeworkCheckTarget(
  String studentId,
  String homeworkItemId, {
  bool includeHistory = true,
}) async {
  final active =
      await HomeworkAssignmentStore.instance.loadActiveAssignments(studentId);
  final activeCandidates = active
      .where((a) => a.homeworkItemId == homeworkItemId)
      .toList()
    ..sort((a, b) => a.assignedAt.compareTo(b.assignedAt));
  if (activeCandidates.isNotEmpty) {
    final target = activeCandidates.last;
    return _HomeworkCheckTarget(
      assignmentId: target.id,
      assignedAt: target.assignedAt,
      dueDate: target.dueDate,
      progress: target.progress,
      issueType: target.issueType,
      issueNote: target.issueNote,
    );
  }

  if (!includeHistory) return null;

  final history = await HomeworkAssignmentStore.instance
      .loadAssignmentsForItem(studentId, homeworkItemId);
  if (history.isEmpty) return null;
  history.sort((a, b) => a.assignedAt.compareTo(b.assignedAt));
  final target = history.last;
  return _HomeworkCheckTarget(
    assignmentId: target.id,
    assignedAt: target.assignedAt,
    dueDate: target.dueDate,
    progress: target.progress,
    issueType: null,
    issueNote: null,
  );
}

List<Widget> _buildHomeworkCheckTargetInfo(
  BuildContext context,
  HomeworkItem hw, {
  required DateTime assignedAt,
  DateTime? dueDate,
  List<HomeworkItem> groupChildren = const <HomeworkItem>[],
  Map<String, int> assignmentCountsByItem = const <String, int>{},
  Map<String, HomeworkAssignmentCycleMeta> cycleMetaByItem =
      const <String, HomeworkAssignmentCycleMeta>{},
}) {
  String extractBookName() {
    final contentRaw = (hw.content ?? '').trim();
    final match = RegExp(r'(?:^|\n)\s*교재:\s*([^\n]+)').firstMatch(contentRaw);
    final fromContent = match?.group(1)?.trim() ?? '';
    if (fromContent.isNotEmpty) return fromContent;
    final hasLinkedTextbook = (hw.bookId ?? '').trim().isNotEmpty &&
        (hw.gradeLabel ?? '').trim().isNotEmpty;
    if (hasLinkedTextbook) {
      final stripped = hw.title
          .trim()
          .replaceFirst(RegExp(r'^\s*\d+\.\d+\.\(\d+\)\s+'), '')
          .trim();
      if (stripped.isNotEmpty) {
        final idx = stripped.indexOf('·');
        if (idx == -1) return stripped;
        final candidate = stripped.substring(0, idx).trim();
        if (candidate.isNotEmpty) return candidate;
      }
    }
    final typeLabel = (hw.type ?? '').trim();
    if (typeLabel.isNotEmpty) return typeLabel;
    return '';
  }

  String extractCourseName() {
    final contentRaw = (hw.content ?? '').trim();
    final match = RegExp(r'(?:^|\n)\s*과정:\s*([^\n]+)').firstMatch(contentRaw);
    return match?.group(1)?.trim() ?? '';
  }

  final bookName = extractBookName();
  final courseName = extractCourseName();
  final bookAndCourse =
      [bookName, courseName].where((s) => s.isNotEmpty).join(' · ');
  final title = hw.title.trim().isEmpty ? '(제목 없음)' : hw.title.trim();
  final page = (hw.page ?? '').trim();
  final count = hw.count;
  final pageAndCount = [
    if (page.isNotEmpty) 'p.$page',
    if (count != null && count > 0) '$count문항',
  ].join('  ');

  int resolveSplitCount(int total, int parts, int round) {
    if (parts <= 1) return total;
    final base = total ~/ parts;
    final remainder = total % parts;
    return base + (round <= remainder ? 1 : 0);
  }

  String childTitle(HomeworkItem child) {
    final title = child.title.trim();
    if (title.isNotEmpty) return title;
    final pageRaw = (child.page ?? '').trim();
    if (pageRaw.isNotEmpty) return 'p.$pageRaw';
    return '(제목 없음)';
  }

  String childPageCount(HomeworkItem child) {
    final pageRaw = (child.page ?? '').trim();
    final pageText = pageRaw.isEmpty ? '' : 'p.$pageRaw';
    final countRaw = child.count ?? 0;
    final safeCount = countRaw < 0 ? 0 : countRaw;
    final meta = cycleMetaByItem[child.id];
    final splitParts =
        (meta?.splitParts ?? child.defaultSplitParts).clamp(1, 4);
    final splitRound = (meta?.splitRound ?? 1).clamp(1, splitParts);
    final splitCount = splitParts <= 1
        ? safeCount
        : resolveSplitCount(safeCount, splitParts, splitRound);
    final countText = safeCount <= 0 ? '' : '$splitCount문항';
    if (pageText.isEmpty && countText.isEmpty) return '';
    if (pageText.isEmpty) return countText;
    if (countText.isEmpty) return pageText;
    return '$pageText · $countText';
  }

  final dateRangeText = _formatDateRange(assignedAt, dueDate);
  final dlg = YggDialogColors.of(context);
  final dateRangeStyle = TextStyle(
    color: dlg.textSub,
    fontSize: 16,
    fontWeight: FontWeight.w600,
  );
  final metaStyle = TextStyle(
    color: dlg.textSub,
    fontSize: 16,
    fontWeight: FontWeight.w600,
  );

  int resolveCheckCount() {
    if (groupChildren.isNotEmpty) {
      return groupChildren.fold<int>(
        0,
        (sum, child) => sum + math.max(0, child.checkCount),
      );
    }
    return math.max(0, hw.checkCount);
  }

  int resolveHomeworkCount() {
    if (groupChildren.isNotEmpty) {
      return groupChildren.fold<int>(0, (sum, child) {
        final raw = assignmentCountsByItem[child.id] ?? 0;
        return sum + math.max(0, raw);
      });
    }
    final raw = assignmentCountsByItem[hw.id] ?? 0;
    return math.max(0, raw);
  }

  final checkHomeworkText =
      '검사 ${resolveCheckCount()}회 · 숙제 ${resolveHomeworkCount()}회';
  const groupTitleFontSize = 20.0;
  final isGroupHomework = groupChildren.isNotEmpty;

  final widgets = <Widget>[
    if (bookAndCourse.isNotEmpty) ...[
      LatexTextRenderer(
        bookAndCourse,
        style: TextStyle(
          color: dlg.text,
          fontSize: 20,
          fontWeight: FontWeight.w900,
        ),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
      ),
      const SizedBox(height: 8),
    ],
    Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: LatexTextRenderer(
            title,
            style: TextStyle(
              color: isGroupHomework
                  ? dlg.text
                  : (bookAndCourse.isNotEmpty ? dlg.textSub : dlg.text),
              fontSize: isGroupHomework ? groupTitleFontSize : 16,
              fontWeight: isGroupHomework
                  ? FontWeight.w800
                  : (bookAndCourse.isNotEmpty
                      ? FontWeight.w600
                      : FontWeight.w800),
            ),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          dateRangeText,
          textAlign: TextAlign.right,
          style: dateRangeStyle,
        ),
      ],
    ),
    const SizedBox(height: 4),
    Row(
      children: [
        Expanded(
          child: Text(
            pageAndCount.isEmpty ? '' : pageAndCount,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: metaStyle,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          checkHomeworkText,
          textAlign: TextAlign.right,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: metaStyle,
        ),
      ],
    ),
  ];
  if (groupChildren.isEmpty) return widgets;

  widgets.addAll([
    const SizedBox(height: 24),
    Container(
      width: double.infinity,
      height: 1,
      color: dlg.divider,
    ),
    const SizedBox(height: 24),
  ]);

  final groupChildTitleStyle = TextStyle(
    color: dlg.groupChildTitle,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 1.2,
  );
  final groupChildMetaStyle = TextStyle(
    color: dlg.textSub,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 1.1,
  );

  for (int i = 0; i < groupChildren.length; i++) {
    final child = groupChildren[i];
    final memo = (child.memo ?? '').trim();
    widgets.add(
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${i + 1}. ',
            style: groupChildTitleStyle,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  childTitle(child),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: groupChildTitleStyle,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        childPageCount(child),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: groupChildMetaStyle,
                      ),
                    ),
                    if (memo.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          memo,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: groupChildMetaStyle,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (i != groupChildren.length - 1) {
      widgets.add(const SizedBox(height: 24));
    }
  }

  return widgets;
}

/// [FabStyleTabBar] 기본 padding(6) 안쪽 하이라이트 알약 높이와 동일.
const double _homeworkCheckActionButtonHeight =
    FabTabBarTokens.fabBarHeight - 12;

/// 확인 버튼 — 라벨+좌우 패딩(20×2) 기준 폭의 130%.
const double _homeworkCheckConfirmButtonWidth = 94.0;

class _HomeworkCheckGlassPanel extends StatelessWidget {
  const _HomeworkCheckGlassPanel({
    required this.icon,
    required this.title,
    required this.child,
    required this.actions,
    required this.onClose,
    this.bottomChild,
    this.shrinkWrap = false,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final Widget? bottomChild;
  final List<Widget> actions;
  final VoidCallback onClose;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    final dlg = YggDialogColors.of(context);
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final glassTint = isDark
        ? UtilityGlassDialogTokens.glassTint
        : FabTabBarTokens.previewAcademyMenuGlassTintLight;
    final glassBorder =
        isDark ? UtilityGlassDialogTokens.borderColor : const Color(0x4D000000);
    final media = MediaQuery.of(context);
    const panelOuterHorizontalPadding = 28.0;
    const panelInnerHorizontalPadding = 22.0;
    final maxWidth = math.min(
      media.size.width - panelOuterHorizontalPadding * 2,
      560.0 * 1.1,
    );
    final maxHeight = math.min(media.size.height * 0.72, 640.0);
    final radius = BorderRadius.circular(28);
    final blurSigma = FabTabBarTokens.previewAcademyMenuGlassBlurSigma;

    return SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            panelOuterHorizontalPadding,
            0,
            panelOuterHorizontalPadding,
            18,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxWidth,
              maxHeight: maxHeight,
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: radius,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0x40000000).withValues(alpha: 0.25),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: radius,
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: BackdropFilter(
                        filter: ui.ImageFilter.blur(
                          sigmaX: blurSigma,
                          sigmaY: blurSigma,
                        ),
                        child: const ColoredBox(color: Colors.transparent),
                      ),
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: glassTint,
                        border: Border.all(color: glassBorder, width: 0.5),
                        borderRadius: radius,
                      ),
                      child: Material(
                        type: MaterialType.transparency,
                        child: Column(
                          mainAxisSize:
                              shrinkWrap ? MainAxisSize.min : MainAxisSize.max,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                panelInnerHorizontalPadding,
                                14,
                                12,
                                8,
                              ),
                              child: Row(
                                children: [
                                  Icon(icon, color: dlg.headerText, size: 24),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: dlg.headerText,
                                        fontSize: 20,
                                        fontWeight: FontWeight.w800,
                                        decoration: TextDecoration.none,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: '닫기',
                                    onPressed: onClose,
                                    icon: Icon(
                                      Icons.close_rounded,
                                      color: dlg.closeIcon,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Divider(height: 1, color: dlg.divider),
                            if (shrinkWrap)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  panelInnerHorizontalPadding,
                                  24,
                                  panelInnerHorizontalPadding,
                                  24,
                                ),
                                child: child,
                              )
                            else
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    panelInnerHorizontalPadding,
                                    24,
                                    panelInnerHorizontalPadding,
                                    24,
                                  ),
                                  child: child,
                                ),
                              ),
                            if (bottomChild != null) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  panelInnerHorizontalPadding,
                                  0,
                                  panelInnerHorizontalPadding,
                                  14,
                                ),
                                child: bottomChild!,
                              ),
                            ] else if (actions.isNotEmpty)
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(18, 10, 18, 14),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    for (var i = 0;
                                        i < actions.length;
                                        i++) ...[
                                      if (i > 0) const SizedBox(width: 8),
                                      actions[i],
                                    ],
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeworkCheckSectionTitle extends StatelessWidget {
  const _HomeworkCheckSectionTitle({
    required this.icon,
    required this.title,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final dlg = YggDialogColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 2),
      child: Row(
        children: [
          Icon(icon, color: dlg.headerText.withValues(alpha: 0.8), size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: dlg.headerText,
                fontSize: 16,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.1,
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            Flexible(child: trailing!),
          ],
        ],
      ),
    );
  }
}

class _HomeworkCheckCard extends StatelessWidget {
  const _HomeworkCheckCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dlg = YggDialogColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: dlg.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: dlg.cardBorder, width: 0.5),
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: child,
        ),
      ),
    );
  }
}

Future<_HomeworkCheckDraft?> _showHomeworkItemCheckDialog({
  required BuildContext context,
  required HomeworkItem hw,
  required _HomeworkCheckTarget target,
  required int minProgress,
  String? studentId,
  bool showStartGradingOption = false,
  List<HomeworkItem> groupChildren = const <HomeworkItem>[],
  Map<String, int> assignmentCountsByItem = const <String, int>{},
  Map<String, HomeworkAssignmentCycleMeta> cycleMetaByItem =
      const <String, HomeworkAssignmentCycleMeta>{},
}) async {
  int progress = minProgress.clamp(0, 150);
  final progressController =
      ImeAwareTextEditingController(text: progress.toString());
  const int sliderMax = 100;
  const int progressMax = 150;
  const validIssues = {'lost', 'forgot', 'other'};
  String? issueType =
      validIssues.contains(target.issueType) ? target.issueType : null;
  bool startGrading = true;
  final noteController = ImeAwareTextEditingController(
    text: issueType == 'other' ? (target.issueNote ?? '') : '',
  );

  var effectiveAssignmentCounts = assignmentCountsByItem;
  final sid = studentId?.trim() ?? '';
  if (effectiveAssignmentCounts.isEmpty && sid.isNotEmpty) {
    effectiveAssignmentCounts =
        await HomeworkAssignmentStore.instance.loadAssignmentCounts(sid);
  }

  final result = await showModalBottomSheet<_HomeworkCheckDraft>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.18),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          final dlg = YggDialogColors.of(ctx);
          return _HomeworkCheckGlassPanel(
            icon: Icons.assignment_turned_in,
            title: '숙제 검사',
            onClose: () => Navigator.of(ctx).pop(null),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _buildHomeworkCheckTargetInfo(
                  ctx,
                  hw,
                  assignedAt: target.assignedAt,
                  dueDate: target.dueDate,
                  groupChildren: groupChildren,
                  assignmentCountsByItem: effectiveAssignmentCounts,
                  cycleMetaByItem: cycleMetaByItem,
                ),
              ),
            ),
            bottomChild: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const _HomeworkCheckSectionTitle(
                  icon: Icons.tune_rounded,
                  title: '완료율',
                ),
                _HomeworkCheckCard(
                  child: Row(
                    children: [
                      Expanded(
                        child: Slider(
                          value: progress > sliderMax
                              ? sliderMax.toDouble()
                              : progress.toDouble(),
                          min: 0,
                          max: sliderMax.toDouble(),
                          divisions: 10,
                          label: '$progress%',
                          activeColor: kDlgAccent,
                          inactiveColor: dlg.border,
                          onChanged: (v) {
                            final next = ((v / 10).round() * 10)
                                .clamp(minProgress, sliderMax);
                            setState(() {
                              progress = next;
                              final text = next.toString();
                              if (progressController.text != text) {
                                progressController.text = text;
                                progressController.selection =
                                    TextSelection.collapsed(
                                        offset: text.length);
                              }
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 70,
                        child: TextField(
                          controller: progressController,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly
                          ],
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: dlg.text,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                          decoration: InputDecoration(
                            suffixText: '%',
                            suffixStyle: TextStyle(
                              color: dlg.textSub,
                              fontSize: 16,
                            ),
                            filled: true,
                            fillColor: dlg.fieldBg,
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(color: dlg.border),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(
                                color: kDlgAccent,
                                width: 1.4,
                              ),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 8,
                            ),
                          ),
                          onChanged: (v) {
                            final parsed = int.tryParse(v);
                            if (parsed == null) return;
                            final safe = parsed.clamp(minProgress, progressMax);
                            setState(() => progress = safe);
                            final safeText = safe.toString();
                            if (safeText != v) {
                              progressController.text = safeText;
                              progressController.selection =
                                  TextSelection.collapsed(
                                      offset: safeText.length);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    YggDialogFilterChip(
                      label: '분실',
                      height: _homeworkCheckActionButtonHeight,
                      labelFontSize: FabTabBarTokens.fabBarLabelFontSize,
                      selected: issueType == 'lost',
                      onSelected: (v) => setState(() {
                        issueType = v ? 'lost' : null;
                        if (issueType != 'other') {
                          noteController.text = '';
                        }
                      }),
                    ),
                    const SizedBox(width: 6),
                    YggDialogFilterChip(
                      label: '잊음',
                      height: _homeworkCheckActionButtonHeight,
                      labelFontSize: FabTabBarTokens.fabBarLabelFontSize,
                      selected: issueType == 'forgot',
                      onSelected: (v) => setState(() {
                        issueType = v ? 'forgot' : null;
                        if (issueType != 'other') {
                          noteController.text = '';
                        }
                      }),
                    ),
                    const SizedBox(width: 6),
                    YggDialogFilterChip(
                      label: '기타',
                      height: _homeworkCheckActionButtonHeight,
                      labelFontSize: FabTabBarTokens.fabBarLabelFontSize,
                      selected: issueType == 'other',
                      onSelected: (v) => setState(() {
                        issueType = v ? 'other' : null;
                        if (!v) noteController.text = '';
                      }),
                    ),
                    if (showStartGradingOption) ...[
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: () {
                          setState(() => startGrading = !startGrading);
                        },
                        behavior: HitTestBehavior.opaque,
                        child: SizedBox(
                          height: _homeworkCheckActionButtonHeight,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 22,
                                height: 22,
                                child: Checkbox(
                                  value: startGrading,
                                  onChanged: (v) {
                                    setState(() => startGrading = v ?? false);
                                  },
                                  activeColor: kDlgAccent,
                                  checkColor: const Color(0xFF10191C),
                                  side: BorderSide(color: dlg.border),
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '바로채점',
                                style: TextStyle(
                                  color: dlg.chipText,
                                  fontSize: FabTabBarTokens.fabBarLabelFontSize,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const Spacer(),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(
                          _homeworkCheckActionButtonHeight / 2,
                        ),
                        onTap: () {
                          final parsed =
                              int.tryParse(progressController.text.trim());
                          final safeProgress =
                              (parsed ?? progress).clamp(minProgress, 150);
                          final issueNote = issueType == 'other'
                              ? noteController.text.trim()
                              : null;
                          Navigator.of(ctx).pop(
                            _HomeworkCheckDraft(
                              progress: safeProgress,
                              issueType: issueType,
                              issueNote:
                                  issueNote?.isEmpty == true ? null : issueNote,
                              startGrading:
                                  showStartGradingOption && startGrading,
                            ),
                          );
                        },
                        child: Container(
                          width: _homeworkCheckConfirmButtonWidth,
                          height: _homeworkCheckActionButtonHeight,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: kDlgAccent,
                            borderRadius: BorderRadius.circular(
                              _homeworkCheckActionButtonHeight / 2,
                            ),
                          ),
                          child: const Text(
                            '확인',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: FabTabBarTokens.fabBarLabelFontSize,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                if (issueType == 'other') ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: noteController,
                    minLines: 1,
                    maxLines: 2,
                    style: TextStyle(color: dlg.text, fontSize: 16),
                    decoration: InputDecoration(
                      hintText: '사유를 입력하세요',
                      hintStyle: TextStyle(
                        color: dlg.hint,
                        fontSize: 16,
                      ),
                      filled: true,
                      fillColor: dlg.fieldBg,
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: dlg.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: kDlgAccent,
                          width: 1.4,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            actions: const [],
          );
        },
      );
    },
  );
  progressController.dispose();
  noteController.dispose();
  return result;
}

Future<void> _runHomeworkCheckAndConfirm({
  required BuildContext context,
  required String studentId,
  required HomeworkItem hw,
  bool markAutoCompleteOnNextWaiting = false,
}) async {
  final latest = HomeworkStore.instance.getById(studentId, hw.id);
  if (latest == null || latest.phase != 3) return;

  final target = await _resolveHomeworkCheckTarget(
    studentId,
    hw.id,
    includeHistory: false,
  );
  if (!context.mounted) return;
  if (target == null) {
    if (markAutoCompleteOnNextWaiting) {
      HomeworkStore.instance.markAutoCompleteOnNextWaiting(hw.id);
    }
    await HomeworkStore.instance.confirm(
      studentId,
      hw.id,
      recordAssignmentCheck: false,
    );
    return;
  }

  final checks = await HomeworkAssignmentStore.instance
      .loadChecksForItem(studentId, hw.id);
  checks.sort((a, b) => a.checkedAt.compareTo(b.checkedAt));
  final previousProgress = checks.isEmpty ? 0 : checks.last.progress;
  final minProgress = math.max(previousProgress, target.progress).clamp(0, 150);

  if (!context.mounted) return;
  final draft = await _showHomeworkItemCheckDialog(
    context: context,
    hw: latest,
    target: target,
    minProgress: minProgress,
    studentId: studentId,
  );
  if (!context.mounted || draft == null) return;

  final saved = await HomeworkAssignmentStore.instance.saveAssignmentCheck(
    assignmentId: target.assignmentId,
    studentId: studentId,
    homeworkItemId: hw.id,
    progress: draft.progress,
    issueType: draft.issueType,
    issueNote: draft.issueNote,
    markCompleted: false,
  );
  if (!context.mounted) return;
  if (!saved) {
    _showHomeworkChipSnackBar(context, '숙제 검사 저장에 실패했습니다.');
    return;
  }

  if (markAutoCompleteOnNextWaiting) {
    HomeworkStore.instance.markAutoCompleteOnNextWaiting(hw.id);
  }
  await HomeworkStore.instance.confirm(
    studentId,
    hw.id,
    recordAssignmentCheck: false,
  );
}

/// 오늘 정규 검사예정이 아닌 그룹 과제 중에서, 학생이 미리(자의로) 더 해온 숙제를
/// 골라 검사 기록만 남기기 위한 선택 다이얼로그(그룹 단위).
/// 기존 검사 흐름과 달리 활성/검사일정 상태는 변경하지 않는다.
Future<bool> _showExtraHomeworkCheckPicker({
  required BuildContext context,
  required String studentId,
  required List<_ExtraCheckGroupCandidate> candidateGroups,
}) async {
  bool recordedAny = false;
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      final media = MediaQuery.of(ctx).size;
      final dialogWidth = math.min(media.width * 0.7, 520.0);
      final listHeight = math.min(media.height * 0.55, 480.0);
      return StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          return AlertDialog(
            backgroundColor: kDlgBg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: const Text(
              '추가로 해온 숙제 검사',
              style: TextStyle(
                color: kDlgText,
                fontWeight: FontWeight.w900,
              ),
            ),
            content: SizedBox(
              width: dialogWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '오늘 정규 검사예정이 아닌 그룹 과제 중, 학생이 미리 해온 숙제를 선택해 검사 기록을 남깁니다.',
                    style: TextStyle(
                      color: kDlgTextSub,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: listHeight,
                    child: candidateGroups.isEmpty
                        ? const Center(
                            child: Text(
                              '추가로 검사할 과제가 없습니다.',
                              style: TextStyle(
                                color: kDlgTextSub,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          )
                        : ListView.separated(
                            itemCount: candidateGroups.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 10),
                            itemBuilder: (context, index) {
                              final g = candidateGroups[index];
                              return _buildExtraCheckGroupCard(
                                g,
                                onTap: () async {
                                  final ok =
                                      await _runExtraHomeworkCheckRecordOnlyForGroup(
                                    context: dialogContext,
                                    studentId: studentId,
                                    group: g.group,
                                    summary: g.summary,
                                    children: g.children,
                                  );
                                  if (ok) {
                                    recordedAny = true;
                                    if (dialogContext.mounted) {
                                      Navigator.of(dialogContext).pop();
                                    }
                                  }
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
                child: const Text('닫기'),
              ),
            ],
          );
        },
      );
    },
  );
  return recordedAny;
}

/// 추가검사 후보 그룹 카드(활성/오늘 검사 현황 카드와 유사한 스타일).
Widget _buildExtraCheckGroupCard(
  _ExtraCheckGroupCandidate candidate, {
  required VoidCallback onTap,
}) {
  final indicatorValue = (candidate.progress.clamp(0, 100)) / 100.0;
  final dueText = candidate.dueDate == null
      ? '검사일 미정'
      : _formatDateWithWeekdayShort(candidate.dueDate!);
  int preDoneMax = 0;
  for (final c in candidate.children) {
    final p = c.preDoneProgress ?? 0;
    if (p > preDoneMax) preDoneMax = p;
  }
  return GestureDetector(
    onTap: onTap,
    behavior: HitTestBehavior.opaque,
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0x221D2B2C),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF31464C)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  candidate.bookAndCourse,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFCAD2C5),
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    height: 1.1,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 120,
                child: Text(
                  candidate.flowLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: Color(0xFF8FA1A1),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    height: 1.1,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  candidate.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kDlgText,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    height: 1.1,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${candidate.children.length}개 과제',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFFCAD2C5),
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                ),
              ),
              if (preDoneMax > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0x3352796F),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '미리 $preDoneMax%',
                    style: const TextStyle(
                      color: Color(0xFF9CC5B8),
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 6),
              const Icon(Icons.add_task_rounded, size: 18, color: kDlgAccent),
            ],
          ),
          const SizedBox(height: 7),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  dueText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kDlgTextSub,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: indicatorValue,
                    minHeight: 7,
                    backgroundColor: const Color(0xFF23363B),
                    valueColor: const AlwaysStoppedAnimation<Color>(kDlgAccent),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${candidate.progress}%',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF8EA3A8),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// 미리 해온 그룹 숙제에 대한 검사 기록만 저장한다(제출/대기/활성 해제 없음).
/// 활성 assignment가 없는 하위 과제는 오늘 날짜 + "자의 추가분" 마커로 생성한다.
Future<bool> _runExtraHomeworkCheckRecordOnlyForGroup({
  required BuildContext context,
  required String studentId,
  required HomeworkGroup group,
  required HomeworkItem summary,
  required List<HomeworkItem> children,
}) async {
  final targetChildren = children
      .where((e) => e.status != HomeworkStatus.completed)
      .toList(growable: false);
  if (targetChildren.isEmpty) return false;

  final groupTitle = group.title.trim().isNotEmpty
      ? group.title.trim()
      : (summary.title.trim().isEmpty ? '이 그룹 과제' : summary.title.trim());

  // 학생이 자의로 미리 해온 과제를 검사한다는 사실을 한 번 더 확인한다.
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kDlgBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      title: const Text(
        '추가 숙제 검사',
        style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
      ),
      content: Text(
        '“$groupTitle” 그룹 과제를 학생이 미리 해온 것으로 보고 추가 검사를 진행할까요?',
        style: const TextStyle(
          color: kDlgTextSub,
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          height: 1.4,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
          child: const Text('취소'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: TextButton.styleFrom(foregroundColor: kDlgAccent),
          child: const Text('진행'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;

  // assignment를 만들지 않고, 학생별 기존 검사/미리해온 기록을 바탕으로
  // 진행률 입력 최소값(이미 검사된 만큼)만 계산한다.
  int globalMinProgress = 0;
  String? issueType;
  String? issueNote;
  for (final child in targetChildren) {
    final checks = await HomeworkAssignmentStore.instance
        .loadChecksForItem(studentId, child.id);
    if (!context.mounted) return false;
    checks.sort((a, b) => a.checkedAt.compareTo(b.checkedAt));
    final lastCheckProgress = checks.isEmpty ? 0 : checks.last.progress;
    final preDone = child.preDoneProgress ?? 0;
    final minProgress =
        math.max(lastCheckProgress, preDone).clamp(0, 150).toInt();
    if (minProgress > globalMinProgress) globalMinProgress = minProgress;
    if (issueType == null && (child.preDoneIssueType?.isNotEmpty ?? false)) {
      issueType = child.preDoneIssueType;
      issueNote = child.preDoneIssueNote;
    }
  }
  if (!context.mounted) return false;

  final dialogTarget = _HomeworkCheckTarget(
    assignmentId: '',
    assignedAt: DateTime.now(),
    dueDate: null,
    progress: globalMinProgress,
    issueType: issueType,
    issueNote: issueNote,
  );
  final assignmentCountsByItem =
      await HomeworkAssignmentStore.instance.loadAssignmentCounts(studentId);
  if (!context.mounted) return false;
  final cycleMetaByItem =
      await HomeworkAssignmentStore.instance.loadLatestCycleMetaByItem(
    studentId,
  );
  if (!context.mounted) return false;
  final targetIds = targetChildren.map((e) => e.id).toSet();
  final groupAssignmentCounts = <String, int>{
    for (final id in targetIds) id: assignmentCountsByItem[id] ?? 0,
  };
  final groupCycleMetaByItem = <String, HomeworkAssignmentCycleMeta>{
    for (final id in targetIds)
      if (cycleMetaByItem[id] != null) id: cycleMetaByItem[id]!,
  };

  final draft = await _showHomeworkItemCheckDialog(
    context: context,
    hw: summary,
    target: dialogTarget,
    minProgress: globalMinProgress,
    groupChildren: targetChildren,
    assignmentCountsByItem: groupAssignmentCounts,
    cycleMetaByItem: groupCycleMetaByItem,
  );
  if (!context.mounted || draft == null) return false;

  // assignment 생성 없이 미리 해온 진행률만 임시 기록한다.
  // 이후 하원/수동으로 숙제를 내줄 때 정식 검사로 소비된다.
  await HomeworkStore.instance.recordPreDoneProgress(
    studentId: studentId,
    itemIds: targetChildren.map((e) => e.id).toList(growable: false),
    progress: draft.progress,
    issueType: draft.issueType,
    issueNote: draft.issueNote,
  );
  if (!context.mounted) return true;
  _showHomeworkChipSnackBar(context, '미리 해온 진행률을 기록했어요.');
  return true;
}

Future<_HomeworkCheckResult?> _runHomeworkCheckDialogOnly({
  required BuildContext context,
  required String studentId,
  required HomeworkItem hw,
}) async {
  final latest = HomeworkStore.instance.getById(studentId, hw.id);
  if (latest == null) return null;

  final target = await _resolveHomeworkCheckTarget(
    studentId,
    hw.id,
    includeHistory: false,
  );
  if (!context.mounted) return null;
  if (target == null) {
    _showHomeworkChipSnackBar(context, '숙제 할당 정보를 찾을 수 없습니다.');
    return null;
  }

  final checks = await HomeworkAssignmentStore.instance
      .loadChecksForItem(studentId, hw.id);
  checks.sort((a, b) => a.checkedAt.compareTo(b.checkedAt));
  final previousProgress = checks.isEmpty ? 0 : checks.last.progress;
  final minProgress = math.max(previousProgress, target.progress).clamp(0, 150);

  if (!context.mounted) return null;
  final draft = await _showHomeworkItemCheckDialog(
    context: context,
    hw: latest,
    target: target,
    minProgress: minProgress,
    studentId: studentId,
    showStartGradingOption: true,
  );
  if (!context.mounted || draft == null) return null;

  final saved = await HomeworkAssignmentStore.instance.saveAssignmentCheck(
    assignmentId: target.assignmentId,
    studentId: studentId,
    homeworkItemId: hw.id,
    progress: draft.progress,
    issueType: draft.issueType,
    issueNote: draft.issueNote,
    markCompleted: false,
  );
  if (!context.mounted) return null;
  if (!saved) {
    _showHomeworkChipSnackBar(context, '숙제 검사 저장에 실패했습니다.');
    return null;
  }
  // 리얼타임 반영 중에도 순서 흔들림이 없도록,
  // 복귀 항목의 order_index를 먼저 "활성 꼬리"로 재배정한 뒤 노출한다.
  await HomeworkStore.instance.placeItemAtActiveTail(
    studentId,
    hw.id,
    activateFromHomework: true,
  );
  if (draft.startGrading) {
    await HomeworkStore.instance.submit(studentId, hw.id);
  } else {
    await HomeworkStore.instance.waitPhase(studentId, hw.id);
  }
  await HomeworkAssignmentStore.instance.clearActiveAssignmentsForItems(
    studentId,
    [hw.id],
  );
  if (!context.mounted) {
    return _HomeworkCheckResult(
      itemIds: [hw.id],
      startGrading: draft.startGrading,
    );
  }
  if (draft.startGrading) {
    _showHomeworkChipSnackBar(context, '숙제 검사 완료 — 제출 상태로 이동했어요.');
  } else {
    _showHomeworkChipSnackBar(
      context,
      '숙제 검사 저장 — 대기 상태로 전환했어요.',
    );
  }
  return _HomeworkCheckResult(
    itemIds: [hw.id],
    startGrading: draft.startGrading,
  );
}

Future<_HomeworkCheckResult?> _runHomeworkCheckDialogForGroup({
  required BuildContext context,
  required String studentId,
  required HomeworkGroup? group,
  required HomeworkItem summary,
  required List<HomeworkItem> children,
}) async {
  final targetChildren = children
      .where((e) => e.status != HomeworkStatus.completed)
      .toList(growable: false);
  if (targetChildren.isEmpty) return null;

  final targets =
      <({HomeworkItem item, _HomeworkCheckTarget target, int min})>[];
  DateTime? earliestAssignedAt;
  DateTime? earliestDueDate;
  String? issueType;
  String? issueNote;

  for (final child in targetChildren) {
    final target = await _resolveHomeworkCheckTarget(
      studentId,
      child.id,
      includeHistory: false,
    );
    if (!context.mounted) return null;
    if (target == null) {
      _showHomeworkChipSnackBar(context, '일부 하위 과제의 숙제 할당 정보를 찾지 못했습니다.');
      return null;
    }

    final checks = await HomeworkAssignmentStore.instance
        .loadChecksForItem(studentId, child.id);
    checks.sort((a, b) => a.checkedAt.compareTo(b.checkedAt));
    final previousProgress = checks.isEmpty ? 0 : checks.last.progress;
    final minProgress =
        math.max(previousProgress, target.progress).clamp(0, 150);

    earliestAssignedAt = earliestAssignedAt == null ||
            target.assignedAt.isBefore(earliestAssignedAt)
        ? target.assignedAt
        : earliestAssignedAt;
    earliestDueDate = _mergeHomeworkDueDate(
      earliestDueDate,
      target.dueDate == null ? null : _dateOnly(target.dueDate!),
    );
    issueType ??= target.issueType;
    issueNote ??= target.issueNote;
    targets.add((item: child, target: target, min: minProgress));
  }

  if (targets.isEmpty || !context.mounted) return null;
  final globalMinProgress =
      targets.fold<int>(0, (maxSoFar, e) => math.max(maxSoFar, e.min));
  final dialogTarget = _HomeworkCheckTarget(
    assignmentId: targets.first.target.assignmentId,
    assignedAt: earliestAssignedAt ?? DateTime.now(),
    dueDate: earliestDueDate,
    progress: globalMinProgress,
    issueType: issueType,
    issueNote: issueNote,
  );
  final assignmentCountsByItem =
      await HomeworkAssignmentStore.instance.loadAssignmentCounts(studentId);
  if (!context.mounted) return null;
  final cycleMetaByItem =
      await HomeworkAssignmentStore.instance.loadLatestCycleMetaByItem(
    studentId,
  );
  if (!context.mounted) return null;
  final targetChildIds = targetChildren.map((e) => e.id).toSet();
  final groupAssignmentCounts = <String, int>{
    for (final id in targetChildIds) id: assignmentCountsByItem[id] ?? 0,
  };
  final groupCycleMetaByItem = <String, HomeworkAssignmentCycleMeta>{
    for (final id in targetChildIds)
      if (cycleMetaByItem[id] != null) id: cycleMetaByItem[id]!,
  };

  final draft = await _showHomeworkItemCheckDialog(
    context: context,
    hw: summary,
    target: dialogTarget,
    minProgress: globalMinProgress,
    showStartGradingOption: true,
    groupChildren: targetChildren,
    assignmentCountsByItem: groupAssignmentCounts,
    cycleMetaByItem: groupCycleMetaByItem,
  );
  if (!context.mounted || draft == null) return null;

  final groupId = (group?.id ??
          HomeworkStore.instance.groupIdOfItem(targets.first.item.id) ??
          '')
      .trim();
  final outcome = await HomeworkAssignmentStore.instance.recordGroupOutcome(
    studentId: studentId,
    groupId: groupId,
    homeworkItemIds: targets.map((entry) => entry.item.id),
    outcome: HomeworkAssignmentOutcome.graded,
    progress: draft.progress,
  );
  if (outcome == null) {
    if (!context.mounted) return null;
    _showHomeworkChipSnackBar(context, '그룹 숙제 검사 저장에 실패했습니다.');
    return null;
  }
  final savedItemIds =
      targets.map((entry) => entry.item.id).toList(growable: false);
  await HomeworkAssignmentStore.instance.clearActiveAssignmentsForItems(
    studentId,
    savedItemIds,
    fromStatuses: const ['assigned', 'in_progress', 'carried_to_class'],
  );

  for (final itemId in savedItemIds) {
    await HomeworkStore.instance.placeItemAtActiveTail(
      studentId,
      itemId,
      activateFromHomework: true,
    );
    if (draft.startGrading) {
      await HomeworkStore.instance.submit(studentId, itemId);
    } else {
      await HomeworkStore.instance.waitPhase(studentId, itemId);
    }
  }
  if (!context.mounted) {
    return _HomeworkCheckResult(
      itemIds: savedItemIds,
      startGrading: draft.startGrading,
    );
  }
  final groupTitle = (group?.title ?? '').trim();
  final summaryTitle = summary.title.trim();
  final prefix = groupTitle.isNotEmpty
      ? groupTitle
      : (summaryTitle.isNotEmpty ? summaryTitle : '그룹 숙제');
  if (draft.startGrading) {
    _showHomeworkChipSnackBar(
      context,
      '$prefix 검사 완료 — 하위 ${savedItemIds.length}개 과제를 제출 상태로 이동했어요.',
    );
  } else {
    _showHomeworkChipSnackBar(
      context,
      '$prefix 검사 저장 — 하위 ${savedItemIds.length}개를 대기 상태로 전환했어요.',
    );
  }
  return _HomeworkCheckResult(
    itemIds: savedItemIds,
    startGrading: draft.startGrading,
  );
}

String _formatDateTime(DateTime dt) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(dt.month)}.${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
}

String _formatDateWithWeekdayAndTime(DateTime dt) {
  String two(int v) => v.toString().padLeft(2, '0');
  const week = ['월', '화', '수', '목', '금', '토', '일'];
  return two(dt.month) +
      '.' +
      two(dt.day) +
      ' (' +
      week[dt.weekday - 1] +
      ') ' +
      two(dt.hour) +
      '시 ' +
      two(dt.minute) +
      '분';
}

String _formatHomeworkOverviewSessionLabel(AttendanceRecord record) {
  String two(int v) => v.toString().padLeft(2, '0');
  const weekLong = ['월요일', '화요일', '수요일', '목요일', '금요일', '토요일', '일요일'];
  final DateTime dt = record.classDateTime;
  final int? sessionNo = record.sessionOrder ?? record.cycle;
  final String sessionLabel =
      sessionNo == null ? '회차미정 수업' : '${sessionNo}회차 수업';
  return '${two(dt.month)}월 ${two(dt.day)}일 ${weekLong[dt.weekday - 1]} ${two(dt.hour)}시 ${two(dt.minute)}분 · $sessionLabel';
}

class _HomeworkDraftEditorController extends ChangeNotifier {
  _HomeworkDraftEditorController({
    required this.studentId,
    required this.attendanceId,
    required this.anchorTime,
  });

  final String studentId;
  final String attendanceId;
  final DateTime anchorTime;

  final Set<String> selectedGroupIds = <String>{};
  final Map<String, DateTime> dueDateByGroupId = <String, DateTime>{};
  final Map<String, HomeworkPlanDestination> destinationByItemId =
      <String, HomeworkPlanDestination>{};
  final Map<String, HomeworkPlanOrigin> originByItemId =
      <String, HomeworkPlanOrigin>{};
  final Set<String> _itemsPresentAtLoad = <String>{};
  final Set<String> _plannedItemIds = <String>{};
  final Set<String> _activeAssignedItemIds = <String>{};

  /// 이번 수업 패널 생애 동안 오늘/다음 계획에 한 번이라도 속한 항목.
  /// 완료돼도 진행·계획 요약에서 빠지지 않게 누적한다.
  /// (다음을 오늘로 뭉개지 않도록 destination을 함께 보관)
  final Map<String, HomeworkPlanDestination> _sessionTodayPlanDestinations =
      <String, HomeworkPlanDestination>{};

  /// 목표 제시 스냅샷(패널을 닫아도 유지 — 홈 카드 '+' 판정용).
  final Set<String> goalSnapshotItemIds = <String>{};
  DateTime? goalSnapshotAt;
  bool get hasGoalSnapshot => goalSnapshotAt != null;

  bool loading = true;
  bool saving = false;
  bool _disposed = false;
  DateTime? defaultDueDate;

  Future<void> load() async {
    loading = true;
    notifyListeners();
    try {
      final activeAssignments = await HomeworkAssignmentStore.instance
          .loadActiveAssignments(studentId);
      final assignedItemIds = activeAssignments
          .map((assignment) => assignment.homeworkItemId.trim())
          .where((id) => id.isNotEmpty)
          .toSet();
      _activeAssignedItemIds
        ..clear()
        ..addAll(assignedItemIds);
      final candidateGroupIds = <String>{};
      final candidateItemsByGroupId = <String, List<HomeworkItem>>{};
      for (final group in HomeworkStore.instance.groups(studentId)) {
        final candidates = HomeworkStore.instance
            .itemsInGroup(studentId, group.id)
            .where((item) =>
                item.status != HomeworkStatus.completed &&
                !assignedItemIds.contains(item.id))
            .toList(growable: false);
        if (candidates.isNotEmpty) {
          candidateGroupIds.add(group.id);
          candidateItemsByGroupId[group.id] = candidates;
        }
      }
      final defaultSelection = await buildDefaultHomeworkAssignSelection(
        studentId,
        anchorTime: anchorTime,
      );
      defaultDueDate = defaultSelection?.dueDate;
      final draft = await HomeworkDepartureDraftService.instance.load(
        attendanceId,
        force: true,
      );
      final plans = await HomeworkSessionPlanService.instance.load(
        attendanceId,
        studentId: studentId,
        force: true,
      );
      destinationByItemId.clear();
      originByItemId.clear();
      _itemsPresentAtLoad.clear();
      _plannedItemIds.clear();
      for (final entry in candidateItemsByGroupId.entries) {
        for (final item in entry.value) {
          _itemsPresentAtLoad.add(item.id);
          destinationByItemId[item.id] = HomeworkPlanDestination.inClass;
          originByItemId[item.id] = HomeworkPlanOrigin.plannedToday;
        }
      }
      for (final plan in plans) {
        _plannedItemIds.add(plan.homeworkItemId);
        destinationByItemId[plan.homeworkItemId] = plan.uiDestination;
        originByItemId[plan.homeworkItemId] = plan.origin;
      }
      selectedGroupIds
        ..clear()
        ..addAll(candidateItemsByGroupId.entries
            .where((entry) => entry.value.any((item) =>
                destinationByItemId[item.id] ==
                HomeworkPlanDestination.homework))
            .map((entry) => entry.key));
      if (plans.isEmpty && draft?.isSaved == true) {
        selectedGroupIds
            .addAll(draft!.groupIds.intersection(candidateGroupIds));
        for (final groupId in selectedGroupIds) {
          for (final item
              in candidateItemsByGroupId[groupId] ?? const <HomeworkItem>[]) {
            destinationByItemId[item.id] = HomeworkPlanDestination.homework;
          }
        }
      }
      dueDateByGroupId
        ..clear()
        ..addEntries(
          candidateGroupIds
              .map((groupId) => MapEntry(
                    groupId,
                    _normalizedDueDate(draft?.dueDateByGroupId[groupId]),
                  ))
              .where((entry) => entry.value != null)
              .map((entry) => MapEntry(entry.key, entry.value!)),
        );
      for (final plan in plans) {
        final dueDate = _normalizedDueDate(plan.targetClassAt);
        final localGroupId =
            HomeworkStore.instance.groupIdOfItem(plan.homeworkItemId)?.trim();
        if (dueDate != null &&
            localGroupId != null &&
            localGroupId.isNotEmpty) {
          dueDateByGroupId[localGroupId] = dueDate;
        }
      }
      _captureSessionTodayPlanDestinations();
      if (draft?.hasGoalSnapshot == true) {
        goalSnapshotItemIds
          ..clear()
          ..addAll(draft!.planSnapshotItemIds);
        goalSnapshotAt = draft.planSnapshotAt;
      }
    } catch (_) {
      selectedGroupIds.clear();
      dueDateByGroupId.clear();
      destinationByItemId.clear();
      originByItemId.clear();
      _plannedItemIds.clear();
      _activeAssignedItemIds.clear();
    } finally {
      loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  void _captureSessionTodayPlanDestinations() {
    for (final entry in destinationByItemId.entries) {
      if (entry.value == HomeworkPlanDestination.inClass ||
          entry.value == HomeworkPlanDestination.nextSession) {
        _sessionTodayPlanDestinations[entry.key] = entry.value;
      }
    }
  }

  void _rememberSessionPlanDestination(
    String itemId,
    HomeworkPlanDestination destination,
  ) {
    if (destination != HomeworkPlanDestination.inClass &&
        destination != HomeworkPlanDestination.nextSession) {
      return;
    }
    final id = itemId.trim();
    if (id.isEmpty) return;
    _sessionTodayPlanDestinations[id] = destination;
  }

  bool _isSessionTodayPlanItem(String itemId) {
    final id = itemId.trim();
    if (id.isEmpty) return false;
    if (_sessionTodayPlanDestinations.containsKey(id)) return true;
    if (_plannedItemIds.contains(id) || _itemsPresentAtLoad.contains(id)) {
      final destination = destinationForItem(id);
      return destination == HomeworkPlanDestination.inClass ||
          destination == HomeworkPlanDestination.nextSession;
    }
    return false;
  }

  HomeworkPlanDestination _effectiveDestinationForSummary(String itemId) {
    final mapped = destinationByItemId[itemId];
    if (mapped != null) return mapped;
    // 완료 후 reload로 map에서 빠져도, 세션에 기록된 오늘/다음을 유지한다.
    final remembered = _sessionTodayPlanDestinations[itemId];
    if (remembered != null) return remembered;
    return destinationForItem(itemId);
  }

  /// 이번 수업 시작 시각 이전으로 저장된 검사일은 지난 회차의 잔여값이므로
  /// 다음 수업 시작 시각(기본값)으로 되돌린다.
  DateTime? _normalizedDueDate(DateTime? value) {
    if (value == null) return defaultDueDate;
    return value.isAfter(anchorTime) ? value : defaultDueDate;
  }

  HomeworkPlanDestination destinationForGroup(
    String groupId,
    List<HomeworkItem> children,
  ) {
    if (children.isEmpty) return HomeworkPlanDestination.inClass;
    final destinations = children
        .map((item) =>
            destinationByItemId[item.id] ?? HomeworkPlanDestination.inClass)
        .toSet();
    return destinations.length == 1
        ? destinations.first
        : HomeworkPlanDestination.inClass;
  }

  HomeworkPlanDestination destinationForItem(String itemId) {
    return destinationByItemId[itemId] ?? HomeworkPlanDestination.inClass;
  }

  Future<void> setGroupDestination(
    String groupId,
    List<HomeworkItem> children,
    HomeworkPlanDestination destination,
  ) async {
    if (children.isEmpty || saving) return;
    final previous = <String, HomeworkPlanDestination>{
      for (final item in children) item.id: destinationForItem(item.id),
    };
    final isDirect =
        children.every((item) => !_itemsPresentAtLoad.contains(item.id));
    final origin = isDirect && destination == HomeworkPlanDestination.homework
        ? HomeworkPlanOrigin.directHomework
        : HomeworkPlanOrigin.plannedToday;
    for (final item in children) {
      destinationByItemId[item.id] = destination;
      originByItemId[item.id] = origin;
    }
    if (destination == HomeworkPlanDestination.homework) {
      selectedGroupIds.add(groupId);
      final dueDate = defaultDueDate;
      if (dueDate != null) {
        dueDateByGroupId.putIfAbsent(groupId, () => dueDate);
      }
    } else {
      selectedGroupIds.remove(groupId);
      if (destination == HomeworkPlanDestination.inClass ||
          destination == HomeworkPlanDestination.nextSession) {
        for (final item in children) {
          _rememberSessionPlanDestination(item.id, destination);
        }
      }
    }
    notifyListeners();
    try {
      await HomeworkSessionPlanService.instance.setGroupDestination(
        attendanceId: attendanceId,
        studentId: studentId,
        groupId: groupId,
        itemIds: children.map((item) => item.id),
        destination: destination,
        origin: origin,
        targetClassAt: destination == HomeworkPlanDestination.inClass
            ? null
            : (dueDateByGroupId[groupId] ?? defaultDueDate),
      );
      HomeworkDepartureDraftService.instance.invalidate(attendanceId);
      if (destination == HomeworkPlanDestination.homework) {
        for (final item in children) {
          item.status = HomeworkStatus.homework;
        }
        HomeworkStore.instance.bumpRevision();
      }
    } catch (_) {
      for (final entry in previous.entries) {
        destinationByItemId[entry.key] = entry.value;
      }
      if (previous.values
          .any((value) => value == HomeworkPlanDestination.homework)) {
        selectedGroupIds.add(groupId);
      } else {
        selectedGroupIds.remove(groupId);
      }
      notifyListeners();
      rethrow;
    }
  }

  Future<void> setChildDestination(
    String groupId,
    List<HomeworkItem> children,
    String itemId,
    HomeworkPlanDestination destination,
  ) async {
    if (children.isEmpty || saving) return;
    final previous = destinationForItem(itemId);
    final isDirect =
        children.every((item) => !_itemsPresentAtLoad.contains(item.id));
    destinationByItemId[itemId] = destination;
    notifyListeners();
    try {
      await HomeworkSessionPlanService.instance.setGroupDestination(
        attendanceId: attendanceId,
        studentId: studentId,
        groupId: groupId,
        itemIds: children.map((item) => item.id),
        destination: destinationForGroup(groupId, children),
        origin: isDirect && destination == HomeworkPlanDestination.homework
            ? HomeworkPlanOrigin.directHomework
            : HomeworkPlanOrigin.plannedToday,
        childOverrides: <String, HomeworkPlanDestination>{
          for (final item in children) item.id: destinationForItem(item.id),
        },
        targetClassAt: dueDateByGroupId[groupId] ?? defaultDueDate,
      );
      HomeworkDepartureDraftService.instance.invalidate(attendanceId);
      if (destination == HomeworkPlanDestination.homework) {
        for (final item in children.where((item) => item.id == itemId)) {
          item.status = HomeworkStatus.homework;
        }
        HomeworkStore.instance.bumpRevision();
      } else if (destination == HomeworkPlanDestination.inClass ||
          destination == HomeworkPlanDestination.nextSession) {
        _rememberSessionPlanDestination(itemId, destination);
      }
      selectedGroupIds
        ..remove(groupId)
        ..addAll(destinationByItemId.entries
            .where((entry) =>
                entry.value == HomeworkPlanDestination.homework &&
                children.any((item) => item.id == entry.key))
            .map((_) => groupId));
    } catch (_) {
      destinationByItemId[itemId] = previous;
      notifyListeners();
      rethrow;
    }
  }

  ({int minutes, bool hasUnestimated}) totalFor(
    HomeworkPlanDestination destination,
  ) {
    var minutes = 0;
    var hasUnestimated = false;
    for (final group in HomeworkStore.instance.groups(studentId)) {
      final matched = <HomeworkItem>[];
      for (final item in HomeworkStore.instance.itemsInGroup(
        studentId,
        group.id,
        includeCompleted: true,
      )) {
        final inSessionToday = _isSessionTodayPlanItem(item.id);
        if (item.status == HomeworkStatus.completed &&
            !inSessionToday &&
            !_plannedItemIds.contains(item.id)) {
          continue;
        }
        if (_activeAssignedItemIds.contains(item.id) &&
            !inSessionToday &&
            !_plannedItemIds.contains(item.id)) {
          continue;
        }
        if (_effectiveDestinationForSummary(item.id) != destination) {
          continue;
        }
        matched.add(item);
      }
      if (matched.isEmpty) continue;
      // 그룹당 α 1회 — 하위과제마다 α를 더하지 않는다.
      final groupTotal = _groupRecommendedMinutesOf(matched);
      minutes += groupTotal.minutes;
      hasUnestimated = hasUnestimated || groupTotal.hasUnestimated;
    }
    return (minutes: minutes, hasUnestimated: hasUnestimated);
  }

  ({int minutes, bool hasUnestimated}) totalForTodayPlan() {
    final today = totalFor(HomeworkPlanDestination.inClass);
    final carry = totalFor(HomeworkPlanDestination.nextSession);
    return (
      minutes: today.minutes + carry.minutes,
      hasUnestimated: today.hasUnestimated || carry.hasUnestimated,
    );
  }

  int elapsedMinutesForToday() {
    var elapsedMs = 0;
    final now = DateTime.now();
    for (final group in HomeworkStore.instance.groups(studentId)) {
      for (final item in HomeworkStore.instance.itemsInGroup(
        studentId,
        group.id,
        includeCompleted: true,
      )) {
        final inSessionToday = _isSessionTodayPlanItem(item.id);
        if (item.status == HomeworkStatus.completed &&
            !inSessionToday &&
            !_plannedItemIds.contains(item.id)) {
          continue;
        }
        if (_activeAssignedItemIds.contains(item.id) &&
            !inSessionToday &&
            !_plannedItemIds.contains(item.id)) {
          continue;
        }
        final destination = _effectiveDestinationForSummary(item.id);
        if (destination != HomeworkPlanDestination.inClass &&
            destination != HomeworkPlanDestination.nextSession) {
          continue;
        }
        // 세션 오늘/다음 계획에 속했던 완료 과제는 계속 누적한다.
        if (item.status == HomeworkStatus.completed && !inSessionToday) {
          continue;
        }
        elapsedMs += item.accumulatedMs;
        final runStart = item.runStart;
        if (item.phase == 2 && runStart != null) {
          elapsedMs +=
              now.difference(runStart).inMilliseconds.clamp(0, 1 << 62).toInt();
        }
      }
    }
    if (elapsedMs <= 0) return 0;
    return (elapsedMs / Duration.millisecondsPerMinute).ceil();
  }

  Future<void> setDueDate(
    String groupId,
    List<HomeworkItem> children,
    DateTime dueDate,
  ) async {
    final previous = dueDateByGroupId[groupId];
    dueDateByGroupId[groupId] = dueDate;
    selectedGroupIds.add(groupId);
    notifyListeners();
    try {
      final itemIds = children.map((item) => item.id).toList(growable: false);
      await Future.wait([
        HomeworkSessionPlanService.instance.updateDueDate(
          attendanceId: attendanceId,
          homeworkItemIds: itemIds,
          dueDate: dueDate,
        ),
        HomeworkAssignmentStore.instance.updateActiveDueDateForItems(
          studentId: studentId,
          homeworkItemIds: itemIds,
          dueDate: dueDate,
        ),
      ]);
    } catch (_) {
      if (previous == null) {
        dueDateByGroupId.remove(groupId);
      } else {
        dueDateByGroupId[groupId] = previous;
      }
      notifyListeners();
      rethrow;
    }
  }

  /// 목표 제시 스냅샷에 넣을 item id.
  /// 홈에 보이는 카드(=계획 선언 시점의 목표)가 빠지면 기존 카드에도 '+'가 붙으므로,
  /// 에디터 destination뿐 아니라 현재 홈 칩에 올라온 과제를 모두 포함한다.
  Set<String> collectGoalSnapshotItemIds() {
    final ids = <String>{};
    void addId(String itemId) {
      final id = itemId.trim();
      if (id.isNotEmpty) ids.add(id);
    }

    void considerDestination(
      String itemId,
      HomeworkPlanDestination destination,
    ) {
      if (destination == HomeworkPlanDestination.inClass ||
          destination == HomeworkPlanDestination.nextSession) {
        addId(itemId);
      }
    }

    for (final entry in destinationByItemId.entries) {
      considerDestination(
        entry.key,
        _effectiveDestinationForSummary(entry.key),
      );
    }
    for (final entry in _sessionTodayPlanDestinations.entries) {
      considerDestination(entry.key, entry.value);
    }

    // 홈 칩과 동일 필터로 "지금 화면에 있는 과제"를 스냅샷에 고정한다.
    for (final group in HomeworkStore.instance.groups(studentId)) {
      for (final item in HomeworkStore.instance.itemsInGroup(
        studentId,
        group.id,
      )) {
        if (item.status == HomeworkStatus.completed) continue;
        if (HomeworkStore.instance.isOptimisticallyCompleting(item.id)) {
          continue;
        }
        addId(item.id);
      }
    }
    return ids;
  }

  Future<void> save() async {
    if (saving) return;
    saving = true;
    notifyListeners();
    try {
      final plans = await HomeworkSessionPlanService.instance.load(
        attendanceId,
        studentId: studentId,
        force: true,
      );
      final savedGroupIds = <String>{...selectedGroupIds};
      final savedDueDates = <String, DateTime>{...dueDateByGroupId};
      for (final plan in plans.where((entry) => entry.isPendingHomework)) {
        final actualGroupId = plan.groupId.trim();
        if (actualGroupId.isEmpty) continue;
        savedGroupIds.add(actualGroupId);
        final localGroupId =
            HomeworkStore.instance.groupIdOfItem(plan.homeworkItemId)?.trim();
        final dueDate = (localGroupId == null || localGroupId.isEmpty)
            ? null
            : dueDateByGroupId[localGroupId];
        final resolvedDueDate = dueDate ?? plan.targetClassAt ?? defaultDueDate;
        if (resolvedDueDate != null) {
          savedDueDates[actualGroupId] ??= resolvedDueDate;
        }
      }
      // 서버 plan row 기준으로도 오늘/다음을 보강해 스냅샷 누락을 막는다.
      final snapshotItemIds = collectGoalSnapshotItemIds();
      for (final plan in plans) {
        final ui = plan.uiDestination;
        if (ui == HomeworkPlanDestination.inClass ||
            ui == HomeworkPlanDestination.nextSession) {
          final id = plan.homeworkItemId.trim();
          if (id.isNotEmpty) snapshotItemIds.add(id);
        }
      }
      await HomeworkDepartureDraftService.instance.save(
        attendanceId: attendanceId,
        groupIds: savedGroupIds,
        dueDateByGroupId: savedDueDates,
        planSnapshotItemIds: snapshotItemIds,
        presentGoalSnapshot: true,
      );
      goalSnapshotItemIds
        ..clear()
        ..addAll(snapshotItemIds);
      goalSnapshotAt = DateTime.now();
      debugPrint(
        '[HW][goal-snapshot] attendance=$attendanceId '
        'items=${snapshotItemIds.length}',
      );
    } finally {
      saving = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class _HomeworkDraftCardExtension extends StatelessWidget {
  const _HomeworkDraftCardExtension({
    required this.groupId,
    required this.children,
    required this.width,
    required this.height,
    required this.enabled,
    required this.dueDateEnabled,
    required this.destination,
    required this.childDestinations,
    required this.expanded,
    required this.dueDate,
    required this.existingHomework,
    required this.onDestinationChanged,
    required this.onChildDestinationChanged,
    required this.onDueDateChanged,
  });

  final String groupId;
  final List<HomeworkItem> children;
  final double width;
  final double height;
  final bool enabled;
  final bool dueDateEnabled;
  final HomeworkPlanDestination destination;
  final Map<String, HomeworkPlanDestination> childDestinations;
  final bool expanded;
  final DateTime? dueDate;
  final bool existingHomework;
  final ValueChanged<HomeworkPlanDestination> onDestinationChanged;
  final void Function(String itemId, HomeworkPlanDestination destination)
      onChildDestinationChanged;
  final ValueChanged<DateTime> onDueDateChanged;

  String _formatDueDay(DateTime? value) {
    if (value == null) return '날짜 미정';
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(value.month)}.${two(value.day)}';
  }

  String _formatDueTime(DateTime? value) {
    if (value == null) return '--:--';
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(value.hour)}:${two(value.minute)}';
  }

  String _destinationLabel(HomeworkPlanDestination value) {
    switch (value) {
      case HomeworkPlanDestination.inClass:
        return '오늘';
      case HomeworkPlanDestination.homework:
        return '숙제';
      case HomeworkPlanDestination.nextSession:
        return '다음';
    }
  }

  Widget _destinationSelector({
    required HomeworkPlanDestination value,
    required ValueChanged<HomeworkPlanDestination> onChanged,
    required TextStyle labelStyle,
  }) {
    return Row(
      children: HomeworkPlanDestination.values.map((entry) {
        final selected = entry == value;
        final Color fg =
            selected ? Colors.white : (enabled ? kDlgText : kDlgTextSub);
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Material(
              color: selected
                  ? kDlgAccent
                  : (enabled
                      ? kDlgFieldBg
                      : kDlgFieldBg.withValues(alpha: 0.72)),
              shape: StadiumBorder(
                side: BorderSide(
                  color: selected ? kDlgAccent : kDlgBorder,
                ),
              ),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: enabled ? () => onChanged(entry) : null,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                  child: Center(
                    child: Text(
                      _destinationLabel(entry),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: labelStyle.copyWith(
                        color: fg,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(growable: false),
    );
  }

  String _recommendedLabel() {
    final total = _groupRecommendedMinutesOf(children);
    if (total.minutes <= 0) {
      return total.hasUnestimated ? '권장시간 미산정' : '권장 0분';
    }
    final suffix = total.hasUnestimated ? ' + 미산정' : '';
    return '권장 ${_formatRecommendedMinutesCompact(total.minutes)}$suffix';
  }

  Future<void> _pickDueDate(BuildContext context) async {
    if (!dueDateEnabled) return;
    final initial = dueDate ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 730)),
      helpText: '숙제 검사 날짜',
      cancelText: '취소',
      confirmText: '다음',
    );
    if (date == null || !context.mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      helpText: '검사 시간',
      cancelText: '취소',
      confirmText: '확인',
    );
    if (time == null) return;
    onDueDateChanged(
      DateTime(date.year, date.month, date.day, time.hour, time.minute),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cardTheme = _HomeworkCardTheme.of(context);
    // 과제카드 2번째 줄(그룹명)과 동일 타이포.
    final labelStyle = cardTheme.metaStyle;
    final dueTextStyle = labelStyle;
    final groupedCardBackground = FabTabBarTokens.previewAcademyPanelStyleFor(
      Theme.of(context).brightness,
    ).groupedCardBackground;
    final reveal = (width / _homeworkDraftExtensionWidth).clamp(0.0, 1.0);
    // 테두리는 본체+확장을 감싸는 부모 foregroundPainter가 그린다.
    // 여기서 면 테두리를 그리면 이음새 세로선·우측 R 잘림이 생긴다.
    return ClipRect(
      child: Align(
        alignment: Alignment.centerLeft,
        widthFactor: reveal,
        child: ClipRRect(
          borderRadius: const BorderRadius.only(
            topRight: Radius.circular(12),
            bottomRight: Radius.circular(12),
          ),
          child: AnimatedContainer(
            duration: _homeworkChipExpandDuration,
            curve: _homeworkChipExpandCurve,
            width: _homeworkDraftExtensionWidth,
            height: height,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: groupedCardBackground,
            ),
            child: SingleChildScrollView(
              // 과제카드와 동일: top 16 → 교재명, (+행높이+19) → 그룹과제명.
              padding: const EdgeInsets.fromLTRB(0, 16, 0, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _destinationSelector(
                    value: existingHomework
                        ? HomeworkPlanDestination.homework
                        : destination,
                    onChanged: onDestinationChanged,
                    labelStyle: labelStyle,
                  ),
                  // 왼쪽 카드: titleStyle(24×1.1)와 플로우칩 중 큰 높이 + 간격 19
                  // 이 시트의 2번째 줄(권장)을 그룹과제명(row2) Y에 맞춘다.
                  Builder(
                    builder: (context) {
                      const bookFontSize = 24.0;
                      const bookLineHeight = 1.1;
                      const flowChipHeight = 5.0 * 2 + 14.0;
                      const bookToTitleGap = 19.0;
                      const destPillVPad = 8.0;
                      final row1Height = math.max(
                        bookFontSize * bookLineHeight,
                        flowChipHeight,
                      );
                      final labelSize = labelStyle.fontSize ?? 16;
                      final labelHeightFactor = labelStyle.height ?? 1.1;
                      final destPillHeight =
                          destPillVPad * 2 + labelSize * labelHeightFactor;
                      final gap =
                          (row1Height + bookToTitleGap) - destPillHeight;
                      return SizedBox(height: gap.clamp(0.0, 64.0));
                    },
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _recommendedLabel(),
                          style: dueTextStyle.copyWith(
                            color: kDlgTextSub,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (destination == HomeworkPlanDestination.homework ||
                          existingHomework)
                        InkWell(
                          onTap: dueDateEnabled
                              ? () => _pickDueDate(context)
                              : null,
                          child: Text(
                            '검사 ${_formatDueDay(dueDate)} '
                            '${_formatDueTime(dueDate)}',
                            style: dueTextStyle.copyWith(
                              color: dueDateEnabled ? kDlgText : kDlgTextSub,
                              decoration: dueDateEnabled
                                  ? TextDecoration.underline
                                  : null,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (expanded && children.length > 1) ...[
                    const SizedBox(height: 14),
                    const Divider(color: kDlgBorder, height: 1),
                    const SizedBox(height: 8),
                    Text(
                      '하위과제 예외',
                      style: labelStyle.copyWith(
                        color: kDlgTextSub,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    for (final child in children) ...[
                      Text(
                        child.title.trim().isEmpty ? '하위과제' : child.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: labelStyle.copyWith(
                          color: kDlgText,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _destinationSelector(
                        value: childDestinations[child.id] ??
                            HomeworkPlanDestination.inClass,
                        onChanged: (value) =>
                            onChildDestinationChanged(child.id, value),
                        labelStyle: labelStyle,
                      ),
                      const SizedBox(height: 9),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DepartureHomeworkDraftPanel extends StatefulWidget {
  const _DepartureHomeworkDraftPanel({
    required this.studentId,
    required this.attendanceId,
    required this.showContent,
  });

  final String studentId;
  final String attendanceId;
  final bool showContent;

  @override
  State<_DepartureHomeworkDraftPanel> createState() =>
      _DepartureHomeworkDraftPanelState();
}

class _DepartureHomeworkDraftPanelState
    extends State<_DepartureHomeworkDraftPanel> {
  List<
      ({
        HomeworkGroup group,
        List<HomeworkItem> children,
      })> _groups = const [];
  Set<String> _selectedGroupIds = <String>{};
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant _DepartureHomeworkDraftPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.studentId != widget.studentId ||
        oldWidget.attendanceId != widget.attendanceId) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    if (widget.attendanceId.trim().isEmpty) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '현재 출석 회차 정보를 찾을 수 없습니다.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final activeAssignments = await HomeworkAssignmentStore.instance
          .loadActiveAssignments(widget.studentId);
      final hiddenItemIds = activeAssignments
          .map((assignment) => assignment.homeworkItemId.trim())
          .where((id) => id.isNotEmpty)
          .toSet();
      final groups = <({
        HomeworkGroup group,
        List<HomeworkItem> children,
      })>[];
      for (final group in HomeworkStore.instance.groups(widget.studentId)) {
        final children = HomeworkStore.instance
            .itemsInGroup(widget.studentId, group.id)
            .where((item) => item.status != HomeworkStatus.completed)
            .where((item) => !hiddenItemIds.contains(item.id))
            .toList(growable: false);
        if (children.isEmpty) continue;
        groups.add((group: group, children: children));
      }
      final draft = await HomeworkDepartureDraftService.instance.load(
        widget.attendanceId,
        force: true,
      );
      if (!mounted) return;
      final candidateIds = groups.map((entry) => entry.group.id).toSet();
      setState(() {
        _groups = groups;
        _selectedGroupIds = draft?.isSaved == true
            ? draft!.groupIds.intersection(candidateIds)
            : candidateIds;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '숙제 초안을 불러오지 못했습니다.';
      });
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await HomeworkDepartureDraftService.instance.save(
        attendanceId: widget.attendanceId,
        groupIds: _selectedGroupIds,
        dueDateByGroupId: const <String, DateTime>{},
      );
      if (!mounted) return;
      _showHomeworkChipSnackBar(
        context,
        _selectedGroupIds.isEmpty
            ? '숙제 없음으로 초안을 저장했어요.'
            : '숙제 초안 ${_selectedGroupIds.length}그룹을 저장했어요.',
      );
    } catch (_) {
      if (!mounted) return;
      _showHomeworkChipSnackBar(context, '숙제 초안 저장에 실패했습니다.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _groupDetail(List<HomeworkItem> children) {
    final mergedPages = mergeHomeworkItemPageRanges(
      children.map(
        (item) => (page: item.page, unitMappings: item.unitMappings),
      ),
    );
    final totalCount =
        children.fold<int>(0, (sum, item) => sum + (item.count ?? 0));
    return <String>[
      '하위 ${children.length}개',
      if (mergedPages.isNotEmpty) 'p.$mergedPages',
      if (totalCount > 0) '$totalCount문항',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.showContent) return const SizedBox.shrink();
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: kDlgAccent),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              style: const TextStyle(color: kDlgTextSub),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _load,
              style: OutlinedButton.styleFrom(
                foregroundColor: kDlgText,
                side: const BorderSide(color: kDlgBorder),
              ),
              child: const Text('다시 시도'),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '검사 날짜는 다음 수업일로 자동 지정됩니다.',
                  style: TextStyle(
                    color: kDlgTextSub,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${_selectedGroupIds.length}그룹',
                style: const TextStyle(
                  color: kDlgAccent,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _groups.isEmpty
                ? const Center(
                    child: Text(
                      '숙제로 선택할 그룹 과제가 없습니다.',
                      style: TextStyle(
                        color: kDlgTextSub,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  )
                : ListView.separated(
                    physics: const BouncingScrollPhysics(),
                    itemCount: _groups.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final entry = _groups[index];
                      final groupId = entry.group.id;
                      final selected = _selectedGroupIds.contains(groupId);
                      final title = entry.group.title.trim().isEmpty
                          ? entry.children.first.title.trim()
                          : entry.group.title.trim();
                      return Container(
                        decoration: BoxDecoration(
                          color: kDlgFieldBg,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: selected ? kDlgAccent : kDlgBorder,
                          ),
                        ),
                        child: CheckboxListTile(
                          value: selected,
                          onChanged: (value) {
                            setState(() {
                              if (value ?? false) {
                                _selectedGroupIds.add(groupId);
                              } else {
                                _selectedGroupIds.remove(groupId);
                              }
                            });
                          },
                          activeColor: kDlgAccent,
                          checkColor: Colors.white,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(
                            title.isEmpty ? '그룹 과제' : title,
                            style: const TextStyle(
                              color: kDlgText,
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          subtitle: Text(
                            _groupDetail(entry.children),
                            style: const TextStyle(
                              color: kDlgTextSub,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.save_rounded, size: 18),
              label: Text(_saving ? '저장 중' : '초안 저장'),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _HomeworkOverviewSessionFilterOption {
  final String id;
  final String label;
  final DateTime? targetDay;
  final DateTime? from;
  final DateTime? to;

  const _HomeworkOverviewSessionFilterOption({
    required this.id,
    required this.label,
    required this.targetDay,
    required this.from,
    required this.to,
  });
}

final Map<String, Map<String, String>> _flowNameCacheByStudent = {};
final Set<String> _flowLoadingStudentIds = <String>{};
final Map<String, int> _assignmentRevisionByStudent = {};
final Map<String, int> _reservedTitleRevisionByStudent = {};
final Map<String, Future<Map<String, int>>> _assignmentCountsFutureByStudent =
    {};
final Map<String, Future<List<HomeworkAssignmentDetail>>>
    _activeAssignmentsFutureByStudent = {};
final Map<String, Future<Map<String, HomeworkAssignmentCycleMeta>>>
    _assignmentCycleMetaFutureByStudent = {};
final Map<String, int> _gradingProgressRevisionByStudent = {};
final Map<String, Future<Map<String, HomeworkGradingProgressRate>>>
    _gradingProgressFutureByStudent = {};

Map<String, String> _getFlowNamesForStudent(String studentId) {
  final flows = StudentFlowStore.instance.cached(studentId);
  if (flows.isNotEmpty) {
    _flowNameCacheByStudent[studentId] = {for (final f in flows) f.id: f.name};
  }
  final cached = _flowNameCacheByStudent[studentId] ?? <String, String>{};
  if (cached.isEmpty && !_flowLoadingStudentIds.contains(studentId)) {
    _flowLoadingStudentIds.add(studentId);
    unawaited(
      StudentFlowStore.instance.loadForStudent(studentId).then((flows) {
        _flowNameCacheByStudent[studentId] = {
          for (final f in flows) f.id: f.name
        };
      }).whenComplete(() {
        _flowLoadingStudentIds.remove(studentId);
      }),
    );
  }
  return cached;
}

String _formatShortTime(DateTime dt) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(dt.hour)}:${two(dt.minute)}';
}

String _formatDurationMs(int totalMs) {
  final duration = Duration(milliseconds: totalMs);
  if (duration.inHours > 0) {
    return '${duration.inHours}h ${duration.inMinutes.remainder(60).toString().padLeft(2, '0')}m';
  }
  return '${duration.inMinutes.remainder(60).toString().padLeft(2, '0')}:${duration.inSeconds.remainder(60).toString().padLeft(2, '0')}';
}

String _phaseLabel(int phase) {
  switch (phase) {
    case 0:
      return '종료';
    case 1:
      return '대기';
    case 2:
      return '수행';
    case 3:
      return '제출';
    case 4:
      return '확인';
    default:
      return '-';
  }
}

String _statusLabel(HomeworkStatus status) {
  switch (status) {
    case HomeworkStatus.inProgress:
      return '진행중';
    case HomeworkStatus.completed:
      return '완료';
    case HomeworkStatus.homework:
      return '숙제';
  }
}

String _fmtTimeOpt(DateTime? dt) => dt == null ? '-' : _formatDateTime(dt);

Widget _detailRow(String label, String value) {
  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 90,
        child: Text(
          label,
          style: const TextStyle(
            color: kDlgTextSub,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          value.trim().isEmpty ? '-' : value,
          style: const TextStyle(
            color: kDlgText,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            height: 1.3,
          ),
          softWrap: true,
        ),
      ),
    ],
  );
}

({
  String overviewLine1Left,
  String expandLine4Left,
  String expandLine4Right,
  String expandLine5Left,
  String expandLine5Right,
  List<_HomeworkOverviewCompletedChildEntry> expandChildren,
}) _homeworkOverviewExpandParts({
  required String studentId,
  required String itemId,
  required List<HomeworkAssignmentCheck> checks,
  required DateTime assignedAt,
}) {
  final hw = HomeworkStore.instance.getById(studentId, itemId);
  final overviewLine1Left = hw != null ? _homeworkBookCourseLabel(hw) : '-';
  final page = (hw?.page ?? '').trim();
  final expandLine4Left = page.isEmpty ? '-' : 'p.$page';
  final count = hw?.count ?? 0;
  final expandLine4Right = count > 0 ? '${count}문항' : '-';
  final expandLine5Left = '검사 ${checks.length}회';
  final expandLine5Right = _formatDateTime(assignedAt);
  final sortedChecks = List<HomeworkAssignmentCheck>.from(checks)
    ..sort((a, b) => b.checkedAt.compareTo(a.checkedAt));
  final expandChildren = <_HomeworkOverviewCompletedChildEntry>[
    for (int i = 0; i < sortedChecks.length; i++)
      _HomeworkOverviewCompletedChildEntry(
        title: '${i + 1}. ${_formatDateTime(sortedChecks[i].checkedAt)}',
        pageCount: '진행 ${sortedChecks[i].progress}%',
        memo: '',
      ),
  ];
  return (
    overviewLine1Left: overviewLine1Left,
    expandLine4Left: expandLine4Left,
    expandLine4Right: expandLine4Right,
    expandLine5Left: expandLine5Left,
    expandLine5Right: expandLine5Right,
    expandChildren: expandChildren,
  );
}

Widget _buildHomeworkOverviewCard(
  _HomeworkOverviewEntry entry, {
  required bool isExpanded,
  VoidCallback? onTap,
}) {
  final double indicatorValue = (entry.progress.clamp(0, 100)) / 100.0;
  final String dueLeftText = entry.dueDate == null
      ? '미정'
      : _formatDateWithWeekdayShort(entry.dueDate!);
  final String checkLabelText = entry.checkedToday
      ? (entry.checkedAt == null
          ? '완료'
          : '완료 (${_formatDateTime(entry.checkedAt!)})')
      : '미완료';

  final childRows = <Widget>[];
  for (int i = 0; i < entry.expandChildren.length; i++) {
    final child = entry.expandChildren[i];
    childRows.add(
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              child.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFB9C3BA),
                fontSize: 14,
                fontWeight: FontWeight.w700,
                height: 1.15,
              ),
            ),
            const SizedBox(height: 3),
            SizedBox(
              width: double.infinity,
              child: Text(
                child.pageCount.isEmpty ? '-' : child.pageCount,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: Color(0xFF8FA1A1),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                ),
              ),
            ),
            if (child.memo.isNotEmpty) ...[
              const SizedBox(height: 2),
              SizedBox(
                width: double.infinity,
                child: Text(
                  child.memo,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: Color(0xFF7D8E8F),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    height: 1.1,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
    if (i != entry.expandChildren.length - 1) {
      childRows.addAll([
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          height: 1,
          color: const Color(0x223A4545),
        ),
        const SizedBox(height: 6),
      ]);
    }
  }

  final card = AnimatedContainer(
    duration: const Duration(milliseconds: 170),
    curve: Curves.easeOutCubic,
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: const Color(0x332C2C2E),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: isExpanded
            ? kDlgAccent.withValues(alpha: 0.45)
            : const Color(0x22FFFFFF),
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                entry.overviewLine1Left,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFFCDD5D5),
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 120,
              child: Text(
                entry.flowLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: kDlgTextSub,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                entry.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kDlgText,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  height: 1.1,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${entry.childCount}개 과제',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFCAD2C5),
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                height: 1.1,
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              isExpanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              size: 18,
              color: kDlgTextSub,
            ),
          ],
        ),
        const SizedBox(height: 7),
        if (!isExpanded)
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  dueLeftText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kDlgTextSub,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: indicatorValue,
                    minHeight: 7,
                    backgroundColor: const Color(0xFF23363B),
                    valueColor: const AlwaysStoppedAnimation<Color>(kDlgAccent),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${entry.progress}%',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF8EA3A8),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                ),
              ),
            ],
          )
        else
          Row(
            children: [
              Expanded(
                child: Text(
                  '내준 ${_formatDateTime(entry.assignedAt)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kDlgTextSub,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                ),
              ),
              Text(
                checkLabelText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color:
                      entry.checkedToday ? kDlgAccent : const Color(0xFF8EA3A8),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                ),
              ),
            ],
          ),
        if (isExpanded) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  entry.expandLine4Left,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF748686),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    height: 1.1,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                entry.expandLine4Right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF748686),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  entry.expandLine5Left,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF748686),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    height: 1.1,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  entry.expandLine5Right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: Color(0xFF748686),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    height: 1.1,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(height: 1, thickness: 1, color: kDlgBorder),
          const SizedBox(height: 8),
          Text(
            '검사 기록 ${entry.expandChildren.length}건',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFFCAD2C5),
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 8),
          if (childRows.isEmpty)
            const Text(
              '검사 기록이 없습니다.',
              style: TextStyle(
                color: kDlgTextSub,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            )
          else
            ...childRows,
        ],
      ],
    ),
  );
  if (onTap == null) return card;
  return GestureDetector(
    onTap: onTap,
    behavior: HitTestBehavior.opaque,
    child: card,
  );
}

String _stripHomeworkUnitPrefix(String raw) {
  return raw.replaceFirst(RegExp(r'^\s*\d+\.\d+\.\(\d+\)\s+'), '').trim();
}

String _extractHomeworkBookName(HomeworkItem hw) {
  final contentRaw = (hw.content ?? '').trim();
  final match = RegExp(r'(?:^|\n)\s*교재:\s*([^\n]+)').firstMatch(contentRaw);
  final fromContent = match?.group(1)?.trim() ?? '';
  if (fromContent.isNotEmpty) return fromContent;

  final hasLinkedTextbook = (hw.bookId ?? '').trim().isNotEmpty &&
      (hw.gradeLabel ?? '').trim().isNotEmpty;
  if (hasLinkedTextbook) {
    final stripped = _stripHomeworkUnitPrefix(hw.title.trim());
    if (stripped.isNotEmpty) {
      final idx = stripped.indexOf('·');
      if (idx == -1) return stripped;
      final candidate = stripped.substring(0, idx).trim();
      if (candidate.isNotEmpty) return candidate;
    }
  }

  final typeLabel = (hw.type ?? '').trim();
  if (typeLabel.isNotEmpty) return typeLabel;
  return '-';
}

String _extractHomeworkCourseName(HomeworkItem hw) {
  final contentRaw = (hw.content ?? '').trim();
  final match = RegExp(r'(?:^|\n)\s*과정:\s*([^\n]+)').firstMatch(contentRaw);
  return match?.group(1)?.trim() ?? '';
}

String _homeworkBookCourseLabel(HomeworkItem hw) {
  final bookName = _extractHomeworkBookName(hw);
  final courseName = _extractHomeworkCourseName(hw);
  return (bookName == '-' || bookName.isEmpty)
      ? (courseName.isEmpty ? '-' : courseName)
      : (courseName.isEmpty ? bookName : '$bookName · $courseName');
}

List<_HomeworkOverviewCompletedGroupEntry>
    _collectRecentCompletedHomeworkGroups(
  String studentId, {
  required Map<String, List<HomeworkAssignmentBrief>> assignmentsByItem,
  Map<String, List<HomeworkAssignmentCheck>> checksByItem =
      const <String, List<HomeworkAssignmentCheck>>{},
  DateTime? targetDay,
  DateTime? windowStart,
  DateTime? windowEnd,
  int limit = 10,
}) {
  final flowNameById = <String, String>{
    for (final flow in StudentFlowStore.instance.cached(studentId))
      flow.id: flow.name,
  };
  final out = <_HomeworkOverviewCompletedGroupEntry>[];
  final groups = HomeworkStore.instance.groups(studentId);
  final now = DateTime.now();
  final DateTime? targetDateOnly =
      targetDay == null ? null : _dateOnly(targetDay);
  final today = _dateOnly(now);

  DateTime? latestTodayCheckAt(String itemId) {
    final checks = checksByItem[itemId];
    if (checks == null || checks.isEmpty) return null;
    DateTime? latest;
    for (final check in checks) {
      if (_dateOnly(check.checkedAt) != today) continue;
      if (latest == null || check.checkedAt.isAfter(latest)) {
        latest = check.checkedAt;
      }
    }
    return latest;
  }

  bool assignmentCompletedToday(String itemId) {
    final briefs = assignmentsByItem[itemId];
    if (briefs == null || briefs.isEmpty) return false;
    for (final brief in briefs) {
      if (brief.status != 'completed') continue;
      // assignment brief에 completed_at이 없어, 오늘 검사 이력과 함께 판정한다.
      if (latestTodayCheckAt(itemId) != null) return true;
    }
    return false;
  }

  DateTime? completedTimestampOf(HomeworkItem child) {
    final todayCheckAt = latestTodayCheckAt(child.id);
    if (child.status == HomeworkStatus.completed || child.completedAt != null) {
      return child.completedAt ??
          todayCheckAt ??
          child.updatedAt ??
          child.createdAt;
    }
    // 오늘 검사로 assignment가 완료됐지만 item 완료 플래그가 아직 없는 경우도 포함한다.
    if (assignmentCompletedToday(child.id)) {
      return todayCheckAt ?? child.updatedAt ?? child.createdAt;
    }
    return null;
  }

  for (final group in groups) {
    final children = HomeworkStore.instance
        .itemsInGroup(
          studentId,
          group.id,
          includeCompleted: true,
        )
        .toList(growable: false);
    if (children.isEmpty) continue;
    final completedChildren = children.where(
      (child) {
        final completedTs = completedTimestampOf(child);
        if (completedTs == null) return false;
        if (targetDateOnly != null &&
            _dateOnly(completedTs) != targetDateOnly) {
          return false;
        }
        if (windowStart != null && completedTs.isBefore(windowStart)) {
          return false;
        }
        if (windowEnd != null && completedTs.isAfter(windowEnd)) {
          return false;
        }
        return true;
      },
    ).toList(growable: false);
    if (completedChildren.isEmpty) continue;

    DateTime latestCompletedAt =
        completedTimestampOf(completedChildren.first) ??
            DateTime.fromMillisecondsSinceEpoch(0);
    int totalDurationMs = 0;
    for (final child in completedChildren) {
      final completedTs = completedTimestampOf(child);
      if (completedTs != null && completedTs.isAfter(latestCompletedAt)) {
        latestCompletedAt = completedTs;
      }
      final int runningMs = child.runStart != null
          ? now.difference(child.runStart!).inMilliseconds
          : 0;
      totalDurationMs += math.max(0, child.accumulatedMs + runningMs);
    }
    final completedAt = latestCompletedAt;
    final title = () {
      final raw = group.title.trim();
      if (raw.isNotEmpty) return raw;
      for (final child in children) {
        final childTitle = child.title.trim();
        if (childTitle.isNotEmpty) return childTitle;
      }
      return '그룹 과제';
    }();
    final flowName = () {
      final groupFlow =
          (flowNameById[(group.flowId ?? '').trim()] ?? '').trim();
      if (groupFlow.isNotEmpty) return groupFlow;
      for (final child in children) {
        final childFlow =
            (flowNameById[(child.flowId ?? '').trim()] ?? '').trim();
        if (childFlow.isNotEmpty) return childFlow;
      }
      return '';
    }();
    final HomeworkItem representativeForBookCourse = () {
      for (final child in children) {
        final label = _homeworkBookCourseLabel(child);
        if (label != '-') return child;
      }
      return children.first;
    }();
    int totalQuestionCount = 0;
    int groupCheckCount = 0;
    int homeworkCount = 0;
    HomeworkAssignmentBrief? latestBrief;
    final groupPageSummary = mergeHomeworkItemPageRanges(
      children.map(
        (item) => (page: item.page, unitMappings: item.unitMappings),
      ),
    );
    for (final child in children) {
      final count = child.count ?? 0;
      if (count > 0) totalQuestionCount += count;
      if (child.checkCount > groupCheckCount) {
        groupCheckCount = child.checkCount;
      }
      final assignmentRows =
          assignmentsByItem[child.id] ?? const <HomeworkAssignmentBrief>[];
      homeworkCount += assignmentRows.length;
      for (final brief in assignmentRows) {
        if (latestBrief == null ||
            brief.assignedAt.isAfter(latestBrief!.assignedAt)) {
          latestBrief = brief;
        }
      }
    }
    final repeatIndex = (latestBrief?.repeatIndex ?? 1).clamp(1, 1 << 30);
    final splitParts = (latestBrief?.splitParts ?? 1).clamp(1, 4);
    final splitRound = (latestBrief?.splitRound ?? 1).clamp(1, splitParts);
    int resolveSplitCount(int total, int parts, int round) {
      if (parts <= 1) return total;
      final base = total ~/ parts;
      final remainder = total % parts;
      return base + (round <= remainder ? 1 : 0);
    }

    final String displayCount = totalQuestionCount <= 0
        ? ''
        : (splitParts <= 1
            ? totalQuestionCount.toString()
            : resolveSplitCount(totalQuestionCount, splitParts, splitRound)
                .toString());
    final String pageSummary =
        groupPageSummary.isEmpty ? '-' : groupPageSummary;
    final String line4Left = 'p.$pageSummary';
    final String line4Right =
        '총 ${displayCount.isNotEmpty ? displayCount : '-'}문항';
    final String line5Left = '검사 ${groupCheckCount}회 · 숙제 ${homeworkCount}회';
    final String splitCycleText =
        splitParts > 1 ? '${splitParts}분할 ${splitRound}차' : '';
    final String line5Right = splitCycleText.isEmpty
        ? '${repeatIndex}회차'
        : '${repeatIndex}회차 · $splitCycleText';

    out.add(
      _HomeworkOverviewCompletedGroupEntry(
        groupId: group.id,
        completedAt: completedAt,
        line1Left: _homeworkBookCourseLabel(representativeForBookCourse),
        line1Right: flowName.isEmpty ? '플로우 미지정' : flowName,
        line2Left: title,
        line2Right: '${children.length}개 과제',
        line3Left: '완료 ${_formatDateTime(completedAt)}',
        line3Right: '총 ${_formatDurationMs(totalDurationMs)}',
        line4Left: line4Left,
        line4Right: line4Right,
        line5Left: line5Left,
        line5Right: line5Right,
        children: [
          for (final child in children)
            _HomeworkOverviewCompletedChildEntry(
              title:
                  child.title.trim().isEmpty ? '(제목 없음)' : child.title.trim(),
              pageCount: [
                if ((child.page ?? '').trim().isNotEmpty)
                  'p.${child.page!.trim()}',
                if ((child.count ?? 0) > 0) '${child.count}문항',
              ].join(' · '),
              memo: (child.memo ?? '').trim(),
            ),
        ],
      ),
    );
  }

  out.sort((a, b) {
    final timeCmp = b.completedAt.compareTo(a.completedAt);
    if (timeCmp != 0) return timeCmp;
    final titleCmp = a.line2Left.compareTo(b.line2Left);
    if (titleCmp != 0) return titleCmp;
    return a.groupId.compareTo(b.groupId);
  });

  if (limit <= 0 || out.length <= limit) return out;
  return out.take(limit).toList(growable: false);
}

Widget _buildCompletedGroupOverviewCard(
  _HomeworkOverviewCompletedGroupEntry entry, {
  required bool isExpanded,
  required VoidCallback onTap,
}) {
  final childRows = <Widget>[];
  for (int i = 0; i < entry.children.length; i++) {
    final child = entry.children[i];
    childRows.add(
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${i + 1}. ${child.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFB9C3BA),
                fontSize: 14,
                fontWeight: FontWeight.w700,
                height: 1.15,
              ),
            ),
            const SizedBox(height: 3),
            SizedBox(
              width: double.infinity,
              child: Text(
                child.pageCount.isEmpty ? '-' : child.pageCount,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: Color(0xFF8FA1A1),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                ),
              ),
            ),
            if (child.memo.isNotEmpty) ...[
              const SizedBox(height: 2),
              SizedBox(
                width: double.infinity,
                child: Text(
                  child.memo,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: Color(0xFF7D8E8F),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    height: 1.1,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
    if (i != entry.children.length - 1) {
      childRows.addAll([
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          height: 1,
          color: const Color(0x223A4545),
        ),
        const SizedBox(height: 6),
      ]);
    }
  }

  return GestureDetector(
    onTap: onTap,
    behavior: HitTestBehavior.opaque,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 170),
      curve: Curves.easeOutCubic,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0x332C2C2E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isExpanded
              ? kDlgAccent.withValues(alpha: 0.45)
              : const Color(0x22FFFFFF),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  entry.line1Left,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFCDD5D5),
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    height: 1.1,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 120,
                child: Text(
                  entry.line1Right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: kDlgTextSub,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    height: 1.1,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  entry.line2Left,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kDlgText,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    height: 1.1,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                entry.line2Right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFFCDD5D5),
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                isExpanded
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: kDlgTextSub,
              ),
            ],
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              Text(
                entry.line3Left,
                style: const TextStyle(
                  color: kDlgTextSub,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
              ),
              const Spacer(),
              Text(
                entry.line3Right,
                style: const TextStyle(
                  color: Color(0xFF8EA3A8),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                ),
              ),
            ],
          ),
          if (isExpanded) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    entry.line4Left,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF748686),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      height: 1.1,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  entry.line4Right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF748686),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    height: 1.1,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    entry.line5Left,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF748686),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      height: 1.1,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(
                    entry.line5Right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: Color(0xFF748686),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      height: 1.1,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Divider(height: 1, thickness: 1, color: kDlgBorder),
            const SizedBox(height: 8),
            Text(
              '그룹 과제 ${entry.children.length}개',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFCAD2C5),
                fontSize: 14.5,
                fontWeight: FontWeight.w700,
                height: 1.1,
              ),
            ),
            const SizedBox(height: 8),
            if (childRows.isEmpty)
              const Text(
                '하위과제가 없습니다.',
                style: TextStyle(
                  color: kDlgTextSub,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              )
            else
              ...childRows,
          ],
        ],
      ),
    ),
  );
}

Future<void> _showHomeworkChipDetailDialog(
  BuildContext context,
  String studentId,
  HomeworkItem hw,
  String flowName,
  int assignmentCount,
) async {
  final bool isRunning =
      HomeworkStore.instance.runningOf(studentId)?.id == hw.id ||
          hw.phase == 2 ||
          hw.runStart != null;
  final int runningMs = hw.runStart != null
      ? DateTime.now().difference(hw.runStart!).inMilliseconds
      : 0;
  final int totalMs = hw.accumulatedMs + runningMs;
  final String durationText = _formatDurationMs(totalMs);
  final int? testLimitMinutes =
      (_isTestHomeworkItem(hw) && (hw.timeLimitMinutes ?? 0) > 0)
          ? hw.timeLimitMinutes
          : null;
  final String durationDisplay = testLimitMinutes == null
      ? durationText
      : '$durationText / ${testLimitMinutes}분';
  final String homeworkText = assignmentCount > 0 ? 'H$assignmentCount' : 'H0';
  final String displayFlow = flowName.isNotEmpty ? flowName : '플로우 미지정';
  final String page = (hw.page ?? '').trim();
  final String count = hw.count?.toString() ?? '';
  final String content = (hw.content ?? '').trim();
  final String body = hw.body.trim();
  final String type = (hw.type ?? '').trim();
  final String title = hw.title.trim().isEmpty ? '(제목 없음)' : hw.title.trim();

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kDlgBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        '과제 상세',
        style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
      ),
      content: SizedBox(
        width: 700,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const YggDialogSectionHeader(
                icon: Icons.info_outline_rounded,
                title: '기본 정보',
              ),
              _detailRow('제목', title),
              const SizedBox(height: 8),
              _detailRow('플로우', displayFlow),
              const SizedBox(height: 8),
              _detailRow('유형', type),
              const SizedBox(height: 8),
              _detailRow('페이지', page),
              const SizedBox(height: 8),
              _detailRow('문항수', count.isEmpty ? '-' : '$count문항'),
              const SizedBox(height: 8),
              _detailRow('진행시간', durationDisplay),
              const SizedBox(height: 8),
              _detailRow('검사횟수', '${hw.checkCount}회'),
              const SizedBox(height: 8),
              _detailRow('숙제여부', homeworkText),
              const SizedBox(height: 8),
              _detailRow('상태', _statusLabel(hw.status)),
              const SizedBox(height: 8),
              _detailRow('단계', _phaseLabel(hw.phase)),
              const SizedBox(height: 8),
              _detailRow('진행중', isRunning ? '예' : '아니오'),
              const SizedBox(height: 10),
              Row(
                children: [
                  const SizedBox(
                    width: 90,
                    child: Text(
                      '색상',
                      style: TextStyle(
                        color: kDlgTextSub,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: hw.color,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.white24),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '0x${hw.color.value.toRadixString(16).toUpperCase().padLeft(8, '0')}',
                    style: const TextStyle(
                      color: kDlgText,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Divider(color: kDlgBorder),
              const SizedBox(height: 10),
              const YggDialogSectionHeader(
                icon: Icons.notes_rounded,
                title: '텍스트',
              ),
              _detailRow('내용', content),
              const SizedBox(height: 8),
              _detailRow('본문', body),
              const SizedBox(height: 14),
              const Divider(color: kDlgBorder),
              const SizedBox(height: 10),
              const YggDialogSectionHeader(
                icon: Icons.schedule_rounded,
                title: '시간 정보',
              ),
              _detailRow('생성', _fmtTimeOpt(hw.createdAt)),
              const SizedBox(height: 8),
              _detailRow('수정', _fmtTimeOpt(hw.updatedAt)),
              const SizedBox(height: 8),
              _detailRow('첫시작', _fmtTimeOpt(hw.firstStartedAt)),
              const SizedBox(height: 8),
              _detailRow('진행시작', _fmtTimeOpt(hw.runStart)),
              const SizedBox(height: 8),
              _detailRow('제출', _fmtTimeOpt(hw.submittedAt)),
              const SizedBox(height: 8),
              _detailRow('확인', _fmtTimeOpt(hw.confirmedAt)),
              const SizedBox(height: 8),
              _detailRow('대기', _fmtTimeOpt(hw.waitingAt)),
              const SizedBox(height: 8),
              _detailRow('완료', _fmtTimeOpt(hw.completedAt)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
          child: const Text('닫기'),
        ),
      ],
    ),
  );
}

Future<void> _openHomeworkEditDialogForHome(
  BuildContext context,
  String studentId,
  HomeworkItem item,
) async {
  final edited = await showDialog<Map<String, dynamic>>(
    context: context,
    builder: (_) => HomeworkEditDialog(
      initialTitle: item.title,
      initialBody: item.body,
      initialColor: item.color,
      initialType: item.type,
      initialPage: item.page,
      initialCount: item.count,
      initialContent: item.content,
    ),
  );
  if (edited == null) return;
  final countStr = (edited['count'] as String?)?.trim();
  final updated = HomeworkItem(
    id: item.id,
    assignmentCode: item.assignmentCode,
    learningTrackCode: item.learningTrackCode,
    title: (edited['title'] as String).trim(),
    body: (edited['body'] as String).trim(),
    color: (edited['color'] as Color),
    flowId: item.flowId,
    testOriginFlowId: item.testOriginFlowId,
    type: (edited['type'] as String?)?.trim(),
    page: (edited['page'] as String?)?.trim(),
    count:
        (countStr == null || countStr.isEmpty) ? null : int.tryParse(countStr),
    timeLimitMinutes: item.timeLimitMinutes,
    memo: item.memo,
    content: (edited['content'] as String?)?.trim(),
    pbPresetId: item.pbPresetId,
    bookId: item.bookId,
    gradeLabel: item.gradeLabel,
    sourceUnitLevel: item.sourceUnitLevel,
    sourceUnitPath: item.sourceUnitPath,
    unitMappings: item.unitMappings == null
        ? null
        : List<Map<String, dynamic>>.from(
            item.unitMappings!.map((e) => Map<String, dynamic>.from(e)),
          ),
    defaultSplitParts: item.defaultSplitParts,
    checkCount: item.checkCount,
    orderIndex: item.orderIndex,
    createdAt: item.createdAt,
    updatedAt: DateTime.now(),
    status: item.status,
    phase: item.phase,
    accumulatedMs: item.accumulatedMs,
    cycleBaseAccumulatedMs: item.cycleBaseAccumulatedMs,
    runStart: item.runStart,
    completedAt: item.completedAt,
    firstStartedAt: item.firstStartedAt,
    submittedAt: item.submittedAt,
    confirmedAt: item.confirmedAt,
    waitingAt: item.waitingAt,
    version: item.version,
  );
  HomeworkStore.instance.edit(studentId, updated);
}

const List<String> _homeworkTypeValues = <String>[
  '프린트',
  '교재',
  '학습',
  '테스트',
];

String _normalizeHomeworkTypeLabel(String raw) {
  final trimmed = raw.trim();
  if (trimmed == '문제집') return '교재';
  if (_homeworkTypeValues.contains(trimmed)) return trimmed;
  return '프린트';
}

Color _colorForHomeworkTypeLabel(String type) {
  switch (_normalizeHomeworkTypeLabel(type)) {
    case '프린트':
      return Colors.blue;
    case '교재':
      return Colors.green;
    case '학습':
      return Colors.purple;
    case '테스트':
      return Colors.red;
    default:
      return Colors.blue;
  }
}

HomeworkItem _copyHomeworkItemForInlineEdit(
  HomeworkItem source, {
  String? page,
  String? memo,
  String? content,
  String? type,
  Color? color,
}) {
  return HomeworkItem(
    id: source.id,
    assignmentCode: source.assignmentCode,
    learningTrackCode: source.learningTrackCode,
    title: source.title,
    body: source.body,
    color: color ?? source.color,
    flowId: source.flowId,
    testOriginFlowId: source.testOriginFlowId,
    type: type ?? source.type,
    page: page ?? source.page,
    count: source.count,
    timeLimitMinutes: source.timeLimitMinutes,
    memo: memo ?? source.memo,
    content: content ?? source.content,
    pbPresetId: source.pbPresetId,
    bookId: source.bookId,
    gradeLabel: source.gradeLabel,
    sourceUnitLevel: source.sourceUnitLevel,
    sourceUnitPath: source.sourceUnitPath,
    unitMappings: source.unitMappings == null
        ? null
        : List<Map<String, dynamic>>.from(
            source.unitMappings!.map((e) => Map<String, dynamic>.from(e)),
          ),
    defaultSplitParts: source.defaultSplitParts,
    checkCount: source.checkCount,
    orderIndex: source.orderIndex,
    createdAt: source.createdAt,
    updatedAt: DateTime.now(),
    status: source.status,
    phase: source.phase,
    accumulatedMs: source.accumulatedMs,
    cycleBaseAccumulatedMs: source.cycleBaseAccumulatedMs,
    runStart: source.runStart,
    completedAt: source.completedAt,
    firstStartedAt: source.firstStartedAt,
    submittedAt: source.submittedAt,
    confirmedAt: source.confirmedAt,
    waitingAt: source.waitingAt,
    version: source.version,
  );
}

Future<void> _showGroupChildPageEditDialog({
  required BuildContext context,
  required String studentId,
  required HomeworkItem child,
}) async {
  final controller =
      ImeAwareTextEditingController(text: (child.page ?? '').trim());
  final submitted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: kDlgBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: const Text(
        '하위 과제 페이지 수정',
        style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
      ),
      content: TextField(
        controller: controller,
        style: const TextStyle(color: kDlgText),
        decoration: InputDecoration(
          labelText: '페이지',
          labelStyle: const TextStyle(color: kDlgTextSub),
          hintText: '예) 10-15, 18',
          hintStyle: const TextStyle(color: Color(0xFF6E7E7E)),
          filled: true,
          fillColor: kDlgFieldBg,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: kDlgBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: kDlgAccent, width: 1.4),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
          child: const Text('저장'),
        ),
      ],
    ),
  );
  if (submitted != true) return;
  final updated = _copyHomeworkItemForInlineEdit(
    child,
    page: controller.text.trim(),
  );
  HomeworkStore.instance.edit(studentId, updated);
  if (!context.mounted) return;
  _showHomeworkChipSnackBar(context, '페이지를 수정했어요.');
}

Future<void> _showGroupChildMemoEditDialog({
  required BuildContext context,
  required String studentId,
  required HomeworkItem child,
}) async {
  final controller = TextEditingController(text: (child.memo ?? '').trim());
  final submitted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: kDlgBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: const Text(
        '하위 과제 메모 수정',
        style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
      ),
      content: TextField(
        controller: controller,
        minLines: 2,
        maxLines: 6,
        style: const TextStyle(color: kDlgText),
        decoration: InputDecoration(
          labelText: '메모',
          labelStyle: const TextStyle(color: kDlgTextSub),
          hintText: '메모를 입력하세요.',
          hintStyle: const TextStyle(color: Color(0xFF6E7E7E)),
          filled: true,
          fillColor: kDlgFieldBg,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: kDlgBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: kDlgAccent, width: 1.4),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
          child: const Text('저장'),
        ),
      ],
    ),
  );
  if (submitted != true) return;
  final updated = _copyHomeworkItemForInlineEdit(
    child,
    memo: controller.text.trim(),
  );
  HomeworkStore.instance.edit(studentId, updated);
  if (!context.mounted) return;
  _showHomeworkChipSnackBar(context, '메모를 수정했어요.');
}

Future<void> _showHomeworkTypeEditDialog({
  required BuildContext context,
  required String studentId,
  required List<HomeworkItem> targets,
}) async {
  final liveTargets = targets
      .map((item) => HomeworkStore.instance.getById(studentId, item.id) ?? item)
      .where((item) => item.status != HomeworkStatus.completed)
      .toList(growable: false);
  if (liveTargets.isEmpty) return;

  final normalizedTypes = liveTargets
      .map((item) => _normalizeHomeworkTypeLabel(item.type ?? ''))
      .toSet();
  String selectedType = normalizedTypes.length == 1
      ? normalizedTypes.first
      : _normalizeHomeworkTypeLabel(liveTargets.first.type ?? '');

  final saved = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            backgroundColor: kDlgBg,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            title: const Text(
              '과제 양식 수정',
              style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
            ),
            content: SizedBox(
              width: 360,
              child: DropdownButtonFormField<String>(
                value: _homeworkTypeValues.contains(selectedType)
                    ? selectedType
                    : '프린트',
                items: [
                  for (final type in _homeworkTypeValues)
                    DropdownMenuItem<String>(
                      value: type,
                      child: Text(type),
                    ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => selectedType = value);
                },
                decoration: InputDecoration(
                  labelText: '과제 양식',
                  labelStyle: const TextStyle(color: kDlgTextSub),
                  filled: true,
                  fillColor: kDlgFieldBg,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: kDlgBorder),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: kDlgAccent, width: 1.4),
                  ),
                ),
                dropdownColor: kDlgPanelBg,
                style: const TextStyle(
                  color: kDlgText,
                  fontWeight: FontWeight.w600,
                ),
                iconEnabledColor: kDlgTextSub,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
                child: const Text('저장'),
              ),
            ],
          );
        },
      );
    },
  );
  if (saved != true || !context.mounted) return;

  final nextType = _normalizeHomeworkTypeLabel(selectedType);
  final nextColor = _colorForHomeworkTypeLabel(nextType);
  for (final item in liveTargets) {
    HomeworkStore.instance.edit(
      studentId,
      _copyHomeworkItemForInlineEdit(
        item,
        type: nextType,
        color: nextColor,
      ),
    );
  }
  if (!context.mounted) return;
  _showHomeworkChipSnackBar(
    context,
    liveTargets.length > 1
        ? '하위 ${liveTargets.length}개 과제의 양식을 수정했어요.'
        : '과제 양식을 수정했어요.',
  );
}

Future<void> _showAddChildHomeworkDialog({
  required BuildContext context,
  required String studentId,
  required HomeworkGroup group,
  required List<HomeworkItem> children,
}) async {
  final template = children.isEmpty ? null : children.first;
  final enabledFlows = await ensureEnabledFlowsForHomework(context, studentId);
  if (enabledFlows.isEmpty) return;

  final desiredFlowId =
      (group.flowId ?? template?.flowId ?? enabledFlows.first.id).trim();
  final initialFlowId = enabledFlows.any((f) => f.id == desiredFlowId)
      ? desiredFlowId
      : enabledFlows.first.id;

  String? lockedBookId;
  String? lockedGradeLabel;
  for (final child in children) {
    final candidateBookId = (child.bookId ?? '').trim();
    final candidateGrade = (child.gradeLabel ?? '').trim();
    if (candidateBookId.isEmpty || candidateGrade.isEmpty) continue;
    lockedBookId = candidateBookId;
    lockedGradeLabel = candidateGrade;
    break;
  }

  final result = await showDialog<dynamic>(
    context: context,
    builder: (ctx) => HomeworkQuickAddProxyDialog(
      studentId: studentId,
      flows: enabledFlows,
      initialFlowId: initialFlowId,
      initialTitle: (template?.title ?? group.title).trim(),
      initialColor: template?.color ?? const Color(0xFF1976D2),
      childAddMode: true,
      lockedGroupTitle: group.title.trim().isEmpty
          ? (template?.title ?? '그룹 과제')
          : group.title.trim(),
      lockedBookId: lockedBookId,
      lockedGradeLabel: lockedGradeLabel,
    ),
  );
  if (!context.mounted || result is! Map<String, dynamic>) return;
  if ((result['studentId'] as String?)?.trim() != studentId) return;

  int? parsePositiveInt(dynamic value) {
    if (value is int) return value > 0 ? value : null;
    if (value is num) {
      final parsed = value.toInt();
      return parsed > 0 ? parsed : null;
    }
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      return (parsed != null && parsed > 0) ? parsed : null;
    }
    return null;
  }

  List<Map<String, dynamic>>? parseUnitMappings(dynamic value) {
    if (value is! List) return null;
    final out = <Map<String, dynamic>>[];
    for (final row in value) {
      if (row is Map<String, dynamic>) {
        out.add(Map<String, dynamic>.from(row));
      } else if (row is Map) {
        out.add(Map<String, dynamic>.from(row));
      }
    }
    return out;
  }

  final rawItems = result['items'];
  final entries = <Map<String, dynamic>>[];
  if (rawItems is List) {
    for (final row in rawItems) {
      if (row is Map<String, dynamic>) {
        entries.add(Map<String, dynamic>.from(row));
      } else if (row is Map) {
        entries.add(Map<String, dynamic>.from(row));
      }
    }
  } else {
    entries.add(Map<String, dynamic>.from(result));
  }
  if (entries.isEmpty) {
    _showHomeworkChipSnackBar(context, '하위 과제가 비어 있습니다.');
    return;
  }

  final flowId = (result['flowId'] as String?)?.trim();
  final hasTestEntries = entries.any(_isTestHomeworkEntry);
  String? testFlowId;
  if (hasTestEntries) {
    try {
      final ensured = await StudentFlowStore.instance.ensureTestFlowForStudent(
        studentId,
      );
      testFlowId = (ensured?.id ?? '').trim();
    } catch (_) {
      testFlowId = null;
    }
    if (testFlowId == null || testFlowId.isEmpty) {
      if (!context.mounted) return;
      _showHomeworkChipSnackBar(context, '테스트 플로우를 준비하지 못했습니다.');
      return;
    }
  }
  int createdCount = 0;
  for (final entry in entries) {
    final isTestCard = _isTestHomeworkEntry(entry);
    final typeLabel = isTestCard ? '프린트' : (entry['type'] as String?)?.trim();
    final resolvedFlowId = isTestCard ? testFlowId : flowId;
    final existingOrigin = (entry['testOriginFlowId'] as String?)?.trim() ?? '';
    final resolvedTestOriginFlowId = isTestCard
        ? (existingOrigin.isNotEmpty ? existingOrigin : flowId)
        : null;
    final createdId = await HomeworkStore.instance.addWaitingItemToGroup(
      studentId: studentId,
      groupId: group.id,
      title: (entry['title'] as String?)?.trim() ?? '',
      body: (entry['body'] as String?)?.trim(),
      page: (entry['page'] as String?)?.trim(),
      count: parsePositiveInt(entry['count']),
      timeLimitMinutes: parsePositiveInt(entry['timeLimitMinutes']),
      testOriginFlowId: resolvedTestOriginFlowId,
      type: typeLabel,
      memo: (entry['memo'] as String?)?.trim(),
      content: (entry['content'] as String?)?.trim(),
      pbPresetId: (entry['pbPresetId'] as String?)?.trim(),
      bookId: (entry['bookId'] as String?)?.trim(),
      gradeLabel: (entry['gradeLabel'] as String?)?.trim(),
      sourceUnitLevel: (entry['sourceUnitLevel'] as String?)?.trim(),
      sourceUnitPath: (entry['sourceUnitPath'] as String?)?.trim(),
      unitMappings: parseUnitMappings(entry['unitMappings']),
      templateItemId: template?.id,
      flowId: resolvedFlowId,
      color: entry['color'] as Color?,
      defaultSplitParts: parsePositiveInt(entry['splitParts']),
    );
    if (createdId != null && createdId.isNotEmpty) {
      createdCount += 1;
    }
  }

  if (!context.mounted) return;
  if (createdCount == entries.length) {
    _showHomeworkChipSnackBar(context, '하위 과제 ${createdCount}개를 추가했어요.');
    return;
  }
  if (createdCount > 0) {
    _showHomeworkChipSnackBar(
      context,
      '하위 과제 ${createdCount}개를 추가했고 일부는 실패했어요.',
    );
    return;
  }
  _showHomeworkChipSnackBar(context, '하위 과제 추가에 실패했습니다.');
}

Future<void> _showHomeworkGroupTitleEditDialog({
  required BuildContext context,
  required String studentId,
  required HomeworkGroup group,
}) async {
  final editableChildren = HomeworkStore.instance
      .itemsInGroup(studentId, group.id)
      .where((e) => e.status != HomeworkStatus.completed)
      .toList(growable: false);
  final editableInWaiting = editableChildren.isNotEmpty &&
      editableChildren.every((e) => e.phase == 1 && e.completedAt == null);
  if (!editableInWaiting) {
    _showHomeworkChipSnackBar(context, '대기 상태 그룹 과제만 제목을 수정할 수 있습니다.');
    return;
  }

  final editableChildIds = editableChildren.map((e) => e.id).toSet();
  final activeAssignments =
      await HomeworkAssignmentStore.instance.loadActiveAssignments(studentId);
  if (!context.mounted) return;
  final hasUncheckedHomework = activeAssignments.any((assignment) {
    if (_isReservationAssignment(assignment)) return false;
    final itemId = assignment.homeworkItemId.trim();
    return itemId.isNotEmpty && editableChildIds.contains(itemId);
  });
  if (hasUncheckedHomework) {
    _showHomeworkChipSnackBar(context, '숙제 검사 전에는 그룹 과제명을 수정할 수 없습니다.');
    return;
  }

  final controller = TextEditingController(text: group.title.trim());
  final submitted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: kDlgBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: const Text(
        '그룹 과제명 수정',
        style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
      ),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLines: 1,
        style: const TextStyle(color: kDlgText),
        decoration: InputDecoration(
          labelText: '그룹 과제명',
          labelStyle: const TextStyle(color: kDlgTextSub),
          hintText: '그룹 과제명을 입력하세요.',
          hintStyle: const TextStyle(color: Color(0xFF6E7E7E)),
          filled: true,
          fillColor: kDlgFieldBg,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: kDlgBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: kDlgAccent, width: 1.4),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
          child: const Text('저장'),
        ),
      ],
    ),
  );
  if (submitted != true) return;
  final nextTitle = controller.text.trim();
  if (nextTitle.isEmpty) {
    _showHomeworkChipSnackBar(context, '그룹 과제명을 입력해 주세요.');
    return;
  }
  if (nextTitle == group.title.trim()) {
    _showHomeworkChipSnackBar(context, '변경 내용이 없습니다.');
    return;
  }
  final updated = await HomeworkStore.instance.updateGroupTitle(
    studentId: studentId,
    groupId: group.id,
    title: nextTitle,
  );
  if (!context.mounted) return;
  _showHomeworkChipSnackBar(
    context,
    updated ? '그룹 과제명을 수정했어요.' : '그룹 과제명 수정에 실패했습니다.',
  );
}

Future<void> _moveGroupChildByDrag({
  required BuildContext context,
  required String studentId,
  required HomeworkGroup targetGroup,
  required HomeworkItem source,
  HomeworkItem? targetBefore,
}) async {
  final sourceWaiting =
      source.status != HomeworkStatus.completed && source.phase == 1;
  if (!sourceWaiting) {
    _showHomeworkChipSnackBar(context, '대기 상태 하위 과제만 이동할 수 있습니다.');
    return;
  }
  if (targetBefore != null) {
    final targetWaiting = targetBefore.status != HomeworkStatus.completed &&
        targetBefore.phase == 1;
    if (!targetWaiting) {
      _showHomeworkChipSnackBar(context, '대기 상태 하위 과제 위치로만 이동할 수 있습니다.');
      return;
    }
    if (targetBefore.id == source.id) return;
  }

  final sourceGroupId =
      (HomeworkStore.instance.groupIdOfItem(source.id) ?? '').trim();
  final targetGroupId = targetGroup.id.trim();
  if (sourceGroupId.isEmpty || targetGroupId.isEmpty) {
    _showHomeworkChipSnackBar(context, '그룹 정보를 확인할 수 없어 이동하지 못했습니다.');
    return;
  }
  final sameGroup = sourceGroupId == targetGroupId;

  String textbookKeyOfHomework(HomeworkItem item) {
    final bookId = (item.bookId ?? '').trim();
    final gradeLabel = (item.gradeLabel ?? '').trim();
    if (bookId.isEmpty || gradeLabel.isEmpty) return '';
    return '$bookId|$gradeLabel';
  }

  String resolveGroupTextbookKey(String groupId) {
    final children = HomeworkStore.instance.itemsInGroup(studentId, groupId);
    for (final child in children) {
      final key = textbookKeyOfHomework(child);
      if (key.isNotEmpty) return key;
    }
    return '';
  }

  if (!sameGroup) {
    final sourceTextbookKey = textbookKeyOfHomework(source);
    final targetTextbookKey = resolveGroupTextbookKey(targetGroupId);
    if (sourceTextbookKey.isEmpty ||
        targetTextbookKey.isEmpty ||
        sourceTextbookKey != targetTextbookKey) {
      _showHomeworkChipSnackBar(context, '같은 출제 교재 그룹으로만 이동할 수 있습니다.');
      return;
    }
  }

  try {
    final moved = await HomeworkStore.instance.moveWaitingItemToGroup(
      studentId: studentId,
      itemId: source.id,
      targetGroupId: targetGroupId,
      targetBeforeItemId: targetBefore?.id,
    );
    if (!context.mounted) return;
    if (!moved) {
      _showHomeworkChipSnackBar(context, '하위 과제 이동에 실패했습니다.');
      return;
    }
    _showHomeworkChipSnackBar(
      context,
      sameGroup ? '하위 과제 순서를 변경했어요.' : '하위 과제를 다른 그룹으로 이동했어요.',
    );
  } catch (e) {
    if (!context.mounted) return;
    final message = e.toString();
    if (message.contains('ASSIGNMENT') || message.contains('MOVE_BLOCKED')) {
      _showHomeworkChipSnackBar(context, '숙제 연결된 과제는 이동할 수 없습니다.');
      return;
    }
    _showHomeworkChipSnackBar(context, '하위 과제 이동 실패: $message');
  }
}

class _HomeworkCardTheme {
  const _HomeworkCardTheme({
    required this.titleStyle,
    required this.metaStyle,
    required this.secondaryRowStyle,
    required this.idleBorderColor,
    required this.reservedBorderColor,
    required this.reservedBorderExpandedColor,
    required this.dividerColor,
    required this.dividerStrongColor,
    required this.childDividerColor,
    required this.iconMutedColor,
    required this.flowChipDefaultBg,
    required this.flowChipDefaultBorder,
    required this.flowChipDefaultText,
    required this.pendingConfirmOverlay,
    required this.dragFeedbackBackground,
    required this.dragFeedbackBorder,
    required this.reservedExpandedShadow,
  });

  final TextStyle titleStyle;
  final TextStyle metaStyle;
  final TextStyle secondaryRowStyle;
  final Color idleBorderColor;
  final Color reservedBorderColor;
  final Color reservedBorderExpandedColor;
  final Color dividerColor;
  final Color dividerStrongColor;
  final Color childDividerColor;
  final Color iconMutedColor;
  final Color flowChipDefaultBg;
  final Color flowChipDefaultBorder;
  final Color flowChipDefaultText;
  final Color pendingConfirmOverlay;
  final Color dragFeedbackBackground;
  final Color dragFeedbackBorder;
  final List<BoxShadow> reservedExpandedShadow;

  factory _HomeworkCardTheme.forBrightness(Brightness brightness) {
    final panel = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
    final isLight = brightness == Brightness.light;
    final groupedBorder =
        FabTabBarTokens.groupedCardBorderFor(brightness).top.color;

    return _HomeworkCardTheme(
      titleStyle: FabTabBarTokens.previewAcademyLabelStyle(panel).copyWith(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        height: 1.1,
      ),
      metaStyle: FabTabBarTokens.previewAcademyLabelStyle(panel).copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.1,
      ),
      secondaryRowStyle: TextStyle(
        fontFamily: FabTabBarTokens.previewAcademyValueFontFamily,
        fontWeight: FontWeight.w600,
        fontSize: 16,
        height: 1.1,
        color: isLight ? panel.hint : const Color(0xFF8FA1A1),
      ),
      idleBorderColor: isLight ? groupedBorder : Colors.white24,
      reservedBorderColor: isLight ? groupedBorder : const Color(0xFF273338),
      reservedBorderExpandedColor: isLight
          ? kDlgAccent.withValues(alpha: 0.45)
          : const Color(0xFF33554C),
      dividerColor: panel.divider,
      dividerStrongColor: isLight ? groupedBorder : const Color(0x80FFFFFF),
      childDividerColor: isLight ? panel.divider : const Color(0x223A4545),
      iconMutedColor: panel.icon,
      flowChipDefaultBg:
          isLight ? const Color(0xFFF2F2F7) : const Color(0xFF2A3030),
      flowChipDefaultBorder: isLight ? groupedBorder : const Color(0xFF4A5858),
      flowChipDefaultText: isLight ? panel.hint : const Color(0xFF9FB3B3),
      pendingConfirmOverlay:
          isLight ? const Color(0xCCF2F2F7) : const Color(0xCC0B1112),
      dragFeedbackBackground:
          isLight ? const Color(0xFFECECEF) : const Color(0xFF202629),
      dragFeedbackBorder: isLight ? groupedBorder : const Color(0xFF3E5757),
      reservedExpandedShadow: isLight
          ? FabTabBarTokens.fabBarLightBoxShadows
          : const [
              BoxShadow(
                color: Color(0x22000000),
                blurRadius: 8,
                offset: Offset(0, 3),
              ),
            ],
    );
  }

  static _HomeworkCardTheme of(BuildContext context) =>
      _HomeworkCardTheme.forBrightness(Theme.of(context).brightness);
}

const double _homeworkChipCollapsedHeight = 180.0;

/// 펼침 요약(시작·총시간·검사/숙제·검사날짜) + 하위과제 헤더 여유.
const double _homeworkChipExpandedHeight = 266.0;
const Duration _homeworkChipExpandDuration = Duration(milliseconds: 170);
const Curve _homeworkChipExpandCurve = Curves.easeOutCubic;
double _homeworkGroupExpandedHeightForChildCount(int childCount) {
  if (childCount <= 0) return _homeworkChipExpandedHeight;
  // 상단 정보와 하위 리스트를 충분히 분리하고,
  // 하위 과제 수에 비례해 카드 높이가 늘어나도록 계산한다.
  // 펼침 요약 5줄 + 하위과제 헤더 여백
  const double groupSectionHeaderHeight = 100;
  // 하위 과제 사이 여백(+8,+8), 메모 줄 제거 반영
  const double perChildRowHeight = 96;
  final double overflowSafetyPadding =
      childCount >= 7 ? 18 : (childCount >= 5 ? 12 : (childCount >= 3 ? 8 : 4));
  return _homeworkChipExpandedHeight +
      groupSectionHeaderHeight +
      (childCount * perChildRowHeight) +
      overflowSafetyPadding;
}

double _homeworkChipMaxSlideFor(double h) => h * 0.58;
const double _homeworkChipOuterLeftInset =
    (ClassContentScreen._studentColumnWidth -
            ClassContentScreen._studentColumnContentWidth) /
        2;
const Color _homePrintPickPanelBg = Color(0xFF10171A);
const Color _homePrintPickBorder = Color(0xFF223131);
const Color _homePrintPickText = Color(0xFFEAF2F2);
const Color _homePrintPickTextSub = Color(0xFF9FB3B3);
const Color _homePrintPickAccent = Color(0xFF33A373);
const String _homeworkPrintTempPrefix = 'hw_print_';
// 그룹 사이클 내(휴식 포함) 진행시간 누적 보장을 위한 기준값 스냅샷 캐시
final Map<String, String> _groupCycleIdentityByGroupId = <String, String>{};
final Map<String, Map<String, int>> _groupChildCycleBaseByGroupId =
    <String, Map<String, int>>{};
final Set<String> _testTimedOutHomeworkKeys = <String>{};
final Set<String> _testAutoSubmitTriggeredKeys = <String>{};
final Map<String, String> _expandedReservedGroupKeyByStudent =
    <String, String>{};
final Set<String> _activatingReservedGroupActionKeys = <String>{};
final ValueNotifier<int> _reservedGroupUiRevision = ValueNotifier<int>(0);

String _formatHomeworkAssignmentCode(String? raw, {String fallback = '-'}) {
  final code = (raw ?? '').trim().toUpperCase();
  if (!RegExp(r'^(CL|PL|FL|EL)[A-Z]{2}[0-9]{4}$').hasMatch(code)) {
    return fallback;
  }
  return code;
}

void _markReservedGroupUiDirty() {
  _reservedGroupUiRevision.value = _reservedGroupUiRevision.value + 1;
}

// ------------------------
// 오른쪽 패널: 슬라이드시트와 동일한 과제 칩 렌더링
// ------------------------
Widget _buildHomeworkChipsReactiveForStudent(
  String studentId,
  double tick, {
  _HomeworkDraftEditorController? homeworkDraftEditor,
  double homeworkDraftReveal = 1,
  Set<String> goalSnapshotItemIds = const <String>{},
  bool hasGoalSnapshot = false,
  Map<({String studentId, String itemId}), bool> pendingConfirms = const {},
  Future<void> Function(
          {required BuildContext context,
          required String studentId,
          required HomeworkItem hw})?
      onPhase3Tap,
  Future<void> Function({
    required BuildContext context,
    required String studentId,
    required HomeworkGroup group,
    required HomeworkItem summary,
    required List<HomeworkItem> children,
  })? onHomeworkCheckTap,
  void Function(String studentId, List<HomeworkItem> submittedItems)?
      onGroupSubmittedDoubleTap,
  bool printPickMode = false,
  Future<void> Function(
          {required BuildContext context,
          required String studentId,
          required HomeworkItem hw})?
      onPrintPickTap,
  Future<void> Function({
    required BuildContext context,
    required String studentId,
    required HomeworkGroup group,
    required HomeworkItem summary,
    required List<HomeworkItem> children,
  })? onGroupPrintPickTap,
  Future<void> Function(
          {required BuildContext context,
          required String studentId,
          required HomeworkItem hw})?
      onPrintPickLongPress,
  Future<void> Function({
    required BuildContext context,
    required String studentId,
    required HomeworkGroup group,
    required HomeworkItem summary,
    required List<HomeworkItem> children,
  })? onGroupPrintPickLongPress,
  VoidCallback? onPrintPickSecondaryTap,
  void Function(({String studentId, String itemId}) key)? onSlideDownComplete,
  Set<String> expandedHomeworkIds = const {},
  void Function(String id)? onToggleExpand,
}) {
  return ValueListenableBuilder<int>(
    valueListenable: StudentFlowStore.instance.revision,
    builder: (context, __, ___) {
      final flowNames = _getFlowNamesForStudent(studentId);
      return ValueListenableBuilder<int>(
        valueListenable: HomeworkAssignmentStore.instance.revision,
        builder: (context, rev, ___) {
          final lastRev = _assignmentRevisionByStudent[studentId];
          if (lastRev != rev) {
            _assignmentRevisionByStudent[studentId] = rev;
            _assignmentCountsFutureByStudent[studentId] =
                HomeworkAssignmentStore.instance
                    .loadAssignmentCounts(studentId);
            _activeAssignmentsFutureByStudent[studentId] =
                HomeworkAssignmentStore.instance
                    .loadActiveAssignments(studentId);
            _assignmentCycleMetaFutureByStudent[studentId] =
                HomeworkAssignmentStore.instance
                    .loadLatestCycleMetaByItem(studentId);
            _gradingProgressRevisionByStudent.remove(studentId);
            _gradingProgressFutureByStudent.remove(studentId);
          }
          final assignmentCountsFuture =
              _assignmentCountsFutureByStudent.putIfAbsent(
            studentId,
            () => HomeworkAssignmentStore.instance
                .loadAssignmentCounts(studentId),
          );
          final activeAssignmentsFuture =
              _activeAssignmentsFutureByStudent.putIfAbsent(
            studentId,
            () => HomeworkAssignmentStore.instance
                .loadActiveAssignments(studentId),
          );
          final assignmentCycleMetaFuture =
              _assignmentCycleMetaFutureByStudent.putIfAbsent(
            studentId,
            () => HomeworkAssignmentStore.instance
                .loadLatestCycleMetaByItem(studentId),
          );
          return FutureBuilder<Map<String, int>>(
            future: assignmentCountsFuture,
            builder: (context, snapshot) {
              final assignmentCounts = snapshot.data ?? const <String, int>{};
              return FutureBuilder<List<HomeworkAssignmentDetail>>(
                future: activeAssignmentsFuture,
                initialData: HomeworkAssignmentStore.instance
                    .peekCachedActiveAssignments(studentId),
                builder: (context, assignmentsSnapshot) {
                  final assignStore = HomeworkAssignmentStore.instance;
                  final cachePeek =
                      assignStore.peekCachedActiveAssignments(studentId);
                  final loadedOnce =
                      assignStore.hasCompletedActiveAssignmentLoad(studentId);
                  final waiting = assignmentsSnapshot.connectionState ==
                      ConnectionState.waiting;
                  if (!loadedOnce && waiting && cachePeek == null) {
                    return const SizedBox(height: 32);
                  }
                  final activeAssignments =
                      assignmentsSnapshot.connectionState ==
                              ConnectionState.done
                          ? (assignmentsSnapshot.data ??
                              const <HomeworkAssignmentDetail>[])
                          : (cachePeek ?? const <HomeworkAssignmentDetail>[]);
                  final hiddenItemIds = <String>{};
                  final assignmentDueByGroupId = <String, DateTime?>{};
                  final assignmentDueByItemId = <String, DateTime?>{};
                  final assignmentCheckLabelByGroupId = <String, String>{};
                  for (final assignment in activeAssignments) {
                    final hwId = assignment.homeworkItemId.trim();
                    if (hwId.isEmpty) continue;
                    if (_isReservationAssignment(assignment)) {
                      hiddenItemIds.add(hwId);
                      continue;
                    }
                    final dueDate = assignment.dueDate;
                    final assignmentGroupId = (assignment.groupId ?? '').trim();
                    if (assignmentGroupId.isNotEmpty) {
                      assignmentDueByGroupId[assignmentGroupId] =
                          _mergeHomeworkDueDate(
                        assignmentDueByGroupId[assignmentGroupId],
                        dueDate,
                      );
                      if (assignment.status == 'carried_to_class') {
                        final original =
                            assignment.originalDueDate ?? assignment.dueDate;
                        assignmentCheckLabelByGroupId[assignmentGroupId] =
                            _homeworkCarriedCheckChipLabel(
                          originalDue: original,
                          dueForCheckAt: assignment.dueForCheckAt,
                          absenceCarryover: assignment.absenceCarryover,
                        );
                      }
                    }
                    assignmentDueByItemId[hwId] = _mergeHomeworkDueDate(
                      assignmentDueByItemId[hwId],
                      dueDate,
                    );
                  }
                  hiddenItemIds.addAll(
                    HomeworkAssignmentStore.instance
                        .peekPendingReservedHomeworkItemIds(studentId),
                  );
                  return FutureBuilder<
                      Map<String, HomeworkAssignmentCycleMeta>>(
                    future: assignmentCycleMetaFuture,
                    builder: (context, cycleSnapshot) {
                      final assignmentCycleMetaByItem = cycleSnapshot.data ??
                          const <String, HomeworkAssignmentCycleMeta>{};
                      return ValueListenableBuilder<int>(
                        valueListenable: HomeworkStore.instance.revision,
                        builder: (context, hwRev, _) {
                          final lastProgressRev =
                              _gradingProgressRevisionByStudent[studentId];
                          if (lastProgressRev != hwRev) {
                            _gradingProgressRevisionByStudent[studentId] =
                                hwRev;
                            _gradingProgressFutureByStudent[studentId] =
                                _loadHomeworkProgressRatesForStudent(
                              studentId,
                            );
                          }
                          final progressFuture =
                              _gradingProgressFutureByStudent.putIfAbsent(
                            studentId,
                            () => _loadHomeworkProgressRatesForStudent(
                              studentId,
                            ),
                          );
                          return FutureBuilder<
                              Map<String, HomeworkGradingProgressRate>>(
                            future: progressFuture,
                            builder: (context, progressSnapshot) {
                              final progressRatesByItem = progressSnapshot
                                      .data ??
                                  const <String, HomeworkGradingProgressRate>{};
                              final chips = _buildHomeworkChipsOnceForStudent(
                                context,
                                studentId,
                                tick,
                                flowNames,
                                assignmentCounts,
                                hiddenItemIds,
                                assignmentCycleMetaByItem,
                                homeworkDraftEditor: homeworkDraftEditor,
                                homeworkDraftReveal: homeworkDraftReveal,
                                goalSnapshotItemIds: goalSnapshotItemIds,
                                hasGoalSnapshot: hasGoalSnapshot,
                                assignmentDueByGroupId: assignmentDueByGroupId,
                                assignmentDueByItemId: assignmentDueByItemId,
                                assignmentCheckLabelByGroupId:
                                    assignmentCheckLabelByGroupId,
                                progressRatesByItem: progressRatesByItem,
                                pendingConfirms: pendingConfirms,
                                onPhase3Tap: onPhase3Tap,
                                onHomeworkCheckTap: onHomeworkCheckTap,
                                onGroupSubmittedDoubleTap:
                                    onGroupSubmittedDoubleTap,
                                printPickMode: printPickMode,
                                onPrintPickTap: onPrintPickTap,
                                onGroupPrintPickTap: onGroupPrintPickTap,
                                onPrintPickLongPress: onPrintPickLongPress,
                                onGroupPrintPickLongPress:
                                    onGroupPrintPickLongPress,
                                onPrintPickSecondaryTap:
                                    onPrintPickSecondaryTap,
                                onSlideDownComplete: onSlideDownComplete,
                                expandedHomeworkIds: expandedHomeworkIds,
                                onToggleExpand: onToggleExpand,
                              );
                              final columnChildren = <Widget>[];
                              for (final chip in chips) {
                                if (columnChildren.isNotEmpty) {
                                  columnChildren
                                      .add(const SizedBox(height: 17));
                                }
                                columnChildren.add(chip);
                              }
                              if (columnChildren.isEmpty) {
                                return const SizedBox.shrink();
                              }
                              return SingleChildScrollView(
                                physics: const BouncingScrollPhysics(),
                                child: Padding(
                                  padding: const EdgeInsets.only(
                                    left: _homeworkChipOuterLeftInset,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: columnChildren,
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      );
                    },
                  );
                },
              );
            },
          );
        },
      );
    },
  );
}

Widget _buildReservedHomeworkChipsReactiveForStudent(
  BuildContext context,
  String studentId,
  double tick,
) {
  return ValueListenableBuilder<int>(
    valueListenable: StudentFlowStore.instance.revision,
    builder: (context, __, ___) {
      final flowNames = _getFlowNamesForStudent(studentId);
      return ValueListenableBuilder<int>(
        valueListenable: HomeworkAssignmentStore.instance.revision,
        builder: (context, rev, ___) {
          final lastRev = _assignmentRevisionByStudent[studentId];
          if (lastRev != rev) {
            _assignmentRevisionByStudent[studentId] = rev;
            _assignmentCountsFutureByStudent[studentId] =
                HomeworkAssignmentStore.instance
                    .loadAssignmentCounts(studentId);
            _activeAssignmentsFutureByStudent[studentId] =
                HomeworkAssignmentStore.instance
                    .loadActiveAssignments(studentId);
            _assignmentCycleMetaFutureByStudent[studentId] =
                HomeworkAssignmentStore.instance
                    .loadLatestCycleMetaByItem(studentId);
            _gradingProgressRevisionByStudent.remove(studentId);
            _gradingProgressFutureByStudent.remove(studentId);
          }
          final assignmentCountsFuture =
              _assignmentCountsFutureByStudent.putIfAbsent(
            studentId,
            () => HomeworkAssignmentStore.instance
                .loadAssignmentCounts(studentId),
          );
          final activeAssignmentsFuture =
              _activeAssignmentsFutureByStudent.putIfAbsent(
            studentId,
            () => HomeworkAssignmentStore.instance
                .loadActiveAssignments(studentId),
          );
          final assignmentCycleMetaFuture =
              _assignmentCycleMetaFutureByStudent.putIfAbsent(
            studentId,
            () => HomeworkAssignmentStore.instance
                .loadLatestCycleMetaByItem(studentId),
          );
          return FutureBuilder<Map<String, int>>(
            future: assignmentCountsFuture,
            builder: (context, snapshot) {
              final assignmentCounts = snapshot.data ?? const <String, int>{};
              return FutureBuilder<List<HomeworkAssignmentDetail>>(
                future: activeAssignmentsFuture,
                initialData: HomeworkAssignmentStore.instance
                    .peekCachedActiveAssignments(studentId),
                builder: (context, assignmentsSnapshot) {
                  final activeAssignments = assignmentsSnapshot.data ??
                      const <HomeworkAssignmentDetail>[];
                  return FutureBuilder<
                      Map<String, HomeworkAssignmentCycleMeta>>(
                    future: assignmentCycleMetaFuture,
                    builder: (context, cycleSnapshot) {
                      final assignmentCycleMetaByItem = cycleSnapshot.data ??
                          const <String, HomeworkAssignmentCycleMeta>{};
                      return ValueListenableBuilder<int>(
                        valueListenable: HomeworkStore.instance.revision,
                        builder: (context, _rev, _) {
                          return ValueListenableBuilder<int>(
                            valueListenable: _reservedGroupUiRevision,
                            builder: (context, uiRevision, ____) {
                              final reservedSections =
                                  _buildReservedHomeworkChipsForStudent(
                                context,
                                studentId,
                                flowNames,
                                assignmentCounts,
                                activeAssignments,
                                assignmentCycleMetaByItem,
                              );
                              if (reservedSections.isEmpty) {
                                return const Center(
                                  child: Text(
                                    '예약 과제가 없습니다.',
                                    style: TextStyle(
                                      color: kDlgTextSub,
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                );
                              }
                              return SingleChildScrollView(
                                key: ValueKey('reserved_ui_$uiRevision'),
                                physics: const BouncingScrollPhysics(),
                                clipBehavior: Clip.none,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: reservedSections,
                                ),
                              );
                            },
                          );
                        },
                      );
                    },
                  );
                },
              );
            },
          );
        },
      );
    },
  );
}

Widget _buildReservedHomeworkTitleReactiveForStudent(String studentId) {
  return ValueListenableBuilder<int>(
    valueListenable: HomeworkAssignmentStore.instance.revision,
    builder: (context, rev, __) {
      final lastRev = _reservedTitleRevisionByStudent[studentId];
      if (lastRev != rev) {
        _reservedTitleRevisionByStudent[studentId] = rev;
        _activeAssignmentsFutureByStudent[studentId] =
            HomeworkAssignmentStore.instance.loadActiveAssignments(studentId);
      }
      final activeAssignmentsFuture =
          _activeAssignmentsFutureByStudent.putIfAbsent(
        studentId,
        () => HomeworkAssignmentStore.instance.loadActiveAssignments(studentId),
      );
      return FutureBuilder<List<HomeworkAssignmentDetail>>(
        future: activeAssignmentsFuture,
        initialData: HomeworkAssignmentStore.instance
            .peekCachedActiveAssignments(studentId),
        builder: (context, assignmentsSnapshot) {
          final activeAssignments =
              assignmentsSnapshot.data ?? const <HomeworkAssignmentDetail>[];
          return ValueListenableBuilder<int>(
            valueListenable: HomeworkStore.instance.revision,
            builder: (context, _rev, _) {
              final reservedGroupCount =
                  _resolveReservedHomeworkGroupsForStudent(
                studentId,
                activeAssignments,
              ).length;
              if (reservedGroupCount <= 0) {
                return const SizedBox.shrink();
              }
              return SizedBox(
                width: ClassContentScreen._studentColumnContentWidth,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    '예약 그룹 과제 $reservedGroupCount개',
                    style: const TextStyle(
                      color: kDlgAccent,
                      fontSize: 23,
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                    ),
                  ),
                ),
              );
            },
          );
        },
      );
    },
  );
}

bool _isReservationAssignment(HomeworkAssignmentDetail assignment) {
  final note = (assignment.note ?? '').trim();
  return note == HomeworkAssignmentStore.reservationNote;
}

Future<void> _activateReservedHomeworkGroup({
  required BuildContext context,
  required String studentId,
  required _ReservedHomeworkGroupSection group,
}) async {
  final actionKey = '$studentId|${group.groupKey}';
  if (_activatingReservedGroupActionKeys.contains(actionKey)) return;
  _activatingReservedGroupActionKeys.add(actionKey);
  _markReservedGroupUiDirty();
  try {
    final activatedItemIds = <String>{};
    for (final entry in group.entries) {
      final hwId = entry.key.homeworkItemId.trim();
      if (hwId.isEmpty || activatedItemIds.contains(hwId)) continue;
      await HomeworkStore.instance.placeItemAtActiveTail(
        studentId,
        hwId,
        activateFromHomework: true,
      );
      final latest = HomeworkStore.instance.getById(studentId, hwId);
      if (latest != null && latest.phase != 1) {
        await HomeworkStore.instance.waitPhase(studentId, hwId);
      }
      activatedItemIds.add(hwId);
    }
    if (activatedItemIds.isEmpty) return;
    await HomeworkAssignmentStore.instance.clearActiveAssignmentsForItems(
      studentId,
      activatedItemIds.toList(growable: false),
    );
    if (!context.mounted) return;
    final int convertedCount = activatedItemIds.length;
    final String message = convertedCount > 1
        ? '예약 그룹 과제 $convertedCount개를 대기 상태로 전환했어요.'
        : '예약 그룹 과제를 대기 상태로 전환했어요.';
    _showHomeworkChipSnackBar(context, message);
    if (_expandedReservedGroupKeyByStudent[studentId] == group.groupKey) {
      _expandedReservedGroupKeyByStudent.remove(studentId);
      _markReservedGroupUiDirty();
    }
  } finally {
    if (_activatingReservedGroupActionKeys.remove(actionKey)) {
      _markReservedGroupUiDirty();
    }
  }
}

Future<void> _deleteReservedHomeworkGroup({
  required BuildContext context,
  required String studentId,
  required _ReservedHomeworkGroupSection group,
}) async {
  final actionKey = '$studentId|${group.groupKey}';
  if (_activatingReservedGroupActionKeys.contains(actionKey)) return;
  _activatingReservedGroupActionKeys.add(actionKey);
  _markReservedGroupUiDirty();
  try {
    final deletedItemIds = <String>{};
    for (final entry in group.entries) {
      final hwId = entry.key.homeworkItemId.trim();
      if (hwId.isEmpty || deletedItemIds.contains(hwId)) continue;
      HomeworkStore.instance.remove(studentId, hwId);
      deletedItemIds.add(hwId);
    }
    if (deletedItemIds.isEmpty) return;
    if (!context.mounted) return;
    final int deletedCount = deletedItemIds.length;
    final String message = deletedCount > 1
        ? '예약 그룹 과제 $deletedCount개를 삭제했어요.'
        : '예약 그룹 과제를 삭제했어요.';
    _showHomeworkChipSnackBar(context, message);
    if (_expandedReservedGroupKeyByStudent[studentId] == group.groupKey) {
      _expandedReservedGroupKeyByStudent.remove(studentId);
      _markReservedGroupUiDirty();
    }
  } finally {
    if (_activatingReservedGroupActionKeys.remove(actionKey)) {
      _markReservedGroupUiDirty();
    }
  }
}

String _formatHomeworkDueChipLabel(DateTime dueDate) {
  final local = dueDate.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.month}월 ${local.day}일 '
      '${two(local.hour)}:${two(local.minute)}까지';
}

String _homeworkAssignmentHistoryStatusLabel(HomeworkAssignmentBrief brief) {
  if (brief.isSelfExtra) return '추가 검사';
  if (brief.absenceCarryover) return '결석 이월';
  switch (brief.status.trim()) {
    case 'carried_over':
      return '이월됨';
    case 'carried_to_class':
      return '수업 이월';
    case 'completed':
      return '완료';
    case 'in_progress':
      return '진행중';
    default:
      break;
  }
  final original = brief.originalDueDate;
  final due = brief.dueDate;
  if (original != null &&
      due != null &&
      _dateOnly(original).isBefore(_dateOnly(due))) {
    return '미검사 이월';
  }
  return '내줌';
}

Future<void> _showHomeworkAssignmentHistoryDialog({
  required BuildContext context,
  required String studentId,
  required List<String> itemIds,
  required String title,
}) async {
  final ids = itemIds.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
  if (ids.isEmpty) {
    _showHomeworkChipSnackBar(context, '숙제 이력을 찾을 수 없습니다.');
    return;
  }

  Map<String, List<HomeworkAssignmentBrief>> assignmentsByItem;
  try {
    assignmentsByItem =
        await HomeworkAssignmentStore.instance.loadAssignmentsForStudent(
      studentId,
    );
  } catch (_) {
    if (!context.mounted) return;
    _showHomeworkChipSnackBar(context, '숙제 이력을 불러오지 못했습니다.');
    return;
  }
  if (!context.mounted) return;

  final byAssignmentId = <String, HomeworkAssignmentBrief>{};
  for (final itemId in ids) {
    for (final brief
        in assignmentsByItem[itemId] ?? const <HomeworkAssignmentBrief>[]) {
      final id = brief.id.trim();
      if (id.isEmpty) continue;
      byAssignmentId.putIfAbsent(id, () => brief);
    }
  }
  final history = byAssignmentId.values.toList(growable: false)
    ..sort((a, b) => b.assignedAt.compareTo(a.assignedAt));

  await showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (ctx) {
      return Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: UtilityGlassDialogShell(
          title: '숙제 히스토리',
          icon: Icons.history_rounded,
          preferredWidth: 460,
          maxWidth: 460,
          maxHeight: 560,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: kDlgText,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: history.isEmpty
                      ? const Center(
                          child: Text(
                            '숙제 이력이 없습니다.',
                            style: TextStyle(
                              color: kDlgTextSub,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        )
                      : ListView.separated(
                          itemCount: history.length,
                          separatorBuilder: (_, __) => const Padding(
                            padding: EdgeInsets.symmetric(vertical: 10),
                            child: Divider(
                              height: 1,
                              thickness: 1,
                              color: Color(0x22FFFFFF),
                            ),
                          ),
                          itemBuilder: (context, index) {
                            final brief = history[index];
                            final status =
                                _homeworkAssignmentHistoryStatusLabel(brief);
                            final assignedText =
                                _formatDateWithWeekdayAndTime(brief.assignedAt);
                            final dueText = brief.dueDate == null
                                ? '검사일 미정'
                                : _formatDateWithWeekdayAndTime(brief.dueDate!);
                            final originalText = brief.originalDueDate == null
                                ? null
                                : _formatDateWithWeekdayAndTime(
                                    brief.originalDueDate!,
                                  );
                            final showOriginal = originalText != null &&
                                brief.originalDueDate != null &&
                                brief.dueDate != null &&
                                !_dateOnly(brief.originalDueDate!)
                                    .isAtSameMomentAs(
                                        _dateOnly(brief.dueDate!));
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '${brief.repeatIndex}회차',
                                        style: const TextStyle(
                                          color: kDlgText,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      status,
                                      style: TextStyle(
                                        color: status.contains('이월')
                                            ? kDlgAccent
                                            : kDlgTextSub,
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '내준  $assignedText',
                                  style: const TextStyle(
                                    color: kDlgTextSub,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    height: 1.35,
                                  ),
                                ),
                                Text(
                                  '검사  $dueText',
                                  style: const TextStyle(
                                    color: kDlgTextSub,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    height: 1.35,
                                  ),
                                ),
                                if (showOriginal)
                                  Text(
                                    '원래  $originalText',
                                    style: const TextStyle(
                                      color: kDlgTextSub,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      height: 1.35,
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

DateTime? _mergeHomeworkDueDate(DateTime? current, DateTime? candidate) {
  if (current == null) return candidate;
  if (candidate == null) return current;
  return candidate.isBefore(current) ? candidate : current;
}

Widget _buildHomeworkReorderableItem({
  required String itemKey,
  required Widget chip,
  required bool showBottomGap,
}) {
  return Padding(
    key: ValueKey(itemKey),
    padding: EdgeInsets.only(bottom: showBottomGap ? 17 : 0),
    child: chip,
  );
}

Widget _buildHomeworkChipWithReorderHandle({
  required Widget chipVisual,
  required int index,
  bool enableReorderDrag = true,
}) {
  // 펼침 때 위젯 트리를 바꾸면 카드가 통째로 교체된 것처럼 깜빡인다.
  // 항상 같은 구조로 두고 enabled 만 토글한다.
  return ReorderableDelayedDragStartListener(
    index: index,
    enabled: enableReorderDrag,
    child: chipVisual,
  );
}

List<Widget> _buildReservedHomeworkChipsForStudent(
  BuildContext context,
  String studentId,
  Map<String, String> flowNames,
  Map<String, int> assignmentCounts,
  List<HomeworkAssignmentDetail> activeAssignments,
  Map<String, HomeworkAssignmentCycleMeta> assignmentCycleMetaByItem,
) {
  final reservedGroups = _resolveReservedHomeworkGroupsForStudent(
    studentId,
    activeAssignments,
  );
  if (reservedGroups.isEmpty) return const <Widget>[];

  final cardTheme = _HomeworkCardTheme.of(context);
  final out = <Widget>[];
  for (int i = 0; i < reservedGroups.length; i++) {
    final group = reservedGroups[i];
    final entries = group.entries;
    final actionKey = '$studentId|${group.groupKey}';
    final bool isExpanded =
        _expandedReservedGroupKeyByStudent[studentId] == group.groupKey;
    final bool isActivating =
        _activatingReservedGroupActionKeys.contains(actionKey);

    final flowLabels = <String>{};
    int totalQuestionCount = 0;
    int totalAssignmentCount = 0;
    DateTime? dueDate;
    for (final entry in entries) {
      final assignment = entry.key;
      final hw = entry.value;
      final flowId = (hw.flowId ?? assignment.flowId ?? '').trim();
      final flowLabel = (flowNames[flowId] ?? '').trim();
      if (flowLabel.isNotEmpty) flowLabels.add(flowLabel);
      final count = hw.count ?? 0;
      if (count > 0) totalQuestionCount += count;
      totalAssignmentCount += assignmentCounts[hw.id] ?? 0;
      dueDate = _mergeHomeworkDueDate(
        dueDate,
        assignment.dueDate,
      );
    }
    final groupPageSummary = mergeHomeworkItemPageRanges(
      entries.map(
        (entry) => (
          page: entry.value.page,
          unitMappings: entry.value.unitMappings,
        ),
      ),
    );

    final String flowSummary = flowLabels.isEmpty
        ? '플로우 미지정'
        : (flowLabels.length == 1
            ? flowLabels.first
            : '플로우 ${flowLabels.length}개');
    final String topMeta = <String>[
      flowSummary,
      if (groupPageSummary.isNotEmpty) 'p.$groupPageSummary',
      if (totalQuestionCount > 0) '$totalQuestionCount문항',
    ].join(' · ');
    final String bottomMeta = <String>[
      '하위 과제 ${entries.length}개',
      if (totalAssignmentCount > 0) '숙제 $totalAssignmentCount회',
      if (dueDate != null) _formatHomeworkDueChipLabel(dueDate),
    ].join(' · ');
    final double collapsedReservedHeight =
        (_homeworkChipCollapsedHeight * 0.9) + 2;
    const double expandedReservedHeight = 322.0;

    String stripUnitPrefix(String raw) {
      return raw.replaceFirst(RegExp(r'^\s*\d+\.\d+\.\(\d+\)\s+'), '').trim();
    }

    String extractBookName(HomeworkItem hw) {
      final contentRaw = (hw.content ?? '').trim();
      final match = RegExp(r'(?:^|\n)\s*교재:\s*([^\n]+)').firstMatch(contentRaw);
      final fromContent = match?.group(1)?.trim() ?? '';
      if (fromContent.isNotEmpty) return fromContent;

      final hasLinkedTextbook = (hw.bookId ?? '').trim().isNotEmpty &&
          (hw.gradeLabel ?? '').trim().isNotEmpty;
      if (hasLinkedTextbook) {
        final stripped = stripUnitPrefix(hw.title.trim());
        if (stripped.isNotEmpty) {
          final idx = stripped.indexOf('·');
          if (idx == -1) return stripped;
          final candidate = stripped.substring(0, idx).trim();
          if (candidate.isNotEmpty) return candidate;
        }
      }

      final typeLabel = (hw.type ?? '').trim();
      if (typeLabel.isNotEmpty) return typeLabel;
      return '';
    }

    String extractCourseName(HomeworkItem hw) {
      final contentRaw = (hw.content ?? '').trim();
      final match = RegExp(r'(?:^|\n)\s*과정:\s*([^\n]+)').firstMatch(contentRaw);
      return match?.group(1)?.trim() ?? '';
    }

    String textbookAndCourseLabel(HomeworkItem hw) {
      final bookName = extractBookName(hw);
      final courseName = extractCourseName(hw);
      if (bookName.isEmpty && courseName.isEmpty) return '-';
      if (bookName.isEmpty) return courseName;
      if (courseName.isEmpty) return bookName;
      return '$bookName · $courseName';
    }

    final groupedCardBackground = FabTabBarTokens.previewAcademyPanelStyleFor(
      Theme.of(context).brightness,
    ).groupedCardBackground;

    final String line1TextbookLabel = () {
      final labels = <String>[];
      for (final entry in entries) {
        final label = textbookAndCourseLabel(entry.value);
        if (label.isEmpty || label == '-') continue;
        if (!labels.contains(label)) labels.add(label);
      }
      if (labels.isEmpty) return '-';
      if (labels.length == 1) return labels.first;
      return '${labels.first} 외 ${labels.length - 1}개';
    }();
    final String line2GroupTitle =
        group.title.trim().isEmpty ? '그룹 과제' : group.title.trim();

    String childLabel(HomeworkItem hw) {
      final title = hw.title.trim();
      if (title.isNotEmpty) return title;
      final pageRaw = (hw.page ?? '').trim();
      if (pageRaw.isNotEmpty) return 'p.$pageRaw';
      return '(제목 없음)';
    }

    String childPageLabel(HomeworkItem hw) {
      final pageRaw = (hw.page ?? '').trim();
      return pageRaw.isEmpty ? '-' : 'p.$pageRaw';
    }

    String childCountLabel(HomeworkItem hw) {
      final count = hw.count;
      if (count == null || count <= 0) return '-';
      return '$count문항';
    }

    String childPageCountLabel(HomeworkItem hw) {
      final page = childPageLabel(hw);
      final count = childCountLabel(hw);
      if (page == '-' && count == '-') return '-';
      if (page == '-') return count;
      if (count == '-') return page;
      return '$page · $count';
    }

    String childMemoLabel(HomeworkItem hw) {
      final memo = (hw.memo ?? '').trim();
      return memo.isEmpty ? '-' : memo;
    }

    final childRows = <Widget>[];
    for (int childIndex = 0; childIndex < entries.length; childIndex++) {
      final hw = entries[childIndex].value;
      childRows.add(
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: double.infinity),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${childIndex + 1}. ${childLabel(hw)}',
                  style: cardTheme.secondaryRowStyle.copyWith(height: 1.2),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                SizedBox(
                  width: double.infinity,
                  child: Text(
                    childPageCountLabel(hw),
                    style: cardTheme.secondaryRowStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                  ),
                ),
                const SizedBox(height: 3),
                SizedBox(
                  width: double.infinity,
                  child: Text(
                    childMemoLabel(hw),
                    style: cardTheme.secondaryRowStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      if (childIndex != entries.length - 1) {
        childRows.addAll([
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            height: 1.3,
            color: cardTheme.childDividerColor,
          ),
          const SizedBox(height: 10),
        ]);
      } else {
        childRows.add(const SizedBox(height: 6));
      }
    }

    out.add(
      _SlideableHomeworkChip(
        key: ValueKey('reserved_group_chip_${studentId}_${group.groupKey}'),
        maxSlide: _homeworkChipMaxSlideFor(
              isExpanded ? expandedReservedHeight : collapsedReservedHeight,
            ) *
            1.3,
        canSlideDown: !isActivating,
        canSlideUp: !isActivating,
        downLabel: isActivating ? '' : '삭제',
        upLabel: '',
        showUpArrowWhenLabelEmpty: true,
        upSubLabel: '출제',
        downColor: const Color(0xFFE57373),
        upColor: kDlgAccent,
        onTap: () {
          if (isActivating) return;
          final current = _expandedReservedGroupKeyByStudent[studentId];
          if (current == group.groupKey) {
            _expandedReservedGroupKeyByStudent.remove(studentId);
          } else {
            _expandedReservedGroupKeyByStudent[studentId] = group.groupKey;
          }
          _markReservedGroupUiDirty();
        },
        onLongPress: null,
        onDoubleTap: null,
        onSlideDown: () {
          unawaited(
            _deleteReservedHomeworkGroup(
              context: context,
              studentId: studentId,
              group: group,
            ),
          );
        },
        onSlideUp: () async {
          await _activateReservedHomeworkGroup(
            context: context,
            studentId: studentId,
            group: group,
          );
        },
        child: AnimatedContainer(
          key: ValueKey('reserved_group_card_${studentId}_${group.groupKey}'),
          duration: _homeworkChipExpandDuration,
          curve: _homeworkChipExpandCurve,
          constraints: BoxConstraints(
            minHeight:
                isExpanded ? expandedReservedHeight : collapsedReservedHeight,
          ),
          decoration: BoxDecoration(
            color: groupedCardBackground,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isExpanded
                  ? cardTheme.reservedBorderExpandedColor
                  : cardTheme.reservedBorderColor,
              width: isExpanded ? 1.4 : 1.1,
            ),
            boxShadow: isExpanded ? cardTheme.reservedExpandedShadow : const [],
          ),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.inventory_2_rounded,
                    size: 17,
                    color: cardTheme.iconMutedColor,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      line1TextbookLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: cardTheme.titleStyle.copyWith(height: 1.15),
                    ),
                  ),
                  if (isActivating)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.7,
                        color: kDlgAccent,
                      ),
                    )
                  else
                    Icon(
                      isExpanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 20,
                      color: cardTheme.iconMutedColor,
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                line2GroupTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: cardTheme.metaStyle.copyWith(height: 1.2),
              ),
              const SizedBox(height: 5),
              Text(
                topMeta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: cardTheme.secondaryRowStyle,
              ),
              const SizedBox(height: 5),
              Text(
                bottomMeta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: cardTheme.secondaryRowStyle,
              ),
              if (isExpanded) ...[
                const SizedBox(height: 20),
                Divider(
                  height: 1,
                  thickness: 1.2,
                  color: cardTheme.dividerStrongColor,
                ),
                const SizedBox(height: 16),
                Text(
                  '그룹 과제 ${entries.length}개',
                  style: cardTheme.secondaryRowStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 12),
                ...childRows,
              ],
            ],
          ),
        ),
      ),
    );
    if (i != reservedGroups.length - 1) {
      out.add(const SizedBox(height: 9));
    }
  }
  return out;
}

List<_ReservedHomeworkGroupSection> _resolveReservedHomeworkGroupsForStudent(
  String studentId,
  List<HomeworkAssignmentDetail> activeAssignments,
) {
  final reservedPairs = _resolveReservedHomeworkPairsForStudent(
    studentId,
    activeAssignments,
  );
  if (reservedPairs.isEmpty) return const <_ReservedHomeworkGroupSection>[];

  final groupedPairs =
      <String, List<MapEntry<HomeworkAssignmentDetail, HomeworkItem>>>{};
  final groupIdByKey = <String, String>{};
  final groupTitleByKey = <String, String>{};
  for (final pair in reservedPairs) {
    final assignment = pair.key;
    final hw = pair.value;
    final groupId = (assignment.groupId ?? '').trim();
    final String groupKey =
        groupId.isNotEmpty ? 'group:$groupId' : 'item:${hw.id}';
    groupedPairs
        .putIfAbsent(
          groupKey,
          () => <MapEntry<HomeworkAssignmentDetail, HomeworkItem>>[],
        )
        .add(pair);
    if (groupId.isNotEmpty) {
      groupIdByKey[groupKey] = groupId;
    }
    final snapshotTitle = (assignment.groupTitleSnapshot ?? '').trim();
    if (snapshotTitle.isNotEmpty && !groupTitleByKey.containsKey(groupKey)) {
      groupTitleByKey[groupKey] = snapshotTitle;
    }
  }

  final groupsById = <String, HomeworkGroup>{
    for (final group in HomeworkStore.instance.groups(studentId))
      group.id: group,
  };
  final out = <_ReservedHomeworkGroupSection>[];
  for (final entry in groupedPairs.entries) {
    final groupKey = entry.key;
    final rows = entry.value;
    final rawGroupId = groupIdByKey[groupKey];
    final groupId = (rawGroupId ?? '').trim();
    var title = (groupTitleByKey[groupKey] ?? '').trim();
    if (title.isEmpty && groupId.isNotEmpty) {
      title = (groupsById[groupId]?.title ?? '').trim();
    }
    if (title.isEmpty) {
      final fromItemTitle = rows.first.value.title.trim();
      title = fromItemTitle.isNotEmpty
          ? fromItemTitle
          : (groupId.isNotEmpty ? '그룹 과제' : '(제목 없음)');
    }
    out.add(
      _ReservedHomeworkGroupSection(
        groupKey: groupKey,
        groupId: groupId.isEmpty ? null : groupId,
        title: title,
        entries:
            List<MapEntry<HomeworkAssignmentDetail, HomeworkItem>>.unmodifiable(
          rows,
        ),
      ),
    );
  }
  return out;
}

List<MapEntry<HomeworkAssignmentDetail, HomeworkItem>>
    _resolveReservedHomeworkPairsForStudent(
  String studentId,
  List<HomeworkAssignmentDetail> activeAssignments,
) {
  final reservedAssignments = activeAssignments
      .where((a) => a.homeworkItemId.trim().isNotEmpty)
      .where(_isReservationAssignment)
      .toList()
    ..sort((a, b) {
      final orderCmp = a.orderIndex.compareTo(b.orderIndex);
      if (orderCmp != 0) return orderCmp;
      return a.assignedAt.compareTo(b.assignedAt);
    });
  if (reservedAssignments.isEmpty) {
    return const <MapEntry<HomeworkAssignmentDetail, HomeworkItem>>[];
  }

  final reservedPairs = <MapEntry<HomeworkAssignmentDetail, HomeworkItem>>[];
  for (final assignment in reservedAssignments) {
    final hw =
        HomeworkStore.instance.getById(studentId, assignment.homeworkItemId);
    if (hw == null || hw.status == HomeworkStatus.completed) continue;
    reservedPairs.add(MapEntry(assignment, hw));
  }
  return reservedPairs;
}

List<Widget> _buildHomeworkChipsOnceForStudent(
  BuildContext context,
  String studentId,
  double tick,
  Map<String, String> flowNames,
  Map<String, int> assignmentCounts,
  Set<String> hiddenItemIds,
  Map<String, HomeworkAssignmentCycleMeta> assignmentCycleMetaByItem, {
  _HomeworkDraftEditorController? homeworkDraftEditor,
  double homeworkDraftReveal = 1,
  Set<String> goalSnapshotItemIds = const <String>{},
  bool hasGoalSnapshot = false,
  Map<String, DateTime?> assignmentDueByGroupId = const {},
  Map<String, DateTime?> assignmentDueByItemId = const {},
  Map<String, String> assignmentCheckLabelByGroupId = const {},
  Map<String, HomeworkGradingProgressRate> progressRatesByItem = const {},
  Map<({String studentId, String itemId}), bool> pendingConfirms = const {},
  Future<void> Function(
          {required BuildContext context,
          required String studentId,
          required HomeworkItem hw})?
      onPhase3Tap,
  Future<void> Function({
    required BuildContext context,
    required String studentId,
    required HomeworkGroup group,
    required HomeworkItem summary,
    required List<HomeworkItem> children,
  })? onHomeworkCheckTap,
  void Function(String studentId, List<HomeworkItem> submittedItems)?
      onGroupSubmittedDoubleTap,
  bool printPickMode = false,
  Future<void> Function(
          {required BuildContext context,
          required String studentId,
          required HomeworkItem hw})?
      onPrintPickTap,
  Future<void> Function({
    required BuildContext context,
    required String studentId,
    required HomeworkGroup group,
    required HomeworkItem summary,
    required List<HomeworkItem> children,
  })? onGroupPrintPickTap,
  Future<void> Function(
          {required BuildContext context,
          required String studentId,
          required HomeworkItem hw})?
      onPrintPickLongPress,
  Future<void> Function({
    required BuildContext context,
    required String studentId,
    required HomeworkGroup group,
    required HomeworkItem summary,
    required List<HomeworkItem> children,
  })? onGroupPrintPickLongPress,
  VoidCallback? onPrintPickSecondaryTap,
  void Function(({String studentId, String itemId}) key)? onSlideDownComplete,
  Set<String> expandedHomeworkIds = const {},
  void Function(String id)? onToggleExpand,
}) {
  final groups = HomeworkStore.instance.groups(studentId);
  final displayedGroups =
      <({HomeworkGroup group, List<HomeworkItem> children})>[];
  for (final group in groups) {
    final children = HomeworkStore.instance
        .itemsInGroup(studentId, group.id)
        .where((e) => e.status != HomeworkStatus.completed)
        .where((e) => !HomeworkStore.instance.isOptimisticallyCompleting(e.id))
        .where((e) => !hiddenItemIds.contains(e.id))
        .toList();
    if (children.isEmpty) continue;
    displayedGroups.add((group: group, children: children));
  }

  if (displayedGroups.isEmpty) return const <Widget>[];
  final cappedGroups = displayedGroups.take(12).toList(growable: false);

  HomeworkItem buildGroupSummary(
    HomeworkGroup group,
    List<HomeworkItem> children,
  ) {
    final first = children.first;
    final String cycleIdentity =
        group.cycleStartedAt?.toUtc().toIso8601String() ?? '__idle__';
    final String? previousCycleIdentity =
        _groupCycleIdentityByGroupId[group.id];
    if (previousCycleIdentity != cycleIdentity) {
      _groupCycleIdentityByGroupId[group.id] = cycleIdentity;
      _groupChildCycleBaseByGroupId[group.id] = <String, int>{};
    }
    final Map<String, int> childCycleBaseCache = _groupChildCycleBaseByGroupId
        .putIfAbsent(group.id, () => <String, int>{});
    final Set<String> currentChildIds = <String>{};

    final int runtimePhase = group.runtimePhase;
    final int runtimeAccumulatedMs = group.runtimeAccumulatedMs;
    final DateTime? runtimeRunStart = group.runtimeRunStart;
    final DateTime? runtimeFirstStartedAt = group.runtimeFirstStartedAt;
    final DateTime? runtimeUpdatedAt = group.runtimeUpdatedAt;
    final int runtimeCheckCount = group.runtimeCheckCount;

    HomeworkItem? runningChild;
    bool hasSubmitted = false;
    bool hasConfirmed = false;
    int maxPhase = 1;
    int groupCycleBaseMs = 0;
    int groupCycleProgressBaseMs = 0;
    int groupCheckCount = 0;
    int totalCount = 0;
    DateTime? latestUpdated;
    DateTime? latestSubmitted;
    DateTime? latestConfirmed;
    DateTime? latestWaiting;
    final pages = <String>[];
    for (final child in children) {
      if (runningChild == null &&
          (child.runStart != null || child.phase == 2)) {
        runningChild = child;
      }
      if (child.phase == 3) hasSubmitted = true;
      if (child.phase == 4) hasConfirmed = true;
      if (child.phase > maxPhase) maxPhase = child.phase;
      int rawChildCycleBaseMs = child.cycleBaseAccumulatedMs;
      if (rawChildCycleBaseMs <= 0 &&
          child.phase == 1 &&
          child.accumulatedMs > 0) {
        // 마이그레이션 미적용/과거 데이터에서도 대기 기준점은 안전하게 유지한다.
        rawChildCycleBaseMs = child.accumulatedMs;
      }
      currentChildIds.add(child.id);
      final int childCycleBaseMs = childCycleBaseCache.putIfAbsent(
        child.id,
        () =>
            rawChildCycleBaseMs > 0 ? rawChildCycleBaseMs : child.accumulatedMs,
      );
      groupCycleBaseMs += childCycleBaseMs;
      final int childCycleProgressBaseMs =
          math.max(0, child.accumulatedMs - childCycleBaseMs);
      if (childCycleProgressBaseMs > groupCycleProgressBaseMs) {
        groupCycleProgressBaseMs = childCycleProgressBaseMs;
      }
      if (child.checkCount > groupCheckCount) {
        groupCheckCount = child.checkCount;
      }
      final childCount = child.count;
      if (childCount != null && childCount > 0) totalCount += childCount;
      final p = homeworkItemPageRangeText(
        page: child.page,
        unitMappings: child.unitMappings,
      );
      if (p.isNotEmpty) pages.add(p);
      final updated = child.updatedAt;
      if (updated != null &&
          (latestUpdated == null || updated.isAfter(latestUpdated))) {
        latestUpdated = updated;
      }
      final submitted = child.submittedAt;
      if (submitted != null &&
          (latestSubmitted == null || submitted.isAfter(latestSubmitted))) {
        latestSubmitted = submitted;
      }
      final confirmed = child.confirmedAt;
      if (confirmed != null &&
          (latestConfirmed == null || confirmed.isAfter(latestConfirmed))) {
        latestConfirmed = confirmed;
      }
      final waiting = child.waitingAt;
      if (waiting != null &&
          (latestWaiting == null || waiting.isAfter(latestWaiting))) {
        latestWaiting = waiting;
      }
    }
    childCycleBaseCache
        .removeWhere((childId, _) => !currentChildIds.contains(childId));

    final int childDerivedPhase = runningChild != null
        ? 2
        : (hasSubmitted ? 3 : (hasConfirmed ? 4 : maxPhase.clamp(1, 4)));
    final bool hasFreshRuntimeSnapshot = runtimePhase >= 1 &&
        runtimePhase <= 4 &&
        (latestUpdated == null ||
            (runtimeUpdatedAt != null &&
                !latestUpdated.isAfter(runtimeUpdatedAt)));
    final int phase =
        hasFreshRuntimeSnapshot ? runtimePhase : childDerivedPhase;
    final pageSummary = () {
      if (pages.isEmpty) return '';
      // 그룹 과제 페이지는 자식 페이지의 합집합을 연속 구간으로 압축해 표시한다.
      // 예: 1-5(1단원) + 6-10(2단원) -> "1-10", 1-5 + 8-10 -> "1-5,8-10"
      final merged = mergeHomeworkPageRawStrings(pages);
      return merged.isEmpty ? pages.join(', ') : merged;
    }();
    final normalizedChildTypes = <String>{
      for (final child in children)
        if ((child.type ?? '').trim().isNotEmpty) (child.type ?? '').trim(),
    };
    final sortedChildTypes = normalizedChildTypes.toList(growable: false)
      ..sort();
    final summaryType = sortedChildTypes.isEmpty
        ? '${children.length}개 과제'
        : (sortedChildTypes.length == 1
            ? sortedChildTypes.first
            : '${sortedChildTypes.first} 외 ${sortedChildTypes.length - 1}개');
    if (phase == 2 && runningChild == null && children.isNotEmpty) {
      runningChild = children.first;
    }

    final DateTime? groupCycleStartedAt = group.cycleStartedAt ??
        runtimeFirstStartedAt ??
        runtimeRunStart ??
        runningChild?.runStart;
    final bool hasRuntimeSnapshot = hasFreshRuntimeSnapshot;
    // 표시 계약 통일:
    // - accumulatedMs: "러닝 delta 제외" 누적값(base)
    // - runStart: 러닝 시작 시각(있으면 렌더 단계에서 1회 delta 가산)
    // 이렇게 유지해야 그룹 요약 카드에서 시간이 2배로 증가하지 않는다.
    final int groupAccumulatedBaseMs = hasRuntimeSnapshot
        ? runtimeAccumulatedMs
        : (groupCycleBaseMs + groupCycleProgressBaseMs);
    final DateTime? groupRunStart = phase == 2
        ? (hasRuntimeSnapshot
            ? (runtimeRunStart ?? runningChild?.runStart)
            : runningChild?.runStart)
        : null;
    final HomeworkItem assignmentCodeSource = () {
      for (final child in children) {
        if (_formatHomeworkAssignmentCode(child.assignmentCode, fallback: '')
            .isNotEmpty) {
          return child;
        }
      }
      return runningChild ?? first;
    }();
    return HomeworkItem(
      id: (runningChild ?? first).id,
      assignmentCode: assignmentCodeSource.assignmentCode,
      learningTrackCode: group.learningTrackCode,
      title: group.title.trim().isEmpty ? first.title : group.title.trim(),
      body: first.body,
      color: first.color,
      flowId: group.flowId ?? first.flowId,
      testOriginFlowId: first.testOriginFlowId,
      type: summaryType,
      page: pageSummary,
      count: totalCount > 0 ? totalCount : null,
      timeLimitMinutes: first.timeLimitMinutes,
      memo: first.memo,
      content: first.content,
      pbPresetId: first.pbPresetId,
      bookId: first.bookId,
      gradeLabel: first.gradeLabel,
      sourceUnitLevel: first.sourceUnitLevel,
      sourceUnitPath: first.sourceUnitPath,
      defaultSplitParts: first.defaultSplitParts,
      checkCount: runtimeCheckCount > 0 ? runtimeCheckCount : groupCheckCount,
      orderIndex: group.orderIndex,
      createdAt: first.createdAt,
      updatedAt: latestUpdated ?? first.updatedAt,
      status: HomeworkStatus.inProgress,
      phase: phase,
      accumulatedMs: groupAccumulatedBaseMs,
      cycleBaseAccumulatedMs: groupCycleBaseMs,
      runStart: groupRunStart,
      completedAt: null,
      firstStartedAt: groupCycleStartedAt,
      submittedAt: latestSubmitted,
      confirmedAt: latestConfirmed,
      waitingAt: latestWaiting,
      version: 1,
    );
  }

  final groupWidgets = <Widget>[];
  final orderedGroupIds = <String>[];
  final assignedItemIds = assignmentDueByItemId.keys.toSet();
  for (int i = 0; i < cappedGroups.length; i++) {
    final entry = cappedGroups[i];
    final group = entry.group;
    final children = entry.children;
    if (children.isEmpty) continue;
    orderedGroupIds.add(group.id);
    final summary = buildGroupSummary(group, children);
    final bool hasRunningChild = summary.phase == 2 ||
        children.any((e) => e.runStart != null || e.phase == 2);
    // 수행 단계 자동 펼침 없음 — 카드 탭으로만 펼침/접힘.
    final bool groupExpanded = expandedHomeworkIds.contains(group.id);
    DateTime? dueDate = assignmentDueByGroupId[group.id];
    bool hasHomeworkAssignment = assignmentDueByGroupId.containsKey(group.id);
    for (final child in children) {
      if (assignmentDueByItemId.containsKey(child.id)) {
        hasHomeworkAssignment = true;
      }
      dueDate = _mergeHomeworkDueDate(dueDate, assignmentDueByItemId[child.id]);
    }
    // assignment 행 로드가 늦거나 서버 RPC가 그룹을 재구성해 group_id가 어긋난
    // 동안에도, 숙제로 확정된 항목은 숙제 칩을 유지한다.
    final bool markedAsHomework =
        children.any((e) => e.status == HomeworkStatus.homework);
    final dueLabel = assignmentCheckLabelByGroupId[group.id] ??
        (dueDate == null ? null : _formatHomeworkDueChipLabel(dueDate));
    final progressRate =
        _aggregateHomeworkProgressRates(children, progressRatesByItem);
    final double chipH = groupExpanded
        ? _homeworkGroupExpandedHeightForChildCount(children.length)
        : _homeworkChipCollapsedHeight;
    final groupFlowId = (group.flowId ?? summary.flowId ?? '').trim();
    final groupFlowName = flowNames[groupFlowId] ?? '';
    final int groupAssignmentCount = children.fold<int>(
      0,
      (sum, item) => sum + (assignmentCounts[item.id] ?? 0),
    );
    final submittedChildren = children
        .where((e) =>
            e.status != HomeworkStatus.completed &&
            e.completedAt == null &&
            e.phase == 3)
        .toList(growable: false);
    final submittedKeys = submittedChildren
        .map((e) => (studentId: studentId, itemId: e.id))
        .toList(growable: false);
    final bool groupPendingSelected = submittedKeys.any(
      pendingConfirms.containsKey,
    );
    final bool groupPendingComplete = groupPendingSelected &&
        submittedKeys.any((key) => pendingConfirms[key] == true);
    final bool groupIsRunning = hasRunningChild;
    final bool groupIsSubmitted = submittedKeys.isNotEmpty;
    final bool groupIsWaiting = summary.phase == 1;
    final bool groupIsConfirmed = summary.phase == 4;
    final bool hasTestChild = children.any(_isTestHomeworkItem);
    final bool groupSlideDownIsEdit = groupIsWaiting || groupIsConfirmed;
    final bool groupCanSlideDown =
        groupIsRunning || groupIsSubmitted || groupSlideDownIsEdit;
    final String groupDownLabel = groupSlideDownIsEdit
        ? '수정'
        : (groupIsSubmitted ? '완료' : (groupIsRunning ? '멈춤' : ''));
    final Color draftExtensionBorderColor = groupIsConfirmed
        ? (Color.lerp(kDlgBorder, kDlgAccent,
                0.5 + 0.5 * math.sin(2 * math.pi * tick)) ??
            kDlgBorder)
        : (groupIsSubmitted
            ? Colors.transparent
            : (groupIsRunning
                ? kDlgAccent
                : (summary.phase == 1 ? Colors.transparent : kDlgBorder)));
    HomeworkItem? runningChildForSlide;
    if (groupIsRunning) {
      for (final child in children) {
        if (child.runStart != null || child.phase == 2) {
          runningChildForSlide = child;
          break;
        }
      }
    }

    final bool draftExtensionOpen =
        homeworkDraftEditor != null && homeworkDraftReveal > 0;
    final CustomPainter? draftUnifiedBorderPainter = !draftExtensionOpen
        ? null
        : (groupIsSubmitted
            ? _RotatingBorderPainter(
                baseColor: kDlgAccent,
                tick: tick,
                strokeWidth: 3,
                cornerRadius: 12,
              )
            : (draftExtensionBorderColor.a > 0.01
                ? _SolidRoundedBorderPainter(
                    color: draftExtensionBorderColor,
                    strokeWidth: 3,
                    cornerRadius: 12,
                  )
                : null));
    final groupCard = _SlideableHomeworkChip(
      key: ValueKey('hw_group_chip_${group.id}'),
      foregroundPainter: draftUnifiedBorderPainter,
      extension: homeworkDraftEditor == null
          ? null
          : AnimatedBuilder(
              animation: homeworkDraftEditor,
              builder: (context, _) {
                return _HomeworkDraftCardExtension(
                  groupId: group.id,
                  children: children,
                  width: _homeworkDraftExtensionWidth * homeworkDraftReveal,
                  height: chipH,
                  enabled: !hasHomeworkAssignment,
                  dueDateEnabled: homeworkDraftEditor.destinationForGroup(
                              group.id, children) ==
                          HomeworkPlanDestination.homework ||
                      hasHomeworkAssignment,
                  destination: homeworkDraftEditor.destinationForGroup(
                    group.id,
                    children,
                  ),
                  childDestinations: <String, HomeworkPlanDestination>{
                    for (final child in children)
                      child.id:
                          homeworkDraftEditor.destinationForItem(child.id),
                  },
                  expanded: groupExpanded,
                  dueDate: homeworkDraftEditor.dueDateByGroupId[group.id] ??
                      assignmentDueByGroupId[group.id],
                  existingHomework: hasHomeworkAssignment,
                  onDestinationChanged: (value) {
                    unawaited(
                      homeworkDraftEditor
                          .setGroupDestination(group.id, children, value)
                          .catchError((_) {
                        if (context.mounted) {
                          _showHomeworkChipSnackBar(
                            context,
                            '과제 계획 변경에 실패했습니다.',
                          );
                        }
                      }),
                    );
                  },
                  onChildDestinationChanged: (itemId, value) {
                    unawaited(
                      homeworkDraftEditor
                          .setChildDestination(
                        group.id,
                        children,
                        itemId,
                        value,
                      )
                          .catchError((_) {
                        if (context.mounted) {
                          _showHomeworkChipSnackBar(
                            context,
                            '하위과제 분리에 실패했습니다.',
                          );
                        }
                      }),
                    );
                  },
                  onDueDateChanged: (value) {
                    unawaited(
                      homeworkDraftEditor
                          .setDueDate(group.id, children, value)
                          .catchError((_) {
                        if (context.mounted) {
                          _showHomeworkChipSnackBar(
                            context,
                            '숙제 마감일 변경에 실패했습니다.',
                          );
                        }
                      }),
                    );
                  },
                );
              },
            ),
      maxSlide: _homeworkChipMaxSlideFor(_homeworkChipCollapsedHeight),
      canSlideDown: !printPickMode && groupCanSlideDown,
      canSlideUp: !printPickMode,
      downLabel: groupDownLabel,
      upLabel: '취소',
      downColor: groupSlideDownIsEdit
          ? kDlgAccent
          : (groupIsSubmitted
              ? const Color(0xFF4CAF50)
              : const Color(0xFF9FB3B3)),
      upColor: const Color(0xFFE57373),
      onTap: () {
        if (printPickMode) {
          if (onGroupPrintPickTap != null) {
            unawaited(
              onGroupPrintPickTap(
                context: context,
                studentId: studentId,
                group: group,
                summary: summary,
                children: children,
              ),
            );
            return;
          }
          if (onPrintPickTap != null) {
            unawaited(
              onPrintPickTap(
                context: context,
                studentId: studentId,
                hw: summary,
              ),
            );
            return;
          }
          return;
        }
        // 숙제 카드도 탭으로 펼쳐 검사 날짜·히스토리를 볼 수 있게 한다.
        // 숙제 검사는 더블탭으로 연다.
        onToggleExpand?.call(group.id);
      },
      onLongPress: printPickMode
          ? () {
              if (onGroupPrintPickLongPress != null) {
                unawaited(
                  onGroupPrintPickLongPress(
                    context: context,
                    studentId: studentId,
                    group: group,
                    summary: summary,
                    children: children,
                  ),
                );
                return;
              }
              if (onPrintPickLongPress != null) {
                unawaited(
                  onPrintPickLongPress(
                    context: context,
                    studentId: studentId,
                    hw: summary,
                  ),
                );
              }
            }
          : null,
      onSecondaryTap: printPickMode ? onPrintPickSecondaryTap : null,
      onSlideDown: () {
        if (printPickMode) return;
        if (groupSlideDownIsEdit) {
          unawaited(
            _showHomeworkGroupActionDialog(
              context: context,
              studentId: studentId,
              group: group,
            ),
          );
          return;
        }
        if (groupIsRunning && runningChildForSlide != null) {
          unawaited(
            HomeworkStore.instance.pause(studentId, runningChildForSlide.id),
          );
          return;
        }
        if (groupIsSubmitted) {
          for (final key in submittedKeys) {
            onSlideDownComplete?.call(key);
          }
        }
      },
      onSlideUp: () async {
        if (printPickMode) return;
        await _showHomeworkGroupSlideCancelDialog(
          context: context,
          studentId: studentId,
          children: children,
        );
      },
      onDoubleTap: () {
        if (printPickMode) return;
        final phase = summary.phase.clamp(1, 4);
        // 반환된 확인 카드가 숙제 assignment를 아직 가지고 있어도,
        // phase 4 확인이 검사 다이얼로그보다 우선이다. 서버가
        // pending_complete면 즉시 완료, 아니면 대기로 전환한다.
        if (phase == 4) {
          unawaited(
            HomeworkStore.instance.bulkTransitionGroup(
              studentId,
              group.id,
              fromPhase: 4,
            ),
          );
          return;
        }
        if (hasHomeworkAssignment || markedAsHomework) {
          unawaited(() async {
            if (onHomeworkCheckTap != null) {
              await onHomeworkCheckTap(
                context: context,
                studentId: studentId,
                group: group,
                summary: summary,
                children: children,
              );
              return;
            }
            await _runHomeworkCheckDialogForGroup(
              context: context,
              studentId: studentId,
              group: group,
              summary: summary,
              children: children,
            );
          }());
          return;
        }

        switch (phase) {
          case 1:
            if (hasTestChild &&
                !HomeworkStore.instance.isStudentInClassTime(studentId)) {
              _showHomeworkChipSnackBar(context, '테스트 카드는 수업시간에만 수행할 수 있어요.');
              return;
            }
            unawaited(
              HomeworkStore.instance.bulkTransitionGroup(
                studentId,
                group.id,
                fromPhase: 1,
              ),
            );
            return;
          case 2:
            unawaited(
              HomeworkStore.instance.bulkTransitionGroup(
                studentId,
                group.id,
                fromPhase: 2,
              ),
            );
            return;
          case 3:
            if (submittedChildren.isNotEmpty) {
              onGroupSubmittedDoubleTap?.call(studentId, submittedChildren);
            }
            return;
          case 4:
            return;
        }
      },
      child: _buildHomeworkChipWithReorderHandle(
        index: i,
        enableReorderDrag: !groupExpanded,
        chipVisual: _buildHomeworkChipVisual(
          context,
          studentId,
          summary,
          groupFlowName,
          groupAssignmentCount,
          groupId: group.id,
          assignedItemIds: assignedItemIds,
          tick: tick,
          dueLabel: dueLabel,
          isHomeworkDue: hasHomeworkAssignment || markedAsHomework,
          progressRate: progressRate,
          attachRightExtension:
              homeworkDraftEditor != null && homeworkDraftReveal > 0,
          isExpanded: groupExpanded,
          showAdditionalPrefix: hasGoalSnapshot &&
              children.isNotEmpty &&
              !children.any(
                (child) => goalSnapshotItemIds.contains(child.id),
              ),
          groupChildren: children,
          isPendingConfirm: groupPendingSelected,
          isCompleteCheckbox: groupPendingComplete,
          onGroupChildPageTap: (child) {
            unawaited(
              _showGroupChildPageEditDialog(
                context: context,
                studentId: studentId,
                child: child,
              ),
            );
          },
          onGroupChildAddTap: () {
            unawaited(
              _showAddChildHomeworkDialog(
                context: context,
                studentId: studentId,
                group: group,
                children: children,
              ),
            );
          },
          onGroupTitleTap:
              groupIsWaiting && !hasHomeworkAssignment && !printPickMode
                  ? () {
                      unawaited(
                        _showHomeworkGroupTitleEditDialog(
                          context: context,
                          studentId: studentId,
                          group: group,
                        ),
                      );
                    }
                  : null,
          onTypeTap: printPickMode
              ? null
              : () {
                  final targets = children.isEmpty ? [summary] : children;
                  unawaited(
                    _showHomeworkTypeEditDialog(
                      context: context,
                      studentId: studentId,
                      targets: targets,
                    ),
                  );
                },
          onInspectionDateTap: (hasHomeworkAssignment || markedAsHomework)
              ? () {
                  final historyTitle = group.title.trim().isNotEmpty
                      ? group.title.trim()
                      : summary.title.trim();
                  unawaited(
                    _showHomeworkAssignmentHistoryDialog(
                      context: context,
                      studentId: studentId,
                      itemIds:
                          children.map((e) => e.id).toList(growable: false),
                      title: historyTitle.isEmpty ? '숙제' : historyTitle,
                    ),
                  );
                }
              : null,
          onGroupChildDropBefore: (dragged, target) async {
            await _moveGroupChildByDrag(
              context: context,
              studentId: studentId,
              targetGroup: group,
              source: dragged,
              targetBefore: target,
            );
          },
          onGroupChildDropToEnd: (dragged) async {
            await _moveGroupChildByDrag(
              context: context,
              studentId: studentId,
              targetGroup: group,
              source: dragged,
            );
          },
          onInfoTap: () {
            unawaited(
              _showHomeworkGroupActionDialog(
                context: context,
                studentId: studentId,
                group: group,
              ),
            );
          },
        ),
      ),
    );
    groupWidgets.add(groupCard);
  }

  if (groupWidgets.isEmpty || orderedGroupIds.isEmpty) return const <Widget>[];
  return <Widget>[
    ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: groupWidgets.length,
      buildDefaultDragHandles: false,
      proxyDecorator: (child, _, __) =>
          Material(color: Colors.transparent, child: child),
      onReorder: (oldIndex, newIndex) {
        if (newIndex > oldIndex) newIndex -= 1;
        final reorderedIds = List<String>.from(orderedGroupIds);
        final movedId = reorderedIds.removeAt(oldIndex);
        reorderedIds.insert(newIndex, movedId);
        unawaited(
            HomeworkStore.instance.reorderGroups(studentId, reorderedIds));
      },
      itemBuilder: (context, index) {
        return _buildHomeworkReorderableItem(
          itemKey: 'current_hw_group_${orderedGroupIds[index]}',
          chip: groupWidgets[index],
          showBottomGap: index != groupWidgets.length - 1,
        );
      },
    ),
  ];
}

class _ResolvedHomeworkPdfLinks {
  final String bookId;
  final String gradeLabel;
  final String bodyPathRaw;
  final String answerPathRaw;
  final String solutionPathRaw;

  const _ResolvedHomeworkPdfLinks({
    required this.bookId,
    required this.gradeLabel,
    required this.bodyPathRaw,
    required this.answerPathRaw,
    required this.solutionPathRaw,
  });
}

class _ResolvedHomeworkPrintSource {
  final String pathRaw;
  final String sourceKey;
  final String bookId;
  final String gradeLabel;
  final bool isProblemBank;
  final String preferredPaperSize;

  const _ResolvedHomeworkPrintSource({
    required this.pathRaw,
    required this.sourceKey,
    this.bookId = '',
    this.gradeLabel = '',
    this.isProblemBank = false,
    this.preferredPaperSize = '',
  });

  bool get isEmpty => pathRaw.trim().isEmpty;
}

class _PreparedHomeworkPrintTarget {
  final _ResolvedHomeworkPrintSource source;
  final String printablePath;

  const _PreparedHomeworkPrintTarget({
    required this.source,
    required this.printablePath,
  });
}

class _HomeworkPrintRunResult {
  final bool printJobSentToSpooler;
  final String? error;

  const _HomeworkPrintRunResult({
    required this.printJobSentToSpooler,
    this.error,
  });
}

class _HomeworkGroupPrintRequest {
  final HomeworkItem seed;
  final String initialRange;
  final String dialogTitle;
  final List<HomeworkItem> eligibleChildren;
  final Map<String, bool> printableById;
  final Map<String, bool> initialSelectedById;
  final Map<String, String> childPageRangeById;
  final Map<String, HomeworkAssignmentDetail> assignmentByItemId;
  final Map<String, _ResolvedHomeworkPrintSource> sourceByItemId;
  final String? warning;
  final String? error;

  const _HomeworkGroupPrintRequest({
    required this.seed,
    required this.initialRange,
    required this.dialogTitle,
    required this.eligibleChildren,
    required this.printableById,
    required this.initialSelectedById,
    this.childPageRangeById = const <String, String>{},
    required this.assignmentByItemId,
    required this.sourceByItemId,
    this.warning,
    this.error,
  });
}

class _HomeworkPrintConfirmResult {
  final String pageRange;
  final List<String> selectedChildIds;
  final PrintDuplexMode duplexMode;

  const _HomeworkPrintConfirmResult({
    required this.pageRange,
    this.selectedChildIds = const <String>[],
    this.duplexMode = PrintDuplexMode.twoSidedLongEdge,
  });
}

enum _HomePrintQueueStatus {
  queued,
  printing,
  completed,
  failed,
}

class _HomePrintQueueItem {
  final int id;
  final String studentId;
  final String title;
  final HomeworkItem hw;
  final HomeworkGroup? group;
  final HomeworkItem? summary;
  final List<HomeworkItem> children;
  _HomePrintQueueStatus status;
  String message;
  String? error;

  _HomePrintQueueItem({
    required this.id,
    required this.studentId,
    required this.title,
    required this.hw,
    this.group,
    this.summary,
    this.children = const <HomeworkItem>[],
  })  : status = _HomePrintQueueStatus.queued,
        message = '대기 중',
        error = null;

  bool get isTerminal =>
      status == _HomePrintQueueStatus.completed ||
      status == _HomePrintQueueStatus.failed;
}

class _HomeworkPrintOverlayMeta {
  final String assignedDateText;
  final String bookCourseText;
  final String studentName;
  final String assignmentCodeText;

  const _HomeworkPrintOverlayMeta({
    required this.assignedDateText,
    required this.bookCourseText,
    required this.studentName,
    required this.assignmentCodeText,
  });
}

String _resolveHomeworkPrintStudentName(String studentId) {
  final sid = studentId.trim();
  if (sid.isEmpty) return '학생';
  for (final row in DataManager.instance.students) {
    if (row.student.id != sid) continue;
    final name = row.student.name.trim();
    return name.isEmpty ? '학생' : name;
  }
  return '학생';
}

Future<_HomeworkPrintOverlayMeta> _resolveHomeworkPrintOverlayMeta({
  required String studentId,
  required HomeworkItem fallbackHomework,
  required List<HomeworkItem> selectedHomeworks,
}) async {
  final byId = <String, HomeworkItem>{};
  for (final hw in selectedHomeworks) {
    final id = hw.id.trim();
    if (id.isEmpty || byId.containsKey(id)) continue;
    byId[id] = hw;
  }
  if (byId.isEmpty) {
    final fallbackId = fallbackHomework.id.trim();
    if (fallbackId.isNotEmpty) {
      byId[fallbackId] = fallbackHomework;
    }
  }
  if (byId.isEmpty) {
    return _HomeworkPrintOverlayMeta(
      assignedDateText: '-',
      bookCourseText: '교재 미기재',
      studentName: _resolveHomeworkPrintStudentName(studentId),
      assignmentCodeText: '-',
    );
  }

  HomeworkItem representative = byId.values.first;
  DateTime? firstAssignedAt;
  DateTime? firstCreatedAt;
  for (final hw in byId.values) {
    final createdAt = hw.createdAt;
    if (createdAt == null) continue;
    if (firstCreatedAt == null || createdAt.isBefore(firstCreatedAt)) {
      firstCreatedAt = createdAt;
    }
  }
  try {
    final assignmentsByItem =
        await HomeworkAssignmentStore.instance.loadAssignmentsForStudent(
      studentId,
    );
    for (final entry in byId.entries) {
      final rows = List<HomeworkAssignmentBrief>.from(
          assignmentsByItem[entry.key] ?? []);
      if (rows.isEmpty) continue;
      rows.sort((a, b) => a.assignedAt.compareTo(b.assignedAt));
      final DateTime candidateAssignedAt = rows.first.assignedAt;
      if (firstAssignedAt == null ||
          candidateAssignedAt.isBefore(firstAssignedAt)) {
        firstAssignedAt = candidateAssignedAt;
        representative = entry.value;
      }
    }
  } catch (_) {}

  final bookCourseRaw = _homeworkBookCourseLabel(representative).trim();
  final String bookCourseText = (bookCourseRaw.isEmpty || bookCourseRaw == '-')
      ? '교재 미기재'
      : bookCourseRaw;
  final DateTime? assignedDateBase = firstAssignedAt ?? firstCreatedAt;
  final String assignedDateText =
      assignedDateBase == null ? '-' : _formatDateShort(assignedDateBase);
  String assignmentCodeText = '-';
  for (final hw in byId.values) {
    final code = _formatHomeworkAssignmentCode(
      hw.assignmentCode,
      fallback: '',
    );
    if (code.isNotEmpty) {
      assignmentCodeText = code;
      break;
    }
  }
  return _HomeworkPrintOverlayMeta(
    assignedDateText: assignedDateText,
    bookCourseText: bookCourseText,
    studentName: _resolveHomeworkPrintStudentName(studentId),
    assignmentCodeText: assignmentCodeText,
  );
}

Future<sf.PdfFont> _loadHomeworkPrintOverlayFont(
  double size, {
  bool bold = false,
}) async {
  if (Platform.isWindows) {
    final candidates = <String>[
      if (bold) r'C:\Windows\Fonts\malgunbd.ttf',
      r'C:\Windows\Fonts\malgun.ttf',
      if (!bold) r'C:\Windows\Fonts\malgunbd.ttf',
    ];
    for (final path in candidates) {
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        return sf.PdfTrueTypeFont(
          bytes,
          size,
          style: bold ? sf.PdfFontStyle.bold : sf.PdfFontStyle.regular,
        );
      } catch (_) {}
    }
  }
  return sf.PdfStandardFont(
    sf.PdfFontFamily.helvetica,
    size,
    style: bold ? sf.PdfFontStyle.bold : sf.PdfFontStyle.regular,
  );
}

void _drawHomeworkPrintOverlayOnFirstPage({
  required sf.PdfPage page,
  required _HomeworkPrintOverlayMeta meta,
  required sf.PdfFont line1Font,
  required sf.PdfFont line2Font,
  required sf.PdfFont assignmentCodeFont,
  double topInsetOverride = 12,
  double bottomInsetOverride = 10,
  sf.PdfGraphics? graphicsOverride,
  bool bottomLeftLayout = false,
}) {
  final size = page.getClientSize();
  final g = graphicsOverride ?? page.graphics;
  final singleLineParts = <String>[
    if (meta.assignedDateText.trim().isNotEmpty && meta.assignedDateText != '-')
      meta.assignedDateText,
    if (meta.bookCourseText.trim().isNotEmpty) meta.bookCourseText,
    if (meta.studentName.trim().isNotEmpty) meta.studentName.trim() else '학생',
  ];
  final singleLineText =
      singleLineParts.isEmpty ? '-' : singleLineParts.join(' · ');
  final assignmentCodeText =
      meta.assignmentCodeText.trim().isEmpty ? '-' : meta.assignmentCodeText;

  if (bottomLeftLayout) {
    const double leftInset = 14;
    const double lineH = 14;
    const double pad = 2;
    final double bottomInset = bottomInsetOverride;
    final textBrush = sf.PdfSolidBrush(sf.PdfColor(32, 32, 32));

    final double infoBlockH = lineH;
    final double infoTop = size.height - bottomInset - infoBlockH;
    final infoBgRect = Rect.fromLTWH(
      leftInset - pad,
      infoTop - pad,
      260 + pad * 2,
      infoBlockH + pad * 2,
    );
    g.drawRectangle(
      brush: sf.PdfSolidBrush(sf.PdfColor(255, 255, 255)),
      bounds: infoBgRect,
    );
    final leftFormat = sf.PdfStringFormat(
      alignment: sf.PdfTextAlignment.left,
      lineAlignment: sf.PdfVerticalAlignment.top,
    );
    g.drawString(
      singleLineText,
      line1Font,
      brush: textBrush,
      bounds: Rect.fromLTWH(leftInset, infoTop, 260, lineH),
      format: leftFormat,
    );

    const double codeW = 120;
    final double codeTop = size.height - bottomInset - lineH;
    final double codeLeft = size.width - 14 - codeW;
    final codeBgRect = Rect.fromLTWH(
      codeLeft - pad,
      codeTop - pad,
      codeW + pad * 2,
      lineH + pad * 2,
    );
    g.drawRectangle(
      brush: sf.PdfSolidBrush(sf.PdfColor(255, 255, 255)),
      bounds: codeBgRect,
    );
    final rightFormat = sf.PdfStringFormat(
      alignment: sf.PdfTextAlignment.right,
      lineAlignment: sf.PdfVerticalAlignment.top,
    );
    g.drawString(
      assignmentCodeText,
      assignmentCodeFont,
      brush: textBrush,
      bounds: Rect.fromLTWH(codeLeft, codeTop, codeW, lineH),
      format: rightFormat,
    );
    return;
  }

  const double rightInset = 14;
  final double topInset = topInsetOverride;
  const double lineH = 18;
  final double boxWidth = math.max(180, size.width * 0.68);
  final double left = math.max(0, size.width - boxWidth - rightInset);
  final format = sf.PdfStringFormat(
    alignment: sf.PdfTextAlignment.right,
    lineAlignment: sf.PdfVerticalAlignment.top,
  );
  final textBrush = sf.PdfSolidBrush(sf.PdfColor(32, 32, 32));
  g.drawString(
    singleLineText,
    line1Font,
    brush: textBrush,
    bounds: Rect.fromLTWH(left, topInset, boxWidth, lineH),
    format: format,
  );
  final double bottomInset = bottomInsetOverride;
  const double codeLineH = 18;
  final codeTop = math.max(0.0, size.height - bottomInset - codeLineH);
  final codeFormat = sf.PdfStringFormat(
    alignment: sf.PdfTextAlignment.right,
    lineAlignment: sf.PdfVerticalAlignment.bottom,
  );
  g.drawString(
    assignmentCodeText,
    assignmentCodeFont,
    brush: textBrush,
    bounds: Rect.fromLTWH(left, codeTop, boxWidth, codeLineH),
    format: codeFormat,
  );
}

bool _isWebUrl(String raw) {
  final lower = raw.trim().toLowerCase();
  return lower.startsWith('http://') || lower.startsWith('https://');
}

String _textbookStorageKeyFromRaw(String rawPath) {
  final trimmed = rawPath.trim();
  if (trimmed.isEmpty || _isWebUrl(trimmed)) return '';
  final withoutScheme = trimmed.toLowerCase().startsWith('storage://textbook/')
      ? trimmed.substring('storage://textbook/'.length)
      : trimmed;
  final key = withoutScheme.split('?').first.trim();
  if (!RegExp(r'^academies/.+\.pdf$', caseSensitive: false).hasMatch(key)) {
    return '';
  }
  return key;
}

String _toLocalFilePath(String rawPath) {
  final trimmed = rawPath.trim();
  if (trimmed.isEmpty || _isWebUrl(trimmed)) return '';
  if (_textbookStorageKeyFromRaw(trimmed).isNotEmpty) return '';
  if (trimmed.toLowerCase().startsWith('file://')) {
    try {
      return Uri.parse(trimmed).toFilePath(windows: Platform.isWindows);
    } catch (_) {
      return '';
    }
  }
  return trimmed;
}

void _showHomeworkChipSnackBar(BuildContext context, String message) {
  if (!context.mounted) return;
  showAppSnackBar(context, message);
}

Future<Map<String, HomeworkAssignmentDetail>>
    _loadActiveAssignmentByItemIdForPrint(
  String studentId,
) async {
  try {
    final rows =
        await HomeworkAssignmentStore.instance.loadActiveAssignments(studentId);
    final out = <String, HomeworkAssignmentDetail>{};
    for (final row in rows) {
      final itemId = row.homeworkItemId.trim();
      if (itemId.isEmpty || out.containsKey(itemId)) continue;
      out[itemId] = row;
    }
    return out;
  } catch (_) {
    return const <String, HomeworkAssignmentDetail>{};
  }
}

/// 인쇄 파이프라인이 오류 없이 끝난 뒤, 실제로 인쇄 대상이 된 과제의 유형을 `프린트`로 맞춘다.
void _applyHomeworkTypePrintAfterSuccessfulPrint({
  required String studentId,
  required Iterable<String> itemIds,
}) {
  const printType = '프린트';
  const testType = '테스트';
  for (final id in itemIds) {
    final latest = HomeworkStore.instance.getById(studentId, id);
    if (latest == null) continue;
    if ((latest.type ?? '').trim() == testType) continue;
    if ((latest.type ?? '').trim() == printType) continue;
    latest.type = printType;
    HomeworkStore.instance.edit(studentId, latest);
  }
}

List<HomeworkSplitPartInput> _parseSplitPartInputsFromRaw({
  required HomeworkItem source,
  required String raw,
}) {
  final out = <HomeworkSplitPartInput>[];
  final lines = raw
      .split(RegExp(r'[;\n]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList(growable: false);
  int index = 1;
  for (final line in lines) {
    final parts = line.split('|');
    final page = parts.first.trim();
    if (page.isEmpty) continue;
    final count = parts.length >= 2 ? int.tryParse(parts[1].trim()) : null;
    final customTitle = parts.length >= 3 ? parts[2].trim() : '';
    out.add(
      HomeworkSplitPartInput(
        title: customTitle.isEmpty ? '${source.title} ${index++}' : customTitle,
        page: page,
        count: count,
        type: source.type,
        memo: source.memo,
        content: source.content,
      ),
    );
  }
  return out;
}

Future<void> _showHomeworkGroupSplitDialog({
  required BuildContext context,
  required String studentId,
  required HomeworkGroup group,
}) async {
  final waitingItems = HomeworkStore.instance
      .itemsInGroup(studentId, group.id)
      .where((e) =>
          e.status != HomeworkStatus.completed &&
          e.phase == 1 &&
          e.completedAt == null)
      .toList();
  if (waitingItems.isEmpty) {
    _showHomeworkChipSnackBar(context, '분할 가능한 대기 과제가 없습니다.');
    return;
  }

  String selectedItemId = waitingItems.first.id;
  final splitSpecController = ImeAwareTextEditingController();
  final submitted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (dialogContext, setLocalState) {
          return AlertDialog(
            backgroundColor: kDlgBg,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text(
              '그룹 과제 분할',
              style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
            ),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const YggDialogSectionHeader(
                    icon: Icons.call_split_rounded,
                    title: '분할 대상 선택',
                  ),
                  DropdownButtonFormField<String>(
                    value: selectedItemId,
                    dropdownColor: kDlgBg,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: kDlgFieldBg,
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: kDlgBorder),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide:
                            const BorderSide(color: kDlgAccent, width: 1.4),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    items: waitingItems
                        .map(
                          (item) => DropdownMenuItem<String>(
                            value: item.id,
                            child: Text(
                              item.title.trim().isEmpty
                                  ? '(제목 없음)'
                                  : item.title,
                              style: const TextStyle(color: kDlgText),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (value) {
                      if (value == null) return;
                      setLocalState(() => selectedItemId = value);
                    },
                  ),
                  const SizedBox(height: 12),
                  const YggDialogSectionHeader(
                    icon: Icons.edit_note_rounded,
                    title: '분할 정의',
                  ),
                  const Text(
                    '한 줄(또는 ;)마다 `페이지|문항수|제목` 형식으로 입력하세요.\n예) 10-12|12|1세트',
                    style: TextStyle(color: kDlgTextSub, fontSize: 12.5),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: splitSpecController,
                    minLines: 3,
                    maxLines: 8,
                    style: const TextStyle(color: kDlgText),
                    decoration: InputDecoration(
                      hintText: '10-12|12|A세트; 13-15|10|B세트',
                      hintStyle: const TextStyle(color: Color(0xFF6E7E7E)),
                      filled: true,
                      fillColor: kDlgFieldBg,
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: const BorderSide(color: kDlgBorder),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide:
                            const BorderSide(color: kDlgAccent, width: 1.4),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
                child: const Text('분할 실행'),
              ),
            ],
          );
        },
      );
    },
  );
  if (submitted != true || !context.mounted) return;

  final source = waitingItems.firstWhere(
    (item) => item.id == selectedItemId,
    orElse: () => waitingItems.first,
  );
  final parts = _parseSplitPartInputsFromRaw(
    source: source,
    raw: splitSpecController.text,
  );
  if (parts.length < 2) {
    _showHomeworkChipSnackBar(context, '분할 정의는 2개 이상 필요합니다.');
    return;
  }

  try {
    final created = await HomeworkStore.instance.splitWaitingItemInGroup(
      studentId: studentId,
      groupId: group.id,
      sourceItemId: source.id,
      parts: parts,
    );
    if (!context.mounted) return;
    _showHomeworkChipSnackBar(
      context,
      created.isEmpty ? '분할 결과를 확인하지 못했습니다.' : '분할 완료: ${created.length}개 생성',
    );
  } catch (e) {
    if (!context.mounted) return;
    _showHomeworkChipSnackBar(context, '분할 실패: ${e.toString()}');
  }
}

Future<void> _showHomeworkGroupActionDialog({
  required BuildContext context,
  required String studentId,
  required HomeworkGroup group,
}) async {
  final children = HomeworkStore.instance
      .itemsInGroup(studentId, group.id)
      .where((e) => e.status != HomeworkStatus.completed)
      .toList(growable: false);
  final waitingCount =
      children.where((e) => e.phase == 1 && e.completedAt == null).length;
  final runningCount = children.where((e) => e.phase == 2).length;
  final submittedCount = children.where((e) => e.phase == 3).length;
  final confirmedCount = children.where((e) => e.phase == 4).length;
  final hasTestChild = children.any(_isTestHomeworkItem);

  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        backgroundColor: kDlgBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          group.title.trim().isEmpty ? '그룹 과제' : group.title,
          style: const TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
        ),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const YggDialogSectionHeader(
                icon: Icons.folder_open_rounded,
                title: '그룹 상태',
              ),
              Text(
                '총 ${children.length}개 · 대기 $waitingCount · 수행 $runningCount · 제출 $submittedCount · 확인 $confirmedCount',
                style: const TextStyle(color: kDlgTextSub, fontSize: 13.5),
              ),
              const SizedBox(height: 12),
              const Text(
                '그룹 카드는 좌우 슬라이드로 상태를 일괄 전환할 수 있습니다.',
                style: TextStyle(color: Color(0xFF9FE3C6), fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
            child: const Text('닫기'),
          ),
          OutlinedButton.icon(
            onPressed: waitingCount >= 1
                ? () {
                    Navigator.of(dialogContext).pop();
                    unawaited(
                      _showHomeworkGroupSplitDialog(
                        context: context,
                        studentId: studentId,
                        group: group,
                      ),
                    );
                  }
                : null,
            icon: const Icon(Icons.call_split_rounded, size: 16),
            label: const Text('분할'),
          ),
          FilledButton.icon(
            onPressed: children.isEmpty
                ? null
                : () {
                    Navigator.of(dialogContext).pop();
                    unawaited(() async {
                      final int? fromPhase = runningCount > 0
                          ? 2
                          : (confirmedCount > 0
                              ? 4
                              : (waitingCount > 0 ? 1 : null));
                      if (fromPhase == 1 &&
                          hasTestChild &&
                          !HomeworkStore.instance
                              .isStudentInClassTime(studentId)) {
                        if (!context.mounted) return;
                        _showHomeworkChipSnackBar(
                          context,
                          '테스트 카드는 수업시간에만 수행할 수 있어요.',
                        );
                        return;
                      }
                      final changed =
                          await HomeworkStore.instance.bulkTransitionGroup(
                        studentId,
                        group.id,
                        fromPhase: fromPhase,
                      );
                      if (!context.mounted) return;
                      _showHomeworkChipSnackBar(
                        context,
                        changed > 0
                            ? '그룹 과제 $changed개 상태를 전환했어요.'
                            : '전환 가능한 과제가 없습니다.',
                      );
                    }());
                  },
            icon: const Icon(Icons.swap_horiz_rounded, size: 16),
            label: const Text('일괄 전환'),
            style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
          ),
        ],
      );
    },
  );
}

Future<void> _showHomeworkGroupSlideCancelDialog({
  required BuildContext context,
  required String studentId,
  required List<HomeworkItem> children,
}) async {
  if (children.isEmpty) return;
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kDlgBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        '과제 취소',
        style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
      ),
      content: const SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            YggDialogSectionHeader(
              icon: Icons.cancel_outlined,
              title: '처리 방식',
            ),
            Text(
              '완전 취소 또는 포기를 선택하세요.',
              style: TextStyle(color: kDlgTextSub),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(null),
          style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
          child: const Text('닫기'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.of(ctx).pop('remove'),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFE57373),
            side: const BorderSide(color: Color(0xFFE57373)),
          ),
          child: const Text('카드 삭제'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop('abandon'),
          style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
          child: const Text('포기'),
        ),
      ],
    ),
  );
  if (!context.mounted || choice == null) return;
  if (choice == 'remove') {
    for (final child in children) {
      HomeworkStore.instance.remove(studentId, child.id);
    }
    if (!context.mounted) return;
    _showHomeworkChipSnackBar(context, '그룹 과제 ${children.length}개를 삭제했어요.');
    return;
  }
  if (choice == 'abandon') {
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = ImeAwareTextEditingController();
        return AlertDialog(
          backgroundColor: kDlgBg,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text(
            '포기 사유',
            style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const YggDialogSectionHeader(
                  icon: Icons.edit_note,
                  title: '사유 입력',
                ),
                TextField(
                  controller: controller,
                  minLines: 2,
                  maxLines: 4,
                  style: const TextStyle(color: kDlgText),
                  decoration: InputDecoration(
                    hintText: '포기 사유를 입력하세요.',
                    hintStyle: const TextStyle(color: Color(0xFF6E7E7E)),
                    filled: true,
                    fillColor: kDlgFieldBg,
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: kDlgBorder),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide:
                          const BorderSide(color: kDlgAccent, width: 1.4),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
              child: const Text('저장'),
            ),
          ],
        );
      },
    );
    if (!context.mounted) return;
    if (reason != null && reason.trim().isNotEmpty) {
      for (final child in children) {
        unawaited(HomeworkStore.instance.abandon(studentId, child.id, reason));
      }
      _showHomeworkChipSnackBar(
          context, '그룹 과제 ${children.length}개를 포기 처리했어요.');
    }
  }
}

bool _hasDirectHomeworkTextbookLink(HomeworkItem hw) {
  final bookId = (hw.bookId ?? '').trim();
  final gradeLabel = (hw.gradeLabel ?? '').trim();
  return bookId.isNotEmpty && gradeLabel.isNotEmpty;
}

bool _isMigratedHomeworkForProgress(HomeworkItem hw) {
  if ((hw.pbPresetId ?? '').trim().isNotEmpty) return true;
  return _hasDirectHomeworkTextbookLink(hw);
}

HomeworkGradingProgressRate _aggregateHomeworkProgressRates(
  Iterable<HomeworkItem> items,
  Map<String, HomeworkGradingProgressRate> ratesByItem,
) {
  var aggregated = HomeworkGradingProgressRate.disabled;
  for (final item in items) {
    final rate = ratesByItem[item.id];
    if (rate != null) {
      aggregated = aggregated.merge(rate);
      continue;
    }
    if (_isMigratedHomeworkForProgress(item)) {
      aggregated = aggregated.merge(
        HomeworkGradingProgressRate.emptyEnabled(
          total: math.max(0, item.count ?? 0),
        ),
      );
    }
  }
  return aggregated;
}

Future<Map<String, HomeworkGradingProgressRate>>
    _loadHomeworkProgressRatesForStudent(String studentId) async {
  final items = HomeworkStore.instance
      .items(studentId)
      .where((item) => item.status != HomeworkStatus.completed)
      .toList(growable: false);
  if (items.isEmpty) return const <String, HomeworkGradingProgressRate>{};
  final enabledIds = <String>{};
  final fallbackTotals = <String, int>{};
  for (final item in items) {
    final total = math.max(0, item.count ?? 0);
    fallbackTotals[item.id] = total;
    if (_isMigratedHomeworkForProgress(item)) {
      enabledIds.add(item.id);
    }
  }
  return HomeworkTestGradingResultService.instance
      .loadLatestProgressRatesForItems(
    items.map((item) => item.id),
    fallbackTotalByItemId: fallbackTotals,
    enabledItemIds: enabledIds,
  );
}

String _normalizePageRangeForPrint(String raw) {
  final cleaned = raw.trim();
  if (cleaned.isEmpty) return '';
  var normalized = cleaned
      .replaceAll(RegExp(r'p\.', caseSensitive: false), '')
      .replaceAll('페이지', '')
      .replaceAll('쪽', '')
      .replaceAll('~', '-')
      .replaceAll('–', '-')
      .replaceAll('—', '-');
  normalized = normalized.replaceAll(RegExp(r'[^0-9,\-]+'), ',');
  normalized = normalized.replaceAll(RegExp(r',+'), ',');
  normalized = normalized.replaceAll(RegExp(r'^,+|,+$'), '');
  return normalized;
}

Future<String> _homeworkPrintStoredPageRange(HomeworkItem hw) async {
  return homeworkItemPageRangeText(
    page: hw.page,
    unitMappings: hw.unitMappings,
  );
}

Future<Map<String, String>> _homeworkPrintPageRangeByChildId(
  List<HomeworkItem> items,
) async {
  final out = <String, String>{};
  for (final item in items) {
    out[item.id] = await _homeworkPrintStoredPageRange(item);
  }
  return out;
}

String _mergeHomePrintPageRanges(Iterable<String?> ranges) {
  return mergeHomeworkPageRawStrings(ranges);
}

List<int> _parsePageRange(String input, int pageCount) {
  final cleaned = input.trim();
  if (cleaned.isEmpty) {
    return List<int>.generate(pageCount, (i) => i);
  }
  final normalized = cleaned
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll('~', '-')
      .replaceAll('–', '-')
      .replaceAll('—', '-');
  final tokens = normalized.split(',');
  final seen = <int>{};
  final out = <int>[];
  for (final raw in tokens) {
    if (raw.isEmpty) continue;
    if (raw.contains('-')) {
      final parts = raw.split('-');
      if (parts.length != 2) continue;
      final start = int.tryParse(parts[0]);
      final end = int.tryParse(parts[1]);
      if (start == null || end == null) continue;
      var a = start;
      var b = end;
      if (a > b) {
        final tmp = a;
        a = b;
        b = tmp;
      }
      a = a.clamp(1, pageCount);
      b = b.clamp(1, pageCount);
      for (int i = a; i <= b; i++) {
        final idx = i - 1;
        if (seen.add(idx)) out.add(idx);
      }
    } else {
      final v = int.tryParse(raw);
      if (v == null) continue;
      if (v < 1 || v > pageCount) continue;
      final idx = v - 1;
      if (seen.add(idx)) out.add(idx);
    }
  }
  return out;
}

/// 표준 용지의 포트레잇 포인트 크기(1pt = 1/72 inch).
/// 한국/일본 프린터가 인식하는 JIS B4/B5 치수를 사용한다.
/// XELATEX의 `b4paper`는 ISO B4(250×353mm=709×1001pt)로 나오는데,
/// 프린터는 JIS B4(257×364mm=729×1032pt)를 기대하므로 여기서 규격을 맞춰준다.
Size? _standardPaperPointSize(String raw) {
  final normalized =
      raw.trim().toUpperCase().replaceAll(RegExp(r'[\s\-_]+'), '');
  if (normalized.isEmpty) return null;
  switch (normalized) {
    case 'A3':
      return const Size(842, 1191);
    case 'A4':
      return const Size(595, 842);
    case 'A5':
      return const Size(420, 595);
    case 'B4':
    case 'B4JIS':
    case 'JISB4':
      return const Size(729, 1032);
    case 'B5':
    case 'B5JIS':
    case 'JISB5':
      return const Size(516, 729);
    case 'ISOB4':
      return const Size(709, 1001);
    case 'ISOB5':
      return const Size(499, 709);
    case 'LETTER':
    case 'NORTHAMERICALETTER':
      return const Size(612, 792);
    case 'LEGAL':
    case 'NORTHAMERICALEGAL':
      return const Size(612, 1008);
    default:
      return null;
  }
}

/// src의 방향(가로/세로)에 맞춰 target을 회전한다.
Size _orientPaperToSource(Size target, Size src) {
  if (target.width <= 0 || target.height <= 0) return src;
  final srcLandscape = src.width > src.height;
  if (srcLandscape) return Size(target.height, target.width);
  return target;
}

/// src 치수가 비표준(ISO B4 등)일 때 프린터 인식 가능한 JIS 표준 치수로 추정한다.
/// 일치하는 표준이 없으면 null.
Size? _guessStandardFromSrcSize(Size src) {
  final w = src.width;
  final h = src.height;
  final short = w < h ? w : h;
  final long = w < h ? h : w;
  bool near(double a, double b, {double tol = 12}) => (a - b).abs() <= tol;
  // ISO B4 (250×353mm = 709×1001pt) → JIS B4
  if (near(short, 709) && near(long, 1001)) return const Size(729, 1032);
  // ISO B5 (176×250mm = 499×709pt) → JIS B5
  if (near(short, 499) && near(long, 709)) return const Size(516, 729);
  return null;
}

String _paperSizeLabelFromPdfSize(Size src) {
  final w = src.width;
  final h = src.height;
  final short = w < h ? w : h;
  final long = w < h ? h : w;
  bool near(double a, double b, {double tol = 14}) => (a - b).abs() <= tol;
  if (near(short, 842) && near(long, 1191)) return 'A3';
  if (near(short, 595) && near(long, 842)) return 'A4';
  if (near(short, 420) && near(long, 595)) return 'A5';
  if ((near(short, 729) && near(long, 1032)) ||
      (near(short, 709) && near(long, 1001))) {
    return 'B4';
  }
  if ((near(short, 516) && near(long, 729)) ||
      (near(short, 499) && near(long, 709))) {
    return 'B5';
  }
  if (near(short, 612) && near(long, 792)) return 'Letter';
  if (near(short, 612) && near(long, 1008)) return 'Legal';
  return '';
}

Future<String> _inferPreferredPaperSizeFromPdf({
  required String inputPath,
  required String pageRange,
}) async {
  final inPath = inputPath.trim();
  if (inPath.isEmpty || !inPath.toLowerCase().endsWith('.pdf')) return '';
  try {
    final srcBytes = await File(inPath).readAsBytes();
    final src = sf.PdfDocument(inputBytes: srcBytes);
    try {
      final pageCount = src.pages.count;
      if (pageCount <= 0) return '';
      final indices = _parsePageRange(pageRange, pageCount);
      final effectiveIndices = indices.isEmpty
          ? List<int>.generate(pageCount, (index) => index)
          : indices;
      String firstRecognized = '';
      for (final i in effectiveIndices.take(24)) {
        if (i < 0 || i >= pageCount) continue;
        final label = _paperSizeLabelFromPdfSize(src.pages[i].size);
        if (label.isEmpty) continue;
        firstRecognized = firstRecognized.isEmpty ? label : firstRecognized;
        if (label != 'A4') return label;
      }
      return firstRecognized;
    } finally {
      src.dispose();
    }
  } catch (_) {
    return '';
  }
}

Future<String?> _buildPdfForPrintRange({
  required String inputPath,
  required String pageRange,
  _HomeworkPrintOverlayMeta? overlayMeta,
  String preferredPaperSize = '',
}) async {
  final inPath = inputPath.trim();
  if (inPath.isEmpty || !inPath.toLowerCase().endsWith('.pdf')) return null;
  final srcBytes = await File(inPath).readAsBytes();
  final src = sf.PdfDocument(inputBytes: srcBytes);
  final dst = sf.PdfDocument();
  try {
    try {
      dst.pageSettings.margins.all = 0;
    } catch (_) {}
    final pageCount = src.pages.count;
    final indices = _parsePageRange(pageRange, pageCount);
    if (indices.isEmpty) return null;
    final standardPortrait = _standardPaperPointSize(preferredPaperSize);
    // preferredPaperSize가 명시적으로 없어도, 첫 페이지 크기가 ISO B4 등 비표준이면
    // 자동으로 JIS 표준으로 정규화하도록 sneak peek.
    Size? firstAutoStandard;
    if (standardPortrait == null && pageCount > 0) {
      try {
        firstAutoStandard = _guessStandardFromSrcSize(src.pages[0].size);
      } catch (_) {
        firstAutoStandard = null;
      }
    }
    final bool needsResize =
        standardPortrait != null || firstAutoStandard != null;
    print(
        '[PRINT][buildPdf] preferredPaper="$preferredPaperSize" standard=${standardPortrait == null ? "(none)" : "${standardPortrait.width}x${standardPortrait.height}"} autoGuess=${firstAutoStandard == null ? "(none)" : "${firstAutoStandard.width}x${firstAutoStandard.height}"}');
    const double kOverlayPrintFontPt = 10.2;
    sf.PdfFont? overlayPdfFont = overlayMeta == null
        ? null
        : await _loadHomeworkPrintOverlayFont(kOverlayPrintFontPt, bold: false);
    // 표준 용지 치수로 강제 정규화가 필요한 경우(B4 등) 짧은 경로를 생략하고
    // 아래 리렌더 루프로 내려가 페이지 크기를 JIS 표준으로 맞춘다.
    if (overlayMeta != null &&
        pageRange.trim().isEmpty &&
        pageCount > 0 &&
        overlayPdfFont != null &&
        !needsResize) {
      // 외부 생성 PDF는 page.graphics 수정이 기존 콘텐츠 아래에 깔린다.
      // round-trip 정규화 후 페이지 레이어를 추가해 콘텐츠 위에 오버레이를 그린다.
      final normalizedBytes = await src.save();
      final normalizedDoc = sf.PdfDocument(
        inputBytes: Uint8List.fromList(normalizedBytes),
      );
      try {
        final overlayFont = await _loadHomeworkPrintOverlayFont(
          kOverlayPrintFontPt,
          bold: false,
        );
        final firstPage = normalizedDoc.pages[0];
        final layer = firstPage.layers.add(name: 'hw_overlay');
        _drawHomeworkPrintOverlayOnFirstPage(
          page: firstPage,
          meta: overlayMeta,
          line1Font: overlayFont,
          line2Font: overlayFont,
          assignmentCodeFont: overlayFont,
          bottomInsetOverride: 25,
          graphicsOverride: layer.graphics,
          bottomLeftLayout: true,
        );
        final outBytes = await normalizedDoc.save();
        print(
            '[OVERLAY] layer: ${outBytes.length} bytes (normalized=${normalizedBytes.length})');
        final dir = await getTemporaryDirectory();
        print('[OVERLAY] temp dir: ${dir.path}');
        final outPath = p.join(
          dir.path,
          '${_homeworkPrintTempPrefix}${DateTime.now().millisecondsSinceEpoch}.pdf',
        );
        await File(outPath).writeAsBytes(outBytes, flush: true);
        return outPath;
      } finally {
        normalizedDoc.dispose();
      }
    }
    // pageRange가 비었고 표준 용지 정규화가 필요한 경우, 전체 페이지를 대상으로 한다.
    final effectiveIndices = (indices.isEmpty && pageRange.trim().isEmpty)
        ? List<int>.generate(pageCount, (i) => i)
        : indices;
    for (int outIndex = 0; outIndex < effectiveIndices.length; outIndex++) {
      final i = effectiveIndices[outIndex];
      if (i < 0 || i >= pageCount) continue;
      final srcPage = src.pages[i];
      final srcSize = srcPage.size;
      // 우선순위: preferredPaperSize에서 직접 해석 > src 치수 기반 자동 추정 > 원본 유지
      Size? effectiveStandardPortrait = standardPortrait;
      if (effectiveStandardPortrait == null) {
        effectiveStandardPortrait = _guessStandardFromSrcSize(srcSize);
        if (effectiveStandardPortrait != null && outIndex == 0) {
          print(
              '[PRINT][buildPdf] auto-normalized src=${srcSize.width}x${srcSize.height} -> ${effectiveStandardPortrait.width}x${effectiveStandardPortrait.height}');
        }
      }
      final targetSize = effectiveStandardPortrait != null
          ? _orientPaperToSource(effectiveStandardPortrait, srcSize)
          : srcSize;
      try {
        dst.pageSettings.size = targetSize;
        dst.pageSettings.margins.all = 0;
      } catch (_) {}
      final tmpl = srcPage.createTemplate();
      final newPage = dst.pages.add();
      final tw = targetSize.width;
      final th = targetSize.height;
      final sw = srcSize.width;
      final sh = srcSize.height;
      if (tw <= 0 || th <= 0 || sw <= 0 || sh <= 0) {
        try {
          newPage.graphics.drawPdfTemplate(tmpl, const Offset(0, 0));
        } catch (_) {
          newPage.graphics.drawPdfTemplate(tmpl, const Offset(0, 0));
        }
        if (outIndex == 0 && overlayMeta != null && overlayPdfFont != null) {
          _drawHomeworkPrintOverlayOnFirstPage(
            page: newPage,
            meta: overlayMeta,
            line1Font: overlayPdfFont,
            line2Font: overlayPdfFont,
            assignmentCodeFont: overlayPdfFont,
          );
        }
        continue;
      }
      // 왜곡 채움(stretch): 가로/세로를 독립 스케일로 늘려 페이지를 꽉 채운다.
      try {
        newPage.graphics
            .drawPdfTemplate(tmpl, const Offset(0, 0), Size(tw, th));
      } catch (_) {
        newPage.graphics.drawPdfTemplate(tmpl, const Offset(0, 0));
      }
      if (outIndex == 0 && overlayMeta != null && overlayPdfFont != null) {
        _drawHomeworkPrintOverlayOnFirstPage(
          page: newPage,
          meta: overlayMeta,
          line1Font: overlayPdfFont,
          line2Font: overlayPdfFont,
          assignmentCodeFont: overlayPdfFont,
        );
      }
    }
    final outBytes = await dst.save();
    final dir = await getTemporaryDirectory();
    final outPath = p.join(
      dir.path,
      '${_homeworkPrintTempPrefix}${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
    await File(outPath).writeAsBytes(outBytes, flush: true);
    return outPath;
  } finally {
    src.dispose();
    dst.dispose();
  }
}

void _scheduleTempDelete(String path) {
  Future<void>.delayed(const Duration(minutes: 10), () async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  });
}

Future<bool> _openPrintDialogForPath(
  String path, {
  String preferredPaperSize = '',
  PrintDuplexMode duplexMode = PrintDuplexMode.systemDefault,
  bool skipRawTcpFirst = false,
}) {
  return PrintRoutingService.instance.printFile(
    path: path,
    channel: PrintRoutingChannel.general,
    duplexMode: duplexMode,
    preferredPaperSize: preferredPaperSize,
    debugSource: 'class_content.waiting_chip',
    skipRawTcpFirst: skipRawTcpFirst,
  );
}

Future<_ResolvedHomeworkPdfLinks> _resolveHomeworkPdfLinks(
  HomeworkItem hw, {
  bool allowFlowFallback = false,
}) async {
  String bookId = (hw.bookId ?? '').trim();
  String gradeLabel = (hw.gradeLabel ?? '').trim();
  final flowId = (hw.flowId ?? '').trim();

  if (allowFlowFallback &&
      (bookId.isEmpty || gradeLabel.isEmpty) &&
      flowId.isNotEmpty) {
    try {
      final rows = await DataManager.instance.loadFlowTextbookLinks(flowId);
      if (rows.isNotEmpty) {
        Map<String, dynamic>? matched;
        for (final row in rows) {
          final rowBookId = '${row['book_id'] ?? ''}'.trim();
          final rowGrade = '${row['grade_label'] ?? ''}'.trim();
          final bool bookMatches = bookId.isNotEmpty && rowBookId == bookId;
          final bool gradeMatches =
              gradeLabel.isNotEmpty && rowGrade == gradeLabel;
          if (bookMatches || gradeMatches) {
            matched = row;
            break;
          }
        }
        final selected = matched ?? rows.first;
        if (bookId.isEmpty) {
          bookId = '${selected['book_id'] ?? ''}'.trim();
        }
        if (gradeLabel.isEmpty) {
          gradeLabel = '${selected['grade_label'] ?? ''}'.trim();
        }
      }
    } catch (_) {}
  }

  if (bookId.isEmpty || gradeLabel.isEmpty) {
    return const _ResolvedHomeworkPdfLinks(
      bookId: '',
      gradeLabel: '',
      bodyPathRaw: '',
      answerPathRaw: '',
      solutionPathRaw: '',
    );
  }

  try {
    final links = await DataManager.instance.loadResourceFileLinks(bookId);
    return _ResolvedHomeworkPdfLinks(
      bookId: bookId,
      gradeLabel: gradeLabel,
      bodyPathRaw: (links['$gradeLabel#body'] ?? '').trim(),
      answerPathRaw: (links['$gradeLabel#ans'] ?? '').trim(),
      solutionPathRaw: (links['$gradeLabel#sol'] ?? '').trim(),
    );
  } catch (_) {
    return _ResolvedHomeworkPdfLinks(
      bookId: bookId,
      gradeLabel: gradeLabel,
      bodyPathRaw: '',
      answerPathRaw: '',
      solutionPathRaw: '',
    );
  }
}

String _preferredLiveReleaseExportJobIdForPrint({
  required LearningProblemLiveRelease release,
  bool preferFrozen = false,
}) {
  final active = release.activeExportJobId.trim();
  final frozen = release.frozenExportJobId.trim();
  if (preferFrozen) {
    if (frozen.isNotEmpty) return frozen;
    return active;
  }
  if (active.isNotEmpty) return active;
  return frozen;
}

const String _kPrintPipelinePb = 'pb';
const String _kPrintPipelineTextbook = 'textbook';
const String _kNaesinLinkConfigKeyForPrint = 'naesinLinkKey';

String _naesinLinkKeyForPrint(HomeworkItem hw) {
  final sourceLevel = (hw.sourceUnitLevel ?? '').trim().toLowerCase();
  if (sourceLevel != 'naesin') return '';
  return (hw.sourceUnitPath ?? '').trim();
}

bool _isPbPrintTarget({
  required HomeworkItem hw,
  HomeworkAssignmentDetail? assignment,
}) {
  final presetId = (hw.pbPresetId ?? '').trim();
  final liveReleaseId = (assignment?.liveReleaseId ?? '').trim();
  final exportJobId = (assignment?.releaseExportJobId ?? '').trim();
  return presetId.isNotEmpty ||
      liveReleaseId.isNotEmpty ||
      exportJobId.isNotEmpty ||
      _naesinLinkKeyForPrint(hw).isNotEmpty;
}

bool _canCreatePbPrintFromTarget({
  required HomeworkItem hw,
  HomeworkAssignmentDetail? assignment,
}) {
  return _isPbPrintTarget(hw: hw, assignment: assignment);
}

String _printPipelineKeyForHomework({
  required HomeworkItem hw,
  HomeworkAssignmentDetail? assignment,
}) {
  return _isPbPrintTarget(hw: hw, assignment: assignment)
      ? _kPrintPipelinePb
      : _kPrintPipelineTextbook;
}

Future<String> _resolveAcademyIdForPrint() async {
  var academyId =
      (await TenantService.instance.getActiveAcademyId() ?? '').trim();
  if (academyId.isEmpty) {
    academyId = (await TenantService.instance.ensureActiveAcademy()).trim();
  }
  return academyId;
}

Future<LearningProblemDocumentExportPreset?> _resolveNaesinPresetForPrint({
  required String academyId,
  required String linkKey,
  LearningProblemBankService? problemBankService,
}) async {
  final safeAcademyId = academyId.trim();
  final safeLinkKey = linkKey.trim();
  if (safeAcademyId.isEmpty || safeLinkKey.isEmpty) return null;
  final pbService = problemBankService ?? LearningProblemBankService();
  try {
    final presets = await pbService.listExportPresets(
      academyId: safeAcademyId,
      limit: 500,
    );
    for (final preset in presets) {
      final candidate =
          '${preset.renderConfig[_kNaesinLinkConfigKeyForPrint] ?? preset.naesinLinkKey}'
              .trim();
      if (NaesinExamContext.linkKeysEquivalentForNaesin(
        candidate,
        safeLinkKey,
      )) {
        return preset;
      }
    }
  } catch (_) {}
  return null;
}

String _normalizePaperSizeForPrint(String raw) {
  final normalized =
      raw.trim().toUpperCase().replaceAll(RegExp(r'[\s\-_]+'), '');
  switch (normalized) {
    case 'B4JIS':
    case 'JISB4':
    case 'B4':
      return 'B4';
    case 'B5JIS':
    case 'JISB5':
    case 'B5':
      return 'B5';
    case 'A3':
      return 'A3';
    case 'A4':
      return 'A4';
    case 'A5':
      return 'A5';
    case 'LETTER':
    case 'NORTHAMERICALETTER':
      return 'LETTER';
    case 'LEGAL':
    case 'NORTHAMERICALEGAL':
      return 'LEGAL';
    default:
      return normalized;
  }
}

bool _isPaperSizeCompatibleForPrint({
  required String expectedPaperSize,
  required String actualPaperSize,
}) {
  final expected = _normalizePaperSizeForPrint(expectedPaperSize);
  final actual = _normalizePaperSizeForPrint(actualPaperSize);
  if (expected.isEmpty || actual.isEmpty) return true;
  return expected == actual;
}

Future<_ResolvedHomeworkPrintSource?> _sourceFromPbExportJobForPrint({
  required String academyId,
  required String exportJobId,
  required String sourceKey,
  LearningProblemBankService? problemBankService,
  String preferredPaperSize = '',
}) async {
  final safeJobId = exportJobId.trim();
  if (academyId.trim().isEmpty || safeJobId.isEmpty) return null;
  final pbService = problemBankService ?? LearningProblemBankService();
  try {
    String resolvedPaperSize = preferredPaperSize.trim();
    // export_job에 기록된 paperSize를 우선 확보: 검증 + 빈 값일 때 폴백.
    try {
      final job = await pbService.getExportJob(
        academyId: academyId,
        jobId: safeJobId,
      );
      final actualPaperSize = (job?.paperSize ?? '').trim();
      if (resolvedPaperSize.isNotEmpty && actualPaperSize.isNotEmpty) {
        if (!_isPaperSizeCompatibleForPrint(
          expectedPaperSize: resolvedPaperSize,
          actualPaperSize: actualPaperSize,
        )) {
          return null;
        }
      } else if (resolvedPaperSize.isEmpty && actualPaperSize.isNotEmpty) {
        // 프리셋/라이브릴리즈에 저장되지 않았더라도 export_job.paper_size로 보완.
        resolvedPaperSize = actualPaperSize;
      }
    } catch (_) {}
    final signedUrl = await pbService.regenerateExportSignedUrl(
      academyId: academyId,
      exportJobId: safeJobId,
    );
    final safeSignedUrl = signedUrl.trim();
    if (safeSignedUrl.isEmpty) return null;
    return _ResolvedHomeworkPrintSource(
      pathRaw: safeSignedUrl,
      sourceKey: sourceKey,
      isProblemBank: true,
      preferredPaperSize: resolvedPaperSize,
    );
  } catch (_) {
    return null;
  }
}

List<String> _extractSelectedQuestionUidsFromPreset(
  LearningProblemDocumentExportPreset preset,
) {
  if (preset.selectedQuestionUids.isNotEmpty) {
    return preset.selectedQuestionUids
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  List<String> parse(dynamic raw) {
    if (raw is! List) return const <String>[];
    return raw
        .map((e) => '$e'.trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  final renderConfig = preset.renderConfig;
  final fromOrdered = parse(renderConfig['selectedQuestionUidsOrdered']);
  if (fromOrdered.isNotEmpty) return fromOrdered;
  final fromOrderedLegacy = parse(renderConfig['selectedQuestionIdsOrdered']);
  if (fromOrderedLegacy.isNotEmpty) return fromOrderedLegacy;
  final fromRaw = parse(renderConfig['selectedQuestionUids']);
  if (fromRaw.isNotEmpty) return fromRaw;
  return parse(renderConfig['selectedQuestionIds']);
}

bool _parseBoolLooseForPrint(
  dynamic raw, {
  required bool fallback,
}) {
  if (raw is bool) return raw;
  final text = '$raw'.trim().toLowerCase();
  if (text.isEmpty) return fallback;
  if (text == 'true' || text == '1' || text == 'yes' || text == 'y') {
    return true;
  }
  if (text == 'false' || text == '0' || text == 'no' || text == 'n') {
    return false;
  }
  return fallback;
}

Future<LearningProblemExportJob?> _waitPbExportCompleted({
  required String academyId,
  required LearningProblemExportJob initialJob,
  LearningProblemBankService? problemBankService,
  ValueNotifier<String>? progressText,
  int maxAttempts = 240,
}) async {
  final pbService = problemBankService ?? LearningProblemBankService();
  var current = initialJob;
  for (var attempt = 0; attempt < maxAttempts; attempt += 1) {
    if (current.isTerminal) return current;
    if (progressText != null) {
      progressText.value = '문제은행 PDF 생성 중입니다...';
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    LearningProblemExportJob? latest;
    try {
      latest = await pbService.getExportJob(
        academyId: academyId,
        jobId: current.id,
      );
    } catch (_) {
      latest = null;
    }
    if (latest == null) continue;
    current = latest;
    if (current.isTerminal) return current;
  }
  return current;
}

Future<LearningProblemExportJob?> _ensurePbExportJob({
  required HomeworkItem hw,
  HomeworkAssignmentDetail? assignment,
  String academyId = '',
  LearningProblemBankService? problemBankService,
  ValueNotifier<String>? progressText,
}) async {
  final pbService = problemBankService ?? LearningProblemBankService();
  final safeAcademyId = academyId.trim().isNotEmpty
      ? academyId.trim()
      : await _resolveAcademyIdForPrint();
  if (safeAcademyId.isEmpty) return null;

  String presetId = (hw.pbPresetId ?? '').trim();
  final liveReleaseId = (assignment?.liveReleaseId ?? '').trim();
  if (presetId.isEmpty && liveReleaseId.isNotEmpty) {
    try {
      final liveRelease = await pbService.getLiveReleaseById(
        academyId: safeAcademyId,
        liveReleaseId: liveReleaseId,
      );
      presetId = (liveRelease?.presetId ?? '').trim();
    } catch (_) {}
  }
  if (presetId.isEmpty) {
    final naesinPreset = await _resolveNaesinPresetForPrint(
      academyId: safeAcademyId,
      linkKey: _naesinLinkKeyForPrint(hw),
      problemBankService: pbService,
    );
    presetId = (naesinPreset?.id ?? '').trim();
  }
  if (presetId.isEmpty) return null;

  progressText?.value = '문제은행 프리셋 정보를 불러오는 중입니다...';
  final preset = await pbService.getExportPresetById(
    academyId: safeAcademyId,
    presetId: presetId,
  );
  if (preset == null) return null;

  final documentId = preset.sourceDocumentId.trim().isNotEmpty
      ? preset.sourceDocumentId.trim()
      : preset.documentId.trim();
  if (documentId.isEmpty) return null;
  final selectedQuestionUids = _extractSelectedQuestionUidsFromPreset(preset);
  if (selectedQuestionUids.isEmpty) return null;

  final renderConfig = preset.renderConfig;
  final templateProfile =
      preset.templateProfile.isNotEmpty ? preset.templateProfile : 'csat';
  final paperSize = preset.paperSize.isNotEmpty ? preset.paperSize : 'A4';
  final includeAnswerSheet = _parseBoolLooseForPrint(
    renderConfig['includeAnswerSheet'],
    fallback: false,
  );
  final includeExplanation = _parseBoolLooseForPrint(
    renderConfig['includeExplanation'],
    fallback: false,
  );
  final renderHash = '${renderConfig['renderHash'] ?? ''}'.trim();
  final options = <String, dynamic>{
    ...renderConfig,
    'includeAnswerSheet': includeAnswerSheet,
    'includeExplanation': includeExplanation,
    if (renderHash.isNotEmpty) 'renderHash': renderHash,
    'previewOnly': false,
  };

  if (renderHash.isNotEmpty) {
    try {
      final reusableJob = await pbService.findReusableCompletedExport(
        academyId: safeAcademyId,
        renderHash: renderHash,
        previewOnly: false,
      );
      if (reusableJob != null && reusableJob.id.trim().isNotEmpty) {
        progressText?.value = '기존 문제은행 PDF를 재사용합니다...';
        return reusableJob;
      }
    } catch (_) {}
  }

  progressText?.value = '문제은행 인쇄 PDF 생성을 요청하는 중입니다...';
  final queuedJob = await pbService.createExportJob(
    academyId: safeAcademyId,
    documentId: documentId,
    templateProfile: templateProfile,
    paperSize: paperSize,
    includeAnswerSheet: includeAnswerSheet,
    includeExplanation: includeExplanation,
    selectedQuestionUids: selectedQuestionUids,
    renderHash: renderHash,
    previewOnly: false,
    options: options,
  );
  final completedJob = await _waitPbExportCompleted(
    academyId: safeAcademyId,
    initialJob: queuedJob,
    problemBankService: pbService,
    progressText: progressText,
    maxAttempts: 24,
  );
  if (completedJob == null) return null;

  if (completedJob.status.trim() == 'completed' &&
      completedJob.id.trim().isNotEmpty) {
    final sourceDocumentIds = preset.sourceDocumentIds.isNotEmpty
        ? preset.sourceDocumentIds
        : <String>[documentId];
    try {
      await pbService.upsertLiveReleaseForPreset(
        academyId: safeAcademyId,
        presetId: presetId,
        sourceDocumentIds: sourceDocumentIds,
        templateProfile: templateProfile,
        paperSize: paperSize,
        activeExportJobId: completedJob.id.trim(),
        note: 'homework_print_auto_export',
      );
    } catch (_) {}
  }
  return completedJob;
}

Future<_ResolvedHomeworkPrintSource?> _resolvePbPrintSource(
  HomeworkItem hw, {
  HomeworkAssignmentDetail? assignment,
  LearningProblemBankService? problemBankService,
  String academyId = '',
  bool ensureExportJob = false,
  ValueNotifier<String>? progressText,
}) async {
  final pbService = problemBankService ?? LearningProblemBankService();
  final safeAcademyId = academyId.trim().isNotEmpty
      ? academyId.trim()
      : await _resolveAcademyIdForPrint();
  if (safeAcademyId.isEmpty) return null;

  String preferredPaperSize = '';
  String pbPresetId = (hw.pbPresetId ?? '').trim();
  LearningProblemLiveRelease? assignmentRelease;
  final liveReleaseId = (assignment?.liveReleaseId ?? '').trim();
  if (liveReleaseId.isNotEmpty) {
    try {
      assignmentRelease = await pbService.getLiveReleaseById(
        academyId: safeAcademyId,
        liveReleaseId: liveReleaseId,
      );
      preferredPaperSize = (assignmentRelease?.paperSize ?? '').trim();
      if (pbPresetId.isEmpty) {
        pbPresetId = (assignmentRelease?.presetId ?? '').trim();
      }
    } catch (_) {
      assignmentRelease = null;
    }
  }

  final lockedExportJobId = (assignment?.releaseExportJobId ?? '').trim();
  if (lockedExportJobId.isNotEmpty) {
    final resolved = await _sourceFromPbExportJobForPrint(
      academyId: safeAcademyId,
      exportJobId: lockedExportJobId,
      sourceKey: 'pb_export_job:$lockedExportJobId',
      problemBankService: pbService,
      preferredPaperSize: preferredPaperSize,
    );
    if (resolved != null) return resolved;
  }

  if (liveReleaseId.isNotEmpty) {
    if (assignmentRelease != null) {
      final preferFrozen =
          (assignment?.status ?? '').trim().toLowerCase() == 'completed';
      final exportJobId = _preferredLiveReleaseExportJobIdForPrint(
        release: assignmentRelease,
        preferFrozen: preferFrozen,
      );
      if (exportJobId.isNotEmpty) {
        final resolved = await _sourceFromPbExportJobForPrint(
          academyId: safeAcademyId,
          exportJobId: exportJobId,
          sourceKey: 'pb_export_job:$exportJobId',
          problemBankService: pbService,
          preferredPaperSize: preferredPaperSize,
        );
        if (resolved != null) return resolved;
      }
    }
  }

  final assignmentSignedUrl = (assignment?.liveReleaseSignedUrl ?? '').trim();
  if (assignmentSignedUrl.isNotEmpty && preferredPaperSize.isEmpty) {
    // signed URL 경로에서도 export_job.paperSize로 용지 크기 보완 시도.
    if (lockedExportJobId.isNotEmpty) {
      try {
        final job = await pbService.getExportJob(
          academyId: safeAcademyId,
          jobId: lockedExportJobId,
        );
        final actualPaperSize = (job?.paperSize ?? '').trim();
        if (actualPaperSize.isNotEmpty) {
          preferredPaperSize = actualPaperSize;
        }
      } catch (_) {}
    }
    return _ResolvedHomeworkPrintSource(
      pathRaw: assignmentSignedUrl,
      sourceKey: liveReleaseId.isNotEmpty
          ? 'pb_live_release:$liveReleaseId'
          : 'pb_assignment:${assignment?.id ?? hw.id}',
      isProblemBank: true,
      preferredPaperSize: preferredPaperSize,
    );
  }

  if (pbPresetId.isEmpty) {
    final naesinPreset = await _resolveNaesinPresetForPrint(
      academyId: safeAcademyId,
      linkKey: _naesinLinkKeyForPrint(hw),
      problemBankService: pbService,
    );
    pbPresetId = (naesinPreset?.id ?? '').trim();
    if (preferredPaperSize.isEmpty) {
      preferredPaperSize = (naesinPreset?.paperSize ?? '').trim();
    }
  }
  if (pbPresetId.isNotEmpty && preferredPaperSize.isEmpty) {
    try {
      final preset = await pbService.getExportPresetById(
        academyId: safeAcademyId,
        presetId: pbPresetId,
      );
      preferredPaperSize = (preset?.paperSize ?? '').trim();
    } catch (_) {}
  }
  if (pbPresetId.isNotEmpty) {
    print(
      '[PRINT][pb] preset="$pbPresetId" paper="$preferredPaperSize" '
      'naesinLink="${_naesinLinkKeyForPrint(hw)}" liveRelease="$liveReleaseId"',
    );
  }
  if (pbPresetId.isNotEmpty) {
    try {
      final latestRelease = await pbService.getLatestLiveReleaseForPreset(
        academyId: safeAcademyId,
        presetId: pbPresetId,
      );
      if (latestRelease != null) {
        if (preferredPaperSize.isEmpty) {
          preferredPaperSize = latestRelease.paperSize.trim();
        }
        final exportJobId = _preferredLiveReleaseExportJobIdForPrint(
          release: latestRelease,
          preferFrozen: false,
        );
        if (exportJobId.isNotEmpty) {
          final resolved = await _sourceFromPbExportJobForPrint(
            academyId: safeAcademyId,
            exportJobId: exportJobId,
            sourceKey: 'pb_export_job:$exportJobId',
            problemBankService: pbService,
            preferredPaperSize: preferredPaperSize,
          );
          if (resolved != null) return resolved;
        }
      }
    } catch (_) {}
  }

  if (!ensureExportJob) return null;

  final createdOrLatestJob = await _ensurePbExportJob(
    hw: hw,
    assignment: assignment,
    academyId: safeAcademyId,
    problemBankService: pbService,
    progressText: progressText,
  );
  if (createdOrLatestJob == null) return null;
  if (createdOrLatestJob.status.trim() != 'completed') return null;
  final exportJobId = createdOrLatestJob.id.trim();
  if (exportJobId.isEmpty) return null;
  if (preferredPaperSize.isEmpty && pbPresetId.isNotEmpty) {
    try {
      final preset = await pbService.getExportPresetById(
        academyId: safeAcademyId,
        presetId: pbPresetId,
      );
      preferredPaperSize = (preset?.paperSize ?? '').trim();
    } catch (_) {}
  }
  return _sourceFromPbExportJobForPrint(
    academyId: safeAcademyId,
    exportJobId: exportJobId,
    sourceKey: 'pb_export_job:$exportJobId',
    problemBankService: pbService,
    preferredPaperSize: preferredPaperSize,
  );
}

Future<_ResolvedHomeworkPrintSource> _resolveTextbookPrintSource(
  HomeworkItem hw, {
  bool allowFlowFallback = false,
}) async {
  final textbook = await _resolveHomeworkPdfLinks(
    hw,
    allowFlowFallback: allowFlowFallback,
  );
  final textbookRaw = textbook.bodyPathRaw.trim();
  final textbookKey =
      (textbook.bookId.isNotEmpty && textbook.gradeLabel.isNotEmpty)
          ? 'textbook:${textbook.bookId}|${textbook.gradeLabel}'
          : 'textbook_raw:$textbookRaw';
  return _ResolvedHomeworkPrintSource(
    pathRaw: textbookRaw,
    sourceKey: textbookKey,
    bookId: textbook.bookId,
    gradeLabel: textbook.gradeLabel,
    isProblemBank: false,
  );
}

TextbookPdfRef? _textbookPdfRefFromStoragePath(
  String rawPath, {
  required String kind,
}) {
  final key = _textbookStorageKeyFromRaw(rawPath);
  if (key.isEmpty) return null;
  final match = RegExp(
    r'^academies/([^/]+)/files/([^/]+)/(.+)/(body|ans|sol)\.pdf$',
    caseSensitive: false,
  ).firstMatch(key);
  // storage_key로 조회해야 함. 경로 segment(courseKey)와 DB grade(courseLabel)
  // 가 다른 고등 교재 등에서 tuple 조회만 하면 link_not_found가 난다.
  if (match == null) {
    return TextbookPdfRef(storageKey: key, kind: kind);
  }
  final fileKind = (match.group(4) ?? kind).toLowerCase();
  return TextbookPdfRef(
    academyId: match.group(1),
    fileId: match.group(2),
    gradeLabel: match.group(3),
    kind: fileKind,
    storageKey: key,
  );
}

Future<TextbookPdfRef?> _textbookPdfRefFromPrintSource(
  _ResolvedHomeworkPrintSource source, {
  required String kind,
}) async {
  final fromStoragePath = _textbookPdfRefFromStoragePath(
    source.pathRaw,
    kind: kind,
  );
  if (fromStoragePath != null) return fromStoragePath;

  final bookId = source.bookId.trim();
  final gradeLabel = source.gradeLabel.trim();
  if (bookId.isEmpty || gradeLabel.isEmpty) return null;
  final academyId = await _resolveAcademyIdForPrint();
  if (academyId.trim().isEmpty) return null;

  // gradeLabel(표시명)과 경로/DB composite가 다를 수 있어 storage_key를 먼저 조회.
  try {
    final rows = await Supabase.instance.client
        .from('resource_file_links')
        .select('storage_key,grade,migration_status')
        .match({'academy_id': academyId.trim(), 'file_id': bookId});
    final safeKind = kind.trim().toLowerCase();
    final wantedComposite = '$gradeLabel#$safeKind';
    String? storageKey;
    for (final raw in (rows as List<dynamic>)) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      final grade = '${row['grade'] ?? ''}'.trim();
      final key = '${row['storage_key'] ?? ''}'.trim();
      final status = '${row['migration_status'] ?? ''}'.trim();
      if (key.isEmpty) continue;
      if (status != 'dual' && status != 'migrated') continue;
      if (!grade.endsWith('#$safeKind')) continue;
      if (grade == wantedComposite) {
        storageKey = key;
        break;
      }
      if (grade.startsWith('$gradeLabel#')) {
        storageKey ??= key;
      }
    }
    if (storageKey != null && storageKey.isNotEmpty) {
      return TextbookPdfRef(
        academyId: academyId.trim(),
        fileId: bookId,
        gradeLabel: gradeLabel,
        kind: kind,
        storageKey: storageKey,
      );
    }
  } catch (e) {
    print('[PRINT][textbook] storage_key lookup failed: $e');
  }

  return TextbookPdfRef(
    academyId: academyId.trim(),
    fileId: bookId,
    gradeLabel: gradeLabel,
    kind: kind,
  );
}

Future<String?> _downloadPrintablePdfUrl(
  String rawUrl, {
  required String cacheKey,
  LearningProblemBankService? problemBankService,
}) async {
  final url = rawUrl.trim();
  if (!_isWebUrl(url)) return null;
  final pbService = problemBankService ?? LearningProblemBankService();
  try {
    final bytes = await pbService.downloadPdfBytesFromUrl(url);
    if (bytes.isEmpty) return null;
    final tmpDir = await getTemporaryDirectory();
    final path = p.join(
      tmpDir.path,
      '${cacheKey}_${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    _scheduleTempDelete(path);
    return path;
  } catch (_) {
    return null;
  }
}

Future<bool> _isPrintableResolvedHomeworkPrintSource(
  _ResolvedHomeworkPrintSource source,
) async {
  final raw = source.pathRaw.trim();
  if (raw.isEmpty) return false;
  if (_isWebUrl(raw)) return true;
  if (!source.isProblemBank && _textbookStorageKeyFromRaw(raw).isNotEmpty) {
    final ref = await _textbookPdfRefFromPrintSource(source, kind: 'body');
    return ref != null;
  }
  final localPath = _toLocalFilePath(raw);
  if (localPath.isEmpty) return false;
  return File(localPath).exists();
}

Future<String?> _materializeTextbookStoragePrintPath(
  _ResolvedHomeworkPrintSource source, {
  required String cacheKey,
  LearningProblemBankService? problemBankService,
  List<String>? errorsOut,
}) async {
  if (source.isProblemBank) return null;
  try {
    final ref = await _textbookPdfRefFromPrintSource(source, kind: 'body');
    if (ref == null) {
      errorsOut?.add(
        'textbook_ref_missing(book=${source.bookId}, grade=${source.gradeLabel}, path=${source.pathRaw})',
      );
      return null;
    }
    print(
      '[PRINT][textbook] resolve storageKey=${ref.storageKey ?? "(none)"} '
      'fileId=${ref.fileId ?? "(none)"} grade=${ref.gradeLabel ?? "(none)"}',
    );
    final resolved = await TextbookPdfService.instance.resolve(ref);
    final localPath = (resolved.localPath ?? '').trim();
    if (localPath.isNotEmpty &&
        localPath.toLowerCase().endsWith('.pdf') &&
        await File(localPath).exists()) {
      return localPath;
    }
    final url = (resolved.url ?? '').trim();
    if (_isWebUrl(url)) {
      final downloaded = await _downloadPrintablePdfUrl(
        url,
        cacheKey: cacheKey,
        problemBankService: problemBankService,
      );
      if (downloaded != null && downloaded.isNotEmpty) return downloaded;
      errorsOut?.add('storage_url_download_failed');
      return null;
    }
    errorsOut?.add(
      'resolve_no_local_or_url(type=${resolved.type}, status=${resolved.migrationStatus})',
    );
  } catch (e) {
    print('[PRINT][textbook] resolve failed: $e');
    errorsOut?.add('resolve_failed: $e');
  }
  return null;
}

Future<String?> _materializePrintablePathFromSource(
  _ResolvedHomeworkPrintSource source, {
  required String cacheKey,
  LearningProblemBankService? problemBankService,
  List<String>? errorsOut,
}) async {
  final raw = source.pathRaw.trim();
  if (raw.isEmpty) {
    errorsOut?.add('empty_pathRaw');
    return null;
  }
  print(
    '[PRINT][materialize] pathRaw=${raw.length > 120 ? '${raw.substring(0, 120)}…' : raw} '
    'book=${source.bookId} grade=${source.gradeLabel} pb=${source.isProblemBank}',
  );
  if (_isWebUrl(raw)) {
    final downloaded = await _downloadPrintablePdfUrl(
      raw,
      cacheKey: cacheKey,
      problemBankService: problemBankService,
    );
    if (downloaded != null && downloaded.isNotEmpty) return downloaded;
    errorsOut?.add('web_url_download_failed');
    // Dropbox 등 legacy URL 실패 시 bookId/grade로 storage 경로 재시도.
    return _materializeTextbookStoragePrintPath(
      source,
      cacheKey: cacheKey,
      problemBankService: problemBankService,
      errorsOut: errorsOut,
    );
  }
  if (!source.isProblemBank && _textbookStorageKeyFromRaw(raw).isNotEmpty) {
    return _materializeTextbookStoragePrintPath(
      source,
      cacheKey: cacheKey,
      problemBankService: problemBankService,
      errorsOut: errorsOut,
    );
  }
  // storage:// 없이 bookId/grade만 있는 경우도 storage resolve 시도.
  if (!source.isProblemBank &&
      source.bookId.trim().isNotEmpty &&
      source.gradeLabel.trim().isNotEmpty) {
    final fromTuple = await _materializeTextbookStoragePrintPath(
      source,
      cacheKey: cacheKey,
      problemBankService: problemBankService,
      errorsOut: errorsOut,
    );
    if (fromTuple != null && fromTuple.isNotEmpty) return fromTuple;
  }
  final localPath = _toLocalFilePath(raw);
  if (localPath.isEmpty) {
    errorsOut?.add('unrecognized_path');
    return null;
  }
  if (!await File(localPath).exists()) {
    errorsOut?.add('local_missing: $localPath');
    return null;
  }
  return localPath;
}

Future<_HomeworkPrintConfirmResult?> _showHomeworkPrintConfirmDialog({
  required BuildContext context,
  required HomeworkItem hw,
  required String filePath,
  required bool isPdf,
  required String initialRange,
  String? dialogTitle,
  List<HomeworkItem> selectableChildren = const <HomeworkItem>[],
  Map<String, bool> childPrintableById = const <String, bool>{},
  Map<String, bool> initialChildSelectionById = const <String, bool>{},
  Map<String, String> childPageRangeById = const <String, String>{},
}) async {
  final controller = ImeAwareTextEditingController(text: initialRange);
  final contentScrollController = ScrollController();
  bool printWhole = initialRange.isEmpty || !isPdf;
  final resolvedTitle = (dialogTitle ?? hw.title).trim();
  final hasChildChecklist = selectableChildren.isNotEmpty;
  final selectedChildById = <String, bool>{
    for (final child in selectableChildren)
      child.id: (childPrintableById[child.id] ?? true) &&
          (initialChildSelectionById[child.id] ??
              (childPrintableById[child.id] ?? true)),
  };
  String mergedRangeFromSelection() {
    if (!hasChildChecklist || !isPdf) return '';
    final picked = selectableChildren
        .where((child) => selectedChildById[child.id] ?? false)
        .toList(growable: false);
    if (picked.isEmpty) return '';
    return _normalizePageRangeForPrint(
      _mergeHomePrintPageRanges(
        picked.map((child) => childPageRangeById[child.id] ?? child.page),
      ),
    );
  }

  var duplexMode = PrintDuplexMode.twoSidedLongEdge;
  final result = await showDialog<_HomeworkPrintConfirmResult>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setLocalState) {
          final selectedChildIds = hasChildChecklist
              ? selectableChildren
                  .where((child) => selectedChildById[child.id] ?? false)
                  .map((child) => child.id)
                  .toList(growable: false)
              : const <String>[];
          final canSubmit = !hasChildChecklist || selectedChildIds.isNotEmpty;
          return AlertDialog(
            backgroundColor: kDlgBg,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text(
              '인쇄 설정 확인',
              style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
            ),
            content: SizedBox(
              width: hasChildChecklist ? 540 : 440,
              child: Scrollbar(
                controller: contentScrollController,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: contentScrollController,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (hasChildChecklist) ...[
                        const YggDialogSectionHeader(
                          icon: Icons.checklist_rounded,
                          title: '하위 과제 선택',
                        ),
                        const Text(
                          '체크한 하위 과제 페이지만 인쇄 범위에 반영됩니다.',
                          style: TextStyle(color: kDlgTextSub, fontSize: 12.5),
                        ),
                        const SizedBox(height: 10),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 260),
                          child: Column(
                            children: [
                              for (var idx = 0;
                                  idx < selectableChildren.length;
                                  idx++) ...[
                                if (idx > 0) const SizedBox(height: 8),
                                (() {
                                  final child = selectableChildren[idx];
                                  final canPrint =
                                      childPrintableById[child.id] ?? true;
                                  final pageText =
                                      (childPageRangeById[child.id] ??
                                              child.page ??
                                              '')
                                          .trim();
                                  final countText =
                                      (child.count != null && child.count! > 0)
                                          ? '${child.count}문항'
                                          : '-';
                                  final subtitle = [
                                    if (pageText.isNotEmpty) 'p.$pageText',
                                    countText,
                                    if (!canPrint) '인쇄 소스 없음',
                                  ].join(' · ');
                                  return Container(
                                    decoration: BoxDecoration(
                                      color: kDlgPanelBg,
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: kDlgBorder),
                                    ),
                                    child: CheckboxListTile(
                                      value:
                                          selectedChildById[child.id] ?? false,
                                      onChanged: canPrint
                                          ? (v) => setLocalState(() {
                                                selectedChildById[child.id] =
                                                    v ?? false;
                                                if (isPdf && !printWhole) {
                                                  final merged =
                                                      mergedRangeFromSelection();
                                                  if (merged.isNotEmpty ||
                                                      controller.text
                                                          .trim()
                                                          .isEmpty) {
                                                    controller.text = merged;
                                                  }
                                                }
                                              })
                                          : null,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 2,
                                      ),
                                      activeColor: kDlgAccent,
                                      checkColor: Colors.white,
                                      controlAffinity:
                                          ListTileControlAffinity.leading,
                                      title: LatexTextRenderer(
                                        child.title.trim().isEmpty
                                            ? '(제목 없음)'
                                            : child.title.trim(),
                                        style: TextStyle(
                                          color:
                                              canPrint ? kDlgText : kDlgTextSub,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13.5,
                                        ),
                                        maxLines: 1,
                                        softWrap: false,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      subtitle: Text(
                                        subtitle,
                                        style: TextStyle(
                                          color: canPrint
                                              ? kDlgTextSub
                                              : const Color(0xFF6E7E7E),
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                  );
                                })(),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                      ],
                      const YggDialogSectionHeader(
                        icon: Icons.print_rounded,
                        title: '출력 정보',
                      ),
                      LatexTextRenderer(
                        resolvedTitle.isEmpty ? '(제목 없음)' : resolvedTitle,
                        style: const TextStyle(
                          color: kDlgText,
                          fontWeight: FontWeight.w800,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        p.basename(filePath),
                        style:
                            const TextStyle(color: kDlgTextSub, fontSize: 12.5),
                      ),
                      const SizedBox(height: 14),
                      if (!isPdf)
                        const Text(
                          'PDF가 아니어서 전체 인쇄로 진행됩니다.',
                          style: TextStyle(color: kDlgTextSub),
                        )
                      else ...[
                        CheckboxListTile(
                          value: printWhole,
                          onChanged: (v) {
                            setLocalState(() {
                              printWhole = v ?? false;
                              if (!printWhole && hasChildChecklist) {
                                final merged = mergedRangeFromSelection();
                                if (merged.isNotEmpty) {
                                  controller.text = merged;
                                }
                              }
                            });
                          },
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          activeColor: kDlgAccent,
                          title: const Text(
                            '전체 인쇄',
                            style: TextStyle(
                                color: kDlgText, fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: controller,
                          enabled: !printWhole,
                          style: const TextStyle(color: kDlgText),
                          cursorColor: kDlgAccent,
                          decoration: InputDecoration(
                            hintText: '페이지 범위 (예: 10-15, 20)',
                            hintStyle: const TextStyle(color: kDlgTextSub),
                            filled: true,
                            fillColor: kDlgFieldBg,
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: kDlgBorder),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(
                                  color: kDlgAccent, width: 1.4),
                            ),
                            disabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: const BorderSide(color: kDlgBorder),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 14),
                      const YggDialogSectionHeader(
                        icon: Icons.flip_rounded,
                        title: '인쇄 면',
                      ),
                      Row(
                        children: [
                          ChoiceChip(
                            label: const Text('양면'),
                            selected:
                                duplexMode == PrintDuplexMode.twoSidedLongEdge,
                            onSelected: (_) => setLocalState(() {
                              duplexMode = PrintDuplexMode.twoSidedLongEdge;
                            }),
                            selectedColor: kDlgAccent,
                            labelStyle: TextStyle(
                              color:
                                  duplexMode == PrintDuplexMode.twoSidedLongEdge
                                      ? Colors.white
                                      : kDlgText,
                              fontWeight: FontWeight.w700,
                            ),
                            backgroundColor: kDlgPanelBg,
                            side: BorderSide(
                              color:
                                  duplexMode == PrintDuplexMode.twoSidedLongEdge
                                      ? kDlgAccent
                                      : kDlgBorder,
                            ),
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('단면'),
                            selected: duplexMode == PrintDuplexMode.oneSided,
                            onSelected: (_) => setLocalState(() {
                              duplexMode = PrintDuplexMode.oneSided;
                            }),
                            selectedColor: kDlgAccent,
                            labelStyle: TextStyle(
                              color: duplexMode == PrintDuplexMode.oneSided
                                  ? Colors.white
                                  : kDlgText,
                              fontWeight: FontWeight.w700,
                            ),
                            backgroundColor: kDlgPanelBg,
                            side: BorderSide(
                              color: duplexMode == PrintDuplexMode.oneSided
                                  ? kDlgAccent
                                  : kDlgBorder,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: canSubmit
                    ? () => Navigator.of(ctx).pop(
                          _HomeworkPrintConfirmResult(
                            pageRange: (isPdf && !printWhole)
                                ? controller.text.trim()
                                : '',
                            selectedChildIds: selectedChildIds,
                            duplexMode: duplexMode,
                          ),
                        )
                    : null,
                style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
                child: const Text('인쇄'),
              ),
            ],
          );
        },
      );
    },
  );
  controller.dispose();
  contentScrollController.dispose();
  return result;
}

Future<void> _runWithPrintProgressDialog(
  BuildContext context, {
  required Future<void> Function(ValueNotifier<String> progressText) run,
}) async {
  if (!context.mounted) return;
  final progressText = ValueNotifier<String>('인쇄 파일을 준비하는 중입니다...');
  final dialogContextCompleter = Completer<BuildContext>();

  unawaited(
    showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (dialogContext) {
        if (!dialogContextCompleter.isCompleted) {
          dialogContextCompleter.complete(dialogContext);
        }
        return PopScope(
          canPop: false,
          child: AlertDialog(
            backgroundColor: kDlgBg,
            contentPadding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: kDlgBorder),
            ),
            content: SizedBox(
              width: 360,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.6,
                      color: kDlgAccent,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: ValueListenableBuilder<String>(
                      valueListenable: progressText,
                      builder: (context, text, _) {
                        return SizedBox(
                          height: 24,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              text,
                              style: const TextStyle(
                                color: kDlgText,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );

  BuildContext? dialogContext;
  try {
    dialogContext = await dialogContextCompleter.future;
    await run(progressText);
  } finally {
    progressText.dispose();
    if (dialogContext != null && dialogContext.mounted) {
      Navigator.of(dialogContext, rootNavigator: true).pop();
    }
  }
}

String _messageFromPrintError(Object error) {
  final raw = error.toString().trim();
  if (raw.isEmpty) return '인쇄 요청 중 오류가 발생했습니다.';
  return raw
      .replaceFirst(RegExp(r'^Bad state:\s*'), '')
      .replaceFirst(RegExp(r'^Exception:\s*'), '');
}

Future<_PreparedHomeworkPrintTarget> _prepareHomeworkPrintTarget({
  required String studentId,
  required HomeworkItem hw,
  Map<String, HomeworkAssignmentDetail> assignmentByItemId =
      const <String, HomeworkAssignmentDetail>{},
  Map<String, _ResolvedHomeworkPrintSource> preResolvedSourceByItemId =
      const <String, _ResolvedHomeworkPrintSource>{},
  ValueNotifier<String>? progressText,
}) async {
  final resolvedAssignments = assignmentByItemId.isNotEmpty
      ? assignmentByItemId
      : await _loadActiveAssignmentByItemIdForPrint(studentId);
  final assignment = resolvedAssignments[hw.id.trim()];
  final isPbTarget = _isPbPrintTarget(hw: hw, assignment: assignment);
  final preResolved = preResolvedSourceByItemId[hw.id];

  _ResolvedHomeworkPrintSource resolvedSource;
  String? bodyPath;
  final materializeErrors = <String>[];

  if (isPbTarget) {
    var pbSource = (preResolved != null && preResolved.isProblemBank)
        ? preResolved
        : const _ResolvedHomeworkPrintSource(
            pathRaw: '',
            sourceKey: 'pb_missing',
            isProblemBank: true,
          );
    final hasPrintableSource =
        await _isPrintableResolvedHomeworkPrintSource(pbSource);
    if (pbSource.isEmpty || !hasPrintableSource) {
      progressText?.value = '문제은행 인쇄 PDF를 준비하는 중입니다...';
      pbSource = await _resolvePbPrintSource(
            hw,
            assignment: assignment,
            ensureExportJob: true,
            progressText: progressText,
          ) ??
          const _ResolvedHomeworkPrintSource(
            pathRaw: '',
            sourceKey: 'pb_missing',
            isProblemBank: true,
          );
    }
    if (pbSource.isEmpty) {
      throw StateError('문제은행 인쇄 PDF를 준비하지 못했습니다.');
    }
    progressText?.value = '인쇄 파일을 내려받는 중입니다...';
    bodyPath = await _materializePrintablePathFromSource(
      pbSource,
      cacheKey: 'hw_print_${hw.id}',
      errorsOut: materializeErrors,
    );
    resolvedSource = pbSource;
  } else {
    resolvedSource = (preResolved != null && !preResolved.isProblemBank)
        ? preResolved
        : await _resolveTextbookPrintSource(
            hw,
            allowFlowFallback: true,
          );
    if (resolvedSource.isEmpty) {
      throw StateError('인쇄 가능한 교재 PDF를 찾지 못했습니다.');
    }
    progressText?.value = '인쇄 파일을 준비하는 중입니다...';
    bodyPath = await _materializePrintablePathFromSource(
      resolvedSource,
      cacheKey: 'hw_print_${hw.id}',
      errorsOut: materializeErrors,
    );
  }

  if (bodyPath == null || bodyPath.isEmpty) {
    final detail = materializeErrors.isEmpty
        ? ''
        : ' (${materializeErrors.take(2).join(' | ')})';
    throw StateError('인쇄 파일을 찾을 수 없습니다.$detail');
  }
  return _PreparedHomeworkPrintTarget(
    source: resolvedSource,
    printablePath: bodyPath,
  );
}

Future<_HomeworkPrintRunResult> _runResolvedHomeworkPrint({
  required String studentId,
  required HomeworkItem hw,
  required _ResolvedHomeworkPrintSource resolvedSource,
  required String printablePath,
  required _HomeworkPrintConfirmResult confirmResult,
  List<HomeworkItem> selectableGroupChildren = const <HomeworkItem>[],
  ValueNotifier<String>? progressText,
}) async {
  if (selectableGroupChildren.isNotEmpty &&
      confirmResult.selectedChildIds.isEmpty) {
    return const _HomeworkPrintRunResult(
      printJobSentToSpooler: false,
      error: '인쇄 가능한 하위 과제를 선택하세요.',
    );
  }

  final selectedIds = confirmResult.selectedChildIds.toSet();
  final selectedHomeworks = selectableGroupChildren.isNotEmpty
      ? selectableGroupChildren
          .where((child) => selectedIds.contains(child.id))
          .toList(growable: false)
      : <HomeworkItem>[hw];
  final overlayMeta = await _resolveHomeworkPrintOverlayMeta(
    studentId: studentId,
    fallbackHomework: hw,
    selectedHomeworks: selectedHomeworks,
  );

  final isPdf = printablePath.toLowerCase().endsWith('.pdf');
  final selectedRange = confirmResult.pageRange;
  String pathToPrint = printablePath;
  final rangeDisplay = _normalizePageRangeForPrint(selectedRange);
  final rangeRaw = resolvedSource.isProblemBank ? '' : rangeDisplay;
  var effectivePaperSize = resolvedSource.preferredPaperSize.trim();
  if (!resolvedSource.isProblemBank && isPdf) {
    effectivePaperSize = 'A4';
    print('[PRINT][paper] textbookDefaultPaper="A4"');
  } else if (effectivePaperSize.isEmpty && isPdf) {
    effectivePaperSize = await _inferPreferredPaperSizeFromPdf(
      inputPath: printablePath,
      pageRange: rangeRaw,
    );
    if (effectivePaperSize.isNotEmpty) {
      print('[PRINT][paper] inferredPaper="$effectivePaperSize"');
    }
  }

  if (isPdf) {
    progressText?.value = rangeRaw.isEmpty
        ? '인쇄 파일을 준비하는 중입니다...'
        : '선택한 페이지를 인쇄 파일로 만드는 중입니다...';
    final out = await _buildPdfForPrintRange(
      inputPath: printablePath,
      pageRange: rangeRaw,
      overlayMeta: overlayMeta,
      preferredPaperSize: effectivePaperSize,
    );
    if (out == null || out.isEmpty) {
      return _HomeworkPrintRunResult(
        printJobSentToSpooler: false,
        error: rangeRaw.isEmpty
            ? '인쇄 파일 생성에 실패했습니다.'
            : '페이지 범위를 확인하세요. (예: 10-15, 20)',
      );
    }
    pathToPrint = out;
    _scheduleTempDelete(pathToPrint);
  } else if (rangeRaw.isNotEmpty) {
    return const _HomeworkPrintRunResult(
      printJobSentToSpooler: false,
      error: '페이지 범위 인쇄는 PDF에서만 지원합니다.',
    );
  }

  progressText?.value = '프린터로 전송 중입니다...';
  final skipRawTcpForTextbookHomework = !resolvedSource.isProblemBank &&
      PrintRoutingService.kTextbookHomeworkPrintPreferDriverSpooler;
  if (skipRawTcpForTextbookHomework) {
    print('[PRINT][route] textbookHomework driverSpoolerFirst=true');
  }
  final printJobSentToSpooler = await _openPrintDialogForPath(
    pathToPrint,
    preferredPaperSize: effectivePaperSize,
    duplexMode: confirmResult.duplexMode,
    skipRawTcpFirst: skipRawTcpForTextbookHomework,
  );
  if (printJobSentToSpooler) {
    _applyHomeworkTypePrintAfterSuccessfulPrint(
      studentId: studentId,
      itemIds: selectedHomeworks.map((e) => e.id),
    );
  }
  return _HomeworkPrintRunResult(
    printJobSentToSpooler: printJobSentToSpooler,
  );
}

Future<_HomeworkPrintRunResult> _runHomeworkPrintWithDefaultSettings({
  required String studentId,
  required HomeworkItem hw,
  String? initialRangeOverride,
  List<HomeworkItem> selectableGroupChildren = const <HomeworkItem>[],
  Map<String, bool> groupChildPrintableById = const <String, bool>{},
  Map<String, bool> groupInitialSelectionById = const <String, bool>{},
  Map<String, HomeworkAssignmentDetail> assignmentByItemId =
      const <String, HomeworkAssignmentDetail>{},
  Map<String, _ResolvedHomeworkPrintSource> preResolvedSourceByItemId =
      const <String, _ResolvedHomeworkPrintSource>{},
  ValueNotifier<String>? progressText,
}) async {
  final prepared = await _prepareHomeworkPrintTarget(
    studentId: studentId,
    hw: hw,
    assignmentByItemId: assignmentByItemId,
    preResolvedSourceByItemId: preResolvedSourceByItemId,
    progressText: progressText,
  );
  final resolvedAssignments = assignmentByItemId.isNotEmpty
      ? assignmentByItemId
      : await _loadActiveAssignmentByItemIdForPrint(studentId);
  final assignment = resolvedAssignments[hw.id.trim()];
  final isPbTarget = _isPbPrintTarget(hw: hw, assignment: assignment);
  final initialRangeRaw = isPbTarget
      ? ''
      : (initialRangeOverride ?? await _homeworkPrintStoredPageRange(hw));
  final selectedChildIds = selectableGroupChildren.isEmpty
      ? const <String>[]
      : selectableGroupChildren
          .where((child) =>
              (groupChildPrintableById[child.id] ?? true) &&
              (groupInitialSelectionById[child.id] ?? true))
          .map((child) => child.id)
          .toList(growable: false);
  final confirmResult = _HomeworkPrintConfirmResult(
    pageRange: _normalizePageRangeForPrint(initialRangeRaw),
    selectedChildIds: selectedChildIds,
    duplexMode: PrintDuplexMode.twoSidedLongEdge,
  );
  return _runResolvedHomeworkPrint(
    studentId: studentId,
    hw: hw,
    resolvedSource: prepared.source,
    printablePath: prepared.printablePath,
    confirmResult: confirmResult,
    selectableGroupChildren: selectableGroupChildren,
    progressText: progressText,
  );
}

Future<_HomeworkGroupPrintRequest> _buildHomeworkGroupPrintRequest({
  required String studentId,
  required HomeworkGroup group,
  required HomeworkItem summary,
  required List<HomeworkItem> children,
}) async {
  final latestChildren = children
      .map((e) => HomeworkStore.instance.getById(studentId, e.id) ?? e)
      .toList(growable: false);
  final eligibleChildren = latestChildren
      .where((e) => e.status != HomeworkStatus.completed)
      .toList(growable: false);
  if (eligibleChildren.isEmpty) {
    return _HomeworkGroupPrintRequest(
      seed: summary,
      initialRange: '',
      dialogTitle: summary.title.trim().isEmpty ? '(제목 없음)' : summary.title,
      eligibleChildren: const <HomeworkItem>[],
      printableById: const <String, bool>{},
      initialSelectedById: const <String, bool>{},
      assignmentByItemId: const <String, HomeworkAssignmentDetail>{},
      sourceByItemId: const <String, _ResolvedHomeworkPrintSource>{},
      error: '인쇄 가능한 하위 과제가 없습니다.',
    );
  }

  final assignmentByItemId =
      await _loadActiveAssignmentByItemIdForPrint(studentId);
  final printableById = <String, bool>{};
  final sourceByItemId = <String, _ResolvedHomeworkPrintSource>{};
  String? canonicalPrintGroupKey;
  final observedPipelineKinds = <String>{};
  final observedPrintGroupKeys = <String>{};
  for (final child in eligibleChildren) {
    final assignment = assignmentByItemId[child.id.trim()];
    final pipelineKey =
        _printPipelineKeyForHomework(hw: child, assignment: assignment);
    observedPipelineKinds.add(pipelineKey);
    final isPb = pipelineKey == _kPrintPipelinePb;
    final source = isPb
        ? (await _resolvePbPrintSource(
              child,
              assignment: assignment,
            ) ??
            const _ResolvedHomeworkPrintSource(
              pathRaw: '',
              sourceKey: 'pb_missing',
              isProblemBank: true,
            ))
        : await _resolveTextbookPrintSource(
            child,
            allowFlowFallback: true,
          );
    sourceByItemId[child.id] = source;
    final available = isPb
        ? (await _isPrintableResolvedHomeworkPrintSource(source) ||
            _canCreatePbPrintFromTarget(hw: child, assignment: assignment))
        : await _isPrintableResolvedHomeworkPrintSource(source);
    if (!available) {
      printableById[child.id] = false;
      continue;
    }
    final printGroupKey =
        isPb ? pipelineKey : '$pipelineKey:${source.sourceKey}';
    observedPrintGroupKeys.add(printGroupKey);
    canonicalPrintGroupKey ??= printGroupKey;
    printableById[child.id] = canonicalPrintGroupKey == printGroupKey;
  }

  final defaultPrintableChildren = eligibleChildren
      .where((e) => printableById[e.id] ?? false)
      .toList(growable: false);
  if (defaultPrintableChildren.isEmpty) {
    return _HomeworkGroupPrintRequest(
      seed: eligibleChildren.first,
      initialRange: '',
      dialogTitle: summary.title.trim().isEmpty ? '(제목 없음)' : summary.title,
      eligibleChildren: eligibleChildren,
      printableById: printableById,
      initialSelectedById: {
        for (final child in eligibleChildren)
          child.id: printableById[child.id] ?? false,
      },
      assignmentByItemId: assignmentByItemId,
      sourceByItemId: sourceByItemId,
      error: '인쇄 가능한 하위 과제가 없습니다.',
    );
  }

  final seed = defaultPrintableChildren.first;
  final childPageRangeById =
      await _homeworkPrintPageRangeByChildId(defaultPrintableChildren);
  final mergedPage = _mergeHomePrintPageRanges(defaultPrintableChildren.map(
    (child) => childPageRangeById[child.id] ?? child.page,
  ));
  final mergedTitle = summary.title.trim().isNotEmpty
      ? summary.title.trim()
      : (group.title.trim().isNotEmpty
          ? group.title.trim()
          : seed.title.trim());
  final printRange = mergedPage.isEmpty ? (seed.page ?? '') : mergedPage;
  final dialogTitle = mergedTitle.isEmpty ? '(제목 없음)' : mergedTitle;
  return _HomeworkGroupPrintRequest(
    seed: seed,
    initialRange: printRange,
    dialogTitle: dialogTitle,
    eligibleChildren: eligibleChildren,
    printableById: printableById,
    initialSelectedById: {
      for (final child in eligibleChildren)
        child.id: printableById[child.id] ?? false,
    },
    childPageRangeById: childPageRangeById,
    assignmentByItemId: assignmentByItemId,
    sourceByItemId: sourceByItemId,
    warning: observedPipelineKinds.length > 1
        ? '혼합 인쇄는 지원되지 않아요. 문제은행/교재를 분리해서 인쇄해 주세요.'
        : (observedPrintGroupKeys.length > 1
            ? '서로 다른 교재 PDF는 함께 인쇄할 수 없어 첫 번째 교재만 인쇄합니다.'
            : null),
  );
}

Future<void> _handleWaitingChipLongPressPrint({
  required BuildContext context,
  required String studentId,
  required HomeworkItem hw,
  String? initialRangeOverride,
  String? dialogTitleOverride,
  List<HomeworkItem> selectableGroupChildren = const <HomeworkItem>[],
  Map<String, bool> groupChildPrintableById = const <String, bool>{},
  Map<String, bool> groupInitialSelectionById = const <String, bool>{},
  Map<String, String> groupChildPageRangeById = const <String, String>{},
  Map<String, HomeworkAssignmentDetail> assignmentByItemId =
      const <String, HomeworkAssignmentDetail>{},
  Map<String, _ResolvedHomeworkPrintSource> preResolvedSourceByItemId =
      const <String, _ResolvedHomeworkPrintSource>{},
}) async {
  if (hw.status == HomeworkStatus.completed) return;
  final resolvedAssignments = assignmentByItemId.isNotEmpty
      ? assignmentByItemId
      : await _loadActiveAssignmentByItemIdForPrint(studentId);
  final assignment = resolvedAssignments[hw.id.trim()];
  final isPbTarget = _isPbPrintTarget(hw: hw, assignment: assignment);

  // ── Phase 1: kick off background PDF preparation ──
  final bgCompleter = Completer<_PreparedHomeworkPrintTarget>();
  unawaited(() async {
    try {
      final prepared = await _prepareHomeworkPrintTarget(
        studentId: studentId,
        hw: hw,
        assignmentByItemId: resolvedAssignments,
        preResolvedSourceByItemId: preResolvedSourceByItemId,
      );
      if (!bgCompleter.isCompleted) bgCompleter.complete(prepared);
    } catch (e) {
      if (!bgCompleter.isCompleted) bgCompleter.completeError(e);
    }
  }());

  // ── Phase 2: show print confirm dialog immediately ──
  final isPdf = true;
  final initialRangeRaw = isPbTarget
      ? ''
      : (initialRangeOverride ?? await _homeworkPrintStoredPageRange(hw));
  final initialRange = _normalizePageRangeForPrint(initialRangeRaw);
  final confirmResult = await _showHomeworkPrintConfirmDialog(
    context: context,
    hw: hw,
    filePath: '인쇄 파일 준비 중...',
    isPdf: isPdf,
    initialRange: initialRange,
    dialogTitle: dialogTitleOverride,
    selectableChildren: selectableGroupChildren,
    childPrintableById: groupChildPrintableById,
    initialChildSelectionById: groupInitialSelectionById,
    childPageRangeById: groupChildPageRangeById,
  );
  if (!context.mounted || confirmResult == null) return;
  if (selectableGroupChildren.isNotEmpty &&
      confirmResult.selectedChildIds.isEmpty) {
    _showHomeworkChipSnackBar(context, '인쇄 가능한 하위 과제를 선택하세요.');
    return;
  }

  // ── Phase 3: wait for background PDF if not done yet ──
  _PreparedHomeworkPrintTarget prepared;
  try {
    prepared = bgCompleter.isCompleted
        ? await bgCompleter.future
        : await () async {
            late final _PreparedHomeworkPrintTarget result;
            await _runWithPrintProgressDialog(
              context,
              run: (progressText) async {
                progressText.value = '인쇄 파일을 준비하는 중입니다...';
                result = await bgCompleter.future;
              },
            );
            return result;
          }();
  } catch (e) {
    if (!context.mounted) return;
    _showHomeworkChipSnackBar(context, _messageFromPrintError(e));
    return;
  }
  if (!context.mounted) return;

  _HomeworkPrintRunResult runResult =
      const _HomeworkPrintRunResult(printJobSentToSpooler: false);
  try {
    await _runWithPrintProgressDialog(
      context,
      run: (progressText) async {
        runResult = await _runResolvedHomeworkPrint(
          studentId: studentId,
          hw: hw,
          resolvedSource: prepared.source,
          printablePath: prepared.printablePath,
          confirmResult: confirmResult,
          selectableGroupChildren: selectableGroupChildren,
          progressText: progressText,
        );
      },
    );
  } catch (e) {
    if (!context.mounted) return;
    _showHomeworkChipSnackBar(context, _messageFromPrintError(e));
    return;
  }
  if (!context.mounted) return;
  if (runResult.error != null) {
    _showHomeworkChipSnackBar(context, runResult.error!);
  }
}

Future<void> _handleSubmittedChipTapWithAnswerViewer({
  required BuildContext context,
  required String studentId,
  required HomeworkItem hw,
}) async {
  final resolved = await _resolveHomeworkPdfLinks(hw, allowFlowFallback: true);
  if (!context.mounted) return;

  final answerRaw = resolved.answerPathRaw;
  if (answerRaw.isEmpty) {
    await _runHomeworkCheckAndConfirm(
      context: context,
      studentId: studentId,
      hw: hw,
    );
    return;
  }
  final answerIsUrl = _isWebUrl(answerRaw);
  final answerPath =
      answerIsUrl ? answerRaw.trim() : _toLocalFilePath(answerRaw);
  if (answerPath.isEmpty ||
      (!answerIsUrl && !answerPath.toLowerCase().endsWith('.pdf'))) {
    _showHomeworkChipSnackBar(context, '답지 PDF 경로를 확인할 수 없어 바로 확인 처리합니다.');
    await _runHomeworkCheckAndConfirm(
      context: context,
      studentId: studentId,
      hw: hw,
    );
    return;
  }
  if (!answerIsUrl && !await File(answerPath).exists()) {
    if (!context.mounted) return;
    _showHomeworkChipSnackBar(context, '답지 PDF 파일을 찾을 수 없어 바로 확인 처리합니다.');
    await _runHomeworkCheckAndConfirm(
      context: context,
      studentId: studentId,
      hw: hw,
    );
    return;
  }

  String? solutionPath;
  final solutionRaw = resolved.solutionPathRaw;
  if (_isWebUrl(solutionRaw)) {
    solutionPath = solutionRaw.trim();
  } else if (solutionRaw.isNotEmpty) {
    final candidate = _toLocalFilePath(solutionRaw);
    if (candidate.isNotEmpty &&
        candidate.toLowerCase().endsWith('.pdf') &&
        await File(candidate).exists()) {
      solutionPath = candidate;
    }
  }

  final closeAction = closeRightSideSheetAction;
  if (closeAction != null) {
    await closeAction();
  }
  final action = await openHomeworkAnswerViewerPage(
    context,
    filePath: answerPath,
    title: hw.title.trim().isEmpty ? '답지 확인' : hw.title.trim(),
    solutionFilePath: solutionPath,
    cacheKey: 'student:$studentId|answer:$answerPath',
    enableConfirm: true,
  );
  if (!context.mounted) return;
  if (action == HomeworkAnswerViewerAction.complete) {
    await _runHomeworkCheckAndConfirm(
      context: context,
      studentId: studentId,
      hw: hw,
      markAutoCompleteOnNextWaiting: true,
    );
    return;
  }
  if (action == HomeworkAnswerViewerAction.confirm) {
    await _runHomeworkCheckAndConfirm(
      context: context,
      studentId: studentId,
      hw: hw,
    );
  }
}

bool _isTestHomeworkType(String? typeLabel) =>
    (typeLabel ?? '').trim() == '테스트';

bool _isTestHomeworkEntry(Map<String, dynamic> entry) {
  final typeLabel = (entry['type'] as String?)?.trim();
  final sourceUnitLevel = (entry['sourceUnitLevel'] as String?)?.trim();
  final testOriginFlowId = (entry['testOriginFlowId'] as String?)?.trim();
  return _isTestHomeworkType(typeLabel) ||
      entry['testMode'] == true ||
      sourceUnitLevel == 'naesin' ||
      (testOriginFlowId != null && testOriginFlowId.isNotEmpty);
}

bool _isTestHomeworkItem(HomeworkItem item) {
  final sourceUnitLevel = (item.sourceUnitLevel ?? '').trim();
  final testOriginFlowId = (item.testOriginFlowId ?? '').trim();
  return _isTestHomeworkType(item.type) ||
      testOriginFlowId.isNotEmpty ||
      (sourceUnitLevel == 'naesin' && (item.timeLimitMinutes ?? 0) > 0);
}

Widget _buildFlowChip(
  String flowName, {
  required _HomeworkCardTheme cardTheme,
  String? dueLabel,
  bool isHomeworkDue = false,
  String? overrideText,
  Color? overrideTextColor,
  Color? overrideBackgroundColor,
  Border? overrideBorder,
}) {
  final normalizedFlowName = flowName.trim();
  final normalizedDueLabel = (dueLabel ?? '').trim();
  final normalizedOverrideText = (overrideText ?? '').trim();
  // 숙제: 긴 due 라벨 대신 '숙제'만. 배경은 제거하고 테두리는 유지.
  if (isHomeworkDue && normalizedOverrideText.isEmpty) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: overrideBackgroundColor ?? Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        border: overrideBorder ?? Border.all(color: kDlgAccent, width: 1.05),
      ),
      child: Text(
        '숙제',
        style: TextStyle(
          color: overrideTextColor ?? const Color(0xFF9FE3C6),
          fontSize: 14,
          fontWeight: FontWeight.w600,
          height: 1.1,
        ),
      ),
    );
  }
  final chipText = normalizedOverrideText.isNotEmpty
      ? normalizedOverrideText
      : (normalizedDueLabel.isEmpty
          ? (normalizedFlowName.isEmpty ? '플로우 미지정' : normalizedFlowName)
          : (normalizedFlowName.isEmpty
              ? normalizedDueLabel
              : '$normalizedFlowName · $normalizedDueLabel'));
  final bool isDefault =
      StudentFlow.normalizeName(normalizedFlowName) == '개념' && !isHomeworkDue;
  final Color backgroundColor = overrideBackgroundColor ??
      (isDefault ? Colors.transparent : cardTheme.flowChipDefaultBg);
  final Border? border = overrideBorder ??
      (isDefault
          ? Border.all(color: cardTheme.flowChipDefaultBorder, width: 1)
          : null);
  final Color textColor = overrideTextColor ?? cardTheme.flowChipDefaultText;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
    decoration: BoxDecoration(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(20),
      border: border,
    ),
    child: Text(
      chipText,
      style: TextStyle(
        color: textColor,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

String _formatRecommendedMinutesCompact(int minutes) {
  final safeMinutes = math.max(0, minutes);
  final hours = safeMinutes ~/ 60;
  final remain = safeMinutes % 60;
  if (hours <= 0) return '${remain}분';
  if (remain == 0) return '${hours}시간';
  return '${hours}시간 $remain분';
}

String _formatKoreanDurationMs(int totalMs) {
  final totalMinutes = math.max(0, totalMs) ~/ 60000;
  return _formatRecommendedMinutesCompact(totalMinutes);
}

int _homeworkRecommendedMinutesOf(HomeworkItem item) {
  final confirmed = item.recommendedMinutes ?? 0;
  if (confirmed > 0) return confirmed;
  return item.recommendedMinutesAuto ?? 0;
}

/// 그룹 과제 권장분: 하위 합산 후 α는 그룹당 1회만 남긴다.
({int minutes, bool hasUnestimated}) _groupRecommendedMinutesOf(
  Iterable<HomeworkItem> items,
) {
  var raw = 0;
  var alphaCount = 0;
  var hasUnestimated = false;
  for (final item in items) {
    final value = _homeworkRecommendedMinutesOf(item);
    if (value > 0) {
      raw += value;
      alphaCount += 1;
    } else {
      hasUnestimated = true;
    }
  }
  final minutes = math.max(
    0,
    raw -
        math.max(0, alphaCount - 1) *
            HomeworkTimeDefaultsService.initialAlphaMinutes,
  );
  return (minutes: minutes, hasUnestimated: hasUnestimated);
}

Widget _buildHomeworkChipVisual(
  BuildContext context,
  String studentId,
  HomeworkItem hw,
  String flowName,
  int assignmentCount, {
  String? groupId,
  Set<String> assignedItemIds = const <String>{},
  required double tick,
  String? dueLabel,
  bool isHomeworkDue = false,
  HomeworkGradingProgressRate progressRate =
      HomeworkGradingProgressRate.disabled,
  bool isReservation = false,
  bool attachRightExtension = false,
  bool isExpanded = false,
  bool showAdditionalPrefix = false,
  List<HomeworkItem> groupChildren = const <HomeworkItem>[],
  HomeworkAssignmentCycleMeta? cycleMeta,
  bool isPendingConfirm = false,
  bool isCompleteCheckbox = false,
  VoidCallback? onInfoTap,
  VoidCallback? onTypeTap,
  VoidCallback? onGroupTitleTap,
  VoidCallback? onInspectionDateTap,
  void Function(HomeworkItem child)? onGroupChildPageTap,
  VoidCallback? onGroupChildAddTap,
  Future<void> Function(HomeworkItem dragged, HomeworkItem target)?
      onGroupChildDropBefore,
  Future<void> Function(HomeworkItem dragged)? onGroupChildDropToEnd,
}) {
  final bool isRunning =
      HomeworkStore.instance.runningOf(studentId)?.id == hw.id ||
          hw.phase == 2 ||
          hw.runStart != null;
  final int phase = hw.phase;
  final bool visualRunning = isReservation ? false : isRunning;
  final int visualPhase = isReservation ? 1 : phase;
  const Color unifiedHomeworkAccent = kDlgAccent;
  final cardTheme = _HomeworkCardTheme.of(context);
  final TextStyle titleStyle = cardTheme.titleStyle;
  final TextStyle metaStyle = cardTheme.metaStyle;
  final TextStyle secondaryRowStyle = cardTheme.secondaryRowStyle;
  const double leftPad = 24;
  const double rightPad = 24;
  const double borderWMax = 3.0;

  final groupedCardBackground = FabTabBarTokens.previewAcademyPanelStyleFor(
    Theme.of(context).brightness,
  ).groupedCardBackground;

  final String displayFlowName = flowName.isNotEmpty ? flowName : '플로우 미지정';
  final String page = (hw.page ?? '').trim();

  String stripUnitPrefix(String raw) {
    return raw.replaceFirst(RegExp(r'^\s*\d+\.\d+\.\(\d+\)\s+'), '').trim();
  }

  String extractBookName() {
    final contentRaw = (hw.content ?? '').trim();
    final match = RegExp(r'(?:^|\n)\s*교재:\s*([^\n]+)').firstMatch(contentRaw);
    final fromContent = match?.group(1)?.trim() ?? '';
    if (fromContent.isNotEmpty) return fromContent;

    final hasLinkedTextbook = (hw.bookId ?? '').trim().isNotEmpty &&
        (hw.gradeLabel ?? '').trim().isNotEmpty;
    if (hasLinkedTextbook) {
      final stripped = stripUnitPrefix((hw.title).trim());
      if (stripped.isNotEmpty) {
        final idx = stripped.indexOf('·');
        if (idx == -1) return stripped;
        final candidate = stripped.substring(0, idx).trim();
        if (candidate.isNotEmpty) return candidate;
      }
    }

    final typeLabel = (hw.type ?? '').trim();
    if (typeLabel.isNotEmpty) return typeLabel;
    return '-';
  }

  String extractCourseName() {
    final contentRaw = (hw.content ?? '').trim();
    final match = RegExp(r'(?:^|\n)\s*과정:\s*([^\n]+)').firstMatch(contentRaw);
    return match?.group(1)?.trim() ?? '';
  }

  final int homeworkCount = assignmentCount < 0 ? 0 : assignmentCount;
  final int splitParts =
      (cycleMeta?.splitParts ?? hw.defaultSplitParts).clamp(1, 4);
  final int splitRound = (cycleMeta?.splitRound ?? 1).clamp(1, splitParts);
  final String rawTitleText = (hw.title).trim();
  // 서버 title은 그대로 두고 홈 카드 표시에만 '+' (채점모드·다이얼로그는 호출부에서 false).
  final String titleText = showAdditionalPrefix && rawTitleText.isNotEmpty
      ? '+ $rawTitleText'
      : rawTitleText;
  final String bookName = extractBookName();
  final String courseName = extractCourseName();
  final String line2Left = (bookName == '-' || bookName.isEmpty)
      ? (courseName.isEmpty ? '-' : courseName)
      : (courseName.isEmpty ? bookName : '$bookName · $courseName');
  final int? countValue = hw.count;
  int resolveSplitCount(int total, int parts, int round) {
    if (parts <= 1) return total;
    final base = total ~/ parts;
    final remainder = total % parts;
    return base + (round <= remainder ? 1 : 0);
  }

  final String displayCount = () {
    if (countValue == null) return '';
    final safeCount = countValue < 0 ? 0 : countValue;
    if (splitParts <= 1) return safeCount.toString();
    return resolveSplitCount(safeCount, splitParts, splitRound).toString();
  }();
  final String line4PageText = 'p.${page.isNotEmpty ? page : '-'}';
  final int runningMs = hw.runStart != null
      ? DateTime.now().difference(hw.runStart!).inMilliseconds
      : 0;
  final int totalMs = hw.accumulatedMs + runningMs;
  final int cycleBaseMs = hw.cycleBaseAccumulatedMs;
  final int cycleProgressMs = math.max(0, totalMs - cycleBaseMs);
  final bool isPausedWaiting =
      visualPhase == 1 && cycleProgressMs > 0 && hw.firstStartedAt != null;
  final int cycleProgressMsForDisplay =
      (visualPhase == 1 && !isPausedWaiting) ? 0 : cycleProgressMs;
  final String startedAtText =
      hw.firstStartedAt == null ? '-' : _formatShortTime(hw.firstStartedAt!);
  final String rawTypeText =
      (hw.type ?? '').trim().isEmpty ? '-' : (hw.type ?? '').trim();

  final String startDateText = hw.firstStartedAt != null
      ? '${hw.firstStartedAt!.month.toString().padLeft(2, '0')}.${hw.firstStartedAt!.day.toString().padLeft(2, '0')}'
      : (hw.createdAt != null
          ? '${hw.createdAt!.month.toString().padLeft(2, '0')}.${hw.createdAt!.day.toString().padLeft(2, '0')}'
          : '-');

  // 숙제 배정 회차가 아니라 수행 사이클 기준.
  // 확인(checkCount)마다 끝난 시도가 쌓이고, 대기/확인은 그 차수를 유지,
  // 수행·제출에 들어갈 때 다음 차수(+1).
  final int displayRepeatIndex = _homeworkPerformanceAttemptIndex(
    checkCount: hw.checkCount,
    phase: hw.phase,
  );
  // 그룹 과제는 하위과제 공통 1개 코드만 표시한다.
  final String assignmentCodeText = () {
    final sources = groupChildren.isNotEmpty ? groupChildren : [hw];
    for (final item in sources) {
      final code = _formatHomeworkAssignmentCode(
        item.assignmentCode,
        fallback: '',
      );
      if (code.isNotEmpty) return code;
    }
    return '-';
  }();
  final double fixedWidth = ClassContentScreen._studentColumnContentWidth;
  final double maxRowW = fixedWidth - leftPad - rightPad;
  final bool hasGroupChildren = groupChildren.isNotEmpty;
  final recommendedSources =
      hasGroupChildren ? groupChildren : <HomeworkItem>[hw];
  // 하위과제 스냅샷의 α는 그룹당 1회만 남긴다.
  final int totalRecommendedMinutes =
      _groupRecommendedMinutesOf(recommendedSources).minutes;
  final String recommendedTimeText = totalRecommendedMinutes > 0
      ? _formatRecommendedMinutesCompact(totalRecommendedMinutes)
      : '-';
  final bool isTestCard = hasGroupChildren
      ? groupChildren.any(_isTestHomeworkItem)
      : _isTestHomeworkItem(hw);
  final int progressMsForDisplay =
      isTestCard ? totalMs : cycleProgressMsForDisplay;
  final int? testLimitMinutes = isTestCard
      ? () {
          if (hasGroupChildren) {
            for (final child in groupChildren) {
              final limit = child.timeLimitMinutes;
              if (limit != null && limit > 0) return limit;
            }
          }
          final fallbackLimit = hw.timeLimitMinutes;
          if (fallbackLimit != null && fallbackLimit > 0) return fallbackLimit;
          return null;
        }()
      : null;
  final int? testLimitMs = (testLimitMinutes != null && testLimitMinutes > 0)
      ? testLimitMinutes * 60000
      : null;
  final bool hasConfirmedCycleHistory = isTestCard && hw.confirmedAt != null;
  final bool showRunningExtraTime = testLimitMs != null &&
      visualPhase == 2 &&
      !isReservation &&
      hasConfirmedCycleHistory;
  final bool showRunningRemaining = testLimitMs != null &&
      visualPhase == 2 &&
      !isReservation &&
      !showRunningExtraTime;
  final int remainingMs =
      testLimitMs == null ? 0 : math.max(0, testLimitMs - progressMsForDisplay);
  final int remainingMinutes = testLimitMs == null
      ? 0
      : (remainingMs <= 0 ? 0 : ((remainingMs + 59999) ~/ 60000));
  final int extraMs =
      testLimitMs == null ? 0 : math.max(0, progressMsForDisplay - testLimitMs);
  final int extraMinutes = extraMs <= 0 ? 0 : ((extraMs + 59999) ~/ 60000);
  final bool shouldAutoSubmitForTimeout =
      showRunningRemaining && remainingMs <= 0;
  final String resolvedGroupId = (groupId ?? '').trim();
  final String autoSubmitKey = '$studentId|${hw.id}';
  final String timeoutBadgeKey = hasGroupChildren && resolvedGroupId.isNotEmpty
      ? '$studentId|group:$resolvedGroupId'
      : autoSubmitKey;
  if (!isTestCard) {
    _testTimedOutHomeworkKeys.remove(timeoutBadgeKey);
    _testAutoSubmitTriggeredKeys.remove(autoSubmitKey);
  } else {
    if (!shouldAutoSubmitForTimeout) {
      _testAutoSubmitTriggeredKeys.remove(autoSubmitKey);
    }
    if (visualPhase == 2 && remainingMs > 0) {
      _testTimedOutHomeworkKeys.remove(timeoutBadgeKey);
    }
    // 제한시간 만료 시 '자동 제출'은 M5 기기가 담당한다(시험 종료 알람 → 확인 시 제출).
    // 학습앱(플러터)은 서버/M5 상태를 따라가기만 하고 여기서 제출하지 않는다.
    // 시간 초과 표시(배지)는 그대로 유지한다.
    if (shouldAutoSubmitForTimeout) {
      _testTimedOutHomeworkKeys.add(timeoutBadgeKey);
    }
  }
  final bool showTimedOutBadge = isTestCard &&
      visualPhase == 1 &&
      _testTimedOutHomeworkKeys.contains(timeoutBadgeKey);
  final bool hasFinishedTestCycle =
      isTestCard && visualPhase == 1 && hw.confirmedAt != null;
  final bool showSubmittedEndedBadge = isTestCard &&
      !showRunningRemaining &&
      !showRunningExtraTime &&
      (visualPhase >= 3 || hasFinishedTestCycle);
  final bool showEndedBadge = showTimedOutBadge || showSubmittedEndedBadge;
  final String typeText = () {
    if (!showEndedBadge) return rawTypeText;
    if (rawTypeText == '-' || rawTypeText.isEmpty) return '테스트 종료';
    if (rawTypeText.contains('테스트 종료')) return rawTypeText;
    if (rawTypeText.contains('테스트')) {
      return rawTypeText.replaceFirst('테스트', '테스트 종료');
    }
    return '$rawTypeText · 테스트 종료';
  }();
  final String? flowChipOverrideText = showRunningRemaining
      ? '남은 ${remainingMinutes}분'
      : (showRunningExtraTime
          ? '추가 ${extraMinutes}분'
          : (showEndedBadge ? '종료' : null));
  final Color? flowChipOverrideTextColor = showRunningRemaining
      ? const Color(0xFF9FE3C6)
      : (showRunningExtraTime
          ? const Color(0xFFFFD39A)
          : (showEndedBadge ? const Color(0xFFC8D4D4) : null));
  final Color? flowChipOverrideBackgroundColor = showRunningRemaining
      ? const Color(0x1F4FBF97)
      : (showRunningExtraTime
          ? const Color(0x333A2A18)
          : (showEndedBadge ? const Color(0x332A3030) : null));
  final Border? flowChipOverrideBorder = showRunningRemaining
      ? Border.all(color: kDlgAccent, width: 1.05)
      : (showRunningExtraTime
          ? Border.all(color: const Color(0xFFB77A2C), width: 1.05)
          : (showEndedBadge
              ? Border.all(color: const Color(0xFF5F6D6D), width: 1)
              : null));

  String textbookKeyOfHomework(HomeworkItem item) {
    final bookId = (item.bookId ?? '').trim();
    final gradeLabel = (item.gradeLabel ?? '').trim();
    if (bookId.isEmpty || gradeLabel.isEmpty) return '';
    return '$bookId|$gradeLabel';
  }

  String resolveTargetGroupTextbookKey() {
    for (final child in groupChildren) {
      final key = textbookKeyOfHomework(child);
      if (key.isNotEmpty) return key;
    }
    final summaryKey = textbookKeyOfHomework(hw);
    return summaryKey;
  }

  final String targetGroupTextbookKey = resolveTargetGroupTextbookKey();

  bool canAcceptGroupChildDrag(
    HomeworkItem dragged, {
    HomeworkItem? targetBefore,
  }) {
    if (assignedItemIds.contains(dragged.id)) return false;
    if (dragged.status == HomeworkStatus.completed || dragged.phase != 1) {
      return false;
    }
    if (targetBefore != null) {
      if (targetBefore.id == dragged.id) return false;
      if (targetBefore.status == HomeworkStatus.completed ||
          targetBefore.phase != 1) {
        return false;
      }
    }
    if (resolvedGroupId.isEmpty) return false;
    final sourceGroupId =
        (HomeworkStore.instance.groupIdOfItem(dragged.id) ?? '').trim();
    if (sourceGroupId.isEmpty) return false;
    if (sourceGroupId == resolvedGroupId) return true;
    final draggedTextbookKey = textbookKeyOfHomework(dragged);
    if (draggedTextbookKey.isEmpty || targetGroupTextbookKey.isEmpty) {
      return false;
    }
    return draggedTextbookKey == targetGroupTextbookKey;
  }

  final double phase4Pulse = 0.5 + 0.5 * math.sin(2 * math.pi * tick);
  final Border fullBorder = (visualPhase == 3)
      ? Border.all(color: Colors.transparent, width: borderWMax)
      : (visualRunning
          ? Border.all(
              color: unifiedHomeworkAccent.withOpacity(0.9), width: borderWMax)
          : (visualPhase == 4
              ? Border.all(
                  color: Color.lerp(
                        cardTheme.idleBorderColor,
                        unifiedHomeworkAccent.withOpacity(0.9),
                        phase4Pulse,
                      ) ??
                      cardTheme.idleBorderColor,
                  width: borderWMax,
                )
              : (visualPhase == 1
                  ? Border.all(color: Colors.transparent, width: borderWMax)
                  : Border.all(
                      color: cardTheme.idleBorderColor, width: borderWMax))));
  // 둥근 모서리와 함께 쓰는 Border는 모든 면의 색상이 같아야 한다.
  // 확장부가 붙으면 외곽 테두리는 부모(_SlideableHomeworkChip)가 그리고,
  // 본체는 투명 테두리로 폭·레이아웃만 유지한다(이음새 세로선 방지).
  final Border border = attachRightExtension
      ? Border.all(color: Colors.transparent, width: borderWMax)
      : fullBorder;

  Widget row1 = ConstrainedBox(
    constraints: BoxConstraints(maxWidth: maxRowW),
    child: Row(
      children: [
        Expanded(
          child: Text(
            line2Left,
            style: titleStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 10),
        _buildFlowChip(
          displayFlowName,
          cardTheme: cardTheme,
          dueLabel: dueLabel,
          isHomeworkDue: isHomeworkDue,
          overrideText: flowChipOverrideText,
          overrideTextColor: flowChipOverrideTextColor,
          overrideBackgroundColor: flowChipOverrideBackgroundColor,
          overrideBorder: flowChipOverrideBorder,
        ),
      ],
    ),
  );

  Widget row2 = Padding(
    padding: const EdgeInsets.only(right: 5),
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxRowW - 5),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onGroupTitleTap,
              child: Text(
                titleText,
                style: metaStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  final String collapsedCountText =
      '${displayCount.isNotEmpty ? displayCount : '-'}문항';
  Widget collapsedRow3 = ConstrainedBox(
    constraints: BoxConstraints(maxWidth: maxRowW),
    child: Row(
      children: [
        Text(
          startDateText,
          style: secondaryRowStyle,
        ),
        const Spacer(),
        Text(line4PageText, style: secondaryRowStyle),
        const SizedBox(width: 8),
        Text(collapsedCountText, style: secondaryRowStyle),
      ],
    ),
  );

  Widget buildTypeLabelCell() {
    final style = secondaryRowStyle.copyWith(
      decoration: onTypeTap != null ? TextDecoration.underline : null,
      decorationColor: onTypeTap != null ? secondaryRowStyle.color : null,
    );
    final label = Text(
      typeText,
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (onTypeTap == null) {
      return Expanded(child: label);
    }
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTypeTap,
        child: label,
      ),
    );
  }

  Widget collapsedRow4 = ConstrainedBox(
    constraints: BoxConstraints(maxWidth: maxRowW),
    child: Row(
      children: [
        buildTypeLabelCell(),
        const SizedBox(width: 10),
        Text(
          assignmentCodeText,
          style: secondaryRowStyle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.right,
        ),
      ],
    ),
  );

  final bool progressEnabled = progressRate.enabled ||
      (hasGroupChildren
          ? groupChildren.any(_isMigratedHomeworkForProgress)
          : _isMigratedHomeworkForProgress(hw));
  final effectiveProgress = progressEnabled
      ? (progressRate.enabled
          ? progressRate
          : HomeworkGradingProgressRate.emptyEnabled(
              total: hasGroupChildren
                  ? groupChildren.fold<int>(
                      0,
                      (sum, child) => sum + math.max(0, child.count ?? 0),
                    )
                  : math.max(0, hw.count ?? 0),
            ))
      : HomeworkGradingProgressRate.disabled;
  Widget collapsedRow5 = ConstrainedBox(
    constraints: BoxConstraints(maxWidth: maxRowW),
    child: _HomeworkProgressIndicatorRow(
      enabled: effectiveProgress.enabled,
      advance: effectiveProgress.advanceRate,
      completion: effectiveProgress.completionRate,
      textStyle: secondaryRowStyle,
      cycleLabel: '${displayRepeatIndex}차',
    ),
  );

  // 접힌 카드 얼굴은 유지하고, 펼침 전용 영역만 heightFactor 로 드러낸다.
  final visibleGroupChildren = hasGroupChildren ? groupChildren.length : 0;

  String groupChildLabel(HomeworkItem child) {
    final title = child.title.trim();
    if (title.isNotEmpty) return title;
    final pageRaw = (child.page ?? '').trim();
    if (pageRaw.isNotEmpty) return 'p.$pageRaw';
    return '(제목 없음)';
  }

  String groupChildPageLabel(HomeworkItem child) {
    final pageRaw = (child.page ?? '').trim();
    return pageRaw.isEmpty ? '-' : 'p.$pageRaw';
  }

  String groupChildCountLabel(HomeworkItem child) {
    final count = child.count;
    if (count == null || count <= 0) return '-';
    return '${count}문항';
  }

  String groupChildPageCountLabel(HomeworkItem child) {
    final page = groupChildPageLabel(child);
    final count = groupChildCountLabel(child);
    if (page == '-' && count == '-') return '-';
    if (page == '-') return count;
    if (count == '-') return page;
    return '$page $count';
  }

  Widget buildGroupChildRow(HomeworkItem child, int index) {
    final bool childHasAssignment = assignedItemIds.contains(child.id);
    final bool canDragChild = onGroupChildDropBefore != null &&
        child.status != HomeworkStatus.completed &&
        child.phase == 1 &&
        !childHasAssignment;
    final bool canTapPage = onGroupChildPageTap != null;

    Widget buildRowCore({
      required bool enablePageTap,
    }) {
      final pageCountStyle = secondaryRowStyle.copyWith(
        decoration:
            enablePageTap ? TextDecoration.underline : TextDecoration.none,
      );
      return ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxRowW),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${index + 1}. ',
                    style: secondaryRowStyle,
                  ),
                  Expanded(
                    child: LatexTextRenderer(
                      groupChildLabel(child),
                      style: secondaryRowStyle,
                      softWrap: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: enablePageTap
                    ? () => onGroupChildPageTap?.call(child)
                    : null,
                child: Text(
                  // 2번째 줄: 페이지 → 문항수, 오른쪽 끝에 붙임
                  groupChildPageCountLabel(child),
                  style: pageCountStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final baseRow = buildRowCore(
      enablePageTap: canTapPage,
    );

    Widget rowContent = baseRow;
    if (canDragChild) {
      rowContent = LongPressDraggable<HomeworkItem>(
        data: child,
        maxSimultaneousDrags: 1,
        feedback: Material(
          color: Colors.transparent,
          child: Opacity(
            opacity: 0.95,
            child: Container(
              width: maxRowW,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: cardTheme.dragFeedbackBackground,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: cardTheme.dragFeedbackBorder),
              ),
              child: buildRowCore(enablePageTap: false),
            ),
          ),
        ),
        childWhenDragging: Opacity(
          opacity: 0.32,
          child: buildRowCore(
            enablePageTap: canTapPage,
          ),
        ),
        child: baseRow,
      );
    }

    if (onGroupChildDropBefore == null) {
      return rowContent;
    }

    return DragTarget<HomeworkItem>(
      onWillAcceptWithDetails: (details) =>
          canAcceptGroupChildDrag(details.data, targetBefore: child),
      onAcceptWithDetails: (details) {
        unawaited(onGroupChildDropBefore(details.data, child));
      },
      builder: (context, candidateData, rejectedData) {
        final highlighted = candidateData.isNotEmpty;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            rowContent,
            Positioned(
              left: 22,
              right: 0,
              top: 0,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 90),
                  curve: Curves.easeOut,
                  opacity: highlighted ? 1.0 : 0.0,
                  child: Container(
                    height: 2,
                    decoration: BoxDecoration(
                      color: const Color(0xFF4FBF97),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // 2~3번째 줄 간격(7)을 하위과제 요약 줄까지 동일하게 쓴다.
  const double expandLineGap = 7;

  Widget expandPairRow(String left, String right) {
    // 2단 분할이 아니라, 왼쪽 텍스트 + 오른쪽 끝 붙임.
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxRowW),
      child: Row(
        children: [
          Expanded(
            child: Text(
              left,
              style: secondaryRowStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            right,
            style: secondaryRowStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  final inspectionDateText = (() {
    final raw = (dueLabel ?? '').trim();
    if (raw.isNotEmpty) return raw;
    return isHomeworkDue ? '검사일 미정' : '';
  })();

  Widget expandInspectionDateRow() {
    final row = expandPairRow('검사 날짜', inspectionDateText);
    if (onInspectionDateTap == null) return row;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onInspectionDateTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: row,
        ),
      ),
    );
  }

  final List<Widget> expandPanelChildren = [
    const SizedBox(height: expandLineGap),
    expandPairRow(
      '$startedAtText 시작',
      '${_formatKoreanDurationMs(progressMsForDisplay)}째',
    ),
    const SizedBox(height: expandLineGap),
    expandPairRow(
      '총 ${_formatKoreanDurationMs(totalMs)}',
      '권장 $recommendedTimeText',
    ),
    const SizedBox(height: expandLineGap),
    expandPairRow(
      '검사 ${hw.checkCount}회',
      '숙제 ${homeworkCount}회',
    ),
    if (isHomeworkDue && inspectionDateText.isNotEmpty) ...[
      const SizedBox(height: expandLineGap),
      expandInspectionDateRow(),
    ],
    if (hasGroupChildren) ...[
      const SizedBox(height: expandLineGap),
      expandPairRow(
        '하위과제 ${groupChildren.length}개',
        '${displayRepeatIndex}회차',
      ),
      const SizedBox(height: 24),
      for (int i = 0; i < visibleGroupChildren; i++) ...[
        buildGroupChildRow(groupChildren[i], i),
        if (i != visibleGroupChildren - 1) ...[
          const SizedBox(height: 26),
          Container(
            width: maxRowW,
            height: 1.3,
            color: cardTheme.dividerColor,
          ),
          const SizedBox(height: 26),
        ],
        const SizedBox(height: 6),
      ],
    ],
  ];

  final BorderRadius chipRadius = attachRightExtension
      ? const BorderRadius.only(
          topLeft: Radius.circular(12),
          bottomLeft: Radius.circular(12),
        )
      : BorderRadius.circular(12);

  Widget chipInner = _HomeworkExpandingCard(
    expanded: isExpanded,
    padding: const EdgeInsets.fromLTRB(leftPad, 16, rightPad, 8),
    decoration: BoxDecoration(
      color: groupedCardBackground,
      borderRadius: chipRadius,
      border: border,
      boxShadow: [
        if (!visualRunning && visualPhase == 4)
          BoxShadow(
            color: unifiedHomeworkAccent.withOpacity(0.08 + 0.14 * phase4Pulse),
            blurRadius: 14,
            spreadRadius: 0.5,
          ),
      ],
    ),
    header: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row1,
        const SizedBox(height: 19),
        row2,
        const SizedBox(height: 7),
        collapsedRow3,
      ],
    ),
    collapsedBody: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        collapsedRow4,
        const SizedBox(height: 8),
        collapsedRow5,
      ],
    ),
    expandedBody: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: expandPanelChildren,
    ),
  );

  if (!visualRunning && visualPhase == 3 && !attachRightExtension) {
    chipInner = CustomPaint(
      foregroundPainter: _RotatingBorderPainter(
          baseColor: unifiedHomeworkAccent,
          tick: tick,
          strokeWidth: 3.0,
          cornerRadius: 12.0),
      child: chipInner,
    );
  }

  if (isPendingConfirm) {
    chipInner = Stack(
      children: [
        chipInner,
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                color: cardTheme.pendingConfirmOverlay,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Icon(
                  isCompleteCheckbox
                      ? Icons.check_circle
                      : Icons.check_circle_outline,
                  color: isCompleteCheckbox
                      ? const Color(0xFF4CAF50)
                      : const Color(0xFF1B6B63),
                  size: 48,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  if (onGroupChildDropToEnd != null && !isPendingConfirm) {
    final dropTargetChild = chipInner;
    chipInner = DragTarget<HomeworkItem>(
      onWillAcceptWithDetails: (details) =>
          canAcceptGroupChildDrag(details.data),
      onAcceptWithDetails: (details) {
        unawaited(onGroupChildDropToEnd(details.data));
      },
      builder: (context, candidateData, rejectedData) {
        final highlighted = candidateData.isNotEmpty;
        return Stack(
          children: [
            dropTargetChild,
            Positioned(
              left: leftPad,
              right: rightPad,
              bottom: 8,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 90),
                  curve: Curves.easeOut,
                  opacity: highlighted ? 1.0 : 0.0,
                  child: Container(
                    height: 2,
                    decoration: BoxDecoration(
                      color: const Color(0xFF4FBF97),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  return SizedBox(width: fixedWidth, child: chipInner);
}

/// 수행 기준 차수: 첫 시도 1차, 확인 후 재수행부터 2차.
/// 대기(1)·확인(4)은 끝난 시도 수를 유지하고, 수행(2)·제출(3)에서 +1.
int _homeworkPerformanceAttemptIndex({
  required int checkCount,
  required int phase,
}) {
  final checks = checkCount < 0 ? 0 : checkCount;
  if (phase == 2 || phase == 3) return math.max(1, checks + 1);
  return math.max(1, checks);
}

/// 홈 과제 카드용 진행(빈 인디케이터 색)+수행(상세 폰트 색) 겹침 바.
class _HomeworkProgressIndicatorRow extends StatelessWidget {
  const _HomeworkProgressIndicatorRow({
    required this.enabled,
    required this.advance,
    required this.completion,
    required this.textStyle,
    required this.cycleLabel,
  });

  final bool enabled;
  final double advance;
  final double completion;
  final TextStyle textStyle;
  final String cycleLabel;

  @override
  Widget build(BuildContext context) {
    // 진행률(빈 인디케이터 색)=수행분/전체, 수행률(상세 폰트 색·%)=정답/수행분.
    // 미수행·미채점 형제가 있으면 진행만 낮고 수행은 100%가 될 수 있다.
    // 교재 카드처럼 수행을 진행에 클램프하면 전원 정답도 57%처럼 보인다.
    final a = advance.clamp(0.0, 1.0);
    final c = completion.clamp(0.0, 1.0);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final detailColor = textStyle.color ?? const Color(0xFF8FA1A1);
    final labelColor =
        enabled ? detailColor : detailColor.withValues(alpha: 0.38);
    // 예전 빈 트랙 색 → 진행률 채움.
    final progressColor = enabled
        ? (isDark ? Colors.white12 : Colors.black12)
        : (isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.06));
    // 수행률 = 카드 상세 내역과 같은 폰트 색.
    final performanceColor =
        enabled ? detailColor : detailColor.withValues(alpha: 0.28);
    final percentText = enabled ? '${(c * 100).round()}%' : '-';

    // 한글 글리프 시각 중심이 레이아웃 중심보다 아래로 보이므로 바를 살짝 내린다.
    const opticalNudge = Offset(0, 1.5);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          cycleLabel,
          style: textStyle.copyWith(
            color: labelColor,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Transform.translate(
            offset: opticalNudge,
            child: Opacity(
              opacity: enabled ? 1 : 0.55,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: SizedBox(
                  height: 8,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const ColoredBox(color: Colors.transparent),
                      FractionallySizedBox(
                        widthFactor: a,
                        alignment: Alignment.centerLeft,
                        child: ColoredBox(color: progressColor),
                      ),
                      FractionallySizedBox(
                        widthFactor: c,
                        alignment: Alignment.centerLeft,
                        child: ColoredBox(color: performanceColor),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          percentText,
          textAlign: TextAlign.right,
          style: textStyle.copyWith(
            color: labelColor,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.8,
          ),
        ),
      ],
    );
  }
}

/// 카드(테두리·배경) 자체가 커지며 펼쳐지게 한다.
/// heightFactor 롤 공개 대신 AnimatedSize 로 박스 높이를 보간한다.
class _HomeworkExpandingCard extends StatelessWidget {
  const _HomeworkExpandingCard({
    required this.expanded,
    required this.padding,
    required this.decoration,
    required this.header,
    required this.collapsedBody,
    required this.expandedBody,
  });

  final bool expanded;
  final EdgeInsetsGeometry padding;
  final Decoration decoration;
  final Widget header;
  final Widget collapsedBody;
  final Widget expandedBody;

  @override
  Widget build(BuildContext context) {
    // decoration 을 바깥에 두어 테두리·배경이 높이와 함께 늘어나게 한다.
    return Container(
      clipBehavior: Clip.hardEdge,
      constraints:
          const BoxConstraints(minHeight: _homeworkChipCollapsedHeight),
      padding: padding,
      alignment: Alignment.topLeft,
      decoration: decoration,
      child: AnimatedSize(
        duration: _homeworkChipExpandDuration,
        curve: _homeworkChipExpandCurve,
        alignment: Alignment.topCenter,
        clipBehavior: Clip.hardEdge,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            header,
            if (expanded) expandedBody else collapsedBody,
          ],
        ),
      ),
    );
  }
}

class _HomeworkDraftRevealClipper extends CustomClipper<Rect> {
  const _HomeworkDraftRevealClipper(this.width);

  final double width;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, width, size.height);

  @override
  bool shouldReclip(covariant _HomeworkDraftRevealClipper oldClipper) =>
      oldClipper.width != width;
}

// 회전 보더 페인터: 내부 child 레이아웃을 바꾸지 않고 외곽선만 회전시켜 그림
class _SolidRoundedBorderPainter extends CustomPainter {
  final Color color;
  final double strokeWidth;
  final double cornerRadius;
  _SolidRoundedBorderPainter({
    required this.color,
    this.strokeWidth = 3.0,
    this.cornerRadius = 12.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(strokeWidth / 2),
      Radius.circular(cornerRadius),
    );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..isAntiAlias = true;
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(covariant _SolidRoundedBorderPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.cornerRadius != cornerRadius;
  }
}

class _RotatingBorderPainter extends CustomPainter {
  final Color baseColor;
  final double tick; // 0..1
  final double strokeWidth;
  final double cornerRadius;
  _RotatingBorderPainter(
      {required this.baseColor,
      required this.tick,
      this.strokeWidth = 2.0,
      this.cornerRadius = 8.0});
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectXY(
        rect.deflate(strokeWidth / 2), cornerRadius, cornerRadius);
    final shader = SweepGradient(
      startAngle: 0.0,
      endAngle: 2 * math.pi,
      transform: GradientRotation(2 * math.pi * tick),
      colors: [
        baseColor.withOpacity(0.1),
        baseColor.withOpacity(0.9),
        baseColor.withOpacity(0.1),
      ],
      stops: const [0.0, 0.5, 1.0],
    ).createShader(rect);
    final paint = Paint()
      ..shader = shader
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..isAntiAlias = true;
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(covariant _RotatingBorderPainter oldDelegate) {
    return oldDelegate.tick != tick ||
        oldDelegate.baseColor != baseColor ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.cornerRadius != cornerRadius;
  }
}

class _AttendingStudent {
  final String name;
  final Color color;
  final String id;
  final AttendanceRecord record;
  _AttendingStudent({
    required this.id,
    required this.name,
    required this.color,
    required this.record,
  });
}

class _ReservedHomeworkGroupSection {
  final String groupKey;
  final String? groupId;
  final String title;
  final List<MapEntry<HomeworkAssignmentDetail, HomeworkItem>> entries;

  const _ReservedHomeworkGroupSection({
    required this.groupKey,
    required this.groupId,
    required this.title,
    required this.entries,
  });
}

/// 추가검사(자의로 미리 해온 숙제) 후보 그룹.
class _ExtraCheckGroupCandidate {
  final HomeworkGroup group;
  final HomeworkItem summary;
  final List<HomeworkItem> children;
  final String title;
  final String flowLabel;
  final String bookAndCourse;
  final DateTime? dueDate;
  final int progress;

  const _ExtraCheckGroupCandidate({
    required this.group,
    required this.summary,
    required this.children,
    required this.title,
    required this.flowLabel,
    required this.bookAndCourse,
    required this.dueDate,
    required this.progress,
  });
}

class _HomeworkOverviewEntry {
  /// 그룹 id 또는 단독 과제 `item:{id}` 키.
  final String entryKey;
  final String homeworkItemId;
  final List<String> itemIds;
  final String title;
  final DateTime assignedAt;
  final DateTime? dueDate;
  final bool checkedToday;
  final DateTime? checkedAt;
  final int progress;
  final bool isActive;
  final int childCount;
  final String flowLabel;
  final String overviewLine1Left;
  final String expandLine4Left;
  final String expandLine4Right;
  final String expandLine5Left;
  final String expandLine5Right;
  final List<_HomeworkOverviewCompletedChildEntry> expandChildren;

  const _HomeworkOverviewEntry({
    required this.entryKey,
    required this.homeworkItemId,
    required this.itemIds,
    required this.title,
    required this.assignedAt,
    required this.dueDate,
    required this.checkedToday,
    required this.checkedAt,
    required this.progress,
    required this.isActive,
    required this.childCount,
    required this.flowLabel,
    required this.overviewLine1Left,
    required this.expandLine4Left,
    required this.expandLine4Right,
    required this.expandLine5Left,
    required this.expandLine5Right,
    required this.expandChildren,
  });
}

class _HomeworkOverviewCompletedGroupEntry {
  final String groupId;
  final DateTime completedAt;
  final String line1Left;
  final String line1Right;
  final String line2Left;
  final String line2Right;
  final String line3Left;
  final String line3Right;
  final String line4Left;
  final String line4Right;
  final String line5Left;
  final String line5Right;
  final List<_HomeworkOverviewCompletedChildEntry> children;

  const _HomeworkOverviewCompletedGroupEntry({
    required this.groupId,
    required this.completedAt,
    required this.line1Left,
    required this.line1Right,
    required this.line2Left,
    required this.line2Right,
    required this.line3Left,
    required this.line3Right,
    required this.line4Left,
    required this.line4Right,
    required this.line5Left,
    required this.line5Right,
    required this.children,
  });
}

class _HomeworkOverviewCompletedChildEntry {
  final String title;
  final String pageCount;
  final String memo;

  const _HomeworkOverviewCompletedChildEntry({
    required this.title,
    required this.pageCount,
    required this.memo,
  });
}

class _GradingHistoryEntry {
  final String studentId;
  final String studentName;
  final String displayTitle;
  final String meta;
  final DateTime eventAt;
  final List<String> itemIds;

  const _GradingHistoryEntry({
    required this.studentId,
    required this.studentName,
    required this.displayTitle,
    required this.meta,
    required this.eventAt,
    required this.itemIds,
  });
}

class _M5BindingHistoryEntry {
  final String id;
  final String studentId;
  final String studentName;
  final String deviceId;
  final bool active;
  final DateTime boundAt;
  final DateTime? unboundAt;
  final DateTime updatedAt;

  const _M5BindingHistoryEntry({
    required this.id,
    required this.studentId,
    required this.studentName,
    required this.deviceId,
    required this.active,
    required this.boundAt,
    required this.unboundAt,
    required this.updatedAt,
  });
}

DateTime? _tryParseM5BindingDateTime(Object? raw) {
  final text = (raw ?? '').toString().trim();
  if (text.isEmpty || text.toLowerCase() == 'null') return null;
  return DateTime.tryParse(text);
}

String _compactM5DeviceLabel(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '-';
  final compact =
      trimmed.replaceFirst(RegExp(r'^m5-device-', caseSensitive: false), '');
  return compact.isEmpty ? trimmed : compact;
}

DateTime _toKstDateTime(DateTime value) {
  return value.toUtc().add(const Duration(hours: 9));
}

String _formatM5BindingDateTimeKst(DateTime value) {
  return _formatDateTime(_toKstDateTime(value));
}

Future<List<_M5BindingHistoryEntry>> _loadM5BindingHistoryEntries() async {
  final academyId = await TenantService.instance.getActiveAcademyId() ??
      await TenantService.instance.ensureActiveAcademy();
  final rows = await Supabase.instance.client
      .from('m5_device_bindings')
      .select(
          'id, student_id, device_id, active, bound_at, unbound_at, updated_at, created_at')
      .eq('academy_id', academyId)
      .order('bound_at', ascending: false)
      .limit(240);
  final studentNameById = <String, String>{
    for (final row in DataManager.instance.students)
      row.student.id: row.student.name.trim().isEmpty ? '학생' : row.student.name
  };
  final entries = <_M5BindingHistoryEntry>[];
  for (final raw in (rows as List<dynamic>)) {
    if (raw is! Map<String, dynamic>) continue;
    final id = (raw['id'] ?? '').toString().trim();
    final studentId = (raw['student_id'] ?? '').toString().trim();
    final deviceId = (raw['device_id'] ?? '').toString().trim();
    if (id.isEmpty || studentId.isEmpty || deviceId.isEmpty) continue;
    final boundAt = _tryParseM5BindingDateTime(raw['bound_at']) ??
        _tryParseM5BindingDateTime(raw['created_at']) ??
        _tryParseM5BindingDateTime(raw['updated_at']) ??
        DateTime.now();
    final unboundAt = _tryParseM5BindingDateTime(raw['unbound_at']);
    final updatedAt = _tryParseM5BindingDateTime(raw['updated_at']) ?? boundAt;
    final studentName = (studentNameById[studentId] ?? '').trim();
    entries.add(
      _M5BindingHistoryEntry(
        id: id,
        studentId: studentId,
        studentName: studentName.isEmpty ? '학생' : studentName,
        deviceId: deviceId,
        active: raw['active'] == true,
        boundAt: boundAt,
        unboundAt: unboundAt,
        updatedAt: updatedAt,
      ),
    );
  }
  entries.sort((a, b) {
    final timeCmp = b.boundAt.compareTo(a.boundAt);
    if (timeCmp != 0) return timeCmp;
    final nameCmp = a.studentName.compareTo(b.studentName);
    if (nameCmp != 0) return nameCmp;
    return a.id.compareTo(b.id);
  });
  return entries;
}

Future<void> _showM5BindingHistoryDialog({
  required BuildContext context,
}) async {
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        backgroundColor: kDlgBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'M5 바인딩 히스토리',
          style: TextStyle(
            color: kDlgText,
            fontSize: 18,
            fontWeight: FontWeight.w900,
          ),
        ),
        content: SizedBox(
          width: 760,
          child: FutureBuilder<List<_M5BindingHistoryEntry>>(
            future: _loadM5BindingHistoryEntries(),
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const SizedBox(
                  height: 180,
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        valueColor: AlwaysStoppedAnimation<Color>(kDlgAccent),
                      ),
                    ),
                  ),
                );
              }
              if (snapshot.hasError) {
                return const SizedBox(
                  height: 180,
                  child: Center(
                    child: Text(
                      'M5 바인딩 이력을 불러오지 못했습니다.',
                      style: TextStyle(
                        color: kDlgTextSub,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                );
              }
              final entries = snapshot.data ?? const <_M5BindingHistoryEntry>[];
              if (entries.isEmpty) {
                return const SizedBox(
                  height: 180,
                  child: Center(
                    child: Text(
                      '최근 M5 바인딩 이력이 없습니다.',
                      style: TextStyle(
                        color: kDlgTextSub,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                );
              }
              final listHeight = math.min(
                MediaQuery.of(dialogContext).size.height * 0.62,
                620.0,
              );
              return SizedBox(
                height: listHeight,
                child: ListView.separated(
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    final releasedAt = entry.unboundAt ??
                        (entry.active ? null : entry.updatedAt);
                    final statusLabel = entry.active ? '활성' : '해제';
                    final statusBorder = entry.active
                        ? const Color(0xFF4DBD7A)
                        : const Color(0xFF4E6166);
                    final statusFg = entry.active
                        ? const Color(0xFFE4F8EC)
                        : const Color(0xFFC2CCCD);
                    final statusBg = entry.active
                        ? const Color(0x224DBD7A)
                        : const Color(0x2236494D);
                    return Container(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                      decoration: BoxDecoration(
                        color: const Color(0x221D2B2C),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF31464C)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${entry.studentName} · 기기 ${_compactM5DeviceLabel(entry.deviceId)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: kDlgText,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '바인딩 ${_formatM5BindingDateTimeKst(entry.boundAt)}'
                                  '${releasedAt == null ? '' : ' · 해제 ${_formatM5BindingDateTimeKst(releasedAt)}'}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: kDlgTextSub,
                                    fontSize: 13.2,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '원본 ID ${entry.deviceId}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xFF7F8C8C),
                                    fontSize: 12.3,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: statusBg,
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(color: statusBorder),
                            ),
                            child: Text(
                              statusLabel,
                              style: TextStyle(
                                color: statusFg,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text(
              '닫기',
              style: TextStyle(
                color: kDlgTextSub,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      );
    },
  );
}

List<_GradingHistoryEntry> _collectGradingHistoryEntries({
  required List<String> attendingStudentIds,
  required Map<String, String> studentNamesById,
}) {
  bool isHistoryCandidate(HomeworkItem hw) {
    if (hw.phase == 4 && hw.status != HomeworkStatus.completed) return true;
    if (hw.status == HomeworkStatus.completed) return true;
    if (hw.phase == 1 && hw.confirmedAt != null) return true;
    return false;
  }

  DateTime? historyEventAt(HomeworkItem hw) {
    if (hw.phase == 4 && hw.status != HomeworkStatus.completed) {
      return hw.confirmedAt ?? hw.updatedAt ?? hw.createdAt;
    }
    if (hw.status == HomeworkStatus.completed) {
      return hw.completedAt ??
          hw.waitingAt ??
          hw.confirmedAt ??
          hw.updatedAt ??
          hw.createdAt;
    }
    if (hw.phase == 1 && hw.confirmedAt != null) {
      return hw.waitingAt ?? hw.confirmedAt ?? hw.updatedAt ?? hw.createdAt;
    }
    return null;
  }

  String normalizeTitle(String raw, {String fallback = '(제목 없음)'}) {
    final trimmed = raw.trim();
    return trimmed.isEmpty ? fallback : trimmed;
  }

  final recentWindowStart = DateTime.now().subtract(const Duration(days: 7));
  final mergedInfoByKey = <String,
      ({
    String studentId,
    String studentName,
    String displayTitle,
    DateTime eventAt,
  })>{};
  final mergedItemIdsByKey = <String, Set<String>>{};
  final mergedTypesByKey = <String, Set<String>>{};
  final mergedPagesByKey = <String, Set<String>>{};

  final entries = <_GradingHistoryEntry>[];
  for (final studentId in attendingStudentIds) {
    final studentName = studentNamesById[studentId] ?? '학생';
    final items = HomeworkStore.instance.items(studentId);
    for (final hw in items) {
      if (!isHistoryCandidate(hw)) continue;
      final eventAt = historyEventAt(hw);
      if (eventAt == null || eventAt.isBefore(recentWindowStart)) {
        continue;
      }
      final groupId =
          (HomeworkStore.instance.groupIdOfItem(hw.id) ?? '').trim();
      final key = groupId.isEmpty
          ? 'item:$studentId:${hw.id}'
          : 'group:$studentId:$groupId';
      final groupTitle = groupId.isEmpty
          ? ''
          : (HomeworkStore.instance.groupById(studentId, groupId)?.title ?? '')
              .trim();
      final displayTitle =
          normalizeTitle(groupTitle.isEmpty ? hw.title : groupTitle);
      mergedItemIdsByKey.putIfAbsent(key, () => <String>{}).add(hw.id);
      final type = (hw.type ?? '').trim();
      if (type.isNotEmpty) {
        mergedTypesByKey.putIfAbsent(key, () => <String>{}).add(type);
      }
      final page = (hw.page ?? '').trim();
      if (page.isNotEmpty) {
        mergedPagesByKey.putIfAbsent(key, () => <String>{}).add(page);
      }
      final prev = mergedInfoByKey[key];
      if (prev == null || eventAt.isAfter(prev.eventAt)) {
        mergedInfoByKey[key] = (
          studentId: studentId,
          studentName: studentName,
          displayTitle: displayTitle,
          eventAt: eventAt,
        );
      }
    }
  }

  for (final entry in mergedInfoByKey.entries) {
    final key = entry.key;
    final info = entry.value;
    final itemIds = (mergedItemIdsByKey[key] ?? const <String>{})
        .toList(growable: false)
      ..sort();
    final itemCount = itemIds.length;
    final typeSet = mergedTypesByKey[key] ?? const <String>{};
    final pageSet = mergedPagesByKey[key] ?? const <String>{};
    final types = typeSet.toList(growable: false)..sort();
    final metaParts = <String>[];
    if (itemCount > 1) {
      metaParts.add('하위 ${itemCount}개');
    }
    if (types.isNotEmpty) {
      if (types.length == 1) {
        metaParts.add(types.first);
      } else {
        metaParts.add('유형 ${types.length}개');
      }
    }
    if (pageSet.isNotEmpty) {
      final pages = pageSet.toList(growable: false)..sort();
      final preview = pages.take(2).map((e) => 'p.$e').join(', ');
      if (pages.length <= 2) {
        metaParts.add(preview);
      } else {
        metaParts.add('$preview 외 ${pages.length - 2}');
      }
    }
    entries.add(
      _GradingHistoryEntry(
        studentId: info.studentId,
        studentName: info.studentName,
        displayTitle: info.displayTitle,
        meta: metaParts.isEmpty ? '세부 정보 없음' : metaParts.join(' · '),
        eventAt: info.eventAt,
        itemIds: itemIds,
      ),
    );
  }
  entries.sort((a, b) {
    final timeCmp = b.eventAt.compareTo(a.eventAt);
    if (timeCmp != 0) return timeCmp;
    final nameCmp = a.studentName.compareTo(b.studentName);
    if (nameCmp != 0) return nameCmp;
    return a.displayTitle.compareTo(b.displayTitle);
  });
  return entries;
}

Future<void> _showGradingHistoryDialog({
  required BuildContext context,
  required List<String> attendingStudentIds,
  required Map<String, String> studentNamesById,
}) async {
  final cancellingKeys = <String>{};
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (dialogContext, setLocalState) {
          return AlertDialog(
            backgroundColor: kDlgBg,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text(
              '이전 채점 과제',
              style: TextStyle(
                color: kDlgText,
                fontSize: 18,
                fontWeight: FontWeight.w900,
              ),
            ),
            content: SizedBox(
              width: 760,
              child: ValueListenableBuilder<int>(
                valueListenable: HomeworkStore.instance.revision,
                builder: (context, _, __) {
                  final entries = _collectGradingHistoryEntries(
                    attendingStudentIds: attendingStudentIds,
                    studentNamesById: studentNamesById,
                  );
                  if (entries.isEmpty) {
                    return const SizedBox(
                      height: 180,
                      child: Center(
                        child: Text(
                          '최근 7일 내 채점 이력이 없습니다.',
                          style: TextStyle(
                            color: kDlgTextSub,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    );
                  }
                  final listHeight = math.min(
                      MediaQuery.of(dialogContext).size.height * 0.62, 620.0);
                  return SizedBox(
                    height: listHeight,
                    child: ListView.separated(
                      itemCount: entries.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        final key =
                            '${entry.studentId}|${entry.itemIds.join(',')}';
                        final isCancelling = cancellingKeys.contains(key);
                        return Container(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                          decoration: BoxDecoration(
                            color: const Color(0x221D2B2C),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF31464C)),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      entry.displayTitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: kDlgText,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${entry.studentName} · ${_formatDateTime(entry.eventAt)}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: kDlgTextSub,
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      entry.meta,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Color(0xFF7F8C8C),
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              OutlinedButton(
                                onPressed: isCancelling
                                    ? null
                                    : () async {
                                        setLocalState(() {
                                          cancellingKeys.add(key);
                                        });
                                        try {
                                          var rollbackCount = 0;
                                          for (final itemId in entry.itemIds) {
                                            HomeworkStore.instance
                                                .clearAutoCompleteOnNextWaiting(
                                              itemId,
                                            );
                                            final rollbackDecrement =
                                                await HomeworkAssignmentStore
                                                    .instance
                                                    .rollbackLatestCheckForItem(
                                              studentId: entry.studentId,
                                              homeworkItemId: itemId,
                                            );
                                            if ((rollbackDecrement ?? 0) > 0) {
                                              rollbackCount +=
                                                  rollbackDecrement ?? 0;
                                            }
                                          }
                                          await HomeworkStore.instance
                                              .reloadStudentHomework(
                                            entry.studentId,
                                          );
                                          final restoredCount =
                                              await HomeworkStore.instance
                                                  .restoreItemsAfterGradingCancel(
                                            entry.studentId,
                                            entry.itemIds,
                                          );
                                          if (!dialogContext.mounted) return;
                                          if (restoredCount == 0) {
                                            _showHomeworkChipSnackBar(
                                              dialogContext,
                                              '되돌릴 채점 대상을 찾지 못했습니다. 다시 시도해 주세요.',
                                            );
                                            return;
                                          }
                                          _showHomeworkChipSnackBar(
                                            dialogContext,
                                            rollbackCount > 0
                                                ? '채점 ${restoredCount}건을 대기 상태로 되돌렸어요. 검사 기록도 조정했습니다.'
                                                : '채점 ${restoredCount}건을 대기 상태로 되돌렸어요.',
                                          );
                                        } finally {
                                          if (dialogContext.mounted) {
                                            setLocalState(() {
                                              cancellingKeys.remove(key);
                                            });
                                          }
                                        }
                                      },
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFFE57373),
                                  side: const BorderSide(
                                    color: Color(0xFFE57373),
                                  ),
                                ),
                                child: isCancelling
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Text('채점 취소'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
                child: const Text('닫기'),
              ),
            ],
          );
        },
      );
    },
  );
}

/// 과제현황 활성 카드: 삭제 라벨은 고정, 카드만 [revealWidth]만큼 왼쪽으로 이동.
class _OverviewSwipeToDelete extends StatefulWidget {
  const _OverviewSwipeToDelete({
    super.key,
    required this.child,
    required this.onDeleteConfirmed,
    this.revealWidth = 76,
  });

  final Widget child;
  final Future<bool> Function() onDeleteConfirmed;
  final double revealWidth;

  @override
  State<_OverviewSwipeToDelete> createState() => _OverviewSwipeToDeleteState();
}

class _OverviewSwipeToDeleteState extends State<_OverviewSwipeToDelete> {
  double _offset = 0;
  bool _dragging = false;

  Future<void> _endDrag(DragEndDetails details) async {
    final vx = details.primaryVelocity ?? 0.0;
    final shouldOpen = _offset <= -widget.revealWidth * 0.55 || vx < -650;
    if (shouldOpen) {
      setState(() {
        _offset = -widget.revealWidth;
        _dragging = false;
      });
      final deleted = await widget.onDeleteConfirmed();
      if (!mounted) return;
      if (deleted) return;
    }
    setState(() {
      _offset = 0;
      _dragging = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        children: [
          Positioned.fill(
            child: Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: widget.revealWidth,
                child: ColoredBox(
                  color: const Color(0x33E57373),
                  child: const Center(
                    child: Text(
                      '삭제',
                      style: TextStyle(
                        color: Color(0xFFFF8A80),
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                        height: 1.1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          AnimatedContainer(
            duration:
                _dragging ? Duration.zero : const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            transform: Matrix4.translationValues(_offset, 0, 0),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (details) {
                final next = (_offset + details.delta.dx)
                    .clamp(-widget.revealWidth, 0.0);
                setState(() {
                  _offset = next;
                  _dragging = true;
                });
              },
              onHorizontalDragEnd: _endDrag,
              child: widget.child,
            ),
          ),
        ],
      ),
    );
  }
}

class _SlideableHomeworkChip extends StatefulWidget {
  final Widget child;
  final Widget? extension;
  final CustomPainter? foregroundPainter;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onSecondaryTap;
  final VoidCallback? onDoubleTap;
  final VoidCallback onSlideDown;
  final Future<void> Function() onSlideUp;
  final bool canSlideDown;
  final bool canSlideUp;
  final String downLabel;
  final String upLabel;
  final Color downColor;
  final Color upColor;
  final double maxSlide;
  final bool showUpArrowWhenLabelEmpty;
  final String upSubLabel;

  const _SlideableHomeworkChip({
    super.key,
    required this.child,
    this.extension,
    this.foregroundPainter,
    required this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.onDoubleTap,
    required this.onSlideDown,
    required this.onSlideUp,
    required this.canSlideDown,
    required this.canSlideUp,
    required this.downLabel,
    required this.upLabel,
    required this.downColor,
    required this.upColor,
    required this.maxSlide,
    this.showUpArrowWhenLabelEmpty = false,
    this.upSubLabel = '',
  });

  @override
  State<_SlideableHomeworkChip> createState() => _SlideableHomeworkChipState();
}

class _SlideableHomeworkChipState extends State<_SlideableHomeworkChip> {
  double _offset = 0.0;
  bool _dragging = false;

  void _updateOffset(double delta) {
    final next = (_offset + delta).clamp(-widget.maxSlide, widget.maxSlide);
    setState(() {
      _offset = next;
      _dragging = true;
    });
  }

  Future<void> _endDrag(DragEndDetails details) async {
    final vx = details.primaryVelocity ?? 0.0;
    final double absOffset = _offset.abs();
    final bool isRight = _offset > 0;
    final bool isLeft = _offset < 0;
    final bool trigger =
        absOffset >= widget.maxSlide * 0.48 || vx.abs() > 800.0;

    if (trigger) {
      setState(() {
        _offset = 0.0;
        _dragging = false;
      });
      if (isRight && widget.canSlideDown) {
        widget.onSlideDown();
      } else if (isLeft && widget.canSlideUp) {
        await widget.onSlideUp();
      }
      return;
    }
    setState(() {
      _offset = 0.0;
      _dragging = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final double progress = (_offset.abs() / widget.maxSlide).clamp(0.0, 1.0);
    final bool isRight = _offset > 0;
    final bool isLeft = _offset < 0;
    final bool hasExtension = widget.extension != null;
    final TextStyle labelStyle = const TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w700,
      height: 1.1,
    );

    // 원본 카드 clip은 extension과 분리하고, 슬라이드 transform만 같이 적용한다.
    // (전체를 하나의 ClipRRect로 감싸 폭이 변하면 원본 카드 레이아웃이 흔들림)
    final Widget cardBody = ClipRRect(
      borderRadius: hasExtension
          ? const BorderRadius.only(
              topLeft: Radius.circular(12),
              bottomLeft: Radius.circular(12),
            )
          : BorderRadius.circular(12),
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned.fill(
            child: Stack(
              children: [
                if (widget.downLabel.isNotEmpty && widget.canSlideDown)
                  Align(
                    alignment: const Alignment(-0.9, 0),
                    child: Opacity(
                      opacity: isRight
                          ? (0.2 + 0.8 * progress).clamp(0.0, 1.0)
                          : 0.0,
                      child: Text(
                        '→ ${widget.downLabel}',
                        style: labelStyle.copyWith(
                          color: widget.downColor,
                        ),
                        maxLines: 1,
                        softWrap: false,
                      ),
                    ),
                  ),
                if (widget.canSlideUp &&
                    (widget.upLabel.isNotEmpty ||
                        widget.showUpArrowWhenLabelEmpty))
                  Align(
                    alignment: const Alignment(0.9, 0),
                    child: Transform.translate(
                      offset: const Offset(-5, 0),
                      child: Opacity(
                        opacity: isLeft
                            ? (0.2 + 0.8 * progress).clamp(0.0, 1.0)
                            : 0.0,
                        child: widget.upLabel.trim().isEmpty
                            ? Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.arrow_back_rounded,
                                    size: 34,
                                    color: widget.upColor,
                                  ),
                                  if (widget.upSubLabel.trim().isNotEmpty) ...[
                                    const SizedBox(height: 3),
                                    Text(
                                      widget.upSubLabel.trim(),
                                      style: labelStyle.copyWith(
                                        color: widget.upColor,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w800,
                                      ),
                                      maxLines: 1,
                                      softWrap: false,
                                    ),
                                  ],
                                ],
                              )
                            : Text(
                                '← ${widget.upLabel}',
                                style: labelStyle.copyWith(
                                  color: widget.upColor,
                                ),
                                maxLines: 1,
                                softWrap: false,
                              ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          widget.child,
        ],
      ),
    );

    final Widget slidingContent = hasExtension
        ? Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              cardBody,
              widget.extension!,
            ],
          )
        : cardBody;

    final Widget composed = AnimatedContainer(
      duration: _dragging ? Duration.zero : const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      transform: Matrix4.translationValues(_offset, 0, 0),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          onSecondaryTap: widget.onSecondaryTap,
          onDoubleTap: widget.onDoubleTap,
          onHorizontalDragUpdate: (details) {
            final delta = details.delta.dx;
            if (delta > 0) {
              // 오른쪽 방향: 슬라이드 불가여도 반대방향에서 복귀는 허용
              if (!widget.canSlideDown && _offset >= 0) return;
            } else if (delta < 0) {
              // 왼쪽 방향: 슬라이드 불가여도 반대방향에서 복귀는 허용
              if (!widget.canSlideUp && _offset <= 0) return;
            }
            _updateOffset(delta);
          },
          onHorizontalDragEnd: _endDrag,
          child: slidingContent,
        ),
      ),
    );

    if (widget.foregroundPainter == null) return composed;
    return CustomPaint(
      foregroundPainter: widget.foregroundPainter,
      child: composed,
    );
  }
}

/// 홈 등원 카드용 — 지금 이후 가장 가까운 수업 시각.
DateTime? _nextClassDateTimeForStudent(String studentId, {DateTime? after}) {
  return NextClassStartResolver.next(studentId, after: after);
}

String _formatNextClassLabel(DateTime? dt) {
  if (dt == null) return '다음 -';
  const days = ['월', '화', '수', '목', '금', '토', '일'];
  final dow = days[dt.weekday - 1];
  final hm =
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  return '다음 $dow $hm';
}

class _AttendingButton extends StatelessWidget {
  final String name;
  final Color color;
  final String studentId;
  final DateTime? arrivalTime;
  final VoidCallback? onTap;
  final bool showHorizontalDivider;
  final double width;
  final EdgeInsetsGeometry margin;
  const _AttendingButton({
    required this.studentId,
    required this.name,
    required this.color,
    required this.arrivalTime,
    this.onTap,
    this.showHorizontalDivider = false,
    this.width = ClassContentScreen._attendingCardWidth,
    this.margin = const EdgeInsets.only(left: 24),
  });

  Future<void> _confirmUnbindDevice(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Text(
          '$name 학생의 기기 바인딩을 해제할까요?',
          style: const TextStyle(color: Colors.white70, fontSize: 15),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('해제', style: TextStyle(color: Color(0xFF1FA95B))),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final academyId = await TenantService.instance.getActiveAcademyId();
      if (academyId == null) return;
      await Supabase.instance.client.rpc(
        'm5_unbind_by_student',
        params: {
          'p_academy_id': academyId,
          'p_student_id': studentId,
        },
      );
      await DataManager.instance.loadStudents();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final panelStyle = FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
    final primaryTextColor = panelStyle.title;
    final secondaryTextColor = panelStyle.label;
    final tertiaryTextColor = isDark ? Colors.white54 : const Color(0xFF8E8E93);
    // M5 기기 배지와 동일 톤 (배경·글자색 공유).
    final deviceBadgeBackground = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.black.withValues(alpha: 0.05);
    final deviceBadgeTextColor =
        isDark ? Colors.white38 : const Color(0xFF6B6B6B);
    const secondaryLineHeight = 22.0;

    return MouseRegion(
      cursor:
          onTap == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: width,
          height: ClassContentScreen._attendingCardHeight,
          margin: margin,
          padding: const EdgeInsets.fromLTRB(22, 0, 12, 0),
          decoration: BoxDecoration(
            color: Colors.transparent,
            border: showHorizontalDivider
                ? const Border(
                    bottom: BorderSide(color: kDlgBorder, width: 1),
                  )
                : null,
          ),
          child: AnimatedBuilder(
            animation: Listenable.merge([
              DataManager.instance.studentsNotifier,
              DataManager.instance.deviceBindingsRevision,
              DataManager.instance.studentAppPresenceRevision,
              DataManager.instance.studentTimeBlocksRevision,
              DataManager.instance.sessionOverridesNotifier,
              HomeworkStore.instance.revision,
            ]),
            builder: (context, _) {
              final items = HomeworkStore.instance
                  .items(studentId)
                  .where((e) => e.status != HomeworkStatus.completed)
                  .toList();
              final hasAny = items.isNotEmpty;
              final hasRunning =
                  HomeworkStore.instance.runningOf(studentId) != null ||
                      items.any((e) => e.phase == 2 || e.runStart != null);
              final isResting = hasAny && !hasRunning;

              String school = '';
              String gradeText = '';
              try {
                final swi = DataManager.instance.students
                    .firstWhere((s) => s.student.id == studentId);
                school = swi.student.school;
                final g = swi.student.grade;
                gradeText = g > 0 ? '${g}학년' : '';
              } catch (_) {}

              final boundDevice = DataManager.instance.boundDeviceId(studentId);
              final deviceLabel = boundDevice != null
                  ? boundDevice.replaceAll(RegExp(r'^m5-device-'), '')
                  : null;
              final appPresence =
                  DataManager.instance.studentAppPresence(studentId);
              final nextClassLabel = _formatNextClassLabel(
                _nextClassDateTimeForStudent(studentId),
              );

              final nameStyle = TextStyle(
                color: isResting ? tertiaryTextColor : primaryTextColor,
                fontSize: 34,
                fontWeight: FontWeight.w600,
                height: 1.0,
              );
              final infoLine = [
                if (school.isNotEmpty) school,
                if (gradeText.isNotEmpty) gradeText,
              ].join(' · ');
              final arrivalText = arrivalTime != null
                  ? _formatShortTime(arrivalTime!)
                  : '--:--';

              // 오른쪽 정보 3줄 — 글자 크기 동일
              const rightInfoFontSize = 14.0;
              final metaStyle = TextStyle(
                color: secondaryTextColor,
                fontSize: rightInfoFontSize,
                height: 1.2,
                fontWeight: FontWeight.w600,
              );
              final arrivalStyle = TextStyle(
                color: tertiaryTextColor,
                fontSize: rightInfoFontSize,
                height: 1.2,
                fontWeight: FontWeight.w600,
              );
              final nextClassStyle = TextStyle(
                color: tertiaryTextColor,
                fontSize: rightInfoFontSize,
                height: 1.2,
                fontWeight: FontWeight.w600,
              );

              Widget _pill({
                required String label,
                required Color background,
                required Color foreground,
                VoidCallback? onTap,
              }) {
                final child = Container(
                  height: secondaryLineHeight,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: background,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      color: foreground,
                      fontSize: 12,
                      height: 1.0,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                );
                if (onTap == null) return child;
                return MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onTap,
                    child: child,
                  ),
                );
              }

              Widget deviceLine({required double maxWidth}) {
                final pills = <Widget>[];
                if (appPresence != null) {
                  // 등원 카드에 있으면 등원중 → 로그인 시 항상 학원.
                  pills.add(
                    _pill(
                      label: '앱, 학원',
                      background: deviceBadgeBackground,
                      foreground: deviceBadgeTextColor,
                    ),
                  );
                }
                if (deviceLabel != null) {
                  pills.add(
                    _pill(
                      label: '기기 $deviceLabel',
                      background: deviceBadgeBackground,
                      foreground: deviceBadgeTextColor,
                      onTap: () => _confirmUnbindDevice(context),
                    ),
                  );
                }
                if (pills.isEmpty) {
                  return SizedBox(width: maxWidth, height: secondaryLineHeight);
                }
                return Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < pills.length; i++) ...[
                          if (i > 0) const SizedBox(width: 6),
                          Flexible(child: pills[i]),
                        ],
                      ],
                    ),
                  ),
                );
              }

              // 좌우 모두 같은 고정 높이. IntrinsicHeight는 내부 LayoutBuilder와
              // 함께 쓸 수 없으므로 사용하지 않는다.
              return Center(
                child: SizedBox(
                  height: 72,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 3,
                        child: LayoutBuilder(
                          builder: (context, leftConstraints) {
                            final namePainter = TextPainter(
                              text: TextSpan(text: name, style: nameStyle),
                              maxLines: 1,
                              ellipsis: '…',
                              textDirection: TextDirection.ltr,
                            )..layout(maxWidth: leftConstraints.maxWidth);
                            final pillMaxWidth = namePainter.width
                                .clamp(0.0, leftConstraints.maxWidth)
                                .toDouble();
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name,
                                  style: nameStyle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                // 이름·기기 알약 최소 간격
                                const SizedBox(height: 10),
                                const Spacer(),
                                deviceLine(maxWidth: pillMaxWidth),
                              ],
                            );
                          },
                        ),
                      ),
                      const SizedBox(width: 20),
                      Expanded(
                        flex: 3,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              infoLine.isEmpty ? '-' : infoLine,
                              style: metaStyle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.right,
                            ),
                            Text(
                              '등원 $arrivalText',
                              style: arrivalStyle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.right,
                            ),
                            Text(
                              nextClassLabel,
                              style: nextClassStyle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.right,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
