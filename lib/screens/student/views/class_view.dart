import 'package:flutter/material.dart';
import 'package:mneme_flutter/models/student.dart';
import 'package:mneme_flutter/widgets/student_card.dart';

class ClassView extends StatelessWidget {
  final List<Student> students;
  final Function(Student) onShowDetails;

  const ClassView({
    Key? key,
    required this.students,
    required this.onShowDetails,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final classGroups = <String, List<Student>>{};
    
    for (final student in students) {
      if (student.classInfo != null) {
        final className = student.classInfo!.name;
        classGroups[className] ??= [];
        classGroups[className]!.add(student);
      }
    }

    final sortedClasses = classGroups.keys.toList()..sort();

    return ListView.builder(
      padding: const EdgeInsets.all(16.0),
      itemCount: sortedClasses.length,
      itemBuilder: (context, index) {
        final className = sortedClasses[index];
        final classStudents = classGroups[className]!;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: Text(
                className,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: classStudents.length,
              itemBuilder: (context, index) {
                final student = classStudents[index];
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