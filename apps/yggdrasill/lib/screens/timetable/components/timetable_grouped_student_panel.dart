import 'package:flutter/material.dart';

import '../../../models/education_level.dart';
import '../../../models/student.dart';
import '../../../models/student_time_block.dart';
import '../../../services/data_manager.dart';
import '../../../widgets/swipe_action_reveal.dart';
import 'student_time_info_dialog.dart';

class TimetableGroupedStudentPanel extends StatelessWidget {
  final List<StudentWithInfo> students;
  /// 셀/요일 선택 시 라벨(보강/추가수업/희망수업/시범수업) 등을 학생카드 형태로 추가 표시하기 위한 슬롯
  // hot reload 중에는 기존 인스턴스에 새 필드가 null로 남는 경우가 있어 nullable로 둔다.
  final List<Widget>? extraCards;
  /// 스와이프(수정/삭제) 액션에서 "선택한 셀 날짜" 기준으로 동작하기 위한 refDate(=date-only).
  /// null이면 스와이프 액션은 비활성화된다.
  final DateTime? refDateForActions;
  /// 학생 카드 스와이프 액션: 기간 수정
  final Future<void> Function(BuildContext context, StudentWithInfo student, StudentTimeBlock block, DateTime refDate)? onEditTimeBlock;
  /// 학생 카드 스와이프 액션: 삭제(해당 refDate부터 제거)
  final Future<void> Function(BuildContext context, StudentWithInfo student, StudentTimeBlock block, DateTime refDate)? onDeleteTimeBlock;
  final String dayTimeLabel;
  final double? maxHeight;
  final bool isSelectMode;
  final Set<String> selectedStudentIds;
  final void Function(String studentId, bool selected)? onStudentSelectChanged;
  final void Function(StudentWithInfo student)? onOpenStudentPage;
  final bool enableDrag;
  final int? dayIndex;
  final DateTime? startTime;
  final bool isClassRegisterMode;
  final VoidCallback? onDragStart;
  final VoidCallback? onDragEnd;
  // 셀 선택 시 미리 계산된 블록 정보를 우선 사용하기 위한 override 맵
  final Map<String, StudentTimeBlock>? blockOverrides;
  /// 우측 학생 리스트에서 "선택(필터)"된 학생 id (카드 테두리 하이라이트 용)
  final String? highlightedStudentId;
  /// 우측 학생 카드 탭(토글) 콜백: 탭된 학생 id 전달
  final ValueChanged<String>? onStudentCardTap;

  // 그룹핑 캐시 (학생 ID 목록 기준)
  static final Map<String, _GroupedCache> _groupCache = {};
  static int _lastStudentTimeBlocksRev = -1;
  static int _lastClassAssignRev = -1;

  const TimetableGroupedStudentPanel({
    super.key,
    required this.students,
    this.extraCards,
    this.refDateForActions,
    this.onEditTimeBlock,
    this.onDeleteTimeBlock,
    required this.dayTimeLabel,
    this.maxHeight,
    this.isSelectMode = false,
    this.selectedStudentIds = const {},
    this.onStudentSelectChanged,
    this.onOpenStudentPage,
    this.enableDrag = false,
    this.dayIndex,
    this.startTime,
    this.isClassRegisterMode = false,
    this.onDragStart,
    this.onDragEnd,
    this.blockOverrides,
    this.highlightedStudentId,
    this.onStudentCardTap,
  });

  String _levelLabel(EducationLevel level) {
    switch (level) {
      case EducationLevel.elementary:
        return '초등';
      case EducationLevel.middle:
        return '중등';
      case EducationLevel.high:
        return '고등';
    }
  }

