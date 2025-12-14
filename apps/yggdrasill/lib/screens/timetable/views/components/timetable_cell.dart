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
import 'package:uuid/uuid.dart';
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
import '../../../../models/session_override.dart';

class OverlayLabel {
  final String text;
  final OverrideType type; // add 또는 replace
  final bool isCompleted; // 출석(등원+하원) 완료된 보강/추가수업 표시용
  const OverlayLabel({required this.text, required this.type, this.isCompleted = false});
}

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
  final bool isSelected;
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
  final List<OverlayLabel> makeupOverlays; // 보강/추가수업 오버레이 항목들

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
    this.isSelected = false,
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
    this.makeupOverlays = const [],
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
        print('[DRAG][drop:onWillAccept] data=$data');
        if (data == null) return false;
        if (data['type'] == 'move') {
          return data.containsKey('students') && data.containsKey('oldDayIndex') && data.containsKey('oldStartTime');
        }
        if (data['type'] == 'class-move') {
          return data.containsKey('classId') && data.containsKey('blocks');
        }
        return false;
      },
      onAccept: (data) async {
        if (data['type'] == 'move') {
          // 학생 이동 기존 로직
          final studentsRaw = (data['students'] as List);
          final students = studentsRaw
              .map((e) => e is StudentWithInfo ? e : e['student'] as StudentWithInfo)
              .toList();
          final oldDayIndex = data['oldDayIndex'] as int?;
          final oldStartTime = data['oldStartTime'] as DateTime?;
          final ids = students.map((s) => s.student.id).join(',');
          final setIds = studentsRaw.map((e) => e is StudentWithInfo ? 'null' : (e['setId']?.toString() ?? 'null')).join(',');
          print('[DRAG][drop:onAccept] ids=$ids setIds=$setIds from=$oldDayIndex/${oldStartTime?.hour}:${oldStartTime?.minute} -> to=$dayIdx/${startTime.hour}:${startTime.minute}');
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
                id: '', studentId: '', dayIndex: -1, startHour: 0, startMinute: 0, duration: Duration.zero, createdAt: DateTime(0), startDate: DateTime(0), setId: null, number: null,
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
                  final now = DateTime.now();
                  final newBlock = block.copyWith(
                    id: const Uuid().v4(),
                    dayIndex: dayIdx,
                    startHour: startTime.hour,
                    startMinute: startTime.minute,
                    createdAt: now,
                    startDate: DateTime(now.year, now.month, now.day),
                    endDate: null,
                  );
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
              final now = DateTime.now();
              final today = DateTime(now.year, now.month, now.day);
              for (final block in toMove) {
                final diff = block.number! - baseNumber;
                final newTime = baseTime.add(Duration(minutes: duration.inMinutes * diff));
                final newBlock = block.copyWith(
                  id: const Uuid().v4(),
                  dayIndex: dayIdx,
                  startHour: newTime.hour,
                  startMinute: newTime.minute,
                  createdAt: now,
                  startDate: today,
                  endDate: null,
                );
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
          print('[DRAG][drop:summary] remove=${toRemove.map((b) => b.id).toList()} add=${toAdd.map((b) => b.id).toList()} failed=${failedStudents.map((f)=>f.student.id).toList()}');
          await DataManager.instance.bulkDeleteStudentTimeBlocks(toRemove.map((b) => b.id).toList());
          await DataManager.instance.bulkAddStudentTimeBlocks(toAdd);
          await DataManager.instance.loadStudents();
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
          print('[DEBUG][TimetableCell] timetableContentViewState != null: ${timetableContentViewState != null}');
          if (timetableContentViewState != null) {
            timetableContentViewState.updateCellStudentsAfterMove(dayIdx, startTime);
            print('[DEBUG][TimetableCell] exitSelectModeIfNeeded 호출 시도');
            timetableContentViewState.exitSelectModeIfNeeded();
          }
          return;
        }

        if (data['type'] == 'class-move') {
          final blocksRaw = (data['blocks'] as List).cast<Map>();
          if (blocksRaw.isEmpty) return;
          // 기준점 계산
          int minTotal = 1 << 30;
          for (final b in blocksRaw) {
            final total = (b['dayIndex'] as int) * 24 * 60 + (b['startHour'] as int) * 60 + (b['startMinute'] as int);
            if (total < minTotal) minTotal = total;
          }
          final targetTotal = dayIdx * 24 * 60 + startTime.hour * 60 + startTime.minute;
          final delta = targetTotal - minTotal;
          List<StudentTimeBlock> newBlocks = [];
          List<String> oldIds = [];
          for (final b in blocksRaw) {
            final oldTotal = (b['dayIndex'] as int) * 24 * 60 + (b['startHour'] as int) * 60 + (b['startMinute'] as int);
            final newTotal = oldTotal + delta;
            final newDay = newTotal ~/ (24 * 60);
            final newMinuteTotal = newTotal % (24 * 60);
            final newHour = newMinuteTotal ~/ 60;
            final newMinute = newMinuteTotal % 60;
            final duration = Duration(minutes: b['duration'] as int);
            oldIds.add(b['id'] as String);
            newBlocks.add(StudentTimeBlock(
              id: b['id'] as String,
              studentId: b['studentId'] as String,
              dayIndex: newDay,
              startHour: newHour,
              startMinute: newMinute,
              duration: duration,
              createdAt: DateTime.now(),
              startDate: DateTime.now(),
              setId: b['setId'] as String?,
              number: b['number'] as int?,
              sessionTypeId: b['sessionTypeId'] as String?,
            ));
          }
          await DataManager.instance.bulkDeleteStudentTimeBlocks(oldIds, immediate: true);
          await DataManager.instance.bulkAddStudentTimeBlocks(newBlocks, immediate: true);
          await DataManager.instance.loadStudents();
          final timetableContentViewState = context.findAncestorStateOfType<TimetableContentViewState>();
          if (timetableContentViewState != null) {
            timetableContentViewState.updateCellStudentsAfterMove(dayIdx, startTime);
            timetableContentViewState.exitSelectModeIfNeeded();
          }
        }
      },
      builder: (context, candidateData, rejectedData) {
        return GestureDetector(
          onTap: onTap,
          child: Stack(
            children: [
              // 배경 및 선택/드래그 하이라이트
              Builder(builder: (_) {
                final bool showSelected = isSelected && !isBreakTime;
                final Color backgroundColor = isBreakTime
                    ? const Color(0xFF1F1F1F)
                    : isDragHighlight
                        ? const Color(0xFF1976D2).withOpacity(0.18)
                        : showSelected
                            ? const Color(0xFF33A373).withOpacity(0.12)
                            : Colors.transparent;
                final Border border = Border(
                  left: BorderSide(
                    color: Colors.white.withOpacity(0.1),
                  ),
                );
                return Container(
                  decoration: BoxDecoration(
                    color: backgroundColor,
                    border: border,
                  ),
                );
              }),
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
                    width: 18, // 요청에 따라 19로 조정
                    height: double.infinity,
                    margin: const EdgeInsets.symmetric(vertical: 0.5), // 음수 margin 제거
                    decoration: BoxDecoration(
                      color: countColor ?? Colors.green,
                      borderRadius: BorderRadius.circular(50), // 알약 형태
                    ),
                    child: Center(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final text = '$activeStudentCount';
                          final bool isTwoDigits = text.length >= 2;
                          final double fontSize = isTwoDigits ? 12 : 14.5;
                          return Text(
                            text,
                            style: TextStyle(
                              color: Colors.black45, // 상단앱바 타이틀 색상(회색)
                              fontSize: fontSize,
                              fontWeight: FontWeight.bold,
                              height: 1.0,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.visible,
                          );
                        },
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
              if (makeupOverlays.isNotEmpty)
                Positioned(
                  left: 21, // 좌측 카운트 바를 피해서 표시 (5px 더 확장)
                  top: 4,
                  right: 4,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: makeupOverlays.map((item) {
                      final bool isReplace = item.type == OverrideType.replace;
                      final Color bg = item.isCompleted
                          ? const Color(0xFF212A31).withOpacity(0.6)
                          : (isReplace
                              ? const Color(0xFF1976D2).withOpacity(0.18) // 파란 형광펜
                              : const Color(0xFF4CAF50).withOpacity(0.18)); // 초록 형광펜 (추가수업)
                      return Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: 2.0),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                        decoration: BoxDecoration(
                          color: bg,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Center(
                          child: Text(
                            item.text,
                            style: TextStyle(
                              color: item.isCompleted ? Colors.white70 : const Color(0xFFEAF2F2),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              height: 1.1,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
} 