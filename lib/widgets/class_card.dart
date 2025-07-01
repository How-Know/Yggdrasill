import 'package:flutter/material.dart';
import '../models/group_info.dart';
import '../models/student.dart';
import 'class_registration_dialog.dart';
import 'student_card.dart';

class GroupCard extends StatelessWidget {
  final GroupInfo groupInfo;
  final List<Student> students;
  final List<GroupInfo> groups;
  final Function(GroupInfo, int) onEdit;
  final Function(String) onDelete;
  final Function(Student, GroupInfo?) onStudentMove;
  final Function(Student) onStudentEdit;
  final Function(Student) onStudentDelete;

  const GroupCard({
    super.key,
    required this.groupInfo,
    required this.students,
    required this.groups,
    required this.onEdit,
    required this.onDelete,
    required this.onStudentMove,
    required this.onStudentEdit,
    required this.onStudentDelete,
  });

  @override
  Widget build(BuildContext context) {
    final groupStudents = students.where((s) => s.groupInfo?.id == groupInfo.id).toList();
    return DragTarget<Student>(
      onWillAccept: (student) => student != null && student.groupInfo?.id != groupInfo.id,
      onAccept: (student) {
        final oldGroupInfo = student.groupInfo;
        onStudentMove(student, groupInfo);
        // 변경 알림 표시
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${student.name}님이 ${oldGroupInfo?.name ?? '미배정'} → ${groupInfo.name}으로 이동되었습니다.',
            ),
            backgroundColor: const Color(0xFF2A2A2A),
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: '실행 취소',
              onPressed: () {
                onStudentMove(student, oldGroupInfo);
              },
            ),
          ),
        );
      },
      builder: (context, candidateData, rejectedData) {
        return Card(
          color: const Color(0xFF2A2A2A),
          child: Theme(
            data: Theme.of(context).copyWith(
              dividerColor: Colors.transparent,
              expansionTileTheme: ExpansionTileThemeData(
                iconColor: Colors.white70,
                collapsedIconColor: Colors.white70,
              ),
            ),
            child: ExpansionTile(
              title: Row(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: groupInfo.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    groupInfo.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${groupStudents.length}/${groupInfo.capacity}명',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.edit_rounded,
                      color: Colors.white70,
                      size: 20,
                    ),
                    onPressed: () async {
                      final result = await showDialog<GroupInfo>(
                        context: context,
                        builder: (context) => GroupRegistrationDialog(
                          editMode: true,
                          groupInfo: groupInfo,
                        ),
                      );
                      if (result != null) {
                        onEdit(result, groups.indexWhere((g) => g.id == groupInfo.id));
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.delete_rounded,
                      color: Colors.white70,
                      size: 20,
                    ),
                    onPressed: () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          backgroundColor: const Color(0xFF1F1F1F),
                          title: const Text(
                            '그룹 삭제',
                            style: TextStyle(color: Colors.white),
                          ),
                          content: Text(
                            '${groupInfo.name} 그룹을 삭제하시겠습니까?\n소속된 학생들의 그룹 정보도 삭제됩니다.',
                            style: const TextStyle(color: Colors.white),
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
                              child: const Text('삭제'),
                            ),
                          ],
                        ),
                      );

                      if (confirmed == true) {
                        onDelete(groupInfo.id);
                      }
                    },
                  ),
                ],
              ),
              children: [
                Container(
                  color: const Color(0xFF1F1F1F),
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  child: Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    alignment: WrapAlignment.start,
                    children: groupStudents
                        .map((student) => StudentCard(
                              student: student,
                              groups: groups,
                              onEdit: onStudentEdit,
                              onDelete: onStudentDelete,
                            ))
                        .toList(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
} 