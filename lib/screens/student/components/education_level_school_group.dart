import 'package:flutter/material.dart';
import '../../../models/student.dart';
import '../../../widgets/student_card.dart';

class EducationLevelSchoolGroup extends StatelessWidget {
  final String levelTitle;
  final EducationLevel level;
  final Map<EducationLevel, Map<String, List<Student>>> groupedStudents;
  final List<ClassInfo> classes;
  final Function(Student) onEdit;
  final Function(Student) onDelete;
  final Function(Student) onShowDetails;

  const EducationLevelSchoolGroup({
    super.key,
    required this.levelTitle,
    required this.level,
    required this.groupedStudents,
    required this.classes,
    required this.onEdit,
    required this.onDelete,
    required this.onShowDetails,
  });

  @override
  Widget build(BuildContext context) {
    final schoolMap = groupedStudents[level]!;
    if (schoolMap.isEmpty) return const SizedBox.shrink();

    final sortedSchools = schoolMap.keys.toList()..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 16.0),
          child: Text(
            levelTitle,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ),
        for (final school in sortedSchools) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 12.0),
            child: Text(
              school,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: Colors.white70,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 24.0),
            child: Wrap(
              alignment: WrapAlignment.start,
              spacing: 16.0,
              runSpacing: 16.0,
              children: [
                for (final student in schoolMap[school]!)
                  StudentCard(
                    student: student,
                    width: 160,
                    classes: classes,
                    onEdit: onEdit,
                    onDelete: onDelete,
                    onShowDetails: onShowDetails,
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
} 