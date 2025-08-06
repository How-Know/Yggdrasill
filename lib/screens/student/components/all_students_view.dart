import 'package:flutter/material.dart';
import '../../../models/student.dart';
import '../../../models/education_level.dart';
import '../../../widgets/student_card.dart';
import '../../../models/group_info.dart';
import '../../../widgets/student_registration_dialog.dart';
import '../../../widgets/group_student_card.dart';
import '../../../widgets/group_registration_dialog.dart';
import '../../../services/data_manager.dart';
import '../../../widgets/app_snackbar.dart';
import '../../../widgets/student_filter_dialog.dart';

class AllStudentsView extends StatefulWidget {
  final List<StudentWithInfo> students;
  final List<GroupInfo> groups;
  final Set<GroupInfo> expandedGroups;
  final Function(StudentWithInfo) onShowDetails;
  final Function(GroupInfo) onGroupAdded;
  final Function(GroupInfo, int) onGroupUpdated;
  final Function(GroupInfo) onGroupDeleted;
  final Function(StudentWithInfo, GroupInfo?) onStudentMoved;
  final Function(GroupInfo) onGroupExpanded;
  final void Function(int oldIndex, int newIndex) onReorder;
  final Function(StudentWithInfo) onDeleteStudent;
  final Function(StudentWithInfo) onStudentUpdated;
  final Map<String, Set<String>>? activeFilter;
  final Function(Map<String, Set<String>>?) onFilterChanged;

  const AllStudentsView({
    Key? key,
    required this.students,
    required this.groups,
    required this.expandedGroups,
    required this.onShowDetails,
    required this.onGroupAdded,
    required this.onGroupUpdated,
    required this.onGroupDeleted,
    required this.onStudentMoved,
    required this.onGroupExpanded,
    required this.onReorder,
    required this.onDeleteStudent,
    required this.onStudentUpdated,
    this.activeFilter,
    required this.onFilterChanged,
  }) : super(key: key);

  @override
  State<AllStudentsView> createState() => _AllStudentsViewState();
}

class _AllStudentsViewState extends State<AllStudentsView> {
  bool _showDeleteZone = false;

  List<StudentWithInfo> _applyFilter(List<StudentWithInfo> students) {
    if (widget.activeFilter == null) {
      print('[DEBUG] 필터 없음, 전체 학생 반환: ${students.length}명');
      return students;
    }
    
    print('[DEBUG] 필터 적용 시작: ${widget.activeFilter}');
    
    final filteredStudents = students.where((studentWithInfo) {
      final student = studentWithInfo.student;
      final filter = widget.activeFilter!;
      
      // 학년별 필터
      final educationLevels = filter['educationLevels'] ?? <String>{};
      final grades = filter['grades'] ?? <String>{};
      
      print('[DEBUG] 학생: ${student.name}, 학년: ${student.grade}, 학교: ${student.school}, 그룹: ${student.groupInfo?.name}');
      
      if (educationLevels.isNotEmpty || grades.isNotEmpty) {
        String? studentEducationLevel;
        switch (student.educationLevel) {
          case EducationLevel.elementary:
            studentEducationLevel = '초등';
            break;
          case EducationLevel.middle:
            studentEducationLevel = '중등';
            break;
          case EducationLevel.high:
            studentEducationLevel = '고등';
            break;
        }
        
        bool matchesEducationLevel = educationLevels.isEmpty || 
          (studentEducationLevel != null && educationLevels.contains(studentEducationLevel));
        bool matchesGrade = grades.isEmpty || grades.contains(student.grade);
        
        print('[DEBUG] 학년 필터 - 교육단계: $studentEducationLevel, 매치: $matchesEducationLevel, 학년매치: $matchesGrade');
        
        if (!matchesEducationLevel || !matchesGrade) {
          print('[DEBUG] 학년 필터로 제외: ${student.name}');
          return false;
        }
      }
      
      // 학교 필터
      final schools = filter['schools'] ?? <String>{};
      if (schools.isNotEmpty && !schools.contains(student.school)) {
        print('[DEBUG] 학교 필터로 제외: ${student.name} (${student.school})');
        return false;
      }
      
      // 그룹 필터
      final groups = filter['groups'] ?? <String>{};
      if (groups.isNotEmpty) {
        final studentGroupName = student.groupInfo?.name;
        if (studentGroupName == null || !groups.contains(studentGroupName)) {
          print('[DEBUG] 그룹 필터로 제외: ${student.name} (${studentGroupName})');
          return false;
        }
      }
      
      print('[DEBUG] 필터 통과: ${student.name}');
      return true;
    }).toList();
    
    print('[DEBUG] 필터 적용 완료: ${students.length}명 -> ${filteredStudents.length}명');
    return filteredStudents;
  }

