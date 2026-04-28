import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/data_manager.dart';
import '../services/tenant_service.dart';
import '../services/homework_store.dart';
import '../services/homework_batch_confirm_service.dart';
import '../services/homework_test_grading_result_service.dart';
import '../services/student_flow_store.dart';
import '../services/homework_assignment_store.dart';
import '../services/learning_problem_bank_service.dart';
import '../services/print_routing_service.dart';
import '../models/attendance_record.dart';
import '../models/student_flow.dart';
import 'learning/homework_quick_add_proxy_dialog.dart';
import '../services/tag_preset_service.dart';
import '../services/tag_store.dart';
import 'learning/tag_preset_dialog.dart';
import 'learning/homework_edit_dialog.dart';
import 'learning/models/problem_bank_export_models.dart'
    show previewAnswerForMode;
import '../widgets/dialog_tokens.dart';
import '../widgets/homework_assign_dialog.dart';
import '../widgets/homework_overview_naesin_past_exam_panel.dart';
import '../app_overlays.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';
import '../widgets/flow_setup_dialog.dart';
import '../widgets/pdf/homework_answer_viewer_dialog.dart';
import '../widgets/latex_text_renderer.dart';
import '../widgets/home_header_weather_icon.dart';
import '../utils/homework_page_text.dart';
import 'class_content/grading_mode_page.dart';

/// 수업 내용 관리 6번째 페이지 (구조만 정의, 기능 미구현)
class ClassContentScreen extends StatefulWidget {
  const ClassContentScreen({super.key});

  static const double _attendingCardHeight = 102; // 기존 대비 15% 축소
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
  String? _expandedReservedStudentId;
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

  Map<({String studentId, String itemId}), bool> get _pendingConfirms =>
      _batchConfirmService.pending;

