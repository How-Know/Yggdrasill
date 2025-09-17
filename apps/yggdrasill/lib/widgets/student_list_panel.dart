import 'package:flutter/material.dart';
import '../services/data_manager.dart';
import '../models/student.dart';

class StudentListPanel extends StatelessWidget {
  final double? width;
  final ValueChanged<StudentWithInfo>? onStudentSelected;
  final StudentWithInfo? selected;
  const StudentListPanel({super.key, this.width, this.onStudentSelected, this.selected});

  @override
  Widget build(BuildContext context) {
    final double screenW = MediaQuery.of(context).size.width;
    const double baseWidth = 320.0;
    const double halfWidth = 160.0;
    const double minWidth = 150.0;
    double w = width ?? (screenW <= 1600 ? halfWidth : baseWidth);
    w = w < minWidth ? minWidth : w;

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
            child: Text(
              '학생 목록',
              style: TextStyle(
                color: Colors.grey,
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<List<StudentWithInfo>>(
              valueListenable: DataManager.instance.studentsNotifier,
              builder: (context, students, child) {
                final sorted = [...students]..sort((a, b) => a.student.name.compareTo(b.student.name));
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: sorted.length,
                  itemBuilder: (context, index) {
                    final s = sorted[index];
                    final bool isSelected = selected?.student.id == s.student.id;
                    return InkWell(
                      onTap: () => onStudentSelected?.call(s),
                      child: Container(
                        height: 48,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        margin: const EdgeInsets.only(bottom: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1F1F1F),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: isSelected ? const Color(0xFF1976D2) : Colors.transparent, width: 2),
                        ),
                        alignment: Alignment.centerLeft,
                        child: Text(s.student.name, style: const TextStyle(color: Colors.white70, fontSize: 16)),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}


