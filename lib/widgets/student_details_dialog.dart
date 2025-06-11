import 'package:flutter/material.dart';
import '../models/student.dart';

class StudentDetailsDialog extends StatelessWidget {
  final Student student;

  const StudentDetailsDialog({
    super.key,
    required this.student,
  });

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 16,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1F1F1F),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(
          student.name,
          style: const TextStyle(color: Colors.white),
        ),
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_rounded,
            color: Colors.white,
            size: 32,
            weight: 700,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDetailRow('과정', getEducationLevelName(student.educationLevel)),
            _buildDetailRow('학년', student.grade.name),
            _buildDetailRow('학교', student.school),
            _buildDetailRow('클래스', student.classInfo?.name ?? '미소속'),
            _buildDetailRow('연락처', student.phoneNumber),
            _buildDetailRow('부모님 연락처', student.parentPhoneNumber),
            _buildDetailRow(
              '등록일',
              '${student.registrationDate.year}년 ${student.registrationDate.month}월 ${student.registrationDate.day}일',
            ),
          ],
        ),
      ),
    );
  }
} 