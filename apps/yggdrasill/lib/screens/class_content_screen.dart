import 'package:flutter/material.dart';
import '../services/data_manager.dart';
import 'dart:async';
import 'dart:math' as math;
import '../services/homework_store.dart';
import '../services/student_flow_store.dart';
import '../services/homework_assignment_store.dart';
import '../models/attendance_record.dart';
import 'learning/homework_quick_add_proxy_dialog.dart';
import '../services/tag_preset_service.dart';
import '../services/tag_store.dart';
import 'learning/tag_preset_dialog.dart';
import 'package:uuid/uuid.dart';
import '../models/memo.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';
import '../widgets/flow_setup_dialog.dart';

/// 수업 내용 관리 6번째 페이지 (구조만 정의, 기능 미구현)
class ClassContentScreen extends StatefulWidget {
  const ClassContentScreen({super.key});

  static const double _attendingCardHeight = 100; // 64 * 1.2
  static const double _attendingCardWidth = 330; // 고정 폭으로 내부 우측 정렬 보장

  @override
  State<ClassContentScreen> createState() => _ClassContentScreenState();
}

class _ClassContentScreenState extends State<ClassContentScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _uiAnimController;
  final List<_NoteEntry> _notes = <_NoteEntry>[]; // ephemeral, not persisted
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
                              _AttendingButton(studentId: s.id, name: s.name, color: s.color, onAddTag: () => _onAddTag(context, s.id), onAddHomework: () => _onAddHomework(context, s.id)),
                              const SizedBox(width: 24),
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
                                        (text) { if (!mounted) return; setState(() { _notes.add(_NoteEntry(text)); }); },
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
        // Floating completion notes (ephemeral)
        Positioned(
          right: 16,
          top: 16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: _notes.map((n) => _buildNote(n)).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildNote(_NoteEntry n) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F1F),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF1976D2), width: 1.5), // blue border
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.25), blurRadius: 8, offset: const Offset(0, 4))],
      ),
      constraints: const BoxConstraints(maxWidth: 420),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(child: Text(n.text, style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.2)) ),
          const SizedBox(width: 8),
          InkWell(
            onTap: () { setState(() { _notes.remove(n); }); },
            borderRadius: BorderRadius.circular(999),
            child: const Icon(Icons.close, color: Colors.white60, size: 18),
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
      // 색상은 슬라이드 시트의 "출석" 박스 느낌을 살려 파랑 계열 고정(개별 과목 색상 추후 반영 가능)
      result.add(_AttendingStudent(id: rec.studentId, name: name, color: const Color(0xFF0F467D)));
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
        final countStr = (item['count'] as String?)?.trim();
        HomeworkStore.instance.add(
          item['studentId'],
          title: item['title'],
          body: item['body'],
          color: item['color'],
          flowId: item['flowId'] as String?,
          type: (item['type'] as String?)?.trim(),
          page: (item['page'] as String?)?.trim(),
          count: (countStr == null || countStr.isEmpty)
              ? null
              : int.tryParse(countStr),
          content: (item['content'] as String?)?.trim(),
        );
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('과제를 추가했어요.')));
      }
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
final Map<String, Future<Map<String, int>>> _assignmentCountsFutureByStudent = {};

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

void _appendCompletionMemo(String studentId, HomeworkItem item) {
  final accMs = item.accumulatedMs;
  final d = Duration(milliseconds: accMs);
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final timeText = h > 0 ? ('$h시간 $m분') : ('$m분');
  final studentName = DataManager.instance.students
      .firstWhere((s) => s.student.id == studentId)
      .student
      .name;
  final title = (item.title).trim();
  final String page = (item.page ?? '').trim();
  final String count = item.count != null ? item.count.toString() : '';
  final String content = (item.content ?? '').trim();
  final parts = <String>[];
  if (page.isNotEmpty) parts.add('p.$page');
  if (count.isNotEmpty) parts.add('${count}문항');
  if (content.isNotEmpty) parts.add(content);
  final detail = parts.join(' ');
  final original =
      '$studentName 학생 ${title.isEmpty ? '' : title + ' '}완료, ${[if (detail.isNotEmpty) detail, timeText].join(' ')}'
          .trim();
  final now = DateTime.now();
  final memo = Memo(
    id: const Uuid().v4(),
    original: original,
    summary: original,
    categoryKey: MemoCategory.inquiry,
    scheduledAt: now.add(const Duration(hours: 24)),
    dismissed: false,
    createdAt: now,
    updatedAt: now,
  );
  unawaited(DataManager.instance.addMemo(memo));
}

