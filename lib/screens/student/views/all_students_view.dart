import 'package:flutter/material.dart';
import '../../../models/student.dart';
import '../../../widgets/student_card.dart';
import '../components/education_level_group.dart';

class AllStudentsView extends StatelessWidget {
  final List<Student> students;
  final Function(Student) onShowDetails;

  const AllStudentsView({
    Key? key,
    required this.students,
    required this.onShowDetails,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(16.0),
      itemCount: students.length,
      itemBuilder: (context, index) {
        final student = students[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 8.0),
          child: StudentCard(
            student: student,
            onShowDetails: onShowDetails,
          ),
        );
      },
    );
  }
} 