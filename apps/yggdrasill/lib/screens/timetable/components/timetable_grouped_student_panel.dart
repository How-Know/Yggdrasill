import 'package:flutter/material.dart';

import '../../../models/education_level.dart';
import '../../../models/student.dart';
import '../../../services/data_manager.dart';

class TimetableGroupedStudentPanel extends StatelessWidget {
  final List<StudentWithInfo> students;
  final String dayTimeLabel;
  final double? maxHeight;
  final bool isSelectMode;
  final Set<String> selectedStudentIds;
  final void Function(String studentId, bool selected)? onStudentSelectChanged;
  final void Function(StudentWithInfo student)? onOpenStudentPage;

  const TimetableGroupedStudentPanel({
    super.key,
    required this.students,
    required this.dayTimeLabel,
    this.maxHeight,
    this.isSelectMode = false,
    this.selectedStudentIds = const {},
    this.onStudentSelectChanged,
    this.onOpenStudentPage,
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
    final Map<EducationLevel, Map<int, List<StudentWithInfo>>> byLevel = {};
    for (final s in students) {
      final level = s.student.educationLevel;
      final grade = s.student.grade;
      byLevel.putIfAbsent(level, () => {});
      byLevel[level]!.putIfAbsent(grade, () => []);
      byLevel[level]![grade]!.add(s);
    }

    List<EducationLevel> sortedLevels = [
      EducationLevel.elementary,
      EducationLevel.middle,
      EducationLevel.high,
    ].where((l) => byLevel.containsKey(l)).toList();

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
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
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
            height: 48, // 주차 버튼 높이와 일치
            width: double.infinity,
            margin: const EdgeInsets.only(right: 0, bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 15),
            decoration: BoxDecoration(
              color: const Color(0xFF223131), // 배경색 변경
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Text(
              dayTimeLabel,
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
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
                            return Padding(
                              padding: const EdgeInsets.only(left: 14),
                              child: _PanelStudentCard(
                                student: s,
                                selected: isSelected,
                                isSelectMode: isSelectMode,
                                onToggleSelect: onStudentSelectChanged == null
                                    ? null
                                    : (next) => onStudentSelectChanged!(s.student.id, next),
                                onOpenStudentPage: onOpenStudentPage,
                              ),
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

class _PanelStudentCard extends StatelessWidget {
  final StudentWithInfo student;
  final bool selected;
  final bool isSelectMode;
  final void Function(bool next)? onToggleSelect;
  final void Function(StudentWithInfo student)? onOpenStudentPage;

  const _PanelStudentCard({
    required this.student,
    this.selected = false,
    this.isSelectMode = false,
    this.onToggleSelect,
    this.onOpenStudentPage,
  });

  @override
  Widget build(BuildContext context) {
    final nameStyle = const TextStyle(color: Color(0xFFEAF2F2), fontSize: 16, fontWeight: FontWeight.w600);
    final schoolStyle = const TextStyle(color: Colors.white60, fontSize: 13, fontWeight: FontWeight.w500);
    final schoolLabel = student.student.school.isNotEmpty ? student.student.school : '';
    final groupColor = student.student.groupInfo?.color;
    final hasGroupColor = groupColor != null;
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
                    color: hasGroupColor ? groupColor : Colors.transparent,
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