  @override
  Widget build(BuildContext context) {
    final extras = extraCards ?? const <Widget>[];
    final stbRev = DataManager.instance.studentTimeBlocksRevision.value;
    final assignRev = DataManager.instance.classAssignmentsRevision.value;

    if (_lastStudentTimeBlocksRev != stbRev || _lastClassAssignRev != assignRev) {
      _groupCache.clear();
      _lastStudentTimeBlocksRev = stbRev;
      _lastClassAssignRev = assignRev;
    }

    final key = students.map((s) => s.student.id).toList()..sort();
    final cacheKey = key.join('|');
    final grouped = _groupCache.putIfAbsent(cacheKey, () {
      final Map<EducationLevel, Map<int, List<StudentWithInfo>>> groupedMap = {};
      for (final s in students) {
        final level = s.student.educationLevel;
        final grade = s.student.grade;
        groupedMap.putIfAbsent(level, () => {});
        groupedMap[level]!.putIfAbsent(grade, () => []);
        groupedMap[level]![grade]!.add(s);
      }
      final levels = [
        EducationLevel.elementary,
        EducationLevel.middle,
        EducationLevel.high,
      ].where((l) => groupedMap.containsKey(l)).toList();
      // 깊은 복사로 캐시 안전성 확보
      final copied = <EducationLevel, Map<int, List<StudentWithInfo>>>{};
      groupedMap.forEach((level, grades) {
        copied[level] = {};
        grades.forEach((g, list) {
          copied[level]![g] = List<StudentWithInfo>.from(list);
        });
      });
      return _GroupedCache(levels, copied);
    });

    final byLevel = grouped.byLevel;
    final sortedLevels = grouped.sortedLevels;

    const accent = Color(0xFF1B6B63);
    const levelBarColor = Color(0xFF223131);
    const levelTextColor = Color(0xFFEAF2F2);

    final bool useExpanded = maxHeight != null;

    if (students.isEmpty && extras.isEmpty) {
      Widget emptyBody() => Container(
            padding: const EdgeInsets.fromLTRB(15, 10, 12, 12),
            alignment: Alignment.center,
            constraints: BoxConstraints(minHeight: maxHeight ?? 160),
            decoration: BoxDecoration(
              color: const Color(0xFF0B1112),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: levelBarColor, width: 1),
            ),
            width: double.infinity,
            child: const Text(
              '시간을 선택하면 상세 정보가 여기에 표시됩니다.',
              style: TextStyle(color: Colors.white38, fontSize: 15, fontWeight: FontWeight.w500),
              textAlign: TextAlign.center,
            ),
          );

      Widget content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (dayTimeLabel.isNotEmpty)
            Container(
              height: 48,
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 15),
              decoration: BoxDecoration(
                color: const Color(0xFF223131),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Text(
                dayTimeLabel,
                style: const TextStyle(color: Color(0xFFEAF2F2), fontSize: 21, fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
            ),
          if (useExpanded)
            Expanded(child: emptyBody())
          else
            emptyBody(),
        ],
      );

      if (useExpanded) {
        return SizedBox(height: maxHeight, child: content);
      }
      return content;
    }