  @override
  void initState() {
    super.initState();
    DataManager.instance.loadDeviceBindings();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      gradingModeActive.value = _isGradingMode;
      homeBatchConfirmFabVisible.value = true;
      _batchConfirmService.syncPendingCount();
    });
    _uiAnimController = AnimationController(
        duration: const Duration(milliseconds: 1800), vsync: this)
      ..repeat();
    _clockTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted) return;
      setState(() {
        _now = DateTime.now();
      });
    });
  }

  @override
  void dispose() {
    homeBatchConfirmFabVisible.value = false;
    rightSideSheetTestGradingSession.value = null;
    _uiAnimController.dispose();
    _clockTimer.cancel();
    super.dispose();
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
              isTestHomework: _isTestHomeworkType(hw.type),
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

  Widget _buildHeaderPillIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color iconColor = const Color(0xFFD0DDDD),
  }) {
    const double controlHeight = 48;
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: controlHeight,
          height: controlHeight,
          decoration: BoxDecoration(
            color: const Color(0xFF2A2A2A),
            borderRadius: BorderRadius.circular(controlHeight / 2),
            border: Border.all(color: Colors.transparent),
          ),
          child: Center(
            child: Icon(
              icon,
              color: iconColor,
              size: 24,
            ),
          ),
        ),
      ),
    );
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
            color: const Color(0xFF0B1112),
            width: double.infinity,
            child: ValueListenableBuilder<List<AttendanceRecord>>(
              valueListenable: DataManager.instance.attendanceRecordsNotifier,
              builder: (context, _records, __) {
                // sessionOverrides 변화도 함께 트리거
                final _ = DataManager.instance.sessionOverridesNotifier.value;
                final list = _computeAttendingStudentsRealtime();
                final attendingStudentIds =
                    list.map((s) => s.id).toList(growable: false);
                final studentNamesById = <String, String>{
                  for (final s in list) s.id: s.name,
                };
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ValueListenableBuilder<int>(
                      valueListenable: HomeworkStore.instance.revision,
                      builder: (context, homeworkRevision, _) {
                        final submittedCount = _isGradingMode
                            ? _countSubmittedHomeworkItems(list)
                            : 0;
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(40, 8, 16, 0),
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              // 인쇄·채점 컨트롤은 항상 1행 우측에 고정. 좌측만 날짜/통계 줄바꿈.
                              final double controlsReserve =
                                  _isGradingMode ? 380 : 270;
                              final double leftBudget = math.max(
                                0.0,
                                constraints.maxWidth -
                                    controlsReserve -
                                    56, // 좌우 패딩·간격 여유
                              );
                              final double headerScale =
                                  (constraints.maxWidth / 1680.0)
                                      .clamp(0.68, 1.0);
                              final double dateTimeFontSize =
                                  (50 * headerScale).clamp(26.0, 50.0);
                              final double statsFontSize =
                                  (38 * headerScale).clamp(18.0, 40.0);
                              final double weatherIconSize =
                                  dateTimeFontSize * 1.1;
                              // 한 줄에 날짜+통계까지 넣기에 부족하면 통계만 2번째 줄.
                              final bool statsOnSecondLine =
                                  leftBudget < 920 * headerScale;
                              final Widget dateLine = Wrap(
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 12 * headerScale,
                                runSpacing: 4,
                                children: [
                                  HomeHeaderWeatherIcon(
                                    iconSize: weatherIconSize,
                                    color: Colors.white70,
                                  ),
                                  Text(
                                    _formatDateWithWeekdayAndTime(_now),
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: dateTimeFontSize,
                                      fontWeight: FontWeight.bold,
                                      height: 1.0,
                                    ),
                                  ),
                                ],
                              );
                              final Widget statsLine = Wrap(
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 14 * headerScale,
                                runSpacing: 4,
                                children: [
                                  if (!_isGradingMode)
                                    Text(
                                      '등원: ${list.length}명',
                                      style: TextStyle(
                                        color: Colors.white60,
                                        fontSize: statsFontSize,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    )
                                  else
                                    Text(
                                      '제출: $submittedCount개',
                                      style: TextStyle(
                                        color: const Color(0xFF8FB3FF),
                                        fontSize: statsFontSize,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                ],
                              );
                              final Widget infoBlock = statsOnSecondLine
                                  ? Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        dateLine,
                                        SizedBox(height: 6 * headerScale),
                                        statsLine,
                                      ],
                                    )
                                  : Wrap(
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      spacing: 18 * headerScale,
                                      runSpacing: 6,
                                      children: [
                                        HomeHeaderWeatherIcon(
                                          iconSize: weatherIconSize,
                                          color: Colors.white70,
                                        ),
                                        Text(
                                          _formatDateWithWeekdayAndTime(_now),
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: dateTimeFontSize,
                                            fontWeight: FontWeight.bold,
                                            height: 1.0,
                                          ),
                                        ),
                                        if (!_isGradingMode)
                                          Text(
                                            '등원: ${list.length}명',
                                            style: TextStyle(
                                              color: Colors.white60,
                                              fontSize: statsFontSize,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          )
                                        else
                                          Text(
                                            '제출: $submittedCount개',
                                            style: TextStyle(
                                              color: const Color(0xFF8FB3FF),
                                              fontSize: statsFontSize,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                      ],
                                    );
                              final Widget controls = Wrap(
                                alignment: WrapAlignment.end,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 12,
                                runSpacing: 12,
                                children: [
                                  _buildHeaderPillIconButton(
                                    icon: Icons.link_rounded,
                                    tooltip: 'M5 바인딩 이력',
                                    iconColor: const Color(0xFFD0DDDD),
                                    onTap: () => unawaited(
                                      _showM5BindingHistoryDialog(
                                        context: context,
                                      ),
                                    ),
                                  ),
                                  _buildHeaderPillIconButton(
                                    icon: Icons.print,
                                    tooltip: '인쇄',
                                    iconColor: _printPickMode
                                        ? const Color(0xFFEAF2F2)
                                        : const Color(0xFFD0DDDD),
                                    onTap: () => unawaited(
                                      _openHeaderHomeworkPrintFlow(
                                        attendingStudents: list,
                                      ),
                                    ),
                                  ),
                                  if (_isGradingMode)
                                    ValueListenableBuilder<bool>(
                                      valueListenable: rightSideSheetOpen,
                                      builder: (context, isOpen, _) {
                                        return _buildHeaderPillIconButton(
                                          icon: isOpen
                                              ? Icons
                                                  .keyboard_double_arrow_right_rounded
                                              : Icons
                                                  .keyboard_double_arrow_left_rounded,
                                          tooltip: isOpen
                                              ? '오른쪽 시트 닫기'
                                              : '오른쪽 시트 열기',
                                          iconColor: const Color(0xFFD0DDDD),
                                          onTap: () async {
                                            blockRightSideSheetOpen.value =
                                                false;
                                            final action =
                                                toggleRightSideSheetAction;
                                            if (action != null) {
                                              await action();
                                            }
                                          },
                                        );
                                      },
                                    ),
                                  if (_isGradingMode)
                                    _buildHeaderPillIconButton(
                                      icon: Icons.history_rounded,
                                      tooltip: '채점 이력',
                                      iconColor: const Color(0xFFD0DDDD),
                                      onTap: () {
                                        unawaited(
                                          _showGradingHistoryDialog(
                                            context: context,
                                            attendingStudentIds:
                                                attendingStudentIds,
                                            studentNamesById: studentNamesById,
                                          ),
                                        );
                                      },
                                    ),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Switch(
                                        value: _isGradingMode,
                                        onChanged: (value) {
                                          setState(() {
                                            _isGradingMode = value;
                                            if (!value) {
                                              _batchConfirmService
                                                  .clearPending();
                                            }
                                          });
                                          gradingModeActive.value = value;
                                          if (value) {
                                            blockRightSideSheetOpen.value =
                                                false;
                                          } else {
                                            blockRightSideSheetOpen.value =
                                                true;
                                            final closeAction =
                                                closeRightSideSheetAction;
                                            if (closeAction != null) {
                                              unawaited(closeAction());
                                            }
                                          }
                                        },
                                        activeColor: kDlgAccent,
                                      ),
                                    ],
                                  ),
                                ],
                              );
                              return Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(child: infoBlock),
                                  const SizedBox(width: 20),
                                  controls,
                                ],
                              );
                            },
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 16),
                    const SizedBox(height: 20),
                    Expanded(
                      child: _isGradingMode
                          ? GradingModePage(
                              attendingStudentIds: attendingStudentIds,
                              studentNamesById: studentNamesById,
                              pendingConfirms: _pendingConfirms,
                              onSubmittedCardTap:
                                  (studentId, group, summary, children) async {
                                final submittedChildren = children
                                    .where(
                                      (e) =>
                                          e.status !=
                                              HomeworkStatus.completed &&
                                          e.phase == 3 &&
                                          e.completedAt == null,
                                    )
                                    .toList(growable: false);
                                if (submittedChildren.isEmpty) return;
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
                                  if (_hasDirectHomeworkTextbookLink(child)) {
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
                              onHomeworkCardTap:
                                  (studentId, group, summary, children) {
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
                                return _runHomeworkGradingForCardWithCombo(
                                  context: context,
                                  studentId: studentId,
                                  group: group,
                                  summary: summary,
                                  children: children,
                                );
                              },
                              onTogglePending: (studentId, itemId) {
                                setState(() {
                                  final key =
                                      (studentId: studentId, itemId: itemId);
                                  if (_pendingConfirms.containsKey(key)) {
                                    _pendingConfirms.remove(key);
                                  } else {
                                    _pendingConfirms[key] = false;
                                  }
                                });
                              },
                            )
                          : ListView.separated(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
                              itemCount: list.length,
                              separatorBuilder: (_, __) => SizedBox(
                                width: 14.4,
                                child: Align(
                                  alignment: Alignment.topCenter,
                                  child: Container(
                                    width: 1,
                                    height:
                                        ClassContentScreen._attendingCardHeight,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF223131),
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                  ),
                                ),
                              ),
                              itemBuilder: (ctx, i) {
                                return _buildStudentColumn(context, list[i]);
                              },
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
          if (_printPickMode)
            Positioned(
              top: 86,
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
                        onTap: () {
                          if (mounted) setState(() => _printPickMode = false);
                        },
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

  Widget _buildStudentColumn(BuildContext context, _AttendingStudent student) {
    final isReservedExpanded = _expandedReservedStudentId == student.id;
    const panelWidth = ClassContentScreen._studentColumnContentWidth;
    void toggleReservedPanel() {
      setState(() {
        _expandedReservedStudentId = isReservedExpanded ? null : student.id;
      });
    }

    final column = AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOutCubic,
      width: ClassContentScreen._studentColumnWidth +
          (isReservedExpanded ? panelWidth : 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: ClassContentScreen._studentColumnWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _AttendingButton(
                  studentId: student.id,
                  name: student.name,
                  color: student.color,
                  arrivalTime: student.record.arrivalTime,
                  onTap: toggleReservedPanel,
                  showHorizontalDivider: false,
                  width: ClassContentScreen._studentColumnContentWidth,
                  margin: EdgeInsets.zero,
                ),
                const SizedBox(height: 0),
                Center(
                  child: SizedBox(
                    width: ClassContentScreen._studentColumnContentWidth,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.max,
                      children: [
                        SizedBox(
                          width: 58,
                          height: 58,
                          child: IconButton(
                            onPressed: () =>
                                _onAddHomework(context, student.id),
                            icon: const Icon(Icons.add_rounded),
                            iconSize: 28,
                            color: kDlgTextSub,
                            splashRadius: 29,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Tooltip(
                          message:
                              isReservedExpanded ? '예약 과제 접기' : '예약 과제 펼치기',
                          child: SizedBox(
                            width: 58,
                            height: 58,
                            child: IconButton(
                              onPressed: toggleReservedPanel,
                              icon: Icon(
                                isReservedExpanded
                                    ? Icons.inventory_2_rounded
                                    : Icons.inventory_2_outlined,
                              ),
                              iconSize: 25,
                              color:
                                  isReservedExpanded ? kDlgAccent : kDlgTextSub,
                              splashRadius: 29,
                            ),
                          ),
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
                              color: kDlgTextSub,
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
                ),
                const SizedBox(height: 18),
                Expanded(
                  child: AnimatedBuilder(
                    animation: _uiAnimController,
                    builder: (context, __) {
                      final tick = _uiAnimController.value; // 0..1
                      return _buildHomeworkChipsReactiveForStudent(
                        student.id,
                        tick,
                        pendingConfirms: _pendingConfirms,
                        onPhase3Tap: _handleSubmittedChipTapForPending,
                        onGroupSubmittedDoubleTap: (sid, submittedItems) {
                          setState(() {
                            final keys = submittedItems
                                .map((e) => (studentId: sid, itemId: e.id))
                                .toList(growable: false);
                            final allSelected = keys.isNotEmpty &&
                                keys.every(_pendingConfirms.containsKey);
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
                        onPrintPickLongPress:
                            _handleHomeworkPrintPickWithSettings,
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
                  ),
                ),
              ],
            ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOutCubic,
            width: isReservedExpanded ? panelWidth : 0,
            alignment: Alignment.centerLeft,
            child: LayoutBuilder(
              builder: (context, constraints) {
                const panelTopInset = ClassContentScreen._attendingCardHeight;
                const panelHeaderHeight = 58.0;
                const panelHeaderGap = 18.0;
                const panelRevealRatio = 0.82;
                final maxHeight = constraints.maxHeight;
                final topInset = maxHeight.isFinite
                    ? math.min(panelTopInset, maxHeight)
                    : panelTopInset;
                final currentWidth = constraints.maxWidth.isFinite
                    ? constraints.maxWidth
                    : panelWidth;
                final revealContent = isReservedExpanded &&
                    currentWidth >= panelWidth * panelRevealRatio;
                final panelHeader = revealContent
                    ? _buildReservedHomeworkTitleReactiveForStudent(student.id)
                    : const SizedBox.shrink();
                final panelBodyCore = IgnorePointer(
                  ignoring: !isReservedExpanded,
                  child: AnimatedBuilder(
                    animation: _uiAnimController,
                    builder: (context, __) {
                      final tick = _uiAnimController.value;
                      return _buildReservedHomeworkSlidePanel(
                        context: context,
                        studentId: student.id,
                        tick: tick,
                        showContent: revealContent,
                      );
                    },
                  ),
                );
                final panelBody = revealContent
                    ? panelBodyCore
                    : ClipRect(child: panelBodyCore);
                if (!constraints.hasBoundedHeight) {
                  return Padding(
                    padding: const EdgeInsets.only(top: panelTopInset),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: panelHeaderHeight,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: panelHeader,
                          ),
                        ),
                        const SizedBox(height: panelHeaderGap),
                        panelBody,
                      ],
                    ),
                  );
                }
                return Column(
                  children: [
                    SizedBox(height: topInset),
                    SizedBox(
                      height: panelHeaderHeight,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: panelHeader,
                      ),
                    ),
                    const SizedBox(height: panelHeaderGap),
                    Expanded(child: panelBody),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
    if (_isGradingMode) {
      return TapRegion(
        onTapOutside: (_) {
          if (_expandedReservedStudentId == student.id) {
            setState(() => _expandedReservedStudentId = null);
          }
        },
        child: column,
      );
    }
    return TapRegion(
      onTapOutside: (_) {
        if (_expandedReservedStudentId == student.id) {
          setState(() => _expandedReservedStudentId = null);
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

  // 리얼타임 반영: 출석 레코드/세션 오버라이드 변경에 따라 즉시 갱신
  List<_AttendingStudent> _computeAttendingStudentsRealtime() {
    // DataManager의 attendanceRecordsNotifier와 sessionOverridesNotifier를 묶음 관찰
    // 여기서는 단순히 값을 소비만 하고, 상위에서 ValueListenableBuilder로 재빌드 유도
    final _ = DataManager.instance.attendanceRecordsNotifier.value;
    final __ = DataManager.instance.sessionOverridesNotifier.value;
    return _computeAttendingStudentsStatic();
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

  List<_AttendingStudent> _computeAttendingStudentsStatic() {
    final List<_AttendingStudent> result = [];
    final now = DateTime.now();
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
            sameDay(rec.classDateTime, now))
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
    var resolvedFlowId = (template.flowId ?? '').trim();
    final bookId = template.primaryBookId;
    final gradeLabel = template.primaryGradeLabel;
    if (bookId.isNotEmpty && gradeLabel.isNotEmpty) {
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
    final modeLabel = mode == _FavoriteIssueMode.reserve ? '예약 과제' : '즉시 과제';
    _showHomeworkChipSnackBar(
      context,
      '${student.name}에게 $modeLabel ${createdCount}개를 추가했어요.',
    );
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
            OutlinedButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(_FavoriteIssueMode.reserve),
              style: OutlinedButton.styleFrom(
                foregroundColor: kDlgText,
                side: const BorderSide(color: kDlgBorder),
              ),
              child: const Text('예약 과제'),
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
              : ((part.flowId ?? '').trim().isEmpty ? null : part.flowId),
          'testOriginFlowId':
              isTestPart ? resolvedOriginFlowId : part.testOriginFlowId,
          'type': partType,
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
      final fallbackFlowId = (part.flowId ?? '').trim();
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
        type: part.type,
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

  Future<void> _onAddHomework(BuildContext context, String studentId) async {
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
      ),
    );
    if (item is Map<String, dynamic>) {
      if (item['studentId'] == studentId) {
        final action = (item['action'] as String?)?.trim() ?? 'add';
        final isReserve = action == 'reserve';
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
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('하위 과제를 1개 이상 추가하세요.')),
            );
            return;
          }
          final selectedFlowId = (item['flowId'] as String?)?.trim();
          final hasTestEntries = entries.any(
            (entry) => _isTestHomeworkTypeLabel(entry['type'] as String?),
          );
          if (hasTestEntries) {
            final testFlowId = await _ensureTestFlowIdForStudent(studentId);
            if (testFlowId == null || testFlowId.isEmpty) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('테스트 플로우를 준비하지 못했습니다.')),
              );
              return;
            }
            for (final entry in entries) {
              if (!_isTestHomeworkTypeLabel(entry['type'] as String?)) continue;
              entry['flowId'] = testFlowId;
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
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('그룹 과제 생성에 실패했어요.')),
            );
            return;
          }
          if (!context.mounted) return;
          final childCount = createdItems.length;
          final msg = isReserve
              ? '그룹 예약 과제(하위 ${childCount}개)를 추가했어요.'
              : '그룹 과제(하위 ${childCount}개)를 추가했어요.';
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(msg)));
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
        final hasTestEntries = entries.any(
          (entry) => _isTestHomeworkTypeLabel(entry['type'] as String?),
        );
        String? testFlowId;
        if (hasTestEntries) {
          testFlowId = await _ensureTestFlowIdForStudent(studentId);
          if (testFlowId == null || testFlowId.isEmpty) {
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('테스트 플로우를 준비하지 못했습니다.')),
            );
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
          final typeLabel = (entry['type'] as String?)?.trim();
          final bool isTestCard = _isTestHomeworkTypeLabel(typeLabel);
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
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('예약 과제 저장에 실패했어요.')),
            );
            return;
          }
        }
        final String msg = isReserve
            ? (entries.length > 1
                ? '예약 과제를 ${entries.length}개 추가했어요.'
                : '예약 과제를 추가했어요.')
            : (entries.length > 1
                ? '과제를 ${entries.length}개 추가했어요.'
                : '과제를 추가했어요.');
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    }
  }

  Future<void> _showHomeworkOverviewDialog(
    BuildContext context,
    String studentId,
  ) async {
    try {
      final activeAssignments = await HomeworkAssignmentStore.instance
          .loadActiveAssignments(studentId);
      final reservedItemIds = activeAssignments
          .where(_isReservationAssignment)
          .map((assignment) => assignment.homeworkItemId.trim())
          .where((itemId) => itemId.isNotEmpty)
          .toSet();
      final visibleAssignments = activeAssignments
          .where((assignment) => !_isReservationAssignment(assignment))
          .toList(growable: false);
      final checksByItem = await HomeworkAssignmentStore.instance
          .loadChecksForStudent(studentId);
      final assignmentsByItem = await HomeworkAssignmentStore.instance
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

      final entries = <_HomeworkOverviewEntry>[];
      final seenItemIds = <String>{};

      for (final assignment in visibleAssignments) {
        final itemId = assignment.homeworkItemId.trim();
        if (itemId.isEmpty) continue;
        final checks = List<HomeworkAssignmentCheck>.from(
          checksByItem[itemId] ?? const <HomeworkAssignmentCheck>[],
        )..sort((a, b) => a.checkedAt.compareTo(b.checkedAt));
        final todayChecks = checks.where((c) => isToday(c.checkedAt)).toList();
        final latestTodayCheck = todayChecks.isEmpty ? null : todayChecks.last;
        final fallbackTitle =
            HomeworkStore.instance.getById(studentId, itemId)?.title.trim() ??
                '';
        final titleRaw = assignment.title.trim().isNotEmpty
            ? assignment.title.trim()
            : fallbackTitle;
        final xp = _homeworkOverviewExpandParts(
          studentId: studentId,
          itemId: itemId,
          checks: checks,
          assignedAt: assignment.assignedAt,
        );
        entries.add(
          _HomeworkOverviewEntry(
            homeworkItemId: itemId,
            title: titleRaw.isEmpty ? '(제목 없음)' : titleRaw,
            assignedAt: assignment.assignedAt,
            dueDate: assignment.dueDate,
            checkedToday: latestTodayCheck != null,
            checkedAt: latestTodayCheck?.checkedAt,
            progress: latestTodayCheck?.progress ?? assignment.progress,
            isActive: true,
            flowLabel: homeworkOverviewFlowLabel(itemId),
            overviewLine1Left: xp.overviewLine1Left,
            expandLine4Left: xp.expandLine4Left,
            expandLine4Right: xp.expandLine4Right,
            expandLine5Left: xp.expandLine5Left,
            expandLine5Right: xp.expandLine5Right,
            expandChildren: xp.expandChildren,
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
        final todayChecks = checks.where((c) => isToday(c.checkedAt)).toList();
        if (todayChecks.isEmpty) continue;
        final latestTodayCheck = todayChecks.last;

        final briefs = List<HomeworkAssignmentBrief>.from(
          assignmentsByItem[itemId] ?? const <HomeworkAssignmentBrief>[],
        )..sort((a, b) => b.assignedAt.compareTo(a.assignedAt));
        final latestBrief = briefs.isEmpty ? null : briefs.first;
        final fallbackTitle =
            HomeworkStore.instance.getById(studentId, itemId)?.title.trim() ??
                '';
        final xp2 = _homeworkOverviewExpandParts(
          studentId: studentId,
          itemId: itemId,
          checks: checks,
          assignedAt: latestBrief?.assignedAt ?? latestTodayCheck.checkedAt,
        );
        entries.add(
          _HomeworkOverviewEntry(
            homeworkItemId: itemId,
            title: fallbackTitle.isEmpty ? '(제목 없음)' : fallbackTitle,
            assignedAt: latestBrief?.assignedAt ?? latestTodayCheck.checkedAt,
            dueDate: latestBrief?.dueDate,
            checkedToday: true,
            checkedAt: latestTodayCheck.checkedAt,
            progress: latestTodayCheck.progress,
            isActive: false,
            flowLabel: homeworkOverviewFlowLabel(itemId),
            overviewLine1Left: xp2.overviewLine1Left,
            expandLine4Left: xp2.expandLine4Left,
            expandLine4Right: xp2.expandLine4Right,
            expandLine5Left: xp2.expandLine5Left,
            expandLine5Right: xp2.expandLine5Right,
            expandChildren: xp2.expandChildren,
          ),
        );
      }

      entries.sort((a, b) {
        if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
        final leftTs = a.checkedAt ?? a.assignedAt;
        final rightTs = b.checkedAt ?? b.assignedAt;
        return rightTs.compareTo(leftTs);
      });
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
        builder: (ctx) {
          final media = MediaQuery.of(ctx).size;
          final dialogWidth = math.min(media.width * 0.9, 1080.0);
          final panelHeight = math.min(media.height * 0.52, 560.0);
          return StatefulBuilder(
            builder: (dialogContext, setDialogState) {
              final selectedFilter = sessionFilterOptions.firstWhere(
                (opt) => opt.id == selectedSessionFilterId,
                orElse: () => sessionFilterOptions.first,
              );
              final completedGroupEntries =
                  _collectRecentCompletedHomeworkGroups(
                studentId,
                assignmentsByItem: assignmentsByItem,
                targetDay: selectedFilter.targetDay,
                windowStart: selectedFilter.from,
                windowEnd: selectedFilter.to,
                limit: 16,
              );
              return AlertDialog(
                backgroundColor: kDlgBg,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                title: Text(
                  '$studentName 과제 현황',
                  style: const TextStyle(
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
                      Row(
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
                                dropdownColor: kDlgBg,
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
                      const SizedBox(height: 10),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const YggDialogSectionHeader(
                                  icon: Icons.task_alt_rounded,
                                  title: '완료 그룹과제',
                                ),
                                const SizedBox(height: 10),
                                SizedBox(
                                  height: panelHeight,
                                  child: completedGroupEntries.isEmpty
                                      ? const Center(
                                          child: Text(
                                            '선택한 수업에서 완료한 그룹과제가 없습니다.',
                                            style: TextStyle(
                                              color: kDlgTextSub,
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        )
                                      : ListView.separated(
                                          itemCount:
                                              completedGroupEntries.length,
                                          separatorBuilder: (_, __) =>
                                              const SizedBox(height: 10),
                                          itemBuilder: (context, index) {
                                            final entry =
                                                completedGroupEntries[index];
                                            final isExpanded =
                                                expandedCompletedGroupIds
                                                    .contains(entry.groupId);
                                            return _buildCompletedGroupOverviewCard(
                                              entry,
                                              isExpanded: isExpanded,
                                              onTap: () {
                                                setDialogState(() {
                                                  if (isExpanded) {
                                                    expandedCompletedGroupIds
                                                        .remove(entry.groupId);
                                                  } else {
                                                    expandedCompletedGroupIds
                                                        .add(entry.groupId);
                                                  }
                                                });
                                              },
                                            );
                                          },
                                        ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 14),
                          Container(
                            width: 1,
                            height: panelHeight + 34,
                            color: const Color(0xFF2A3B3E),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const YggDialogSectionHeader(
                                  icon: Icons.assignment_rounded,
                                  title: '활성/오늘 검사 현황',
                                ),
                                const SizedBox(height: 10),
                                SizedBox(
                                  height: panelHeight,
                                  child: entries.isEmpty
                                      ? const Center(
                                          child: Text(
                                            '활성 숙제와 오늘 검사 항목이 없습니다.',
                                            style: TextStyle(
                                              color: kDlgTextSub,
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        )
                                      : ListView.separated(
                                          itemCount: entries.length,
                                          separatorBuilder: (_, __) =>
                                              const SizedBox(height: 10),
                                          itemBuilder: (context, index) {
                                            final e = entries[index];
                                            final isOvEx =
                                                expandedHomeworkOverviewItemIds
                                                    .contains(e.homeworkItemId);
                                            return _buildHomeworkOverviewCard(
                                              e,
                                              isExpanded: isOvEx,
                                              onTap: () {
                                                setDialogState(() {
                                                  if (isOvEx) {
                                                    expandedHomeworkOverviewItemIds
                                                        .remove(
                                                            e.homeworkItemId);
                                                  } else {
                                                    expandedHomeworkOverviewItemIds
                                                        .add(e.homeworkItemId);
                                                  }
                                                });
                                              },
                                            );
                                          },
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      HomeworkOverviewNaesinPastExamPanel(
                        studentId: studentId,
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
    final hasHomeworkItems = HomeworkStore.instance.items(studentId).isNotEmpty;
    final HomeworkAssignSelection? selection = hasHomeworkItems
        ? await showHomeworkAssignDialog(
            context,
            studentId,
            anchorTime: student.record.classDateTime,
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
      if (selection.itemIds.isNotEmpty) {
        final selectedItemIds = selection.itemIds
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toSet()
            .toList(growable: false);
        HomeworkStore.instance.markItemsAsHomework(
          studentId,
          selectedItemIds,
          dueDate: selection.dueDate,
          cloneCompletedItems: true,
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
            selectedBehaviorIds: selection.selectedBehaviorIds,
            irregularBehaviorCounts: selection.irregularBehaviorCounts,
            dueDate: selection.dueDate,
            className: record.className,
            classEndTime: record.classEndTime,
            setId: record.setId,
          );
        } catch (e) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('알림장 인쇄에 실패했어요: $e')),
          );
        }
      }
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${student.name} 하원 처리되었습니다.')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('하원 처리 실패: $e')),
      );
    }
  }

  Future<void> _onAddTag(BuildContext context, String studentId) async {
    final setId = _inferSetIdForStudent(studentId);
    if (setId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('현재 수업 세트를 찾지 못했습니다. 시간표를 확인하세요.')));
      return;
    }
    await _openClassTagDialogLikeSideSheet(context, setId, studentId);
  }

  Future<String?> _openRecordNoteDialog(BuildContext context) async {
    final controller = ImeAwareTextEditingController();
    return showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1F1F1F),
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
    switch (state) {
      case HomeworkAnswerCellState.correct:
        return 'correct';
      case HomeworkAnswerCellState.wrong:
        return 'wrong';
      case HomeworkAnswerCellState.unsolved:
        return 'unsolved';
    }
  }

  HomeworkAnswerCellState _decodeTestGradingState(String? raw) {
    final normalized = (raw ?? '').trim().toLowerCase();
    switch (normalized) {
      case 'wrong':
        return HomeworkAnswerCellState.wrong;
      case 'unsolved':
        return HomeworkAnswerCellState.unsolved;
      case 'correct':
      default:
        return HomeworkAnswerCellState.correct;
    }
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
                    'answer': cell.answer,
                    'answerMode': cell.answerMode,
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
    final selectedUids = preset.selectedQuestionUids
        .map((uid) => uid.trim())
        .where((uid) => uid.isNotEmpty)
        .toList(growable: false);
    if (selectedUids.isEmpty) return null;

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
      final rawIndex = int.tryParse(question.displayQuestionNumber.trim());
      final questionIndex = rawIndex != null && rawIndex > 0
          ? rawIndex
          : (question.sourceOrder > 0 ? question.sourceOrder : fallbackIndex);
      final answerMode = (modeByUid[uid] ?? '').trim().toLowerCase();
      final answer = previewAnswerForMode(question, answerMode).trim();

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

      final key = '${baseItem.id}|$pageNumber|$questionIndex|$uid';
      final uidScore = presetScoreByUid[uid];
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
    );
  }

  Future<void> _handleSubmittedChipTapForPending({
    required BuildContext context,
    required String studentId,
    required HomeworkItem hw,
    List<({String studentId, String itemId})>? targetKeys,
    bool suppressCombo = false,
  }) async {
    final keys = (targetKeys == null || targetKeys.isEmpty)
        ? <({String studentId, String itemId})>[
            (studentId: studentId, itemId: hw.id),
          ]
        : targetKeys;
    if (keys.isEmpty) return;
    final allSelected = keys.every(_pendingConfirms.containsKey);
    if (allSelected) {
      setState(() {
        for (final key in keys) {
          _pendingConfirms.remove(key);
        }
      });
      return;
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
        if (!context.mounted) return;
        final initialStates = savedSession?.states.isNotEmpty == true
            ? savedSession!.states
            : cachedStates;
        final hasSavedGrading = savedSession != null ||
            _testGradingSavedHomeworkIds.contains(payload.homeworkId);
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
        rightSideSheetTestGradingSession.value =
            RightSideSheetTestGradingSession(
          sessionId: 'student:$studentId|test_pb_grade:${payload.homeworkId}',
          title: payload.title,
          studentName: studentName,
          groupHomeworkTitle: groupHomeworkTitle,
          assignmentCode: normalizedAssignmentCode,
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
          initialStates: _toRightSheetStateMap(initialStates),
          gradingLocked: hasSavedGrading,
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
          onAction: (action, states) async {
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
              );
              if (!mounted) return;
              if (!saved) {
                savedGrading = false;
                _showHomeworkChipSnackBar(context, '채점 결과 저장에 실패했습니다.');
              } else {
                _testGradingSavedHomeworkIds.add(payload.homeworkId);
              }
            }
            if (!mounted || !savedGrading) return;
            setState(() {
              for (final key in keys) {
                _pendingConfirms[key] = action == 'complete';
              }
            });
            _batchConfirmService.syncPendingCount();
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
          backgroundColor: const Color(0xFF1F1F1F),
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
      if (!suppressCombo && context.mounted) {
        await _maybeOfferSubmittedGradingCombo(
          context: context,
          seed: hw,
          keys: keys,
        );
      }
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
    final bool pdfActionCommitted =
        action == HomeworkAnswerViewerAction.complete ||
            action == HomeworkAnswerViewerAction.confirm;
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
    if (!suppressCombo && pdfActionCommitted && context.mounted) {
      await _maybeOfferSubmittedGradingCombo(
        context: context,
        seed: hw,
        keys: keys,
      );
    }
  }

  Future<void> _maybeOfferSubmittedGradingCombo({
    required BuildContext context,
    required HomeworkItem seed,
    required List<({String studentId, String itemId})> keys,
  }) async {
    final store = HomeworkStore.instance;
    final seedChildren = <HomeworkItem>[];
    for (final key in keys) {
      final item = store.getById(key.studentId, key.itemId);
      if (item != null) seedChildren.add(item);
    }
    final matchKey = _resolveGradingComboMatchKey(
      summary: seed,
      children: seedChildren,
    );
    if (matchKey == null) return;
    final excluded = <String>{};
    for (final key in keys) {
      excluded.add('item:${key.itemId}');
      final gid = store.groupIdOfItem(key.itemId);
      if (gid != null && gid.isNotEmpty) {
        excluded.add('group:$gid');
      }
    }
    await _runSubmittedGradingComboAfter(
      context: context,
      matchKey: matchKey,
      excludedKeys: excluded,
    );
  }

  Future<void> _handleHomeworkCardTapForPending({
    required BuildContext context,
    required String studentId,
    required HomeworkItem hw,
  }) async {
    final key = (studentId: studentId, itemId: hw.id);
    if (_pendingConfirms.containsKey(key)) {
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
    );
    if (!context.mounted || draft == null) return;

    setState(() => _pendingConfirms[key] = false);
  }

  Future<void> _openHeaderHomeworkPrintFlow({
    required List<_AttendingStudent> attendingStudents,
  }) async {
    if (_printPickMode) {
      if (mounted) {
        setState(() => _printPickMode = false);
      }
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
    setState(() => _printPickMode = true);
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
    setState(() => _printPickMode = false);
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
      assignmentByItemId: request.assignmentByItemId,
      preResolvedSourceByItemId: request.sourceByItemId,
    );
  }

  /// 채점 모드 홈에서 숙제 카드를 눌렀을 때 검사 다이얼로그를 실행하고,
  /// 저장이 성공하면 같은 교재·같은 과제유형의 다음 후보를 콤보 다이얼로그로 이어서 검사한다.
  Future<void> _runHomeworkGradingForCardWithCombo({
    required BuildContext context,
    required String studentId,
    required HomeworkGroup? group,
    required HomeworkItem summary,
    required List<HomeworkItem> children,
  }) async {
    final excludedKeys = <String>{
      if (group != null) 'group:${group.id}' else 'item:${summary.id}',
    };
    _GradingComboMatchKey? currentMatchKey = _resolveGradingComboMatchKey(
      summary: summary,
      children: children,
    );

    final firstOk = (group == null && children.length == 1)
        ? await _runHomeworkCheckDialogOnly(
            context: context,
            studentId: studentId,
            hw: children.first,
          )
        : await _runHomeworkCheckDialogForGroup(
            context: context,
            studentId: studentId,
            group: group,
            summary: summary,
            children: children,
          );

    if (!mounted || !context.mounted) return;
    if (!firstOk || currentMatchKey == null) return;

    while (mounted && context.mounted) {
      final attendingList = _computeAttendingStudentsRealtime();
      final attendingIds =
          attendingList.map((s) => s.id).toList(growable: false);
      final namesById = <String, String>{
        for (final s in attendingList) s.id: s.name,
      };
      final candidates = await _collectGradingComboCandidates(
        attendingStudentIds: attendingIds,
        studentNamesById: namesById,
        matchKey: currentMatchKey!,
        excludeUniqueKeys: excludedKeys,
        section: _GradingComboSection.homework,
      );
      if (!mounted || !context.mounted) return;
      if (candidates.isEmpty) return;

      final picked = await _showGradingComboDialog(
        context: context,
        recommended: candidates.first,
        candidates: candidates,
        section: _GradingComboSection.homework,
      );
      if (!mounted || !context.mounted || picked == null) return;
      excludedKeys.add(picked.uniqueKey);

      final savedNext = picked.isGroup
          ? await _runHomeworkCheckDialogForGroup(
              context: context,
              studentId: picked.studentId,
              group: picked.group,
              summary: picked.summary,
              children: picked.children,
            )
          : await _runHomeworkCheckDialogOnly(
              context: context,
              studentId: picked.studentId,
              hw: picked.summary,
            );
      if (!mounted || !context.mounted) return;
      if (!savedNext) {
        // 사용자가 검사 다이얼로그에서 취소했거나 저장 실패 → 콤보 체인 종료.
        return;
      }
      // matchKey는 동일하게 유지(같은 교재·유형으로 계속 추천).
    }
  }

  /// 제출(과제) 카드의 검사 동작이 의미 있게 완료된 뒤,
  /// 같은 교재·같은 과제유형을 가진 다음 제출 과제를 이어서 검사할지 추천.
  Future<void> _runSubmittedGradingComboAfter({
    required BuildContext context,
    required _GradingComboMatchKey matchKey,
    required Set<String> excludedKeys,
  }) async {
    while (mounted && context.mounted) {
      final attendingList = _computeAttendingStudentsRealtime();
      final attendingIds =
          attendingList.map((s) => s.id).toList(growable: false);
      final namesById = <String, String>{
        for (final s in attendingList) s.id: s.name,
      };
      final candidates = await _collectGradingComboCandidates(
        attendingStudentIds: attendingIds,
        studentNamesById: namesById,
        matchKey: matchKey,
        excludeUniqueKeys: excludedKeys,
        section: _GradingComboSection.submitted,
      );
      if (!mounted || !context.mounted) return;
      if (candidates.isEmpty) return;

      final picked = await _showGradingComboDialog(
        context: context,
        recommended: candidates.first,
        candidates: candidates,
        section: _GradingComboSection.submitted,
      );
      if (!mounted || !context.mounted || picked == null) return;
      excludedKeys.add(picked.uniqueKey);

      // 제출 카드 탭과 동일한 플로우로 재진입한다.
      final submittedChildren = picked.children
          .where(_itemHasSubmittedCandidateForCombo)
          .toList(growable: false);
      if (submittedChildren.isEmpty) continue;
      final pendingKeys = submittedChildren
          .map((e) => (studentId: picked.studentId, itemId: e.id))
          .toList(growable: false);
      final seed = submittedChildren.firstWhere(
        _hasDirectHomeworkTextbookLink,
        orElse: () => submittedChildren.first,
      );
      await _handleSubmittedChipTapForPending(
        context: context,
        studentId: picked.studentId,
        hw: seed,
        targetKeys: pendingKeys,
        suppressCombo: true,
      );
      if (!mounted || !context.mounted) return;
      // 재귀적으로 다음 후보 추천을 계속 이어간다(matchKey 유지).
    }
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
      backgroundColor: const Color(0xFF1F1F1F),
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
            backgroundColor: const Color(0xFF1F1F1F),
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

String _formatDateWithWeekdayShort(DateTime dt) {
  const week = ['월', '화', '수', '목', '금', '토', '일'];
  return '${_formatDateShort(dt)} (${week[dt.weekday - 1]})';
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

  const _HomeworkCheckDraft({
    required this.progress,
    required this.issueType,
    required this.issueNote,
  });
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
  HomeworkItem hw, {
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
    if (pageText.isEmpty && countText.isEmpty) return '-';
    if (pageText.isEmpty) return countText;
    if (countText.isEmpty) return pageText;
    return '$pageText · $countText';
  }

  String childCheckHomeworkText(HomeworkItem child) {
    final homeworkCountRaw = assignmentCountsByItem[child.id] ?? 0;
    final homeworkCount = homeworkCountRaw < 0 ? 0 : homeworkCountRaw;
    return '검사 ${child.checkCount}회 · 숙제 $homeworkCount회';
  }

  final widgets = <Widget>[
    if (bookAndCourse.isNotEmpty) ...[
      LatexTextRenderer(
        bookAndCourse,
        style: const TextStyle(
          color: kDlgText,
          fontSize: 20,
          fontWeight: FontWeight.w900,
        ),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
      ),
      const SizedBox(height: 4),
    ],
    LatexTextRenderer(
      title,
      style: TextStyle(
        color: bookAndCourse.isNotEmpty ? kDlgTextSub : kDlgText,
        fontSize: bookAndCourse.isNotEmpty ? 15 : 18,
        fontWeight:
            bookAndCourse.isNotEmpty ? FontWeight.w600 : FontWeight.w800,
      ),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
    ),
    if (pageAndCount.isNotEmpty) ...[
      const SizedBox(height: 3),
      Text(
        pageAndCount,
        style: const TextStyle(color: kDlgTextSub, fontSize: 13),
      ),
    ],
  ];
  if (groupChildren.isEmpty) return widgets;

  widgets.addAll([
    const SizedBox(height: 12),
    Container(
      width: double.infinity,
      height: 1,
      color: const Color(0x223A4545),
    ),
    const SizedBox(height: 10),
    Text(
      '하위 과제 ${groupChildren.length}개',
      style: const TextStyle(
        color: kDlgText,
        fontSize: 14,
        fontWeight: FontWeight.w800,
      ),
    ),
    const SizedBox(height: 8),
  ]);

  const TextStyle groupChildTitleStyle = TextStyle(
    color: Color(0xFFB9C3BA),
    fontSize: 15,
    fontWeight: FontWeight.w600,
    height: 1.2,
  );
  const TextStyle groupChildMetaStyle = TextStyle(
    color: Color(0xFF8FA1A1),
    fontSize: 13.5,
    fontWeight: FontWeight.w600,
    height: 1.1,
  );

  for (int i = 0; i < groupChildren.length; i++) {
    final child = groupChildren[i];
    final memo = (child.memo ?? '').trim();
    final memoText = memo.isEmpty ? '-' : memo;
    widgets.add(
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${i + 1}. ${childTitle(child)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: groupChildTitleStyle,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    childCheckHomeworkText(child),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: groupChildMetaStyle,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
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
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    memoText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: groupChildMetaStyle,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (i != groupChildren.length - 1) {
      widgets.addAll([
        const SizedBox(height: 5),
        Container(
          width: double.infinity,
          height: 1,
          color: const Color(0x223A4545),
        ),
        const SizedBox(height: 5),
      ]);
    }
  }

  return widgets;
}

Future<_HomeworkCheckDraft?> _showHomeworkItemCheckDialog({
  required BuildContext context,
  required HomeworkItem hw,
  required _HomeworkCheckTarget target,
  required int minProgress,
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
  final noteController = ImeAwareTextEditingController(
    text: issueType == 'other' ? (target.issueNote ?? '') : '',
  );

  final result = await showDialog<_HomeworkCheckDraft>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          final maxContentHeight = math.max(
            320.0,
            math.min(MediaQuery.of(ctx).size.height * 0.66, 620.0),
          );
          return AlertDialog(
            backgroundColor: kDlgBg,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('숙제 검사',
                style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900)),
            content: SizedBox(
              width: 480,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxContentHeight),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10, top: 2),
                        child: Row(
                          children: [
                            Container(
                              width: 4,
                              height: 16,
                              decoration: BoxDecoration(
                                color: kDlgAccent,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(width: 10),
                            const Icon(
                              Icons.assignment_turned_in,
                              color: kDlgTextSub,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            const Text(
                              '숙제 내용',
                              style: TextStyle(
                                color: kDlgText,
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                _formatDateRange(
                                    target.assignedAt, target.dueDate),
                                textAlign: TextAlign.right,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: kDlgTextSub,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: _buildHomeworkCheckTargetInfo(
                            hw,
                            groupChildren: groupChildren,
                            assignmentCountsByItem: assignmentCountsByItem,
                            cycleMetaByItem: cycleMetaByItem,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      const YggDialogSectionHeader(
                          icon: Icons.tune_rounded, title: '완료율'),
                      Row(
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
                              inactiveColor: kDlgBorder,
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
                              style: const TextStyle(
                                  color: kDlgText,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800),
                              decoration: InputDecoration(
                                suffixText: '%',
                                suffixStyle:
                                    const TextStyle(color: kDlgTextSub),
                                filled: true,
                                fillColor: kDlgFieldBg,
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide:
                                      const BorderSide(color: kDlgBorder),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: const BorderSide(
                                      color: kDlgAccent, width: 1.4),
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 8),
                              ),
                              onChanged: (v) {
                                final parsed = int.tryParse(v);
                                if (parsed == null) return;
                                final safe =
                                    parsed.clamp(minProgress, progressMax);
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
                      const SizedBox(height: 12),
                      const YggDialogSectionHeader(
                          icon: Icons.flag_outlined, title: '미완료 사유 (선택)'),
                      Wrap(
                        spacing: 8,
                        children: [
                          YggDialogFilterChip(
                            label: '분실',
                            selected: issueType == 'lost',
                            onSelected: (v) => setState(() {
                              issueType = v ? 'lost' : null;
                              if (issueType != 'other')
                                noteController.text = '';
                            }),
                          ),
                          YggDialogFilterChip(
                            label: '잊음',
                            selected: issueType == 'forgot',
                            onSelected: (v) => setState(() {
                              issueType = v ? 'forgot' : null;
                              if (issueType != 'other')
                                noteController.text = '';
                            }),
                          ),
                          YggDialogFilterChip(
                            label: '기타',
                            selected: issueType == 'other',
                            onSelected: (v) => setState(() {
                              issueType = v ? 'other' : null;
                              if (!v) noteController.text = '';
                            }),
                          ),
                        ],
                      ),
                      if (issueType == 'other') ...[
                        const SizedBox(height: 8),
                        TextField(
                          controller: noteController,
                          minLines: 1,
                          maxLines: 2,
                          style: const TextStyle(color: kDlgText),
                          decoration: InputDecoration(
                            hintText: '사유를 입력하세요',
                            hintStyle:
                                const TextStyle(color: Color(0xFF6E7E7E)),
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
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                          ),
                        ),
                      ],
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
                onPressed: () {
                  final parsed = int.tryParse(progressController.text.trim());
                  final safeProgress =
                      (parsed ?? progress).clamp(minProgress, 150);
                  final issueNote =
                      issueType == 'other' ? noteController.text.trim() : null;
                  Navigator.of(ctx).pop(
                    _HomeworkCheckDraft(
                      progress: safeProgress,
                      issueType: issueType,
                      issueNote: issueNote?.isEmpty == true ? null : issueNote,
                    ),
                  );
                },
                style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
                child: const Text('저장'),
              ),
            ],
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

Future<bool> _runHomeworkCheckDialogOnly({
  required BuildContext context,
  required String studentId,
  required HomeworkItem hw,
}) async {
  final latest = HomeworkStore.instance.getById(studentId, hw.id);
  if (latest == null) return false;

  final target = await _resolveHomeworkCheckTarget(
    studentId,
    hw.id,
    includeHistory: false,
  );
  if (!context.mounted) return false;
  if (target == null) {
    _showHomeworkChipSnackBar(context, '숙제 할당 정보를 찾을 수 없습니다.');
    return false;
  }

  final checks = await HomeworkAssignmentStore.instance
      .loadChecksForItem(studentId, hw.id);
  checks.sort((a, b) => a.checkedAt.compareTo(b.checkedAt));
  final previousProgress = checks.isEmpty ? 0 : checks.last.progress;
  final minProgress = math.max(previousProgress, target.progress).clamp(0, 150);

  if (!context.mounted) return false;
  final draft = await _showHomeworkItemCheckDialog(
    context: context,
    hw: latest,
    target: target,
    minProgress: minProgress,
  );
  if (!context.mounted || draft == null) return false;

  final saved = await HomeworkAssignmentStore.instance.saveAssignmentCheck(
    assignmentId: target.assignmentId,
    studentId: studentId,
    homeworkItemId: hw.id,
    progress: draft.progress,
    issueType: draft.issueType,
    issueNote: draft.issueNote,
    markCompleted: false,
  );
  if (!context.mounted) return false;
  if (!saved) {
    _showHomeworkChipSnackBar(context, '숙제 검사 저장에 실패했습니다.');
    return false;
  }
  // 리얼타임 반영 중에도 순서 흔들림이 없도록,
  // 복귀 항목의 order_index를 먼저 "활성 꼬리"로 재배정한 뒤 노출한다.
  await HomeworkStore.instance.placeItemAtActiveTail(
    studentId,
    hw.id,
    activateFromHomework: true,
  );
  final bool isCompletedProgress = draft.progress >= 100;
  if (isCompletedProgress) {
    await HomeworkStore.instance.submit(studentId, hw.id);
  } else {
    await HomeworkStore.instance.waitPhase(studentId, hw.id);
  }
  await HomeworkAssignmentStore.instance.clearActiveAssignmentsForItems(
    studentId,
    [hw.id],
  );
  if (!context.mounted) return true;
  if (isCompletedProgress) {
    _showHomeworkChipSnackBar(context, '숙제 검사 완료 — 제출 상태로 이동했어요.');
  } else {
    _showHomeworkChipSnackBar(
      context,
      '완료율이 100% 미만이어서 대기 상태로 두었어요.',
    );
  }
  return true;
}

Future<bool> _runHomeworkCheckDialogForGroup({
  required BuildContext context,
  required String studentId,
  required HomeworkGroup? group,
  required HomeworkItem summary,
  required List<HomeworkItem> children,
}) async {
  final targetChildren = children
      .where((e) => e.status != HomeworkStatus.completed)
      .toList(growable: false);
  if (targetChildren.isEmpty) return false;

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
    if (!context.mounted) return false;
    if (target == null) {
      _showHomeworkChipSnackBar(context, '일부 하위 과제의 숙제 할당 정보를 찾지 못했습니다.');
      return false;
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

  if (targets.isEmpty || !context.mounted) return false;
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
  if (!context.mounted) return false;
  final cycleMetaByItem =
      await HomeworkAssignmentStore.instance.loadLatestCycleMetaByItem(
    studentId,
  );
  if (!context.mounted) return false;
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
    groupChildren: targetChildren,
    assignmentCountsByItem: groupAssignmentCounts,
    cycleMetaByItem: groupCycleMetaByItem,
  );
  if (!context.mounted || draft == null) return false;

  final savedItemIds = <String>[];
  for (final entry in targets) {
    final saved = await HomeworkAssignmentStore.instance.saveAssignmentCheck(
      assignmentId: entry.target.assignmentId,
      studentId: studentId,
      homeworkItemId: entry.item.id,
      progress: draft.progress,
      issueType: draft.issueType,
      issueNote: draft.issueNote,
      markCompleted: false,
    );
    if (!saved) continue;
    savedItemIds.add(entry.item.id);
  }

  if (savedItemIds.isEmpty) {
    if (!context.mounted) return false;
    _showHomeworkChipSnackBar(context, '그룹 숙제 검사 저장에 실패했습니다.');
    return false;
  }

  for (final itemId in savedItemIds) {
    await HomeworkStore.instance.placeItemAtActiveTail(
      studentId,
      itemId,
      activateFromHomework: true,
    );
    if (draft.progress >= 100) {
      await HomeworkStore.instance.submit(studentId, itemId);
    } else {
      await HomeworkStore.instance.waitPhase(studentId, itemId);
    }
  }
  await HomeworkAssignmentStore.instance
      .clearActiveAssignmentsForItems(studentId, savedItemIds);
  if (!context.mounted) return true;
  final groupTitle = (group?.title ?? '').trim();
  final summaryTitle = summary.title.trim();
  final prefix = groupTitle.isNotEmpty
      ? groupTitle
      : (summaryTitle.isNotEmpty ? summaryTitle : '그룹 숙제');
  if (draft.progress >= 100) {
    _showHomeworkChipSnackBar(
      context,
      '$prefix 검사 완료 — 하위 ${savedItemIds.length}개 과제를 제출 상태로 이동했어요.',
    );
  } else {
    _showHomeworkChipSnackBar(
      context,
      '$prefix 검사 저장 — 완료율이 100% 미만이어서 하위 ${savedItemIds.length}개를 대기 상태로 두었어요.',
    );
  }
  return true;
}

// ========== 채점 콤보(같은 교재·과제유형 연속 검사) ==========

enum _GradingComboSection { homework, submitted }

class _GradingComboMatchKey {
  final String bookId;
  final String typeLabel;
  const _GradingComboMatchKey({
    required this.bookId,
    required this.typeLabel,
  });
}

class _GradingComboCandidate {
  final String studentId;
  final String studentName;
  final HomeworkGroup? group;
  final HomeworkItem summary;
  final List<HomeworkItem> children;
  final String bookLabel;
  final String typeLabel;
  final String displayTitle;
  final int? firstPageNumber;
  final int orderIndex;

  const _GradingComboCandidate({
    required this.studentId,
    required this.studentName,
    required this.group,
    required this.summary,
    required this.children,
    required this.bookLabel,
    required this.typeLabel,
    required this.displayTitle,
    required this.firstPageNumber,
    required this.orderIndex,
  });

  bool get isGroup => group != null;
  String get uniqueKey => isGroup ? 'group:${group!.id}' : 'item:${summary.id}';
}

_GradingComboMatchKey? _resolveGradingComboMatchKey({
  HomeworkItem? summary,
  List<HomeworkItem> children = const [],
}) {
  String bookId = (summary?.bookId ?? '').trim();
  String typeLabel = (summary?.type ?? '').trim();
  for (final child in children) {
    if (bookId.isEmpty) bookId = (child.bookId ?? '').trim();
    if (typeLabel.isEmpty) typeLabel = (child.type ?? '').trim();
    if (bookId.isNotEmpty && typeLabel.isNotEmpty) break;
  }
  if (bookId.isEmpty || typeLabel.isEmpty) return null;
  return _GradingComboMatchKey(bookId: bookId, typeLabel: typeLabel);
}

int? _firstPageNumberOfHomework(HomeworkItem hw) {
  final raw = (hw.page ?? '').trim();
  if (raw.isEmpty) return null;
  final match = RegExp(r'\d+').firstMatch(raw);
  if (match == null) return null;
  return int.tryParse(match.group(0) ?? '');
}

int? _earliestFirstPageOfChildren(List<HomeworkItem> children) {
  int? best;
  for (final child in children) {
    final candidate = _firstPageNumberOfHomework(child);
    if (candidate == null) continue;
    if (best == null || candidate < best) best = candidate;
  }
  return best;
}

String _gradingComboBookLabelOf({
  required HomeworkItem summary,
  required List<HomeworkItem> children,
}) {
  final re = RegExp(r'(?:^|\n)\s*교재:\s*([^\n]+)');
  String? pick(HomeworkItem hw) {
    final raw = (hw.content ?? '').trim();
    if (raw.isEmpty) return null;
    final m = re.firstMatch(raw)?.group(1);
    if (m == null) return null;
    final t = m.trim();
    return t.isEmpty ? null : t;
  }

  final fromSummary = pick(summary);
  if (fromSummary != null) return fromSummary;
  for (final child in children) {
    final v = pick(child);
    if (v != null) return v;
  }
  final gradeLabel = (summary.gradeLabel ?? '').trim();
  if (gradeLabel.isNotEmpty) return gradeLabel;
  return summary.title.trim().isEmpty ? '(교재명 없음)' : summary.title.trim();
}

bool _itemHasSubmittedCandidateForCombo(HomeworkItem item) {
  return item.status != HomeworkStatus.completed &&
      item.phase == 3 &&
      item.completedAt == null;
}

Future<List<_GradingComboCandidate>> _collectGradingComboCandidates({
  required List<String> attendingStudentIds,
  required Map<String, String> studentNamesById,
  required _GradingComboMatchKey matchKey,
  required Set<String> excludeUniqueKeys,
  required _GradingComboSection section,
}) async {
  final store = HomeworkStore.instance;
  final assignmentStore = HomeworkAssignmentStore.instance;
  final out = <_GradingComboCandidate>[];
  for (final studentId in attendingStudentIds) {
    Set<String> assignedItemIds = <String>{};
    try {
      final assignments =
          await assignmentStore.loadActiveAssignments(studentId);
      for (final a in assignments) {
        if ((a.note ?? '').trim() == HomeworkAssignmentStore.reservationNote) {
          continue;
        }
        assignedItemIds.add(a.homeworkItemId);
      }
    } catch (_) {
      // 오프라인 등 실패 시에는 숙제 할당 필터를 완화하지 않고 건너뛴다.
      continue;
    }

    final coveredItemIds = <String>{};
    final groups = store.groups(studentId);
    for (final group in groups) {
      final childrenAll = store
          .itemsInGroup(studentId, group.id)
          .where((e) => e.status != HomeworkStatus.completed)
          .toList(growable: false);
      if (childrenAll.isEmpty) continue;
      coveredItemIds.addAll(childrenAll.map((e) => e.id));

      final summarySource = childrenAll.first;
      final groupBook = (summarySource.bookId ?? '').trim();
      final groupType = (summarySource.type ?? '').trim();
      if (groupBook != matchKey.bookId || groupType != matchKey.typeLabel) {
        continue;
      }

      final hasSubmitted = childrenAll.any(_itemHasSubmittedCandidateForCombo);
      final assignedChildren = childrenAll
          .where((c) => assignedItemIds.contains(c.id) && c.phase != 0)
          .toList(growable: false);

      final include = section == _GradingComboSection.submitted
          ? hasSubmitted
          : (!hasSubmitted && assignedChildren.isNotEmpty);
      if (!include) continue;

      final uniqueKey = 'group:${group.id}';
      if (excludeUniqueKeys.contains(uniqueKey)) continue;

      final displayTitle = group.title.trim().isNotEmpty
          ? group.title.trim()
          : summarySource.title.trim();
      out.add(_GradingComboCandidate(
        studentId: studentId,
        studentName: studentNamesById[studentId] ?? '학생',
        group: group,
        summary: summarySource,
        children: childrenAll,
        bookLabel: _gradingComboBookLabelOf(
          summary: summarySource,
          children: childrenAll,
        ),
        typeLabel: groupType,
        displayTitle: displayTitle.isEmpty ? '그룹 과제' : displayTitle,
        firstPageNumber: _earliestFirstPageOfChildren(childrenAll),
        orderIndex: group.orderIndex,
      ));
    }

    final looseItems = store
        .items(studentId)
        .where((e) => e.status != HomeworkStatus.completed)
        .where((e) => !coveredItemIds.contains(e.id))
        .toList(growable: false);
    for (final item in looseItems) {
      if ((item.bookId ?? '').trim() != matchKey.bookId) continue;
      if ((item.type ?? '').trim() != matchKey.typeLabel) continue;
      final uniqueKey = 'item:${item.id}';
      if (excludeUniqueKeys.contains(uniqueKey)) continue;
      final hasSubmitted = _itemHasSubmittedCandidateForCombo(item);
      final hasHomeworkAssignment =
          assignedItemIds.contains(item.id) && item.phase != 0;
      final include = section == _GradingComboSection.submitted
          ? hasSubmitted
          : (!hasSubmitted && hasHomeworkAssignment);
      if (!include) continue;
      out.add(_GradingComboCandidate(
        studentId: studentId,
        studentName: studentNamesById[studentId] ?? '학생',
        group: null,
        summary: item,
        children: [item],
        bookLabel: _gradingComboBookLabelOf(
          summary: item,
          children: [item],
        ),
        typeLabel: (item.type ?? '').trim(),
        displayTitle: item.title.trim().isEmpty ? '개별 숙제' : item.title.trim(),
        firstPageNumber: _firstPageNumberOfHomework(item),
        orderIndex: item.orderIndex,
      ));
    }
  }

  out.sort((a, b) {
    final ap = a.firstPageNumber;
    final bp = b.firstPageNumber;
    if (ap != null && bp != null) {
      final cmp = ap.compareTo(bp);
      if (cmp != 0) return cmp;
    } else if (ap != null && bp == null) {
      return -1; // 페이지 있는 쪽이 먼저
    } else if (ap == null && bp != null) {
      return 1;
    }
    final oi = a.orderIndex.compareTo(b.orderIndex);
    if (oi != 0) return oi;
    final nameCmp = a.studentName.compareTo(b.studentName);
    if (nameCmp != 0) return nameCmp;
    return a.uniqueKey.compareTo(b.uniqueKey);
  });
  return out;
}

Future<_GradingComboCandidate?> _showGradingComboDialog({
  required BuildContext context,
  required _GradingComboCandidate recommended,
  required List<_GradingComboCandidate> candidates,
  required _GradingComboSection section,
}) {
  final sectionLabel = section == _GradingComboSection.submitted ? '제출' : '숙제';
  return showDialog<_GradingComboCandidate?>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      String selectedKey = recommended.uniqueKey;
      return StatefulBuilder(
        builder: (ctx, setInner) {
          return AlertDialog(
            backgroundColor: kDlgBg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            title: Text(
              '이어서 검사할 $sectionLabel 과제',
              style: const TextStyle(
                color: kDlgText,
                fontWeight: FontWeight.w800,
                fontSize: 18,
              ),
            ),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560, maxHeight: 440),
              child: SizedBox(
                width: 520,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '같은 교재 · 같은 유형(${recommended.typeLabel})의 후보입니다.',
                      style: const TextStyle(
                        color: kDlgTextSub,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: candidates.length,
                        separatorBuilder: (_, __) => const Divider(
                          height: 1,
                          color: Color(0xFF23333D),
                        ),
                        itemBuilder: (ctx, i) {
                          final c = candidates[i];
                          final pageLabel = c.firstPageNumber == null
                              ? '페이지 미정'
                              : 'p.${c.firstPageNumber}';
                          final meta = <String>[
                            c.studentName,
                            if (c.bookLabel.trim().isNotEmpty) c.bookLabel,
                            if (c.typeLabel.trim().isNotEmpty) c.typeLabel,
                            pageLabel,
                          ].join(' · ');
                          final isRecommended =
                              c.uniqueKey == recommended.uniqueKey;
                          return RadioListTile<String>(
                            value: c.uniqueKey,
                            groupValue: selectedKey,
                            activeColor: kDlgAccent,
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            onChanged: (v) {
                              if (v == null) return;
                              setInner(() {
                                selectedKey = v;
                              });
                            },
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    c.displayTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: kDlgText,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14.5,
                                    ),
                                  ),
                                ),
                                if (isRecommended)
                                  Container(
                                    margin: const EdgeInsets.only(left: 6),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: kDlgAccent.withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Text(
                                      '추천',
                                      style: TextStyle(
                                        color: kDlgAccent,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            subtitle: Text(
                              meta,
                              style: const TextStyle(
                                color: kDlgTextSub,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
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
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
                child: const Text('중단'),
              ),
              FilledButton(
                onPressed: () {
                  final picked = candidates.firstWhere(
                    (e) => e.uniqueKey == selectedKey,
                    orElse: () => recommended,
                  );
                  Navigator.of(ctx).pop(picked);
                },
                style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
                child: const Text('이 항목으로 계속'),
              ),
            ],
          );
        },
      );
    },
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
  required VoidCallback onTap,
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

  return GestureDetector(
    onTap: onTap,
    behavior: HitTestBehavior.opaque,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 170),
      curve: Curves.easeOutCubic,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0x221D2B2C),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isExpanded ? const Color(0xFF36525A) : const Color(0xFF31464C),
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
                  entry.flowLabel,
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
              const Text(
                '1개 과제',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
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
                      valueColor:
                          const AlwaysStoppedAnimation<Color>(kDlgAccent),
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
                    color: entry.checkedToday
                        ? kDlgAccent
                        : const Color(0xFF8EA3A8),
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
    ),
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

  DateTime? completedTimestampOf(HomeworkItem child) {
    return child.completedAt ?? child.updatedAt ?? child.createdAt;
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
        if (!(child.status == HomeworkStatus.completed ||
            child.completedAt != null)) {
          return false;
        }
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
    final pageLabels = <String>[];
    int totalQuestionCount = 0;
    int groupCheckCount = 0;
    int homeworkCount = 0;
    HomeworkAssignmentBrief? latestBrief;
    for (final child in children) {
      final page = (child.page ?? '').trim();
      if (page.isNotEmpty &&
          !pageLabels.contains(page) &&
          pageLabels.length < 4) {
        pageLabels.add(page);
      }
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
    final String pageSummary = () {
      if (pageLabels.isEmpty) return '-';
      if (pageLabels.length <= 3) return pageLabels.join(', ');
      return '${pageLabels.take(3).join(', ')}, ...';
    }();
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
        color: const Color(0x221D2B2C),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isExpanded ? const Color(0xFF36525A) : const Color(0xFF31464C),
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
                  entry.line1Right,
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
      (_isTestHomeworkType(hw.type) && (hw.timeLimitMinutes ?? 0) > 0)
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

HomeworkItem _copyHomeworkItemForInlineEdit(
  HomeworkItem source, {
  String? page,
  String? memo,
  String? content,
}) {
  return HomeworkItem(
    id: source.id,
    assignmentCode: source.assignmentCode,
    title: source.title,
    body: source.body,
    color: source.color,
    flowId: source.flowId,
    testOriginFlowId: source.testOriginFlowId,
    type: source.type,
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
  final hasTestEntries = entries.any(
    (entry) => _isTestHomeworkType(entry['type'] as String?),
  );
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
    final typeLabel = (entry['type'] as String?)?.trim();
    final isTestCard = _isTestHomeworkType(typeLabel);
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

const double _homeworkChipCollapsedHeight = 160.0;
const double _homeworkChipExpandedHeight = 238.0;
double _homeworkGroupExpandedHeightForChildCount(int childCount) {
  if (childCount <= 0) return _homeworkChipExpandedHeight;
  // 상단 정보와 하위 리스트를 충분히 분리하고,
  // 하위 과제 수에 비례해 카드 높이가 늘어나도록 계산한다.
  const double groupSectionHeaderHeight = 58;
  const double perChildRowHeight = 102;
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
  if (!RegExp(r'^[A-Z]{4}[0-9]{4}$').hasMatch(code)) return fallback;
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
  Map<({String studentId, String itemId}), bool> pendingConfirms = const {},
  Future<void> Function(
          {required BuildContext context,
          required String studentId,
          required HomeworkItem hw})?
      onPhase3Tap,
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
                  for (final assignment in activeAssignments) {
                    final hwId = assignment.homeworkItemId.trim();
                    if (hwId.isEmpty) continue;
                    if (_isReservationAssignment(assignment)) {
                      hiddenItemIds.add(hwId);
                      continue;
                    }
                    final dueDate = assignment.dueDate;
                    final dueDateOnly =
                        dueDate == null ? null : _dateOnly(dueDate);
                    final assignmentGroupId = (assignment.groupId ?? '').trim();
                    if (assignmentGroupId.isNotEmpty) {
                      assignmentDueByGroupId[assignmentGroupId] =
                          _mergeHomeworkDueDate(
                        assignmentDueByGroupId[assignmentGroupId],
                        dueDateOnly,
                      );
                    }
                    assignmentDueByItemId[hwId] = _mergeHomeworkDueDate(
                      assignmentDueByItemId[hwId],
                      dueDateOnly,
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
                        builder: (context, _rev, _) {
                          final chips = _buildHomeworkChipsOnceForStudent(
                            context,
                            studentId,
                            tick,
                            flowNames,
                            assignmentCounts,
                            hiddenItemIds,
                            assignmentCycleMetaByItem,
                            assignmentDueByGroupId: assignmentDueByGroupId,
                            assignmentDueByItemId: assignmentDueByItemId,
                            pendingConfirms: pendingConfirms,
                            onPhase3Tap: onPhase3Tap,
                            onGroupSubmittedDoubleTap:
                                onGroupSubmittedDoubleTap,
                            printPickMode: printPickMode,
                            onPrintPickTap: onPrintPickTap,
                            onGroupPrintPickTap: onGroupPrintPickTap,
                            onPrintPickLongPress: onPrintPickLongPress,
                            onGroupPrintPickLongPress:
                                onGroupPrintPickLongPress,
                            onPrintPickSecondaryTap: onPrintPickSecondaryTap,
                            onSlideDownComplete: onSlideDownComplete,
                            expandedHomeworkIds: expandedHomeworkIds,
                            onToggleExpand: onToggleExpand,
                          );
                          final columnChildren = <Widget>[];
                          for (final chip in chips) {
                            if (columnChildren.isNotEmpty) {
                              columnChildren.add(const SizedBox(height: 17));
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
                                crossAxisAlignment: CrossAxisAlignment.start,
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
  return '${dueDate.month}월 ${dueDate.day}일까지';
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
  if (!enableReorderDrag) return chipVisual;
  return ReorderableDelayedDragStartListener(
    index: index,
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
    final pageLabels = <String>[];
    int totalQuestionCount = 0;
    int totalAssignmentCount = 0;
    DateTime? dueDate;
    for (final entry in entries) {
      final assignment = entry.key;
      final hw = entry.value;
      final flowId = (hw.flowId ?? assignment.flowId ?? '').trim();
      final flowLabel = (flowNames[flowId] ?? '').trim();
      if (flowLabel.isNotEmpty) flowLabels.add(flowLabel);
      final page = (hw.page ?? '').trim();
      if (page.isNotEmpty && !pageLabels.contains('p.$page')) {
        pageLabels.add('p.$page');
      }
      final count = hw.count ?? 0;
      if (count > 0) totalQuestionCount += count;
      totalAssignmentCount += assignmentCounts[hw.id] ?? 0;
      dueDate = _mergeHomeworkDueDate(
        dueDate,
        assignment.dueDate == null ? null : _dateOnly(assignment.dueDate!),
      );
    }

    final String flowSummary = flowLabels.isEmpty
        ? '플로우 미지정'
        : (flowLabels.length == 1
            ? flowLabels.first
            : '플로우 ${flowLabels.length}개');
    final String topMeta = <String>[
      flowSummary,
      if (pageLabels.isNotEmpty) pageLabels.take(3).join(', '),
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
                  style: const TextStyle(
                    color: Color(0xFFB9C3BA),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                SizedBox(
                  width: double.infinity,
                  child: Text(
                    childPageCountLabel(hw),
                    style: const TextStyle(
                      color: Color(0xFF8FA1A1),
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      height: 1.1,
                    ),
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
                    style: const TextStyle(
                      color: Color(0xFF8FA1A1),
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      height: 1.1,
                    ),
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
            color: const Color(0x223A4545),
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
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          constraints: BoxConstraints(
            minHeight:
                isExpanded ? expandedReservedHeight : collapsedReservedHeight,
          ),
          decoration: BoxDecoration(
            color: const Color(0xFF15171C),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isExpanded
                  ? const Color(0xFF33554C)
                  : const Color(0xFF273338),
              width: isExpanded ? 1.4 : 1.1,
            ),
            boxShadow: isExpanded
                ? const [
                    BoxShadow(
                      color: Color(0x22000000),
                      blurRadius: 8,
                      offset: Offset(0, 3),
                    ),
                  ]
                : const [],
          ),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.inventory_2_rounded,
                    size: 17,
                    color: Color(0xFF8FA3A8),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      line1TextbookLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFCAD2C5),
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                      ),
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
                      color: kDlgTextSub,
                    ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                line2GroupTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFFB9C3BA),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                topMeta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF8FA1A1),
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                bottomMeta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kDlgAccent,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                ),
              ),
              if (isExpanded) ...[
                const SizedBox(height: 20),
                const Divider(
                  height: 1,
                  thickness: 1.2,
                  color: Color(0x80FFFFFF),
                ),
                const SizedBox(height: 16),
                Text(
                  '그룹 과제 ${entries.length}개',
                  style: const TextStyle(
                    color: Color(0xFFCAD2C5),
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    height: 1.1,
                  ),
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
  Map<String, DateTime?> assignmentDueByGroupId = const {},
  Map<String, DateTime?> assignmentDueByItemId = const {},
  Map<({String studentId, String itemId}), bool> pendingConfirms = const {},
  Future<void> Function(
          {required BuildContext context,
          required String studentId,
          required HomeworkItem hw})?
      onPhase3Tap,
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
      final p = (child.page ?? '').trim();
      if (p.isNotEmpty && pages.length < 4) pages.add(p);
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

    int phase = 1;
    if (runtimePhase >= 1 && runtimePhase <= 4) {
      phase = runtimePhase;
    } else if (runningChild != null) {
      phase = 2;
    } else if (hasSubmitted) {
      phase = 3;
    } else if (hasConfirmed) {
      phase = 4;
    } else {
      phase = maxPhase.clamp(1, 4);
    }
    final pageSummary = () {
      if (pages.isEmpty) return '';
      if (pages.length <= 3) return pages.join(', ');
      return '${pages.take(3).join(', ')}, ...';
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
    final bool hasRuntimeSnapshot = runtimePhase >= 1 && runtimePhase <= 4;
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
    final bool groupExpanded =
        hasRunningChild || expandedHomeworkIds.contains(group.id);
    DateTime? dueDate = assignmentDueByGroupId[group.id];
    bool hasHomeworkAssignment = assignmentDueByGroupId.containsKey(group.id);
    for (final child in children) {
      if (assignmentDueByItemId.containsKey(child.id)) {
        hasHomeworkAssignment = true;
      }
      dueDate = _mergeHomeworkDueDate(dueDate, assignmentDueByItemId[child.id]);
    }
    final dueLabel =
        dueDate == null ? null : _formatHomeworkDueChipLabel(dueDate);
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
    final bool hasTestChild =
        children.any((child) => _isTestHomeworkType(child.type));
    final bool blockDoubleTapForUncheckedHomework =
        hasHomeworkAssignment && !groupIsSubmitted && !groupIsConfirmed;
    final bool groupSlideDownIsEdit = groupIsWaiting || groupIsConfirmed;
    final bool groupCanSlideDown =
        groupIsRunning || groupIsSubmitted || groupSlideDownIsEdit;
    final String groupDownLabel = groupSlideDownIsEdit
        ? '수정'
        : (groupIsSubmitted ? '완료' : (groupIsRunning ? '멈춤' : ''));
    HomeworkItem? runningChildForSlide;
    if (groupIsRunning) {
      for (final child in children) {
        if (child.runStart != null || child.phase == 2) {
          runningChildForSlide = child;
          break;
        }
      }
    }

    final groupCard = _SlideableHomeworkChip(
      key: ValueKey('hw_group_chip_${group.id}'),
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
        if (hasHomeworkAssignment) {
          unawaited(
            _runHomeworkCheckDialogForGroup(
              context: context,
              studentId: studentId,
              group: group,
              summary: summary,
              children: children,
            ),
          );
          return;
        }
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
        if (blockDoubleTapForUncheckedHomework) return;
        if (submittedChildren.isNotEmpty) {
          onGroupSubmittedDoubleTap?.call(studentId, submittedChildren);
          return;
        }
        if (summary.phase == 1 &&
            hasTestChild &&
            !HomeworkStore.instance.isStudentInClassTime(studentId)) {
          _showHomeworkChipSnackBar(context, '테스트 카드는 수업시간에만 수행할 수 있어요.');
          return;
        }
        unawaited(
          HomeworkStore.instance.bulkTransitionGroup(
            studentId,
            group.id,
            fromPhase: groupIsConfirmed ? 4 : null,
          ),
        );
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
          isHomeworkDue: hasHomeworkAssignment,
          isExpanded: groupExpanded,
          groupChildren: children,
          chipHeightOverride: chipH,
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
          onGroupChildMemoTap: (child) {
            unawaited(
              _showGroupChildMemoEditDialog(
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
  final bool isTest;

  const _HomeworkPrintOverlayMeta({
    required this.assignedDateText,
    required this.bookCourseText,
    required this.studentName,
    required this.assignmentCodeText,
    this.isTest = false,
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
      isTest: _isTestHomeworkType(fallbackHomework.type),
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
  final sortedCodes = byId.values
      .map((hw) =>
          _formatHomeworkAssignmentCode(hw.assignmentCode, fallback: ''))
      .where((code) => code.isNotEmpty)
      .toSet()
      .toList(growable: false)
    ..sort();
  final String assignmentCodeText = sortedCodes.isEmpty
      ? '-'
      : (sortedCodes.length == 1
          ? sortedCodes.first
          : '${sortedCodes.first} 외 ${sortedCodes.length - 1}건');
  final bool isTestMeta =
      byId.values.any((hw) => _isTestHomeworkType(hw.type)) ||
          _isTestHomeworkType(fallbackHomework.type);
  return _HomeworkPrintOverlayMeta(
    assignedDateText: assignedDateText,
    bookCourseText: bookCourseText,
    studentName: _resolveHomeworkPrintStudentName(studentId),
    assignmentCodeText: assignmentCodeText,
    isTest: isTestMeta,
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
  final line1Parts = <String>[
    if (meta.assignedDateText.trim().isNotEmpty && meta.assignedDateText != '-')
      meta.assignedDateText,
    if (meta.bookCourseText.trim().isNotEmpty) meta.bookCourseText,
  ];
  final line1 = line1Parts.isEmpty ? '-' : line1Parts.join(' · ');
  final line2 = meta.studentName.trim().isEmpty ? '학생' : meta.studentName;
  final assignmentCodeText =
      meta.assignmentCodeText.trim().isEmpty ? '-' : meta.assignmentCodeText;
  // 테스트 카드는 상단을 한 줄로(날짜·교재·학생명 합쳐서) 출력한다.
  final bool singleLineTop = meta.isTest;
  final String singleLineText = () {
    final parts = <String>[
      if (line1.trim().isNotEmpty && line1 != '-') line1,
      if (line2.trim().isNotEmpty) line2,
    ];
    return parts.isEmpty ? '-' : parts.join(' · ');
  }();

  if (bottomLeftLayout) {
    const double leftInset = 14;
    const double lineH = 14;
    const double pad = 2;
    final double bottomInset = bottomInsetOverride;
    final textBrush = sf.PdfSolidBrush(sf.PdfColor(32, 32, 32));

    final double infoBlockH = singleLineTop ? lineH : lineH * 2;
    final double infoTop = size.height - bottomInset - infoBlockH;
    final infoBgRect = Rect.fromLTWH(
      leftInset - pad,
      infoTop - pad,
      (singleLineTop ? 260 : 180) + pad * 2,
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
    if (singleLineTop) {
      g.drawString(
        singleLineText,
        line1Font,
        brush: textBrush,
        bounds: Rect.fromLTWH(leftInset, infoTop, 260, lineH),
        format: leftFormat,
      );
    } else {
      g.drawString(
        line1,
        line1Font,
        brush: textBrush,
        bounds: Rect.fromLTWH(leftInset, infoTop, 180, lineH),
        format: leftFormat,
      );
      g.drawString(
        line2,
        line2Font,
        brush: textBrush,
        bounds: Rect.fromLTWH(leftInset, infoTop + lineH, 180, lineH),
        format: leftFormat,
      );
    }

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
  if (singleLineTop) {
    g.drawString(
      singleLineText,
      line1Font,
      brush: textBrush,
      bounds: Rect.fromLTWH(left, topInset, boxWidth, lineH),
      format: format,
    );
  } else {
    g.drawString(
      line1,
      line1Font,
      brush: textBrush,
      bounds: Rect.fromLTWH(left, topInset, boxWidth, lineH),
      format: format,
    );
    g.drawString(
      line2,
      line2Font,
      brush: textBrush,
      bounds: Rect.fromLTWH(left, topInset + lineH, boxWidth, lineH),
      format: format,
    );
  }
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

String _toLocalFilePath(String rawPath) {
  final trimmed = rawPath.trim();
  if (trimmed.isEmpty || _isWebUrl(trimmed)) return '';
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
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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

String _mergeGroupPageText(List<HomeworkItem> items) {
  return mergeHomeworkPageRawStrings(items.map((e) => e.page));
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
  final hasTestChild = children.any((child) => _isTestHomeworkType(child.type));

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

String _shiftNormalizedPageRangeForPdf(String normalizedRange, int pageOffset) {
  final cleaned = normalizedRange.trim();
  if (cleaned.isEmpty || pageOffset == 0) return cleaned;
  final tokens = cleaned.split(',');
  final out = <String>[];
  for (final token in tokens) {
    final t = token.trim();
    if (t.isEmpty) continue;
    if (t.contains('-')) {
      final parts = t.split('-');
      if (parts.length != 2) continue;
      final s = int.tryParse(parts[0]);
      final e = int.tryParse(parts[1]);
      if (s == null || e == null) continue;
      int a = s + pageOffset;
      int b = e + pageOffset;
      if (a <= 0 && b <= 0) continue;
      if (a < 1) a = 1;
      if (b < 1) b = 1;
      if (a > b) {
        final temp = a;
        a = b;
        b = temp;
      }
      out.add(a == b ? '$a' : '$a-$b');
      continue;
    }
    final v = int.tryParse(t);
    if (v == null) continue;
    final shifted = v + pageOffset;
    if (shifted <= 0) continue;
    out.add('$shifted');
  }
  return out.join(',');
}

Future<int> _loadTextbookPageOffset({
  required String bookId,
  required String gradeLabel,
}) async {
  final bid = bookId.trim();
  final gl = gradeLabel.trim();
  if (bid.isEmpty || gl.isEmpty) return 0;
  try {
    final row = await DataManager.instance.loadTextbookMetadataPayload(
      bookId: bid,
      gradeLabel: gl,
    );
    final raw = row?['page_offset'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim()) ?? 0;
    return 0;
  } catch (_) {
    return 0;
  }
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
}) {
  return PrintRoutingService.instance.printFile(
    path: path,
    channel: PrintRoutingChannel.general,
    duplexMode: duplexMode,
    preferredPaperSize: preferredPaperSize,
    debugSource: 'class_content.waiting_chip',
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

bool _isPbPrintTarget({
  required HomeworkItem hw,
  HomeworkAssignmentDetail? assignment,
}) {
  final presetId = (hw.pbPresetId ?? '').trim();
  final liveReleaseId = (assignment?.liveReleaseId ?? '').trim();
  final exportJobId = (assignment?.releaseExportJobId ?? '').trim();
  return presetId.isNotEmpty ||
      liveReleaseId.isNotEmpty ||
      exportJobId.isNotEmpty;
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
  LearningProblemLiveRelease? assignmentRelease;
  final liveReleaseId = (assignment?.liveReleaseId ?? '').trim();
  if (liveReleaseId.isNotEmpty) {
    try {
      assignmentRelease = await pbService.getLiveReleaseById(
        academyId: safeAcademyId,
        liveReleaseId: liveReleaseId,
      );
      preferredPaperSize = (assignmentRelease?.paperSize ?? '').trim();
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

  final pbPresetId = (hw.pbPresetId ?? '').trim().isNotEmpty
      ? (hw.pbPresetId ?? '').trim()
      : (assignmentRelease?.presetId ?? '').trim();
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

Future<bool> _isPrintableResolvedHomeworkPrintSource(
  _ResolvedHomeworkPrintSource source,
) async {
  final raw = source.pathRaw.trim();
  if (raw.isEmpty) return false;
  if (_isWebUrl(raw)) return true;
  final localPath = _toLocalFilePath(raw);
  if (localPath.isEmpty) return false;
  return File(localPath).exists();
}

Future<String?> _materializePrintablePathFromSource(
  _ResolvedHomeworkPrintSource source, {
  required String cacheKey,
  LearningProblemBankService? problemBankService,
}) async {
  final raw = source.pathRaw.trim();
  if (raw.isEmpty) return null;
  if (_isWebUrl(raw)) {
    final pbService = problemBankService ?? LearningProblemBankService();
    try {
      final bytes = await pbService.downloadPdfBytesFromUrl(raw);
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
  final localPath = _toLocalFilePath(raw);
  if (localPath.isEmpty) return null;
  if (!await File(localPath).exists()) return null;
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
    return _normalizePageRangeForPrint(_mergeGroupPageText(picked));
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
                                  final pageText = (child.page ?? '').trim();
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
    );
  }

  if (bodyPath == null || bodyPath.isEmpty) {
    throw StateError('인쇄 파일을 찾을 수 없습니다.');
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
  final int pageOffset = (!resolvedSource.isProblemBank && isPdf)
      ? await _loadTextbookPageOffset(
          bookId: resolvedSource.bookId,
          gradeLabel: resolvedSource.gradeLabel,
        )
      : 0;
  final selectedRange = confirmResult.pageRange;
  String pathToPrint = printablePath;
  final rangeDisplay = _normalizePageRangeForPrint(selectedRange);
  final rangeRaw = resolvedSource.isProblemBank
      ? ''
      : _shiftNormalizedPageRangeForPdf(rangeDisplay, pageOffset);

  if (isPdf) {
    progressText?.value = rangeRaw.isEmpty
        ? '인쇄 파일을 준비하는 중입니다...'
        : '선택한 페이지를 인쇄 파일로 만드는 중입니다...';
    final out = await _buildPdfForPrintRange(
      inputPath: printablePath,
      pageRange: rangeRaw,
      overlayMeta: overlayMeta,
      preferredPaperSize: resolvedSource.preferredPaperSize,
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
  final printJobSentToSpooler = await _openPrintDialogForPath(
    pathToPrint,
    preferredPaperSize: resolvedSource.preferredPaperSize,
    duplexMode: confirmResult.duplexMode,
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
  final initialRangeRaw =
      isPbTarget ? '' : (initialRangeOverride ?? hw.page ?? '');
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
  String? canonicalPipelineKey;
  final observedPipelineKinds = <String>{};
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
    canonicalPipelineKey ??= pipelineKey;
    printableById[child.id] = canonicalPipelineKey == pipelineKey;
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
  final mergedPage = _mergeGroupPageText(defaultPrintableChildren);
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
    assignmentByItemId: assignmentByItemId,
    sourceByItemId: sourceByItemId,
    warning: observedPipelineKinds.length > 1
        ? '혼합 인쇄는 지원되지 않아요. 문제은행/교재를 분리해서 인쇄해 주세요.'
        : null,
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
  final initialRangeRaw =
      isPbTarget ? '' : (initialRangeOverride ?? (hw.page ?? ''));
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

Widget _buildFlowChip(
  String flowName, {
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
  final chipText = normalizedOverrideText.isNotEmpty
      ? normalizedOverrideText
      : (isHomeworkDue
          ? (normalizedDueLabel.isEmpty ? '검사일 미정' : normalizedDueLabel)
          : (normalizedDueLabel.isEmpty
              ? (normalizedFlowName.isEmpty ? '플로우 미지정' : normalizedFlowName)
              : (normalizedFlowName.isEmpty
                  ? normalizedDueLabel
                  : '$normalizedFlowName · $normalizedDueLabel')));
  final bool isDefault = normalizedFlowName == '현행' && !isHomeworkDue;
  final Color backgroundColor = overrideBackgroundColor ??
      (isHomeworkDue
          ? const Color(0x1F4FBF97)
          : (isDefault ? Colors.transparent : const Color(0xFF2A3030)));
  final Border? border = overrideBorder ??
      (isHomeworkDue
          ? Border.all(color: kDlgAccent, width: 1.05)
          : (isDefault
              ? Border.all(color: const Color(0xFF4A5858), width: 1)
              : null));
  final Color textColor = overrideTextColor ??
      (isHomeworkDue ? const Color(0xFF9FE3C6) : const Color(0xFF9FB3B3));
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
  bool isReservation = false,
  bool isExpanded = false,
  List<HomeworkItem> groupChildren = const <HomeworkItem>[],
  double? chipHeightOverride,
  HomeworkAssignmentCycleMeta? cycleMeta,
  bool isPendingConfirm = false,
  bool isCompleteCheckbox = false,
  VoidCallback? onInfoTap,
  VoidCallback? onGroupTitleTap,
  void Function(HomeworkItem child)? onGroupChildPageTap,
  void Function(HomeworkItem child)? onGroupChildMemoTap,
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
  final TextStyle titleStyle = const TextStyle(
    color: Color(0xFFCAD2C5),
    fontSize: 24,
    fontWeight: FontWeight.w700,
    height: 1.1,
  );
  final TextStyle metaStyle = const TextStyle(
    color: Color(0xFFCAD2C5),
    fontSize: 17,
    fontWeight: FontWeight.w600,
    height: 1.1,
  );
  final TextStyle statStyle = const TextStyle(
    color: Color(0xFF7F8C8C),
    fontSize: 14.5,
    fontWeight: FontWeight.w600,
    height: 1.1,
  );
  final TextStyle line4Style = const TextStyle(
    color: Color(0xFF748686),
    fontSize: 13.5,
    fontWeight: FontWeight.w600,
    height: 1.1,
  );
  final TextStyle typeStyle = const TextStyle(
    color: Color(0xFFCAD2C5),
    fontSize: 17,
    fontWeight: FontWeight.w600,
    height: 1.1,
  );
  final TextStyle groupChildTitleStyle = const TextStyle(
    color: Color(0xFFB9C3BA),
    fontSize: 15,
    fontWeight: FontWeight.w600,
    height: 1.2,
  );
  final TextStyle groupChildMetaStyle = const TextStyle(
    color: Color(0xFF8FA1A1),
    fontSize: 13.5,
    fontWeight: FontWeight.w600,
    height: 1.1,
  );
  const double leftPad = 24;
  const double rightPad = 24;
  final double chipHeight = chipHeightOverride ??
      (isExpanded ? _homeworkChipExpandedHeight : _homeworkChipCollapsedHeight);
  const double borderWMax = 3.0;

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
  final int repeatIndex = (cycleMeta?.repeatIndex ?? 1).clamp(1, 1 << 30);
  final int splitParts =
      (cycleMeta?.splitParts ?? hw.defaultSplitParts).clamp(1, 4);
  final int splitRound = (cycleMeta?.splitRound ?? 1).clamp(1, splitParts);
  final String titleText = (hw.title).trim();
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
  final String line4TotalCountText =
      '총 ${displayCount.isNotEmpty ? displayCount : '-'}문항';
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
  final String durationText = _formatDurationMs(totalMs);
  final String startedAtText =
      hw.firstStartedAt == null ? '-' : _formatShortTime(hw.firstStartedAt!);
  final String rawTypeText =
      (hw.type ?? '').trim().isEmpty ? '-' : (hw.type ?? '').trim();

  final String startDateText = hw.firstStartedAt != null
      ? '${hw.firstStartedAt!.month.toString().padLeft(2, '0')}.${hw.firstStartedAt!.day.toString().padLeft(2, '0')}'
      : (hw.createdAt != null
          ? '${hw.createdAt!.month.toString().padLeft(2, '0')}.${hw.createdAt!.day.toString().padLeft(2, '0')}'
          : '-');

  final String line5Left = '검사 ${hw.checkCount}회 · 숙제 ${homeworkCount}회';
  final String repeatCycleText = '${repeatIndex}회차';
  final String splitCycleText =
      splitParts > 1 ? '${splitParts}분할 ${splitRound}차' : '';
  final String line5Right = splitCycleText.isEmpty
      ? repeatCycleText
      : '$repeatCycleText · $splitCycleText';
  final sortedAssignmentCodes = (groupChildren.isNotEmpty
          ? groupChildren
          : [hw])
      .map((item) =>
          _formatHomeworkAssignmentCode(item.assignmentCode, fallback: ''))
      .where((code) => code.isNotEmpty)
      .toSet()
      .toList(growable: false)
    ..sort();
  final String assignmentCodeText = sortedAssignmentCodes.isEmpty
      ? '-'
      : (sortedAssignmentCodes.length == 1
          ? sortedAssignmentCodes.first
          : '${sortedAssignmentCodes.first} 외 ${sortedAssignmentCodes.length - 1}건');
  final double fixedWidth = ClassContentScreen._studentColumnContentWidth;
  final double maxRowW = fixedWidth - leftPad - rightPad;
  final bool hasGroupChildren = groupChildren.isNotEmpty;
  final bool isTestCard = hasGroupChildren
      ? groupChildren.any((child) => _isTestHomeworkType(child.type))
      : _isTestHomeworkType(hw.type);
  final int progressMsForDisplay =
      isTestCard ? totalMs : cycleProgressMsForDisplay;
  final int progressMinutes =
      progressMsForDisplay <= 0 ? 0 : (progressMsForDisplay ~/ 60000);
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
    if (shouldAutoSubmitForTimeout &&
        !_testAutoSubmitTriggeredKeys.contains(autoSubmitKey)) {
      _testAutoSubmitTriggeredKeys.add(autoSubmitKey);
      _testTimedOutHomeworkKeys.add(timeoutBadgeKey);
      unawaited(() async {
        await HomeworkStore.instance.submit(studentId, hw.id);
        final latest = HomeworkStore.instance.getById(studentId, hw.id);
        if (latest != null && latest.phase == 2) {
          _testAutoSubmitTriggeredKeys.remove(autoSubmitKey);
        }
      }());
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
  final String progressText = '진행 ${progressMinutes}분';
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
  final Border border = (visualPhase == 3)
      ? Border.all(color: Colors.transparent, width: borderWMax)
      : (visualRunning
          ? Border.all(
              color: unifiedHomeworkAccent.withOpacity(0.9), width: borderWMax)
          : (visualPhase == 4
              ? Border.all(
                  color: Color.lerp(
                        Colors.white24,
                        unifiedHomeworkAccent.withOpacity(0.9),
                        phase4Pulse,
                      ) ??
                      Colors.white24,
                  width: borderWMax,
                )
              : (visualPhase == 1
                  ? Border.all(color: Colors.transparent, width: borderWMax)
                  : Border.all(color: Colors.white24, width: borderWMax))));

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
          const SizedBox(width: 8),
          SizedBox(
            width: 110,
            child: Text(
              typeText,
              style: typeStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    ),
  );

  Widget collapsedRow3 = ConstrainedBox(
    constraints: BoxConstraints(maxWidth: maxRowW),
    child: Row(
      children: [
        Text(startDateText, style: statStyle),
        const SizedBox(width: 8),
        Text(progressText, style: statStyle),
        const Spacer(),
        Text('총 $durationText', style: statStyle),
      ],
    ),
  );

  Widget collapsedRow4 = ConstrainedBox(
    constraints: BoxConstraints(maxWidth: maxRowW),
    child: Row(
      children: [
        Text('과제번호', style: line4Style),
        const Spacer(),
        Text(
          assignmentCodeText,
          style: line4Style.copyWith(color: const Color(0xFFB9C9C9)),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.right,
        ),
      ],
    ),
  );

  final List<Widget> columnChildren;
  if (isExpanded) {
    final String expandedLine3Left = '시작 $startedAtText · $progressText';
    final String expandedLine3Right = '총 $durationText';
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
      return '$page · $count';
    }

    String groupChildMemoLabel(HomeworkItem child) {
      final memo = (child.memo ?? '').trim();
      return memo.isEmpty ? '-' : memo;
    }

    Widget buildGroupChildRow(HomeworkItem child, int index) {
      final bool childHasAssignment = assignedItemIds.contains(child.id);
      final bool canDragChild = onGroupChildDropBefore != null &&
          child.status != HomeworkStatus.completed &&
          child.phase == 1 &&
          !childHasAssignment;
      final bool canTapPage = onGroupChildPageTap != null;
      final bool canTapMemo = onGroupChildMemoTap != null;

      Widget buildRowCore({
        required bool enablePageTap,
        required bool enableMemoTap,
      }) {
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxRowW),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${index + 1}. ',
                      style: groupChildTitleStyle,
                    ),
                    Expanded(
                      child: LatexTextRenderer(
                        groupChildLabel(child),
                        style: groupChildTitleStyle,
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
                  child: SizedBox(
                    width: double.infinity,
                    child: Text(
                      groupChildPageCountLabel(child),
                      style: groupChildMetaStyle.copyWith(
                        decoration: enablePageTap
                            ? TextDecoration.underline
                            : TextDecoration.none,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: enableMemoTap
                      ? () => onGroupChildMemoTap?.call(child)
                      : null,
                  child: SizedBox(
                    width: double.infinity,
                    child: Text(
                      groupChildMemoLabel(child),
                      style: groupChildMetaStyle.copyWith(
                        decoration: enableMemoTap
                            ? TextDecoration.underline
                            : TextDecoration.none,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }

      final baseRow = buildRowCore(
        enablePageTap: canTapPage,
        enableMemoTap: canTapMemo,
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF202629),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF3E5757)),
                ),
                child: buildRowCore(enablePageTap: false, enableMemoTap: false),
              ),
            ),
          ),
          childWhenDragging: Opacity(
            opacity: 0.32,
            child: buildRowCore(
              enablePageTap: canTapPage,
              enableMemoTap: canTapMemo,
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

    columnChildren = [
      row1,
      const SizedBox(height: 19),
      row2,
      const SizedBox(height: 7),
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxRowW),
        child: Row(
          children: [
            Expanded(
              child: Text(
                expandedLine3Left,
                style: statStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              expandedLine3Right,
              style: statStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
            ),
          ],
        ),
      ),
      const SizedBox(height: 6),
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxRowW),
        child: Row(
          children: [
            Expanded(
              child: Text(
                line4PageText,
                style: line4Style,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              line4TotalCountText,
              style: line4Style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
            ),
          ],
        ),
      ),
      const SizedBox(height: 6),
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxRowW),
        child: Row(
          children: [
            Expanded(
              child: Text(
                line5Left,
                style: line4Style,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                line5Right,
                style: line4Style,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 6),
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxRowW),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '과제번호',
                style: line4Style,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                assignmentCodeText,
                style: line4Style.copyWith(color: const Color(0xFFB9C9C9)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
      ),
      if (hasGroupChildren) ...[
        const SizedBox(height: 16),
        Container(
          width: maxRowW,
          height: 1,
          color: const Color(0x80FFFFFF),
        ),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxRowW),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '그룹 과제 ${groupChildren.length}개',
                  style: metaStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (onInfoTap != null)
                GestureDetector(
                  onTap: onInfoTap,
                  behavior: HitTestBehavior.opaque,
                  child: const SizedBox(
                    width: 34,
                    height: 34,
                    child: Icon(
                      Icons.info_outline_rounded,
                      size: 24,
                      color: Color(0xFF9FB3B3),
                    ),
                  ),
                ),
              if (onInfoTap != null && onGroupChildAddTap != null)
                const SizedBox(width: 4),
              if (onGroupChildAddTap != null)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onGroupChildAddTap,
                  child: const SizedBox(
                    width: 34,
                    height: 34,
                    child: Icon(
                      Icons.add_rounded,
                      size: 24,
                      color: Color(0xFF9FE3C6),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        for (int i = 0; i < visibleGroupChildren; i++) ...[
          buildGroupChildRow(groupChildren[i], i),
          if (i != visibleGroupChildren - 1) ...[
            const SizedBox(height: 10),
            Container(
              width: maxRowW,
              height: 1.3,
              color: const Color(0x66FFFFFF),
            ),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 6),
        ],
      ],
    ];
  } else {
    columnChildren = [
      row1,
      const SizedBox(height: 19),
      row2,
      const SizedBox(height: 7),
      collapsedRow3,
      const SizedBox(height: 6),
      collapsedRow4,
    ];
  }

  Widget chipInner = Container(
    height: chipHeight,
    padding: const EdgeInsets.fromLTRB(leftPad, 14, rightPad, 14),
    alignment: Alignment.topLeft,
    decoration: BoxDecoration(
      color: const Color(0xFF15171C),
      borderRadius: BorderRadius.circular(12),
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
    child: Align(
      alignment: Alignment.topLeft,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: columnChildren,
      ),
    ),
  );

  if (!visualRunning && visualPhase == 3) {
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
                color: const Color(0xCC0B1112),
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

// 회전 보더 페인터: 내부 child 레이아웃을 바꾸지 않고 외곽선만 회전시켜 그림
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

class _HomeworkOverviewEntry {
  final String homeworkItemId;
  final String title;
  final DateTime assignedAt;
  final DateTime? dueDate;
  final bool checkedToday;
  final DateTime? checkedAt;
  final int progress;
  final bool isActive;
  final String flowLabel;
  final String overviewLine1Left;
  final String expandLine4Left;
  final String expandLine4Right;
  final String expandLine5Left;
  final String expandLine5Right;
  final List<_HomeworkOverviewCompletedChildEntry> expandChildren;

  const _HomeworkOverviewEntry({
    required this.homeworkItemId,
    required this.title,
    required this.assignedAt,
    required this.dueDate,
    required this.checkedToday,
    required this.checkedAt,
    required this.progress,
    required this.isActive,
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
                                            ScaffoldMessenger.of(dialogContext)
                                                .showSnackBar(
                                              const SnackBar(
                                                content: Text(
                                                  '되돌릴 채점 대상을 찾지 못했습니다. 다시 시도해 주세요.',
                                                ),
                                              ),
                                            );
                                            return;
                                          }
                                          ScaffoldMessenger.of(dialogContext)
                                              .showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                rollbackCount > 0
                                                    ? '채점 ${restoredCount}건을 대기 상태로 되돌렸어요. 검사 기록도 조정했습니다.'
                                                    : '채점 ${restoredCount}건을 대기 상태로 되돌렸어요.',
                                              ),
                                            ),
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

class _SlideableHomeworkChip extends StatefulWidget {
  final Widget child;
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
    final TextStyle labelStyle = const TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w700,
      height: 1.1,
    );

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              color: kDlgBg,
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
                                    if (widget.upSubLabel
                                        .trim()
                                        .isNotEmpty) ...[
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
          ),
        ),
        AnimatedContainer(
          duration:
              _dragging ? Duration.zero : const Duration(milliseconds: 160),
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
              child: widget.child,
            ),
          ),
        ),
      ],
    );
  }
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

  @override
  Widget build(BuildContext context) {
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
          child: ValueListenableBuilder(
              valueListenable: DataManager.instance.studentsNotifier,
              builder: (context, _, __) => ValueListenableBuilder<int>(
                  valueListenable: DataManager.instance.deviceBindingsRevision,
                  builder: (context, _bindRev, __) =>
                      ValueListenableBuilder<int>(
                        valueListenable: HomeworkStore.instance.revision,
                        builder: (context, _rev, _) {
                          // 과제 진행 상태 확인
                          final items = HomeworkStore.instance
                              .items(studentId)
                              .where(
                                  (e) => e.status != HomeworkStatus.completed)
                              .toList();
                          final bool hasAny = items.isNotEmpty;
                          final bool hasRunning =
                              HomeworkStore.instance.runningOf(studentId) !=
                                      null ||
                                  items.any(
                                    (e) => e.phase == 2 || e.runStart != null,
                                  );
                          final bool isResting =
                              hasAny && !hasRunning; // 모든 칩 정지 → 휴식 상태

                          // 학생 정보 조회(학교/학년)
                          String school = '';
                          String gradeText = '';
                          try {
                            final swi = DataManager.instance.students
                                .firstWhere((s) => s.student.id == studentId);
                            school = swi.student.school;
                            final int g = swi.student.grade;
                            gradeText = g > 0 ? (g.toString() + '학년') : '';
                          } catch (_) {}

                          final boundDevice =
                              DataManager.instance.boundDeviceId(studentId);
                          final deviceLabel = boundDevice != null
                              ? boundDevice.replaceAll(
                                  RegExp(r'^m5-device-'), '')
                              : null;

                          final nameStyle = TextStyle(
                            color: isResting ? Colors.white54 : Colors.white,
                            fontSize: 38,
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
                          final double nameHeight = (nameStyle.fontSize ?? 34) *
                              (nameStyle.height ?? 1.0);

                          return Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  const SizedBox(width: 12),
                                  Expanded(
                                    flex: 3,
                                    child: Text(
                                      name,
                                      style: nameStyle,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 20),
                                  Expanded(
                                    flex: 3,
                                    child: Align(
                                      alignment: Alignment.centerRight,
                                      child: SizedBox(
                                        height: nameHeight,
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.end,
                                          children: [
                                            Text(
                                              infoLine.isEmpty ? '-' : infoLine,
                                              style: const TextStyle(
                                                color: Colors.white70,
                                                fontSize: 16,
                                                height: 1.2,
                                                fontWeight: FontWeight.w600,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            Text(
                                              '등원 $arrivalText',
                                              style: const TextStyle(
                                                color: Colors.white54,
                                                fontSize: 14,
                                                height: 1.2,
                                                fontWeight: FontWeight.w600,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (deviceLabel != null)
                                Padding(
                                  padding:
                                      const EdgeInsets.only(top: 6, right: 0),
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: MouseRegion(
                                      cursor: SystemMouseCursors.click,
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: () async {
                                          final confirm =
                                              await showDialog<bool>(
                                            context: context,
                                            builder: (ctx) => AlertDialog(
                                              backgroundColor:
                                                  const Color(0xFF1E1E1E),
                                              shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                          16)),
                                              content: Text(
                                                '$name 학생의 기기 바인딩을 해제할까요?',
                                                style: const TextStyle(
                                                    color: Colors.white70,
                                                    fontSize: 15),
                                              ),
                                              actions: [
                                                TextButton(
                                                  onPressed: () =>
                                                      Navigator.pop(ctx, false),
                                                  child: const Text('취소',
                                                      style: TextStyle(
                                                          color:
                                                              Colors.white54)),
                                                ),
                                                TextButton(
                                                  onPressed: () =>
                                                      Navigator.pop(ctx, true),
                                                  child: const Text('해제',
                                                      style: TextStyle(
                                                          color: Color(
                                                              0xFF1FA95B))),
                                                ),
                                              ],
                                            ),
                                          );
                                          if (confirm == true) {
                                            try {
                                              final academyId =
                                                  await TenantService.instance
                                                      .getActiveAcademyId();
                                              if (academyId == null) return;
                                              await Supabase.instance.client
                                                  .rpc('m5_unbind_by_student',
                                                      params: {
                                                    'p_academy_id': academyId,
                                                    'p_student_id': studentId,
                                                  });
                                              await DataManager.instance
                                                  .loadStudents();
                                            } catch (_) {}
                                          }
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 10, vertical: 4),
                                          decoration: BoxDecoration(
                                            color:
                                                Colors.white.withOpacity(0.12),
                                            borderRadius:
                                                BorderRadius.circular(999),
                                          ),
                                          child: Text(
                                            '기기 $deviceLabel',
                                            style: const TextStyle(
                                              color: Colors.white38,
                                              fontSize: 12,
                                              height: 1.2,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ))),
        ),
      ),
    );
  }
}
