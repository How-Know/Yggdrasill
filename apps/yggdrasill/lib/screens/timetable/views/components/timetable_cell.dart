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

class _BlockRange {
  final DateTime start;
  final DateTime? end;
  const _BlockRange({required this.start, required this.end});
}

Future<_BlockRange?> _pickEffectiveRange(BuildContext context, DateTime defaultDate) async {
  DateTime startDate = DateTime(defaultDate.year, defaultDate.month, defaultDate.day);
  DateTime endDate = startDate;
  bool hasEnd = false;
  String _pad(int v) => v.toString().padLeft(2, '0');
  final startYearC = TextEditingController(text: startDate.year.toString());
  final startMonthC = TextEditingController(text: _pad(startDate.month));
  final startDayC = TextEditingController(text: _pad(startDate.day));
  final endYearC = TextEditingController(text: endDate.year.toString());
  final endMonthC = TextEditingController(text: _pad(endDate.month));
  final endDayC = TextEditingController(text: _pad(endDate.day));

  Future<void> pickDate(bool isStart, StateSetter setState) async {
    final initial = isStart ? startDate : endDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      builder: (ctx, child) => Theme(data: Theme.of(ctx).copyWith(useMaterial3: true), child: child ?? const SizedBox.shrink()),
    );
    if (picked != null) {
      setState(() {
        if (isStart) {
          startDate = DateTime(picked.year, picked.month, picked.day);
          if (!hasEnd) endDate = startDate;
        } else {
          endDate = DateTime(picked.year, picked.month, picked.day);
        }
        startYearC.text = startDate.year.toString();
        startMonthC.text = _pad(startDate.month);
        startDayC.text = _pad(startDate.day);
        endYearC.text = endDate.year.toString();
        endMonthC.text = _pad(endDate.month);
        endDayC.text = _pad(endDate.day);
      });
    }
  }

  Widget dateFields({required bool isStart, required StateSetter setState}) {
    final yC = isStart ? startYearC : endYearC;
    final mC = isStart ? startMonthC : endMonthC;
    final dC = isStart ? startDayC : endDayC;
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: TextField(
            controller: yC,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            keyboardType: TextInputType.number,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(labelText: '년', labelStyle: TextStyle(color: Colors.white54)),
            onChanged: (v) {
              final year = int.tryParse(v);
              if (year != null && year > 0) {
                setState(() {
                  if (isStart) {
                    startDate = DateTime(year, startDate.month, startDate.day);
                    if (!hasEnd) endDate = startDate;
                  } else {
                    endDate = DateTime(year, endDate.month, endDate.day);
                  }
                });
              }
            },
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 56,
          child: TextField(
            controller: mC,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            keyboardType: TextInputType.number,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(labelText: '월', labelStyle: TextStyle(color: Colors.white54)),
            onChanged: (v) {
              final month = int.tryParse(v);
              if (month != null && month >= 1 && month <= 12) {
                setState(() {
                  if (isStart) {
                    startDate = DateTime(startDate.year, month, startDate.day);
                    if (!hasEnd) endDate = startDate;
                  } else {
                    endDate = DateTime(endDate.year, month, endDate.day);
                  }
                });
              }
            },
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 56,
          child: TextField(
            controller: dC,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            keyboardType: TextInputType.number,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(labelText: '일', labelStyle: TextStyle(color: Colors.white54)),
            onChanged: (v) {
              final day = int.tryParse(v);
              if (day != null && day >= 1 && day <= 31) {
                setState(() {
                  if (isStart) {
                    startDate = DateTime(startDate.year, startDate.month, day);
                    if (!hasEnd) endDate = startDate;
                  } else {
                    endDate = DateTime(endDate.year, endDate.month, day);
                  }
                });
              }
            },
          ),
        ),
        IconButton(
          onPressed: () => pickDate(isStart, setState),
          icon: const Icon(Icons.calendar_today, color: Colors.white70, size: 20),
        ),
      ],
    );
  }

  return showDialog<_BlockRange?>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF0B1112),
            title: const Text('효력 기간 선택', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RadioListTile<bool>(
                  value: false,
                  groupValue: hasEnd,
                  onChanged: (v) => setState(() {
                    hasEnd = v ?? false;
                    if (!hasEnd) endDate = startDate;
                  }),
                  title: const Text('종료기간 없음', style: TextStyle(color: Colors.white70)),
                  activeColor: const Color(0xFF66BB6A),
                  enableFeedback: false,
                ),
                RadioListTile<bool>(
                  value: true,
                  groupValue: hasEnd,
                  onChanged: (v) => setState(() {
                    hasEnd = v ?? true;
                  }),
                  title: const Text('종료기간 있음', style: TextStyle(color: Colors.white70)),
                  activeColor: const Color(0xFF66BB6A),
                  enableFeedback: false,
                ),
                const SizedBox(height: 8),
                const Text('시작일', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                dateFields(isStart: true, setState: setState),
                if (hasEnd) ...[
                  const SizedBox(height: 12),
                  const Text('종료일', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  dateFields(isStart: false, setState: setState),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                child: const Text('취소', style: TextStyle(color: Colors.white70)),
              ),
              TextButton(
                onPressed: () {
                  if (hasEnd && endDate.isBefore(startDate)) {
                    showAppSnackBar(context, '종료일은 시작일 이후여야 합니다.', useRoot: true);
                    return;
                  }
                  Navigator.of(ctx).pop(_BlockRange(start: startDate, end: hasEnd ? endDate : null));
                },
                child: const Text('확인', style: TextStyle(color: Color(0xFF66BB6A), fontWeight: FontWeight.w700)),
              ),
            ],
          );
        },
      );
    },
  );
}

