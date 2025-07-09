import 'package:flutter/material.dart';
import '../models/student.dart';
import '../models/group_info.dart';
import '../models/education_level.dart';
import '../services/data_manager.dart';

class GroupStudentCard extends StatelessWidget {
  final StudentWithInfo studentWithInfo;
  final double? width;
  final Function(StudentWithInfo)? onDragStarted;
  final VoidCallback? onDragEnd;
  final Function(StudentWithInfo) onShowDetails;
  final Function(StudentWithInfo)? onDelete;

  const GroupStudentCard({
    Key? key,
    required this.studentWithInfo,
    this.width,
    this.onDragStarted,
    this.onDragEnd,
    required this.onShowDetails,
    this.onDelete,
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
        color: const Color(0xFF1F1F1F),
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
                    studentWithInfo.student.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      studentWithInfo.student.school,
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
                    _getEducationLevelName(studentWithInfo.student.educationLevel),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _getGradeName(studentWithInfo.student),
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
    return Draggable<StudentWithInfo>(
      data: studentWithInfo,
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
          onDragStarted!(studentWithInfo);
        }
      },
      onDragEnd: (_) {
        if (onDragEnd != null) {
          onDragEnd!();
        }
      },
      child: Material(
        color: Colors.transparent,
        child: _buildCardContent(isOriginal: true),
      ),
    );
  }
} 