    Widget body() {
      final List<Widget> contentChildren = <Widget>[];
      if (students.isNotEmpty) {
        contentChildren.add(_buildLevels(sortedLevels, byLevel, levelBarColor, levelTextColor));
      }
      // ✅ 셀 선택 리스트에서는 보강/추가/희망/시범 카드가 하단에 정렬되어야 한다.
      if (extras.isNotEmpty) {
        if (students.isNotEmpty) {
          contentChildren.add(const SizedBox(height: 1));
        }
        // 원래 "학년 라벨"이 있던 자리 스타일로 '기타' 라벨을 추가해 시각적 간격을 맞춤
        contentChildren.add(const Padding(
          padding: EdgeInsets.only(bottom: 6, left: 14),
          child: Text(
            '기타',
            style: TextStyle(color: Color(0xFFEAF2F2), fontSize: 16, fontWeight: FontWeight.w500),
          ),
        ));
        contentChildren.add(Padding(
          padding: const EdgeInsets.only(left: 14),
          child: Wrap(
            spacing: 6.4,
            runSpacing: 6.4,
            children: extras,
          ),
        ));
      }
      return Container(
        padding: const EdgeInsets.fromLTRB(15, 10, 12, 12),
        decoration: BoxDecoration(
          color: const Color(0xFF0B1112),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: levelBarColor, width: 1),
        ),
        child: useExpanded
            ? Scrollbar(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: contentChildren,
                  ),
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: contentChildren,
              ),
      );
    }

    Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (dayTimeLabel.isNotEmpty)
          Container(
            height: 48,
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 15),
            decoration: BoxDecoration(
              color: const Color(0xFF223131),
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Text(
              dayTimeLabel,
              style: const TextStyle(color: Color(0xFFEAF2F2), fontSize: 21, fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
          ),
        if (useExpanded)
          Expanded(child: body())
        else
          body(),
      ],
    );

    if (useExpanded) {
      return SizedBox(
        height: maxHeight,
        child: content,
      );
    }
    return content;
  }

  Widget _buildLevels(
    List<EducationLevel> sortedLevels,
    Map<EducationLevel, Map<int, List<StudentWithInfo>>> byLevel,
    Color levelBarColor,
    Color levelTextColor,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...sortedLevels.map<Widget>((level) {
          final grades = byLevel[level]!;
          final levelCount = grades.values.fold<int>(0, (p, c) => p + c.length);
          final sortedGrades = grades.keys.toList()..sort();

          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      _levelLabel(level),
                      style: TextStyle(color: levelTextColor, fontSize: 21, fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                  ],
                ),
                const SizedBox(height: 12),
                ...sortedGrades.map<Widget>((g) {
                  final gradeStudents = grades[g]!..sort((a, b) => a.student.name.compareTo(b.student.name));
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6, left: 14),
                          child: Text(
                            '$g학년',
                            style: const TextStyle(color: Color(0xFFEAF2F2), fontSize: 16, fontWeight: FontWeight.w500),
                          ),
                        ),
                        Wrap(
                          spacing: 8,
                          runSpacing: 10,
                          children: gradeStudents.map<Widget>((s) {
                            final isSelected = selectedStudentIds.contains(s.student.id);
                            final isHighlighted = !isSelectMode &&
                                (highlightedStudentId ?? '').isNotEmpty &&
                                highlightedStudentId == s.student.id;
                            Color? indicatorOverride;
                          int? blockNumber;
                            final int? dIdx = dayIndex;
                            final DateTime? st = startTime;
                          final StudentTimeBlock? overrideBlock = blockOverrides?[s.student.id];
                          if (dIdx != null && st != null) {
                            if (overrideBlock != null) {
                              blockNumber = overrideBlock.number;
                              indicatorOverride = (overrideBlock.sessionTypeId != null && overrideBlock.sessionTypeId!.isNotEmpty)
                                  ? DataManager.instance.getStudentClassColorAt(
                                      s.student.id,
                                      dIdx,
                                      DateTime(0, 1, 1, st.hour, st.minute),
                                      setId: overrideBlock.setId,
                                      refDate: DateTime(st.year, st.month, st.day),
                                    )
                                  : Colors.transparent;
                            }
                            if (indicatorOverride == null) {
                              final ref = DateTime(st.year, st.month, st.day);
                              bool isActiveOn(StudentTimeBlock b) {
                                final sd = DateTime(b.startDate.year, b.startDate.month, b.startDate.day);
                                final ed = b.endDate == null ? null : DateTime(b.endDate!.year, b.endDate!.month, b.endDate!.day);
                                return !sd.isAfter(ref) && (ed == null || !ed.isBefore(ref));
                              }
                              final weekBlocks = DataManager.instance.getStudentTimeBlocksForWeek(ref);
                              final candidates = weekBlocks.where((b) =>
                                  b.studentId == s.student.id &&
                                  b.dayIndex == dIdx &&
                                  b.startHour == st.hour &&
                                  b.startMinute == st.minute &&
                                  isActiveOn(b)
                              ).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
                              final block = candidates.isNotEmpty
                                  ? candidates.first
                                  : StudentTimeBlock(
                                      id: '',
                                      studentId: '',
                                      dayIndex: 0,
                                      startHour: 0,
                                      startMinute: 0,
                                      duration: Duration.zero,
                                      createdAt: DateTime(0),
                                      startDate: DateTime(0),
                                      sessionTypeId: null,
                                      setId: null,
                                    );
                              blockNumber ??= block.number;
                              final sessionId = block.sessionTypeId;
                              if (sessionId != null && sessionId != '__default_class__') {
                                indicatorOverride = DataManager.instance.getStudentClassColorAt(
                                  s.student.id,
                                  dIdx,
                                  DateTime(0, 1, 1, st.hour, st.minute),
                                  setId: block.setId,
                                  refDate: DateTime(st.year, st.month, st.day),
                                );
                              } else {
                                // sessionTypeId 없거나 기본수업이면 색상 표시하지 않음 (fallback 방지)
                                indicatorOverride = Colors.transparent;
                              }
                            }
                          }
                            final card = Padding(
                              padding: const EdgeInsets.only(left: 14),
                              child: _PanelStudentCard(
                                student: s,
                                selected: isSelected,
                                highlighted: isHighlighted,
                                isSelectMode: isSelectMode,
                                onToggleSelect: onStudentSelectChanged == null
                                    ? null
                                    : (next) => onStudentSelectChanged!(s.student.id, next),
                                onOpenStudentPage: onOpenStudentPage,
                                onTapCard: (!isSelectMode && onStudentCardTap != null)
                                    ? () => onStudentCardTap!(s.student.id)
                                    : null,
                                indicatorColorOverride: indicatorOverride,
                              blockNumber: blockNumber,
                              ),
                            );
                            if (!enableDrag || dayIndex == null || startTime == null) return card;
                            return _DraggablePanelCard(
                              card: card,
                              student: s,
                              allStudents: students,
                              selectedStudentIds: selectedStudentIds,
                              dayIndex: dayIndex!,
                              startTime: startTime!,
                              isClassRegisterMode: isClassRegisterMode,
                              onDragStart: onDragStart,
                              onDragEnd: onDragEnd,
                              blockOverride: blockOverrides?[s.student.id],
                              enableSwipeActions: !isSelectMode &&
                                  refDateForActions != null &&
                                  (onEditTimeBlock != null || onDeleteTimeBlock != null),
                              refDateForActions: refDateForActions,
                              onEditTimeBlock: onEditTimeBlock,
                              onDeleteTimeBlock: onDeleteTimeBlock,
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          );
        }),
      ],
    );
  }
}

