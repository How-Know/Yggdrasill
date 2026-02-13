import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import '../services/data_manager.dart';
import '../services/homework_store.dart';
import '../services/student_flow_store.dart';
import '../services/homework_assignment_store.dart';
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

/// 수업 내용 관리 6번째 페이지 (구조만 정의, 기능 미구현)
class ClassContentScreen extends StatefulWidget {
  const ClassContentScreen({super.key});

  static const double _attendingCardHeight = 120; // 과제칩 높이와 맞춤
  static const double _attendingCardWidth = 320; // 고정 폭으로 내부 우측 정렬 보장

  @override
  State<ClassContentScreen> createState() => _ClassContentScreenState();
}

class _ClassContentScreenState extends State<ClassContentScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _uiAnimController;
  late final Timer _clockTimer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _uiAnimController = AnimationController(duration: const Duration(milliseconds: 1800), vsync: this)..repeat();
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
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: RichText(
                            text: TextSpan(
                              children: [
                                TextSpan(
                                  text: _formatDateWithWeekdayAndTime(_now),
                                  style: const TextStyle(color: Colors.white, fontSize: 50, fontWeight: FontWeight.bold),
                                ),
                                const WidgetSpan(child: SizedBox(width: 30)),
                                TextSpan(
                                  text: '등원중: ' + list.length.toString() + '명',
                                  style: const TextStyle(color: Colors.white60, fontSize: 40, fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Divider(color: Color(0xFF223131), height: 24),
                  const SizedBox(height: 24),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      itemCount: list.length,
                      itemBuilder: (ctx, i) {
                        final s = list[i];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 24),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              _AttendingButton(
                                studentId: s.id,
                                name: s.name,
                                color: s.color,
                                arrivalTime: s.record.arrivalTime,
                                showHorizontalDivider: i != list.length - 1,
                              ),
                              const SizedBox(width: 12),
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 58,
                                    height: 58,
                                    child: IconButton(
                                      onPressed: () =>
                                          _onAddHomework(context, s.id),
                                      icon: const Icon(Icons.add_rounded),
                                      iconSize: 28,
                                      color: kDlgTextSub,
                                      splashRadius: 29,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  SizedBox(
                                    width: 58,
                                    height: 58,
                                    child: IconButton(
                                      onPressed: () => _onDepartFromHome(
                                        context,
                                        s,
                                      ),
                                      icon: const Icon(Icons.logout_rounded),
                                      iconSize: 26,
                                      color: const Color(0xFFE57373),
                                      splashRadius: 29,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(width: 12),
                              _buildHomeworkBadge(
                                context,
                                s.id,
                                onUpdated: () {
                                  if (!mounted) return;
                                  setState(() {
                                    _activeAssignmentsFutureByStudent[s.id] =
                                        HomeworkAssignmentStore.instance
                                            .loadActiveAssignments(s.id);
                                  });
                                },
                              ),
                              const SizedBox(width: 16),
                              Flexible(
                                fit: FlexFit.loose,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: AnimatedBuilder(
                                    animation: _uiAnimController,
                                    builder: (context, __) {
                                      final tick = _uiAnimController.value; // 0..1
                                      return _buildHomeworkChipsReactiveForStudent(
                                        s.id,
                                        tick,
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
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

  // 리얼타임 반영: 출석 레코드/세션 오버라이드 변경에 따라 즉시 갱신
  List<_AttendingStudent> _computeAttendingStudentsRealtime() {
    // DataManager의 attendanceRecordsNotifier와 sessionOverridesNotifier를 묶음 관찰
    // 여기서는 단순히 값을 소비만 하고, 상위에서 ValueListenableBuilder로 재빌드 유도
    final _ = DataManager.instance.attendanceRecordsNotifier.value;
    final __ = DataManager.instance.sessionOverridesNotifier.value;
    return _computeAttendingStudentsStatic();
  }

  List<_AttendingStudent> _computeAttendingStudentsStatic() {
    final List<_AttendingStudent> result = [];
    final now = DateTime.now();
    bool sameDay(DateTime a, DateTime b) => a.year==b.year && a.month==b.month && a.day==b.day;
    final students = DataManager.instance.students.map((e) => e.student).toList();
    // 슬라이드 시트와 동일 정렬: 등원 시간 asc
    final records = DataManager.instance.attendanceRecords
        .where((rec) => rec.isPresent && rec.arrivalTime != null && rec.departureTime == null && sameDay(rec.classDateTime, now))
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
    final blocks = DataManager.instance.studentTimeBlocks.where((b) => b.studentId == studentId && b.dayIndex == todayIdx).toList();
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
      if (score < bestScore) { bestScore = score; bestSet = b.setId; }
    }
    return bestSet;
  }

  Future<void> _onAddHomework(BuildContext context, String studentId) async {
    final enabledFlows = await ensureEnabledFlowsForHomework(context, studentId);
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
        final flowId = item['flowId'] as String?;
        final dynamic multiRaw = item['items'];
        final entries = <Map<String, dynamic>>[];
        if (multiRaw is List) {
          for (final e in multiRaw) {
            if (e is Map<String, dynamic>) entries.add(e);
          }
        } else {
          entries.add(item);
        }
        for (final entry in entries) {
          final countStr = (entry['count'] as String?)?.trim();
          HomeworkStore.instance.add(
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
        }
        final String msg =
            entries.length > 1 ? '과제를 ${entries.length}개 추가했어요.' : '과제를 추가했어요.';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
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
      final unselectedIds = allPendingItemIds
          .where((id) => !selectedIds.contains(id))
          .toList();
      if (unselectedIds.isNotEmpty) {
        HomeworkStore.instance.restoreItemsToWaiting(
          studentId,
          unselectedIds,
        );
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('현재 수업 세트를 찾지 못했습니다. 시간표를 확인하세요.')));
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
        title: const Text('기록 입력', style: TextStyle(color: Colors.white, fontSize: 20)),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            maxLines: 3,
            decoration: const InputDecoration(hintText: '간단히 적어주세요', hintStyle: TextStyle(color: Colors.white38), filled: true, fillColor: Color(0xFF2A2A2A), border: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2)))),
            style: const TextStyle(color: Colors.white),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('취소', style: TextStyle(color: Colors.white70))),
          ElevatedButton(onPressed: () => Navigator.of(ctx).pop(controller.text.trim()), style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1976D2), foregroundColor: Colors.white), child: const Text('추가')),
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
      title: const Text('기록 입력', style: TextStyle(color: Colors.white, fontSize: 20)),
      content: SizedBox(
        width: 520,
        child: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(hintText: '간단히 적어주세요', hintStyle: TextStyle(color: Colors.white38), filled: true, fillColor: Color(0xFF2A2A2A), border: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2)))),
          style: const TextStyle(color: Colors.white),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(null), child: const Text('취소', style: TextStyle(color: Colors.white70))),
        ElevatedButton(onPressed: () => Navigator.of(ctx).pop(controller.text.trim()), style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1976D2), foregroundColor: Colors.white), child: const Text('추가')),
      ],
    ),
  );
}

