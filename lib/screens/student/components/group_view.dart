import 'package:flutter/material.dart';
import '../../../models/student.dart';
import '../../../models/group_info.dart';
import '../../../widgets/group_student_card.dart';
import '../../../widgets/group_registration_dialog.dart';
import '../../../services/data_manager.dart';

class GroupView extends StatefulWidget {
  final List<GroupInfo> groups;
  final List<Student> students;
  final Set<GroupInfo> expandedGroups;
  final Function(GroupInfo) onGroupExpanded;
  final Function(GroupInfo, int) onGroupUpdated;
  final Function(GroupInfo) onGroupDeleted;
  final Function(Student, GroupInfo?) onStudentMoved;

  const GroupView({
    super.key,
    required this.groups,
    required this.students,
    required this.expandedGroups,
    required this.onGroupExpanded,
    required this.onGroupUpdated,
    required this.onGroupDeleted,
    required this.onStudentMoved,
  });

  @override
  State<GroupView> createState() => _GroupViewState();
}

class _GroupViewState extends State<GroupView> {
  bool _showDeleteZone = false;

  void _onDeleteZoneAccepted(Student student) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF232326),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('그룹에서 삭제', style: TextStyle(color: Colors.white)),
        content: Text('${student.name} 학생을 그룹에서 삭제하시겠습니까?', style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('취소', style: TextStyle(color: Colors.white70)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('확인'),
          ),
        ],
      ),
    );
    if (result == true) {
      widget.onStudentMoved(student, null);
      await DataManager.instance.updateStudent(student.copyWith(groupInfo: null));
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 1000,
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
        decoration: BoxDecoration(
          color: Color(0xFF18181A),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('그룹 목록', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                FilledButton.icon(
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => GroupRegistrationDialog(
                        editMode: false,
                        onSave: (groupInfo) {
                          // 그룹 추가 로직 (상위에서 콜백으로 받아야 할 경우 수정 필요)
                        },
                      ),
                    );
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1976D2),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                    minimumSize: const Size(0, 44),
                    maximumSize: const Size(double.infinity, 44),
                  ),
                  icon: const Icon(Icons.add, size: 26),
                  label: const Text(
                    '그룹 등록',
                    style: TextStyle(
                      fontSize: 16.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            if (_showDeleteZone)
              Padding(
                padding: const EdgeInsets.only(bottom: 16.0, top: 12.0),
                child: DragTarget<Student>(
                  onWillAccept: (student) => true,
                  onAccept: (student) {
                    _onDeleteZoneAccepted(student);
                  },
                  builder: (context, candidateData, rejectedData) {
                    final isHover = candidateData.isNotEmpty;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: double.infinity,
                      height: 72,
                      decoration: BoxDecoration(
                        color: Colors.grey[900],
                        border: Border.all(
                          color: isHover ? Colors.red : Colors.grey[700]!,
                          width: isHover ? 3 : 2,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Center(
                        child: Icon(
                          Icons.delete_outline,
                          color: isHover ? Colors.red : Colors.white70,
                          size: 36,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ReorderableListView.builder(
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
              itemCount: widget.groups.length,
              itemBuilder: (context, index) {
                final groupInfo = widget.groups[index];
                final studentsInGroup = widget.students.where((s) => s.groupInfo == groupInfo).toList();
                final isExpanded = widget.expandedGroups.contains(groupInfo);
                return Padding(
                  key: ValueKey(groupInfo),
                  padding: const EdgeInsets.only(bottom: 16),
                  child: DragTarget<Student>(
                    onWillAccept: (student) => student != null,
                    onAccept: (student) {
                      final oldGroupInfo = student.groupInfo;
                      widget.onStudentMoved(student, groupInfo);
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
                              widget.onStudentMoved(student, oldGroupInfo);
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
                                  color: groupInfo.color,
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
                                onTap: () => widget.onGroupExpanded(groupInfo),
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
                                          color: groupInfo.color,
                                          borderRadius: BorderRadius.circular(2),
                                        ),
                                      ),
                                      const SizedBox(width: 24),
                                      Expanded(
                                        child: Row(
                                          children: [
                                            Text(
                                              groupInfo.name,
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 22,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                            if (groupInfo.description.isNotEmpty) ...[
                                              const SizedBox(width: 16),
                                              Expanded(
                                                child: Text(
                                                  groupInfo.description,
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
                                        '${studentsInGroup.length}/${groupInfo.capacity}명',
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
                                              // TODO: 그룹 수정 다이얼로그 표시
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
                                                      '${groupInfo.name} 삭제',
                                                      style: const TextStyle(color: Colors.white),
                                                    ),
                                                    content: const Text(
                                                      '정말로 이 그룹을 삭제하시겠습니까?',
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
                                                          widget.onGroupDeleted(groupInfo);
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
                              secondChild: studentsInGroup.isNotEmpty
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
                                          children: studentsInGroup.map((student) => GroupStudentCard(
                                            student: student,
                                            onShowDetails: (student) {
                                              // TODO: 학생 상세 정보 다이얼로그 표시
                                            },
                                            onDragStarted: (s) => setState(() => _showDeleteZone = true),
                                            onDragEnd: () => setState(() => _showDeleteZone = false),
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
                if (newIndex > oldIndex) newIndex--;
                final item = widget.groups.removeAt(oldIndex);
                widget.groups.insert(newIndex, item);
              },
            ),
          ],
        ),
      ),
    );
  }
} 