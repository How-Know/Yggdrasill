import 'package:flutter/material.dart';
import '../../../models/student.dart';
import '../../../models/group_info.dart';
import '../../../widgets/student_card.dart';

class EducationLevelGroup extends StatelessWidget {
  final String title;
  final EducationLevel level;
  final Map<EducationLevel, Map<int, List<Student>>> groupedStudents;
  final List<GroupInfo> classes;
  final Function(Student) onEdit;
  final Function(Student) onDelete;
  final Function(Student) onShowDetails;

  const EducationLevelGroup({
    super.key,
    required this.title,
    required this.level,
    required this.groupedStudents,
    required this.classes,
    required this.onEdit,
    required this.onDelete,
    required this.onShowDetails,
  });

  @override
  Widget build(BuildContext context) {
    final students = groupedStudents[level]!;
    final totalCount = students.values.fold<int>(0, (sum, list) => sum + list.length);

    final List<Widget> gradeWidgets = students.entries
        .where((entry) => entry.value.isNotEmpty)
        .map<Widget>((entry) {
          final gradeStudents = entry.value;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 16, bottom: 8),
                child: Text(
                  '${entry.key}학년',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Wrap(
                spacing: 16,
                runSpacing: 16,
                children: gradeStudents.map((student) => StudentCard(
                  student: student,
                  onShowDetails: onShowDetails,
                )).toList(),
              ),
            ],
          );
        })
        .toList();

    return Padding(
      padding: const EdgeInsets.only(bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '$totalCount명',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 20,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ...gradeWidgets,
        ],
      ),
    );
  }
} 