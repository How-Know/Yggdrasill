import 'package:flutter/material.dart';
import '../../../models/student.dart';
import '../../../models/education_level.dart';
import '../../../widgets/student_card.dart';
import '../../../models/group_info.dart';
import '../../../widgets/student_registration_dialog.dart';
import '../../../widgets/group_student_card.dart';
import '../../../widgets/group_registration_dialog.dart';

class AllStudentsView extends StatelessWidget {
  final List<Student> students;
  final List<GroupInfo> groups;
  final Set<GroupInfo> expandedGroups;
  final Function(Student) onShowDetails;
  final Function(GroupInfo) onGroupAdded;
  final Function(GroupInfo, int) onGroupUpdated;
  final Function(GroupInfo) onGroupDeleted;
  final Function(Student, GroupInfo?) onStudentMoved;
  final Function(GroupInfo) onGroupExpanded;
  final void Function(int oldIndex, int newIndex) onGroupReorder;

  const AllStudentsView({
    super.key,
    required this.students,
    required this.groups,
    required this.expandedGroups,
    required this.onShowDetails,
    required this.onGroupAdded,
    required this.onGroupUpdated,
    required this.onGroupDeleted,
    required this.onStudentMoved,
    required this.onGroupExpanded,
    required this.onGroupReorder,
  });

  @override
  Widget build(BuildContext context) {
    final Map<EducationLevel, Map<int, List<Student>>> groupedStudents = {
      EducationLevel.elementary: {},
      EducationLevel.middle: {},
      EducationLevel.high: {},
    };

    for (final student in students) {
      groupedStudents[student.educationLevel]![student.grade] ??= [];
      groupedStudents[student.educationLevel]![student.grade]!.add(student);
    }

    // 각 교육과정 내에서 학년별로 학생들을 정렬
    for (final level in groupedStudents.keys) {
      for (final gradeStudents in groupedStudents[level]!.values) {
        gradeStudents.sort((a, b) => a.name.compareTo(b.name));
      }
    }

    return Center(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: 24), // 왼쪽 여백
          Expanded(
            flex: 2,
            child: Container(
              width: 600,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
              decoration: BoxDecoration(
                color: Color(0xFF18181A),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildEducationLevelGroup('초등', EducationLevel.elementary, groupedStudents),
                  const Divider(color: Colors.white24, height: 48),
                  _buildEducationLevelGroup('중등', EducationLevel.middle, groupedStudents),
                  const Divider(color: Colors.white24, height: 48),
                  _buildEducationLevelGroup('고등', EducationLevel.high, groupedStudents),
                ],
              ),
            ),
          ),
          const SizedBox(width: 32),
          Expanded(
            flex: 1,
            child: Container(
              width: 400,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
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
                      const Text('클래스 목록', style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                      FilledButton.icon(
                        onPressed: () async {
                          final result = await showDialog<GroupInfo>(
                            context: context,
                            builder: (context) => GroupRegistrationDialog(
                              editMode: false,
                              onSave: (groupInfo) {
                                Navigator.of(context).pop(groupInfo);
                              },
                            ),
                          );
                          if (result != null) {
                            onGroupAdded(result);
                          }
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
                          '클래스 등록',
                          style: TextStyle(
                            fontSize: 16.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
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
                    itemCount: groups.length,
                    itemBuilder: (context, index) {
                      final groupInfo = groups[index];
                      final studentsInGroup = students.where((s) => s.groupInfo == groupInfo).toList();
                      final isExpanded = expandedGroups.contains(groupInfo);
                      return Padding(
                        key: ValueKey(groupInfo.id),
                        padding: const EdgeInsets.only(bottom: 16),
                        child: DragTarget<Student>(
                          onWillAccept: (student) => student != null,
                          onAccept: (student) {
                            final oldGroupInfo = student.groupInfo;
                            onStudentMoved(student, groupInfo);
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
                                    onStudentMoved(student, oldGroupInfo);
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
                                      onTap: () => onGroupExpanded(groupInfo),
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
                                                  onPressed: () async {
                                                    final result = await showDialog<GroupInfo>(
                                                      context: context,
                                                      builder: (context) => GroupRegistrationDialog(
                                                        editMode: true,
                                                        onSave: (updatedGroup) {
                                                          Navigator.of(context).pop(updatedGroup);
                                                        },
                                                      ),
                                                    );
                                                    if (result != null) {
                                                      onGroupUpdated(result, index);
                                                    }
                                                  },
                                                  icon: const Icon(Icons.edit_rounded),
                                                  style: IconButton.styleFrom(
                                                    foregroundColor: Colors.white70,
                                                  ),
                                                ),
                                                IconButton(
                                                  onPressed: () {
                                                    onGroupDeleted(groupInfo);
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
                                              spacing: 4,
                                              runSpacing: 8,
                                              children: studentsInGroup.map((student) => GroupStudentCard(
                                                student: student,
                                                onShowDetails: onShowDetails,
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
                    onReorder: onGroupReorder,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 24), // 오른쪽 여백
        ],
      ),
    );
  }

  Widget _buildEducationLevelGroup(
    String title,
    EducationLevel level,
    Map<EducationLevel, Map<int, List<Student>>> groupedStudents,
  ) {
    final students = groupedStudents[level]!;
    final totalCount = students.values.fold<int>(0, (sum, list) => sum + list.length);

    final List<Widget> gradeWidgets = students.entries
        .where((entry) => entry.value.isNotEmpty)
        .map<Widget>((entry) {
          final gradeStudents = entry.value;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 16, bottom: 8),
                child: Text(
                  '${entry.key}학년',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Wrap(
                spacing: 4,
                runSpacing: 8,
                children: gradeStudents.map((student) => StudentCard(
                  student: student,
                  onShowDetails: onShowDetails,
                )).toList(),
              ),
            ],
          );
        })
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '$totalCount명',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 20,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ...gradeWidgets,
      ],
    );
  }
} 