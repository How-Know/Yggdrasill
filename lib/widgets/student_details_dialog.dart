import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mneme_flutter/models/student.dart';
import 'package:mneme_flutter/models/group_info.dart';
import 'package:mneme_flutter/models/education_level.dart';
import 'package:mneme_flutter/services/data_manager.dart';
import 'package:mneme_flutter/widgets/student_registration_dialog.dart';
import '../main.dart';

class StudentDetailsDialog extends StatelessWidget {
  final Student student;

  const StudentDetailsDialog({
    Key? key,
    required this.student,
  }) : super(key: key);

  String _getEducationLevelName(EducationLevel level) {
    switch (level) {
      case EducationLevel.elementary:
        return '초등';
      case EducationLevel.middle:
        return '중등';
      case EducationLevel.high:
        return '고등';
    }
  }

  String _getGradeName(Student student) {
    final grades = gradesByLevel[student.educationLevel] ?? [];
    final grade = grades.firstWhere(
      (g) => g.value == student.grade,
      orElse: () => grades.first,
    );
    return grade.name;
  }

  Future<void> _handleEdit(BuildContext context) async {
    final result = await showDialog(
      context: rootNavigatorKey.currentContext!,
      builder: (context) => StudentRegistrationDialog(
        student: student,
        onSave: (updatedStudent) async {
          await DataManager.instance.updateStudent(
            updatedStudent,
            StudentBasicInfo(studentId: updatedStudent.id, registrationDate: DateTime.now())
          );
        },
        groups: DataManager.instance.groups,
      ),
    );

    if (result is Student) {
      Future.microtask(() => Navigator.of(context).pop(true));
    }
  }

  Future<void> _handleDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('학생 삭제'),
        content: const Text('정말로 이 학생을 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await DataManager.instance.deleteStudent(student.id);
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(student.name),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('학교: ${student.school}'),
          const SizedBox(height: 8),
          Text('과정: ${_getEducationLevelName(student.educationLevel)}'),
          const SizedBox(height: 8),
          Text('학년: ${_getGradeName(student)}'),
          const SizedBox(height: 8),
          if (student.phoneNumber != null) ...[
            Text('연락처: ${student.phoneNumber}'),
            const SizedBox(height: 8),
          ],
          Text(
            '등록일: '
            + (student.registrationDate != null ? DateFormat('yyyy년 MM월 dd일').format(student.registrationDate!) : '정보 없음'),
          ),
          const SizedBox(height: 8),
          if (student.groupInfo != null)
            Text('소속 그룹: ${student.groupInfo!.name}'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Future.microtask(() => Navigator.of(context).pop(false)),
          child: const Text('닫기'),
        ),
        TextButton(
          onPressed: () => _handleEdit(context),
          child: const Text('수정'),
        ),
        FilledButton(
          onPressed: () => _handleDelete(context),
          child: const Text('삭제'),
        ),
      ],
    );
  }
} 