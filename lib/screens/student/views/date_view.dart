import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mneme_flutter/models/student.dart';
import 'package:mneme_flutter/widgets/student_card.dart';

class DateView extends StatelessWidget {
  final List<Student> students;
  final Function(Student) onShowDetails;

  const DateView({
    Key? key,
    required this.students,
    required this.onShowDetails,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final dateGroups = <String, List<Student>>{};
    final dateFormat = DateFormat('yyyy년 MM월');
    
    for (final student in students) {
      // registrationDate가 항상 현재시간을 반환하므로 임시로 현재시간 사용
      final registrationDate = student.registrationDate;
      final dateKey = dateFormat.format(registrationDate);
      dateGroups[dateKey] ??= [];
      dateGroups[dateKey]!.add(student);
    }

    final sortedDates = dateGroups.keys.toList()
      ..sort((a, b) => dateFormat.parse(b).compareTo(dateFormat.parse(a)));

    return Center(
      child: Container(
        width: 1000,
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
        decoration: BoxDecoration(
          color: Color(0xFF18181A),
          borderRadius: BorderRadius.circular(16),
        ),
        child: ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          itemCount: sortedDates.length,
          itemBuilder: (context, index) {
            final dateKey = sortedDates[index];
            final dateStudents = dateGroups[dateKey]!;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Text(
                    dateKey,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: dateStudents.length,
                  itemBuilder: (context, index) {
                    final student = dateStudents[index];
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
        ),
      ),
    );
  }
} 