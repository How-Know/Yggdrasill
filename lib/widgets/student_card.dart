import 'package:flutter/material.dart';
import '../models/student.dart';
import '../models/group_info.dart';
import 'student_details_dialog.dart';
import 'student_registration_dialog.dart';
import '../services/data_manager.dart';

class StudentCard extends StatelessWidget {
  final StudentWithInfo studentWithInfo;
  final VoidCallback? onTap;
  final Function(StudentWithInfo) onShowDetails;
  final Function(StudentWithInfo)? onDelete;
  final Function(StudentWithInfo)? onUpdate;

  const StudentCard({
    Key? key,
    required this.studentWithInfo,
    this.onTap,
    required this.onShowDetails,
    this.onDelete,
    this.onUpdate,
  }) : super(key: key);

  Future<void> _handleEdit(BuildContext context) async {
    final result = await showDialog<Student>(
      context: context,
      builder: (context) => StudentRegistrationDialog(
        student: studentWithInfo.student,
        onSave: (updatedStudent, basicInfo) async {
          await DataManager.instance.updateStudent(updatedStudent, basicInfo);
        },
        groups: DataManager.instance.groups,
      ),
    );
    // result는 Student만 반환되므로, 별도 후처리 필요 없음
  }

  void _showDetails(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => StudentDetailsDialog(studentWithInfo: studentWithInfo),
    );
  }

  Future<void> _handleDelete(BuildContext context) async {
    print('[DEBUG][StudentCard] _handleDelete 진입: id=${studentWithInfo.student.id}, name=${studentWithInfo.student.name}');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: const Text(
          '학생 삭제',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          '정말로 이 학생을 삭제하시겠습니까?',
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    print('[DEBUG][StudentCard] _handleDelete 다이얼로그 결과: confirmed=$confirmed');
    if (confirmed == true) {
      print('[DEBUG][StudentCard] onDelete 콜백 호출 직전');
      if (onDelete != null) {
        onDelete!(studentWithInfo);
        print('[DEBUG][StudentCard] onDelete 콜백 호출 완료');
      } else {
        print('[DEBUG][StudentCard] onDelete 콜백이 null');
      }
    }
  }

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
              _handleEdit(context);
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
              _handleDelete(context);
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final student = studentWithInfo.student;
    return _buildCardContent(context);
  }

  Widget _buildCardContent(BuildContext context) {
    final student = studentWithInfo.student;
    return Card(
      color: const Color(0xFF1F1F1F),
      margin: const EdgeInsets.symmetric(vertical: 2.0, horizontal: 4.0),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8.0),
      ),
      child: Container(
        width: 110,
        height: 50,
        padding: EdgeInsets.only(
          left: student.groupInfo == null ? 15.0 : 4.0,
          right: 4.0,
        ),
        child: SizedBox(
          width: 120,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              if (student.groupInfo != null) ...[
                Container(
                  width: 5,
                  height: 20,
                  decoration: BoxDecoration(
                    color: student.groupInfo!.color,
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
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: Colors.white54),
                color: const Color(0xFF2A2A2A),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                tooltip: '',
                onSelected: (value) async {
                  print('[DEBUG][StudentCard] PopupMenuButton onSelected: value=$value, id=${studentWithInfo.student.id}, name=${studentWithInfo.student.name}');
                  if (value == 'edit') {
                    await _handleEdit(context);
                  } else if (value == 'delete') {
                    print('[DEBUG][StudentCard] 삭제 다이얼로그 호출 직전');
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        backgroundColor: const Color(0xFF2A2A2A),
                        title: const Text('학생 삭제', style: TextStyle(color: Colors.white)),
                        content: const Text('정말로 이 학생을 삭제하시겠습니까?', style: TextStyle(color: Colors.white)),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(false),
                            child: const Text('취소'),
                          ),
                          FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: Colors.red),
                            onPressed: () => Navigator.of(context).pop(true),
                            child: const Text('삭제'),
                          ),
                        ],
                      ),
                    );
                    print('[DEBUG][StudentCard] 삭제 다이얼로그 결과: confirmed=$confirmed');
                    if (confirmed == true) {
                      print('[DEBUG][StudentCard] onDelete 콜백 호출 직전');
                      if (onDelete != null) {
                        onDelete!(studentWithInfo);
                        print('[DEBUG][StudentCard] onDelete 콜백 호출 완료');
                      } else {
                        print('[DEBUG][StudentCard] onDelete 콜백이 null');
                      }
                    }
                  } else if (value == 'details') {
                    _showDetails(context);
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'details',
                    child: ListTile(
                      leading: const Icon(Icons.info_outline, color: Colors.white70),
                      title: const Text('상세보기', style: TextStyle(color: Colors.white)),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'edit',
                    child: ListTile(
                      leading: const Icon(Icons.edit_outlined, color: Colors.white70),
                      title: const Text('수정', style: TextStyle(color: Colors.white)),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: ListTile(
                      leading: const Icon(Icons.delete_outline, color: Colors.red),
                      title: const Text('삭제', style: TextStyle(color: Colors.red)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
} 