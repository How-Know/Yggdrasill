import 'package:flutter/material.dart';
import '../../../models/student.dart';
import '../../../widgets/student_card.dart';
import '../components/education_level_group.dart';

class AllStudentsView extends StatelessWidget {
  final List<Student> students;
  final List<ClassInfo> classes;
  final Function(Student) onEdit;
  final Function(Student) onDelete;
  final Function(Student) onShowDetails;

  const AllStudentsView({
    super.key,
    required this.students,
    required this.classes,
    required this.onEdit,
    required this.onDelete,
    required this.onShowDetails,
  });

  @override
  Widget build(BuildContext context) {
    final Map<EducationLevel, Map<int, List<Student>>> groupedStudents = {
      EducationLevel.elementary: {},
      EducationLevel.middle: {},
      EducationLevel.high: {},
    };

    for (final student in students) {
      groupedStudents[student.educationLevel]![student.grade.value] ??= [];
      groupedStudents[student.educationLevel]![student.grade.value]!.add(student);
    }

    for (final level in groupedStudents.keys) {
      for (final gradeStudents in groupedStudents[level]!.values) {
        gradeStudents.sort((a, b) => a.name.compareTo(b.name));
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final level in EducationLevel.values)
          if (groupedStudents[level]!.isNotEmpty)
            EducationLevelGroup(
              title: _getLevelTitle(level),
              level: level,
              groupedStudents: groupedStudents,
              classes: classes,
              onEdit: onEdit,
              onDelete: onDelete,
              onShowDetails: onShowDetails,
            ),
      ],
    );
  }

  String _getLevelTitle(EducationLevel level) {
    switch (level) {
      case EducationLevel.elementary:
        return '초등학생';
      case EducationLevel.middle:
        return '중학생';
      case EducationLevel.high:
        return '고등학생';
    }
  }
} 