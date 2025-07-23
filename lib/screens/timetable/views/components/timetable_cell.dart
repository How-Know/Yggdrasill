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
        // 학생카드만 허용 (students, oldDayIndex, oldStartTime이 있어야 함)
        return data != null && data.containsKey('students') && data.containsKey('oldDayIndex') && data.containsKey('oldStartTime');
      },
      onAccept: (data) async {
        print('[DEBUG][TimetableCell][onAccept] 드롭 데이터: $data');
        final students = (data['students'] as List<StudentWithInfo>?) ?? [];
        final oldDayIndex = data['oldDayIndex'] as int?;
        final oldStartTime = data['oldStartTime'] as DateTime?;
        final isSelfStudy = data['isSelfStudy'] as bool? ?? false;
        print('[DEBUG][TimetableCell][onAccept] students=${students.map((s) => s.student.name).toList()}, oldDayIndex=$oldDayIndex, oldStartTime=$oldStartTime, isSelfStudy=$isSelfStudy');
        if (isSelfStudy) {
          print('[DEBUG][TimetableCell][onAccept] 자습 블록 이동 처리');
          // 자습 블록 이동 처리
          for (final studentWithInfo in students) {
            if (studentWithInfo == null || oldDayIndex == null || oldStartTime == null) continue;
            final studentId = studentWithInfo.student.id;
            print('[DEBUG][TimetableCell][onAccept] 자습 블록 이동: studentId=$studentId, oldDayIndex=$oldDayIndex, oldStartTime=$oldStartTime');
            
            // 자습 블록 찾기 (setId 기반으로 모든 블록 찾기)
            final targetBlock = DataManager.instance.selfStudyTimeBlocks.firstWhere(
              (b) => b.studentId == studentId && 
                     b.dayIndex == oldDayIndex && 
                     b.startTime.hour == oldStartTime.hour && 
                     b.startTime.minute == oldStartTime.minute,
              orElse: () => SelfStudyTimeBlock(
                id: '', studentId: '', dayIndex: -1, startTime: DateTime(0), duration: Duration.zero, createdAt: DateTime(0), setId: null, number: null,
              ),
            );
            
            print('[DEBUG][TimetableCell][onAccept] 타겟 자습 블록: setId=${targetBlock.setId}, number=${targetBlock.number}');
            
            if (targetBlock.setId != null && targetBlock.number != null) {
              // setId+studentId로 모든 블록 찾기
              final setId = targetBlock.setId;
              final baseNumber = targetBlock.number!;
              final toMove = DataManager.instance.selfStudyTimeBlocks.where((b) => b.setId == setId && b.studentId == studentId).toList();
              
              // number 기준 정렬
              toMove.sort((a, b) => a.number!.compareTo(b.number!));
              
              print('[DEBUG][TimetableCell][onAccept] setId 기반 이동할 자습 블록: ${toMove.length}개');
              
              // 드롭된 셀의 시간(=number==baseNumber가 이동할 시간)
              final baseTime = startTime;
              final duration = targetBlock.duration;
              
              for (final block in toMove) {
                final diff = block.number! - baseNumber;
                final newTime = baseTime.add(Duration(minutes: duration.inMinutes * diff));
                final newBlock = block.copyWith(
                  dayIndex: dayIdx,
                  startTime: newTime,
                );
                print('[DEBUG][TimetableCell][onAccept] 자습 블록 이동: ${block.id} (number=${block.number}) -> dayIndex=$dayIdx, startTime=$newTime');
                await DataManager.instance.updateSelfStudyTimeBlock(block.id, newBlock);
              }
            } else {
              // setId가 없는 경우 단일 블록만 이동
              final selfStudyBlocks = DataManager.instance.selfStudyTimeBlocks.where((b) =>
                b.studentId == studentId && 
                b.dayIndex == oldDayIndex && 
                b.startTime.hour == oldStartTime.hour && 
                b.startTime.minute == oldStartTime.minute
              ).toList();
              
              print('[DEBUG][TimetableCell][onAccept] setId 없는 경우 단일 자습 블록 이동: ${selfStudyBlocks.length}개');
              
              for (final block in selfStudyBlocks) {
                final newBlock = block.copyWith(
                  dayIndex: dayIdx,
                  startTime: startTime,
                );
                print('[DEBUG][TimetableCell][onAccept] 단일 자습 블록 이동: ${block.id} -> dayIndex=$dayIdx, startTime=$startTime');
                await DataManager.instance.updateSelfStudyTimeBlock(block.id, newBlock);
              }
            }
          }
          
          // 자습 블록 이동 후 UI 갱신
          final timetableContentViewState = context.findAncestorStateOfType<TimetableContentViewState>();
          if (timetableContentViewState != null) {
            print('[DEBUG][TimetableCell][onAccept] 자습 블록 이동 후 UI 갱신');
            timetableContentViewState.exitSelectModeIfNeeded();
          }
          return;
        }
        
        // 수업 블록 이동 처리 (기존 로직)
        print('[DEBUG][TimetableCell][onAccept] 수업 블록 이동 처리');
        List<StudentTimeBlock> toRemove = [];
        List<StudentTimeBlock> toAdd = [];
        for (final studentWithInfo in students) {
          if (studentWithInfo == null || oldDayIndex == null || oldStartTime == null) continue;
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
              toRemove.add(block);
              toAdd.add(newBlock);
            }
            continue;
          }
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
            toRemove.add(block);
            toAdd.add(newBlock);
          }
        }
        // 1. 메모리상의 studentTimeBlocks를 즉시 갱신 (UI 즉시 반영)
        final newBlocks = List<StudentTimeBlock>.from(DataManager.instance.studentTimeBlocks);
        newBlocks.removeWhere((b) => toRemove.any((r) => r.id == b.id));
        newBlocks.addAll(toAdd);
        DataManager.instance.studentTimeBlocks = newBlocks;
        DataManager.instance.studentTimeBlocksNotifier.value = List.unmodifiable(newBlocks);
        // 2. DB 동기화는 트랜잭션으로 처리 (await하지 않음)
        DataManager.instance.bulkDeleteStudentTimeBlocks(toRemove.map((b) => b.id).toList());
        DataManager.instance.bulkAddStudentTimeBlocks(toAdd);
        // 3. 학생/블록 전체 동기화는 백그라운드에서
        DataManager.instance.loadStudentTimeBlocks();
        DataManager.instance.loadStudents();
        // 4. 반드시 이동 후의 셀(dayIdx, startTime) 기준으로 학생카드 리스트 갱신
        final timetableContentViewState = context.findAncestorStateOfType<TimetableContentViewState>();
        if (timetableContentViewState != null) {
          timetableContentViewState.updateCellStudentsAfterMove(dayIdx, startTime);
          // 다중 이동/수정 후 선택모드 종료 콜백 호출
          timetableContentViewState.exitSelectModeIfNeeded();
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