import 'package:flutter/material.dart';
import '../models/student.dart';

class StudentDetailsDialog extends StatelessWidget {
  final Student student;

  const StudentDetailsDialog({
    super.key,
    required this.student,
  });

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
    return Dialog(
      backgroundColor: const Color(0xFF2A2A2A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Container(
        width: 400,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (student.classInfo != null) ...[
                  Container(
                    width: 4,
                    height: 24,
                    decoration: BoxDecoration(
                      color: student.classInfo!.color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Text(
                  student.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            _buildDetailRow('학교', student.school),
            _buildDetailRow('과정', _getEducationLevelName(student.educationLevel)),
            _buildDetailRow('학년', '${student.grade.value}학년'),
            if (student.classInfo != null)
              _buildDetailRow('소속 반', student.classInfo!.name),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                ),
                child: const Text('닫기'),
              ),
            ),
          ],
        ),
      ),
    );
  }
} 