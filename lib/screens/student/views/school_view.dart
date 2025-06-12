import 'package:flutter/material.dart';
import '../../../models/student.dart';
import '../../../widgets/student_card.dart';
import '../components/education_level_school_group.dart';

class SchoolView extends StatelessWidget {
  final List<Student> students;
  final List<ClassInfo> classes;
  final Function(Student) onEdit;
  final Function(Student) onDelete;
  final Function(Student) onShowDetails;

  const SchoolView({
    super.key,
    required this.students,
    required this.classes,
    required this.onEdit,
    required this.onDelete,
    required this.onShowDetails,
  });

  @override
  Widget build(BuildContext context) {
    final Map<EducationLevel, Map<String, List<Student>>> groupedStudents = {
      EducationLevel.elementary: <String, List<Student>>{},
      EducationLevel.middle: <String, List<Student>>{},
      EducationLevel.high: <String, List<Student>>{},
    };

    for (final student in students) {
      final level = student.educationLevel;
      final school = student.school;
      if (groupedStudents[level]![school] == null) {
        groupedStudents[level]![school] = [];
      }
      groupedStudents[level]![school]!.add(student);
    }

    for (final level in groupedStudents.keys) {
      final schoolMap = groupedStudents[level]!;
      for (final students in schoolMap.values) {
        students.sort((a, b) => a.name.compareTo(b.name));
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
              EducationLevelSchoolGroup(
                levelTitle: '초등',
                level: EducationLevel.elementary,
                groupedStudents: groupedStudents,
                classes: classes,
                onEdit: onEdit,
                onDelete: onDelete,
                onShowDetails: onShowDetails,
              ),
              if (groupedStudents[EducationLevel.elementary]!.isNotEmpty &&
                  (groupedStudents[EducationLevel.middle]!.isNotEmpty ||
                   groupedStudents[EducationLevel.high]!.isNotEmpty))
                const Divider(color: Colors.white24, height: 48),
              EducationLevelSchoolGroup(
                levelTitle: '중등',
                level: EducationLevel.middle,
                groupedStudents: groupedStudents,
                classes: classes,
                onEdit: onEdit,
                onDelete: onDelete,
                onShowDetails: onShowDetails,
              ),
              if (groupedStudents[EducationLevel.middle]!.isNotEmpty &&
                  groupedStudents[EducationLevel.high]!.isNotEmpty)
                const Divider(color: Colors.white24, height: 48),
              EducationLevelSchoolGroup(
                levelTitle: '고등',
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