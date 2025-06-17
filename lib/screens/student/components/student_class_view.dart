import 'package:flutter/material.dart';
import '../../../models/student.dart';
import '../../../models/class_info.dart';
import '../../../widgets/class_student_card.dart';

class StudentClassView extends StatefulWidget {
  final List<ClassInfo> classes;
  final List<Student> students;
  final void Function(Student) onStudentTap;
  final void Function({
    required bool editMode,
    required ClassInfo? classInfo,
    required int? index,
  }) onClassEdit;
  final void Function(ClassInfo) onClassDelete;

  const StudentClassView({
    super.key,
    required this.classes,
    required this.students,
    required this.onStudentTap,
    required this.onClassEdit,
    required this.onClassDelete,
  });

  @override
  State<StudentClassView> createState() => _StudentClassViewState();
}

class _StudentClassViewState extends State<StudentClassView> {
  final Set<ClassInfo> _expandedClasses = {};

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 24.0),
      child: ReorderableListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        padding: EdgeInsets.zero,
        proxyDecorator: (child, index, animation) {
          return AnimatedBuilder(
            animation: animation,
            builder: (BuildContext context, Widget? child) {
              return Material(
                color: Colors.transparent,
                child: child,
              );
            },
            child: child,
          );
        },
        itemCount: widget.classes.length,
        itemBuilder: (context, index) {
          final classInfo = widget.classes[index];
          final studentsInClass = widget.students.where((s) => s.classInfo == classInfo).toList();
          final isExpanded = _expandedClasses.contains(classInfo);
          
          return Padding(
            key: ValueKey(classInfo),
            padding: const EdgeInsets.only(bottom: 16),
            child: DragTarget<Student>(
              onWillAccept: (student) => student != null,
              onAccept: (student) {
                final oldClassInfo = student.classInfo;
                setState(() {
                  final index = widget.students.indexOf(student);
                  if (index != -1) {
                    widget.students[index] = student.copyWith(classInfo: classInfo);
                  }
                });
                
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
                        setState(() {
                          final index = widget.students.indexOf(student);
                          if (index != -1) {
                            widget.students[index] = student.copyWith(classInfo: oldClassInfo);
                          }
                        });
                      },
                    ),
                  ),
                );
              },
              builder: (context, candidateData, rejectedData) {
                return Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF121212),
                    borderRadius: BorderRadius.circular(12),
                    border: candidateData.isNotEmpty
                      ? Border.all(
                          color: classInfo.color,
                          width: 2,
                        )
                      : null,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Material(
                        color: Colors.transparent,
                        borderRadius: candidateData.isNotEmpty
                          ? const BorderRadius.vertical(
                              top: Radius.circular(10),
                              bottom: Radius.zero,
                            )
                          : BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: candidateData.isNotEmpty
                            ? const BorderRadius.vertical(
                                top: Radius.circular(10),
                                bottom: Radius.zero,
                              )
                            : BorderRadius.circular(12),
                          onTap: () {
                            setState(() {
                              if (isExpanded) {
                                _expandedClasses.remove(classInfo);
                              } else {
                                _expandedClasses.add(classInfo);
                              }
                            });
                          },
                          child: Container(
                            height: 88,
                            decoration: BoxDecoration(
                              color: const Color(0xFF121212),
                              borderRadius: candidateData.isNotEmpty
                                ? const BorderRadius.vertical(
                                    top: Radius.circular(10),
                                    bottom: Radius.zero,
                                  )
                                : BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                const SizedBox(width: 24),
                                Container(
                                  width: 12,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: classInfo.color,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                                const SizedBox(width: 24),
                                Expanded(
                                  child: Row(
                                    children: [
                                      Text(
                                        classInfo.name,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 22,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      if (classInfo.description.isNotEmpty) ...[
                                        const SizedBox(width: 16),
                                        Expanded(
                                          child: Text(
                                            classInfo.description,
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 18,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 20),
                                Text(
                                  '${studentsInClass.length}/${classInfo.capacity}명',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                AnimatedRotation(
                                  duration: const Duration(milliseconds: 200),
                                  turns: isExpanded ? 0.5 : 0,
                                  child: const Icon(
                                    Icons.expand_more,
                                    color: Colors.white70,
                                    size: 24,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      onPressed: () {
                                        widget.onClassEdit(
                                          editMode: true,
                                          classInfo: classInfo,
                                          index: index,
                                        );
                                      },
                                      icon: const Icon(Icons.edit_rounded),
                                      style: IconButton.styleFrom(
                                        foregroundColor: Colors.white70,
                                      ),
                                    ),
                                    IconButton(
                                      onPressed: () {
                                        showDialog(
                                          context: context,
                                          builder: (BuildContext context) {
                                            return AlertDialog(
                                              backgroundColor: const Color(0xFF1F1F1F),
                                              title: Text(
                                                '${classInfo.name} 삭제',
                                                style: const TextStyle(color: Colors.white),
                                              ),
                                              content: const Text(
                                                '정말로 이 클래스를 삭제하시겠습니까?',
                                                style: TextStyle(color: Colors.white),
                                              ),
                                              actions: [
                                                TextButton(
                                                  onPressed: () {
                                                    Navigator.of(context).pop();
                                                  },
                                                  child: const Text(
                                                    '취소',
                                                    style: TextStyle(color: Colors.white70),
                                                  ),
                                                ),
                                                TextButton(
                                                  onPressed: () {
                                                    widget.onClassDelete(classInfo);
                                                    Navigator.of(context).pop();
                                                  },
                                                  child: const Text(
                                                    '삭제',
                                                    style: TextStyle(
                                                      color: Colors.red,
                                                      fontWeight: FontWeight.bold,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            );
                                          },
                                        );
                                      },
                                      icon: const Icon(Icons.delete_rounded),
                                      style: IconButton.styleFrom(
                                        foregroundColor: Colors.white70,
                                      ),
                                    ),
                                    ReorderableDragStartListener(
                                      index: index,
                                      child: IconButton(
                                        onPressed: () {},
                                        icon: const Icon(Icons.drag_handle_rounded),
                                        style: IconButton.styleFrom(
                                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          minimumSize: const Size(40, 40),
                                          padding: EdgeInsets.zero,
                                          foregroundColor: Colors.white70,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(width: 8),
                              ],
                            ),
                          ),
                        ),
                      ),
                      AnimatedCrossFade(
                        firstChild: const SizedBox.shrink(),
                        secondChild: studentsInClass.isNotEmpty
                          ? Container(
                              decoration: BoxDecoration(
                                color: const Color(0xFF121212),
                                borderRadius: candidateData.isNotEmpty
                                  ? const BorderRadius.vertical(
                                      top: Radius.zero,
                                      bottom: Radius.circular(10),
                                    )
                                  : BorderRadius.circular(12),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(30, 16, 24, 16),
                                child: Wrap(
                                  spacing: 16,
                                  runSpacing: 16,
                                  children: studentsInClass.map((student) => ClassStudentCard(
                                    student: student,
                                    onShowDetails: widget.onStudentTap,
                                  )).toList(),
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                        crossFadeState: isExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                        duration: const Duration(milliseconds: 200),
                      ),
                    ],
                  ),
                );
              },
            ),
          );
        },
        onReorder: (oldIndex, newIndex) {
          setState(() {
            if (newIndex > oldIndex) {
              newIndex -= 1;
            }
            final ClassInfo item = widget.classes.removeAt(oldIndex);
            widget.classes.insert(newIndex, item);
          });
        },
      ),
    );
  }
} 