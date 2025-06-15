import 'package:flutter/material.dart';
import '../../../models/student.dart';
import '../../../widgets/student_card.dart';

class EducationLevelSchoolGroup extends StatelessWidget {
  final String levelTitle;
  final EducationLevel level;
  final Map<EducationLevel, Map<String, List<Student>>> groupedStudents;
  final Function(Student) onShowDetails;

  const EducationLevelSchoolGroup({
    Key? key,
    required this.levelTitle,
    required this.level,
    required this.groupedStudents,
    required this.onShowDetails,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final schoolMap = groupedStudents[level]!;
    if (schoolMap.isEmpty) {
      return const SizedBox.shrink();
    }

    final sortedSchools = schoolMap.keys.toList()..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          levelTitle,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Colors.white,
              ),
        ),
        const SizedBox(height: 16),
        for (final school in sortedSchools) ...[
          Text(
            school,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Colors.white70,
                ),
          ),
          const SizedBox(height: 8),
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: schoolMap[school]!.length,
            itemBuilder: (context, index) {
              final student = schoolMap[school]![index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: StudentCard(
                  student: student,
                  onShowDetails: onShowDetails,
                ),
              );
            },
          ),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
} 