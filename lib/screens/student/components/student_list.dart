import 'package:flutter/material.dart';
import '../../../models/student.dart';
import '../../../widgets/student_card.dart';

class StudentList extends StatelessWidget {
  final List<Student> students;
  final void Function(Student) onStudentTap;

  const StudentList({
    super.key,
    required this.students,
    required this.onStudentTap,
  });

  @override
  Widget build(BuildContext context) {
    // 교육과정별, 학년별로 학생들을 그룹화
    final Map<EducationLevel, Map<int, List<Student>>> groupedStudents = {
      EducationLevel.elementary: {},
      EducationLevel.middle: {},
      EducationLevel.high: {},
    };

    for (final student in students) {
      groupedStudents[student.educationLevel]![student.grade] ??= [];
      groupedStudents[student.educationLevel]![student.grade]!.add(student);
    }

    // 각 교육과정 내에서 학년별로 학생들을 정렬
    for (final level in groupedStudents.keys) {
      for (final gradeStudents in groupedStudents[level]!.values) {
        gradeStudents.sort((a, b) => a.name.compareTo(b.name));
      }
    }

    return Padding(
      padding: const EdgeInsets.only(top: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildEducationLevelGroup('초등', EducationLevel.elementary, groupedStudents),
          const Divider(color: Colors.white24, height: 48),
          _buildEducationLevelGroup('중등', EducationLevel.middle, groupedStudents),
          const Divider(color: Colors.white24, height: 48),
          _buildEducationLevelGroup('고등', EducationLevel.high, groupedStudents),
        ],
      ),
    );
  }

  Widget _buildEducationLevelGroup(
    String title,
    EducationLevel level,
    Map<EducationLevel, Map<int, List<Student>>> groupedStudents,
  ) {
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
                  onShowDetails: onStudentTap,
                  onDelete: onStudentTap,
                )).toList(),
              ),
            ],
          );
        })
        .toList();

    return Column(
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
    );
  }
} 