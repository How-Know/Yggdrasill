import 'package:flutter/material.dart';
import '../services/data_manager.dart';
import 'dart:async';
import 'dart:math' as math;
import '../services/homework_store.dart';
import '../models/attendance_record.dart';
import 'learning/homework_quick_add_proxy_dialog.dart';
import '../services/tag_preset_service.dart';
import '../services/tag_store.dart';
import 'learning/tag_preset_dialog.dart';
import 'package:uuid/uuid.dart';
import '../models/memo.dart';

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

  @override
  void initState() {
    super.initState();
    _uiAnimController = AnimationController(duration: const Duration(milliseconds: 1800), vsync: this)..repeat();
  }

  @override
  void dispose() {
    _uiAnimController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final attending = _computeAttendingStudentsRealtime();
    return Stack(
      children: [
        Container(
          color: const Color(0xFF1F1F1F),
          width: double.infinity,
          child: ValueListenableBuilder<List<AttendanceRecord>>(
            valueListenable: DataManager.instance.attendanceRecordsNotifier,
            builder: (context, _records, __) {
              // sessionOverrides 변화도 함께 트리거
              final _ = DataManager.instance.sessionOverridesNotifier.value;
              final list = _computeAttendingStudentsRealtime();
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
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
    final item = await showDialog<dynamic>(
      context: context,
      builder: (ctx) => HomeworkQuickAddProxyDialog(studentId: studentId, initialTitle: '', initialColor: const Color(0xFF1976D2)),
    );
    if (item is Map<String, dynamic>) {
      if (item['studentId'] == studentId) {
        HomeworkStore.instance.add(item['studentId'], title: item['title'], body: item['body'], color: item['color']);
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
    final controller = TextEditingController();
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
  final controller = TextEditingController();
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
  return '${dt.year}.${two(dt.month)}.${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
}

// ------------------------
// 오른쪽 패널: 슬라이드시트와 동일한 과제 칩 렌더링
// ------------------------
Widget _buildHomeworkChipsReactiveForStudent(String studentId, double tick, void Function(String text) onComplete) {
  return ValueListenableBuilder<int>(
    valueListenable: HomeworkStore.instance.revision,
    builder: (context, _rev, _) {
      return Wrap(
        spacing: 24, // 칩 간격 2배
        runSpacing: 24,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: _buildHomeworkChipsOnceForStudent(context, studentId, tick, onComplete),
      );
    },
  );
}

List<Widget> _buildHomeworkChipsOnceForStudent(BuildContext context, String studentId, double tick, void Function(String text) onComplete) {
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
          // 제출 단계에서만: 클릭=확인, 더블클릭=자동완료 플래그 설정+확인 전이
          onTap: () {
            final phase = HomeworkStore.instance.getById(studentId, hw.id)?.phase ?? 1;
            if (phase == 3) {
              unawaited(HomeworkStore.instance.confirm(studentId, hw.id));
              final item = HomeworkStore.instance.getById(studentId, hw.id);
              final accMs = item?.accumulatedMs ?? 0;
              final d = Duration(milliseconds: accMs);
              final h = d.inHours; final m = d.inMinutes.remainder(60);
              final timeText = h > 0 ? ('$h시간 $m분') : ('$m분');
              final studentName = DataManager.instance.students.firstWhere((s) => s.student.id == studentId).student.name;
              final title = (item?.title ?? '').trim();
              final body = (item?.body ?? '').trim();
              final original = '$studentName 학생 ${title.isEmpty ? '' : title + ' '}완료, ${[if (body.isNotEmpty) body, timeText].join(' ')}'.trim();
              final now = DateTime.now();
              final memo = Memo(
                id: const Uuid().v4(),
                original: original,
                summary: original,
                scheduledAt: now.add(const Duration(hours: 24)),
                dismissed: false,
                createdAt: now,
                updatedAt: now,
              );
              unawaited(DataManager.instance.addMemo(memo));
            }
          },
          onDoubleTap: () {
            final phase = HomeworkStore.instance.getById(studentId, hw.id)?.phase ?? 1;
            if (phase == 3) {
              HomeworkStore.instance.markAutoCompleteOnNextWaiting(hw.id);
              unawaited(HomeworkStore.instance.confirm(studentId, hw.id));
              final item = HomeworkStore.instance.getById(studentId, hw.id);
              final accMs = item?.accumulatedMs ?? 0;
              final d = Duration(milliseconds: accMs);
              final h = d.inHours; final m = d.inMinutes.remainder(60);
              final timeText = h > 0 ? ('$h시간 $m분') : ('$m분');
              final studentName = DataManager.instance.students.firstWhere((s) => s.student.id == studentId).student.name;
              final title = (item?.title ?? '').trim();
              final body = (item?.body ?? '').trim();
              final original = '$studentName 학생 ${title.isEmpty ? '' : title + ' '}완료, ${[if (body.isNotEmpty) body, timeText].join(' ')}'.trim();
              final now = DateTime.now();
              final memo = Memo(
                id: const Uuid().v4(),
                original: original,
                summary: original,
                scheduledAt: now.add(const Duration(hours: 24)),
                dismissed: false,
                createdAt: now,
                updatedAt: now,
              );
              unawaited(DataManager.instance.addMemo(memo));
            }
          },
          onSecondaryTap: () {
            final phase = HomeworkStore.instance.getById(studentId, hw.id)?.phase ?? 1;
            if (phase != 3) return;
            // 확인으로 전이 + 다음 대기 진입 시 자동 완료 플래그 설정
            HomeworkStore.instance.markAutoCompleteOnNextWaiting(hw.id);
            unawaited(HomeworkStore.instance.confirm(studentId, hw.id));
            final item = HomeworkStore.instance.getById(studentId, hw.id);
            final accMs = item?.accumulatedMs ?? 0;
            final d = Duration(milliseconds: accMs);
            final h = d.inHours; final m = d.inMinutes.remainder(60);
            final timeText = h > 0 ? ('$h시간 $m분') : ('$m분');
            final studentName = DataManager.instance.students.firstWhere((s) => s.student.id == studentId).student.name;
            final title = (item?.title ?? '').trim();
            final body = (item?.body ?? '').trim();
            final original = '$studentName 학생 ${title.isEmpty ? '' : title + ' '}완료, ${[if (body.isNotEmpty) body, timeText].join(' ')}'.trim();
            final now = DateTime.now();
            final memo = Memo(
              id: const Uuid().v4(),
              original: original,
              summary: original,
              scheduledAt: now.add(const Duration(hours: 24)),
              dismissed: false,
              createdAt: now,
              updatedAt: now,
            );
            unawaited(DataManager.instance.addMemo(memo));
          },
          child: _buildHomeworkChipVisual(context, studentId, hw.id, hw.title, hw.color, tick: tick),
        ),
      ),
    );
  }
  return chips;
}

Widget _buildHomeworkChipVisual(BuildContext context, String studentId, String id, String title, Color color, {required double tick}) {
  final item = HomeworkStore.instance.getById(studentId, id);
  final bool isRunning = HomeworkStore.instance.runningOf(studentId)?.id == id;
  final int phase = item?.phase ?? 1; // 1:대기,2:수행,3:제출,4:확인
  final style = TextStyle(color: isRunning ? Colors.white70 : (phase == 4 ? Colors.white.withOpacity(0.9) : Colors.white60), fontSize: 25, fontWeight: FontWeight.w600, height: 1.1);
  const double leftPad = 40; // 좌우 여백 확대
  const double rightPad = 40; // 좌우 여백 확대
  final double borderW = isRunning ? 3.0 : 2.0; // 테두리 두께 증가
  const double borderWMax = 3.0; // 상태와 무관하게 최대 테두리 두께 기준으로 폭 고정

  // 폭 고정: 텍스트 실제 폭 + 패딩 + 최대 테두리 두께*2 (+여유 6px) - 영문 조기 ellipsis 방지
  final painter = TextPainter(
    text: TextSpan(text: title, style: style),
    maxLines: 1,
    textDirection: TextDirection.ltr,
    textScaleFactor: MediaQuery.of(context).textScaleFactor,
  )..layout(minWidth: 0, maxWidth: double.infinity);
  // 여유폭을 14px로 상향하고 최소폭을 110px로 늘려 영문 조기 ellipsis 방지
  final double fixedWidth = (painter.width + leftPad + rightPad + borderWMax * 2 + 14.0).clamp(110.0, 760.0);

  // 칩 내부: 제목 + 본문/총 수행시간(2줄) 표시
  final String body = HomeworkStore.instance.getById(studentId, id)?.body ?? '';
  final int accumulatedMs = HomeworkStore.instance.getById(studentId, id)?.accumulatedMs ?? 0;
  final Duration acc = Duration(milliseconds: accumulatedMs);
  final int hours = acc.inHours;
  final int minutes = acc.inMinutes.remainder(60);
  final String timeText = hours > 0 ? ('$hours시간 $minutes분') : ('$minutes분');

  Widget chipInner = Container(
    height: ClassContentScreen._attendingCardHeight,
    padding: const EdgeInsets.fromLTRB(leftPad, 10, rightPad, 10),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: isRunning
          ? Colors.transparent
          : (phase == 4
              ? Color.lerp(const Color(0xFF2A2A2A), const Color(0xFF33393F), (0.5 + 0.5 * math.sin(2 * math.pi * tick)))
              : const Color(0xFF2A2A2A)),
      borderRadius: BorderRadius.circular(10),
      border: isRunning
          ? Border.all(color: color.withOpacity(0.9), width: borderW)
          : (phase == 3 ? null : Border.all(color: Colors.white24, width: borderW)),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // 제목은 필요시 폰트를 약간 축소해 잘림을 방지
        SizedBox(
          width: fixedWidth - leftPad - rightPad - 4,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.center,
            child: Text(title, style: style, maxLines: 1, softWrap: false),
          ),
        ),
        const SizedBox(height: 10),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: fixedWidth - leftPad - rightPad - 4),
          child: Text(
            body.isNotEmpty ? (body + ' · ' + timeText) : timeText,
            style: const TextStyle(color: Colors.white60, fontSize: 14, height: 1.15),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    ),
  );

  if (!isRunning && phase == 3) {
    chipInner = CustomPaint(
      foregroundPainter: _RotatingBorderPainter(baseColor: color, tick: tick, strokeWidth: 3.0, cornerRadius: 10.0),
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



