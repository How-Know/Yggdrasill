import 'package:flutter/material.dart';
import '../models/student.dart';
import '../models/class_info.dart';
import 'student_details_dialog.dart';
import 'student_registration_dialog.dart';

class StudentCard extends StatelessWidget {
  final Student student;
  final VoidCallback? onTap;
  final Function(Student) onShowDetails;

  const StudentCard({
    Key? key,
    required this.student,
    this.onTap,
    required this.onShowDetails,
  }) : super(key: key);

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
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF2A2A2A),
      margin: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 8.0),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8.0),
      ),
      child: InkWell(
        onTap: () => onShowDetails(student),
        child: Container(
          width: 120,
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 12.0),
          child: SizedBox(
            width: 120,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                if (student.classInfo != null) ...[
                  Container(
                    width: 5,
                    height: 20,
                    decoration: BoxDecoration(
                      color: student.classInfo!.color,
                      borderRadius: BorderRadius.circular(2.5),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Text(
                  student.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(
                    Icons.more_vert,
                    color: Colors.white70,
                    size: 20,
                  ),
                  onPressed: () => _showMenu(context),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  splashRadius: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
} 