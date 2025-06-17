import 'package:flutter/material.dart';
import '../../../models/student.dart';
import '../../../widgets/student_card.dart';

class StudentSchoolView extends StatelessWidget {
  final List<Student> students;
  final void Function(Student) onStudentTap;

  const StudentSchoolView({
    super.key,
    required this.students,
    required this.onStudentTap,
  });

  @override
  Widget build(BuildContext context) {
    // 교육과정별, 학교별로 학생들을 그룹화
    final Map<EducationLevel, Map<String, List<Student>>> groupedStudents = {
      EducationLevel.elementary: <String, List<Student>>{},
      EducationLevel.middle: <String, List<Student>>{},
      EducationLevel.high: <String, List<Student>>{},
    };

    for (final student in students) {
      final level = student.educationLevel;
      final school = student.school;
      groupedStudents[level]![school] ??= [];
      groupedStudents[level]![school]!.add(student);
    }

    // 각 교육과정 내에서 학교를 가나다순으로 정렬하고,
    // 각 학교 내에서 학생들을 이름순으로 정렬
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
              _buildEducationLevelSchoolGroup('초등', EducationLevel.elementary, groupedStudents),
              if (groupedStudents[EducationLevel.elementary]!.isNotEmpty &&
                  (groupedStudents[EducationLevel.middle]!.isNotEmpty ||
                   groupedStudents[EducationLevel.high]!.isNotEmpty))
                const Divider(color: Colors.white24, height: 48),
              _buildEducationLevelSchoolGroup('중등', EducationLevel.middle, groupedStudents),
              if (groupedStudents[EducationLevel.middle]!.isNotEmpty &&
                  groupedStudents[EducationLevel.high]!.isNotEmpty)
                const Divider(color: Colors.white24, height: 48),
              _buildEducationLevelSchoolGroup('고등', EducationLevel.high, groupedStudents),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEducationLevelSchoolGroup(
    String levelTitle,
    EducationLevel level,
    Map<EducationLevel, Map<String, List<Student>>> groupedStudents,
  ) {
    final schoolMap = groupedStudents[level]!;
    if (schoolMap.isEmpty) return const SizedBox.shrink();

    // 학교들을 가나다순으로 정렬
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
                    onShowDetails: onStudentTap,
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
} 