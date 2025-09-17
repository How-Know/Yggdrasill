import 'package:flutter/material.dart';
import '../../../models/student.dart';
import '../../../models/class_info.dart';
import '../../../widgets/class_student_card.dart';
import '../../../widgets/app_snackbar.dart';

class StudentGroupView extends StatefulWidget {
  final List<ClassInfo> classes;
  final List<Student> students;
  final void Function(Student) onStudentTap;
  final void Function({
    required bool editMode,
    required ClassInfo? classInfo,
    required int? index,
  }) onClassEdit;
  final void Function(ClassInfo) onClassDelete;

  const StudentGroupView({
    super.key,
    required this.classes,
    required this.students,
    required this.onStudentTap,
    required this.onClassEdit,
    required this.onClassDelete,
  });

  @override
  State<StudentGroupView> createState() => _StudentGroupViewState();
}

class _StudentGroupViewState extends State<StudentGroupView> {
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
                showAppSnackBar(context, '${student.name}님이 ${oldClassInfo?.name ?? '미배정'} → ${classInfo.name}으로 이동되었습니다.', useRoot: true);
              },
              builder: (context, candidateData, rejectedData) {
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final double maxW = constraints.maxWidth;
                    // 기준폭: 1000에서 scale 1.0, 더 좁아지면 0.7까지 축소
                    final double scale = (maxW / 1000).clamp(0.7, 1.0);
                    // 아주 작은 화면에서는 카드 너비를 절반까지 축소
                    final bool veryNarrow = maxW < 1100;
                    final double sidePadding = 24 * scale;
                    final double gapLarge = 24 * scale;
                    final double gap = 16 * scale;
                    final double nameSize = 22 * scale;
                    final double descSize = 18 * scale;
                    final double countSize = 18 * scale;
                    final double iconSize = 24 * scale;

                    final card = Container(
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
                                height: 88 * scale,
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
                                    SizedBox(width: sidePadding),
                                    Container(
                                      width: 12 * scale,
                                      height: 40 * scale,
                                      decoration: BoxDecoration(
                                        color: classInfo.color,
                                        borderRadius: BorderRadius.circular(2 * scale),
                                      ),
                                    ),
                                    SizedBox(width: gapLarge),
                                    Expanded(
                                      child: Row(
                                        children: [
                                          Text(
                                            classInfo.name,
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: nameSize,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                          if (classInfo.description.isNotEmpty) ...[
                                            SizedBox(width: gap),
                                            Expanded(
                                              child: Text(
                                                classInfo.description,
                                                style: TextStyle(
                                                  color: Colors.white70,
                                                  fontSize: descSize,
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    SizedBox(width: 20 * scale),
                                    Text(
                                      '${studentsInClass.length}/${classInfo.capacity}명',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: countSize,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    SizedBox(width: 16 * scale),
                                    AnimatedRotation(
                                      duration: const Duration(milliseconds: 200),
                                      turns: isExpanded ? 0.5 : 0,
                                      child: Icon(
                                        Icons.expand_more,
                                        color: Colors.white70,
                                        size: iconSize,
                                      ),
                                    ),
                                    SizedBox(width: 8 * scale),
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
                                            visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
                                            minimumSize: Size(36 * scale, 36 * scale),
                                            padding: EdgeInsets.zero,
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
                                            visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
                                            minimumSize: Size(36 * scale, 36 * scale),
                                            padding: EdgeInsets.zero,
                                          ),
                                        ),
                                        ReorderableDragStartListener(
                                          index: index,
                                          child: IconButton(
                                            onPressed: () {},
                                            icon: const Icon(Icons.drag_handle_rounded),
                                            style: IconButton.styleFrom(
                                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                              minimumSize: Size(36 * scale, 36 * scale),
                                              padding: EdgeInsets.zero,
                                              foregroundColor: Colors.white70,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    SizedBox(width: 8 * scale),
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
                                      padding: EdgeInsets.fromLTRB(30 * scale, 16 * scale, 24 * scale, 16 * scale),
                                      child: Wrap(
                                        spacing: 16 * scale,
                                        runSpacing: 16 * scale,
                                        children: studentsInClass
                                            .map((student) => ClassStudentCard(
                                                  student: student,
                                                  onShowDetails: widget.onStudentTap,
                                                ))
                                            .toList(),
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

                    if (veryNarrow) {
                      return Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: 0.5,
                          child: card,
                        ),
                      );
                    }
                    return card;
                  },
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