Future<void> _openClassTagDialogLikeSideSheet(BuildContext context, String setId, String studentId) async {
  final presets = await TagPresetService.instance.loadPresets();
  List<TagEvent> applied = List<TagEvent>.from(TagStore.instance.getEventsForSet(setId));
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          Future<void> handleTagPressed(String name, Color color, IconData icon) async {
            final now = DateTime.now();
            String? note;
            if (name == '기록') {
              note = await _openRecordNoteDialogGlobal(context);
              if (note == null || note.trim().isEmpty) return;
            }
            setLocal(() {
              applied.add(TagEvent(tagName: name, colorValue: color.value, iconCodePoint: icon.codePoint, timestamp: now, note: note?.trim()));
            });
            TagStore.instance.appendEvent(setId, studentId, TagEvent(tagName: name, colorValue: color.value, iconCodePoint: icon.codePoint, timestamp: now, note: note?.trim()));
          }

          return AlertDialog(
            backgroundColor: const Color(0xFF1F1F1F),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            title: const Text('수업 태그', style: TextStyle(color: Colors.white, fontSize: 20)),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
        child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('적용된 태그', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    if (applied.isEmpty)
                      const Text('아직 추가된 태그가 없습니다.', style: TextStyle(color: Colors.white38))
                    else
                      Column(
                        children: [
                          for (int i = applied.length - 1; i >= 0; i--) ...[
                            Builder(builder: (context) {
                              final e = applied[i];
                              return Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF22262C),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Color(e.colorValue).withOpacity(0.35), width: 1),
                                ),
                                child: Row(
                                  children: [
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(IconData(e.iconCodePoint, fontFamily: 'MaterialIcons'), color: Color(e.colorValue), size: 18),
                                        const SizedBox(width: 8),
                                        Text(e.tagName, style: const TextStyle(color: Colors.white70)),
                                        if (e.note != null && e.note!.isNotEmpty) ...[
                                          const SizedBox(width: 8),
                                          Text(e.note!, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                                        ],
                                      ],
                                    ),
                                    const Spacer(),
                                    Text(_formatDateTime(e.timestamp), style: const TextStyle(color: Colors.white54, fontSize: 12)),
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
                        const Text('추가 가능한 태그', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
                        const Spacer(),
                        IconButton(
                          tooltip: '태그 관리',
                          onPressed: () async {
                            await showDialog(context: context, builder: (_) => const TagPresetDialog());
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
                            onPressed: () => handleTagPressed(p.name, p.color, p.icon),
                            backgroundColor: const Color(0xFF2A2A2A),
                            label: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(p.icon, color: p.color, size: 18),
                                const SizedBox(width: 6),
                                Text(p.name, style: const TextStyle(color: Colors.white70)),
                              ],
                            ),
                            shape: StadiumBorder(side: BorderSide(color: p.color.withOpacity(0.6), width: 1.0)),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('닫기', style: TextStyle(color: Colors.white70))),
            ],
          );
        },
      );
    },
  );
}

  String _formatDateShort(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(dt.month)}.${two(dt.day)}';
  }

  String _formatDateRange(DateTime start, DateTime? end) {
    final left = _formatDateShort(start);
    if (end == null) return '$left ~ 미정';
    return '$left ~ ${_formatDateShort(end)}';
  }

  Widget _buildHomeworkBadge(
    BuildContext context,
    String studentId, {
    required VoidCallback onUpdated,
  }) {
    return ValueListenableBuilder<int>(
      valueListenable: HomeworkAssignmentStore.instance.revision,
      builder: (context, _rev, _) {
        _activeAssignmentsFutureByStudent[studentId] =
            HomeworkAssignmentStore.instance.loadActiveAssignments(studentId);
        _assignmentChecksFutureByStudent[studentId] =
            HomeworkAssignmentStore.instance.loadChecksForStudent(studentId);
        final assignmentsFuture = _activeAssignmentsFutureByStudent[studentId]!;
        final checksFuture = _assignmentChecksFutureByStudent[studentId]!;
        return FutureBuilder<List<HomeworkAssignmentDetail>>(
          future: assignmentsFuture,
          builder: (context, assignmentsSnapshot) {
            final list =
                assignmentsSnapshot.data ?? const <HomeworkAssignmentDetail>[];
            if (list.isEmpty) return const SizedBox.shrink();
            return FutureBuilder<Map<String, List<HomeworkAssignmentCheck>>>(
              future: checksFuture,
              builder: (context, checksSnapshot) {
                final checksByItem =
                    checksSnapshot.data ??
                        const <String, List<HomeworkAssignmentCheck>>{};
                bool sameDay(DateTime a, DateTime b) =>
                    a.year == b.year && a.month == b.month && a.day == b.day;
                final now = DateTime.now();
                final dueToday = list
                    .where((a) => a.dueDate != null && sameDay(a.dueDate!, now))
                    .toList();
                if (dueToday.isEmpty) return const SizedBox.shrink();
                bool hasCheck(HomeworkAssignmentDetail a) {
                  final checks = checksByItem[a.homeworkItemId] ?? const [];
                  return checks.any((c) => c.assignmentId == a.id);
                }

                final dueUnchecked =
                    dueToday.where((a) => !hasCheck(a)).toList();
                if (dueUnchecked.isEmpty) return const SizedBox.shrink();
                return InkWell(
                  onTap: () => showHomeworkAssignmentsDialog(
                    context,
                    studentId,
                    onUpdated: onUpdated,
                  ),
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    height: ClassContentScreen._attendingCardHeight,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(10),
                      border:
                          Border.all(color: const Color(0xFF2C3E3E), width: 2),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.assignment_outlined,
                          color: kDlgAccent,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '숙제 ${dueUnchecked.length}',
                          style: const TextStyle(
                            color: kDlgText,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
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
      },
    );
  }

Future<void> showHomeworkAssignmentsDialog(
  BuildContext context,
  String studentId, {
  VoidCallback? onUpdated,
  bool hideBadgeOnSave = true,
}) async {
    final assignments =
        await HomeworkAssignmentStore.instance.loadActiveAssignments(studentId);
    if (!context.mounted) return;
    if (assignments.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('현재 숙제가 없습니다.')),
      );
      return;
    }
    final counts =
        await HomeworkAssignmentStore.instance.loadAssignmentCounts(studentId);
    if (!context.mounted) return;
    final checksByItem =
        await HomeworkAssignmentStore.instance.loadChecksForStudent(studentId);
    if (!context.mounted) return;

    final Map<String, int> progressById = {
      for (final a in assignments) a.id: a.progress,
    };
    final Map<String, int> initialProgressById = {
      for (final a in assignments) a.id: a.progress,
    };
    final Map<String, String?> issueTypeById = {
      for (final a in assignments) a.id: a.issueType,
    };
    final Map<String, TextEditingController> noteControllers = {
      for (final a in assignments)
        a.id: TextEditingController(text: a.issueNote ?? ''),
    };
    final Map<String, TextEditingController> progressControllers = {
      for (final a in assignments)
        a.id: TextEditingController(text: a.progress.toString()),
    };
    final Map<String, bool> selectedById = {
      for (final a in assignments) a.id: true,
    };
    final Map<String, int> latestProgressByItem = {};
    for (final entry in checksByItem.entries) {
      final list = List<HomeworkAssignmentCheck>.from(entry.value);
      if (list.isEmpty) continue;
      list.sort((a, b) => a.checkedAt.compareTo(b.checkedAt));
      latestProgressByItem[entry.key] = list.last.progress;
    }
    final Map<String, int> minProgressById = {};
    for (final a in assignments) {
      final prev = latestProgressByItem[a.homeworkItemId] ?? 0;
      final min = math.max(prev, a.progress);
      minProgressById[a.id] = min;
      if ((progressById[a.id] ?? 0) < min) {
        progressById[a.id] = min;
        final controller = progressControllers[a.id];
        if (controller != null) {
          controller.text = min.toString();
          controller.selection =
              TextSelection.collapsed(offset: controller.text.length);
        }
      }
    }
    bool isClosing = false;

    Future<bool> applyAssignmentUpdates(
      List<Map<String, dynamic>> updates,
    ) async {
      bool ok = true;
      for (final u in updates) {
        final saved = await HomeworkAssignmentStore.instance.saveAssignmentCheck(
          assignmentId: u['id'] as String,
          studentId: studentId,
          homeworkItemId: u['homeworkItemId'] as String,
          progress: u['progress'] as int,
          issueType: u['issueType'] as String?,
          issueNote: u['issueNote'] as String?,
          markCompleted: (u['markCompleted'] as bool?) ?? false,
        );
        if (!saved) ok = false;
        if (saved) {
          final itemId = u['homeworkItemId'] as String;
          final bool abandon = (u['abandon'] as bool?) ?? false;
          if (abandon) {
            unawaited(HomeworkStore.instance.abandon(studentId, itemId, '분실'));
          } else {
            final item = HomeworkStore.instance.getById(studentId, itemId);
            if (item != null && item.phase < 3) {
              unawaited(HomeworkStore.instance.submit(studentId, itemId));
            }
          }
        }
      }
      if (!context.mounted) return ok;
      onUpdated?.call();
      return ok;
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            return AlertDialog(
              backgroundColor: kDlgBg,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Text('숙제 현황', style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900)),
              content: SizedBox(
                width: 720,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const YggDialogSectionHeader(icon: Icons.assignment_turned_in, title: '현재 숙제'),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 520),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: assignments.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (ctx, idx) {
                          final a = assignments[idx];
                          final progress = progressById[a.id] ?? 0;
                          final progressController = progressControllers[a.id]!;
                          final issueType = issueTypeById[a.id];
                          final bool selected = selectedById[a.id] ?? true;
                          final int minProgress = minProgressById[a.id] ?? 0;
                          final bool lockProgress =
                              !selected || issueType == 'lost';
                          final String type = (a.type ?? '').trim();
                          final String page = (a.page ?? '').trim();
                          final String count = a.count != null ? a.count.toString() : '';
                          final String meta = [
                            if (type.isNotEmpty) type,
                            if (page.isNotEmpty) 'p.$page',
                            if (count.isNotEmpty) '${count}문항',
                          ].join(' · ');
                          final int assignCount = counts[a.homeworkItemId] ?? 1;
                          final String reassignText =
                              assignCount > 1 ? '재숙제 ${assignCount}회' : '';
                          const double progressThumbRadius = 8;
                          return Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: kDlgPanelBg,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: kDlgBorder),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Checkbox(
                                      value: selected,
                                      onChanged: isClosing
                                          ? null
                                          : (v) {
                                              setState(() {
                                                selectedById[a.id] = v ?? false;
                                              });
                                            },
                                      activeColor: kDlgAccent,
                                      checkColor: Colors.white,
                                      side: const BorderSide(color: kDlgBorder),
                                      materialTapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                      visualDensity: VisualDensity.compact,
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        a.title.isEmpty ? '(제목 없음)' : a.title,
                                        style: const TextStyle(
                                          color: kDlgText,
                                          fontWeight: FontWeight.w800,
                                          fontSize: 19,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (reassignText.isNotEmpty)
                                      Text(
                                        reassignText,
                                        style: const TextStyle(
                                          color: kDlgTextSub,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                  ],
                                ),
                                if (meta.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    meta,
                                    style: const TextStyle(
                                      color: kDlgTextSub,
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 6),
                                Text(
                                  _formatDateRange(a.assignedAt, a.dueDate),
                                  style: const TextStyle(
                                    color: kDlgTextSub,
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Opacity(
                                  opacity: lockProgress ? 0.4 : 1,
                                  child: IgnorePointer(
                                    ignoring: lockProgress,
                                    child: Row(
                                      children: [
                                        const Text('수행률',
                                            style: TextStyle(color: kDlgTextSub)),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              SliderTheme(
                                                data: SliderTheme.of(ctx).copyWith(
                                                  trackHeight: 4,
                                                  activeTrackColor: kDlgAccent,
                                                  inactiveTrackColor: kDlgBorder,
                                                  thumbColor: kDlgAccent,
                                                  overlayColor:
                                                      kDlgAccent.withOpacity(0.12),
                                                  thumbShape: RoundSliderThumbShape(
                                                    enabledThumbRadius:
                                                        progressThumbRadius,
                                                  ),
                                                  tickMarkShape:
                                                      const RoundSliderTickMarkShape(
                                                    tickMarkRadius: 0,
                                                  ),
                                                  activeTickMarkColor: kDlgAccent,
                                                  inactiveTickMarkColor: kDlgBorder,
                                                  overlayShape:
                                                      const RoundSliderOverlayShape(
                                                    overlayRadius: 14,
                                                  ),
                                                  valueIndicatorColor: kDlgAccent,
                                                  valueIndicatorTextStyle:
                                                      const TextStyle(
                                                    color: Colors.white,
                                                  ),
                                                ),
                                                child: Slider(
                                                  value: progress.toDouble(),
                                                  min: 0,
                                                  max: 150,
                                                  divisions: 15,
                                                  label: '$progress%',
                                                  onChanged: (v) {
                                                    if (isClosing) return;
                                                    final next = ((v / 10).round() * 10)
                                                        .clamp(minProgress, 150);
                                                    setState(() {
                                                      progressById[a.id] = next;
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
                                              const SizedBox(height: 4),
                                              Padding(
                                                padding: EdgeInsets.symmetric(
                                                    horizontal: progressThumbRadius),
                                                child: SizedBox(
                                                  height: 22,
                                                  child: Stack(
                                                    clipBehavior: Clip.none,
                                                    children: [
                                                      for (final v in const [
                                                        0,
                                                        50,
                                                        100,
                                                        150
                                                      ])
                                                        Align(
                                                          alignment: Alignment(
                                                              -1 + (v / 150) * 2,
                                                              -1),
                                                          child: Column(
                                                            mainAxisSize:
                                                                MainAxisSize.min,
                                                            children: [
                                                              Container(
                                                                width: 1,
                                                                height: 6,
                                                                color: kDlgBorder,
                                                              ),
                                                              const SizedBox(height: 2),
                                                              Text(
                                                                '$v%',
                                                                style: const TextStyle(
                                                                  color: kDlgTextSub,
                                                                  fontSize: 10,
                                                                  fontWeight:
                                                                      FontWeight.w600,
                                                                ),
                                                              ),
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
                                        const SizedBox(width: 10),
                                        SizedBox(
                                          width: 64,
                                          child: TextField(
                                            controller: progressController,
                                            enabled: !lockProgress,
                                            keyboardType: TextInputType.number,
                                            inputFormatters: [
                                              FilteringTextInputFormatter.digitsOnly
                                            ],
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                              color: kDlgText,
                                              fontSize: 14,
                                              fontWeight: FontWeight.w800,
                                            ),
                                            decoration: InputDecoration(
                                              suffixText: '%',
                                              suffixStyle:
                                                  const TextStyle(color: kDlgTextSub),
                                              filled: true,
                                              fillColor: kDlgFieldBg,
                                              enabledBorder: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                borderSide: const BorderSide(
                                                  color: kDlgBorder,
                                                ),
                                              ),
                                              focusedBorder: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                borderSide: const BorderSide(
                                                  color: kDlgAccent,
                                                  width: 1.4,
                                                ),
                                              ),
                                              contentPadding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 6,
                                                vertical: 8,
                                              ),
                                            ),
                                            onChanged: (v) {
                                              if (isClosing) return;
                                              final parsed = int.tryParse(v);
                                              if (parsed == null) return;
                                              final safe =
                                                  parsed.clamp(minProgress, 150);
                                              setState(() {
                                                progressById[a.id] = safe;
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
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Opacity(
                                  opacity: selected ? 1 : 0.4,
                                  child: IgnorePointer(
                                    ignoring: !selected,
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Wrap(
                                          spacing: 8,
                                          children: [
                                            YggDialogFilterChip(
                                              label: '분실',
                                              selected: issueType == 'lost',
                                              onSelected: (v) {
                                                if (isClosing) return;
                                                setState(() {
                                                  issueTypeById[a.id] =
                                                      v ? 'lost' : null;
                                                  if (issueTypeById[a.id] != 'other') {
                                                    noteControllers[a.id]?.text = '';
                                                  }
                                                });
                                              },
                                            ),
                                            YggDialogFilterChip(
                                              label: '잊음',
                                              selected: issueType == 'forgot',
                                              onSelected: (v) {
                                                if (isClosing) return;
                                                setState(() {
                                                  issueTypeById[a.id] =
                                                      v ? 'forgot' : null;
                                                  if (issueTypeById[a.id] != 'other') {
                                                    noteControllers[a.id]?.text = '';
                                                  }
                                                });
                                              },
                                            ),
                                            YggDialogFilterChip(
                                              label: '기타',
                                              selected: issueType == 'other',
                                              onSelected: (v) {
                                                if (isClosing) return;
                                                setState(() {
                                                  issueTypeById[a.id] =
                                                      v ? 'other' : null;
                                                  if (!v) {
                                                    noteControllers[a.id]?.text = '';
                                                  }
                                                });
                                              },
                                            ),
                                          ],
                                        ),
                                        if (issueType == 'other') ...[
                                          const SizedBox(height: 8),
                                          TextField(
                                            controller: noteControllers[a.id],
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
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                                borderSide: const BorderSide(
                                                  color: kDlgBorder,
                                                ),
                                              ),
                                              focusedBorder: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                                borderSide: const BorderSide(
                                                  color: kDlgAccent,
                                                  width: 1.4,
                                                ),
                                              ),
                                              contentPadding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 12,
                                                vertical: 10,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
                  child: const Text('닫기'),
                ),
                FilledButton(
                  onPressed: () async {
                    final updates = <Map<String, dynamic>>[];
                    for (final a in assignments) {
                      if (!(selectedById[a.id] ?? true)) {
                        continue;
                      }
                      final raw = progressControllers[a.id]?.text.trim() ?? '';
                      final parsed = int.tryParse(raw);
                      final progress =
                          (parsed ?? (progressById[a.id] ?? 0)).clamp(0, 150);
                      final issueType = issueTypeById[a.id];
                      final issueNote =
                          (issueType == 'other')
                              ? noteControllers[a.id]?.text.trim()
                              : null;
                      updates.add({
                        'id': a.id,
                        'homeworkItemId': a.homeworkItemId,
                        'progress': progress,
                        'issueType': issueType,
                        'issueNote': issueNote,
                        'abandon': issueType == 'lost',
                        'markCompleted': true,
                      });
                    }
                    isClosing = true;
                    FocusManager.instance.primaryFocus?.unfocus();
                    await Future<void>.delayed(const Duration(milliseconds: 1));
                    if (!ctx.mounted) return;
                    Navigator.of(ctx).pop();
                    unawaited(applyAssignmentUpdates(updates).then((ok) {
                      if (!context.mounted) return;
                      if (!ok) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('숙제 점검 저장에 실패했습니다. 권한/네트워크를 확인해 주세요.'),
                          ),
                        );
                      }
                    }));
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
    for (final c in noteControllers.values) {
      c.dispose();
    }
    for (final c in progressControllers.values) {
      c.dispose();
    }
  }

String _formatDateTime(DateTime dt) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(dt.month)}.${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
}

String _formatDateWithWeekdayAndTime(DateTime dt) {
  String two(int v) => v.toString().padLeft(2, '0');
  const week = ['월', '화', '수', '목', '금', '토', '일'];
  return two(dt.month) + '.' + two(dt.day) + ' (' + week[dt.weekday - 1] + ') ' + two(dt.hour) + '시 ' + two(dt.minute) + '분';
}

final Map<String, Map<String, String>> _flowNameCacheByStudent = {};
final Set<String> _flowLoadingStudentIds = <String>{};
final Map<String, int> _assignmentRevisionByStudent = {};
final Map<String, Future<Map<String, int>>> _assignmentCountsFutureByStudent = {};
final Map<String, Future<Set<String>>> _activeAssignedItemIdsFutureByStudent = {};
final Map<String, Future<List<HomeworkAssignmentDetail>>> _activeAssignmentsFutureByStudent = {};
final Map<String, Future<Map<String, List<HomeworkAssignmentCheck>>>>
    _assignmentChecksFutureByStudent = {};

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
        _flowNameCacheByStudent[studentId] = {for (final f in flows) f.id: f.name};
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

Future<void> _showHomeworkChipDetailDialog(
  BuildContext context,
  String studentId,
  HomeworkItem hw,
  String flowName,
  int assignmentCount,
) async {
  final bool isRunning = HomeworkStore.instance.runningOf(studentId)?.id == hw.id;
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
    count: (countStr == null || countStr.isEmpty) ? null : int.tryParse(countStr),
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

const double _homeworkChipHeight = 120.0;
const double _homeworkChipMaxSlide = _homeworkChipHeight * 0.5;
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
                HomeworkAssignmentStore.instance.loadAssignmentCounts(studentId);
            _activeAssignedItemIdsFutureByStudent[studentId] =
                HomeworkAssignmentStore.instance.loadActiveAssignedItemIds(studentId);
          }
          final assignmentCountsFuture =
              _assignmentCountsFutureByStudent.putIfAbsent(
                studentId,
                () => HomeworkAssignmentStore.instance.loadAssignmentCounts(studentId),
              );
          final activeAssignedFuture =
              _activeAssignedItemIdsFutureByStudent.putIfAbsent(
                studentId,
                () => HomeworkAssignmentStore.instance
                    .loadActiveAssignedItemIds(studentId),
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
                      final rowChildren = <Widget>[];
                      for (final chip in chips) {
                        if (rowChildren.isNotEmpty) {
                          rowChildren.add(const SizedBox(width: 20));
                        }
                        rowChildren.add(chip);
                      }
                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        physics: const BouncingScrollPhysics(),
                        child: Row(children: rowChildren),
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

List<Widget> _buildHomeworkChipsOnceForStudent(
  BuildContext context,
  String studentId,
  double tick,
  Map<String, String> flowNames,
  Map<String, int> assignmentCounts,
  Set<String> activeAssignedItemIds,
) {
  final List<Widget> chips = [];
  final List<HomeworkItem> hwList = HomeworkStore.instance.items(studentId)
      .where((e) => e.status != HomeworkStatus.completed)
      .where((e) => !activeAssignedItemIds.contains(e.id))
      .toList();
  // 정렬: 수행(phase=2, runStart!=null), 대기(1), 확인(4), 제출(3). 같은 그룹 내 runStart/타임스탬프 asc
  int group(HomeworkItem e) {
    final running = e.runStart != null;
    if (running) return 0; // 수행
    switch (e.phase) {
      case 1: return 1; // 대기
      case 4: return 2; // 확인
      case 3: return 3; // 제출
      default: return 4;
    }
  }
  DateTime? ts(HomeworkItem e) {
    if (e.runStart != null) return e.runStart;
    if (e.waitingAt != null) return e.waitingAt;
    if (e.confirmedAt != null) return e.confirmedAt;
    if (e.submittedAt != null) return e.submittedAt;
    return e.firstStartedAt;
  }
  hwList.sort((a, b) {
    final ga = group(a);
    final gb = group(b);
    if (ga != gb) return ga - gb;
    final ta = ts(a);
    final tb = ts(b);
    if (ta == null && tb == null) return 0;
    if (ta == null) return 1;
    if (tb == null) return -1;
    return ta.compareTo(tb);
  });

  for (final hw in hwList.take(12)) {
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
            : (isSubmitted
                ? const Color(0xFF4CAF50)
                : const Color(0xFF9FB3B3)),
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
            // 아래로 슬라이드한 완료 의도: 다음 대기 진입 시 완료 처리
            HomeworkStore.instance.markAutoCompleteOnNextWaiting(hw.id);
            unawaited(HomeworkStore.instance.confirm(studentId, hw.id));
          }
        },
        onSlideUp: () async {
          final choice = await showDialog<String>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: kDlgBg,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Text('과제 취소', style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900)),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    YggDialogSectionHeader(icon: Icons.cancel_outlined, title: '처리 방식'),
                    Text('완전 취소 또는 포기를 선택하세요.', style: TextStyle(color: kDlgTextSub)),
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
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  title: const Text('포기 사유', style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900)),
                  content: SizedBox(
                    width: 420,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const YggDialogSectionHeader(icon: Icons.edit_note, title: '사유 입력'),
                        TextField(
                          controller: controller,
                          minLines: 2,
                          maxLines: 4,
                          style: const TextStyle(color: kDlgText),
                          decoration: InputDecoration(
                            hintText: '포기 사유를 입력하세요',
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
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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
              unawaited(HomeworkStore.instance.abandon(studentId, hw.id, reason));
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
        child: _buildHomeworkChipVisual(
          context,
          studentId,
          hw,
          flowNames[hw.flowId ?? ''] ?? '',
          assignmentCounts[hw.id] ?? 0,
          tick: tick,
        ),
      ),
    );
  }
  return chips;
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
  final target = path.trim();
  if (target.isEmpty) return;
  try {
    if (Platform.isWindows) {
      final q = "'${target.replaceAll("'", "''")}'";
      await Process.start(
        'powershell',
        ['-NoProfile', '-Command', 'Start-Process -FilePath $q -Verb Print'],
        runInShell: true,
      );
      return;
    }
  } catch (_) {
    // fallthrough
  }
  await OpenFilex.open(target);
}

Future<_ResolvedHomeworkPdfLinks> _resolveHomeworkPdfLinks(HomeworkItem hw) async {
  String bookId = (hw.bookId ?? '').trim();
  String gradeLabel = (hw.gradeLabel ?? '').trim();
  final flowId = (hw.flowId ?? '').trim();

  if ((bookId.isEmpty || gradeLabel.isEmpty) && flowId.isNotEmpty) {
    try {
      final rows = await DataManager.instance.loadFlowTextbookLinks(flowId);
      if (rows.isNotEmpty) {
        Map<String, dynamic>? matched;
        for (final row in rows) {
          final rowBookId = '${row['book_id'] ?? ''}'.trim();
          final rowGrade = '${row['grade_label'] ?? ''}'.trim();
          final bool bookMatches = bookId.isNotEmpty && rowBookId == bookId;
          final bool gradeMatches = gradeLabel.isNotEmpty && rowGrade == gradeLabel;
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

Future<void> _confirmHomeworkIfSubmitted(String studentId, String hwId) async {
  final latest = HomeworkStore.instance.getById(studentId, hwId);
  if (latest == null || latest.phase != 3) return;
  await HomeworkStore.instance.confirm(studentId, hwId);
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                        style: TextStyle(color: kDlgText, fontWeight: FontWeight.w700),
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
                          borderSide: const BorderSide(color: kDlgAccent, width: 1.4),
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

Future<void> _handleWaitingChipLongPressPrint({
  required BuildContext context,
  required HomeworkItem hw,
}) async {
  if (hw.phase != 1) return;
  final resolved = await _resolveHomeworkPdfLinks(hw);
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
  if (rangeRaw.isNotEmpty) {
    if (!bodyPath.toLowerCase().endsWith('.pdf')) {
      _showHomeworkChipSnackBar(context, '페이지 범위 인쇄는 PDF에서만 지원합니다.');
      return;
    }
    final out = await _buildPdfForPrintRange(
      inputPath: bodyPath,
      pageRange: rangeRaw,
    );
    if (!context.mounted) return;
    if (out == null || out.isEmpty) {
      _showHomeworkChipSnackBar(context, '페이지 범위를 확인하세요. (예: 10-15, 20)');
      return;
    }
    pathToPrint = out;
    _scheduleTempDelete(pathToPrint);
  }

  await _openPrintDialogForPath(pathToPrint);
}

Future<void> _handleSubmittedChipTapWithAnswerViewer({
  required BuildContext context,
  required String studentId,
  required HomeworkItem hw,
}) async {
  final resolved = await _resolveHomeworkPdfLinks(hw);
  if (!context.mounted) return;

  final answerRaw = resolved.answerPathRaw;
  if (answerRaw.isEmpty) {
    await _confirmHomeworkIfSubmitted(studentId, hw.id);
    return;
  }
  final answerIsUrl = _isWebUrl(answerRaw);
  final answerPath = answerIsUrl ? answerRaw.trim() : _toLocalFilePath(answerRaw);
  if (answerPath.isEmpty ||
      (!answerIsUrl && !answerPath.toLowerCase().endsWith('.pdf'))) {
    _showHomeworkChipSnackBar(context, '답지 PDF 경로를 확인할 수 없어 바로 확인 처리합니다.');
    await _confirmHomeworkIfSubmitted(studentId, hw.id);
    return;
  }
  if (!answerIsUrl && !await File(answerPath).exists()) {
    if (!context.mounted) return;
    _showHomeworkChipSnackBar(context, '답지 PDF 파일을 찾을 수 없어 바로 확인 처리합니다.');
    await _confirmHomeworkIfSubmitted(studentId, hw.id);
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

  final confirmed = await openHomeworkAnswerViewerPage(
    context,
    filePath: answerPath,
    title: hw.title.trim().isEmpty ? '답지 확인' : hw.title.trim(),
    solutionFilePath: solutionPath,
    cacheKey: 'student:$studentId|answer:$answerPath',
    enableConfirm: true,
  );
  if (!context.mounted) return;
  if (confirmed == true) {
    await _confirmHomeworkIfSubmitted(studentId, hw.id);
  }
}

Widget _buildHomeworkChipVisual(
  BuildContext context,
  String studentId,
  HomeworkItem hw,
  String flowName,
  int assignmentCount, {
  required double tick,
}) {
  final bool isRunning = HomeworkStore.instance.runningOf(studentId)?.id == hw.id;
  final int phase = hw.phase; // 1:대기,2:수행,3:제출,4:확인
  final TextStyle titleStyle = const TextStyle(
    color: Color(0xFFEAF2F2),
    fontSize: 19,
    fontWeight: FontWeight.w700,
    height: 1.1,
  );
  final TextStyle flowStyle = const TextStyle(
    color: Color(0xFF9FB3B3),
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.1,
  );
  final TextStyle metaStyle = const TextStyle(
    color: Color(0xFF9FB3B3),
    fontSize: 14,
    fontWeight: FontWeight.w600,
    height: 1.1,
  );
  final TextStyle statStyle = const TextStyle(
    color: Color(0xFF7F8C8C),
    fontSize: 12,
    fontWeight: FontWeight.w600,
    height: 1.1,
  );
  const double leftPad = 24;
  const double rightPad = 24;
  const double chipHeight = _homeworkChipHeight;
  const double borderWMax = 3.0; // 상태와 무관하게 최대 테두리 두께 기준으로 폭 고정

  final String displayFlowName = flowName.isNotEmpty ? flowName : '플로우 미지정';
  final String page = (hw.page ?? '').trim();
  final String count = hw.count != null ? hw.count.toString() : '';

  String stripUnitPrefix(String raw) {
    return raw.replaceFirst(RegExp(r'^\s*\d+\.\d+\.\(\d+\)\s+'), '').trim();
  }

  String extractBookName() {
    final contentRaw = (hw.content ?? '').trim();
    final match = RegExp(r'(?:^|\n)\s*교재:\s*([^\n]+)')
        .firstMatch(contentRaw);
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

  final String homeworkText = assignmentCount > 0 ? 'H$assignmentCount' : 'H0';
  final String titleText = (hw.title).trim();
  final String bookName = extractBookName();
  final String courseName = extractCourseName();
  final String line2Left = (bookName == '-' || bookName.isEmpty)
      ? (courseName.isEmpty ? '-' : courseName)
      : (courseName.isEmpty ? bookName : '$bookName · $courseName');
  final String line2Right =
      'p.${page.isNotEmpty ? page : '-'} · ${count.isNotEmpty ? count : '-'}문항';
  final int runningMs = hw.runStart != null
      ? DateTime.now().difference(hw.runStart!).inMilliseconds
      : 0;
  final int totalMs = hw.accumulatedMs + runningMs;
  final String durationText = _formatDurationMs(totalMs);
  final String line3 = '검사 ${hw.checkCount}회 · $homeworkText · 진행 $durationText';
  // 폭 고정: 가장 긴 라인 기준으로 계산
  final titlePainter = TextPainter(
    text: TextSpan(text: titleText, style: titleStyle),
    maxLines: 1,
    textDirection: TextDirection.ltr,
    textScaleFactor: MediaQuery.of(context).textScaleFactor,
  )..layout(minWidth: 0, maxWidth: double.infinity);
  final flowPainter = TextPainter(
    text: TextSpan(text: displayFlowName, style: flowStyle),
    maxLines: 1,
    textDirection: TextDirection.ltr,
    textScaleFactor: MediaQuery.of(context).textScaleFactor,
  )..layout(minWidth: 0, maxWidth: double.infinity);
  final painter2Left = TextPainter(
    text: TextSpan(text: line2Left, style: metaStyle),
    maxLines: 1,
    textDirection: TextDirection.ltr,
    textScaleFactor: MediaQuery.of(context).textScaleFactor,
  )..layout(minWidth: 0, maxWidth: double.infinity);
  final painter2Right = TextPainter(
    text: TextSpan(text: line2Right, style: metaStyle),
    maxLines: 1,
    textDirection: TextDirection.ltr,
    textScaleFactor: MediaQuery.of(context).textScaleFactor,
  )..layout(minWidth: 0, maxWidth: double.infinity);
  final painter3 = TextPainter(
    text: TextSpan(text: line3, style: statStyle),
    maxLines: 1,
    textDirection: TextDirection.ltr,
    textScaleFactor: MediaQuery.of(context).textScaleFactor,
  )..layout(minWidth: 0, maxWidth: double.infinity);
  final double rowWidth = titlePainter.width + 8 + flowPainter.width;
  final double line2Width = painter2Left.width + 10 + painter2Right.width;
  final double maxLineWidth =
      math.max(rowWidth, math.max(line2Width, painter3.width));
  // 여유폭 14px, 최소폭 300px
  final double fixedWidth = (maxLineWidth + leftPad + rightPad + borderWMax * 2 + 14.0).clamp(300.0, 760.0);

  final double phase4Pulse = 0.5 + 0.5 * math.sin(2 * math.pi * tick);
  final Border border = (phase == 3)
      ? Border.all(color: Colors.transparent, width: borderWMax)
      : (isRunning
          ? Border.all(color: hw.color.withOpacity(0.9), width: borderWMax)
          : (phase == 4
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
        if (!isRunning && phase == 4)
          BoxShadow(
            color: hw.color.withOpacity(0.08 + 0.14 * phase4Pulse),
            blurRadius: 14,
            spreadRadius: 0.5,
          ),
      ],
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                titleText,
                style: titleStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                displayFlowName,
                style: flowStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ConstrainedBox(
          constraints:
              BoxConstraints(maxWidth: fixedWidth - leftPad - rightPad - 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  line2Left,
                  style: metaStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                line2Right,
                style: metaStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
              ),
            ],
          ),
        ),
        const SizedBox(height: 9),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: fixedWidth - leftPad - rightPad - 4),
          child: Text(
            line3,
            style: statStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );

  if (!isRunning && phase == 3) {
    chipInner = CustomPaint(
      foregroundPainter: _RotatingBorderPainter(baseColor: hw.color, tick: tick, strokeWidth: 3.0, cornerRadius: 12.0),
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
  _RotatingBorderPainter({required this.baseColor, required this.tick, this.strokeWidth = 2.0, this.cornerRadius = 8.0});
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectXY(rect.deflate(strokeWidth / 2), cornerRadius, cornerRadius);
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
    return oldDelegate.tick != tick || oldDelegate.baseColor != baseColor || oldDelegate.strokeWidth != strokeWidth || oldDelegate.cornerRadius != cornerRadius;
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
    final vy = details.primaryVelocity ?? 0.0;
    final double absOffset = _offset.abs();
    final bool isDown = _offset > 0;
    final bool isUp = _offset < 0;
    final bool trigger =
        absOffset >= widget.maxSlide * 0.55 || vy.abs() > 800.0;

    if (trigger) {
      setState(() {
        _offset = 0.0;
        _dragging = false;
      });
      if (isDown && widget.canSlideDown) {
        widget.onSlideDown();
      } else if (isUp && widget.canSlideUp) {
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
    final double progress =
        (_offset.abs() / widget.maxSlide).clamp(0.0, 1.0);
    final bool isDown = _offset > 0;
    final bool isUp = _offset < 0;
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
              color: const Color(0xFF101315),
              child: Stack(
                children: [
                  if (widget.downLabel.isNotEmpty)
                    Align(
                      alignment: const Alignment(0, -0.75),
                      child: Opacity(
                        opacity: isDown ? progress : 0.0,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.arrow_downward_rounded,
                                color: widget.downColor, size: 24),
                            const SizedBox(width: 6),
                            Text(
                              widget.downLabel,
                              style: labelStyle.copyWith(
                                color: widget.downColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  Align(
                    alignment: const Alignment(0, 0.75),
                    child: Opacity(
                      opacity: isUp ? progress : 0.0,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.arrow_upward_rounded,
                              color: widget.upColor, size: 24),
                          const SizedBox(width: 6),
                          Text(
                            widget.upLabel,
                            style: labelStyle.copyWith(
                              color: widget.upColor,
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
        AnimatedContainer(
          duration: _dragging
              ? Duration.zero
              : const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          transform: Matrix4.translationValues(0, _offset, 0),
          child: GestureDetector(
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            onDoubleTap: widget.onDoubleTap,
            onVerticalDragUpdate: (details) {
              final delta = details.delta.dy;
              if (delta > 0) {
                // 내려가는 방향: 슬라이드 불가여도 위에서 내려오는 복귀는 허용
                if (!widget.canSlideDown && _offset >= 0) return;
              } else if (delta < 0) {
                // 올라가는 방향: 슬라이드 불가여도 아래에서 복귀는 허용
                if (!widget.canSlideUp && _offset <= 0) return;
              }
              _updateOffset(delta);
            },
            onVerticalDragEnd: _endDrag,
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
  const _AttendingButton({
    required this.studentId,
    required this.name,
    required this.color,
    required this.arrivalTime,
    required this.showHorizontalDivider,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {},
      child: Container(
        width: ClassContentScreen._attendingCardWidth,
        height: ClassContentScreen._attendingCardHeight,
        margin: const EdgeInsets.only(left: 24),
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

