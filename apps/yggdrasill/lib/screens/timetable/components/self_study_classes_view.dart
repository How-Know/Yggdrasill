import 'package:flutter/material.dart';
import '../../../models/operating_hours.dart';
import '../../../models/self_study_time_block.dart';
import '../../../models/student.dart';
import '../../../services/data_manager.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/services.dart';

class SelfStudyClassesView extends StatefulWidget {
  final List<OperatingHours> operatingHours;
  final StudentWithInfo selectedStudent;
  final void Function(List<SelfStudyTimeBlock> blocks)? onSelfStudyBlocksRegistered;
  final ScrollController scrollController;

  const SelfStudyClassesView({
    super.key,
    required this.operatingHours,
    required this.selectedStudent,
    this.onSelfStudyBlocksRegistered,
    required this.scrollController,
  });

  @override
  State<SelfStudyClassesView> createState() => _SelfStudyClassesViewState();
}

class _SelfStudyClassesViewState extends State<SelfStudyClassesView> {
  FocusNode? _focusNode;
  int? dragStartIdx;
  int? dragEndIdx;
  int? dragDayIdx;
  bool isDragging = false;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _focusNode?.dispose();
    super.dispose();
  }

  Set<String> get dragHighlightKeys {
    if (!isDragging || dragDayIdx == null || dragStartIdx == null || dragEndIdx == null) return {};
    final start = dragStartIdx!;
    final end = dragEndIdx!;
    final day = dragDayIdx!;
    if (start <= end) {
      return {for (int i = start; i <= end; i++) '$day-$i'};
    } else {
      return {for (int i = end; i <= start; i++) '$day-$i'};
    }
  }

  void _onCellPanStart(int dayIdx, int blockIdx) {
    setState(() {
      dragStartIdx = blockIdx;
      dragEndIdx = blockIdx;
      dragDayIdx = dayIdx;
      isDragging = true;
    });
  }

  void _onCellPanUpdate(int dayIdx, int blockIdx) {
    if (!isDragging || dragDayIdx != dayIdx) return;
    setState(() {
      dragEndIdx = blockIdx;
    });
  }

  void _onCellPanEnd(int dayIdx) async {
    print('[DEBUG][SelfStudyClassesView._onCellPanEnd] widget.selectedStudent=${widget.selectedStudent}');
    if (!isDragging || dragDayIdx != dayIdx || dragStartIdx == null || dragEndIdx == null) {
      setState(() { isDragging = false; });
      return;
    }
    final start = dragStartIdx!;
    final end = dragEndIdx!;
    final selectedIdxs = start <= end
        ? [for (int i = start; i <= end; i++) i]
        : [for (int i = end; i <= start; i++) i];
    setState(() {
      isDragging = false;
      dragStartIdx = null;
      dragEndIdx = null;
      dragDayIdx = null;
    });
    // 자습 블록 생성 및 저장
    final timeBlocks = _generateTimeBlocks();
    final startTimes = selectedIdxs.map((blockIdx) => timeBlocks[blockIdx].startTime).toList();
    final now = DateTime.now();
    final setId = const Uuid().v4();
    final duration = DataManager.instance.academySettings.lessonDuration;
    List<SelfStudyTimeBlock> blocks = [];
    for (int i = 0; i < startTimes.length; i++) {
      print('[DEBUG][SelfStudyClassesView._onCellPanEnd] 블록 생성: studentId=${widget.selectedStudent.student.id}, dayIdx=$dayIdx, startTime=${startTimes[i]}');
      final block = SelfStudyTimeBlock(
        id: const Uuid().v4(),
        studentId: widget.selectedStudent.student.id,
        dayIndex: dayIdx,
        startTime: startTimes[i],
        duration: Duration(minutes: duration),
        createdAt: now,
        setId: setId,
        number: i + 1,
      );
      await DataManager.instance.addSelfStudyTimeBlock(block);
      blocks.add(block);
    }
    print('[DEBUG][SelfStudyClassesView._onCellPanEnd] onSelfStudyBlocksRegistered 콜백 호출: blocks=$blocks');
    if (widget.onSelfStudyBlocksRegistered != null) {
      widget.onSelfStudyBlocksRegistered!(blocks);
    }
  }

  List<_TimeBlock> _generateTimeBlocks() {
    final List<_TimeBlock> blocks = [];
    if (widget.operatingHours.isNotEmpty) {
      final now = DateTime.now();
      int minHour = 23, minMinute = 59, maxHour = 0, maxMinute = 0;
      for (final hours in widget.operatingHours) {
        if (hours.startTime.hour < minHour || (hours.startTime.hour == minHour && hours.startTime.minute < minMinute)) {
          minHour = hours.startTime.hour;
          minMinute = hours.startTime.minute;
        }
        if (hours.endTime.hour > maxHour || (hours.endTime.hour == maxHour && hours.endTime.minute > maxMinute)) {
          maxHour = hours.endTime.hour;
          maxMinute = hours.endTime.minute;
        }
      }
      var currentTime = DateTime(now.year, now.month, now.day, minHour, minMinute);
      final endTime = DateTime(now.year, now.month, now.day, maxHour, maxMinute);
      while (currentTime.isBefore(endTime)) {
        final blockEndTime = currentTime.add(const Duration(minutes: 30));
        blocks.add(_TimeBlock(
          startTime: currentTime,
          endTime: blockEndTime,
        ));
        currentTime = blockEndTime;
      }
    }
    return blocks;
  }

  @override
  Widget build(BuildContext context) {
    print('[DEBUG][SelfStudyClassesView.build] widget.selectedStudent=${widget.selectedStudent}');
    final timeBlocks = _generateTimeBlocks();
    final double blockHeight = 90.0;
    // 테스트 전용 플래그로 autofocus를 제어 (기본 동작은 유지)
    const bool kDisableSelfStudyKbAutofocus = bool.fromEnvironment('DISABLE_SELFSTUDY_KB_AUTOFOCUS', defaultValue: false);
    return RawKeyboardListener(
      focusNode: _focusNode!,
      autofocus: !kDisableSelfStudyKbAutofocus,
      onKey: (event) {
        if (event is RawKeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
          if (widget.onSelfStudyBlocksRegistered != null) {
            widget.onSelfStudyBlocksRegistered!([]); // 빈 리스트로 종료 신호
          }
        }
      },
      child: Listener(
        onPointerDown: (event) {
          final box = context.findRenderObject() as RenderBox;
          final local = box.globalToLocal(event.position);
          final blockIdx = (local.dy / blockHeight).floor();
          final dayIdx = ((local.dx - 60) / ((box.size.width - 60) / 7)).floor();
          if (blockIdx >= 0 && blockIdx < timeBlocks.length && dayIdx >= 0 && dayIdx < 7) {
            _onCellPanStart(dayIdx, blockIdx);
          }
        },
        onPointerMove: (event) {
          if (!isDragging) return;
          final box = context.findRenderObject() as RenderBox;
          final local = box.globalToLocal(event.position);
          final blockIdx = (local.dy / blockHeight).floor();
          final dayIdx = ((local.dx - 60) / ((box.size.width - 60) / 7)).floor();
          if (blockIdx >= 0 && blockIdx < timeBlocks.length && dayIdx == dragDayIdx) {
            _onCellPanUpdate(dayIdx, blockIdx);
          }
        },
        onPointerUp: (event) {
          if (!isDragging) return;
          if (dragDayIdx != null) {
            _onCellPanEnd(dragDayIdx!);
          }
        },
        child: Column(
          children: [
            for (int blockIdx = 0; blockIdx < timeBlocks.length; blockIdx++)
              Container(
                height: blockHeight,
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  border: Border(
                    bottom: BorderSide(
                      color: Colors.white.withOpacity(0.1),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 60,
                      child: Center(
                        child: Text(
                          timeBlocks[blockIdx].timeString,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                    ...List.generate(7, (dayIdx) {
                      final cellKey = '$dayIdx-$blockIdx';
                      final isDragHighlight = dragHighlightKeys.contains(cellKey);
                      bool isBreakTime = false;
                      if (widget.operatingHours.length > dayIdx) {
                        final hours = widget.operatingHours[dayIdx];
                        for (final breakTime in hours.breakTimes) {
                          final breakStart = DateTime(
                            timeBlocks[blockIdx].startTime.year,
                            timeBlocks[blockIdx].startTime.month,
                            timeBlocks[blockIdx].startTime.day,
                            breakTime.startTime.hour,
                            breakTime.startTime.minute,
                          );
                          final breakEnd = DateTime(
                            timeBlocks[blockIdx].startTime.year,
                            timeBlocks[blockIdx].startTime.month,
                            timeBlocks[blockIdx].startTime.day,
                            breakTime.endTime.hour,
                            breakTime.endTime.minute,
                          );
                          if ((timeBlocks[blockIdx].startTime.isAfter(breakStart) || timeBlocks[blockIdx].startTime.isAtSameMomentAs(breakStart)) &&
                              timeBlocks[blockIdx].startTime.isBefore(breakEnd)) {
                            isBreakTime = true;
                            break;
                          }
                        }
                      }
                      return Expanded(
                        child: Container(
                          margin: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: isBreakTime
                                ? const Color(0xFF424242)
                                : (isDragHighlight ? Colors.blue.withOpacity(0.2) : Colors.transparent),
                            border: Border.all(color: Colors.white24),
                          ),
                          child: const SizedBox.shrink(),
                        ),
                      );
                    }),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TimeBlock {
  final DateTime startTime;
  final DateTime endTime;
  _TimeBlock({required this.startTime, required this.endTime});
  String get timeString {
    final hour = startTime.hour.toString().padLeft(2, '0');
    final minute = startTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
} 