// ------------------------
// 오른쪽 패널: 슬라이드시트와 동일한 과제 칩 렌더링
// ------------------------
Widget _buildHomeworkChipsReactiveForStudent(String studentId, double tick, void Function(String text) onComplete) {
  return ValueListenableBuilder<int>(
    valueListenable: StudentFlowStore.instance.revision,
    builder: (context, __, ___) {
      final flowNames = _getFlowNamesForStudent(studentId);
      final assignmentCountsFuture = _assignmentCountsFutureByStudent.putIfAbsent(
        studentId,
        () => HomeworkAssignmentStore.instance.loadAssignmentCounts(studentId),
      );
      return FutureBuilder<Map<String, int>>(
        future: assignmentCountsFuture,
        builder: (context, snapshot) {
          final assignmentCounts = snapshot.data ?? const <String, int>{};
          return ValueListenableBuilder<int>(
            valueListenable: HomeworkStore.instance.revision,
            builder: (context, _rev, _) {
              final chips = _buildHomeworkChipsOnceForStudent(
                context,
                studentId,
                tick,
                onComplete,
                flowNames,
                assignmentCounts,
              );
              final rowChildren = <Widget>[];
              for (final chip in chips) {
                if (rowChildren.isNotEmpty) {
                  rowChildren.add(const SizedBox(width: 24));
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
}

List<Widget> _buildHomeworkChipsOnceForStudent(
  BuildContext context,
  String studentId,
  double tick,
  void Function(String text) onComplete,
  Map<String, String> flowNames,
  Map<String, int> assignmentCounts,
) {
  final List<Widget> chips = [];
  final List<HomeworkItem> hwList = HomeworkStore.instance.items(studentId)
      .where((e) => e.status != HomeworkStatus.completed)
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
    chips.add(
      MouseRegion(
        onEnter: (_) {},
        onExit: (_) {},
        child: GestureDetector(
          // 클릭: 대기→수행→제출→확인→대기 순환
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
                unawaited(HomeworkStore.instance.confirm(studentId, hw.id));
                _appendCompletionMemo(studentId, item);
                break;
              case 4: // 확인 → 대기
                unawaited(HomeworkStore.instance.waitPhase(studentId, hw.id));
                break;
              default:
                unawaited(HomeworkStore.instance.start(studentId, hw.id));
            }
          },
          onDoubleTap: () {
            final phase = HomeworkStore.instance.getById(studentId, hw.id)?.phase ?? 1;
            if (phase == 3) {
              HomeworkStore.instance.markAutoCompleteOnNextWaiting(hw.id);
              unawaited(HomeworkStore.instance.confirm(studentId, hw.id));
              final item = HomeworkStore.instance.getById(studentId, hw.id);
              if (item != null) {
                _appendCompletionMemo(studentId, item);
              }
            }
          },
          onSecondaryTap: () {
            final phase = HomeworkStore.instance.getById(studentId, hw.id)?.phase ?? 1;
            if (phase != 3) return;
            // 확인으로 전이 + 다음 대기 진입 시 자동 완료 플래그 설정
            HomeworkStore.instance.markAutoCompleteOnNextWaiting(hw.id);
            unawaited(HomeworkStore.instance.confirm(studentId, hw.id));
            final item = HomeworkStore.instance.getById(studentId, hw.id);
            if (item != null) {
              _appendCompletionMemo(studentId, item);
            }
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
      ),
    );
  }
  return chips;
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
    fontSize: 11,
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
  const double chipHeight = 120;
  final double borderW = isRunning ? 3.0 : 2.0; // 테두리 두께 증가
  const double borderWMax = 3.0; // 상태와 무관하게 최대 테두리 두께 기준으로 폭 고정

  final String displayFlowName = flowName.isNotEmpty ? flowName : '플로우 미지정';
  final String page = (hw.page ?? '').trim();
  final String count = hw.count != null ? hw.count.toString() : '';
  final String line2Left = 'p.${page.isNotEmpty ? page : '-'} / ${count.isNotEmpty ? count : '-'}문항';
  final String homeworkText = assignmentCount > 0 ? 'H$assignmentCount' : '';
  final List<String> rightParts = ['검사 ${hw.checkCount}'];
  if (homeworkText.isNotEmpty) rightParts.add(homeworkText);
  final String line2Right = rightParts.join(' · ');
  final DateTime? startAt = hw.firstStartedAt ?? hw.runStart ?? hw.createdAt ?? hw.updatedAt;
  final String startText = startAt == null ? '-' : _formatDateTime(startAt);
  final int runningMs = hw.runStart != null
      ? DateTime.now().difference(hw.runStart!).inMilliseconds
      : 0;
  final int totalMs = hw.accumulatedMs + runningMs;
  final String durationText = _formatDurationMs(totalMs);
  final String line3 = '시작 $startText · 진행 $durationText';

  final String titleText = (hw.title).trim();
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
    text: TextSpan(text: line2Right, style: statStyle),
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
  final double line2Width = painter2Left.width + (line2Right.isNotEmpty ? (8 + painter2Right.width) : 0);
  final double maxLineWidth = math.max(rowWidth, math.max(line2Width, painter3.width));
  // 여유폭 14px, 최소폭 300px
  final double fixedWidth = (maxLineWidth + leftPad + rightPad + borderWMax * 2 + 14.0).clamp(300.0, 760.0);

  Widget chipInner = Container(
    height: chipHeight,
    padding: const EdgeInsets.fromLTRB(leftPad, 14, rightPad, 14),
    alignment: Alignment.centerLeft,
    decoration: BoxDecoration(
      color: (phase == 4
          ? Color.lerp(const Color(0xFF15171C), const Color(0xFF1D2128), (0.5 + 0.5 * math.sin(2 * math.pi * tick)))
          : const Color(0xFF15171C)),
      borderRadius: BorderRadius.circular(10),
      border: isRunning
          ? Border.all(color: hw.color.withOpacity(0.9), width: borderW)
          : (phase == 3 ? null : Border.all(color: Colors.white24, width: borderW)),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.4),
          blurRadius: 10,
          offset: const Offset(0, 4),
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
        Row(
          children: [
            Expanded(
              child: Text(
                line2Left,
                style: metaStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (line2Right.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                line2Right,
                style: statStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
              ),
            ],
          ],
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
      foregroundPainter: _RotatingBorderPainter(baseColor: hw.color, tick: tick, strokeWidth: 3.0, cornerRadius: 10.0),
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
  _AttendingStudent({required this.id, required this.name, required this.color});
}

class _AttendingButton extends StatelessWidget {
  final String name;
  final Color color;
  final VoidCallback onAddTag;
  final VoidCallback onAddHomework;
  final String studentId;
  const _AttendingButton({required this.studentId, required this.name, required this.color, required this.onAddTag, required this.onAddHomework});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {},
      child: Container(
        width: ClassContentScreen._attendingCardWidth,
        height: ClassContentScreen._attendingCardHeight,
        padding: const EdgeInsets.fromLTRB(22, 0, 16, 0),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: color, width: 2),
        ),
        child: Row(
          children: [
            ValueListenableBuilder<int>(
              valueListenable: HomeworkStore.instance.revision,
              builder: (context, _rev, _) {
                // 과제 진행 상태 확인
                final items = HomeworkStore.instance
                    .items(studentId)
                    .where((e) => e.status != HomeworkStatus.completed)
                    .toList();
                final bool hasAny = items.isNotEmpty;
                final bool hasRunning = HomeworkStore.instance.runningOf(studentId) != null;
                final bool isResting = hasAny && !hasRunning; // 모든 칩 정지 → 휴식 상태

                // 학생 정보 조회(학교/학년)
                String school = '';
                String gradeText = '';
                try {
                  final swi = DataManager.instance.students.firstWhere((s) => s.student.id == studentId);
                  school = swi.student.school;
                  final int g = swi.student.grade;
                  gradeText = g > 0 ? (g.toString() + '학년') : '';
                } catch (_) {}

                final nameStyle = TextStyle(
                  color: isResting ? Colors.white54 : Colors.white,
                  fontSize: 34,
                  fontWeight: FontWeight.w600,
                );

                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(name, style: nameStyle, overflow: TextOverflow.ellipsis),
                    const SizedBox(width: 22),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(school, style: const TextStyle(color: Colors.white70, fontSize: 16, height: 1.15, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                          SizedBox(height: 8),
                          Text(gradeText, style: const TextStyle(color: Colors.white60, fontSize: 15, height: 1.15), maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
            const Spacer(),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // O: 태그 추가 버튼(아이콘 자리만; 기능 미구현)
                Tooltip(
                  message: '태그 추가',
                  child: InkWell(
                    onTap: onAddTag,
                    borderRadius: BorderRadius.circular(999),
                    child: const SizedBox(
                      width: 48,
                      height: 48,
                      child: Center(child: Icon(Icons.circle_outlined, color: Colors.white70, size: 22)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Tooltip(
                  message: '과제 추가',
                  child: InkWell(
                    onTap: onAddHomework,
                    borderRadius: BorderRadius.circular(999),
                    child: const SizedBox(
                      width: 48,
                      height: 48,
                      child: Center(child: Icon(Icons.add_rounded, color: Colors.white70, size: 24)),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _NoteEntry {
  final String text;
  _NoteEntry(this.text);
}