  @override
  Widget build(BuildContext context) {
    // 정렬 데이터 준비
    final filteredStudents = _applyFilter(widget.students);
    final students = filteredStudents;
    final Map<EducationLevel, Map<int, List<StudentWithInfo>>> groupedByGrade = {
      EducationLevel.elementary: {},
      EducationLevel.middle: {},
      EducationLevel.high: {},
    };
    final Map<EducationLevel, Map<String, List<StudentWithInfo>>> groupedBySchool = {
      EducationLevel.elementary: {},
      EducationLevel.middle: {},
      EducationLevel.high: {},
    };
    for (final studentWithInfo in students) {
      final student = studentWithInfo.student;
      // 학년별
      groupedByGrade[student.educationLevel]![student.grade] ??= [];
      groupedByGrade[student.educationLevel]![student.grade]!.add(studentWithInfo);
      // 학교별
      groupedBySchool[student.educationLevel]![student.school] ??= [];
      groupedBySchool[student.educationLevel]![student.school]!.add(studentWithInfo);
    }
    for (final level in groupedByGrade.keys) {
      for (final gradeStudents in groupedByGrade[level]!.values) {
        gradeStudents.sort((a, b) => a.student.name.compareTo(b.student.name));
      }
    }
    for (final level in groupedBySchool.keys) {
      for (final schoolStudents in groupedBySchool[level]!.values) {
        schoolStudents.sort((a, b) => a.student.name.compareTo(b.student.name));
      }
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
          const SizedBox(width: 24), // 왼쪽 여백
          Expanded(
            flex: 2,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final maxHeight = MediaQuery.of(context).size.height * 0.82 + 24;
                return Container(
                  constraints: BoxConstraints(
                    maxHeight: maxHeight,
                    minWidth: 624,
                    maxWidth: 624,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                  decoration: BoxDecoration(
                    color: Color(0xFF18181A),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 1),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(left: 0),
                            child: Text(
                              '학생 리스트',
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 27,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(right: 0),
                            child: SizedBox(
                              height: 40,
                              width: 104,
                              child: OutlinedButton(
                                style: ButtonStyle(
                                  backgroundColor: MaterialStateProperty.all(Colors.transparent),
                                  shape: MaterialStateProperty.all(RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(24),
                                  )),
                                  side: MaterialStateProperty.all(BorderSide(color: Colors.grey.shade600, width: 1.2)),
                                  padding: MaterialStateProperty.all(const EdgeInsets.symmetric(horizontal: 0)),
                                  foregroundColor: MaterialStateProperty.all(Colors.white70),
                                  textStyle: MaterialStateProperty.all(const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                                  overlayColor: MaterialStateProperty.all(Colors.white.withOpacity(0.07)),
                                ),
                                onPressed: () async {
                                  if (widget.activeFilter != null) {
                                    // 필터 클리어
                                    widget.onFilterChanged(null);
                                  } else {
                                    // 필터 다이얼로그 열기
                                    final result = await showDialog<Map<String, Set<String>>>(
                                      context: context,
                                      builder: (context) => StudentFilterDialog(
                                        initialFilter: widget.activeFilter,
                                      ),
                                    );
                                    if (result != null) {
                                      widget.onFilterChanged(result);
                                    }
                                  }
                                },
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  mainAxisSize: MainAxisSize.max,
                                  children: [
                                    const Icon(Icons.filter_alt_outlined, size: 20),
                                    const SizedBox(width: 6),
                                    const Text('filter'),
                                    if (widget.activeFilter != null) ...[
                                      const SizedBox(width: 6),
                                      Icon(Icons.close, size: 18, color: Colors.white70),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Expanded(
                        child: ListView(
                          children: [
                            _buildEducationLevelGroup(' 초등', EducationLevel.elementary, groupedByGrade),
                            const Divider(color: Color(0xFF0F467D), height: 48),
                            _buildEducationLevelGroup(' 중등', EducationLevel.middle, groupedByGrade),
                            const Divider(color: Color(0xFF0F467D), height: 48),
                            _buildEducationLevelGroup(' 고등', EducationLevel.high, groupedByGrade),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 32),
          Expanded(
            flex: 1,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final maxHeight = MediaQuery.of(context).size.height * 0.82 + 24;
                return Container(
                  constraints: BoxConstraints(
                    maxHeight: maxHeight,
                    minWidth: 424,
                    maxWidth: 424,
                  ),
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
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(left: 4.0),
                            child: Text(
                              '그룹 목록',
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 27,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 130,
                            child: FilledButton.icon(
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
                                  widget.onGroupAdded(result);
                                }
                              },
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF1976D2),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                                minimumSize: const Size(0, 44),
                                maximumSize: const Size(double.infinity, 44),
                              ),
                              icon: const Icon(Icons.add, size: 24),
                              label: const Text(
                                '그룹 등록',
                                style: TextStyle(
                                  fontSize: 15.5,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Expanded(
                        child: ReorderableListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
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
                              key: ValueKey(groupInfo.id),
                              padding: const EdgeInsets.only(bottom: 16),
                              child: DragTarget<StudentWithInfo>(
                                onWillAccept: (student) => student != null,
                                onAccept: (student) {
                                  final oldGroupInfo = student.groupInfo;
                                  widget.onStudentMoved(student, groupInfo);
                                  Builder(
                                    builder: (context) {
                                      print('[DEBUG] hideCurrentSnackBar 호출');
                                      ScaffoldMessenger.of(context).hideCurrentSnackBar();
                                      Future.delayed(const Duration(milliseconds: 50), () {
                                        print('[DEBUG] showSnackBar 호출');
                                        showAppSnackBar(context, '${student.student.name}님이 ${oldGroupInfo?.name ?? '미배정'} → ${groupInfo.name}으로 이동되었습니다.', useRoot: true);
                                      });
                                      return const SizedBox.shrink();
                                    },
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
                                          borderRadius: BorderRadius.circular(12),
                                          child: InkWell(
                                            borderRadius: BorderRadius.circular(12),
                                            onTap: () => widget.onGroupExpanded(groupInfo),
                                            child: Container(
                                              height: 88,
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF121212),
                                                borderRadius: BorderRadius.circular(12),
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
                                                          final studentsInGroup = widget.students.where((s) => s.groupInfo?.id == groupInfo.id).toList();
                                                          print('[DEBUG] all_students_view.dart: studentsInGroup.length=${studentsInGroup.length}');
                                                          final result = await showDialog<GroupInfo>(
                                                            context: context,
                                                            builder: (context) => GroupRegistrationDialog(
                                                              editMode: true,
                                                              groupInfo: groupInfo,
                                                              currentMemberCount: studentsInGroup.length,
                                                              onSave: (updatedGroup) {
                                                                Navigator.of(context).pop(updatedGroup);
                                                              },
                                                            ),
                                                          );
                                                          if (result != null) {
                                                            widget.onGroupUpdated(result, index);
                                                          }
                                                        },
                                                        icon: const Icon(Icons.edit_rounded),
                                                        style: IconButton.styleFrom(
                                                          foregroundColor: Colors.white70,
                                                        ),
                                                      ),
                                                      IconButton(
                                                        onPressed: () async {
                                                          final confirm = await showDialog<bool>(
                                                            context: context,
                                                            builder: (context) => AlertDialog(
                                                              backgroundColor: const Color(0xFF232326),
                                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                                              title: Text('${groupInfo.name} 삭제', style: const TextStyle(color: Colors.white)),
                                                              content: const Text('정말로 이 그룹을 삭제하시겠습니까?', style: TextStyle(color: Colors.white70)),
                                                              actions: [
                                                                TextButton(
                                                                  onPressed: () => Navigator.of(context).pop(false),
                                                                  child: const Text('취소', style: TextStyle(color: Colors.white70)),
                                                                ),
                                                                TextButton(
                                                                  onPressed: () => Navigator.of(context).pop(true),
                                                                  child: const Text('삭제', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                                                                ),
                                                              ],
                                                            ),
                                                          );
                                                          if (confirm == true) {
                                                            widget.onGroupDeleted(groupInfo);
                                                          }
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
                                                  borderRadius: BorderRadius.circular(12),
                                                ),
                                                child: Padding(
                                                  padding: const EdgeInsets.fromLTRB(30, 16, 24, 16),
                                                  child: Wrap(
                                                    spacing: 4,
                                                    runSpacing: 8,
                                                    children: studentsInGroup.map((studentWithInfo) => GroupStudentCard(
                                                      studentWithInfo: studentWithInfo,
                                                      onShowDetails: (_) {},
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
                          onReorder: widget.onReorder,
                        ),
                      ),
                      if (_showDeleteZone)
                        Padding(
                          padding: const EdgeInsets.only(top: 24.0),
                          child: DragTarget<StudentWithInfo>(
                            onWillAccept: (student) => true,
                            onAccept: (student) async {
                              print('[DEBUG] 삭제 드롭존 onAccept 진입');
                              print('[DEBUG] 삭제 드롭존 - student.student: ' + student.student.toString());
                              print('[DEBUG] 삭제 드롭존 - student.basicInfo: ' + student.basicInfo.toString());
                              final studentCopy = student.student.copyWith(groupInfo: null, groupId: null);
                              final basicInfoCopy = student.basicInfo.copyWith(groupId: null);
                              print('[DEBUG] 삭제 드롭존 - studentCopy: ' + studentCopy.toString());
                              print('[DEBUG] 삭제 드롭존 - basicInfoCopy: ' + basicInfoCopy.toString());
                              print('[DEBUG] 삭제 드롭존 - studentCopy.toDb(): ' + studentCopy.toDb().toString());
                              print('[DEBUG] 삭제 드롭존 - basicInfoCopy.toDb(): ' + basicInfoCopy.toDb().toString());
                              final result = await showDialog<bool>(
                                context: context,
                                builder: (context) => AlertDialog(
                                  backgroundColor: const Color(0xFF232326),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                  title: const Text('그룹에서 삭제', style: TextStyle(color: Colors.white)),
                                  content: Text('${student.student.name} 학생을 그룹에서 삭제하시겠습니까?', style: const TextStyle(color: Colors.white70)),
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
                              print('[DEBUG] 삭제 드롭존 - 다이얼로그 result: ' + result.toString());
                              if (result == true) {
                                print('[DEBUG] 삭제 드롭존 - updateStudent 호출 직전');
                                await DataManager.instance.updateStudent(
                                  studentCopy,
                                  basicInfoCopy,
                                );
                                setState(() {});
                                // 그룹에서 제외되었을 때 스낵바 출력
                                showAppSnackBar(context, '그룹에서 제외되었습니다.');
                              }
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
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 24), // 오른쪽 여백
        ],
      );
  }

  Widget _buildEducationLevelGroup(
    String title,
    EducationLevel level,
    Map<EducationLevel, Map<int, List<StudentWithInfo>>> groupedStudents,
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
                children: gradeStudents.map((student) =>
                  Draggable<StudentWithInfo>(
                    data: student,
                    feedback: Material(
                      color: Colors.transparent,
                      child: Opacity(
                        opacity: 0.85,
                        child: StudentCard(
                          studentWithInfo: student,
                          onShowDetails: widget.onShowDetails, // 연결 복구
                          onDelete: widget.onDeleteStudent,
                          onUpdate: widget.onStudentUpdated,
                        ),
                      ),
                    ),
                    childWhenDragging: Opacity(
                      opacity: 0.3,
                      child: StudentCard(
                        studentWithInfo: student,
                        onShowDetails: widget.onShowDetails, // 연결 복구
                        onDelete: widget.onDeleteStudent,
                        onUpdate: widget.onStudentUpdated,
                      ),
                    ),
                    child: StudentCard(
                      studentWithInfo: student,
                      onShowDetails: widget.onShowDetails, // 연결 복구
                      onDelete: widget.onDeleteStudent,
                      onUpdate: widget.onStudentUpdated,
                    ),
                  )
                ).toList(),
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

  Widget _buildEducationLevelSchoolGroup(
    String title,
    EducationLevel level,
    Map<EducationLevel, Map<String, List<StudentWithInfo>>> groupedStudents,
  ) {
    final students = groupedStudents[level]!;
    final totalCount = students.values.fold<int>(0, (sum, list) => sum + list.length);

    final List<Widget> schoolWidgets = [];
    for (final entry in students.entries.where((e) => e.value.isNotEmpty)) {
      final schoolName = entry.key;
      final schoolStudents = entry.value;
      // 학년별로 그룹화
      final Map<int, List<StudentWithInfo>> studentsByGrade = {};
      for (final s in schoolStudents) {
        studentsByGrade[s.student.grade] ??= [];
        studentsByGrade[s.student.grade]!.add(s);
      }
      final sortedGrades = studentsByGrade.keys.toList()..sort();
      schoolWidgets.add(
        Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 8),
          child: Text(
            schoolName, // 학교명
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 18,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      );
      for (final grade in sortedGrades) {
        final gradeStudents = studentsByGrade[grade]!;
        gradeStudents.sort((a, b) => a.student.name.compareTo(b.student.name));
        schoolWidgets.add(
          Padding(
            padding: const EdgeInsets.only(left: 50, bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text(
                    '${grade}학년',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Expanded(
                  child: Wrap(
                    spacing: 4,
                    runSpacing: 8,
                    children: gradeStudents.map((studentWithInfo) => StudentCard(
                      studentWithInfo: studentWithInfo,
                      onShowDetails: widget.onShowDetails, // 연결 복구
                      onDelete: widget.onDeleteStudent, // 삭제 콜백 연결
                      onUpdate: widget.onStudentUpdated,
                    )).toList(),
                  ),
                ),
              ],
            ),
          ),
        );
      }
    }

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
        ...schoolWidgets,
      ],
    );
  }
} 