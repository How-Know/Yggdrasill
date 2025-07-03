// TODO: 이 파일은 group_view.dart로 파일명을 변경해야 합니다.
import 'package:flutter/material.dart';
import 'package:mneme_flutter/models/student.dart';
import 'package:mneme_flutter/widgets/student_card.dart';

class GroupView extends StatelessWidget {
  final List<Student> students;
  final Function(Student) onShowDetails;

  const GroupView({
    Key? key,
    required this.students,
    required this.onShowDetails,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    print('[DEBUG] views/group_view.dart build 시작');
    print('[DEBUG] students: $students');
    final groupGroups = <String, List<Student>>{};
    
    for (final student in students) {
      if (student.groupInfo != null) {
        final groupName = student.groupInfo!.name;
        groupGroups[groupName] ??= [];
        groupGroups[groupName]!.add(student);
      }
    }
    print('[DEBUG] groupGroups: $groupGroups');

    final sortedGroups = groupGroups.keys.toList()..sort();

    return ListView.builder(
      padding: const EdgeInsets.all(16.0),
      itemCount: sortedGroups.length,
      itemBuilder: (context, index) {
        final groupName = sortedGroups[index];
        final groupStudents = groupGroups[groupName]!;
        print('[DEBUG] 그룹: $groupName, groupStudents: $groupStudents');

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: Text(
                groupName,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: groupStudents.length,
              itemBuilder: (context, index) {
                final student = groupStudents[index];
                print('[DEBUG] StudentCard 생성: $student');
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