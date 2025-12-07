import 'package:flutter/material.dart';

import '../../../models/education_level.dart';
import '../../../models/student.dart';
import '../../../models/student_time_block.dart';
import '../../../services/data_manager.dart';

class TimetableGroupedStudentPanel extends StatelessWidget {
  final List<StudentWithInfo> students;
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

  // 그룹핑 캐시 (학생 ID 목록 기준)
  static final Map<String, _GroupedCache> _groupCache = {};
  static int _lastStudentTimeBlocksRev = -1;
  static int _lastClassAssignRev = -1;

  const TimetableGroupedStudentPanel({
    super.key,
    required this.students,
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

    if (students.isEmpty) {
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
                  child: _buildLevels(sortedLevels, byLevel, levelBarColor, levelTextColor),
                ),
              )
            : _buildLevels(sortedLevels, byLevel, levelBarColor, levelTextColor),
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
                    Container(
                            width: 5,
                      height: 22,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        color: levelBarColor,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
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
                            Color? indicatorOverride;
                            final int? dIdx = dayIndex;
                            final DateTime? st = startTime;
                            if (dIdx != null && st != null) {
                              final block = DataManager.instance.studentTimeBlocks.firstWhere(
                                (b) =>
                                    b.studentId == s.student.id &&
                                    b.dayIndex == dIdx &&
                                    b.startHour == st.hour &&
                                    b.startMinute == st.minute,
                                orElse: () => StudentTimeBlock(
                                  id: '',
                                  studentId: '',
                                  dayIndex: 0,
                                  startHour: 0,
                                  startMinute: 0,
                                  duration: Duration.zero,
                                  createdAt: DateTime(0),
                                  sessionTypeId: null,
                                  setId: null,
                                ),
                              );
                              final sessionId = block.sessionTypeId;
                              if (sessionId != null && sessionId != '__default_class__') {
                                indicatorOverride = DataManager.instance.getStudentClassColorAt(
                                  s.student.id,
                                  dIdx,
                                  DateTime(0, 1, 1, st.hour, st.minute),
                                  setId: block.setId,
                                );
                              } else {
                                // sessionTypeId 없거나 기본수업이면 색상 표시하지 않음 (fallback 방지)
                                indicatorOverride = Colors.transparent;
                              }
                            }
                            final card = Padding(
                              padding: const EdgeInsets.only(left: 14),
                              child: _PanelStudentCard(
                                student: s,
                                selected: isSelected,
                                isSelectMode: isSelectMode,
                                onToggleSelect: onStudentSelectChanged == null
                                    ? null
                                    : (next) => onStudentSelectChanged!(s.student.id, next),
                                onOpenStudentPage: onOpenStudentPage,
                                indicatorColorOverride: indicatorOverride,
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
  final bool isSelectMode;
  final void Function(bool next)? onToggleSelect;
  final void Function(StudentWithInfo student)? onOpenStudentPage;
  final Color? indicatorColorOverride;

  const _PanelStudentCard({
    required this.student,
    this.selected = false,
    this.isSelectMode = false,
    this.onToggleSelect,
    this.onOpenStudentPage,
    this.indicatorColorOverride,
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
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        color: selected ? const Color(0xFF33A373).withOpacity(0.18) : const Color(0xFF15171C),
        borderRadius: BorderRadius.circular(12),
        border: selected ? Border.all(color: const Color(0xFF33A373), width: 1) : Border.all(color: Colors.transparent, width: 1),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            if (isSelectMode && onToggleSelect != null) {
              onToggleSelect!(!selected);
            } else if (!isSelectMode && onOpenStudentPage != null) {
              onOpenStudentPage!(student);
            }
          },
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
                  child: Text(
                    student.student.name,
                    style: nameStyle,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
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
  });

  String? _findSetId(StudentWithInfo s) {
    final block = DataManager.instance.studentTimeBlocks.firstWhere(
      (b) => b.studentId == s.student.id && b.dayIndex == dayIndex && b.startHour == startTime.hour && b.startMinute == startTime.minute,
      orElse: () => StudentTimeBlock(id: '', studentId: '', dayIndex: 0, startHour: 0, startMinute: 0, duration: Duration.zero, createdAt: DateTime(0)),
    );
    return block.id.isEmpty ? null : block.setId;
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

    return Draggable<Map<String, dynamic>>(
      data: dragData,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      maxSimultaneousDrags: 1,
      onDragStarted: onDragStart,
      onDragEnd: (details) {
        onDragEnd?.call();
      },
      feedback: _PanelDragFeedback(
        students: dragStudents.map((e) => e['student'] as StudentWithInfo).toList(),
        dayIndex: dayIndex,
        startTime: startTime,
      ),
      childWhenDragging: Opacity(
        opacity: 0.3,
        child: card,
      ),
      child: card,
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
    classColor = DataManager.instance.getStudentClassColorAt(s.student.id, dayIndex, startTime);
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

