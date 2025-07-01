import 'package:flutter/material.dart';
import '../../../models/student.dart';
import '../../../models/education_level.dart';
import '../../../widgets/student_card.dart';
import 'package:mneme_flutter/services/data_manager.dart';

class SchoolView extends StatelessWidget {
  final List<StudentWithInfo> students;
  final Function(StudentWithInfo) onShowDetails;

  const SchoolView({
    super.key,
    required this.students,
    required this.onShowDetails,
  });

  @override
  Widget build(BuildContext context) {
    // 교육과정별, 학교별로 학생들을 그룹화
    final Map<EducationLevel, Map<String, List<StudentWithInfo>>> groupedStudents = {
      EducationLevel.elementary: <String, List<StudentWithInfo>>{},
      EducationLevel.middle: <String, List<StudentWithInfo>>{},
      EducationLevel.high: <String, List<StudentWithInfo>>{},
    };

    for (final studentWithInfo in students) {
      final level = studentWithInfo.student.educationLevel;
      final school = studentWithInfo.student.school;
      if (groupedStudents[level]![school] == null) {
        groupedStudents[level]![school] = [];
      }
      groupedStudents[level]![school]!.add(studentWithInfo);
    }

    // 각 교육과정 내에서 학교를 가나다순으로 정렬하고,
    // 각 학교 내에서 학생들을 이름순으로 정렬
    for (final level in groupedStudents.keys) {
      final schoolMap = groupedStudents[level]!;
      for (final students in schoolMap.values) {
        students.sort((a, b) => a.student.name.compareTo(b.student.name));
      }
    }

    return Center(
      child: Container(
        width: 1000,
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
        decoration: BoxDecoration(
          color: Color(0xFF18181A),
          borderRadius: BorderRadius.circular(16),
        ),
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
    );
  }

  Widget _buildEducationLevelSchoolGroup(
    String levelTitle,
    EducationLevel level,
    Map<EducationLevel, Map<String, List<StudentWithInfo>>> groupedStudents,
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
                for (final studentWithInfo in schoolMap[school]!)
                  StudentCard(
                    studentWithInfo: studentWithInfo,
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