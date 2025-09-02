import 'package:flutter/material.dart';
import '../services/data_manager.dart';
import '../models/student.dart';

class StudentGroupedListPanel extends StatefulWidget {
  final StudentWithInfo? selected;
  final ValueChanged<StudentWithInfo>? onStudentSelected;
  final double width;
  const StudentGroupedListPanel({super.key, this.selected, this.onStudentSelected, this.width = 240});

  @override
  State<StudentGroupedListPanel> createState() => _StudentGroupedListPanelState();
}

class _StudentGroupedListPanelState extends State<StudentGroupedListPanel> {
  final Map<String, bool> _isExpanded = {};

  Map<String, List<StudentWithInfo>> _groupStudentsByGrade(List<StudentWithInfo> students) {
    final Map<String, List<StudentWithInfo>> gradeGroups = {};
    for (var student in students) {
      final levelPrefix = _getEducationLevelPrefix(student.student.educationLevel);
      final grade = '$levelPrefix${student.student.grade}';
      gradeGroups.putIfAbsent(grade, () => []).add(student);
    }
    final sortedKeys = gradeGroups.keys.toList()
      ..sort((a, b) {
        final aNum = int.tryParse(a.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        final bNum = int.tryParse(b.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        const levelOrder = {'초': 1, '중': 2, '고': 3};
        final aLevel = levelOrder[a.replaceAll(RegExp(r'[0-9]'), '')] ?? 4;
        final bLevel = levelOrder[b.replaceAll(RegExp(r'[0-9]'), '')] ?? 4;
        if (aLevel != bLevel) return aLevel.compareTo(bLevel);
        return aNum.compareTo(bNum);
      });
    return {for (var key in sortedKeys) key: gradeGroups[key]!};
  }

  String _getEducationLevelPrefix(dynamic educationLevel) {
    if (educationLevel.toString().contains('elementary')) return '초';
    if (educationLevel.toString().contains('middle')) return '중';
    if (educationLevel.toString().contains('high')) return '고';
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final double w = widget.width;

    return Container(
      width: w,
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F1F),
        borderRadius: BorderRadius.circular(12),
      ),
      margin: const EdgeInsets.only(right: 16, left: 15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 18),
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text('학생 목록', style: TextStyle(color: Colors.grey, fontSize: 22, fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: ValueListenableBuilder<List<StudentWithInfo>>(
              valueListenable: DataManager.instance.studentsNotifier,
              builder: (context, students, child) {
                final gradeGroups = _groupStudentsByGrade(students);
                return ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    ...gradeGroups.entries.map((entry) {
                      final key = entry.key;
                      final isExpanded = _isExpanded[key] ?? false;
                      final list = entry.value;
                      return Container(
                        decoration: BoxDecoration(
                          color: isExpanded ? const Color(0xFF2A2A2A) : const Color(0xFF2D2D2D),
                          borderRadius: BorderRadius.circular(0),
                        ),
                        margin: const EdgeInsets.only(bottom: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            GestureDetector(
                              onTap: () {
                                setState(() {
                                  if (isExpanded) {
                                    _isExpanded[key] = false;
                                  } else {
                                    _isExpanded.clear();
                                    _isExpanded[key] = true;
                                  }
                                });
                              },
                              child: Container(
                                color: Colors.transparent,
                                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                                child: Row(
                                  children: [
                                    Text('  $key   ${list.length}명', style: const TextStyle(color: Color(0xFFB0B0B0), fontSize: 17, fontWeight: FontWeight.bold)),
                                    const Spacer(),
                                    Icon(isExpanded ? Icons.expand_less : Icons.expand_more, color: const Color(0xFFB0B0B0)),
                                  ],
                                ),
                              ),
                            ),
                            if (isExpanded)
                              ListView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: list.length,
                                itemBuilder: (context, index) {
                                  final s = list[index];
                                  final bool isSelected = widget.selected?.student.id == s.student.id;
                                  return InkWell(
                                    onTap: () => widget.onStudentSelected?.call(s),
                                    child: Container(
                                      height: 58,
                                      padding: const EdgeInsets.symmetric(horizontal: 12),
                                      decoration: BoxDecoration(
                                        border: isSelected ? Border.all(color: const Color(0xFF1976D2), width: 2) : Border.all(color: Colors.transparent, width: 2),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      alignment: Alignment.centerLeft,
                                      child: Text(s.student.name, style: const TextStyle(color: Color(0xFFE0E0E0), fontSize: 17, fontWeight: FontWeight.w500, height: 1.0)),
                                    ),
                                  );
                                },
                              ),
                          ],
                        ),
                      );
                    }).toList(),
                    const SizedBox(height: 32),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}


