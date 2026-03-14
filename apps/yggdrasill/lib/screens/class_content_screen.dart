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
                            onSubmittedCardTap: (studentId, hw) {
                              return _handleSubmittedChipTapForPending(
                                context: context,
                                studentId: studentId,
                                hw: hw,
                              );
                            },
                            onHomeworkCardTap: (studentId, hw) {
                              if (_printPickMode) {
                                return _handleHomeworkPrintPick(
                                  context: context,
                                  studentId: studentId,
                                  hw: hw,
                                );
                              }
                              return _runHomeworkCheckDialogOnly(
                                context: context,
                                studentId: studentId,
                                hw: hw,
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
      ],
    );
  }

  Widget _buildStudentColumn(BuildContext context, _AttendingStudent student) {
    final isReservedExpanded = _expandedReservedStudentId == student.id;
    const panelWidth = ClassContentScreen._studentColumnContentWidth;
    return AnimatedContainer(
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
    final allPendingItemIds = HomeworkStore.instance
        .items(studentId)
        .where((e) => e.status != HomeworkStatus.completed)
        .map((e) => e.id)
        .toList();
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
        HomeworkStore.instance.markItemsAsHomework(
          studentId,
          selection.itemIds,
          dueDate: selection.dueDate,
          cloneCompletedItems: true,
        );
      }
      final selectedIds = selection.itemIds.toSet();
      final unselectedIds =
          allPendingItemIds.where((id) => !selectedIds.contains(id)).toList();
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
  }) async {
    final key = (studentId: studentId, itemId: hw.id);
    if (_pendingConfirms.containsKey(key)) {
      setState(() => _pendingConfirms.remove(key));
      return;
    }

    if (!_hasDirectHomeworkTextbookLink(hw)) {
      setState(() => _pendingConfirms[key] = false);
      return;
    }
    final resolved =
        await _resolveHomeworkPdfLinks(hw, allowFlowFallback: false);
    if (!context.mounted) return;

    final answerRaw = resolved.answerPathRaw;
    if (answerRaw.isEmpty) {
      setState(() => _pendingConfirms[key] = false);
      return;
    }
    final answerIsUrl = _isWebUrl(answerRaw);
    final answerPath =
        answerIsUrl ? answerRaw.trim() : _toLocalFilePath(answerRaw);
    if (answerPath.isEmpty ||
        (!answerIsUrl && !answerPath.toLowerCase().endsWith('.pdf'))) {
      setState(() => _pendingConfirms[key] = false);
      return;
    }
    if (!answerIsUrl && !await File(answerPath).exists()) {
      if (!context.mounted) return;
      setState(() => _pendingConfirms[key] = false);
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
      setState(() => _pendingConfirms[key] = true);
    } else if (action == HomeworkAnswerViewerAction.confirm) {
      setState(() => _pendingConfirms[key] = false);
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

      if (hw.phase == 3 && isComplete) {
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
        await HomeworkStore.instance
            .confirm(key.studentId, key.itemId, recordAssignmentCheck: false);
        HomeworkStore.instance.markAutoCompleteOnNextWaiting(key.itemId);
      } else if (hw.phase == 3 && !isComplete) {
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
      Text(
        bookAndCourse,
        style: const TextStyle(
          color: kDlgText,
          fontSize: 20,
          fontWeight: FontWeight.w900,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      const SizedBox(height: 4),
    ],
    Text(
      title,
      style: TextStyle(
        color: bookAndCourse.isNotEmpty ? kDlgTextSub : kDlgText,
        fontSize: bookAndCourse.isNotEmpty ? 15 : 18,
        fontWeight:
            bookAndCourse.isNotEmpty ? FontWeight.w600 : FontWeight.w800,
      ),
      maxLines: 1,
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
    markCompleted: true,
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
final Map<String, Future<Set<String>>> _activeAssignedItemIdsFutureByStudent =
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
  final controller =
      ImeAwareTextEditingController(text: (child.memo ?? '').trim());
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
  final titleController = ImeAwareTextEditingController(
    text: (template?.title ?? group.title).trim(),
  );
  final pageController =
      ImeAwareTextEditingController(text: (template?.page ?? '').trim());
  final countController = ImeAwareTextEditingController(
    text: template?.count == null ? '' : '${template!.count}',
  );
  final typeController =
      ImeAwareTextEditingController(text: (template?.type ?? '').trim());
  final memoController =
      ImeAwareTextEditingController(text: (template?.memo ?? '').trim());

  final submitted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: kDlgBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: const Text(
        '하위 과제 추가',
        style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
      ),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                style: const TextStyle(color: kDlgText),
                decoration: InputDecoration(
                  labelText: '제목',
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
              ),
              const SizedBox(height: 8),
              TextField(
                controller: pageController,
                style: const TextStyle(color: kDlgText),
                decoration: InputDecoration(
                  labelText: '페이지',
                  labelStyle: const TextStyle(color: kDlgTextSub),
                  hintText: '예) 10-15',
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
              const SizedBox(height: 8),
              TextField(
                controller: countController,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: kDlgText),
                decoration: InputDecoration(
                  labelText: '문항수',
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
              ),
              const SizedBox(height: 8),
              TextField(
                controller: typeController,
                style: const TextStyle(color: kDlgText),
                decoration: InputDecoration(
                  labelText: '유형',
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
              ),
              const SizedBox(height: 8),
              TextField(
                controller: memoController,
                minLines: 2,
                maxLines: 5,
                style: const TextStyle(color: kDlgText),
                decoration: InputDecoration(
                  labelText: '메모',
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
              ),
            ],
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
          child: const Text('추가'),
        ),
      ],
    ),
  );
  if (submitted != true || !context.mounted) return;

  final page = pageController.text.trim();
  if (page.isEmpty) {
    _showHomeworkChipSnackBar(context, '페이지를 입력해 주세요.');
    return;
  }

  final createdId = await HomeworkStore.instance.addWaitingItemToGroup(
    studentId: studentId,
    groupId: group.id,
    title: titleController.text.trim(),
    page: page,
    count: int.tryParse(countController.text.trim()),
    type: typeController.text.trim(),
    memo: memoController.text.trim(),
    templateItemId: template?.id,
  );
  if (!context.mounted) return;
  _showHomeworkChipSnackBar(
    context,
    createdId == null ? '하위 과제 추가에 실패했습니다.' : '하위 과제를 추가했어요.',
  );
}

String _mergeGroupChildMemoText(Iterable<HomeworkItem> items) {
  final out = <String>[];
  final seen = <String>{};
  for (final item in items) {
    final memo = (item.memo ?? '').trim();
    if (memo.isEmpty) continue;
    if (seen.add(memo)) out.add(memo);
  }
  return out.join('\n');
}

Future<void> _mergeGroupChildrenByDrag({
  required BuildContext context,
  required String studentId,
  required HomeworkGroup group,
  required HomeworkItem source,
  required HomeworkItem target,
}) async {
  if (source.id == target.id) return;
  final sourceWaiting =
      source.status != HomeworkStatus.completed && source.phase == 1;
  final targetWaiting =
      target.status != HomeworkStatus.completed && target.phase == 1;
  if (!sourceWaiting || !targetWaiting) {
    _showHomeworkChipSnackBar(context, '병합은 대기 상태 하위 과제끼리만 가능합니다.');
    return;
  }

  final shouldMerge = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: kDlgBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: const Text(
        '하위 과제 병합',
        style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
      ),
      content: Text(
        '`${source.title.trim().isEmpty ? '(제목 없음)' : source.title.trim()}`을(를)\n'
        '`${target.title.trim().isEmpty ? '(제목 없음)' : target.title.trim()}` 위로 합칠까요?',
        style: const TextStyle(color: kDlgTextSub, height: 1.35),
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
          child: const Text('병합'),
        ),
      ],
    ),
  );
  if (shouldMerge != true || !context.mounted) return;

  final mergedTitle = (target.title).trim().isNotEmpty
      ? target.title.trim()
      : ((source.title).trim().isNotEmpty
          ? source.title.trim()
          : (group.title.trim().isEmpty ? '병합 과제' : group.title.trim()));
  final mergedPage = _mergeGroupPageText([source, target]).trim();
  final mergedCountValue = ((source.count ?? 0) > 0 ? (source.count ?? 0) : 0) +
      ((target.count ?? 0) > 0 ? (target.count ?? 0) : 0);
  final mergedType = (target.type ?? '').trim().isNotEmpty
      ? target.type!.trim()
      : (source.type ?? '').trim();
  final mergedMemo = _mergeGroupChildMemoText([target, source]);

  try {
    final mergedId = await HomeworkStore.instance.mergeWaitingItemsInGroup(
      studentId: studentId,
      groupId: group.id,
      itemIds: [source.id, target.id],
      mergedTitle: mergedTitle,
      mergedPage: mergedPage,
      mergedCount: mergedCountValue > 0 ? mergedCountValue : null,
      mergedType: mergedType,
      mergedMemo: mergedMemo,
    );
    if (mergedId != null && mergedMemo.trim().isNotEmpty) {
      final mergedItem = HomeworkStore.instance.getById(studentId, mergedId);
      if (mergedItem != null &&
          (mergedItem.memo ?? '').trim() != mergedMemo.trim()) {
        HomeworkStore.instance.edit(
          studentId,
          _copyHomeworkItemForInlineEdit(mergedItem, memo: mergedMemo.trim()),
        );
      }
    }
    if (!context.mounted) return;
    _showHomeworkChipSnackBar(
      context,
      mergedId == null ? '병합 결과를 확인하지 못했습니다.' : '드래그 병합 완료',
    );
  } catch (e) {
    if (!context.mounted) return;
    _showHomeworkChipSnackBar(context, '병합 실패: ${e.toString()}');
  }
}

