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

    return SingleChildScrollView(
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(30.0, 24.0, 30.0, 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              EducationLevelGroup(
                title: '초등',
                level: EducationLevel.elementary,
                groupedStudents: groupedStudents,
                classes: classes,
                onEdit: onEdit,
                onDelete: onDelete,
                onShowDetails: onShowDetails,
              ),
              const Divider(color: Colors.white24, height: 48),
              EducationLevelGroup(
                title: '중등',
                level: EducationLevel.middle,
                groupedStudents: groupedStudents,
                classes: classes,
                onEdit: onEdit,
                onDelete: onDelete,
                onShowDetails: onShowDetails,
              ),
              const Divider(color: Colors.white24, height: 48),
              EducationLevelGroup(
                title: '고등',
                level: EducationLevel.high,
                groupedStudents: groupedStudents,
                classes: classes,
                onEdit: onEdit,
                onDelete: onDelete,
                onShowDetails: onShowDetails,
              ),
            ],
          ),
        ),
      ),
    );
  }
} 