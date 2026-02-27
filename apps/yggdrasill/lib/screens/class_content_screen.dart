import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import '../services/data_manager.dart';
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

  @override
  void initState() {
    super.initState();
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
                                    const WidgetSpan(child: SizedBox(width: 30)),
                                    TextSpan(
                                      text: '등원중: ${list.length}명',
                                      style: const TextStyle(
                                          color: Colors.white60,
                                          fontSize: 40,
                                          fontWeight: FontWeight.bold),
                                    ),
                                    const WidgetSpan(child: SizedBox(width: 24)),
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
                                    });
                                  },
                                  activeColor: kDlgAccent,
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
                        ? const GradingModePage()
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
                                  height: ClassContentScreen._attendingCardHeight,
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
    return SizedBox(
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
          Padding(
            padding: const EdgeInsets.only(
              left: ClassContentScreen._studentNameStartInset,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 58,
                  height: 58,
                  child: IconButton(
                    onPressed: () => _onAddHomework(context, student.id),
                    icon: const Icon(Icons.add_rounded),
                    iconSize: 28,
                    color: kDlgTextSub,
                    splashRadius: 29,
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
          const SizedBox(height: 18),
          Expanded(
            child: AnimatedBuilder(
              animation: _uiAnimController,
              builder: (context, __) {
                final tick = _uiAnimController.value; // 0..1
                return _buildHomeworkChipsReactiveForStudent(
                  student.id,
                  tick,
                );
              },
            ),
          ),
        ],
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
        for (final entry in entries) {
          final countStr = (entry['count'] as String?)?.trim();
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
          );
          createdItems.add(created);
        }
        if (isReserve && createdItems.isNotEmpty) {
          await HomeworkAssignmentStore.instance.recordAssignments(
            studentId,
            createdItems,
            note: HomeworkAssignmentStore.reservationNote,
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
      final activeAssignments =
          await HomeworkAssignmentStore.instance.loadActiveAssignments(studentId);
      final checksByItem =
          await HomeworkAssignmentStore.instance.loadChecksForStudent(studentId);
      final assignmentsByItem = await HomeworkAssignmentStore.instance
          .loadAssignmentsForStudent(studentId);
      if (!context.mounted) return;

      final today = _dateOnly(DateTime.now());
      bool isToday(DateTime dt) => _dateOnly(dt) == today;

      final entries = <_HomeworkOverviewEntry>[];
      final seenItemIds = <String>{};

      for (final assignment in activeAssignments) {
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
        if (itemId.isEmpty || seenItemIds.contains(itemId)) continue;
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
    final hasHomeworkItems = HomeworkStore.instance
        .items(studentId)
        .any((e) => e.status != HomeworkStatus.completed);
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
  final active = await HomeworkAssignmentStore.instance
      .loadActiveAssignments(studentId);
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

Future<_HomeworkCheckDraft?> _showHomeworkItemCheckDialog({
  required BuildContext context,
  required HomeworkItem hw,
  required _HomeworkCheckTarget target,
  required int minProgress,
}) async {
  int progress = minProgress.clamp(0, 150);
  final progressController =
      ImeAwareTextEditingController(text: progress.toString());
  final validIssues = const {'lost', 'forgot', 'other'};
  String? issueType = validIssues.contains(target.issueType)
      ? target.issueType
      : null;
  final noteController = ImeAwareTextEditingController(
    text: issueType == 'other' ? (target.issueNote ?? '') : '',
  );

  final result = await showDialog<_HomeworkCheckDraft>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            backgroundColor: kDlgBg,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text(
              '숙제 검사',
              style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900),
            ),
            content: SizedBox(
              width: 560,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const YggDialogSectionHeader(
                    icon: Icons.assignment_turned_in,
                    title: '검사 대상',
                  ),
                  Text(
                    hw.title.trim().isEmpty ? '(제목 없음)' : hw.title.trim(),
                    style: const TextStyle(
                      color: kDlgText,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _formatDateRange(target.assignedAt, target.dueDate),
                    style: const TextStyle(color: kDlgTextSub, fontSize: 13),
                  ),
                  const SizedBox(height: 14),
                  const YggDialogSectionHeader(
                    icon: Icons.tune_rounded,
                    title: '완료율',
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Slider(
                          value: progress.toDouble(),
                          min: 0,
                          max: 150,
                          divisions: 15,
                          label: '$progress%',
                          activeColor: kDlgAccent,
                          inactiveColor: kDlgBorder,
                          onChanged: (v) {
                            final next = ((v / 10).round() * 10)
                                .clamp(minProgress, 150);
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
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: kDlgText,
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                          decoration: InputDecoration(
                            suffixText: '%',
                            suffixStyle: const TextStyle(color: kDlgTextSub),
                            filled: true,
                            fillColor: kDlgFieldBg,
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(color: kDlgBorder),
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
                            final safe = parsed.clamp(minProgress, 150);
                            setState(() {
                              progress = safe;
                            });
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
                    icon: Icons.flag_outlined,
                    title: '사유(선택)',
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      YggDialogFilterChip(
                        label: '분실',
                        selected: issueType == 'lost',
                        onSelected: (v) {
                          setState(() {
                            issueType = v ? 'lost' : null;
                            if (issueType != 'other') noteController.text = '';
                          });
                        },
                      ),
                      YggDialogFilterChip(
                        label: '잊음',
                        selected: issueType == 'forgot',
                        onSelected: (v) {
                          setState(() {
                            issueType = v ? 'forgot' : null;
                            if (issueType != 'other') noteController.text = '';
                          });
                        },
                      ),
                      YggDialogFilterChip(
                        label: '기타',
                        selected: issueType == 'other',
                        onSelected: (v) {
                          setState(() {
                            issueType = v ? 'other' : null;
                            if (!v) noteController.text = '';
                          });
                        },
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
                          vertical: 10,
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

  final checks =
      await HomeworkAssignmentStore.instance.loadChecksForItem(studentId, hw.id);
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

  final checks =
      await HomeworkAssignmentStore.instance.loadChecksForItem(studentId, hw.id);
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
  HomeworkStore.instance.restoreItemsToWaiting(studentId, [hw.id]);
  await HomeworkAssignmentStore.instance.clearActiveAssignmentsForItems(
    studentId,
    [hw.id],
  );
  await HomeworkStore.instance.moveToBottom(studentId, hw.id);
  if (!context.mounted) return;
  _showHomeworkChipSnackBar(context, '숙제 검사 기록 저장 후 현재 과제로 이동했어요.');
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
final Map<String, Future<Map<String, int>>> _assignmentCountsFutureByStudent =
    {};
final Map<String, Future<Set<String>>> _activeAssignedItemIdsFutureByStudent =
    {};
final Map<String, Future<List<HomeworkAssignmentDetail>>>
    _activeAssignmentsFutureByStudent = {};

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
  final badgeBg = entry.isActive ? const Color(0x3340A883) : const Color(0x334A6871);
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
    checkCount: item.checkCount,
    createdAt: item.createdAt,
    updatedAt: DateTime.now(),
    status: item.status,
    phase: item.phase,
    accumulatedMs: item.accumulatedMs,
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

const double _homeworkChipHeight = 140.0;
const double _homeworkChipMaxSlide = _homeworkChipHeight * 0.58;
const double _homeworkChipOuterLeftInset =
    (ClassContentScreen._studentColumnWidth -
            ClassContentScreen._studentColumnContentWidth) /
        2;
const String _homeworkPrintTempPrefix = 'hw_print_';

// ------------------------
// 오른쪽 패널: 슬라이드시트와 동일한 과제 칩 렌더링
// ------------------------
Widget _buildHomeworkChipsReactiveForStudent(String studentId, double tick) {
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
                  final activeAssignedIds =
                      activeSnapshot.data ?? const <String>{};
                  return FutureBuilder<List<HomeworkAssignmentDetail>>(
                    future: activeAssignmentsFuture,
                    builder: (context, assignmentsSnapshot) {
                      final activeAssignments = assignmentsSnapshot.data ??
                          const <HomeworkAssignmentDetail>[];
                      return ValueListenableBuilder<int>(
                        valueListenable: HomeworkStore.instance.revision,
                        builder: (context, _rev, _) {
                          final chips = _buildHomeworkChipsOnceForStudent(
                            context,
                            studentId,
                            tick,
                            flowNames,
                            assignmentCounts,
                            activeAssignedIds,
                          );
                          final assignedHomeworkSections =
                              _buildAssignedHomeworkChipsForStudent(
                            context,
                            studentId,
                            tick,
                            flowNames,
                            assignmentCounts,
                            activeAssignments,
                          );
                          final columnChildren = <Widget>[];
                          for (final chip in chips) {
                            if (columnChildren.isNotEmpty) {
                              columnChildren.add(const SizedBox(height: 17));
                            }
                            columnChildren.add(chip);
                          }
                          if (assignedHomeworkSections.isNotEmpty) {
                            if (columnChildren.isNotEmpty) {
                              columnChildren.add(const SizedBox(height: 30));
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
  await HomeworkAssignmentStore.instance.clearActiveAssignmentsForItems(
    studentId,
    [hwId],
  );
  final latest = HomeworkStore.instance.getById(studentId, hwId);
  if (latest != null && latest.phase != 1) {
    await HomeworkStore.instance.waitPhase(studentId, hwId);
  }
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
}) {
  return Stack(
    clipBehavior: Clip.hardEdge,
    children: [
      chipVisual,
      Positioned(
        top: 6,
        right: 24,
        child: SizedBox(
          width: 32,
          height: 32,
          child: Center(
            child: ReorderableDragStartListener(
              index: index,
              child: const Icon(
                Icons.drag_handle_rounded,
                size: 20,
                color: Color(0xFF8FA3A8),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

List<Widget> _buildAssignedHomeworkChipsForStudent(
  BuildContext context,
  String studentId,
  double tick,
  Map<String, String> flowNames,
  Map<String, int> assignmentCounts,
  List<HomeworkAssignmentDetail> activeAssignments,
) {
  final assigned = activeAssignments
      .where((a) => a.homeworkItemId.trim().isNotEmpty)
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

  final grouped = <DateTime?, List<MapEntry<HomeworkAssignmentDetail, HomeworkItem>>>{};
  for (final pair in assignedPairs) {
    final dueDate = pair.key.dueDate;
    final key = dueDate == null ? null : _dateOnly(dueDate);
    grouped.putIfAbsent(key, () => <MapEntry<HomeworkAssignmentDetail, HomeworkItem>>[])
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
) {
  final List<Widget> chips = [];
  final List<HomeworkItem> hwList = HomeworkStore.instance
      .items(studentId)
      .where((e) => e.status != HomeworkStatus.completed)
      .where((e) => !activeAssignedItemIds.contains(e.id))
      .toList();

  final displayedHw = hwList.take(12).toList();
  for (int i = 0; i < displayedHw.length; i++) {
    final hw = displayedHw[i];
    final bool isRunning = hw.runStart != null || hw.phase == 2;
    final bool isSubmitted = hw.phase == 3;
    final bool isWaiting = hw.phase == 1;
    final bool isConfirmed = hw.phase == 4;
    final bool slideDownIsEdit = isWaiting || isConfirmed;
    final bool canSlideDown = isRunning || isSubmitted || slideDownIsEdit;
    final String downLabel =
        slideDownIsEdit ? '수정' : (isSubmitted ? '완료' : (isRunning ? '멈춤' : ''));
    chips.add(
      _SlideableHomeworkChip(
        key: ValueKey('hw_chip_${hw.id}'),
        maxSlide: _homeworkChipMaxSlide,
        canSlideDown: canSlideDown,
        canSlideUp: true,
        downLabel: downLabel,
        upLabel: '취소',
        downColor: slideDownIsEdit
            ? kDlgAccent
            : (isSubmitted ? const Color(0xFF4CAF50) : const Color(0xFF9FB3B3)),
        upColor: const Color(0xFFE57373),
        onTap: () {
          final item = HomeworkStore.instance.getById(studentId, hw.id);
          if (item == null) return;
          final int phase = item.phase;
          switch (phase) {
            case 1: // 대기 → 수행
              unawaited(HomeworkStore.instance.start(studentId, hw.id));
              break;
            case 2: // 수행 → 제출
              unawaited(HomeworkStore.instance.submit(studentId, hw.id));
              break;
            case 3: // 제출 → 확인
              unawaited(
                _handleSubmittedChipTapWithAnswerViewer(
                  context: context,
                  studentId: studentId,
                  hw: item,
                ),
              );
              break;
            case 4: // 확인 → 대기
              unawaited(HomeworkStore.instance.waitPhase(studentId, hw.id));
              break;
            default:
              unawaited(HomeworkStore.instance.start(studentId, hw.id));
          }
        },
        onLongPress: !isWaiting
            ? null
            : () {
                final item = HomeworkStore.instance.getById(studentId, hw.id);
                if (item == null || item.phase != 1) return;
                unawaited(
                  _handleWaitingChipLongPressPrint(
                    context: context,
                    hw: item,
                  ),
                );
              },
        onSlideDown: () {
          final item = HomeworkStore.instance.getById(studentId, hw.id);
          if (item == null) return;
          if (item.phase == 1 || item.phase == 4) {
            unawaited(_openHomeworkEditDialogForHome(context, studentId, item));
          } else if (item.runStart != null || item.phase == 2) {
            unawaited(HomeworkStore.instance.pause(studentId, hw.id));
          } else if (item.phase == 3) {
            unawaited(
              _runHomeworkCheckAndConfirm(
                context: context,
                studentId: studentId,
                hw: item,
                markAutoCompleteOnNextWaiting: true,
              ),
            );
          }
        },
        onSlideUp: () async {
          final choice = await showDialog<String>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: kDlgBg,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              title: const Text('과제 취소',
                  style:
                      TextStyle(color: kDlgText, fontWeight: FontWeight.w900)),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    YggDialogSectionHeader(
                        icon: Icons.cancel_outlined, title: '처리 방식'),
                    Text('완전 취소 또는 포기를 선택하세요.',
                        style: TextStyle(color: kDlgTextSub)),
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
                  child: const Text('하드삭제'),
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
            HomeworkStore.instance.remove(studentId, hw.id);
            return;
          }
          if (choice == 'abandon') {
            final reason = await showDialog<String>(
              context: context,
              builder: (ctx) {
                final controller = ImeAwareTextEditingController();
                return AlertDialog(
                  backgroundColor: kDlgBg,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  title: const Text('포기 사유',
                      style: TextStyle(
                          color: kDlgText, fontWeight: FontWeight.w900)),
                  content: SizedBox(
                    width: 420,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const YggDialogSectionHeader(
                            icon: Icons.edit_note, title: '사유 입력'),
                        TextField(
                          controller: controller,
                          minLines: 2,
                          maxLines: 4,
                          style: const TextStyle(color: kDlgText),
                          decoration: InputDecoration(
                            hintText: '포기 사유를 입력하세요',
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
                                horizontal: 12, vertical: 12),
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
                      onPressed: () =>
                          Navigator.of(ctx).pop(controller.text.trim()),
                      style:
                          FilledButton.styleFrom(backgroundColor: kDlgAccent),
                      child: const Text('저장'),
                    ),
                  ],
                );
              },
            );
            if (!context.mounted) return;
            if (reason != null && reason.trim().isNotEmpty) {
              unawaited(
                  HomeworkStore.instance.abandon(studentId, hw.id, reason));
            }
          }
        },
        onDoubleTap: () {
          final item = HomeworkStore.instance.getById(studentId, hw.id);
          if (item == null) return;
          final flow = flowNames[item.flowId ?? ''] ?? '';
          final assignmentCountNow = assignmentCounts[item.id] ?? 0;
          unawaited(
            _showHomeworkChipDetailDialog(
              context,
              studentId,
              item,
              flow,
              assignmentCountNow,
            ),
          );
        },
        child: _buildHomeworkChipWithReorderHandle(
          index: i,
          chipVisual: _buildHomeworkChipVisual(
            context,
            studentId,
            hw,
            flowNames[hw.flowId ?? ''] ?? '',
            assignmentCounts[hw.id] ?? 0,
            tick: tick,
          ),
        ),
      ),
    );
  }
  if (chips.isEmpty) return chips;
  final orderedIds = displayedHw.map((e) => e.id).toList();
  return <Widget>[
    ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: chips.length,
      buildDefaultDragHandles: false,
      proxyDecorator: (child, _, __) =>
          Material(color: Colors.transparent, child: child),
      onReorder: (oldIndex, newIndex) {
        if (newIndex > oldIndex) newIndex -= 1;
        final reorderedIds = List<String>.from(orderedIds);
        final movedId = reorderedIds.removeAt(oldIndex);
        reorderedIds.insert(newIndex, movedId);
        unawaited(
          HomeworkStore.instance.reorderActiveItems(
            studentId,
            reorderedIds,
          ),
        );
      },
      itemBuilder: (context, index) {
        return _buildHomeworkReorderableItem(
          itemKey: 'current_hw_${orderedIds[index]}',
          chip: chips[index],
          showBottomGap: index != chips.length - 1,
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
  final rangeRaw = _normalizePageRangeForPrint(selectedRange);
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

Widget _buildHomeworkChipVisual(
  BuildContext context,
  String studentId,
  HomeworkItem hw,
  String flowName,
  int assignmentCount, {
  required double tick,
  bool isReservation = false,
}) {
  final bool isRunning =
      HomeworkStore.instance.runningOf(studentId)?.id == hw.id;
  final int phase = hw.phase; // 1:대기,2:수행,3:제출,4:확인
  final bool visualRunning = isReservation ? false : isRunning;
  final int visualPhase = isReservation ? 1 : phase;
  final TextStyle titleStyle = const TextStyle(
    color: Color(0xFFEAF2F2),
    fontSize: 20,
    fontWeight: FontWeight.w700,
    height: 1.1,
  );
  final TextStyle metaStyle = const TextStyle(
    color: Color(0xFF9FB3B3),
    fontSize: 15,
    fontWeight: FontWeight.w600,
    height: 1.1,
  );
  final TextStyle statStyle = const TextStyle(
    color: Color(0xFF7F8C8C),
    fontSize: 12.5,
    fontWeight: FontWeight.w600,
    height: 1.1,
  );
  final TextStyle line4Style = const TextStyle(
    color: Color(0xFF748686),
    fontSize: 11.5,
    fontWeight: FontWeight.w600,
    height: 1.1,
  );
  const double leftPad = 24;
  const double rightPad = 24;
  const double chipHeight = _homeworkChipHeight;
  const double borderWMax = 3.0; // 상태와 무관하게 최대 테두리 두께 기준으로 폭 고정
  const double row1ShiftY = -3.0;
  const double lowerRowsShiftY = 1.5;
  const double row1ToRow2Gap = 8.0;
  const double row2ToRow3Gap = 7.0;
  const double row3ToRow4Gap = 6.0;

  final String displayFlowName = flowName.isNotEmpty ? flowName : '플로우 미지정';
  final String page = (hw.page ?? '').trim();
  final String count = hw.count != null ? hw.count.toString() : '';

  String stripUnitPrefix(String raw) {
    return raw.replaceFirst(RegExp(r'^\s*\d+\.\d+\.\(\d+\)\s+'), '').trim();
  }

  String extractBookName() {
    final contentRaw = (hw.content ?? '').trim();
    final match = RegExp(r'(?:^|\n)\s*교재:\s*([^\n]+)').firstMatch(contentRaw);
    final fromContent = match?.group(1)?.trim() ?? '';
    if (fromContent.isNotEmpty) return fromContent;
    final stripped = stripUnitPrefix((hw.title).trim());
    if (stripped.isEmpty) return '-';
    final idx = stripped.indexOf('·');
    if (idx == -1) {
      return (hw.type ?? '').trim() == '교재' ? stripped : '-';
    }
    final candidate = stripped.substring(0, idx).trim();
    return candidate.isEmpty ? '-' : candidate;
  }

  String extractCourseName() {
    final contentRaw = (hw.content ?? '').trim();
    final match = RegExp(r'(?:^|\n)\s*과정:\s*([^\n]+)').firstMatch(contentRaw);
    return match?.group(1)?.trim() ?? '';
  }

  final int homeworkCount = assignmentCount < 0 ? 0 : assignmentCount;
  final String titleText = (hw.title).trim();
  final String bookName = extractBookName();
  final String courseName = extractCourseName();
  final String line2Left = (bookName == '-' || bookName.isEmpty)
      ? (courseName.isEmpty ? '-' : courseName)
      : (courseName.isEmpty ? bookName : '$bookName · $courseName');
  final String line4Left =
      '페이지 p.${page.isNotEmpty ? page : '-'} · 문항 ${count.isNotEmpty ? count : '-'}문항';
  final int runningMs =
      hw.runStart != null ? DateTime.now().difference(hw.runStart!).inMilliseconds : 0;
  final int runningMinutes = runningMs <= 0 ? 0 : (runningMs ~/ 60000);
  final int totalMs = hw.accumulatedMs + runningMs;
  final String durationText = _formatDurationMs(totalMs);
  final String startedAtText =
      hw.firstStartedAt == null ? '-' : _formatShortTime(hw.firstStartedAt!);
  final String line3 = '시작 $startedAtText · 현재 ${runningMinutes}분 · 총 $durationText';
  final String line4Right = '검사 ${hw.checkCount}회 · 숙제 ${homeworkCount}회';
  final double fixedWidth = ClassContentScreen._studentColumnContentWidth;

  final double phase4Pulse = 0.5 + 0.5 * math.sin(2 * math.pi * tick);
  final Border border = (visualPhase == 3)
      ? Border.all(color: Colors.transparent, width: borderWMax)
      : (visualRunning
          ? Border.all(color: hw.color.withOpacity(0.9), width: borderWMax)
          : (visualPhase == 4
              ? Border.all(
                  color: Color.lerp(
                        Colors.white24,
                        hw.color.withOpacity(0.9),
                        phase4Pulse,
                      ) ??
                      Colors.white24,
                  width: borderWMax,
                )
              : Border.all(color: Colors.white24, width: borderWMax)));

  Widget chipInner = Container(
    height: chipHeight,
    padding: const EdgeInsets.fromLTRB(leftPad, 14, rightPad, 14),
    alignment: Alignment.centerLeft,
    decoration: BoxDecoration(
      // 홈 메뉴 페이지 배경톤과 동일하게 맞춤
      color: kDlgBg,
      borderRadius: BorderRadius.circular(12),
      border: border,
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.4),
          blurRadius: 10,
          offset: const Offset(0, 4),
        ),
        if (!visualRunning && visualPhase == 4)
          BoxShadow(
            color: hw.color.withOpacity(0.08 + 0.14 * phase4Pulse),
            blurRadius: 14,
            spreadRadius: 0.5,
          ),
      ],
    ),
    child: Stack(
      fit: StackFit.expand,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Transform.translate(
                offset: const Offset(0, row1ShiftY),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                      maxWidth: fixedWidth - leftPad - rightPad - 4),
                  child: Text(
                    line2Left,
                    style: titleStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(height: row1ToRow2Gap),
              Transform.translate(
                offset: const Offset(0, lowerRowsShiftY),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                      maxWidth: fixedWidth - leftPad - rightPad - 4),
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
                      const SizedBox(width: 10),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 180),
                        child: Text(
                          displayFlowName,
                          style: metaStyle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: row2ToRow3Gap),
              Transform.translate(
                offset: const Offset(0, lowerRowsShiftY),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                      maxWidth: fixedWidth - leftPad - rightPad - 4),
                  child: Text(
                    line3,
                    style: statStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(height: row3ToRow4Gap),
              Transform.translate(
                offset: const Offset(0, lowerRowsShiftY),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                      maxWidth: fixedWidth - leftPad - rightPad - 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          line4Left,
                          style: line4Style,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.left,
                        ),
                      ),
                      const SizedBox(width: 10),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 180),
                        child: Text(
                          line4Right,
                          style: line4Style,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        if (isReservation)
          Align(
            alignment: Alignment.bottomRight,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0x552A353A),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: const Color(0xFF425056)),
              ),
              child: const Text(
                '예약',
                style: TextStyle(
                  color: Color(0xFF8EA0A6),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  height: 1.0,
                ),
              ),
            ),
          ),
      ],
    ),
  );

  if (!visualRunning && visualPhase == 3) {
    chipInner = CustomPaint(
      foregroundPainter: _RotatingBorderPainter(
          baseColor: hw.color,
          tick: tick,
          strokeWidth: 3.0,
          cornerRadius: 12.0),
      child: chipInner,
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
                        opacity:
                            isRight ? (0.2 + 0.8 * progress).clamp(0.0, 1.0) : 0.0,
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
                          opacity:
                              isLeft ? (0.2 + 0.8 * progress).clamp(0.0, 1.0) : 0.0,
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
        padding: const EdgeInsets.fromLTRB(22, 0, 32, 0),
        decoration: BoxDecoration(
          color: Colors.transparent,
          border: showHorizontalDivider
              ? const Border(
                  bottom: BorderSide(color: kDlgBorder, width: 1),
                )
              : null,
        ),
        child: ValueListenableBuilder<int>(
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
            final bool isResting = hasAny && !hasRunning; // 모든 칩 정지 → 휴식 상태

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
            final arrivalText =
                arrivalTime != null ? _formatShortTime(arrivalTime!) : '--:--';
            final double nameHeight =
                (nameStyle.fontSize ?? 34) * (nameStyle.height ?? 1.0);

            return Row(
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
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.end,
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
            );
          },
        ),
      ),
    );
  }
}
