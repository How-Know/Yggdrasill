import 'package:flutter/material.dart';
import 'package:collection/collection.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/animation.dart';
import 'package:flutter/cupertino.dart';
import 'package:mneme_flutter/models/student_time_block.dart';
import 'package:mneme_flutter/models/student.dart';
import 'package:mneme_flutter/models/group_info.dart';
import 'package:mneme_flutter/models/education_level.dart';
import 'package:mneme_flutter/widgets/app_snackbar.dart';
import 'package:mneme_flutter/widgets/class_student_card.dart';
import 'package:mneme_flutter/services/data_manager.dart';
import '../../components/timetable_content_view.dart';

class TimetableCell extends StatelessWidget {
  final int dayIdx;
  final int blockIdx;
  final String cellKey;
  final DateTime startTime;
  final DateTime endTime;
  final List<StudentTimeBlock> students;
  final bool isBreakTime;
  final bool isExpanded;
  final bool isDragHighlight;
  final VoidCallback? onTap;
  final VoidCallback? onDragStart;
  final VoidCallback? onDragEnd;
  final Color? countColor;
  final int activeStudentCount;
  final List<StudentWithInfo> cellStudentWithInfos;
  final List<GroupInfo> groups;
  final double cellWidth;

  const TimetableCell({
    super.key,
    required this.dayIdx,
    required this.blockIdx,
    required this.cellKey,
    required this.startTime,
    required this.endTime,
    required this.students,
    required this.isBreakTime,
    required this.isExpanded,
    required this.isDragHighlight,
    this.onTap,
    this.onDragStart,
    this.onDragEnd,
    this.countColor,
    this.activeStudentCount = 0,
    this.cellStudentWithInfos = const [],
    this.groups = const [],
    this.cellWidth = 0,
  });

  @override
  Widget build(BuildContext context) {
    return DragTarget<Map<String, dynamic>>(
      onWillAccept: (data) {
        // 학생카드만 허용 (student, oldDayIndex, oldStartTime이 있어야 함)
        return data != null && data.containsKey('student') && data.containsKey('oldDayIndex') && data.containsKey('oldStartTime');
      },
      onAccept: (data) async {
        final studentWithInfo = data['student'] as StudentWithInfo;
        final oldDayIndex = data['oldDayIndex'] as int?;
        final oldStartTime = data['oldStartTime'] as DateTime?;
        if (studentWithInfo == null || oldDayIndex == null || oldStartTime == null) return;
        final studentId = studentWithInfo.student.id;
        // 1. 이동 대상 블록(setId, number) 찾기
        final allBlocks = DataManager.instance.studentTimeBlocks;
        final targetBlock = allBlocks.firstWhere(
          (b) => b.studentId == studentId && b.dayIndex == oldDayIndex && b.startTime.hour == oldStartTime.hour && b.startTime.minute == oldStartTime.minute,
          orElse: () => StudentTimeBlock(
            id: '', studentId: '', dayIndex: -1, startTime: DateTime(0), duration: Duration.zero, createdAt: DateTime(0), setId: null, number: null,
          ),
        );
        if (targetBlock.setId == null || targetBlock.number == null) {
          // setId/number 없는 경우 단일 블록만 이동
          final block = allBlocks.firstWhereOrNull((b) => b.studentId == studentId && b.dayIndex == oldDayIndex && b.startTime.hour == oldStartTime.hour && b.startTime.minute == oldStartTime.minute);
          if (block != null) {
            final newBlock = block.copyWith(dayIndex: dayIdx, startTime: startTime);
            await DataManager.instance.removeStudentTimeBlock(block.id);
            await DataManager.instance.addStudentTimeBlock(newBlock);
          }
        } else {
          // setId+studentId로 모든 블록 찾기
          final setId = targetBlock.setId;
          final baseNumber = targetBlock.number!;
          final toMove = allBlocks.where((b) => b.setId == setId && b.studentId == studentId).toList();
          // number 기준 정렬
          toMove.sort((a, b) => a.number!.compareTo(b.number!));
          // 드롭된 셀의 시간(=number==baseNumber가 이동할 시간)
          final baseTime = startTime;
          final duration = targetBlock.duration;
          for (final block in toMove) {
            final diff = block.number! - baseNumber;
            final newTime = baseTime.add(Duration(minutes: duration.inMinutes * diff));
            final newBlock = block.copyWith(dayIndex: dayIdx, startTime: newTime);
            await DataManager.instance.removeStudentTimeBlock(block.id);
            await DataManager.instance.addStudentTimeBlock(newBlock);
          }
        }
        // 이동 후 데이터 일괄 새로고침
        await DataManager.instance.loadStudentTimeBlocks();
        await DataManager.instance.loadStudents();
        // 반드시 이동 후의 셀(dayIdx, startTime) 기준으로 학생카드 리스트 갱신
        final timetableContentViewState = context.findAncestorStateOfType<TimetableContentViewState>();
        if (timetableContentViewState != null) {
          timetableContentViewState.updateCellStudentsAfterMove(dayIdx, startTime);
        }
      },
      builder: (context, candidateData, rejectedData) {
        return GestureDetector(
          onTap: onTap,
          child: Stack(
            children: [
              Container(
                decoration: BoxDecoration(
                  color: isBreakTime
                      ? const Color(0xFF1F1F1F)
                      : isDragHighlight
                          ? const Color(0xFF1976D2).withOpacity(0.18)
                          : Colors.transparent,
                  border: Border(
                    left: BorderSide(
                      color: Colors.white.withOpacity(0.1),
                    ),
                  ),
                ),
              ),
              if (isBreakTime)
                Center(
                  child: Text(
                    '휴식',
                    style: TextStyle(
                      color: Colors.grey.shade400,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              if (activeStudentCount > 0)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 28,
                    color: countColor ?? Colors.green,
                    child: Center(
                      child: Text('$activeStudentCount명', style: TextStyle(color: Colors.white)),
                    ),
                  ),
                ),
              if (isExpanded && students.isNotEmpty)
                // 학생 카드(간단 버전)
                Positioned.fill(
                  child: Wrap(
                    spacing: 5,
                    runSpacing: 10,
                    children: cellStudentWithInfos.map((s) => Container(
                      width: 109,
                      height: 39,
                      margin: EdgeInsets.all(2),
                      color: Colors.grey.shade300,
                      child: Center(child: Text(s.student.name, style: TextStyle(color: Colors.black))),
                    )).toList(),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
} 