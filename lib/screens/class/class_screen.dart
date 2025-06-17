import 'package:flutter/material.dart';
import '../../models/class_info.dart';
import '../../models/student.dart';
import '../../services/data_manager.dart';
import '../../widgets/class_registration_dialog.dart';

class ClassScreen extends StatefulWidget {
  const ClassScreen({Key? key}) : super(key: key);

  @override
  State<ClassScreen> createState() => _ClassScreenState();
}

class _ClassScreenState extends State<ClassScreen> {
  final List<ClassInfo> _classes = [];
  final List<Student> _students = [];
  final Set<ClassInfo> _expandedClasses = {};

  @override
  void initState() {
    super.initState();
    _initializeData();
  }

  Future<void> _initializeData() async {
    await DataManager.instance.initialize();
    setState(() {
      _classes.clear();
      _classes.addAll(DataManager.instance.classes);
      _students.clear();
      _students.addAll(DataManager.instance.students);
    });
  }

  void _showClassRegistrationDialog({
    bool editMode = false,
    ClassInfo? classInfo,
    int? index,
  }) {
    showDialog(
      context: context,
      builder: (context) => ClassRegistrationDialog(
        editMode: editMode,
        classInfo: classInfo,
        onSave: (result) {
          setState(() {
            if (editMode && index != null) {
              _classes[index] = result;

              // 해당 클래스에 속한 학생들의 클래스 정보도 업데이트
              for (var i = 0; i < _students.length; i++) {
                if (_students[i].classInfo?.id == result.id) {
                  _students[i] = _students[i].copyWith(classInfo: result);
                }
              }
            } else {
              _classes.add(result);
            }
          });
        },
      ),
    );
  }

  Widget _buildClassView() {
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
        itemCount: _classes.length,
        itemBuilder: (context, index) {
          final classInfo = _classes[index];
          final studentsInClass = _students.where((s) => s.classInfo == classInfo).toList();
          final isExpanded = _expandedClasses.contains(classInfo);
          
          return Padding(
            key: ValueKey(classInfo),
            padding: const EdgeInsets.only(bottom: 16),
            child: DragTarget<Student>(
              onWillAccept: (student) => student != null,
              onAccept: (student) {
                final oldClassInfo = student.classInfo;
                setState(() {
                  final index = _students.indexOf(student);
                  if (index != -1) {
                    _students[index] = student.copyWith(classInfo: classInfo);
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
                          final index = _students.indexOf(student);
                          if (index != -1) {
                            _students[index] = student.copyWith(classInfo: oldClassInfo);
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
                                        _showClassRegistrationDialog(
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
                                                    setState(() {
                                                      _classes.removeAt(index);
                                                      DataManager.instance.deleteClass(classInfo);
                                                    });
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
                                        onPressed: null,
                                        icon: const Icon(Icons.drag_handle_rounded),
                                        style: IconButton.styleFrom(
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
                      if (isExpanded)
                        Container(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '소속 학생',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 16),
                              if (studentsInClass.isEmpty)
                                const Text(
                                  '아직 소속된 학생이 없습니다.',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 16,
                                  ),
                                )
                              else
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: studentsInClass.map((student) {
                                    return Draggable<Student>(
                                      data: student,
                                      feedback: Material(
                                        color: Colors.transparent,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 16,
                                            vertical: 8,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF2A2A2A),
                                            borderRadius: BorderRadius.circular(8),
                                          ),
                                          child: Text(
                                            student.name,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 16,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                      ),
                                      childWhenDragging: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF2A2A2A).withOpacity(0.5),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          student.name,
                                          style: const TextStyle(
                                            color: Colors.white54,
                                            fontSize: 16,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF2A2A2A),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Text(
                                          student.name,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 16,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                ),
                            ],
                          ),
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
            if (oldIndex < newIndex) {
              newIndex -= 1;
            }
            final ClassInfo item = _classes.removeAt(oldIndex);
            _classes.insert(newIndex, item);
          });
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '클래스 관리',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: () => _showClassRegistrationDialog(),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('클래스 추가'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF42A5F5),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 16,
                      ),
                    ),
                  ),
                ],
              ),
              _buildClassView(),
            ],
          ),
        ),
      ),
    );
  }
} 