import 'package:flutter/material.dart';
import '../../../models/student.dart';
import '../../../models/group_info.dart';
import '../../../widgets/group_student_card.dart';
import '../../../widgets/group_registration_dialog.dart';
import '../../../services/data_manager.dart';
import '../../../main.dart';
import '../../../widgets/app_snackbar.dart';

class GroupView extends StatefulWidget {
  final List<GroupInfo> groups;
  final List<StudentWithInfo> students;
  final Set<GroupInfo> expandedGroups;
  final Function(GroupInfo) onGroupExpanded;
  final Function(GroupInfo, int) onGroupUpdated;
  final Function(GroupInfo) onGroupDeleted;
  final Function(StudentWithInfo, GroupInfo?) onStudentMoved;
  final Function(GroupInfo, int)? onGroupEdited;

  const GroupView({
    super.key,
    required this.groups,
    required this.students,
    required this.expandedGroups,
    required this.onGroupExpanded,
    required this.onGroupUpdated,
    required this.onGroupDeleted,
    required this.onStudentMoved,
    this.onGroupEdited,
  });

  @override
  State<GroupView> createState() => _GroupViewState();
}

class _GroupViewState extends State<GroupView> {
  bool _showDeleteZone = false;
  StudentWithInfo? _pendingDeleteStudent;
  late BuildContext _rootContext;

