import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/data_manager.dart';
import '../services/tenant_service.dart';
import '../services/homework_store.dart';
import '../services/student_flow_store.dart';
import '../services/homework_assignment_store.dart';
import '../services/print_routing_service.dart';
import '../models/attendance_record.dart';
import '../models/student_flow.dart';
import 'learning/homework_quick_add_proxy_dialog.dart';
import '../services/tag_preset_service.dart';
import '../services/tag_store.dart';
import 'learning/tag_preset_dialog.dart';
import 'learning/homework_edit_dialog.dart';
import '../widgets/dialog_tokens.dart';
import '../widgets/homework_assign_dialog.dart';
import '../app_overlays.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';
import '../widgets/flow_setup_dialog.dart';
import '../widgets/pdf/homework_answer_viewer_dialog.dart';
import '../widgets/latex_text_renderer.dart';
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
  final Map<({String studentId, String itemId}), bool> _pendingConfirms = {};
  final Set<String> _expandedHomeworkIds = {};
  String? _expandedReservedStudentId;

  @override
  void initState() {
    super.initState();
    gradingModeActive.value = _isGradingMode;
    DataManager.instance.loadDeviceBindings();
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
    _uiAnimController.dispose();
    _clockTimer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
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
                      final submittedCount = _countSubmittedHomeworkItems(list);
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(40, 16, 16, 0),
                        child: Row(
                          children: [
                            Expanded(
                              child: RichText(
                                text: TextSpan(
                                  children: [
                                    TextSpan(
                                      text: _formatDateWithWeekdayAndTime(_now),
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 50,
                                          fontWeight: FontWeight.bold),
                                    ),
                                    const WidgetSpan(
                                        child: SizedBox(width: 30)),
                                    TextSpan(
                                      text: '등원중: ${list.length}명',
                                      style: const TextStyle(
                                          color: Colors.white60,
                                          fontSize: 40,
                                          fontWeight: FontWeight.bold),
                                    ),
                                    const WidgetSpan(
                                        child: SizedBox(width: 24)),
                                    TextSpan(
                                      text: '제출: $submittedCount개',
                                      style: const TextStyle(
                                        color: Color(0xFF8FB3FF),
                                        fontSize: 40,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 20),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  height: 44,
                                  child: OutlinedButton(
                                    onPressed: () => unawaited(
                                      _openHeaderHomeworkPrintFlow(
                                        attendingStudents: list,
                                      ),
                                    ),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: _printPickMode
                                          ? Colors.white
                                          : Colors.white70,
                                      side: BorderSide(
                                        color: _printPickMode
                                            ? kDlgAccent
                                            : Colors.white24,
                                      ),
                                      shape: const StadiumBorder(),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 16,
                                      ),
                                      backgroundColor: _printPickMode
                                          ? const Color(0xFF132822)
                                          : Colors.transparent,
                                    ),
                                    child: const Icon(Icons.print, size: 20),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                if (_isGradingMode) ...[
                                  Tooltip(
                                    message: '채점 이력',
                                    child: SizedBox(
                                      width: 36,
                                      height: 36,
                                      child: IconButton(
                                        onPressed: () {
                                          unawaited(
                                            _showGradingHistoryDialog(
                                              context: context,
                                              attendingStudentIds:
                                                  attendingStudentIds,
                                              studentNamesById:
                                                  studentNamesById,
                                            ),
                                          );
                                        },
                                        padding: EdgeInsets.zero,
                                        splashRadius: 20,
                                        visualDensity: VisualDensity.compact,
                                        icon: const Icon(
                                          Icons.history_rounded,
                                          size: 20,
                                          color: kDlgTextSub,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                ],
                                const Text(
                                  '채점 모드',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Switch(
                                  value: _isGradingMode,
                                  onChanged: (value) {
                                    setState(() {
                                      _isGradingMode = value;
                                      if (!value) {
                                        _pendingConfirms.clear();
                                      }
                                    });
                                    gradingModeActive.value = value;
                                  },
                                  activeColor: kDlgAccent,
                                ),
                                const SizedBox(width: 12),
                                Opacity(
                                  opacity: _pendingConfirms.isEmpty ? 0.4 : 1.0,
                                  child: SizedBox(
                                    width: 130,
                                    height: 48,
                                    child: Material(
                                      color: const Color(0xFF1B6B63),
                                      borderRadius: BorderRadius.circular(24),
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(24),
                                        onTap: _pendingConfirms.isEmpty
                                            ? null
                                            : () =>
                                                _executeBatchConfirm(context),
                                        child: const Padding(
                                          padding: EdgeInsets.only(right: 10),
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Icon(Icons.check,
                                                  color: Color(0xFFEAF2F2),
                                                  size: 20),
                                              SizedBox(width: 8),
                                              Text(
                                                '확인',
                                                style: TextStyle(
                                                  color: Color(0xFFEAF2F2),
                                                  fontSize: 18,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  const Divider(color: Color(0xFF223131), height: 24),
                  const SizedBox(height: 24),
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
                                        e.status != HomeworkStatus.completed &&
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
                              HomeworkItem answerSeed = submittedChildren.first;
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
                              if (group == null && children.length == 1) {
                                return _runHomeworkCheckDialogOnly(
                                  context: context,
                                  studentId: studentId,
                                  hw: children.first,
                                );
                              }
                              return _runHomeworkCheckDialogForGroup(
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
                            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
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
      ],
    );
  }

  Widget _buildStudentColumn(BuildContext context, _AttendingStudent student) {
    final isReservedExpanded = _expandedReservedStudentId == student.id;
    const panelWidth = ClassContentScreen._studentColumnContentWidth;
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
                              onPressed: () {
                                setState(() {
                                  _expandedReservedStudentId =
                                      isReservedExpanded ? null : student.id;
                                });
                              },
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
                        SizedBox(
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
                final panelBody = ClipRect(
                  child: IgnorePointer(
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
                  ),
                );
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
    if (_isGradingMode) return column;
    return DragTarget<HomeworkRecentTemplate>(
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
        return AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: highlight
                ? Border.all(color: kDlgAccent.withOpacity(0.85), width: 1.4)
                : null,
            color: highlight ? const Color(0x221B6B63) : Colors.transparent,
          ),
          child: column,
        );
      },
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
        final bookName = bookId.trim().isEmpty ? '교재 없음' : bookId;
        final shouldLink = await _confirmFavoriteTemplateLink(
          context: context,
          bookName: bookName,
          gradeLabel: gradeLabel,
        );
        if (!context.mounted || !shouldLink) return;
        final linkedFlowId = await _linkFavoriteTemplateBookToFlow(
          context: context,
          studentId: studentId,
          bookId: bookId,
          gradeLabel: gradeLabel,
          bookName: bookName,
          preferredFlowId: resolvedFlowId,
        );
        if (!context.mounted || linkedFlowId == null) return;
        resolvedFlowId = linkedFlowId;
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

    final flowId = templateFlowId.trim();
    if (flowId.isNotEmpty) {
      try {
        final rows = await DataManager.instance.loadFlowTextbookLinks(flowId);
        if (hasMatch(rows)) {
          return _FavoriteTemplateLinkStatus(linked: true, flowId: flowId);
        }
      } catch (_) {}
    }

    final flows = await StudentFlowStore.instance.loadForStudent(studentId);
    final enabledFlows = flows.where((f) => f.enabled).toList(growable: false);
    for (final flow in enabledFlows) {
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
            '$bookName ($gradeLabel)이(가) 연결되지 않았습니다.\n연결 후 과제를 낼까요?',
            style: const TextStyle(color: kDlgTextSub, height: 1.35),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
              child: const Text('연결'),
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
    final splitMap = <String, int>{};
    final createdItems = <HomeworkItem>[];

    if (template.isGroup || template.parts.length > 1) {
      final rows = <Map<String, dynamic>>[];
      for (final part in template.parts) {
        rows.add({
          'title': part.title,
          'body': part.body,
          'color': part.color,
          'type': part.type,
          'page': part.page,
          'count': part.count,
          'memo': part.memo,
          'content': part.content,
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
      );
      createdItems.addAll(generated);
      for (final item in generated) {
        splitMap[item.id] = item.defaultSplitParts.clamp(1, 4).toInt();
      }
    } else {
      final part = template.parts.first;
      final fallbackFlowId = (part.flowId ?? '').trim();
      final created = HomeworkStore.instance.add(
        studentId,
        title: part.title,
        body: part.body,
        color: part.color,
        flowId: normalizedFlowId.isEmpty ? fallbackFlowId : normalizedFlowId,
        type: part.type,
        page: part.page,
        count: part.count,
        memo: part.memo,
        content: part.content,
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
      );
      createdItems.add(created);
      splitMap[created.id] = created.defaultSplitParts.clamp(1, 4).toInt();
    }

    if (createdItems.isEmpty) return 0;
    if (mode == _FavoriteIssueMode.reserve) {
      await HomeworkAssignmentStore.instance.recordAssignments(
        studentId,
        createdItems,
        note: HomeworkAssignmentStore.reservationNote,
        splitPartsByItem: splitMap,
      );
    } else {
      HomeworkStore.instance.markItemsAsHomework(
        studentId,
        createdItems.map((e) => e.id).toList(growable: false),
      );
    }
    return createdItems.length;
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
          final createdItems =
              await HomeworkStore.instance.createGroupWithWaitingItems(
            studentId: studentId,
            groupTitle: (item['groupTitle'] as String?)?.trim() ?? '',
            flowId: (item['flowId'] as String?)?.trim(),
            items: entries,
          );
          if (createdItems.isEmpty) {
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('그룹 과제 생성에 실패했어요.')),
            );
            return;
          }
          if (isReserve) {
            await HomeworkAssignmentStore.instance.recordAssignments(
              studentId,
              createdItems,
              note: HomeworkAssignmentStore.reservationNote,
              splitPartsByItem: <String, int>{
                for (final hw in createdItems)
                  hw.id: hw.defaultSplitParts.clamp(1, 4).toInt(),
              },
            );
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
        int _parseSplitParts(dynamic value) {
          if (value is int) return value.clamp(1, 4).toInt();
          if (value is num) return value.toInt().clamp(1, 4).toInt();
          if (value is String) {
            return (int.tryParse(value) ?? 1).clamp(1, 4).toInt();
          }
          return 1;
        }

        for (final entry in entries) {
          final countStr = (entry['count'] as String?)?.trim();
          final splitParts =
              _parseSplitParts(entry['splitParts'] ?? item['splitParts']);
          final created = HomeworkStore.instance.add(
            item['studentId'],
            title: (entry['title'] as String?) ?? '',
            body: (entry['body'] as String?) ?? '',
            color: (entry['color'] as Color?) ?? const Color(0xFF1976D2),
            flowId: flowId,
            type: (entry['type'] as String?)?.trim(),
            page: (entry['page'] as String?)?.trim(),
            count: (countStr == null || countStr.isEmpty)
                ? null
                : int.tryParse(countStr),
            content: (entry['content'] as String?)?.trim(),
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
          );
          createdItems.add(created);
        }
        if (isReserve && createdItems.isNotEmpty) {
          await HomeworkAssignmentStore.instance.recordAssignments(
            studentId,
            createdItems,
            note: HomeworkAssignmentStore.reservationNote,
            splitPartsByItem: <String, int>{
              for (final hw in createdItems)
                hw.id: hw.defaultSplitParts.clamp(1, 4).toInt(),
            },
          );
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
      if (!context.mounted) return;

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
          ),
        );
      }

      entries.sort((a, b) {
        if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
        final leftTs = a.checkedAt ?? a.assignedAt;
        final rightTs = b.checkedAt ?? b.assignedAt;
        return rightTs.compareTo(leftTs);
      });

      String studentName = '학생';
      for (final row in DataManager.instance.students) {
        if (row.student.id == studentId) {
          final name = row.student.name.trim();
          studentName = name.isEmpty ? '학생' : name;
          break;
        }
      }

      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: kDlgBg,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            '$studentName 숙제 리스트',
            style: const TextStyle(
              color: kDlgText,
              fontWeight: FontWeight.w900,
            ),
          ),
          content: SizedBox(
            width: 720,
            child: entries.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      '활성 숙제와 오늘 검사 항목이 없습니다.',
                      style: TextStyle(
                        color: kDlgTextSub,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const YggDialogSectionHeader(
                          icon: Icons.assignment_rounded,
                          title: '활성/오늘 검사 현황',
                        ),
                        const SizedBox(height: 10),
                        for (int i = 0; i < entries.length; i++) ...[
                          if (i > 0) const SizedBox(height: 10),
                          _buildHomeworkOverviewCard(entries[i]),
                        ],
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
      setState(() {
        for (final key in keys) {
          _pendingConfirms.remove(key);
        }
      });
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
      setState(() {
        for (final key in keys) {
          _pendingConfirms[key] = true;
        }
      });
    } else if (action == HomeworkAnswerViewerAction.confirm) {
      setState(() {
        for (final key in keys) {
          _pendingConfirms[key] = false;
        }
      });
    }
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
    final waitingCandidates = <HomeworkItem>[];
    for (final student in attendingStudents) {
      waitingCandidates.addAll(
        HomeworkStore.instance.items(student.id).where(
              (hw) =>
                  hw.status != HomeworkStatus.completed &&
                  hw.phase == 1 &&
                  _hasDirectHomeworkTextbookLink(hw),
            ),
      );
    }
    if (waitingCandidates.isEmpty) {
      if (mounted) {
        _showHomeworkChipSnackBar(context, '인쇄 가능한 대기 과제가 없습니다.');
      }
      return;
    }

    var hasPrintableBodyLink = false;
    for (final hw in waitingCandidates) {
      try {
        final resolved =
            await _resolveHomeworkPdfLinks(hw, allowFlowFallback: false);
        final bodyRaw = resolved.bodyPathRaw.trim();
        if (bodyRaw.isEmpty) continue;
        if (_isWebUrl(bodyRaw)) continue;
        hasPrintableBodyLink = true;
        break;
      } catch (_) {}
    }
    if (!mounted) return;
    if (!hasPrintableBodyLink) {
      _showHomeworkChipSnackBar(context, '인쇄 가능한 교재 본문 링크가 없습니다.');
      return;
    }
    setState(() => _printPickMode = true);
  }

  Future<void> _handleHomeworkPrintPick({
    required BuildContext context,
    required String studentId,
    required HomeworkItem hw,
  }) async {
    if (!_printPickMode) return;
    final latest = HomeworkStore.instance.getById(studentId, hw.id);
    if (latest == null) return;
    if (latest.phase != 1) {
      _showHomeworkChipSnackBar(context, '인쇄 모드에서는 대기 상태 과제만 선택할 수 있어요.');
      return;
    }
    if (mounted) {
      setState(() => _printPickMode = false);
    }
    await _handleWaitingChipLongPressPrint(
      context: context,
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
    final waitingChildren = latestChildren
        .where((e) => e.status != HomeworkStatus.completed && e.phase == 1)
        .toList(growable: false);
    if (waitingChildren.isEmpty) {
      _showHomeworkChipSnackBar(context, '인쇄 가능한 대기 하위 과제가 없습니다.');
      return;
    }

    if (mounted) {
      setState(() => _printPickMode = false);
    }

    final printableById = <String, bool>{
      for (final child in waitingChildren)
        child.id: _hasDirectHomeworkTextbookLink(child),
    };
    final initialSelectedById = <String, bool>{
      for (final child in waitingChildren)
        child.id: printableById[child.id] ?? false,
    };
    final defaultPrintableChildren = waitingChildren
        .where((e) => printableById[e.id] ?? false)
        .toList(growable: false);
    if (defaultPrintableChildren.isEmpty) {
      _showHomeworkChipSnackBar(context, '인쇄할 하위 과제를 선택하세요.');
      return;
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

    await _handleWaitingChipLongPressPrint(
      context: context,
      hw: seed,
      initialRangeOverride: printRange,
      dialogTitleOverride: dialogTitle,
      selectableGroupChildren: waitingChildren,
      groupChildPrintableById: printableById,
      groupInitialSelectionById: initialSelectedById,
    );
  }

  Future<void> _executeBatchConfirm(BuildContext context) async {
    if (_pendingConfirms.isEmpty) return;
    final pending =
        Map<({String studentId, String itemId}), bool>.from(_pendingConfirms);
    setState(() => _pendingConfirms.clear());
    unawaited(_processBatchConfirmInBackground(context, pending));
  }

  Future<void> _processBatchConfirmInBackground(
    BuildContext context,
    Map<({String studentId, String itemId}), bool> pending,
  ) async {
    for (final entry in pending.entries) {
      final key = entry.key;
      final hw = HomeworkStore.instance.getById(key.studentId, key.itemId);
      if (hw == null) continue;

      final isComplete = entry.value;

      if (isComplete) {
        HomeworkStore.instance.markAutoCompleteOnNextWaiting(key.itemId);
        final target = await _resolveHomeworkCheckTarget(
          key.studentId,
          key.itemId,
          includeHistory: false,
        );
        if (target != null) {
          await HomeworkAssignmentStore.instance.saveAssignmentCheck(
            assignmentId: target.assignmentId,
            studentId: key.studentId,
            homeworkItemId: key.itemId,
            progress: target.progress,
            issueType: null,
            issueNote: null,
            markCompleted: false,
          );
        }
        if (hw.phase == 3) {
          await HomeworkStore.instance.confirm(
            key.studentId,
            key.itemId,
            recordAssignmentCheck: false,
          );
        }
      } else if (hw.phase == 3) {
        final target = await _resolveHomeworkCheckTarget(
          key.studentId,
          key.itemId,
          includeHistory: false,
        );
        if (target != null) {
          await HomeworkAssignmentStore.instance.saveAssignmentCheck(
            assignmentId: target.assignmentId,
            studentId: key.studentId,
            homeworkItemId: key.itemId,
            progress: target.progress,
            issueType: null,
            issueNote: null,
            markCompleted: false,
          );
        }
        await HomeworkStore.instance.confirm(
          key.studentId,
          key.itemId,
          recordAssignmentCheck: false,
        );
      } else {
        final target = await _resolveHomeworkCheckTarget(
          key.studentId,
          key.itemId,
          includeHistory: false,
        );
        if (target != null) {
          await HomeworkAssignmentStore.instance.saveAssignmentCheck(
            assignmentId: target.assignmentId,
            studentId: key.studentId,
            homeworkItemId: key.itemId,
            progress: target.progress,
            issueType: null,
            issueNote: null,
            markCompleted: false,
          );
        }
        HomeworkStore.instance
            .restoreItemsToWaiting(key.studentId, [key.itemId]);
        await HomeworkStore.instance.placeItemAtActiveTail(
          key.studentId,
          key.itemId,
          activateFromHomework: true,
        );
        await HomeworkAssignmentStore.instance.clearActiveAssignmentsForItems(
          key.studentId,
          [key.itemId],
        );
      }
    }
    if (mounted && context.mounted) {
      _showHomeworkChipSnackBar(context, '${pending.length}건의 과제를 일괄 처리했어요.');
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

List<Widget> _buildHomeworkCheckTargetInfo(HomeworkItem hw) {
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

  return [
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
}

Future<_HomeworkCheckDraft?> _showHomeworkItemCheckDialog({
  required BuildContext context,
  required HomeworkItem hw,
  required _HomeworkCheckTarget target,
  required int minProgress,
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
                          children: _buildHomeworkCheckTargetInfo(hw),
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

Future<void> _runHomeworkCheckDialogOnly({
  required BuildContext context,
  required String studentId,
  required HomeworkItem hw,
}) async {
  final latest = HomeworkStore.instance.getById(studentId, hw.id);
  if (latest == null) return;

  final target = await _resolveHomeworkCheckTarget(
    studentId,
    hw.id,
    includeHistory: false,
  );
  if (!context.mounted) return;
  if (target == null) {
    _showHomeworkChipSnackBar(context, '숙제 할당 정보를 찾을 수 없습니다.');
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
  // 리얼타임 반영 중에도 순서 흔들림이 없도록,
  // 복귀 항목의 order_index를 먼저 "활성 꼬리"로 재배정한 뒤 노출한다.
  await HomeworkStore.instance.placeItemAtActiveTail(
    studentId,
    hw.id,
    activateFromHomework: true,
  );
  await HomeworkStore.instance.submit(studentId, hw.id);
  await HomeworkAssignmentStore.instance.clearActiveAssignmentsForItems(
    studentId,
    [hw.id],
  );
  if (!context.mounted) return;
  _showHomeworkChipSnackBar(context, '숙제 검사 완료 — 제출 상태로 이동했어요.');
}

Future<void> _runHomeworkCheckDialogForGroup({
  required BuildContext context,
  required String studentId,
  required HomeworkGroup? group,
  required HomeworkItem summary,
  required List<HomeworkItem> children,
}) async {
  final targetChildren = children
      .where((e) => e.status != HomeworkStatus.completed)
      .toList(growable: false);
  if (targetChildren.isEmpty) return;

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
    if (!context.mounted) return;
    if (target == null) {
      _showHomeworkChipSnackBar(context, '일부 하위 과제의 숙제 할당 정보를 찾지 못했습니다.');
      return;
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

  if (targets.isEmpty || !context.mounted) return;
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

  final draft = await _showHomeworkItemCheckDialog(
    context: context,
    hw: summary,
    target: dialogTarget,
    minProgress: globalMinProgress,
  );
  if (!context.mounted || draft == null) return;

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
    if (!context.mounted) return;
    _showHomeworkChipSnackBar(context, '그룹 숙제 검사 저장에 실패했습니다.');
    return;
  }

  for (final itemId in savedItemIds) {
    await HomeworkStore.instance.placeItemAtActiveTail(
      studentId,
      itemId,
      activateFromHomework: true,
    );
    await HomeworkStore.instance.submit(studentId, itemId);
  }
  await HomeworkAssignmentStore.instance
      .clearActiveAssignmentsForItems(studentId, savedItemIds);
  if (!context.mounted) return;
  final groupTitle = (group?.title ?? '').trim();
  final summaryTitle = summary.title.trim();
  final prefix = groupTitle.isNotEmpty
      ? groupTitle
      : (summaryTitle.isNotEmpty ? summaryTitle : '그룹 숙제');
  _showHomeworkChipSnackBar(
    context,
    '$prefix 검사 완료 — 하위 ${savedItemIds.length}개 과제를 제출 상태로 이동했어요.',
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

Widget _buildHomeworkOverviewCard(_HomeworkOverviewEntry entry) {
  final indicatorValue = (entry.progress.clamp(0, 100)) / 100.0;
  final badgeBg =
      entry.isActive ? const Color(0x3340A883) : const Color(0x334A6871);
  final badgeText = entry.isActive ? '활성' : '오늘 검사';
  return Container(
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
                entry.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kDlgText,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: badgeBg,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: const Color(0xFF4A6871)),
              ),
              child: Text(
                badgeText,
                style: const TextStyle(
                  color: kDlgTextSub,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '내준 시각: ${_formatDateTime(entry.assignedAt)}',
          style: const TextStyle(
            color: kDlgTextSub,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          entry.dueDate == null
              ? '검사일: 미정'
              : '검사일: ${_formatDateWithWeekdayShort(entry.dueDate!)}',
          style: const TextStyle(
            color: kDlgTextSub,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          entry.checkedToday
              ? '오늘 검사: 완료${entry.checkedAt == null ? '' : ' (${_formatDateTime(entry.checkedAt!)})'}'
              : '오늘 검사: 미완료',
          style: TextStyle(
            color: entry.checkedToday ? kDlgAccent : const Color(0xFF8EA3A8),
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
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
            const SizedBox(width: 10),
            Text(
              '완료율 ${entry.progress}%',
              style: const TextStyle(
                color: kDlgText,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                height: 1.1,
              ),
            ),
          ],
        ),
      ],
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
      HomeworkStore.instance.runningOf(studentId)?.id == hw.id;
  final int runningMs = hw.runStart != null
      ? DateTime.now().difference(hw.runStart!).inMilliseconds
      : 0;
  final int totalMs = hw.accumulatedMs + runningMs;
  final String durationText = _formatDurationMs(totalMs);
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
              _detailRow('진행시간', durationText),
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
    title: (edited['title'] as String).trim(),
    body: (edited['body'] as String).trim(),
    color: (edited['color'] as Color),
    flowId: item.flowId,
    type: (edited['type'] as String?)?.trim(),
    page: (edited['page'] as String?)?.trim(),
    count:
        (countStr == null || countStr.isEmpty) ? null : int.tryParse(countStr),
    memo: item.memo,
    content: (edited['content'] as String?)?.trim(),
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
    title: source.title,
    body: source.body,
    color: source.color,
    flowId: source.flowId,
    type: source.type,
    page: page ?? source.page,
    count: source.count,
    memo: memo ?? source.memo,
    content: content ?? source.content,
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
  int createdCount = 0;
  for (final entry in entries) {
    final createdId = await HomeworkStore.instance.addWaitingItemToGroup(
      studentId: studentId,
      groupId: group.id,
      title: (entry['title'] as String?)?.trim() ?? '',
      body: (entry['body'] as String?)?.trim(),
      page: (entry['page'] as String?)?.trim(),
      count: parsePositiveInt(entry['count']),
      type: (entry['type'] as String?)?.trim(),
      memo: (entry['memo'] as String?)?.trim(),
      content: (entry['content'] as String?)?.trim(),
      bookId: (entry['bookId'] as String?)?.trim(),
      gradeLabel: (entry['gradeLabel'] as String?)?.trim(),
      sourceUnitLevel: (entry['sourceUnitLevel'] as String?)?.trim(),
      sourceUnitPath: (entry['sourceUnitPath'] as String?)?.trim(),
      unitMappings: parseUnitMappings(entry['unitMappings']),
      templateItemId: template?.id,
      flowId: flowId,
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

const double _homeworkChipCollapsedHeight = 136.0;
const double _homeworkChipExpandedHeight = 210.0;
double _homeworkGroupExpandedHeightForChildCount(int childCount) {
  if (childCount <= 0) return _homeworkChipExpandedHeight;
  // 상단 정보와 하위 리스트를 충분히 분리하고,
  // 하위 과제 수에 비례해 카드 높이가 늘어나도록 계산한다.
  const double groupSectionHeaderHeight = 58;
  const double perChildRowHeight = 78;
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
final Map<String, String> _expandedReservedGroupKeyByStudent =
    <String, String>{};
final Set<String> _activatingReservedGroupActionKeys = <String>{};
final ValueNotifier<int> _reservedGroupUiRevision = ValueNotifier<int>(0);

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
                builder: (context, assignmentsSnapshot) {
                  final activeAssignments = assignmentsSnapshot.data ??
                      const <HomeworkAssignmentDetail>[];
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

    final childRows = <Widget>[];
    for (int childIndex = 0; childIndex < entries.length; childIndex++) {
      final assignment = entries[childIndex].key;
      final hw = entries[childIndex].value;
      final cycleMeta = assignmentCycleMetaByItem[hw.id];
      final repeatIndex =
          (cycleMeta?.repeatIndex ?? assignment.repeatIndex).clamp(1, 1 << 30);
      final splitParts =
          (cycleMeta?.splitParts ?? assignment.splitParts).clamp(1, 4);
      final splitRound =
          (cycleMeta?.splitRound ?? assignment.splitRound).clamp(1, splitParts);
      final String cycleText = splitParts > 1
          ? '$repeatIndex회차 · $splitParts분할 $splitRound차'
          : '$repeatIndex회차';
      final flowId = (hw.flowId ?? assignment.flowId ?? '').trim();
      final flowLabel = (flowNames[flowId] ?? '').trim();
      final page = (hw.page ?? '').trim();
      final count = hw.count ?? 0;
      final childTitle = hw.title.trim().isEmpty ? '(제목 없음)' : hw.title.trim();
      final childMeta = <String>[
        if (flowLabel.isNotEmpty) flowLabel,
        if (page.isNotEmpty) 'p.$page',
        if (count > 0) '$count문항',
        cycleText,
      ].join(' · ');
      childRows.add(
        Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: BoxDecoration(
            color: const Color(0xFF11171A),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: const Color(0xFF263237)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                childTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFFB9C3BA),
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                childMeta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF8FA1A1),
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                ),
              ),
            ],
          ),
        ),
      );
      if (childIndex != entries.length - 1) {
        childRows.add(const SizedBox(height: 6));
      }
    }

    out.add(
      _SlideableHomeworkChip(
        key: ValueKey('reserved_group_chip_${studentId}_${group.groupKey}'),
        maxSlide: _homeworkChipMaxSlideFor(isExpanded ? 260 : 148),
        canSlideDown: false,
        canSlideUp: !isActivating,
        downLabel: '',
        upLabel: isActivating ? '전환 중' : '진행 전환',
        downColor: const Color(0xFF9FB3B3),
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
        onSlideDown: () {},
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
          decoration: BoxDecoration(
            color: const Color(0xFF15171C),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color:
                  isExpanded ? const Color(0xFF33554C) : const Color(0xFF273338),
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
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
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
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      group.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFFB9C3BA),
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
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
              const SizedBox(height: 6),
              Text(
                topMeta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF8FA1A1),
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                bottomMeta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kDlgAccent,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 5),
              const Text(
                '탭하면 펼쳐지고, 왼쪽으로 밀면 진행 과제로 전환됩니다.',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Color(0xFF7D8E8F),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                ),
              ),
              if (isExpanded) ...[
                const SizedBox(height: 10),
                const Divider(height: 1, thickness: 1, color: kDlgBorder),
                const SizedBox(height: 8),
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
    for (final group in HomeworkStore.instance.groups(studentId)) group.id: group,
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

    HomeworkItem? runningChild;
    bool hasSubmitted = false;
    bool hasConfirmed = false;
    int maxPhase = 1;
    int groupCycleBaseMs = 0;
    int groupCycleProgressMs = 0;
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
      final int childRunningMs = child.runStart != null
          ? DateTime.now().difference(child.runStart!).inMilliseconds
          : 0;
      final int childTotalMs = child.accumulatedMs + childRunningMs;
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
      final int childCycleProgressMs =
          math.max(0, childTotalMs - childCycleBaseMs);
      if (childCycleProgressMs > groupCycleProgressMs) {
        groupCycleProgressMs = childCycleProgressMs;
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
    if (runningChild != null) {
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
    final DateTime? groupCycleStartedAt =
        group.cycleStartedAt ?? runningChild?.runStart;
    final int groupTotalMs = groupCycleBaseMs + groupCycleProgressMs;
    return HomeworkItem(
      id: (runningChild ?? first).id,
      title: group.title.trim().isEmpty ? first.title : group.title.trim(),
      body: first.body,
      color: first.color,
      flowId: group.flowId ?? first.flowId,
      type: '${children.length}개 과제',
      page: pageSummary,
      count: totalCount > 0 ? totalCount : null,
      memo: first.memo,
      content: first.content,
      bookId: first.bookId,
      gradeLabel: first.gradeLabel,
      sourceUnitLevel: first.sourceUnitLevel,
      sourceUnitPath: first.sourceUnitPath,
      defaultSplitParts: first.defaultSplitParts,
      checkCount: groupCheckCount,
      orderIndex: group.orderIndex,
      createdAt: first.createdAt,
      updatedAt: latestUpdated ?? first.updatedAt,
      status: HomeworkStatus.inProgress,
      phase: phase,
      accumulatedMs: groupTotalMs,
      cycleBaseAccumulatedMs: groupCycleBaseMs,
      // baseline(합산) + 이번 사이클 진행(delta 1회) 형태로 그룹 타이머를 표현한다.
      runStart: null,
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
    final bool hasRunningChild =
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
      maxSlide: _homeworkChipMaxSlideFor(chipH),
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
      onLongPress: null,
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
          onGroupTitleTap: groupIsWaiting && !printPickMode
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

class _HomeworkPrintConfirmResult {
  final String pageRange;
  final List<String> selectedChildIds;

  const _HomeworkPrintConfirmResult({
    required this.pageRange,
    this.selectedChildIds = const <String>[],
  });
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

Set<int> _parsePageNumbersForGroupAction(String raw) {
  final cleaned = raw.trim();
  if (cleaned.isEmpty) return <int>{};
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
  if (normalized.isEmpty) return <int>{};
  final out = <int>{};
  for (final token in normalized.split(',')) {
    final t = token.trim();
    if (t.isEmpty) continue;
    if (t.contains('-')) {
      final parts = t.split('-');
      if (parts.length != 2) continue;
      final start = int.tryParse(parts[0]);
      final end = int.tryParse(parts[1]);
      if (start == null || end == null) continue;
      var a = start;
      var b = end;
      if (a > b) {
        final temp = a;
        a = b;
        b = temp;
      }
      for (int p = a; p <= b; p++) {
        if (p > 0) out.add(p);
      }
      continue;
    }
    final value = int.tryParse(t);
    if (value != null && value > 0) out.add(value);
  }
  return out;
}

String _compressPageNumbersForGroupAction(Set<int> pages) {
  if (pages.isEmpty) return '';
  final sorted = pages.toList()..sort();
  final out = <String>[];
  int start = sorted.first;
  int prev = sorted.first;
  for (int i = 1; i < sorted.length; i++) {
    final value = sorted[i];
    if (value == prev + 1) {
      prev = value;
      continue;
    }
    out.add(start == prev ? '$start' : '$start-$prev');
    start = value;
    prev = value;
  }
  out.add(start == prev ? '$start' : '$start-$prev');
  return out.join(',');
}

String _mergeGroupPageText(List<HomeworkItem> items) {
  final pages = <int>{};
  for (final item in items) {
    pages.addAll(_parsePageNumbersForGroupAction(item.page ?? ''));
  }
  return _compressPageNumbersForGroupAction(pages);
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

Future<String?> _buildPdfForPrintRange({
  required String inputPath,
  required String pageRange,
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
    for (final i in indices) {
      if (i < 0 || i >= pageCount) continue;
      final srcPage = src.pages[i];
      final srcSize = srcPage.size;
      try {
        dst.pageSettings.size = srcSize;
        dst.pageSettings.margins.all = 0;
      } catch (_) {}
      final tmpl = srcPage.createTemplate();
      final newPage = dst.pages.add();
      final tw = srcSize.width;
      final th = srcSize.height;
      final sw = srcSize.width;
      final sh = srcSize.height;
      if (tw <= 0 || th <= 0 || sw <= 0 || sh <= 0) {
        try {
          newPage.graphics.drawPdfTemplate(tmpl, const Offset(0, 0));
        } catch (_) {
          newPage.graphics.drawPdfTemplate(tmpl, const Offset(0, 0));
        }
        continue;
      }
      // 프린터 여백 영향을 줄이기 위해 약간 확대해서 출력한다.
      const double overscan = 1.02;
      final scale = math.max(tw / sw, th / sh) * overscan;
      final w = sw * scale;
      final h = sh * scale;
      final dx = (tw - w) / 2.0;
      final dy = (th - h) / 2.0;
      try {
        newPage.graphics.drawPdfTemplate(tmpl, Offset(dx, dy), Size(w, h));
      } catch (_) {
        newPage.graphics.drawPdfTemplate(tmpl, const Offset(0, 0));
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

Future<void> _openPrintDialogForPath(String path) async {
  await PrintRoutingService.instance.printFile(
    path: path,
    channel: PrintRoutingChannel.general,
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
              child: SingleChildScrollView(
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
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: selectableChildren.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (ctx, idx) {
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
                              if (!canPrint) '교재 링크 없음',
                            ].join(' · ');
                            return Container(
                              decoration: BoxDecoration(
                                color: kDlgPanelBg,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: kDlgBorder),
                              ),
                              child: CheckboxListTile(
                                value: selectedChildById[child.id] ?? false,
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
                                contentPadding: const EdgeInsets.symmetric(
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
                                    color: canPrint ? kDlgText : kDlgTextSub,
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
                          },
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
                            borderSide:
                                const BorderSide(color: kDlgAccent, width: 1.4),
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
                  ],
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

Future<void> _handleWaitingChipLongPressPrint({
  required BuildContext context,
  required HomeworkItem hw,
  String? initialRangeOverride,
  String? dialogTitleOverride,
  List<HomeworkItem> selectableGroupChildren = const <HomeworkItem>[],
  Map<String, bool> groupChildPrintableById = const <String, bool>{},
  Map<String, bool> groupInitialSelectionById = const <String, bool>{},
}) async {
  if (hw.phase != 1) return;
  if (!_hasDirectHomeworkTextbookLink(hw)) {
    _showHomeworkChipSnackBar(context, '해당 과제에는 연결된 교재가 없어 인쇄할 수 없습니다.');
    return;
  }
  final resolved = await _resolveHomeworkPdfLinks(hw, allowFlowFallback: false);
  if (!context.mounted) return;

  final bodyRaw = resolved.bodyPathRaw;
  if (bodyRaw.isEmpty) {
    _showHomeworkChipSnackBar(context, '연결된 교재 본문 PDF가 없습니다.');
    return;
  }
  if (_isWebUrl(bodyRaw)) {
    _showHomeworkChipSnackBar(context, 'URL 인쇄는 지원하지 않습니다. 파일 경로를 사용하세요.');
    return;
  }

  final bodyPath = _toLocalFilePath(bodyRaw);
  if (bodyPath.isEmpty) {
    _showHomeworkChipSnackBar(context, '교재 본문 경로를 확인할 수 없습니다.');
    return;
  }
  if (!await File(bodyPath).exists()) {
    if (!context.mounted) return;
    _showHomeworkChipSnackBar(context, '교재 본문 파일을 찾을 수 없습니다.');
    return;
  }

  final bool isPdf = bodyPath.toLowerCase().endsWith('.pdf');
  final int pageOffset = isPdf
      ? await _loadTextbookPageOffset(
          bookId: resolved.bookId,
          gradeLabel: resolved.gradeLabel,
        )
      : 0;
  final initialRangeRaw =
      initialRangeOverride ?? (isPdf ? (hw.page ?? '') : '');
  final initialRange =
      isPdf ? _normalizePageRangeForPrint(initialRangeRaw) : '';
  final confirmResult = await _showHomeworkPrintConfirmDialog(
    context: context,
    hw: hw,
    filePath: bodyPath,
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
    _showHomeworkChipSnackBar(context, '인쇄할 하위 과제를 선택하세요.');
    return;
  }

  final selectedRange = confirmResult.pageRange;
  String pathToPrint = bodyPath;
  final rangeDisplay = _normalizePageRangeForPrint(selectedRange);
  final rangeRaw = _shiftNormalizedPageRangeForPdf(rangeDisplay, pageOffset);
  String? printError;
  try {
    await _runWithPrintProgressDialog(
      context,
      run: (progressText) async {
        if (rangeRaw.isNotEmpty) {
          if (!bodyPath.toLowerCase().endsWith('.pdf')) {
            printError = '페이지 범위 인쇄는 PDF에서만 지원합니다.';
            return;
          }
          progressText.value = '선택한 페이지를 인쇄 파일로 만드는 중입니다...';
          final out = await _buildPdfForPrintRange(
            inputPath: bodyPath,
            pageRange: rangeRaw,
          );
          if (out == null || out.isEmpty) {
            printError = '페이지 범위를 확인하세요. (예: 10-15, 20)';
            return;
          }
          pathToPrint = out;
          _scheduleTempDelete(pathToPrint);
        }
        progressText.value = '프린터로 전송 중입니다...';
        await _openPrintDialogForPath(pathToPrint);
      },
    );
  } catch (_) {
    if (!context.mounted) return;
    _showHomeworkChipSnackBar(context, '인쇄 요청 중 오류가 발생했습니다.');
    return;
  }
  if (!context.mounted) return;
  if (printError != null) {
    _showHomeworkChipSnackBar(context, printError!);
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

Widget _buildFlowChip(
  String flowName, {
  String? dueLabel,
  bool isHomeworkDue = false,
}) {
  final normalizedFlowName = flowName.trim();
  final normalizedDueLabel = (dueLabel ?? '').trim();
  final chipText = isHomeworkDue
      ? (normalizedDueLabel.isEmpty ? '검사일 미정' : normalizedDueLabel)
      : (normalizedDueLabel.isEmpty
          ? (normalizedFlowName.isEmpty ? '플로우 미지정' : normalizedFlowName)
          : (normalizedFlowName.isEmpty
              ? normalizedDueLabel
              : '$normalizedFlowName · $normalizedDueLabel'));
  final bool isDefault = normalizedFlowName == '현행' && !isHomeworkDue;
  final Color backgroundColor = isHomeworkDue
      ? const Color(0x1F4FBF97)
      : (isDefault ? Colors.transparent : const Color(0xFF2A3030));
  final Border? border = isHomeworkDue
      ? Border.all(color: kDlgAccent, width: 1.05)
      : (isDefault
          ? Border.all(color: const Color(0xFF4A5858), width: 1)
          : null);
  final Color textColor =
      isHomeworkDue ? const Color(0xFF9FE3C6) : const Color(0xFF9FB3B3);
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
      HomeworkStore.instance.runningOf(studentId)?.id == hw.id;
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
  final int progressMs =
      (visualPhase == 1 && !isPausedWaiting) ? 0 : cycleProgressMs;
  final int progressMinutes = progressMs <= 0 ? 0 : (progressMs ~/ 60000);
  final String durationText = _formatDurationMs(totalMs);
  final String startedAtText =
      hw.firstStartedAt == null ? '-' : _formatShortTime(hw.firstStartedAt!);
  final String typeText =
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
  final double fixedWidth = ClassContentScreen._studentColumnContentWidth;
  final double maxRowW = fixedWidth - leftPad - rightPad;
  final bool hasGroupChildren = groupChildren.isNotEmpty;
  final String resolvedGroupId = (groupId ?? '').trim();

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
        Text('진행 ${progressMinutes}분', style: statStyle),
        const Spacer(),
        Text('총 $durationText', style: statStyle),
      ],
    ),
  );

  final List<Widget> columnChildren;
  if (isExpanded) {
    final String expandedLine3Left =
        '시작 $startedAtText · 진행 ${progressMinutes}분';
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
                Text(
                  '${index + 1}. ${groupChildLabel(child)}',
                  style: groupChildTitleStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
      if (hasGroupChildren) ...[
        const SizedBox(height: 16),
        Container(
          width: maxRowW,
          height: 1,
          color: const Color(0x334D5A5A),
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
              color: const Color(0x223A4545),
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

  const _HomeworkOverviewEntry({
    required this.homeworkItemId,
    required this.title,
    required this.assignedAt,
    required this.dueDate,
    required this.checkedToday,
    required this.checkedAt,
    required this.progress,
    required this.isActive,
  });
}

class _GradingHistoryEntry {
  final String studentId;
  final String studentName;
  final HomeworkItem item;

  const _GradingHistoryEntry({
    required this.studentId,
    required this.studentName,
    required this.item,
  });

  DateTime get confirmedAt =>
      item.confirmedAt ??
      item.updatedAt ??
      item.createdAt ??
      DateTime.fromMillisecondsSinceEpoch(0);
}

List<_GradingHistoryEntry> _collectGradingHistoryEntries({
  required List<String> attendingStudentIds,
  required Map<String, String> studentNamesById,
}) {
  final entries = <_GradingHistoryEntry>[];
  for (final studentId in attendingStudentIds) {
    final studentName = studentNamesById[studentId] ?? '학생';
    final confirmedItems = HomeworkStore.instance
        .items(studentId)
        .where((hw) => hw.status != HomeworkStatus.completed && hw.phase == 4)
        .toList();
    for (final hw in confirmedItems) {
      entries.add(
        _GradingHistoryEntry(
          studentId: studentId,
          studentName: studentName,
          item: hw,
        ),
      );
    }
  }
  entries.sort((a, b) {
    final timeCmp = b.confirmedAt.compareTo(a.confirmedAt);
    if (timeCmp != 0) return timeCmp;
    final nameCmp = a.studentName.compareTo(b.studentName);
    if (nameCmp != 0) return nameCmp;
    return a.item.id.compareTo(b.item.id);
  });
  return entries;
}

String _gradingHistoryTitle(HomeworkItem hw) {
  final title = hw.title.trim();
  return title.isEmpty ? '(제목 없음)' : title;
}

String _gradingHistoryMeta(HomeworkItem hw) {
  final parts = <String>[];
  final type = (hw.type ?? '').trim();
  final page = (hw.page ?? '').trim();
  if (type.isNotEmpty) parts.add(type);
  if (page.isNotEmpty) parts.add('p.$page');
  if (hw.count != null) parts.add('${hw.count}문항');
  return parts.isEmpty ? '세부 정보 없음' : parts.join(' · ');
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
                          '이전에 채점한 과제가 없습니다.',
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
                        final key = '${entry.studentId}|${entry.item.id}';
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
                                      _gradingHistoryTitle(entry.item),
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
                                      '${entry.studentName} · ${_formatDateTime(entry.confirmedAt)}',
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
                                      _gradingHistoryMeta(entry.item),
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
                                          final rollbackDecrement =
                                              await HomeworkAssignmentStore
                                                  .instance
                                                  .rollbackLatestCheckForItem(
                                            studentId: entry.studentId,
                                            homeworkItemId: entry.item.id,
                                          );
                                          if (!dialogContext.mounted) return;
                                          if (rollbackDecrement == null) {
                                            ScaffoldMessenger.of(dialogContext)
                                                .showSnackBar(
                                              const SnackBar(
                                                content: Text(
                                                  '검사 횟수 롤백에 실패했습니다. 다시 시도해 주세요.',
                                                ),
                                              ),
                                            );
                                            return;
                                          }
                                          await HomeworkStore.instance.submit(
                                              entry.studentId, entry.item.id);
                                          if (!dialogContext.mounted) return;
                                          ScaffoldMessenger.of(dialogContext)
                                              .showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                rollbackDecrement > 0
                                                    ? '채점을 취소하고 제출 단계로 되돌렸어요. 검사횟수도 복원했습니다.'
                                                    : '채점을 취소하고 제출 단계로 되돌렸어요.',
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

  const _SlideableHomeworkChip({
    super.key,
    required this.child,
    required this.onTap,
    this.onLongPress,
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
                  if (widget.upLabel.isNotEmpty && widget.canSlideUp)
                    Align(
                      alignment: const Alignment(0.9, 0),
                      child: Transform.translate(
                        offset: const Offset(-5, 0),
                        child: Opacity(
                          opacity: isLeft
                              ? (0.2 + 0.8 * progress).clamp(0.0, 1.0)
                              : 0.0,
                          child: Text(
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
  final bool showHorizontalDivider;
  final double width;
  final EdgeInsetsGeometry margin;
  const _AttendingButton({
    required this.studentId,
    required this.name,
    required this.color,
    required this.arrivalTime,
    this.showHorizontalDivider = false,
    this.width = ClassContentScreen._attendingCardWidth,
    this.margin = const EdgeInsets.only(left: 24),
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {},
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
                builder: (context, _bindRev, __) => ValueListenableBuilder<int>(
                      valueListenable: HomeworkStore.instance.revision,
                      builder: (context, _rev, _) {
                        // 과제 진행 상태 확인
                        final items = HomeworkStore.instance
                            .items(studentId)
                            .where((e) => e.status != HomeworkStatus.completed)
                            .toList();
                        final bool hasAny = items.isNotEmpty;
                        final bool hasRunning =
                            HomeworkStore.instance.runningOf(studentId) != null;
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
                            ? boundDevice.replaceAll(RegExp(r'^m5-device-'), '')
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
                                        final confirm = await showDialog<bool>(
                                          context: context,
                                          builder: (ctx) => AlertDialog(
                                            backgroundColor:
                                                const Color(0xFF1E1E1E),
                                            shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(16)),
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
                                                        color: Colors.white54)),
                                              ),
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.pop(ctx, true),
                                                child: const Text('해제',
                                                    style: TextStyle(
                                                        color:
                                                            Color(0xFF1FA95B))),
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
                                            await Supabase.instance.client.rpc(
                                                'm5_unbind_by_student',
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
                                          color: Colors.white.withOpacity(0.12),
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
    );
  }
}
