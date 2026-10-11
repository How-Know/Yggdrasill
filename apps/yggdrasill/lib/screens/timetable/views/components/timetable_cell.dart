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
import 'package:mneme_flutter/widgets/schedule_locked_by_makeup_dialog.dart';
import 'package:mneme_flutter/widgets/dialog_tokens.dart';
import 'package:mneme_flutter/services/consult_inquiry_demand_service.dart';
import 'package:mneme_flutter/screens/design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';
import '../../components/timetable_content_view.dart';
import '../../../../models/operating_hours.dart';
import '../../../../models/session_override.dart';

class _BlockRange {
  final DateTime start;
  final DateTime? end;
  const _BlockRange({required this.start, required this.end});
}

Future<_BlockRange?> _pickEffectiveRange(
    BuildContext context, DateTime defaultDate) async {
  DateTime startDate =
      DateTime(defaultDate.year, defaultDate.month, defaultDate.day);
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
      builder: (ctx, child) => Theme(
          data: Theme.of(ctx).copyWith(useMaterial3: true),
          child: child ?? const SizedBox.shrink()),
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
            decoration: const InputDecoration(
                labelText: '년', labelStyle: TextStyle(color: Colors.white54)),
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
            decoration: const InputDecoration(
                labelText: '월', labelStyle: TextStyle(color: Colors.white54)),
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
            decoration: const InputDecoration(
                labelText: '일', labelStyle: TextStyle(color: Colors.white54)),
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
          icon:
              const Icon(Icons.calendar_today, color: Colors.white70, size: 20),
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
            backgroundColor: kDlgBg,
            title: const Text('효력 기간 선택',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700)),
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
                  title: const Text('종료기간 없음',
                      style: TextStyle(color: Colors.white70)),
                  activeColor: const Color(0xFF66BB6A),
                  enableFeedback: false,
                ),
                RadioListTile<bool>(
                  value: true,
                  groupValue: hasEnd,
                  onChanged: (v) => setState(() {
                    hasEnd = v ?? true;
                  }),
                  title: const Text('종료기간 있음',
                      style: TextStyle(color: Colors.white70)),
                  activeColor: const Color(0xFF66BB6A),
                  enableFeedback: false,
                ),
                const SizedBox(height: 8),
                const Text('시작일',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                dateFields(isStart: true, setState: setState),
                if (hasEnd) ...[
                  const SizedBox(height: 12),
                  const Text('종료일',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  dateFields(isStart: false, setState: setState),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                child:
                    const Text('취소', style: TextStyle(color: Colors.white70)),
              ),
              TextButton(
                onPressed: () {
                  if (hasEnd && endDate.isBefore(startDate)) {
                    showAppSnackBar(context, '종료일은 시작일 이후여야 합니다.',
                        useRoot: true);
                    return;
                  }
                  Navigator.of(ctx).pop(_BlockRange(
                      start: startDate, end: hasEnd ? endDate : null));
                },
                child: const Text('확인',
                    style: TextStyle(
                        color: Color(0xFF66BB6A), fontWeight: FontWeight.w700)),
              ),
            ],
          );
        },
      );
    },
  );
}

class OverlayLabel {
  final String overrideId;
  final String text;
  final OverrideType type; // add 또는 replace
  final bool isCompleted; // 출석(등원+하원) 완료된 보강/추가수업 표시용
  const OverlayLabel({
    required this.overrideId,
    required this.text,
    required this.type,
    this.isCompleted = false,
  });
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

/// 정원 도달 띠·숫자. 시간표에서 앰버는 이 의미로만 쓴다.
const Color _kCapacityFullColor = Color(0xFFF2B45B);

/// 인원 띠의 위·아래 여백. 칸 안 숫자·칩 위치도 이 값에 맞춘다.
const double kTimetableBandInset = 6;

/// 인원 단계: 0 비어 있음 / 1 여유(정원 70% 미만) / 2 혼잡(70~99%) / 3 정원 도달.
/// 정원이 0이면 인원이 있어도 여유로 본다.
int timetableCapacityLevel(int count, int capacity) {
  if (count <= 0) return 0;
  if (capacity <= 0) return 1;
  if (count >= capacity) return 3;
  if (count >= capacity * 0.7) return 2;
  return 1;
}

/// 같은 인원 단계가 이어지는 칸들을 하나로 묶은 둥근 띠.
class TimetableCapacityBand extends StatelessWidget {
  const TimetableCapacityBand({super.key, required this.level});

