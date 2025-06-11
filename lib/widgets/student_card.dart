import 'package:flutter/material.dart';
import 'package:animations/animations.dart';
import '../models/student.dart';
import '../models/class_info.dart';
import 'student_details_dialog.dart';
import 'student_registration_dialog.dart';

class StudentCard extends StatelessWidget {
  final Student student;
  final double width;
  final List<ClassInfo> classes;
  final Function(Student) onEdit;
  final Function(Student) onDelete;

  const StudentCard({
    super.key,
    required this.student,
    required this.width,
    required this.classes,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Draggable<Student>(
      data: student,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          width: 280,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF2A2A2A).withOpacity(0.8),
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                student.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    getEducationLevelName(student.educationLevel),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    student.grade.name,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.5,
        child: _buildStudentCardContent(context),
      ),
      child: _buildStudentCardContent(context),
    );
  }

  Widget _buildStudentCardContent(BuildContext context) {
    return OpenContainer(
      transitionType: ContainerTransitionType.fade,
      openBuilder: (context, _) => StudentDetailsDialog(student: student),
      closedShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
      closedColor: const Color(0xFF333333),
      closedElevation: 0,
      closedBuilder: (context, openContainer) => Container(
        width: width,
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        student.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Text(
                            getEducationLevelName(student.educationLevel),
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            student.grade.name,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(
                    Icons.more_vert,
                    color: Colors.white70,
                  ),
                  color: const Color(0xFF2A2A2A),
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'edit',
                      child: Row(
                        children: [
                          const Icon(
                            Icons.edit_rounded,
                            color: Colors.white70,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            '수정',
                            style: TextStyle(
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          const Icon(
                            Icons.delete_rounded,
                            color: Colors.red,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            '삭제',
                            style: TextStyle(
                              color: Colors.red,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  onSelected: (value) async {
                    if (value == 'edit') {
                      final result = await showDialog<Student>(
                        context: context,
                        builder: (context) => StudentRegistrationDialog(
                          editMode: true,
                          editingStudent: student,
                          classes: classes,
                        ),
                      );
                      if (result != null) {
                        onEdit(result);
                      }
                    } else if (value == 'delete') {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          backgroundColor: const Color(0xFF1F1F1F),
                          title: const Text(
                            '학생 퇴원',
                            style: TextStyle(color: Colors.white),
                          ),
                          content: const Text(
                            '삭제된 파일은 복구가 불가능합니다.\n퇴원시키겠습니까?',
                            style: TextStyle(color: Colors.white),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(false),
                              child: const Text(
                                '취소',
                                style: TextStyle(color: Colors.white70),
                              ),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.of(context).pop(true),
                              style: FilledButton.styleFrom(
                                backgroundColor: Colors.red,
                              ),
                              child: const Text('퇴원'),
                            ),
                          ],
                        ),
                      );

                      if (confirmed == true) {
                        onDelete(student);
                      }
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    student.school,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (student.classInfo != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: student.classInfo!.color.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      student.classInfo!.name,
                      style: TextStyle(
                        color: student.classInfo!.color,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
} 