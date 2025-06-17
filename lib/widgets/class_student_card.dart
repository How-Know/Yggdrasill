import 'package:flutter/material.dart';
import '../models/student.dart';
import '../models/class_info.dart';
import '../models/education_level.dart';

class ClassStudentCard extends StatelessWidget {
  final Student student;
  final double? width;
  final Function(Student)? onDragStarted;
  final Function(Student) onShowDetails;

  const ClassStudentCard({
    Key? key,
    required this.student,
    this.width,
    this.onDragStarted,
    required this.onShowDetails,
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

  Widget _buildCardContent({bool isOriginal = false}) {
    return Container(
      width: 160,
      height: 80,
      decoration: BoxDecoration(
        color: isOriginal ? const Color(0xFF1F1F1F) : const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(12),
        boxShadow: isOriginal ? null : [
          BoxShadow(
            color: Colors.black.withOpacity(0.2),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 160,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    student.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      student.school,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: 160,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _getEducationLevelName(student.educationLevel),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _getGradeName(student),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Draggable<Student>(
      data: student,
      feedback: Material(
        color: Colors.transparent,
        child: _buildCardContent(isOriginal: false),
      ),
      childWhenDragging: Opacity(
        opacity: 0.3,
        child: _buildCardContent(isOriginal: true),
      ),
      onDragStarted: () {
        if (onDragStarted != null) {
          onDragStarted!(student);
        }
      },
      child: Material(
        color: Colors.transparent,
        child: _buildCardContent(isOriginal: true),
      ),
    );
  }
} 