  final int level;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : Colors.black;
    final isFull = level >= 3;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: isFull
            ? _kCapacityFullColor.withValues(alpha: 0.16)
            : ink.withValues(alpha: level == 2 ? 0.15 : 0.06),
        borderRadius: BorderRadius.circular(10),
        border: isFull
            ? Border.all(color: _kCapacityFullColor.withValues(alpha: 0.55))
            : null,
      ),
    );
  }
}

/// 휴식 칸: 진한 블록 대신 옅은 사선.
class _BreakHatchPainter extends CustomPainter {
  const _BreakHatchPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const step = 10.0;
    for (double x = -size.height; x < size.width; x += step) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BreakHatchPainter oldDelegate) =>
      oldDelegate.color != color;
}

class TimetableCell extends StatelessWidget {
  final int dayIdx;
  final int blockIdx;
  final String cellKey;
  final DateTime startTime;
  final DateTime endTime;

  /// 현재 렌더링 중인 "주 시작(월요일)" 날짜(date-only)
  /// - 보강/추가수업 드래그 이동 시 target replacementClassDateTime 계산에 사용
  final DateTime weekStartDate;
  final List<StudentTimeBlock> students;
  final bool isBreakTime;
  final bool isExpanded;
  final bool isDragHighlight;
  final bool isSelected;
  final bool isPendingHighlight;
  final VoidCallback? onTap;
  final VoidCallback? onDragStart;
  final VoidCallback? onDragEnd;
  final int activeStudentCount;

  /// 직전 칸과 인원이 다르면 true — 띠 안에서 바뀐 인원을 흐리게 표시한다.
  final bool countChanged;

  /// 인원 띠(여유·혼잡·정원 단계)가 이 칸에서 시작하면 true — 숫자를 밝게 표시한다.
  final bool capacityBandStart;

  /// 정시(:00) 칸이면 true — 정시에만 세로선을 긋는다.
  final bool isHourStart;

  /// 마우스가 올라간 시간 열(모든 요일 공통)이면 true.
  final bool isHoverColumn;

  /// 이 칸 자체에 마우스가 올라가 있으면 true — 숨은 인원 숫자를 흐리게 보여 준다.
  final bool isHovered;
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
    required this.weekStartDate,
    required this.students,
    required this.isBreakTime,
    required this.isExpanded,
    required this.isDragHighlight,
    this.isSelected = false,
    this.isPendingHighlight = false,
    this.onTap,
    this.onDragStart,
    this.onDragEnd,
    this.activeStudentCount = 0,
    this.countChanged = true,
    this.capacityBandStart = true,
    this.isHourStart = false,
    this.isHoverColumn = false,
    this.isHovered = false,
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

