import 'package:flutter/material.dart';
import '../../../models/student.dart';
import '../../../widgets/student_card.dart';
import '../components/education_level_school_group.dart';

class SchoolView extends StatelessWidget {
  final List<Student> students;
  final Function(Student) onShowDetails;

  const SchoolView({
    Key? key,
    required this.students,
    required this.onShowDetails,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final schoolGroups = <String, List<Student>>{};
    
    for (final student in students) {
      schoolGroups[student.school] ??= [];
      schoolGroups[student.school]!.add(student);
    }

    final sortedSchools = schoolGroups.keys.toList()..sort();

    return ListView.builder(
      padding: const EdgeInsets.all(16.0),
      itemCount: sortedSchools.length,
      itemBuilder: (context, index) {
        final school = sortedSchools[index];
        final schoolStudents = schoolGroups[school]!;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: Text(
                school,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: schoolStudents.length,
              itemBuilder: (context, index) {
                final student = schoolStudents[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: StudentCard(
                    student: student,
                    onShowDetails: onShowDetails,
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }
} 