class OverlayLabel {
  final String text;
  final OverrideType type; // add 또는 replace
  final bool isCompleted; // 출석(등원+하원) 완료된 보강/추가수업 표시용
  const OverlayLabel({required this.text, required this.type, this.isCompleted = false});
}

class InquiryOverlayLabel {
  final String noteId;
  final String text;
  const InquiryOverlayLabel({required this.noteId, required this.text});
}

class TrialOverlayLabel {
  final String noteId;
  final String text;
  const TrialOverlayLabel({required this.noteId, required this.text});
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
  final bool isPendingHighlight;
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
  final List<InquiryOverlayLabel> inquiryOverlays; // 문의(희망시간) 오버레이 항목들
  final List<TrialOverlayLabel> trialOverlays; // 시범수업(일회성) 오버레이 항목들
  /// 문의(희망수업) 오버레이 라벨 클릭 시 호출 (셀 선택/학생리스트와 분리)
  final void Function(String noteId)? onInquiryOverlayTap;

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
    this.isPendingHighlight = false,
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
    this.inquiryOverlays = const [],
    this.trialOverlays = const [],
    this.onInquiryOverlayTap,
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
    bool _isBlockActiveOnDate(StudentTimeBlock block, DateTime date) {
      final start = DateTime(block.startDate.year, block.startDate.month, block.startDate.day);
      final end = block.endDate != null ? DateTime(block.endDate!.year, block.endDate!.month, block.endDate!.day) : null;
      return !start.isAfter(date) && (end == null || !end.isBefore(date));
    }

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
          final refDate = DateTime(startTime.year, startTime.month, startTime.day);
          final range = await _pickEffectiveRange(context, refDate);
          if (range == null) return;
          final effectiveStart = DateTime(range.start.year, range.start.month, range.start.day);
          final effectiveEnd = range.end == null ? null : DateTime(range.end!.year, range.end!.month, range.end!.day);
          final closeDate = effectiveStart.subtract(const Duration(days: 1));
          final revertStart = effectiveEnd == null ? null : effectiveEnd.add(const Duration(days: 1));