  @override
  Widget build(BuildContext context) {
    bool _isBlockActiveOnDate(StudentTimeBlock block, DateTime date) {
      final start = DateTime(
          block.startDate.year, block.startDate.month, block.startDate.day);
      final end = block.endDate != null
          ? DateTime(
              block.endDate!.year, block.endDate!.month, block.endDate!.day)
          : null;
      return !start.isAfter(date) && (end == null || !end.isBefore(date));
    }

    DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
    final weekStart = _dateOnly(weekStartDate);
    final cellDate = weekStart.add(Duration(days: dayIdx));
    final cellStartDateTime = DateTime(
      cellDate.year,
      cellDate.month,
      cellDate.day,
      startTime.hour,
      startTime.minute,
    );
    final double overlayChipWidth = (cellWidth > 0 ? cellWidth - 16 : 132.0) < 96
        ? 96
        : (cellWidth > 0 ? cellWidth - 16 : 132.0);

    return DragTarget<Map<String, dynamic>>(
      onWillAccept: (data) {
        // NOTE: 드래그 중 onWillAccept는 매우 자주 호출되므로 print는 렉 유발.
        if (data == null) return false;
        if (data['type'] == 'override-move') {
          return data['overrideId'] != null;
        }
        if (data['type'] == 'inquiry-move') {
          return data['noteId'] != null && data['oldKey'] != null;
        }
        if (data['type'] == 'move') {
          return data.containsKey('students') &&
              data.containsKey('oldDayIndex') &&
              data.containsKey('oldStartTime');
        }
        if (data['type'] == 'class-move') {
          return data.containsKey('classId') && data.containsKey('blocks');
        }
        return false;
      },
      onAccept: (data) async {
        if (data['type'] == 'override-move') {
          try {
            final overrideId = data['overrideId']?.toString() ?? '';
            if (overrideId.isEmpty) return;

            final ov = DataManager.instance.sessionOverrides
                .firstWhereOrNull((o) => o.id == overrideId);
            if (ov == null) return;
            if (ov.status == OverrideStatus.completed) {
              showAppSnackBar(context, '완료된 수업은 이동할 수 없습니다.', useRoot: true);
              return;
            }

            final updated =
                ov.copyWith(replacementClassDateTime: cellStartDateTime);
            await DataManager.instance.updateSessionOverride(updated);
          } catch (e) {
            showAppSnackBar(context, '이동 실패: $e', useRoot: true);
          }
          return;
        }

        if (data['type'] == 'inquiry-move') {
          try {
            final noteId = data['noteId']?.toString() ?? '';
            final oldKey = data['oldKey']?.toString() ?? '';
            if (noteId.isEmpty || oldKey.isEmpty) return;

            await ConsultInquiryDemandService.instance.load();
            final slots = ConsultInquiryDemandService.instance.slots
                .where((s) => s.sourceNoteId == noteId)
                .toList();
            if (slots.isEmpty) return;

            final title = slots.first.title;
            DateTime startWeek = _dateOnly(slots.first.startWeek);
            for (final s in slots) {
              final sw = _dateOnly(s.startWeek);
              if (sw.isBefore(startWeek)) startWeek = sw;
            }

            final keys = slots
                .map((s) => ConsultInquiryDemandService.slotKey(
                    s.dayIndex, s.hour, s.minute))
                .toSet();
            final newKey = ConsultInquiryDemandService.slotKey(
                dayIdx, startTime.hour, startTime.minute);
            if (newKey == oldKey) return;
            if (keys.contains(newKey)) {
              showAppSnackBar(context, '이미 선택된 희망시간입니다.', useRoot: true);
              return;
            }
            keys.remove(oldKey);
            keys.add(newKey);
            await ConsultInquiryDemandService.instance.upsertForNote(
              noteId: noteId,
              title: title,
              startWeek: startWeek,
              slotKeys: keys,
            );
          } catch (e) {
            showAppSnackBar(context, '이동 실패: $e', useRoot: true);
          }
          return;
        }

        if (data['type'] == 'move') {
          // 학생 이동 기존 로직
          final studentsRaw = (data['students'] as List);
          final students = studentsRaw
              .map((e) =>
                  e is StudentWithInfo ? e : e['student'] as StudentWithInfo)
              .toList();
          final oldDayIndex = data['oldDayIndex'] as int?;
          final oldStartTime = data['oldStartTime'] as DateTime?;
          final refDate = DateTime(cellDate.year, cellDate.month, cellDate.day);
          final range = await _pickEffectiveRange(context, refDate);
          if (range == null) return;
          final effectiveStart =
              DateTime(range.start.year, range.start.month, range.start.day);
          final effectiveEnd = range.end == null
              ? null
              : DateTime(range.end!.year, range.end!.month, range.end!.day);
          final closeDate = effectiveStart.subtract(const Duration(days: 1));
          final revertStart = effectiveEnd == null
              ? null
              : effectiveEnd.add(const Duration(days: 1));

          // 드래그 데이터에 포함된 setId/number(다중 선택 포함)
          final Map<String, String?> draggedSetIdByStudent = {};
          final Map<String, int?> draggedNumberByStudent = {};
          for (final e in studentsRaw) {
            if (e is StudentWithInfo) continue;
            final s = e['student'] as StudentWithInfo?;
            if (s == null) continue;
            draggedSetIdByStudent[s.student.id] = e['setId']?.toString();
            final n = e['number'];
            draggedNumberByStudent[s.student.id] =
                n is int ? n : int.tryParse(n?.toString() ?? '');
          }

          final ids = students.map((s) => s.student.id).join(',');
          final setIds = studentsRaw
              .map((e) => e is StudentWithInfo
                  ? 'null'
                  : (e['setId']?.toString() ?? 'null'))
              .join(',');
          // NOTE: 드래그 중 print는 렉 유발 가능(필요 시 디버그 플래그로만 출력)
          List<StudentTimeBlock> toRemove = [];
          List<StudentTimeBlock> toAdd = [];
          List<StudentWithInfo> failedStudents = [];
          for (final studentWithInfo in students) {
            if (studentWithInfo == null ||
                oldDayIndex == null ||
                oldStartTime == null) continue;
            final studentId = studentWithInfo.student.id;
            final allBlocks = DataManager.instance.studentTimeBlocks;
            final activeAtStart = allBlocks
                .where((b) => _isBlockActiveOnDate(b, effectiveStart))
                .toList();
            StudentTimeBlock? targetBlock;
            final draggedSetId = draggedSetIdByStudent[studentId];
            final draggedNum = draggedNumberByStudent[studentId];
            if (draggedSetId != null && draggedSetId.isNotEmpty) {
              final candidates = activeAtStart
                  .where((b) =>
                      b.studentId == studentId && b.setId == draggedSetId)
                  .toList()
                ..sort((a, b) => (a.number ?? 0).compareTo(b.number ?? 0));
              if (candidates.isNotEmpty) {
                if (draggedNum != null) {
                  targetBlock = candidates
                          .firstWhereOrNull((b) => b.number == draggedNum) ??
                      candidates.first;
                } else {
                  targetBlock = candidates.first;
                }
              }
            }
            targetBlock ??= activeAtStart.firstWhereOrNull(
              (b) =>
                  b.studentId == studentId &&
                  b.dayIndex == oldDayIndex &&
                  b.startHour == oldStartTime.hour &&
                  b.startMinute == oldStartTime.minute,
            );
            bool studentHasConflict = false;
            if (targetBlock == null) {
              studentHasConflict = true;
            } else if (targetBlock.setId == null ||
                targetBlock.number == null) {
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
                final activeAtRevert = allBlocks
                    .where((b) => _isBlockActiveOnDate(b, revertStart))
                    .toList();
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
              final toMove = activeAtStart
                  .where((b) => b.setId == setId && b.studentId == studentId)
                  .toList();
              toMove.sort((a, b) => a.number!.compareTo(b.number!));

              // ===== [규칙] 예약 충돌 처리 =====
              // - 임시 변경(range.start~range.end) 기간 중 "다른 세그먼트(start_date)"가 시작되면 충돌로 간주하고 이동 불가
              // - 임시 변경 종료 후(range.end+1)에는, 이미 예약된 다음 세그먼트가 있으면 원복 블록 end_date를 (다음 세그먼트 시작-1)로 자동 클리핑
              // - 종료기간 없음(end=null) 이동은, 이미 예약된 다음 세그먼트가 있으면 이동 블록 end_date를 (다음 세그먼트 시작-1)로 자동 클리핑
              final List<DateTime> segmentStarts = allBlocks
                  .where((b) => b.studentId == studentId && b.setId == setId)
                  .map((b) => DateTime(
                      b.startDate.year, b.startDate.month, b.startDate.day))
                  .toSet()
                  .toList()
                ..sort((a, b) => a.compareTo(b));

              final DateTime? nextStartAfterStart = segmentStarts
                  .firstWhereOrNull((d) => d.isAfter(effectiveStart));
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
                  : segmentStarts
                      .firstWhereOrNull((d) => d.isAfter(revertStart));
              final DateTime? clipEndAfterRevert = nextStartAfterRevert != null
                  ? nextStartAfterRevert.subtract(const Duration(days: 1))
                  : null;

              final baseTime = startTime;
              final duration = targetBlock.duration;
              final newBlocks = <StudentTimeBlock>[];
              final now = DateTime.now();
              if (!studentHasConflict)
                for (final block in toMove) {
                  final diff = block.number! - baseNumber;
                  final newTime = baseTime
                      .add(Duration(minutes: duration.inMinutes * diff));
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
                if (conflictBlock != null &&
                    !toMove.any((src) => src.id == conflictBlock.id)) {
                  studentHasConflict = true;
                  break;
                }
              }

              // 기간 변경(종료일 존재)면 원복 블록 생성: range.end+1일부터 원래 스케줄로 복귀
              if (!studentHasConflict &&
                  revertStart != null &&
                  !hasStartAtRevert) {
                final revertBlocks = <StudentTimeBlock>[];
                for (final b in toMove) {
                  DateTime? revertEnd = b.endDate;
                  if (clipEndAfterRevert != null) {
                    if (revertEnd == null ||
                        revertEnd.isAfter(clipEndAfterRevert)) {
                      revertEnd = clipEndAfterRevert;
                    }
                  }
                  if (revertEnd != null && revertEnd.isBefore(revertStart))
                    continue;
                  revertBlocks.add(b.copyWith(
                    id: const Uuid().v4(),
                    createdAt: now,
                    startDate: revertStart,
                    endDate: revertEnd,
                  ));
                }

                if (revertBlocks.isNotEmpty) {
                  final activeAtRevert = allBlocks
                      .where((b) => _isBlockActiveOnDate(b, revertStart))
                      .toList();
                  final activeRevertExcludingSource = activeAtRevert
                      .where((b) => !toMove.any((src) => src.id == b.id))
                      .toList();
                  for (final rb in revertBlocks) {
                    final conflict =
                        activeRevertExcludingSource.firstWhereOrNull((b) =>
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
          print(
              '[DRAG][drop:summary] remove=${toRemove.map((b) => b.id).toList()} add=${toAdd.map((b) => b.id).toList()} failed=${failedStudents.map((f) => f.student.id).toList()}');
          try {
            // 예약 이동: 기존 블록은 range.start - 1일로 닫아 "즉시 종료(어제)"를 방지
            await DataManager.instance.bulkDeleteStudentTimeBlocks(
              toRemove.map((b) => b.id).toList(),
              skipPlannedRegen: true,
              endDateOverride: closeDate,
            );
            await DataManager.instance.bulkAddStudentTimeBlocks(toAdd);
          } on ScheduleLockedByMakeupException catch (e) {
            if (!context.mounted) return;
            await showScheduleLockedByMakeupDialog(context, e, useRoot: true);
            return;
          } catch (e) {
            showAppSnackBar(context, '이동 실패: $e', useRoot: true);
            return;
          }
          await DataManager.instance.loadStudents();
          if (failedStudents.isNotEmpty) {
            await showDialog(
              context: context,
              builder: (context) {
                return AlertDialog(
                  backgroundColor: const Color(0xFF1F1F1F),
                  title: const Text('이동 실패 학생',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold)),
                  content: SizedBox(
                    width: 320,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('다음 학생은 이미 등록된 시간과 겹쳐 이동할 수 없습니다.',
                            style: TextStyle(
                                color: Color(0xFFB0B0B0), fontSize: 15)),
                        const SizedBox(height: 12),
                        ...failedStudents.map((s) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Text(s.student.name,
                                  style: const TextStyle(
                                      color: Color(0xFFB0B0B0), fontSize: 16)),
                            )),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('확인',
                          style: TextStyle(
                              color: Color(0xFF1976D2),
                              fontWeight: FontWeight.bold)),
                    ),
                  ],
                );
              },
            );
          }
          final timetableContentViewState =
              context.findAncestorStateOfType<TimetableContentViewState>();
          print(
              '[DEBUG][TimetableCell] timetableContentViewState != null: ${timetableContentViewState != null}');
          if (timetableContentViewState != null) {
            timetableContentViewState.updateCellStudentsAfterMove(
                dayIdx, startTime);
            print('[DEBUG][TimetableCell] exitSelectModeIfNeeded 호출 시도');
            timetableContentViewState.exitSelectModeIfNeeded();
          }
          return;
        }

        if (data['type'] == 'class-move') {
          final blocksRaw = (data['blocks'] as List).cast<Map>();
          if (blocksRaw.isEmpty) return;
          final refDate =
              DateTime(startTime.year, startTime.month, startTime.day);
          final range = await _pickEffectiveRange(context, refDate);
          if (range == null) return;
          final effectiveStart =
              DateTime(range.start.year, range.start.month, range.start.day);
          final effectiveEnd = range.end == null
              ? null
              : DateTime(range.end!.year, range.end!.month, range.end!.day);
          final closeDate = effectiveStart.subtract(const Duration(days: 1));
          final revertStart = effectiveEnd == null
              ? null
              : effectiveEnd.add(const Duration(days: 1));

          final allBlocks = DataManager.instance.studentTimeBlocks;
          final activeAtStart = allBlocks
              .where((b) => _isBlockActiveOnDate(b, effectiveStart))
              .toList();
          final sourceBlocks = blocksRaw
              .map((b) => activeAtStart
                  .firstWhereOrNull((ab) => ab.id == (b['id'] as String)))
              .whereType<StudentTimeBlock>()
              .toList();
          if (sourceBlocks.isEmpty) {
            print('[DRAG][class-move] active source blocks not found -> skip');
            return;
          }
          // 기준점 계산 (sourceBlocks 기준)
          int minTotal = 1 << 30;
          for (final b in sourceBlocks) {
            final total =
                b.dayIndex * 24 * 60 + b.startHour * 60 + b.startMinute;
            if (total < minTotal) minTotal = total;
          }
          final targetTotal =
              dayIdx * 24 * 60 + startTime.hour * 60 + startTime.minute;
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
                  .where(
                      (x) => x.studentId == b.studentId && x.setId == b.setId)
                  .map((x) => DateTime(
                      x.startDate.year, x.startDate.month, x.startDate.day))
                  .toSet()
                  .toList()
                ..sort((a, bb) => a.compareTo(bb));

              final DateTime? nextStartAfterStart = segmentStarts
                  .firstWhereOrNull((d) => d.isAfter(effectiveStart));
              clipEndAfterStart = nextStartAfterStart != null
                  ? nextStartAfterStart.subtract(const Duration(days: 1))
                  : null;

              if (effectiveEnd != null) {
                final overlapStart = segmentStarts.firstWhereOrNull((d) =>
                    d.isAfter(effectiveStart) && !d.isAfter(effectiveEnd));
                if (overlapStart != null) {
                  showAppSnackBar(
                      context, '이미 예약된 변경이 있어 기간이 겹칩니다. (setId=${b.setId})',
                      useRoot: true);
                  return;
                }
              }

              hasStartAtRevert =
                  revertStart != null && segmentStarts.contains(revertStart);
              final DateTime? nextStartAfterRevert = revertStart == null
                  ? null
                  : segmentStarts
                      .firstWhereOrNull((d) => d.isAfter(revertStart));
              clipEndAfterRevert = nextStartAfterRevert != null
                  ? nextStartAfterRevert.subtract(const Duration(days: 1))
                  : null;
            }

            final oldTotal =
                b.dayIndex * 24 * 60 + b.startHour * 60 + b.startMinute;
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
                if (revertEnd == null ||
                    revertEnd.isAfter(clipEndAfterRevert)) {
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
          final activeExcludingSource =
              activeAtStart.where((b) => !oldIds.contains(b.id)).toList();
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
            final activeAtRevert = allBlocks
                .where((b) => _isBlockActiveOnDate(b, revertStart))
                .toList();
            final activeRevertExcludingSource =
                activeAtRevert.where((b) => !oldIds.contains(b.id)).toList();
            for (final rb in revertBlocks) {
              final conflict = activeRevertExcludingSource.firstWhereOrNull(
                  (b) =>
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

          print(
              '[DRAG][class-move] remove=${oldIds.length} add=${newBlocks.length} targetDay=$dayIdx targetTime=${startTime.hour}:${startTime.minute}');
          try {
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
          } on ScheduleLockedByMakeupException catch (e) {
            if (!context.mounted) return;
            await showScheduleLockedByMakeupDialog(context, e, useRoot: true);
            return;
          } catch (e) {
            showAppSnackBar(context, '이동 실패: $e', useRoot: true);
            return;
          }
          await DataManager.instance.loadStudents();
          final timetableContentViewState =
              context.findAncestorStateOfType<TimetableContentViewState>();
          if (timetableContentViewState != null) {
            timetableContentViewState.updateCellStudentsAfterMove(
                dayIdx, startTime);
            timetableContentViewState.exitSelectModeIfNeeded();
          }
        }
      },
      builder: (context, candidateData, rejectedData) {
        final brightness = Theme.of(context).brightness;
        final panelStyle =
            FabTabBarTokens.previewAcademyPanelStyleFor(brightness);
        final ink =
            brightness == Brightness.dark ? Colors.white : Colors.black;
        final capacity = DataManager.instance.academySettings.defaultCapacity;
        final bool hasCount = !isBreakTime && activeStudentCount > 0;
        final bool isFull =
            hasCount && capacity > 0 && activeStudentCount >= capacity;
        // 인원 띠는 요일 행에서 칸 뒤에 그린다. 칸은 숫자만: 띠 시작은 밝게,
        // 띠 안에서 인원이 바뀐 곳·마우스가 올라간 칸은 흐리게.
        final Color? countColor = !hasCount
            ? null
            : capacityBandStart
                ? (isFull ? _kCapacityFullColor : panelStyle.title)
                : (countChanged || isHovered)
                    ? panelStyle.hint
                    : null;
        final bool showLeftDivider = blockIdx == 0 || isHourStart;
        final bool showSelected = isSelected && !isBreakTime;
        final Color highlight = isBreakTime
            ? Colors.transparent
            : isDragHighlight
                ? const Color(0xFF1976D2).withValues(alpha: 0.18)
                : (showSelected || isPendingHighlight)
                    // 등록모드 pending 하이라이트는 일반 셀 선택 하이라이트와 동일 색상/강도 사용
                    ? kDlgAccent.withValues(alpha: 0.12)
                    : Colors.transparent;
        return GestureDetector(
          onTap: onTap,
          child: Stack(
            children: [
              // 배경: 정시 세로선 → 호버 열 → 휴식 사선 → 선택/드래그 하이라이트
              Container(
                decoration: BoxDecoration(
                  border: Border(
                    left: showLeftDivider
                        ? BorderSide(
                            color: blockIdx == 0
                                ? panelStyle.divider
                                : panelStyle.divider.withValues(
                                    alpha: panelStyle.divider.a * 0.6),
                          )
                        : BorderSide.none,
                  ),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (isHoverColumn)
                      ColoredBox(color: ink.withValues(alpha: 0.03)),
                    if (isBreakTime)
                      CustomPaint(
                        painter: _BreakHatchPainter(
                          color: ink.withValues(alpha: 0.06),
                        ),
                      ),
                    if (highlight != Colors.transparent)
                      ColoredBox(color: highlight),
                  ],
                ),
              ),
              if (isBreakTime)
                Center(
                  child: Text(
                    '휴식',
                    style: TextStyle(
                      color: panelStyle.hint,
                      fontSize: 13,
                      fontFamily: FabTabBarTokens.previewAcademyLabelFontFamily,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (countColor != null)
                Positioned(
                  top: kTimetableBandInset + 7,
                  left: 12,
                  child: IgnorePointer(
                    child: Text(
                      '$activeStudentCount',
                      style: TextStyle(
                        color: countColor,
                        fontSize: 13,
                        fontFamily:
                            FabTabBarTokens.previewAcademyLabelFontFamily,
                        fontWeight: FontWeight.w700,
                        height: 1.0,
                        fontFeatures: const [FontFeature.tabularFigures()],
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
                    children: cellStudentWithInfos
                        .map((s) => Container(
                              width: 109,
                              height: 39,
                              margin: EdgeInsets.all(2),
                              color: Colors.grey.shade300,
                              child: Center(
                                  child: Text(s.student.name,
                                      style: TextStyle(color: Colors.black))),
                            ))
                        .toList(),
                  ),
                ),
              if (makeupOverlays.isNotEmpty ||
                  trialOverlays.isNotEmpty ||
                  inquiryOverlays.isNotEmpty)
                Positioned(
                  left: 8,
                  top: activeStudentCount > 0 ? 32 : kTimetableBandInset + 4,
                  right: 8,
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      ...makeupOverlays.map((item) {
                        final bool isReplace =
                            item.type == OverrideType.replace;
                        final Widget chip = _overlayChip(
                          width: overlayChipWidth,
                          icon: isReplace
                              ? Icons.replay_rounded
                              : Icons.add_rounded,
                          text: item.text,
                          panelStyle: panelStyle,
                          ink: ink,
                          completed: item.isCompleted,
                        );
                        // 완료된(출석 기록 완료) 항목은 이동 불가
                        if (item.isCompleted) return chip;
                        final dragData = <String, dynamic>{
                          'type': 'override-move',
                          'overrideId': item.overrideId,
                          'oldDayIndex': dayIdx,
                          'oldStartTime': cellStartDateTime,
                        };
                        return LongPressDraggable<Map<String, dynamic>>(
                          data: dragData,
                          dragAnchorStrategy: pointerDragAnchorStrategy,
                          maxSimultaneousDrags: 1,
                          hapticFeedbackOnStart: true,
                          feedback: Material(
                            color: Colors.transparent,
                            child: IgnorePointer(
                              ignoring: true,
                              child: RepaintBoundary(
                                child: SizedBox(
                                  width: overlayChipWidth,
                                  child: chip,
                                ),
                              ),
                            ),
                          ),
                          childWhenDragging:
                              Opacity(opacity: 0.45, child: chip),
                          child: chip,
                        );
                      }),
                      ...trialOverlays.map((item) {
                        final bool canTap = (onInquiryOverlayTap != null) &&
                            item.noteId.trim().isNotEmpty;
                        final Widget chip = _overlayChip(
                          width: overlayChipWidth,
                          icon: Icons.auto_awesome_rounded,
                          text: item.text,
                          panelStyle: panelStyle,
                          ink: ink,
                        );
                        if (!canTap) return chip;
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onInquiryOverlayTap?.call(item.noteId),
                          child: chip,
                        );
                      }),
                      ...inquiryOverlays.map((item) {
                        final bool canTap = (onInquiryOverlayTap != null) &&
                            item.noteId.trim().isNotEmpty;
                        final Widget chip = _overlayChip(
                          width: overlayChipWidth,
                          icon: Icons.help_outline_rounded,
                          text: item.text,
                          panelStyle: panelStyle,
                          ink: ink,
                        );
                        final Widget tappable = canTap
                            ? GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () =>
                                    onInquiryOverlayTap?.call(item.noteId),
                                child: chip,
                              )
                            : chip;
                        // noteId가 없는(레거시/비정상) 라벨은 이동 불가
                        if (item.noteId.trim().isEmpty) return tappable;
                        final dragData = <String, dynamic>{
                          'type': 'inquiry-move',
                          'noteId': item.noteId,
                          'oldKey': ConsultInquiryDemandService.slotKey(
                            dayIdx,
                            startTime.hour,
                            startTime.minute,
                          ),
                        };
                        return LongPressDraggable<Map<String, dynamic>>(
                          data: dragData,
                          dragAnchorStrategy: pointerDragAnchorStrategy,
                          maxSimultaneousDrags: 1,
                          hapticFeedbackOnStart: true,
                          feedback: Material(
                            color: Colors.transparent,
                            child: IgnorePointer(
                              ignoring: true,
                              child: RepaintBoundary(
                                child: SizedBox(
                                  width: overlayChipWidth,
                                  child: tappable,
                                ),
                              ),
                            ),
                          ),
                          childWhenDragging:
                              Opacity(opacity: 0.45, child: tappable),
                          child: tappable,
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

  /// 보강·추가수업·체험·문의 칩. 색 바탕 대신 같은 중립 캡슐에 앞 아이콘으로 구분한다.
  /// 바깥 폭은 [width] 전체를 잡아 길게 눌러 끌기 영역을 기존과 같게 유지한다.
  Widget _overlayChip({
    required double width,
    required IconData icon,
    required String text,
    required PreviewAcademyPanelStyle panelStyle,
    required Color ink,
    bool completed = false,
  }) {
    return SizedBox(
      width: width,
      child: ColoredBox(
        color: Colors.transparent,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Opacity(
            opacity: completed ? 0.45 : 1.0,
            child: Container(
              height: 27,
              padding: const EdgeInsets.fromLTRB(8, 0, 10, 0),
              decoration: BoxDecoration(
                color: ink.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: ink.withValues(alpha: 0.10)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 14, color: panelStyle.hint),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: panelStyle.title,
                        fontSize: 12.5,
                        fontFamily:
                            FabTabBarTokens.previewAcademyLabelFontFamily,
                        fontWeight: FontWeight.w600,
                        height: 1.0,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
