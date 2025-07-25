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
import 'package:mneme_flutter/models/self_study_time_block.dart';
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
  final String? registrationModeType;

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
    this.registrationModeType,
  });

  @override
  Widget build(BuildContext context) {
    return DragTarget<Map<String, dynamic>>(
      onWillAccept: (data) {
        print('[DEBUG][TimetableCell][onWillAccept] data=$data');
        if (data == null || data['type'] != 'move') return false;
        // 학생카드만 허용 (students, oldDayIndex, oldStartTime이 있어야 함)
        return data != null && data.containsKey('students') && data.containsKey('oldDayIndex') && data.containsKey('oldStartTime');
      },
      onAccept: (data) async {
        print('[DEBUG][TimetableCell][onAccept] 호출: data= [32m$data [0m');
        final students = (data['students'] as List<StudentWithInfo>?) ?? [];
        final oldDayIndex = data['oldDayIndex'] as int?;
        final oldStartTime = data['oldStartTime'] as DateTime?;
        print('[DEBUG][TimetableCell][onAccept] students= [36m${students.map((s) => s.student.name).toList()} [0m, oldDayIndex=$oldDayIndex, oldStartTime=$oldStartTime');
        List<StudentTimeBlock> toRemove = [];
        List<StudentTimeBlock> toAdd = [];
        bool hasConflict = false;
        String? conflictLog;
        for (final studentWithInfo in students) {
          if (studentWithInfo == null || oldDayIndex == null || oldStartTime == null) continue;
          final studentId = studentWithInfo.student.id;
          final allBlocks = DataManager.instance.studentTimeBlocks;
          final targetBlock = allBlocks.firstWhere(
            (b) => b.studentId == studentId && b.dayIndex == oldDayIndex && b.startTime.hour == oldStartTime.hour && b.startTime.minute == oldStartTime.minute,
            orElse: () => StudentTimeBlock(
              id: '', studentId: '', dayIndex: -1, startTime: DateTime(0), duration: Duration.zero, createdAt: DateTime(0), setId: null, number: null,
            ),
          );
          if (targetBlock.setId == null || targetBlock.number == null) {
            // setId/number 없는 경우 단일 블록만 이동/삭제
            final block = allBlocks.firstWhereOrNull((b) => b.studentId == studentId && b.dayIndex == oldDayIndex && b.startTime.hour == oldStartTime.hour && b.startTime.minute == oldStartTime.minute);
            if (block != null) {
              // 중복 체크: 이동하려는 위치에 이미 같은 studentId/setId의 블록이 있으면 예외 허용(같은 setId), 아니면 막음
              final conflictBlock = allBlocks.firstWhereOrNull((b) => b.studentId == studentId && b.dayIndex == dayIdx && b.startTime.hour == startTime.hour && b.startTime.minute == startTime.minute);
              if (conflictBlock != null) {
                // setId가 둘 다 null이거나 같으면 예외 허용
                if (!((conflictBlock.setId == null && block.setId == null) || (conflictBlock.setId != null && block.setId != null && conflictBlock.setId == block.setId))) {
                  hasConflict = true;
                  conflictLog = '[CONFLICT] 단일 블록: studentId=$studentId, setId=${block.setId}, dayIdx=$dayIdx, startTime=$startTime';
                  break;
                }
              }
              final newBlock = block.copyWith(dayIndex: dayIdx, startTime: startTime);
              toRemove.add(block);
              toAdd.add(newBlock);
            }
            continue;
          }
          // setId+studentId로 모든 블록 찾기 (다중 이동/삭제)
          final setId = targetBlock.setId;
          final baseNumber = targetBlock.number!;
          final toMove = allBlocks.where((b) => b.setId == setId && b.studentId == studentId).toList();
          toMove.sort((a, b) => a.number!.compareTo(b.number!));
          final baseTime = startTime;
          final duration = targetBlock.duration;
          final newBlocks = <StudentTimeBlock>[];
          for (final block in toMove) {
            final diff = block.number! - baseNumber;
            final newTime = baseTime.add(Duration(minutes: duration.inMinutes * diff));
            final newBlock = block.copyWith(dayIndex: dayIdx, startTime: newTime);
            newBlocks.add(newBlock);
          }
          // 중복 체크: 이동하려는 위치에 이미 같은 studentId/setId의 블록이 있는지 검사
          for (final newBlock in newBlocks) {
            final conflictBlock = allBlocks.firstWhereOrNull((b) => b.studentId == studentId && b.dayIndex == dayIdx && b.startTime.hour == newBlock.startTime.hour && b.startTime.minute == newBlock.startTime.minute);
            if (conflictBlock != null) {
              // setId가 둘 다 있고 같으면 예외 허용
              if (!(conflictBlock.setId != null && conflictBlock.setId == setId)) {
                hasConflict = true;
                conflictLog = '[CONFLICT] 다중 블록: studentId=$studentId, setId=$setId, dayIdx=$dayIdx, startTime=${newBlock.startTime}';
                break;
              }
            }
          }
          if (hasConflict) break;
          toRemove.addAll(toMove);
          toAdd.addAll(newBlocks);
        }
        if (hasConflict) {
          print('[DEBUG][TimetableCell][onAccept] $conflictLog');
          showAppSnackBar(context, '이미 등록된 시간입니다.');
          return;
        }
        print('[DEBUG][TimetableCell][onAccept] toRemove=${toRemove.map((b) => b.toJson()).toList()}');
        print('[DEBUG][TimetableCell][onAccept] toAdd=${toAdd.map((b) => b.toJson()).toList()}');
        final newBlocksList = List<StudentTimeBlock>.from(DataManager.instance.studentTimeBlocks);
        newBlocksList.removeWhere((b) => toRemove.any((r) => r.id == b.id));
        newBlocksList.addAll(toAdd);
        DataManager.instance.studentTimeBlocks = newBlocksList;
        DataManager.instance.studentTimeBlocksNotifier.value = List.unmodifiable(newBlocksList);
        DataManager.instance.bulkDeleteStudentTimeBlocks(toRemove.map((b) => b.id).toList());
        DataManager.instance.bulkAddStudentTimeBlocks(toAdd);
        DataManager.instance.loadStudentTimeBlocks();
        DataManager.instance.loadStudents();
        final timetableContentViewState = context.findAncestorStateOfType<TimetableContentViewState>();
        if (timetableContentViewState != null) {
          timetableContentViewState.updateCellStudentsAfterMove(dayIdx, startTime);
          timetableContentViewState.exitSelectModeIfNeeded();
        }
      },
      builder: (context, candidateData, rejectedData) {
        print('[DEBUG][TimetableCell][builder] candidateData=$candidateData, rejectedData=$rejectedData');
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