class _GroupedCache {
  final List<EducationLevel> sortedLevels;
  final Map<EducationLevel, Map<int, List<StudentWithInfo>>> byLevel;
  _GroupedCache(this.sortedLevels, this.byLevel);
}

class _PanelStudentCard extends StatelessWidget {
  final StudentWithInfo student;
  final bool selected;
  final bool highlighted;
  final bool isSelectMode;
  final void Function(bool next)? onToggleSelect;
  final void Function(StudentWithInfo student)? onOpenStudentPage;
  final VoidCallback? onTapCard;
  final Color? indicatorColorOverride;
  final int? blockNumber;

  const _PanelStudentCard({
    required this.student,
    this.selected = false,
    this.highlighted = false,
    this.isSelectMode = false,
    this.onToggleSelect,
    this.onOpenStudentPage,
    this.onTapCard,
    this.indicatorColorOverride,
    this.blockNumber,
  });

  @override
  Widget build(BuildContext context) {
    final nameStyle = const TextStyle(color: Color(0xFFEAF2F2), fontSize: 16, fontWeight: FontWeight.w600);
    final schoolStyle = const TextStyle(color: Colors.white60, fontSize: 13, fontWeight: FontWeight.w500);
    final schoolLabel = student.student.school.isNotEmpty ? student.student.school : '';
    // 요일/셀 선택 리스트에서는 setId/시간 기준으로 받은 색상만 사용하고,
    // override가 없으면 투명 처리하여 다른 set의 색상이 퍼지지 않게 한다.
    final Color? classColor = indicatorColorOverride;
    final Color indicatorColor = classColor ?? Colors.transparent;
    final bool showBorder = selected || highlighted;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        color: selected
            ? const Color(0xFF33A373).withOpacity(0.18)
            : const Color(0xFF15171C),
        borderRadius: BorderRadius.circular(12),
        // ✅ border 폭(=1)을 항상 유지해 하이라이트 시에도 다른 카드들이 "밀리지" 않게 한다.
        border: Border.all(
          color: showBorder ? const Color(0xFF33A373) : Colors.transparent,
          width: 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: isSelectMode && onToggleSelect != null
              ? () => onToggleSelect!(!selected)
              : (onTapCard ?? (onOpenStudentPage == null ? null : () => onOpenStudentPage!(student))),
          onDoubleTap: isSelectMode
              ? null
              : () => StudentTimeInfoDialog.show(context, student),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 28,
                  decoration: BoxDecoration(
                    color: indicatorColor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          student.student.name,
                          style: nameStyle,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                      if (blockNumber != null) ...[
                        const SizedBox(width: 10),
                        Text(
                          '${blockNumber}',
                          style: schoolStyle,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ],
                    ],
                  ),
                ),
                if (schoolLabel.isNotEmpty) ...[
                  const SizedBox(width: 10),
                  Text(
                    schoolLabel,
                    style: schoolStyle,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DraggablePanelCard extends StatelessWidget {
  final Widget card;
  final StudentWithInfo student;
  final List<StudentWithInfo> allStudents;
  final Set<String> selectedStudentIds;
  final int dayIndex;
  final DateTime startTime;
  final bool isClassRegisterMode;
  final VoidCallback? onDragStart;
  final VoidCallback? onDragEnd;
  final StudentTimeBlock? blockOverride;
  final bool enableSwipeActions;
  final DateTime? refDateForActions;
  final Future<void> Function(BuildContext context, StudentWithInfo student, StudentTimeBlock block, DateTime refDate)? onEditTimeBlock;
  final Future<void> Function(BuildContext context, StudentWithInfo student, StudentTimeBlock block, DateTime refDate)? onDeleteTimeBlock;

  const _DraggablePanelCard({
    required this.card,
    required this.student,
    required this.allStudents,
    required this.selectedStudentIds,
    required this.dayIndex,
    required this.startTime,
    required this.isClassRegisterMode,
    this.onDragStart,
    this.onDragEnd,
    this.blockOverride,
    this.enableSwipeActions = false,
    this.refDateForActions,
    this.onEditTimeBlock,
    this.onDeleteTimeBlock,
  });

  String? _findSetId(StudentWithInfo s) {
    if (blockOverride != null && blockOverride!.studentId == s.student.id) {
      return blockOverride!.setId;
    }
    final ref = refDateForActions ?? DateTime(startTime.year, startTime.month, startTime.day);
    bool isActiveOn(StudentTimeBlock b) {
      final sd = DateTime(b.startDate.year, b.startDate.month, b.startDate.day);
      final ed = b.endDate == null ? null : DateTime(b.endDate!.year, b.endDate!.month, b.endDate!.day);
      return !sd.isAfter(ref) && (ed == null || !ed.isBefore(ref));
    }
    final weekBlocks = DataManager.instance.getStudentTimeBlocksForWeek(ref);
    final candidates = weekBlocks.where((b) =>
        b.studentId == s.student.id &&
        b.dayIndex == dayIndex &&
        b.startHour == startTime.hour &&
        b.startMinute == startTime.minute &&
        isActiveOn(b)
    ).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return candidates.isEmpty ? null : candidates.first.setId;
  }

  @override
  Widget build(BuildContext context) {
    final isSelected = selectedStudentIds.contains(student.student.id);
    final selectedStudents = allStudents.where((s) => selectedStudentIds.contains(s.student.id)).toList();
    final dragStudents = (isSelected && selectedStudents.length > 1)
        ? selectedStudents.map((s) => {'student': s, 'setId': _findSetId(s)}).toList()
        : [
            {'student': student, 'setId': _findSetId(student)}
          ];
    final bool isMultiDrag = dragStudents.length > 1;

    final dragData = {
      'type': isClassRegisterMode ? 'register' : 'move',
      'students': dragStudents,
      'student': student,
      'setId': dragStudents.first['setId'],
      'oldDayIndex': dayIndex,
      'oldStartTime': startTime,
      'dayIndex': dayIndex,
      'startTime': startTime,
      'isSelfStudy': false,
    };

    final core = LongPressDraggable<Map<String, dynamic>>(
      data: dragData,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      maxSimultaneousDrags: 1,
      hapticFeedbackOnStart: true,
      // ✅ 단일 이동에서는 삭제 드롭존을 띄우지 않음(다중 이동에서만 필요)
      onDragStarted: () {
        if (isMultiDrag) onDragStart?.call();
      },
      onDragEnd: (details) {
        onDragEnd?.call();
      },
      feedback: _PanelDragFeedback(
        students: dragStudents.map((e) => e['student'] as StudentWithInfo).toList(),
        dayIndex: dayIndex,
        startTime: startTime,
      ),
      // ✅ 드래그 중 원본 카드가 투명해지면(Opacity) 스와이프 액션 패널이 비쳐 보일 수 있어
      // 원본은 그대로 보이되 입력만 막는다.
      childWhenDragging: AbsorbPointer(child: card),
      child: card,
    );

    if (!enableSwipeActions) return core;
    final ref = refDateForActions;
    final target = blockOverride;
    if (ref == null || target == null) return core;
    if (onEditTimeBlock == null && onDeleteTimeBlock == null) return core;

    const double paneW = 140;
    final radius = BorderRadius.circular(12);
    final actionPane = Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
      child: Row(
        children: [
          Expanded(
            child: Material(
              color: const Color(0xFF223131),
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                onTap: onEditTimeBlock == null ? null : () async => onEditTimeBlock!(context, student, target, ref),
                borderRadius: BorderRadius.circular(10),
                splashFactory: NoSplash.splashFactory,
                highlightColor: Colors.white.withOpacity(0.06),
                hoverColor: Colors.white.withOpacity(0.03),
                child: const SizedBox.expand(
                  child: Center(
                    child: Icon(Icons.edit_outlined, color: Color(0xFFEAF2F2), size: 18),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Material(
              color: const Color(0xFFB74C4C),
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                onTap: onDeleteTimeBlock == null ? null : () async => onDeleteTimeBlock!(context, student, target, ref),
                borderRadius: BorderRadius.circular(10),
                splashFactory: NoSplash.splashFactory,
                highlightColor: Colors.white.withOpacity(0.08),
                hoverColor: Colors.white.withOpacity(0.04),
                child: const SizedBox.expand(
                  child: Center(
                    child: Icon(Icons.delete_outline_rounded, color: Colors.white, size: 18),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    return SwipeActionReveal(
      enabled: true,
      actionPaneWidth: paneW,
      borderRadius: radius,
      actionPane: actionPane,
      child: core,
    );
  }
}

class _PanelDragFeedback extends StatelessWidget {
  final List<StudentWithInfo> students;
  final int dayIndex;
  final DateTime startTime;
  const _PanelDragFeedback({
    required this.students,
    required this.dayIndex,
    required this.startTime,
  });

  @override
  Widget build(BuildContext context) {
    final count = students.length;
    if (count <= 1) {
      return _feedbackFrame(child: _feedbackCard(students.first));
    }
    final showCount = count >= 4 ? 3 : count;
    final cards = List.generate(showCount, (i) {
      final s = students[i];
      final opacity = (0.85 - i * 0.18).clamp(0.3, 1.0);
      return Positioned(
        left: i * 12.0,
        child: Opacity(
          opacity: opacity,
          child: SizedBox(width: 140, child: _feedbackCard(s)),
        ),
      );
    }).toList();

    return _feedbackFrame(
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          ...cards,
          if (count >= 4)
            Positioned(
              right: 6,
              top: 6,
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: const Color(0xFF15171C),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF223131), width: 1),
                ),
                alignment: Alignment.center,
                child: Text(
                  '+$count',
                  style: const TextStyle(
                    color: Color(0xFFEAF2F2),
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _feedbackFrame({required Widget child}) {
    return Material(
      color: Colors.transparent,
      child: SizedBox(
        width: 150,
        height: 56,
        child: child,
      ),
    );
  }

  Widget _feedbackCard(StudentWithInfo s) {
    final groupColor = s.student.groupInfo?.color;
    Color? classColor;
    classColor = DataManager.instance.getStudentClassColorAt(
      s.student.id,
      dayIndex,
      startTime,
      refDate: DateTime(startTime.year, startTime.month, startTime.day),
    );
    classColor ??= DataManager.instance.getStudentClassColor(s.student.id);
    final Color indicatorColor = classColor ?? Colors.transparent;
    return Material(
      color: Colors.transparent,
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF15171C),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF223131), width: 1),
        ),
        child: Row(
          children: [
            Container(
              width: 5,
              height: 22,
              decoration: BoxDecoration(
                color: indicatorColor,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                s.student.name,
                style: const TextStyle(color: Color(0xFFEAF2F2), fontSize: 14, fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

