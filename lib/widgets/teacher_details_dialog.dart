import 'package:flutter/material.dart';
import '../models/teacher.dart';

class TeacherDetailsDialog extends StatelessWidget {
  final Teacher teacher;
  const TeacherDetailsDialog({Key? key, required this.teacher}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      title: Text(teacher.name, style: const TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('역할: ${teacher.role != null ? getTeacherRoleLabel(teacher.role) : ''}', style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            if (teacher.contact.isNotEmpty) ...[
              Text('연락처: ${teacher.contact}', style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 8),
            ],
            if (teacher.email.isNotEmpty) ...[
              Text('이메일: ${teacher.email}', style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 8),
            ],
            if (teacher.description.isNotEmpty) ...[
              Text('설명: ${teacher.description}', style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF1976D2),
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기'),
        ),
      ],
    );
  }
} 