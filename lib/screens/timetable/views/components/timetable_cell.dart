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
import '../../../../models/operating_hours.dart';

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
  final List<OperatingHours> operatingHours;

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
    required this.operatingHours,
  });

  // [추가] 운영시간/휴식시간 체크 함수 (ClassesViewState에서 복사)
  bool _areAllTimesWithinOperatingAndBreak(int dayIdx, List<DateTime> times) {
    final op = operatingHours.firstWhereOrNull((o) => o.dayOfWeek == dayIdx);
    if (op == null) return false;
    for (final t in times) {
      final tMinutes = t.hour * 60 + t.minute;
      final opStart = op.startHour * 60 + op.startMinute;
      final opEnd = op.endHour * 60 + op.endMinute;
      if (tMinutes < opStart || tMinutes > opEnd) return false;
      for (final br in op.breakTimes) {
        final brStart = br.startHour * 60 + br.startMinute;
        final brEnd = br.endHour * 60 + br.endMinute;
        if (tMinutes >= brStart && tMinutes < brEnd) return false;
      }
    }
    return true;
  }

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
        final students = (data['students'] as List)
            .map((e) => e is StudentWithInfo ? e : e['student'] as StudentWithInfo)
            .toList();
        final oldDayIndex = data['oldDayIndex'] as int?;
        final oldStartTime = data['oldStartTime'] as DateTime?;
        print('[DEBUG][TimetableCell][onAccept] students= [36m${students.map((s) => s.student.name).toList()} [0m, oldDayIndex=$oldDayIndex, oldStartTime=$oldStartTime');
        List<StudentTimeBlock> toRemove = [];
        List<StudentTimeBlock> toAdd = [];
        List<StudentWithInfo> failedStudents = [];
        for (final studentWithInfo in students) {
          if (studentWithInfo == null || oldDayIndex == null || oldStartTime == null) continue;
          final studentId = studentWithInfo.student.id;
          final allBlocks = DataManager.instance.studentTimeBlocks;
          final targetBlock = allBlocks.firstWhere(
            (b) => b.studentId == studentId && b.dayIndex == oldDayIndex && b.startHour == oldStartTime.hour && b.startMinute == oldStartTime.minute,
            orElse: () => StudentTimeBlock(
              id: '', studentId: '', dayIndex: -1, startHour: 0, startMinute: 0, duration: Duration.zero, createdAt: DateTime(0), setId: null, number: null,
            ),
          );
          bool studentHasConflict = false;
          if (targetBlock.setId == null || targetBlock.number == null) {
            final block = allBlocks.firstWhereOrNull((b) => b.studentId == studentId && b.dayIndex == oldDayIndex && b.startHour == oldStartTime.hour && b.startMinute == oldStartTime.minute);
            if (block != null) {
              final conflictBlock = allBlocks.firstWhereOrNull((b) => b.studentId == studentId && b.dayIndex == dayIdx && b.startHour == startTime.hour && b.startMinute == startTime.minute);
              if (conflictBlock != null) {
                if (!((conflictBlock.setId == null && block.setId == null) || (conflictBlock.setId != null && block.setId != null && conflictBlock.setId == block.setId))) {
                  studentHasConflict = true;
                }
              }
              if (!studentHasConflict) {
                final newBlock = block.copyWith(dayIndex: dayIdx, startHour: startTime.hour, startMinute: startTime.minute);
                toRemove.add(block);
                toAdd.add(newBlock);
              }
            } else {
              studentHasConflict = true;
            }
          } else {
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
              final newBlock = block.copyWith(dayIndex: dayIdx, startHour: newTime.hour, startMinute: newTime.minute);
              newBlocks.add(newBlock);
            }
            for (final newBlock in newBlocks) {
              final conflictBlock = allBlocks.firstWhereOrNull((b) => b.studentId == studentId && b.dayIndex == dayIdx && b.startHour == newBlock.startHour && b.startMinute == newBlock.startMinute);
              if (conflictBlock != null) {
                if (!(conflictBlock.setId != null && conflictBlock.setId == setId)) {
                  studentHasConflict = true;
                  break;
                }
              }
            }
            if (!studentHasConflict) {
              toRemove.addAll(toMove);
              toAdd.addAll(newBlocks);
            }
          }
          if (studentHasConflict) {
            failedStudents.add(studentWithInfo);
          }
        }
        // 1. 운영시간/휴식시간 방어: toAdd의 모든 블록이 운영시간/휴식시간과 겹치는지 체크
        bool hasInvalidTime = false;
        for (final block in toAdd) {
          final blockStart = DateTime(0, 1, 1, block.startHour, block.startMinute);
          final blockEnd = blockStart.add(block.duration);
          for (var t = blockStart; t.isBefore(blockEnd); t = t.add(const Duration(minutes: 30))) {
            if (!_areAllTimesWithinOperatingAndBreak(dayIdx, [t])) {
              hasInvalidTime = true;
              break;
            }
          }
          if (hasInvalidTime) break;
        }
        if (hasInvalidTime) {
          Future.microtask(() {
            try {
              showAppSnackBar(context, '운영시간 외 또는 휴식시간에는 수업을 등록할 수 없습니다.', useRoot: true);
            } catch (e, st) {
              print('[DEBUG][showAppSnackBar 예외] $e\n$st');
            }
          });
          return;
        }
        if (toAdd.isEmpty) {
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
        if (failedStudents.isNotEmpty) {
          await showDialog(
            context: context,
            builder: (context) {
              return AlertDialog(
                backgroundColor: const Color(0xFF1F1F1F),
                title: const Text('이동 실패 학생', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                content: SizedBox(
                  width: 320,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('다음 학생은 이미 등록된 시간과 겹쳐 이동할 수 없습니다.', style: TextStyle(color: Color(0xFFB0B0B0), fontSize: 15)),
                      const SizedBox(height: 12),
                      ...failedStudents.map((s) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(s.student.name, style: const TextStyle(color: Color(0xFFB0B0B0), fontSize: 16)),
                      )),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('확인', style: TextStyle(color: Color(0xFF1976D2), fontWeight: FontWeight.bold)),
                  ),
                ],
              );
            },
          );
        }
        final timetableContentViewState = context.findAncestorStateOfType<TimetableContentViewState>();
        if (timetableContentViewState != null) {
          timetableContentViewState.updateCellStudentsAfterMove(dayIdx, startTime);
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
                  bottom: 0,
                  child: Container(
                    width: 23,
                    height: double.infinity,
                    margin: const EdgeInsets.symmetric(vertical: 0.5), // 셀 높이보다 1px 작게
                    decoration: BoxDecoration(
                      color: countColor ?? Colors.green,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 4.0),
                        child: Text(
                          '$activeStudentCount',
                          style: TextStyle(
                            color: Colors.black45, // 상단앱바 타이틀 색상(회색)
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
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