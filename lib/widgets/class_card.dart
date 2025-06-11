import 'package:flutter/material.dart';
import '../models/class_info.dart';
import '../models/student.dart';
import 'class_registration_dialog.dart';
import 'student_card.dart';

class ClassCard extends StatelessWidget {
  final ClassInfo classInfo;
  final List<Student> students;
  final List<ClassInfo> classes;
  final Function(ClassInfo, int) onEdit;
  final Function(String) onDelete;
  final Function(Student, ClassInfo?) onStudentMove;
  final Function(Student) onStudentEdit;
  final Function(Student) onStudentDelete;

  const ClassCard({
    super.key,
    required this.classInfo,
    required this.students,
    required this.classes,
    required this.onEdit,
    required this.onDelete,
    required this.onStudentMove,
    required this.onStudentEdit,
    required this.onStudentDelete,
  });

  @override
  Widget build(BuildContext context) {
    final classStudents = students.where((s) => s.classInfo?.id == classInfo.id).toList();
    return DragTarget<Student>(
      onWillAccept: (student) => student != null && student.classInfo?.id != classInfo.id,
      onAccept: (student) {
        final oldClassInfo = student.classInfo;
        onStudentMove(student, classInfo);
        // 변경 알림 표시
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${student.name}님이 ${oldClassInfo?.name ?? '미배정'} → ${classInfo.name}으로 이동되었습니다.',
            ),
            backgroundColor: const Color(0xFF2A2A2A),
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: '실행 취소',
              onPressed: () {
                onStudentMove(student, oldClassInfo);
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
                      color: classInfo.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    classInfo.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${classStudents.length}/${classInfo.capacity}명',
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
                      final result = await showDialog<ClassInfo>(
                        context: context,
                        builder: (context) => ClassRegistrationDialog(
                          editMode: true,
                          classInfo: classInfo,
                        ),
                      );
                      if (result != null) {
                        onEdit(result, classes.indexWhere((c) => c.id == classInfo.id));
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
                            '클래스 삭제',
                            style: TextStyle(color: Colors.white),
                          ),
                          content: Text(
                            '${classInfo.name} 클래스를 삭제하시겠습니까?\n소속된 학생들의 클래스 정보도 삭제됩니다.',
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
                        onDelete(classInfo.id);
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
                    children: classStudents
                        .map((student) => StudentCard(
                              student: student,
                              width: 280,
                              classes: classes,
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