  void _handleDeleteDialog(StudentWithInfo studentWithInfo) async {
    print('[DEBUG] _handleDeleteDialog: ${studentWithInfo.student.name}');
    final student = studentWithInfo.student;
    final result = await showDialog<bool>(
      context: rootNavigatorKey.currentContext!,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF232326),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('그룹에서 삭제', style: TextStyle(color: Colors.white)),
        content: Text('${student.name} 학생을 그룹에서 삭제하시겠습니까?', style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () {
              print('[DEBUG] 다이얼로그 취소 클릭');
              Navigator.of(context).pop(false);
            },
            child: const Text('취소', style: TextStyle(color: Colors.white70)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            onPressed: () {
              print('[DEBUG] 다이얼로그 확인 클릭');
              Navigator.of(context).pop(true);
            },
            child: const Text('확인'),
          ),
        ],
      ),
    );
    print('[DEBUG] _handleDeleteDialog: dialog result = $result');
    if (result == true) {
      print('[DEBUG] _handleDeleteDialog: updateStudent 호출');
      await DataManager.instance.updateStudent(
        student.copyWith(groupInfo: null),
        studentWithInfo.basicInfo.copyWith(groupId: null),
      );
      print('[DEBUG] _handleDeleteDialog: setState 호출');
      setState(() {});
    }
    setState(() {
      _pendingDeleteStudent = null;
    });
  }

  void _onDeleteZoneAccepted(StudentWithInfo studentWithInfo) async {
    print('[DEBUG] _onDeleteZoneAccepted 진입: ${studentWithInfo.student.name}');
    final student = studentWithInfo.student;
    final prevGroupInfo = student.groupInfo;
    final prevBasicInfo = studentWithInfo.basicInfo;
    // 1. 바로 삭제
    await DataManager.instance.updateStudent(
      student.copyWith(groupInfo: null),
      studentWithInfo.basicInfo.copyWith(groupId: null),
    );
    print('[DEBUG] _onDeleteZoneAccepted: 삭제 후 setState 호출');
    setState(() {});
    // 2. 스낵바로 삭제 알림 및 실행 취소 제공
    showAppSnackBar(context, '${student.name} 학생이 삭제되었습니다.', useRoot: true);
  }

  @override
  Widget build(BuildContext context) {
    print('[DEBUG] GroupView build 시작');
    print('[DEBUG] widget.groups: ${widget.groups}');
    print('[DEBUG] widget.students: ${widget.students}');
    _rootContext = context;
    if (_pendingDeleteStudent != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          final student = _pendingDeleteStudent!.student;
          final prevGroupInfo = student.groupInfo;
          final prevBasicInfo = _pendingDeleteStudent!.basicInfo;
          // 1. 삭제
          await DataManager.instance.updateStudent(
            student.copyWith(groupInfo: null),
            prevBasicInfo.copyWith(groupId: null),
          );
          await DataManager.instance.loadStudents(); // 명시적 갱신
          setState(() {});
          // 2. 스낵바
          showAppSnackBar(context, '${student.name} 학생이 삭제되었습니다.', useRoot: true);
          setState(() {
            _pendingDeleteStudent = null;
          });
        } catch (e, st) {
          print('[ERROR] 삭제/스낵바 처리 중 예외: $e\n$st');
        }
      });
    }
    final nonNullGroups = widget.groups.where((g) => g != null).toList();
    print('[DEBUG] nonNullGroups: $nonNullGroups');
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
                child: DragTarget<StudentWithInfo>(
                  onWillAccept: (student) => true,
                  onAccept: (student) {
                    setState(() {
                      _showDeleteZone = false;
                    });
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
              itemCount: nonNullGroups.length,
              itemBuilder: (context, index) {
                final groupInfo = nonNullGroups[index];
                print('[DEBUG] 그룹카드 생성: groupInfo.id=${groupInfo.id}');
                print('[DEBUG] widget.students.length=${widget.students.length}');
                for (final s in widget.students) {
                  print('[DEBUG] 학생: name=${s.student.name}, groupInfo=\x1B[33m${s.groupInfo}\x1B[0m, groupInfo?.id=${s.groupInfo?.id}, groupId=${s.student.groupId}');
                }
                // 최신 상태 기준으로 계산하여 UI 미반영 이슈 방지
                final liveStudents = DataManager.instance.students;
                print('[DEBUG] liveStudents.length=${liveStudents.length}');
                final studentsInGroup = liveStudents.where((s) => s.groupInfo?.id == groupInfo.id).toList();
                print('[DEBUG] studentsInGroup.length=${studentsInGroup.length}');
                final isExpanded = widget.expandedGroups.contains(groupInfo);
                return Padding(
                  key: ValueKey(groupInfo),
                  padding: const EdgeInsets.only(bottom: 16),
                  child: DragTarget<StudentWithInfo>(
                    onWillAccept: (student) {
                      if (student == null) return false;
                      if (studentsInGroup.length >= (groupInfo.capacity ?? 0)) {
                        // 정원 초과 경고 다이얼로그 (비동기지만, 드롭 자체를 막기 위해 동기적으로 false 반환)
                        WidgetsBinding.instance.addPostFrameCallback((_) async {
                          await showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              backgroundColor: const Color(0xFF232326),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              title: const Text('정원 초과', style: TextStyle(color: Colors.white)),
                              content: Text('이 그룹의 정원(${groupInfo.capacity}명)이 가득 찼습니다. 더 이상 학생을 추가할 수 없습니다.', style: const TextStyle(color: Colors.white70)),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(context).pop(),
                                  child: const Text('확인', style: TextStyle(color: Colors.white70)),
                                ),
                              ],
                            ),
                          );
                        });
                        return false;
                      }
                      return true;
                    },
                    onAccept: (student) async {
                      print('[DEBUG] onAccept 진입: student=${student.student.name}, group=${groupInfo.name}');
                      // 이미 해당 그룹에 소속된 학생은 무시
                      if (student.student.groupInfo?.id == groupInfo.id) {
                        print('[DEBUG] 이미 해당 그룹에 소속된 학생: ${student.student.name}');
                        return;
                      }
                      // 반드시 UI에서 capacity 체크
                      print('[DEBUG] 현재 그룹 인원: ${studentsInGroup.length}, 정원: ${groupInfo.capacity}');
                      if (studentsInGroup.length >= (groupInfo.capacity ?? 0)) {
                        print('[DEBUG] 정원 초과 다이얼로그 진입');
                        await showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                            backgroundColor: const Color(0xFF232326),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            title: const Text('정원 초과', style: TextStyle(color: Colors.white)),
                            content: Text('이 그룹의 정원(${groupInfo.capacity}명)이 가득 찼습니다. 더 이상 학생을 추가할 수 없습니다.', style: const TextStyle(color: Colors.white70)),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(context).pop(),
                                child: const Text('확인', style: TextStyle(color: Colors.white70)),
                              ),
                            ],
                          ),
                        );
                        print('[DEBUG] 정원 초과 다이얼로그 종료');
                        return;
                      }
                      print('[DEBUG] updateStudent 호출');
                      await DataManager.instance.updateStudent(
                        student.student.copyWith(groupInfo: groupInfo, groupId: groupInfo.id),
                        student.basicInfo.copyWith(groupId: groupInfo.id),
                      );
                      print('[DEBUG] setState 호출');
                      setState(() {});
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
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    final double maxW = constraints.maxWidth;
                                    // 기준 폭: 1000에서 1.0 스케일, 좁아지면 0.82까지 축소
                                    final double scale = (maxW / 1000).clamp(0.82, 1.0);
                                    final bool compact = maxW < 720;

                                    final double sidePadding = 24 * scale;
                                    final double gapLarge = 24 * scale;
                                    final double gap = 16 * scale;
                                    final double gapSmall = 8 * scale;
                                    final double colorBarWidth = 12 * scale;
                                    final double colorBarHeight = 40 * scale;
                                    final double nameSize = 22 * scale;
                                    final double descSize = 18 * scale;
                                    final double countSize = 18 * scale;
                                    final double iconSize = 22 * scale;
                                    final double actionMin = 36 * scale;

                                    Widget trailingActions() {
                                      return FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              '${studentsInGroup.length}/${groupInfo.capacity}명',
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: countSize,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                            SizedBox(width: gapSmall),
                                            AnimatedRotation(
                                              duration: const Duration(milliseconds: 200),
                                              turns: isExpanded ? 0.5 : 0,
                                              child: Icon(
                                                Icons.expand_more,
                                                color: Colors.white70,
                                                size: iconSize,
                                              ),
                                            ),
                                            SizedBox(width: gapSmall),
                                            IconButton(
                                              onPressed: () async {
                                                print('[DEBUG] 그룹카드 수정 진입: groupInfo.id=${groupInfo.id}');
                                                await showDialog(
                                                  context: context,
                                                  builder: (context) => GroupRegistrationDialog(
                                                    editMode: true,
                                                    groupInfo: groupInfo,
                                                    index: index,
                                                    currentMemberCount: studentsInGroup.length,
                                                    onSave: (updatedGroup) {
                                                      widget.onGroupUpdated(updatedGroup, index);
                                                    },
                                                  ),
                                                );
                                              },
                                              icon: const Icon(Icons.edit_rounded),
                                              iconSize: iconSize,
                                              style: IconButton.styleFrom(
                                                visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
                                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                                minimumSize: Size(actionMin, actionMin),
                                                padding: EdgeInsets.zero,
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
                                              iconSize: iconSize,
                                              style: IconButton.styleFrom(
                                                visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
                                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                                minimumSize: Size(actionMin, actionMin),
                                                padding: EdgeInsets.zero,
                                                foregroundColor: Colors.white70,
                                              ),
                                            ),
                                            ReorderableDragStartListener(
                                              index: index,
                                              child: IconButton(
                                                onPressed: () {},
                                                icon: const Icon(Icons.drag_handle_rounded),
                                                iconSize: iconSize,
                                                style: IconButton.styleFrom(
                                                  visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
                                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                                  minimumSize: Size(actionMin, actionMin),
                                                  padding: EdgeInsets.zero,
                                                  foregroundColor: Colors.white70,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    }

                                    final Widget leading = Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        SizedBox(width: sidePadding),
                                        Container(
                                          width: colorBarWidth,
                                          height: colorBarHeight,
                                          decoration: BoxDecoration(
                                            color: groupInfo.color,
                                            borderRadius: BorderRadius.circular(2 * scale),
                                          ),
                                        ),
                                        SizedBox(width: gapLarge),
                                      ],
                                    );

                                    final Widget content = Expanded(
                                      child: compact
                                          ? Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  groupInfo.name,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontSize: nameSize,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                                if (groupInfo.description.isNotEmpty) ...[
                                                  SizedBox(height: gapSmall),
                                                  Text(
                                                    groupInfo.description,
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      color: Colors.white70,
                                                      fontSize: descSize,
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            )
                                          : Row(
                                              children: [
                                                Text(
                                                  groupInfo.name,
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontSize: nameSize,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                                if (groupInfo.description.isNotEmpty) ...[
                                                  SizedBox(width: gap),
                                                  Expanded(
                                                    child: Text(
                                                      groupInfo.description,
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
                                    );

                                    return Container(
                                      // compact에서는 높이를 내용에 맡기고, 기본에서는 미세 축소 반영
                                      padding: EdgeInsets.symmetric(vertical: compact ? 12 * scale : 14 * scale),
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
                                          leading,
                                          content,
                                          SizedBox(width: gap),
                                          trailingActions(),
                                          SizedBox(width: gapSmall),
                                        ],
                                      ),
                                    );
                                  },
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
                                          children: studentsInGroup.map((studentWithInfo) => GroupStudentCard(
                                            studentWithInfo: studentWithInfo,
                                            onShowDetails: (s) {
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