          // 드래그 데이터에 포함된 setId/number(다중 선택 포함)
          final Map<String, String?> draggedSetIdByStudent = {};
          final Map<String, int?> draggedNumberByStudent = {};
          for (final e in studentsRaw) {
            if (e is StudentWithInfo) continue;
            final s = e['student'] as StudentWithInfo?;
            if (s == null) continue;
            draggedSetIdByStudent[s.student.id] = e['setId']?.toString();
            final n = e['number'];
            draggedNumberByStudent[s.student.id] = n is int ? n : int.tryParse(n?.toString() ?? '');
          }

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
            final activeAtStart = allBlocks.where((b) => _isBlockActiveOnDate(b, effectiveStart)).toList();
            StudentTimeBlock? targetBlock;
            final draggedSetId = draggedSetIdByStudent[studentId];
            final draggedNum = draggedNumberByStudent[studentId];
            if (draggedSetId != null && draggedSetId.isNotEmpty) {
              final candidates = activeAtStart
                  .where((b) => b.studentId == studentId && b.setId == draggedSetId)
                  .toList()
                ..sort((a, b) => (a.number ?? 0).compareTo(b.number ?? 0));
              if (candidates.isNotEmpty) {
                if (draggedNum != null) {
                  targetBlock = candidates.firstWhereOrNull((b) => b.number == draggedNum) ?? candidates.first;
                } else {
                  targetBlock = candidates.first;
                }
              }
            }
            targetBlock ??= activeAtStart.firstWhereOrNull(
              (b) => b.studentId == studentId && b.dayIndex == oldDayIndex && b.startHour == oldStartTime.hour && b.startMinute == oldStartTime.minute,
            );
            bool studentHasConflict = false;
            if (targetBlock == null) {
              studentHasConflict = true;
            } else if (targetBlock.setId == null || targetBlock.number == null) {
              final block = targetBlock;
              final conflictBlock = activeAtStart.firstWhereOrNull((b) =>
                  b.studentId == studentId &&
                  b.dayIndex == dayIdx &&
                  b.startHour == startTime.hour &&
                  b.startMinute == startTime.minute);
              if (conflictBlock != null && conflictBlock.id != block.id) {
                studentHasConflict = true;
              }

              // 복귀 일정 겹침 체크(복귀 시작일 기준)
              if (!studentHasConflict && revertStart != null) {
                final activeAtRevert = allBlocks.where((b) => _isBlockActiveOnDate(b, revertStart)).toList();
                final conflictRevert = activeAtRevert.firstWhereOrNull((b) =>
                    b.id != block.id &&
                    b.studentId == studentId &&
                    b.dayIndex == block.dayIndex &&
                    b.startHour == block.startHour &&
                    b.startMinute == block.startMinute);
                if (conflictRevert != null) {
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
                  startDate: effectiveStart,
                  endDate: effectiveEnd ?? block.endDate,
                );
                toRemove.add(block);
                toAdd.add(newBlock);

                // 기간 변경(종료일 존재)면 원복 블록도 생성
                if (revertStart != null) {
                  final origEnd = block.endDate;
                  if (origEnd == null || !origEnd.isBefore(revertStart)) {
                    toAdd.add(block.copyWith(
                      id: const Uuid().v4(),
                      createdAt: now,
                      startDate: revertStart,
                      endDate: origEnd,
                    ));
                  }
                }
              }
            } else {
              final setId = targetBlock.setId;
              final baseNumber = targetBlock.number!;
              final toMove = activeAtStart.where((b) => b.setId == setId && b.studentId == studentId).toList();
              toMove.sort((a, b) => a.number!.compareTo(b.number!));

              // ===== [규칙] 예약 충돌 처리 =====
              // - 임시 변경(range.start~range.end) 기간 중 "다른 세그먼트(start_date)"가 시작되면 충돌로 간주하고 이동 불가
              // - 임시 변경 종료 후(range.end+1)에는, 이미 예약된 다음 세그먼트가 있으면 원복 블록 end_date를 (다음 세그먼트 시작-1)로 자동 클리핑
              // - 종료기간 없음(end=null) 이동은, 이미 예약된 다음 세그먼트가 있으면 이동 블록 end_date를 (다음 세그먼트 시작-1)로 자동 클리핑
              final List<DateTime> segmentStarts = allBlocks
                  .where((b) => b.studentId == studentId && b.setId == setId)
                  .map((b) => DateTime(b.startDate.year, b.startDate.month, b.startDate.day))
                  .toSet()
                  .toList()
                ..sort((a, b) => a.compareTo(b));

              final DateTime? nextStartAfterStart = segmentStarts.firstWhereOrNull((d) => d.isAfter(effectiveStart));
              final DateTime? clipEndAfterStart = nextStartAfterStart != null
                  ? nextStartAfterStart.subtract(const Duration(days: 1))
                  : null;

              if (effectiveEnd != null) {
                final overlapStart = segmentStarts.firstWhereOrNull(
                  (d) => d.isAfter(effectiveStart) && !d.isAfter(effectiveEnd),
                );
                if (overlapStart != null) {
                  studentHasConflict = true;
                }
              }

              final bool hasStartAtRevert =
                  revertStart != null && segmentStarts.contains(revertStart);
              final DateTime? nextStartAfterRevert = revertStart == null
                  ? null
                  : segmentStarts.firstWhereOrNull((d) => d.isAfter(revertStart));
              final DateTime? clipEndAfterRevert = nextStartAfterRevert != null
                  ? nextStartAfterRevert.subtract(const Duration(days: 1))
                  : null;

              final baseTime = startTime;
              final duration = targetBlock.duration;
              final newBlocks = <StudentTimeBlock>[];
              final now = DateTime.now();
              if (!studentHasConflict) for (final block in toMove) {
                final diff = block.number! - baseNumber;
                final newTime = baseTime.add(Duration(minutes: duration.inMinutes * diff));
                DateTime? newEnd = effectiveEnd ?? block.endDate;
                if (effectiveEnd == null && clipEndAfterStart != null) {
                  if (newEnd == null || newEnd.isAfter(clipEndAfterStart)) {
                    newEnd = clipEndAfterStart;
                  }
                }
                  final newBlock = block.copyWith(
                  id: const Uuid().v4(),
                  dayIndex: dayIdx,
                  startHour: newTime.hour,
                  startMinute: newTime.minute,
                  createdAt: now,
                    startDate: effectiveStart,
                    endDate: newEnd,
                );
                newBlocks.add(newBlock);
              }
              for (final newBlock in newBlocks) {
                final conflictBlock = activeAtStart.firstWhereOrNull((b) =>
                    b.studentId == studentId &&
                    b.dayIndex == dayIdx &&
                    b.startHour == newBlock.startHour &&
                    b.startMinute == newBlock.startMinute);
                if (conflictBlock != null && !toMove.any((src) => src.id == conflictBlock.id)) {
                  studentHasConflict = true;
                  break;
                }
              }

              // 기간 변경(종료일 존재)면 원복 블록 생성: range.end+1일부터 원래 스케줄로 복귀
              if (!studentHasConflict && revertStart != null && !hasStartAtRevert) {
                final revertBlocks = <StudentTimeBlock>[];
                for (final b in toMove) {
                  DateTime? revertEnd = b.endDate;
                  if (clipEndAfterRevert != null) {
                    if (revertEnd == null || revertEnd.isAfter(clipEndAfterRevert)) {
                      revertEnd = clipEndAfterRevert;
                    }
                  }
                  if (revertEnd != null && revertEnd.isBefore(revertStart)) continue;
                  revertBlocks.add(b.copyWith(
                    id: const Uuid().v4(),
                    createdAt: now,
                    startDate: revertStart,
                    endDate: revertEnd,
                  ));
                }

                if (revertBlocks.isNotEmpty) {
                  final activeAtRevert = allBlocks.where((b) => _isBlockActiveOnDate(b, revertStart)).toList();
                  final activeRevertExcludingSource = activeAtRevert.where((b) => !toMove.any((src) => src.id == b.id)).toList();
                  for (final rb in revertBlocks) {
                    final conflict = activeRevertExcludingSource.firstWhereOrNull((b) =>
                        b.studentId == studentId &&
                        b.dayIndex == rb.dayIndex &&
                        b.startHour == rb.startHour &&
                        b.startMinute == rb.startMinute);
                    if (conflict != null) {
                      studentHasConflict = true;
                      break;
                    }
                  }
                  if (!studentHasConflict) {
                    toAdd.addAll(revertBlocks);
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
          if (toAdd.isEmpty) {
            showAppSnackBar(context, '이미 등록된 시간입니다.');
            return;
          }
          print('[DRAG][drop:summary] remove=${toRemove.map((b) => b.id).toList()} add=${toAdd.map((b) => b.id).toList()} failed=${failedStudents.map((f)=>f.student.id).toList()}');
          // 예약 이동: 기존 블록은 range.start - 1일로 닫아 "즉시 종료(어제)"를 방지
          await DataManager.instance.bulkDeleteStudentTimeBlocks(
            toRemove.map((b) => b.id).toList(),
            skipPlannedRegen: true,
            endDateOverride: closeDate,
          );
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
          final refDate = DateTime(startTime.year, startTime.month, startTime.day);
          final range = await _pickEffectiveRange(context, refDate);
          if (range == null) return;
          final effectiveStart = DateTime(range.start.year, range.start.month, range.start.day);
          final effectiveEnd = range.end == null ? null : DateTime(range.end!.year, range.end!.month, range.end!.day);
          final closeDate = effectiveStart.subtract(const Duration(days: 1));
          final revertStart = effectiveEnd == null ? null : effectiveEnd.add(const Duration(days: 1));

          final allBlocks = DataManager.instance.studentTimeBlocks;
          final activeAtStart = allBlocks.where((b) => _isBlockActiveOnDate(b, effectiveStart)).toList();
          final sourceBlocks = blocksRaw
              .map((b) => activeAtStart.firstWhereOrNull((ab) => ab.id == (b['id'] as String)))
              .whereType<StudentTimeBlock>()
              .toList();
          if (sourceBlocks.isEmpty) {
            print('[DRAG][class-move] active source blocks not found -> skip');
            return;
          }
          // 기준점 계산 (sourceBlocks 기준)
          int minTotal = 1 << 30;
          for (final b in sourceBlocks) {
            final total = b.dayIndex * 24 * 60 + b.startHour * 60 + b.startMinute;
            if (total < minTotal) minTotal = total;
          }
          final targetTotal = dayIdx * 24 * 60 + startTime.hour * 60 + startTime.minute;
          final delta = targetTotal - minTotal;
          final now = DateTime.now();
          final List<StudentTimeBlock> newBlocks = [];
          final List<StudentTimeBlock> revertBlocks = [];
          final List<String> oldIds = [];
          for (final b in sourceBlocks) {
            // ===== [규칙] 예약 충돌 처리(클래스 이동) =====
            // - 임시 변경(range.start~range.end) 기간 중 같은 set_id의 다른 세그먼트(start_date)가 시작되면 충돌로 간주하고 이동 불가
            // - 임시 변경 종료 후(range.end+1)에는, 이미 예약된 다음 세그먼트가 있으면 원복 블록 end_date를 (다음 세그먼트 시작-1)로 자동 클리핑
            // - 종료기간 없음(end=null) 이동은, 이미 예약된 다음 세그먼트가 있으면 이동 블록 end_date를 (다음 세그먼트 시작-1)로 자동 클리핑
            DateTime? clipEndAfterStart;
            DateTime? clipEndAfterRevert;
            bool hasStartAtRevert = false;
            if (b.setId != null && b.setId!.isNotEmpty) {
              final List<DateTime> segmentStarts = allBlocks
                  .where((x) => x.studentId == b.studentId && x.setId == b.setId)
                  .map((x) => DateTime(x.startDate.year, x.startDate.month, x.startDate.day))
                  .toSet()
                  .toList()
                ..sort((a, bb) => a.compareTo(bb));

              final DateTime? nextStartAfterStart = segmentStarts.firstWhereOrNull((d) => d.isAfter(effectiveStart));
              clipEndAfterStart = nextStartAfterStart != null ? nextStartAfterStart.subtract(const Duration(days: 1)) : null;

              if (effectiveEnd != null) {
                final overlapStart = segmentStarts.firstWhereOrNull((d) => d.isAfter(effectiveStart) && !d.isAfter(effectiveEnd));
                if (overlapStart != null) {
                  showAppSnackBar(context, '이미 예약된 변경이 있어 기간이 겹칩니다. (setId=${b.setId})', useRoot: true);
                  return;
                }
              }

              hasStartAtRevert = revertStart != null && segmentStarts.contains(revertStart);
              final DateTime? nextStartAfterRevert = revertStart == null ? null : segmentStarts.firstWhereOrNull((d) => d.isAfter(revertStart));
              clipEndAfterRevert = nextStartAfterRevert != null ? nextStartAfterRevert.subtract(const Duration(days: 1)) : null;
            }

            final oldTotal = b.dayIndex * 24 * 60 + b.startHour * 60 + b.startMinute;
            final newTotal = oldTotal + delta;
            final newDay = newTotal ~/ (24 * 60);
            final newMinuteTotal = newTotal % (24 * 60);
            final newHour = newMinuteTotal ~/ 60;
            final newMinute = newMinuteTotal % 60;
            oldIds.add(b.id);
            // 새 레코드로 생성하여 기존 end_date가 덮어쓰이지 않게 함
            DateTime? newEnd = effectiveEnd ?? b.endDate;
            if (effectiveEnd == null && clipEndAfterStart != null) {
              if (newEnd == null || newEnd.isAfter(clipEndAfterStart)) {
                newEnd = clipEndAfterStart;
              }
            }
            newBlocks.add(b.copyWith(
              id: const Uuid().v4(),
              dayIndex: newDay,
              startHour: newHour,
              startMinute: newMinute,
              createdAt: now,
              startDate: effectiveStart,
              endDate: newEnd,
            ));

            // 기간 변경(종료일 존재)면 원복 블록도 생성
            if (revertStart != null && !hasStartAtRevert) {
              DateTime? revertEnd = b.endDate;
              if (clipEndAfterRevert != null) {
                if (revertEnd == null || revertEnd.isAfter(clipEndAfterRevert)) {
                  revertEnd = clipEndAfterRevert;
                }
              }
              if (revertEnd == null || !revertEnd.isBefore(revertStart)) {
                revertBlocks.add(b.copyWith(
                  id: const Uuid().v4(),
                  createdAt: now,
                  startDate: revertStart,
                  endDate: revertEnd,
                ));
              }
            }
          }
          // 겹침 체크: 기존 활성 블록 중 이동 대상 외에 겹치는 것 있으면 실패
          final activeExcludingSource = activeAtStart.where((b) => !oldIds.contains(b.id)).toList();
          for (final nb in newBlocks) {
            final conflict = activeExcludingSource.firstWhereOrNull((b) =>
                b.studentId == nb.studentId &&
                b.dayIndex == nb.dayIndex &&
                b.startHour == nb.startHour &&
                b.startMinute == nb.startMinute);
            if (conflict != null) {
              showAppSnackBar(context, '이미 등록된 시간과 겹칩니다.', useRoot: true);
              return;
            }
          }

          // 복귀 블록 겹침 체크(복귀 시작일 기준)
          if (revertStart != null && revertBlocks.isNotEmpty) {
            final activeAtRevert = allBlocks.where((b) => _isBlockActiveOnDate(b, revertStart)).toList();
            final activeRevertExcludingSource = activeAtRevert.where((b) => !oldIds.contains(b.id)).toList();
            for (final rb in revertBlocks) {
              final conflict = activeRevertExcludingSource.firstWhereOrNull((b) =>
                  b.studentId == rb.studentId &&
                  b.dayIndex == rb.dayIndex &&
                  b.startHour == rb.startHour &&
                  b.startMinute == rb.startMinute);
              if (conflict != null) {
                showAppSnackBar(context, '복귀 일정이 기존 시간과 겹칩니다.', useRoot: true);
                return;
              }
            }
          }

          print('[DRAG][class-move] remove=${oldIds.length} add=${newBlocks.length} targetDay=$dayIdx targetTime=${startTime.hour}:${startTime.minute}');
          await DataManager.instance.bulkDeleteStudentTimeBlocks(
            oldIds,
            immediate: true,
            skipPlannedRegen: true,
            endDateOverride: closeDate,
          );
          await DataManager.instance.bulkAddStudentTimeBlocks(
            [...newBlocks, ...revertBlocks],
            immediate: true,
          );
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
                            : isPendingHighlight
                                // 등록모드 pending 하이라이트는 일반 셀 선택 하이라이트와 동일 색상/강도 사용
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
              if (makeupOverlays.isNotEmpty || trialOverlays.isNotEmpty || inquiryOverlays.isNotEmpty)
                Positioned(
                  left: 21, // 좌측 카운트 바를 피해서 표시 (5px 더 확장)
                  top: 4,
                  right: 4,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ...makeupOverlays.map((item) {
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
                      }),
                      ...trialOverlays.map((item) {
                        // 추가수업(add)과 동일한 노출/색상으로 표시
                        final Color bg = const Color(0xFF4CAF50).withValues(alpha: 0.18);
                        final bool canTap = (onInquiryOverlayTap != null) && item.noteId.trim().isNotEmpty;
                        final Widget chip = Container(
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
                              style: const TextStyle(
                                color: Color(0xFFEAF2F2),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                height: 1.1,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        );
                        if (!canTap) return chip;
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onInquiryOverlayTap?.call(item.noteId),
                          child: chip,
                        );
                      }),
                      ...inquiryOverlays.map((item) {
                        // 희망수업(문의): #F2B45B
                        // 색이 잘 보이도록 투명도 낮춤(=더 불투명하게)
                        final Color bg = const Color(0xFFF2B45B).withValues(alpha: 0.38);
                        final bool canTap = (onInquiryOverlayTap != null) && item.noteId.trim().isNotEmpty;
                        final Widget chip = Container(
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
                              style: const TextStyle(
                                color: Color(0xFFEAF2F2),
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                height: 1.1,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        );
                        if (!canTap) return chip;
                        // 라벨 탭은 셀 탭(학생리스트/선택)과 분리되어야 하므로 별도 제스처로 소비한다.
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onInquiryOverlayTap?.call(item.noteId),
                          child: chip,
                        );
                      }),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
} 