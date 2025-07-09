import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mneme_flutter/models/student.dart';
import 'package:mneme_flutter/models/group_info.dart';
import 'package:mneme_flutter/models/education_level.dart';
import 'package:mneme_flutter/services/data_manager.dart';
import 'package:mneme_flutter/widgets/student_registration_dialog.dart';
import '../main.dart';

class StudentDetailsDialog extends StatelessWidget {
  final StudentWithInfo studentWithInfo;

  const StudentDetailsDialog({
    Key? key,
    required this.studentWithInfo,
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
        student: studentWithInfo.student,
        onSave: (updatedStudent, basicInfo) async {
          await DataManager.instance.updateStudent(updatedStudent, basicInfo);
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
      await DataManager.instance.deleteStudent(studentWithInfo.student.id);
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final student = studentWithInfo.student;
    final basicInfo = studentWithInfo.basicInfo;
    return Dialog(
      backgroundColor: const Color(0xFF1F1F1F), // 다이얼로그 배경색 변경
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 400,
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 상단: 이름, 학년, 학교, 그룹
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        student.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${_getEducationLevelName(student.educationLevel)} ${_getGradeName(student)}학년',
                        style: const TextStyle(color: Colors.white70, fontSize: 16),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        student.school,
                        style: const TextStyle(color: Colors.white54, fontSize: 15),
                      ),
                      if (student.groupInfo != null) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(Icons.group, color: student.groupInfo!.color, size: 18),
                            const SizedBox(width: 6),
                            Text(
                              student.groupInfo!.name,
                              style: TextStyle(color: student.groupInfo!.color, fontSize: 15, fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            // 중간: 정보 카드
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1F1F1F), // 정보 카드 배경색도 검정색으로 변경
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.phone, color: Colors.white38, size: 18),
                      const SizedBox(width: 8),
                      Text('연락처: ', style: TextStyle(color: Colors.white70, fontSize: 15)),
                      Text(
                        student.phoneNumber ?? basicInfo.phoneNumber ?? '정보 없음',
                        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Icon(Icons.family_restroom, color: Colors.white38, size: 18),
                      const SizedBox(width: 8),
                      Text('보호자 연락처: ', style: TextStyle(color: Colors.white70, fontSize: 15)),
                      Text(
                        basicInfo.parentPhoneNumber ?? '정보 없음',
                        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Icon(Icons.repeat, color: Colors.white38, size: 18),
                      const SizedBox(width: 8),
                      Text('수업 횟수: ', style: TextStyle(color: Colors.white70, fontSize: 15)),
                      Text(
                        '${basicInfo.weeklyClassCount}',
                        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Icon(Icons.calendar_today, color: Colors.white38, size: 18),
                      const SizedBox(width: 8),
                      Text('등록일: ', style: TextStyle(color: Colors.white70, fontSize: 15)),
                      Text(
                        DateFormat('yyyy년 MM월 dd일').format(basicInfo.registrationDate),
                        style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            Align(
              alignment: Alignment.centerRight, // 오른쪽 정렬
              child: SizedBox(
                width: 96, // 20% 감소
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1976D2), // 시그니처 색상
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)), // 라운드 크게
                    elevation: 0,
                  ),
                  child: const Text('닫기', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
} 