const double _homeworkChipCollapsedHeight = 136.0;
const double _homeworkChipExpandedHeight = 210.0;
double _homeworkGroupExpandedHeightForChildCount(int childCount) {
  if (childCount <= 0) return _homeworkChipExpandedHeight;
  // 상단 정보와 하위 리스트를 충분히 분리하고,
  // 하위 과제 수에 비례해 카드 높이가 늘어나도록 계산한다.
  const double groupSectionHeaderHeight = 72;
  const double perChildRowHeight = 58;
  return _homeworkChipExpandedHeight +
      groupSectionHeaderHeight +
      (childCount * perChildRowHeight);
}

double _homeworkChipMaxSlideFor(double h) => h * 0.58;
const double _homeworkChipMaxSlide = _homeworkChipCollapsedHeight * 0.58;
const double _homeworkChipOuterLeftInset =
    (ClassContentScreen._studentColumnWidth -
            ClassContentScreen._studentColumnContentWidth) /
        2;
const String _homeworkPrintTempPrefix = 'hw_print_';
// 그룹 사이클 내(휴식 포함) 진행시간 누적 보장을 위한 기준값 스냅샷 캐시
final Map<String, String> _groupCycleIdentityByGroupId = <String, String>{};
final Map<String, Map<String, int>> _groupChildCycleBaseByGroupId =
    <String, Map<String, int>>{};

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
            _activeAssignedItemIdsFutureByStudent[studentId] =
                HomeworkAssignmentStore.instance
                    .loadActiveAssignedItemIds(studentId);
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
          final activeAssignedFuture =
              _activeAssignedItemIdsFutureByStudent.putIfAbsent(
            studentId,
            () => HomeworkAssignmentStore.instance
                .loadActiveAssignedItemIds(studentId),
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
              return FutureBuilder<Set<String>>(
                future: activeAssignedFuture,
                builder: (context, activeSnapshot) {
                  if (activeSnapshot.connectionState != ConnectionState.done &&
                      !activeSnapshot.hasData) {
                    return const SizedBox.shrink();
                  }
                  return FutureBuilder<List<HomeworkAssignmentDetail>>(
                    future: activeAssignmentsFuture,
                    builder: (context, assignmentsSnapshot) {
                      final activeAssignments = assignmentsSnapshot.data ??
                          const <HomeworkAssignmentDetail>[];
                      final hiddenAssignedIds = <String>{};
                      for (final assignment in activeAssignments) {
                        final hwId = assignment.homeworkItemId.trim();
                        if (hwId.isEmpty) continue;
                        if (_isReservationAssignment(assignment)) {
                          hiddenAssignedIds.add(hwId);
                          continue;
                        }
                        hiddenAssignedIds.add(hwId);
                      }
                      return FutureBuilder<
                          Map<String, HomeworkAssignmentCycleMeta>>(
                        future: assignmentCycleMetaFuture,
                        builder: (context, cycleSnapshot) {
                          final assignmentCycleMetaByItem =
                              cycleSnapshot.data ??
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
                                hiddenAssignedIds,
                                assignmentCycleMetaByItem,
                                pendingConfirms: pendingConfirms,
                                onPhase3Tap: onPhase3Tap,
                                onGroupSubmittedDoubleTap:
                                    onGroupSubmittedDoubleTap,
                                printPickMode: printPickMode,
                                onPrintPickTap: onPrintPickTap,
                                onSlideDownComplete: onSlideDownComplete,
                                expandedHomeworkIds: expandedHomeworkIds,
                                onToggleExpand: onToggleExpand,
                              );
                              final assignedHomeworkSections =
                                  _buildAssignedHomeworkChipsForStudent(
                                context,
                                studentId,
                                tick,
                                flowNames,
                                assignmentCounts,
                                activeAssignments,
                                assignmentCycleMetaByItem,
                                pendingConfirms: pendingConfirms,
                              );
                              final columnChildren = <Widget>[];
                              for (final chip in chips) {
                                if (columnChildren.isNotEmpty) {
                                  columnChildren
                                      .add(const SizedBox(height: 17));
                                }
                                columnChildren.add(chip);
                              }
                              if (assignedHomeworkSections.isNotEmpty) {
                                if (columnChildren.isNotEmpty) {
                                  columnChildren
                                      .add(const SizedBox(height: 30));
                                }
                                columnChildren.addAll(assignedHomeworkSections);
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
              final reservedCount = _resolveReservedHomeworkPairsForStudent(
                studentId,
                activeAssignments,
              ).length;
              if (reservedCount <= 0) {
                return const SizedBox.shrink();
              }
              return SizedBox(
                width: ClassContentScreen._studentColumnContentWidth,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    '예약 과제 $reservedCount개',
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

Future<void> _activateReservedHomeworkChip({
  required BuildContext context,
  required String studentId,
  required HomeworkAssignmentDetail assignment,
}) async {
  final hwId = assignment.homeworkItemId.trim();
  if (hwId.isEmpty) return;
  await HomeworkStore.instance.placeItemAtActiveTail(
    studentId,
    hwId,
    activateFromHomework: true,
  );
  final latest = HomeworkStore.instance.getById(studentId, hwId);
  if (latest != null && latest.phase != 1) {
    await HomeworkStore.instance.waitPhase(studentId, hwId);
  }
  await HomeworkAssignmentStore.instance.clearActiveAssignmentsForItems(
    studentId,
    [hwId],
  );
  if (!context.mounted) return;
  _showHomeworkChipSnackBar(context, '예약 과제를 대기 상태로 전환했어요.');
}

String _formatHomeworkDueSectionLabel(DateTime? dueDate) {
  if (dueDate == null) return '검사일 미정';
  return '검사 ${_formatDateWithWeekdayShort(dueDate)}';
}

Widget _buildHomeworkChipGroupDivider({
  required String title,
  String? subtitle,
  bool prominent = false,
}) {
  final sectionTitle = title.trim();
  final sectionSubtitle = subtitle?.trim() ?? '';
  final lineColor = kDlgAccent;
  final titleColor = kDlgAccent;
  return SizedBox(
    width: ClassContentScreen._studentColumnContentWidth,
    child: Padding(
      padding: EdgeInsets.symmetric(vertical: prominent ? 6 : 4),
      child: Row(
        children: [
          Expanded(child: Container(height: 1, color: lineColor)),
          const SizedBox(width: 10),
          Text(
            sectionTitle,
            style: TextStyle(
              color: titleColor,
              fontSize: 18,
              fontWeight: FontWeight.w800,
              height: 1.1,
            ),
          ),
          if (sectionSubtitle.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(
              sectionSubtitle,
              style: const TextStyle(
                color: Color(0xFF9FE3C6),
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                height: 1.1,
              ),
            ),
          ],
          const SizedBox(width: 10),
          Expanded(child: Container(height: 1, color: lineColor)),
        ],
      ),
    ),
  );
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
  final reservedPairs = _resolveReservedHomeworkPairsForStudent(
    studentId,
    activeAssignments,
  );
  if (reservedPairs.isEmpty) return const <Widget>[];

  final out = <Widget>[];
  for (int i = 0; i < reservedPairs.length; i++) {
    final assignment = reservedPairs[i].key;
    final hw = reservedPairs[i].value;
    final cycleMeta = assignmentCycleMetaByItem[hw.id];
    final repeatIndex = (cycleMeta?.repeatIndex ?? 1).clamp(1, 1 << 30);
    final splitParts =
        (cycleMeta?.splitParts ?? hw.defaultSplitParts).clamp(1, 4);
    final splitRound = (cycleMeta?.splitRound ?? 1).clamp(1, splitParts);
    final flowName = (flowNames[hw.flowId ?? ''] ?? '').trim();
    final page = (hw.page ?? '').trim();
    final count = hw.count ?? 0;
    final countText = count > 0 ? '${count}문항' : '';
    final metaTopParts = <String>[
      if (flowName.isNotEmpty) flowName,
      if (page.isNotEmpty) 'p.$page',
      if (countText.isNotEmpty) countText,
    ];
    final String cycleText = splitParts > 1
        ? '${repeatIndex}회차 · ${splitParts}분할 ${splitRound}차'
        : '${repeatIndex}회차';
    final assignmentCount = assignmentCounts[hw.id] ?? 0;
    final String title = hw.title.trim().isEmpty ? '(제목 없음)' : hw.title.trim();
    final String metaTop = metaTopParts.join(' · ');
    final String metaBottom =
        assignmentCount > 0 ? '$cycleText · 숙제 ${assignmentCount}회' : cycleText;
    out.add(
      MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () {
              unawaited(
                _activateReservedHomeworkChip(
                  context: context,
                  studentId: studentId,
                  assignment: assignment,
                ),
              );
            },
            child: Padding(
              key: ValueKey('reserved_${assignment.id}_${hw.id}'),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Row(
                children: [
                  const Icon(
                    Icons.schedule_rounded,
                    size: 18,
                    color: Color(0xFF8FA3A8),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: kDlgText,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800,
                            height: 1.15,
                          ),
                        ),
                        if (metaTop.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            metaTop,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: kDlgTextSub,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              height: 1.1,
                            ),
                          ),
                        ],
                        const SizedBox(height: 3),
                        Text(
                          metaBottom,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: kDlgAccent,
                            fontSize: 11.8,
                            fontWeight: FontWeight.w700,
                            height: 1.1,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.play_arrow_rounded,
                    size: 27,
                    color: kDlgAccent,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (i != reservedPairs.length - 1) {
      out.add(
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 1),
          child: Divider(height: 1, thickness: 1, color: kDlgBorder),
        ),
      );
    }
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

List<Widget> _buildAssignedHomeworkChipsForStudent(
  BuildContext context,
  String studentId,
  double tick,
  Map<String, String> flowNames,
  Map<String, int> assignmentCounts,
  List<HomeworkAssignmentDetail> activeAssignments,
  Map<String, HomeworkAssignmentCycleMeta> assignmentCycleMetaByItem, {
  Map<({String studentId, String itemId}), bool> pendingConfirms = const {},
}) {
  final assigned = activeAssignments
      .where((a) => a.homeworkItemId.trim().isNotEmpty)
      .where((a) => !_isReservationAssignment(a))
      .toList()
    ..sort((a, b) {
      final ad = a.dueDate == null ? null : _dateOnly(a.dueDate!);
      final bd = b.dueDate == null ? null : _dateOnly(b.dueDate!);
      if (ad == null && bd != null) return 1;
      if (ad != null && bd == null) return -1;
      if (ad != null && bd != null) {
        final dueCmp = ad.compareTo(bd);
        if (dueCmp != 0) return dueCmp;
      }
      final orderCmp = a.orderIndex.compareTo(b.orderIndex);
      if (orderCmp != 0) return orderCmp;
      return a.assignedAt.compareTo(b.assignedAt);
    });

  final assignedPairs = <MapEntry<HomeworkAssignmentDetail, HomeworkItem>>[];
  for (final a in assigned) {
    final hw = HomeworkStore.instance.getById(studentId, a.homeworkItemId);
    if (hw == null || hw.status == HomeworkStatus.completed) continue;
    assignedPairs.add(MapEntry(a, hw));
  }

  if (assignedPairs.isEmpty) return const <Widget>[];

  final grouped =
      <DateTime?, List<MapEntry<HomeworkAssignmentDetail, HomeworkItem>>>{};
  for (final pair in assignedPairs) {
    final dueDate = pair.key.dueDate;
    final key = dueDate == null ? null : _dateOnly(dueDate);
    grouped
        .putIfAbsent(
            key, () => <MapEntry<HomeworkAssignmentDetail, HomeworkItem>>[])
        .add(pair);
  }
  final orderedKeys = grouped.keys.toList()
    ..sort((a, b) {
      if (a == null && b != null) return 1;
      if (a != null && b == null) return -1;
      if (a == null && b == null) return 0;
      return a!.compareTo(b!);
    });

  final out = <Widget>[];

  for (int groupIdx = 0; groupIdx < orderedKeys.length; groupIdx++) {
    final key = orderedKeys[groupIdx];
    final pairs = grouped[key]!;
    final sectionPrefix = groupIdx == 0 ? '숙제' : '다음 숙제';
    final dueLabel = _formatHomeworkDueSectionLabel(key);
    out.add(
      _buildHomeworkChipGroupDivider(
        title: '$sectionPrefix ($dueLabel)',
        prominent: true,
      ),
    );
    out.add(const SizedBox(height: 12));

    final groupChips = <Widget>[];
    final groupAssignmentIds = <String>[];
    for (int i = 0; i < pairs.length; i++) {
      final a = pairs[i].key;
      final hw = pairs[i].value;
      final isReservation = _isReservationAssignment(a);
      groupAssignmentIds.add(a.id);
      groupChips.add(
        _SlideableHomeworkChip(
          key: ValueKey('hw_assigned_${a.id}_${hw.id}'),
          maxSlide: _homeworkChipMaxSlide,
          canSlideDown: false,
          canSlideUp: false,
          downLabel: '',
          upLabel: '',
          downColor: const Color(0xFF9FB3B3),
          upColor: const Color(0xFFE57373),
          onTap: () {
            final item = HomeworkStore.instance.getById(studentId, hw.id);
            if (item == null) return;
            unawaited(
              _runHomeworkCheckDialogOnly(
                context: context,
                studentId: studentId,
                hw: item,
              ),
            );
          },
          onSlideDown: () {},
          onSlideUp: () async {},
          child: _buildHomeworkChipWithReorderHandle(
            index: i,
            chipVisual: _buildHomeworkChipVisual(
              context,
              studentId,
              hw,
              flowNames[hw.flowId ?? ''] ?? '',
              assignmentCounts[hw.id] ?? 0,
              tick: tick,
              isReservation: isReservation,
              cycleMeta: assignmentCycleMetaByItem[hw.id],
              isPendingConfirm: pendingConfirms.containsKey(
                (studentId: studentId, itemId: hw.id),
              ),
              isCompleteCheckbox:
                  pendingConfirms[(studentId: studentId, itemId: hw.id)] ==
                      true,
            ),
          ),
        ),
      );
    }
    out.add(
      ReorderableListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: groupChips.length,
        buildDefaultDragHandles: false,
        proxyDecorator: (child, _, __) =>
            Material(color: Colors.transparent, child: child),
        onReorder: (oldIndex, newIndex) {
          if (newIndex > oldIndex) newIndex -= 1;
          final reorderedAssignmentIds = List<String>.from(groupAssignmentIds);
          final movedId = reorderedAssignmentIds.removeAt(oldIndex);
          reorderedAssignmentIds.insert(newIndex, movedId);
          unawaited(
            HomeworkAssignmentStore.instance.reorderAssignedInDueGroup(
              studentId: studentId,
              dueDate: key,
              orderedAssignmentIds: reorderedAssignmentIds,
            ),
          );
        },
        itemBuilder: (context, index) {
          return _buildHomeworkReorderableItem(
            itemKey: 'assigned_group_${groupIdx}_${groupAssignmentIds[index]}',
            chip: groupChips[index],
            showBottomGap: index != groupChips.length - 1,
          );
        },
      ),
    );

    if (groupIdx != orderedKeys.length - 1) {
      out.add(const SizedBox(height: 10));
    }
  }

  return out;
}

List<Widget> _buildHomeworkChipsOnceForStudent(
  BuildContext context,
  String studentId,
  double tick,
  Map<String, String> flowNames,
  Map<String, int> assignmentCounts,
  Set<String> activeAssignedItemIds,
  Map<String, HomeworkAssignmentCycleMeta> assignmentCycleMetaByItem, {
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
        .where((e) => !activeAssignedItemIds.contains(e.id))
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
    final double chipH = groupExpanded
        ? _homeworkGroupExpandedHeightForChildCount(children.length)
        : _homeworkChipCollapsedHeight;
    final groupFlowId = (group.flowId ?? summary.flowId ?? '').trim();
    final groupFlowName = flowNames[groupFlowId] ?? '';
    final int groupAssignmentCount = children.fold<int>(
      0,
      (sum, item) => sum + (assignmentCounts[item.id] ?? 0),
    );
    final submittedKeys = children
        .where((e) =>
            e.status != HomeworkStatus.completed &&
            e.completedAt == null &&
            e.phase == 3)
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
      onTap: () => onToggleExpand?.call(group.id),
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
        final submittedChildren = children
            .where((e) =>
                e.status != HomeworkStatus.completed &&
                e.completedAt == null &&
                e.phase == 3)
            .toList(growable: false);
        if (submittedChildren.isNotEmpty) {
          onGroupSubmittedDoubleTap?.call(studentId, submittedChildren);
          return;
        }
        unawaited(HomeworkStore.instance.bulkTransitionGroup(
          studentId,
          group.id,
          fromPhase: summary.phase,
        ));
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
          tick: tick,
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
          onGroupChildMergeDrop: (dragged, target) async {
            await _mergeGroupChildrenByDrag(
              context: context,
              studentId: studentId,
              group: group,
              source: dragged,
              target: target,
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

Future<void> _showHomeworkGroupMergeDialog({
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
  if (waitingItems.length < 2) {
    _showHomeworkChipSnackBar(context, '병합은 대기 과제 2개 이상일 때 가능합니다.');
    return;
  }

  final selectedIds = <String>{
    waitingItems[0].id,
    waitingItems[1].id,
  };
  final titleController = ImeAwareTextEditingController(
    text: group.title.trim().isEmpty ? waitingItems.first.title : group.title,
  );
  final pageController = ImeAwareTextEditingController(
    text: _mergeGroupPageText(waitingItems),
  );
  final countController = ImeAwareTextEditingController(
    text: waitingItems
        .fold<int>(
            0, (sum, e) => sum + ((e.count ?? 0) > 0 ? (e.count ?? 0) : 0))
        .toString(),
  );
  final typeController = ImeAwareTextEditingController(
    text: (waitingItems.first.type ?? '').trim(),
  );
  final contentController = ImeAwareTextEditingController(
    text: (waitingItems.first.content ?? '').trim(),
  );

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
              '그룹 과제 병합',
              style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
            ),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const YggDialogSectionHeader(
                      icon: Icons.merge_type_rounded,
                      title: '병합 대상 선택',
                    ),
                    ...waitingItems.map(
                      (item) => CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        activeColor: kDlgAccent,
                        value: selectedIds.contains(item.id),
                        onChanged: (checked) {
                          setLocalState(() {
                            if (checked == true) {
                              selectedIds.add(item.id);
                            } else {
                              selectedIds.remove(item.id);
                            }
                          });
                        },
                        title: Text(
                          item.title.trim().isEmpty ? '(제목 없음)' : item.title,
                          style:
                              const TextStyle(color: kDlgText, fontSize: 13.5),
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          'p.${(item.page ?? '').trim().isEmpty ? '-' : item.page} · ${item.count ?? 0}문항',
                          style: const TextStyle(
                              color: kDlgTextSub, fontSize: 11.5),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const YggDialogSectionHeader(
                      icon: Icons.settings_rounded,
                      title: '병합 결과 설정',
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: titleController,
                      style: const TextStyle(color: kDlgText),
                      decoration: InputDecoration(
                        labelText: '제목',
                        labelStyle: const TextStyle(color: kDlgTextSub),
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
                    const SizedBox(height: 8),
                    TextField(
                      controller: pageController,
                      style: const TextStyle(color: kDlgText),
                      decoration: InputDecoration(
                        labelText: '페이지',
                        labelStyle: const TextStyle(color: kDlgTextSub),
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
                    const SizedBox(height: 8),
                    TextField(
                      controller: countController,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(color: kDlgText),
                      decoration: InputDecoration(
                        labelText: '문항수',
                        labelStyle: const TextStyle(color: kDlgTextSub),
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
                    const SizedBox(height: 8),
                    TextField(
                      controller: typeController,
                      style: const TextStyle(color: kDlgText),
                      decoration: InputDecoration(
                        labelText: '유형',
                        labelStyle: const TextStyle(color: kDlgTextSub),
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
                    const SizedBox(height: 8),
                    TextField(
                      controller: contentController,
                      minLines: 2,
                      maxLines: 4,
                      style: const TextStyle(color: kDlgText),
                      decoration: InputDecoration(
                        labelText: '내용',
                        labelStyle: const TextStyle(color: kDlgTextSub),
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
                child: const Text('병합 실행'),
              ),
            ],
          );
        },
      );
    },
  );
  if (submitted != true || !context.mounted) return;
  if (selectedIds.length < 2) {
    _showHomeworkChipSnackBar(context, '병합 대상은 최소 2개여야 합니다.');
    return;
  }
  final mergedMemo = _mergeGroupChildMemoText(
    waitingItems.where((e) => selectedIds.contains(e.id)),
  );

  try {
    final mergedId = await HomeworkStore.instance.mergeWaitingItemsInGroup(
      studentId: studentId,
      groupId: group.id,
      itemIds: selectedIds.toList(growable: false),
      mergedTitle: titleController.text.trim(),
      mergedPage: pageController.text.trim(),
      mergedCount: int.tryParse(countController.text.trim()),
      mergedType: typeController.text.trim(),
      mergedMemo: mergedMemo,
      mergedContent: contentController.text.trim(),
    );
    if (!context.mounted) return;
    _showHomeworkChipSnackBar(
      context,
      mergedId == null ? '병합 결과를 확인하지 못했습니다.' : '병합 완료',
    );
  } catch (e) {
    if (!context.mounted) return;
    _showHomeworkChipSnackBar(context, '병합 실패: ${e.toString()}');
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
                '그룹 카드 더블탭으로도 일괄 상태전환이 가능합니다.',
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
          OutlinedButton.icon(
            onPressed: waitingCount >= 2
                ? () {
                    Navigator.of(dialogContext).pop();
                    unawaited(
                      _showHomeworkGroupMergeDialog(
                        context: context,
                        studentId: studentId,
                        group: group,
                      ),
                    );
                  }
                : null,
            icon: const Icon(Icons.merge_type_rounded, size: 16),
            label: const Text('병합'),
          ),
          FilledButton.icon(
            onPressed: children.isEmpty
                ? null
                : () {
                    Navigator.of(dialogContext).pop();
                    unawaited(() async {
                      final int? fromPhase = runningCount > 0
                          ? 2
                          : (waitingCount > 0
                              ? 1
                              : (confirmedCount > 0 ? 4 : null));
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

Future<String?> _showHomeworkPrintConfirmDialog({
  required BuildContext context,
  required HomeworkItem hw,
  required String filePath,
  required bool isPdf,
  required String initialRange,
}) async {
  final controller = ImeAwareTextEditingController(text: initialRange);
  bool printWhole = initialRange.isEmpty || !isPdf;
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setLocalState) {
          return AlertDialog(
            backgroundColor: kDlgBg,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text(
              '인쇄 설정 확인',
              style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
            ),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const YggDialogSectionHeader(
                    icon: Icons.print_rounded,
                    title: '출력 정보',
                  ),
                  Text(
                    hw.title.trim().isEmpty ? '(제목 없음)' : hw.title.trim(),
                    style: const TextStyle(
                      color: kDlgText,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    p.basename(filePath),
                    style: const TextStyle(color: kDlgTextSub, fontSize: 12.5),
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
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(
                  (isPdf && !printWhole) ? controller.text.trim() : '',
                ),
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
  final initialRange = isPdf ? _normalizePageRangeForPrint(hw.page ?? '') : '';
  final selectedRange = await _showHomeworkPrintConfirmDialog(
    context: context,
    hw: hw,
    filePath: bodyPath,
    isPdf: isPdf,
    initialRange: initialRange,
  );
  if (!context.mounted || selectedRange == null) return;

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
  if (!_hasDirectHomeworkTextbookLink(hw)) {
    await _runHomeworkCheckAndConfirm(
      context: context,
      studentId: studentId,
      hw: hw,
    );
    return;
  }
  final resolved = await _resolveHomeworkPdfLinks(hw, allowFlowFallback: false);
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

Widget _buildFlowChip(String flowName) {
  final bool isDefault = flowName == '현행';
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
    decoration: BoxDecoration(
      color: isDefault ? Colors.transparent : const Color(0xFF2A3030),
      borderRadius: BorderRadius.circular(20),
      border: isDefault
          ? Border.all(color: const Color(0xFF4A5858), width: 1)
          : null,
    ),
    child: Text(
      flowName,
      style: const TextStyle(
        color: Color(0xFF9FB3B3),
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
  required double tick,
  bool isReservation = false,
  bool isExpanded = false,
  List<HomeworkItem> groupChildren = const <HomeworkItem>[],
  double? chipHeightOverride,
  HomeworkAssignmentCycleMeta? cycleMeta,
  bool isPendingConfirm = false,
  bool isCompleteCheckbox = false,
  VoidCallback? onInfoTap,
  void Function(HomeworkItem child)? onGroupChildPageTap,
  void Function(HomeworkItem child)? onGroupChildMemoTap,
  VoidCallback? onGroupChildAddTap,
  Future<void> Function(HomeworkItem dragged, HomeworkItem target)?
      onGroupChildMergeDrop,
}) {
  final bool isRunning =
      HomeworkStore.instance.runningOf(studentId)?.id == hw.id;
  final int phase = hw.phase;
  final bool visualRunning = isReservation ? false : isRunning;
  final int visualPhase = isReservation ? 1 : phase;
  const Color unifiedHomeworkAccent = kDlgAccent;
  final TextStyle titleStyle = const TextStyle(
    color: Color(0xFFCAD2C5),
    fontSize: 23,
    fontWeight: FontWeight.w700,
    height: 1.1,
  );
  final TextStyle metaStyle = const TextStyle(
    color: Color(0xFFCAD2C5),
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 1.1,
  );
  final TextStyle statStyle = const TextStyle(
    color: Color(0xFF7F8C8C),
    fontSize: 13.5,
    fontWeight: FontWeight.w600,
    height: 1.1,
  );
  final TextStyle line4Style = const TextStyle(
    color: Color(0xFF748686),
    fontSize: 12.5,
    fontWeight: FontWeight.w600,
    height: 1.1,
  );
  final TextStyle typeStyle = const TextStyle(
    color: Color(0xFFCAD2C5),
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 1.1,
  );
  final TextStyle groupChildTitleStyle = const TextStyle(
    color: Color(0xFFB9C3BA),
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.2,
  );
  final TextStyle groupChildIndexStyle = const TextStyle(
    color: Color(0xFF7F8C8C),
    fontSize: 13,
    fontWeight: FontWeight.w700,
    height: 1.1,
  );
  final TextStyle groupChildMetaStyle = const TextStyle(
    color: Color(0xFF8FA1A1),
    fontSize: 12.5,
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
  final String line4Left =
      '페이지 p.${page.isNotEmpty ? page : '-'} · 문항 ${displayCount.isNotEmpty ? displayCount : '-'}문항';
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
        _buildFlowChip(displayFlowName),
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
            child: Text(
              titleText,
              style: metaStyle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
    final String expandedLine3 =
        '시작 $startedAtText · 진행 ${progressMinutes}분 · 총 $durationText';
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

    String groupChildMemoLabel(HomeworkItem child) {
      final memo = (child.memo ?? '').trim();
      return memo.isEmpty ? '-' : memo;
    }

    Widget buildGroupChildRow(HomeworkItem child, int index) {
      final bool canDropMerge = onGroupChildMergeDrop != null &&
          child.status != HomeworkStatus.completed &&
          child.phase == 1;
      final bool canTapPage = onGroupChildPageTap != null;
      final bool canTapMemo = onGroupChildMemoTap != null;

      Widget rowContent = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxRowW),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 22,
                  child: Text(
                    '${index + 1}.',
                    style: groupChildIndexStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Expanded(
                  child: Text(
                    groupChildLabel(child),
                    style: groupChildTitleStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: canTapPage ? () => onGroupChildPageTap(child) : null,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: Text(
                      groupChildPageLabel(child),
                      style: groupChildMetaStyle.copyWith(
                        decoration: canTapPage
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
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.only(left: 22),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: canTapMemo ? () => onGroupChildMemoTap(child) : null,
                child: Text(
                  groupChildMemoLabel(child),
                  style: groupChildMetaStyle.copyWith(
                    decoration: canTapMemo
                        ? TextDecoration.underline
                        : TextDecoration.none,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      );

      if (canDropMerge) {
        rowContent = LongPressDraggable<HomeworkItem>(
          data: child,
          maxSimultaneousDrags: 1,
          feedback: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF202629),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF3E5757)),
              ),
              child: Text(
                groupChildLabel(child),
                style: groupChildTitleStyle,
              ),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.35, child: rowContent),
          child: rowContent,
        );
      }

      if (onGroupChildMergeDrop == null) {
        return rowContent;
      }

      return DragTarget<HomeworkItem>(
        onWillAcceptWithDetails: (details) {
          final dragged = details.data;
          if (dragged.id == child.id) return false;
          final draggedWaiting =
              dragged.status != HomeworkStatus.completed && dragged.phase == 1;
          return draggedWaiting &&
              child.status != HomeworkStatus.completed &&
              child.phase == 1;
        },
        onAcceptWithDetails: (details) {
          unawaited(onGroupChildMergeDrop(details.data, child));
        },
        builder: (context, candidateData, rejectedData) {
          final highlighted = candidateData.isNotEmpty;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: highlighted ? const Color(0x1F4FBF97) : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: highlighted
                  ? Border.all(color: const Color(0xFF4FBF97), width: 1.0)
                  : null,
            ),
            child: rowContent,
          );
        },
      );
    }

    columnChildren = [
      row1,
      const SizedBox(height: 15),
      row2,
      const SizedBox(height: 7),
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxRowW),
        child: Text(
          expandedLine3,
          style: statStyle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      const SizedBox(height: 6),
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxRowW),
        child: Text(
          line4Left,
          style: line4Style,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
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
                  style: line4Style,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (onGroupChildAddTap != null)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onGroupChildAddTap,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: const Color(0x1A9FE3C6),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: const Color(0x664FBF97),
                        width: 1.0,
                      ),
                    ),
                    child: const Icon(
                      Icons.add_rounded,
                      size: 14,
                      color: Color(0xFF9FE3C6),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        for (int i = 0; i < visibleGroupChildren; i++) ...[
          buildGroupChildRow(groupChildren[i], i),
          if (i != visibleGroupChildren - 1) ...[
            const SizedBox(height: 8),
            Container(
              width: maxRowW,
              height: 1,
              color: const Color(0x223A4545),
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 8),
        ],
      ],
      if (onInfoTap != null) ...[
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: GestureDetector(
            onTap: onInfoTap,
            behavior: HitTestBehavior.opaque,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 2, vertical: 2),
              child: Icon(
                Icons.info_outline_rounded,
                size: 16,
                color: Color(0xFF748686),
              ),
            ),
          ),
        ),
      ],
    ];
  } else {
    columnChildren = [
      row1,
      const SizedBox(height: 15),
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
