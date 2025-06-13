import 'package:flutter/material.dart';
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
  final VoidCallback? onTap;
  final bool isSimpleLayout;

  const StudentCard({
    super.key,
    required this.student,
    required this.width,
    required this.classes,
    required this.onEdit,
    required this.onDelete,
    this.onTap,
    this.isSimpleLayout = false,
  });

  void _showMenu(BuildContext context) {
    final RenderBox button = context.findRenderObject() as RenderBox;
    final RenderBox overlay = Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
    final RelativeRect position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(Offset(button.size.width - 40, 0), ancestor: overlay),
        button.localToGlobal(button.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );

    showMenu(
      context: context,
      color: const Color(0xFF2A2A2A),
      position: position,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      items: [
        PopupMenuItem(
          child: ListTile(
            leading: const Icon(Icons.edit_outlined, color: Colors.white70),
            title: const Text(
              '수정',
              style: TextStyle(color: Colors.white),
            ),
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            onTap: () {
              Navigator.of(context).pop();
              onEdit(student);
            },
          ),
        ),
        PopupMenuItem(
          child: ListTile(
            leading: const Icon(Icons.info_outline, color: Colors.white70),
            title: const Text(
              '상세정보',
              style: TextStyle(color: Colors.white),
            ),
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            onTap: () {
              Navigator.of(context).pop();
              showDialog(
                context: context,
                builder: (context) => StudentDetailsDialog(student: student),
              );
            },
          ),
        ),
        PopupMenuItem(
          child: ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.red),
            title: const Text(
              '삭제',
              style: TextStyle(color: Colors.red),
            ),
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            onTap: () {
              Navigator.of(context).pop();
              onDelete(student);
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            showDialog(
              context: context,
              builder: (context) => StudentDetailsDialog(student: student),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            child: isSimpleLayout
                ? Row(
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
                      Expanded(
                        child: Text(
                          student.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.more_vert, color: Colors.white70),
                        splashRadius: 20,
                        padding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _showMenu(context),
                      ),
                    ],
                  )
                : Column(
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
                            _getEducationLevelName(student.educationLevel),
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
                      const SizedBox(height: 4),
                      Text(
                        student.school,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

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
} 