import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform, kIsWeb;
import '../../../models/student.dart';
import '../../../models/education_level.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../../../models/attendance_record.dart';
import '../../../models/payment_record.dart';
import '../../../widgets/student_card.dart';
import '../../../models/group_info.dart';
import '../../../widgets/student_registration_dialog.dart';
import '../student_course_detail_screen.dart';
import '../../../widgets/group_registration_dialog.dart';
import '../../../services/data_manager.dart';
import '../../../widgets/app_snackbar.dart';
import '../../../widgets/student_filter_dialog.dart';
import '../../../models/student_time_block.dart';
import '../../../widgets/dark_panel_route.dart';
import '../../../widgets/swipe_action_reveal.dart';

const Color _studentListPrimaryTextColor = Color(0xFFEAF2F2);
const Color _studentListMutedTextColor = Color(0xFFCBD8D8);
// ✅ 성능: Windows 환경에서 대량 print는 UI 스레드를 쉽게 막아 지연을 유발할 수 있다.
// 기본 OFF, 필요 시 실행 옵션으로만 활성화:
// flutter run ... --dart-define=YG_STUDENT_LIST_DEBUG=true
const bool _kStudentListDebug =
    bool.fromEnvironment('YG_STUDENT_LIST_DEBUG', defaultValue: false);

class AllStudentsView extends StatefulWidget {
  final List<StudentWithInfo> students;
  final List<GroupInfo> groups;
  final Set<GroupInfo> expandedGroups;
  final Function(StudentWithInfo) onShowDetails;
  final Function(StudentWithInfo) onRequestCourseView;
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
    required this.onRequestCourseView,
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
  StudentWithInfo? _detailsStudent;

  bool get _useImmediateDrag {
    if (kIsWeb) return true;
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
        return true;
      default:
        return false;
    }
  }

  Widget _buildStudentDraggable({
    required StudentWithInfo student,
    required Widget feedback,
    required Widget childWhenDragging,
    required Widget child,
  }) {
    void onDragStarted() {
      setState(() => _showDeleteZone = true);
      if (_kStudentListDebug) {
        // ignore: avoid_print
        print('[STUDENT][drag] delete zone opened by ${student.student.name}');
      }
    }

    void onDragEnd(_) {
      setState(() => _showDeleteZone = false);
      if (_kStudentListDebug) {
        // ignore: avoid_print
        print('[STUDENT][drag] delete zone closed');
      }
    }

    if (_useImmediateDrag) {
      // 데스크톱(마우스) UX: 시간표 탭과 동일하게 "클릭+이동" 즉시 드래그
      return Draggable<StudentWithInfo>(
        data: student,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        maxSimultaneousDrags: 1,
        onDragStarted: onDragStarted,
        onDragEnd: onDragEnd,
        feedback: feedback,
        childWhenDragging: childWhenDragging,
        child: child,
      );
    }

    // 모바일/터치 UX: 스크롤/탭과 충돌을 피하려고 기존 롱프레스 드래그 유지
    return LongPressDraggable<StudentWithInfo>(
      data: student,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      maxSimultaneousDrags: 1,
      onDragStarted: onDragStarted,
      onDragEnd: onDragEnd,
      feedback: feedback,
      childWhenDragging: childWhenDragging,
      child: child,
    );
  }

  void _onShowDetails(StudentWithInfo s) {
    setState(() {
      _detailsStudent = s;
    });
  }
  void _clearDetails() {
    setState(() { _detailsStudent = null; });
  }

  bool get _hasGroupFilter {
    final groups = widget.activeFilter?['groups'];
    return groups != null && groups.isNotEmpty;
  }

  void _clearGroupFilter() {
    if (!_hasGroupFilter) return;
    final current = widget.activeFilter;
    if (current == null || current.keys.every((key) => key == 'groups')) {
      widget.onFilterChanged(null);
      return;
    }
    final Map<String, Set<String>> nextFilter = {};
    current.forEach((key, value) {
      if (key == 'groups') return;
      nextFilter[key] = Set<String>.from(value);
    });
    if (nextFilter.isEmpty) {
      widget.onFilterChanged(null);
    } else {
      widget.onFilterChanged(nextFilter);
    }
  }

  void _applyGroupFilter(String groupName) {
    final currentGroups = widget.activeFilter?['groups'] ?? <String>{};
    if (currentGroups.length == 1 && currentGroups.contains(groupName)) {
      _clearGroupFilter();
      return;
    }
    final Map<String, Set<String>> nextFilter = {};
    widget.activeFilter?.forEach((key, value) {
      nextFilter[key] = Set<String>.from(value);
    });
    nextFilter['groups'] = {groupName};
    widget.onFilterChanged(nextFilter);
  }

  void _handleStudentAreaTap() {
    if (_hasGroupFilter) {
      _clearGroupFilter();
    }
  }

  Widget _buildRemoveFromGroupDropZone() {
    return IgnorePointer(
      ignoring: !_showDeleteZone,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 120),
        opacity: _showDeleteZone ? 1.0 : 0.0,
        child: SizedBox(
          width: double.infinity,
          height: 72,
          child: DragTarget<StudentWithInfo>(
            onWillAccept: (student) => student != null,
            onAccept: (student) async {
              final studentCopy = student.student.copyWith(
                clearGroupInfo: true,
                clearGroupId: true,
              );
              final basicInfoCopy = student.basicInfo.copyWith(
                clearGroupId: true,
              );
              final result = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  backgroundColor: const Color(0xFF232326),
                  shape:
                      RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  title:
                      const Text('그룹에서 삭제', style: TextStyle(color: Colors.white)),
                  content: Text(
                    '${student.student.name} 학생을 그룹에서 삭제하시겠습니까?',
                    style: const TextStyle(color: Colors.white70),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child:
                          const Text('취소', style: TextStyle(color: Colors.white70)),
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
                if (_kStudentListDebug) {
                  // ignore: avoid_print
                  print(
                      '[STUDENT][drop] attempting to remove ${student.student.name} from group ${student.student.groupInfo?.name}');
                }
                await DataManager.instance.updateStudent(
                  studentCopy,
                  basicInfoCopy,
                );
                if (_kStudentListDebug) {
                  // ignore: avoid_print
                  print(
                      '[STUDENT][drop] updateStudent complete for ${student.student.id}, loading students...');
                }
                await DataManager.instance.loadStudents();
                setState(() {
                  _showDeleteZone = false;
                });
                showAppSnackBar(context, '그룹에서 제외되었습니다.');
              } else {
                if (_kStudentListDebug) {
                  // ignore: avoid_print
                  print('[STUDENT][drop] remove cancelled for ${student.student.name}');
                }
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
      ),
    );
  }

  List<StudentWithInfo> _applyFilter(List<StudentWithInfo> students) {
    if (widget.activeFilter == null) {
      if (_kStudentListDebug) {
        // ignore: avoid_print
        print('[DEBUG] 필터 없음, 전체 학생 반환: ${students.length}명');
      }
      return students;
    }
    
    if (_kStudentListDebug) {
      // ignore: avoid_print
      print('[DEBUG] 필터 적용 시작: ${widget.activeFilter}');
    }
    
    final filteredStudents = students.where((studentWithInfo) {
      final student = studentWithInfo.student;
      final filter = widget.activeFilter!;
      
      // 학년별 필터
      final educationLevels = filter['educationLevels'] ?? <String>{};
      final grades = filter['grades'] ?? <String>{};
      
      if (_kStudentListDebug) {
        // ignore: avoid_print
        print('[DEBUG] 학생: ${student.name}, 학년: ${student.grade}, 학교: ${student.school}, 그룹: ${student.groupInfo?.name}');
      }
      
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
        
        if (_kStudentListDebug) {
          // ignore: avoid_print
          print('[DEBUG] 학년 필터 - 교육단계: $studentEducationLevel, 매치: $matchesEducationLevel, 학년매치: $matchesGrade');
        }
        
        if (!matchesEducationLevel || !matchesGrade) {
          if (_kStudentListDebug) {
            // ignore: avoid_print
            print('[DEBUG] 학년 필터로 제외: ${student.name}');
          }
          return false;
        }
      }
      
      // 학교 필터
      final schools = filter['schools'] ?? <String>{};
      if (schools.isNotEmpty && !schools.contains(student.school)) {
        if (_kStudentListDebug) {
          // ignore: avoid_print
          print('[DEBUG] 학교 필터로 제외: ${student.name} (${student.school})');
        }
        return false;
      }
      
      // 그룹 필터
      final groups = filter['groups'] ?? <String>{};
      if (groups.isNotEmpty) {
        final studentGroupName = student.groupInfo?.name;
        if (studentGroupName == null || !groups.contains(studentGroupName)) {
          if (_kStudentListDebug) {
            // ignore: avoid_print
            print('[DEBUG] 그룹 필터로 제외: ${student.name} (${studentGroupName})');
          }
          return false;
        }
      }
      
      if (_kStudentListDebug) {
        // ignore: avoid_print
        print('[DEBUG] 필터 통과: ${student.name}');
      }
      return true;
    }).toList();
    
    if (_kStudentListDebug) {
      // ignore: avoid_print
      print('[DEBUG] 필터 적용 완료: ${students.length}명 -> ${filteredStudents.length}명');
    }
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
      crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(width: 0), // 왼쪽 여백
          Expanded(
            flex: 2,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Container(
                  constraints: const BoxConstraints(
                    minWidth: 624,
                    maxWidth: 624,
                  ),
                  padding: const EdgeInsets.only(left: 34, right: 24, top: 24, bottom: 24),
                  decoration: BoxDecoration(
                    color: Color(0xFF0B1112),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 1),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 22),
                        decoration: BoxDecoration(
                          color: const Color(0xFF223131),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.people_alt_outlined, color: Colors.white70, size: 32),
                                const SizedBox(width: 16),
                                Text(
                                  '학생 현황',
                                  style: const TextStyle(
                                    color: _studentListPrimaryTextColor,
                                    fontSize: 32,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(width: 15),
                                Text(
                                  ' ${widget.students.length}명',
                                  style: const TextStyle(
                                    color: _studentListMutedTextColor,
                                    fontSize: 22,
                                  ),
                                ),
                              ],
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '업데이트 ${DateFormat('MM.dd').format(DateTime.now())}',
                                  style: const TextStyle(
                                    color: _studentListMutedTextColor,
                                    fontSize: 16,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: IconButton(
                                    tooltip: '엑셀 내보내기(준비중)',
                                    onPressed: () {
                                      // TODO: 학생현황 엑셀 내보내기 기능 연결
                                    },
                                    icon: const Icon(Symbols.output, color: Colors.white70, size: 26),
                                    splashRadius: 22,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 27),
                      const SizedBox(height: 5),
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onTap: _hasGroupFilter ? _handleStudentAreaTap : null,
                          child: ListView(
                            children: [
                              _buildEducationLevelGroup('초등', EducationLevel.elementary, groupedByGrade),
                              const Divider(color: Color(0xFF223131), height: 48),
                              _buildEducationLevelGroup('중등', EducationLevel.middle, groupedByGrade),
                              const Divider(color: Color(0xFF223131), height: 48),
                              _buildEducationLevelGroup('고등', EducationLevel.high, groupedByGrade),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          SizedBox(
            width: 32,
            child: Center(
              child: Container(
                margin: const EdgeInsets.only(top: 24),
                height: double.infinity,
                child: const VerticalDivider(
                  color: Color(0xFF223131),
                  width: 1,
                  thickness: 1,
                ),
              ),
            ),
          ),
          Expanded(
            flex: 1,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Container(
                  margin: const EdgeInsets.only(right: 10),
                  constraints: const BoxConstraints(
                    minWidth: 424,
                    maxWidth: 424,
                  ),
                  padding: const EdgeInsets.only(top: 24),
                  decoration: BoxDecoration(
                    color: Color(0xFF0B1112),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 1,
                        child: _detailsStudent != null
                            ? _EmbeddedStudentDetailsCard(
                                studentWithInfo: _detailsStudent!,
                                onRequestCourseView: widget.onRequestCourseView,
                              )
                            : Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0B1112),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: const Color(0xFF223131), width: 1.5),
                                ),
                                child: const Center(
                                  child: Text(
                                    '학생을 선택하면 상세 정보가 여기에 표시됩니다.',
                                    style: TextStyle(color: Colors.white38, fontSize: 16),
                                  ),
                                ),
                              ),
                      ),
                        const SizedBox(height: 16),
                        Padding(
                          // ✅ 우측 여백을 줄여 + 버튼을 더 오른쪽으로 붙임
                          padding: const EdgeInsets.fromLTRB(24, 15, 12, 0),
                          child: Row(
                            children: [
                              const Icon(Icons.groups_rounded, color: _studentListPrimaryTextColor, size: 28),
                              const SizedBox(width: 12),
                              const Text(
                                '그룹',
                                style: TextStyle(
                                  color: _studentListPrimaryTextColor,
                                  fontSize: 25,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const Spacer(),
                              // ✅ 그룹 추가 버튼: 시간탭 "수업 리스트" + 버튼 스타일과 통일
                              Padding(
                                padding: const EdgeInsets.only(top: 0, right: 0),
                                child: SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: IconButton(
                                    tooltip: '그룹 추가',
                                    onPressed: () async {
                                      final result = await showDialog<GroupInfo>(
                                        context: context,
                                        builder: (context) => GroupRegistrationDialog(
                                          onSave: (_) {},
                                        ),
                                      );
                                      if (result != null) {
                                        widget.onGroupAdded(result);
                                      }
                                    },
                                    icon: const Icon(Icons.add_rounded),
                                    iconSize: 30,
                                    color: _studentListPrimaryTextColor,
                                    padding: EdgeInsets.zero,
                                    splashRadius: 26,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          flex: 1,
                          child: Stack(
                            children: [
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                child: ReorderableListView.builder(
                              physics: const AlwaysScrollableScrollPhysics(),
                              dragStartBehavior: DragStartBehavior.down,
                              buildDefaultDragHandles: false,
                              // 삭제 드롭존이 나타나도 그룹 리스트가 "밀리지" 않도록 하단 여백을 확보
                              padding: const EdgeInsets.only(bottom: 90),
                              proxyDecorator: (child, index, animation) {
                                return AnimatedBuilder(
                                  animation: animation,
                                  builder: (BuildContext context, Widget? child) {
                                    // ✅ 드래그 피드백: 마우스에 "붙는 느낌" + 살짝 확대/부유 효과
                                    final t = Curves.easeOutCubic.transform(animation.value);
                                    final scale = 1.0 + (0.03 * t);
                                    final elev = 2.0 + (8.0 * t);
                                    return Transform.scale(
                                      scale: scale,
                                      alignment: Alignment.centerLeft,
                                      child: Material(
                                        color: Colors.transparent,
                                        elevation: elev,
                                        shadowColor: Colors.black.withOpacity(0.45),
                                        child: child,
                                      ),
                                    );
                                  },
                                  child: child,
                                );
                              },
                              itemCount: widget.groups.length,
                              itemBuilder: (context, index) {
                                final groupInfo = widget.groups[index];
                                final liveStudents = DataManager.instance.students;
                                final studentsInGroup = liveStudents.where((s) => s.groupInfo?.id == groupInfo.id).toList();
                                final activeGroups = widget.activeFilter?['groups'] ?? <String>{};
                                final bool isFiltered = activeGroups.contains(groupInfo.name);

                              return Padding(
                                key: ValueKey(groupInfo.id),
                                padding: const EdgeInsets.only(bottom: 12.0),
                                child: DragTarget<StudentWithInfo>(
                                  onWillAccept: (student) {
                                    if (student == null) return false;
                                    final cap = groupInfo.capacity;
                                    // null/0 이면 제한 없음
                                    if (cap != null && cap > 0 && studentsInGroup.length >= cap) return false;
                                    return true;
                                  },
                                  onAccept: (student) {
                                    final oldGroupInfo = student.groupInfo;
                                    widget.onStudentMoved(student, groupInfo);
                                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                                    Future.delayed(const Duration(milliseconds: 50), () {
                                      showAppSnackBar(
                                        context,
                                        '${student.student.name}님이 ${oldGroupInfo?.name ?? '미배정'} → ${groupInfo.name}으로 이동되었습니다.',
                                        useRoot: true,
                                      );
                                    });
                                  },
                                  builder: (context, candidateData, rejectedData) {
                                    final bool isHovering = candidateData.isNotEmpty;
                                    final bool highlight = isHovering || isFiltered;
                                    final Color borderColor = highlight ? groupInfo.color : Colors.transparent;
                                    final Color indicatorColor = groupInfo.color;

                                    // ✅ 수업카드(_ClassCard)와 동일한 "모양/사이즈/텍스트 높이 정렬"을 그룹에도 적용
                                    const titleStyle = TextStyle(
                                      color: _studentListPrimaryTextColor,
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                      height: 1.15,
                                    );
                                    const descStyle = TextStyle(
                                      color: Colors.white70,
                                      fontSize: 14,
                                      height: 1.15,
                                    );
                                    const gap = 4.0;
                                    const extra = 2.0;
                                    final String desc = groupInfo.description.trim();
                                    final bool hasDesc = desc.isNotEmpty;
                                    final ts = MediaQuery.textScalerOf(context);
                                    final titlePx = ts.scale(titleStyle.fontSize!);
                                    final descPx = ts.scale(descStyle.fontSize!);
                                    final textBlockH =
                                        (titlePx * titleStyle.height!) + gap + (descPx * descStyle.height!) + extra;

                                    final cardBody = Container(
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF15171C),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: borderColor, width: 2),
                                      ),
                                      child: Material(
                                        color: Colors.transparent,
                                        borderRadius: BorderRadius.circular(12),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                                          child: Row(
                                            crossAxisAlignment: CrossAxisAlignment.center,
                                            children: [
                                              Container(
                                                width: 10,
                                                height: textBlockH,
                                                decoration: BoxDecoration(
                                                  color: indicatorColor,
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                              ),
                                              const SizedBox(width: 14),
                                              Expanded(
                                                child: SizedBox(
                                                  height: textBlockH,
                                                  child: hasDesc
                                                      ? Column(
                                                          mainAxisSize: MainAxisSize.max,
                                                          crossAxisAlignment: CrossAxisAlignment.start,
                                                          mainAxisAlignment: MainAxisAlignment.start,
                                                          children: [
                                                            Text(
                                                              groupInfo.name,
                                                              maxLines: 1,
                                                              overflow: TextOverflow.ellipsis,
                                                              style: titleStyle,
                                                            ),
                                                            const SizedBox(height: gap),
                                                            Text(
                                                              desc,
                                                              maxLines: 1,
                                                              overflow: TextOverflow.ellipsis,
                                                              style: descStyle,
                                                            ),
                                                          ],
                                                        )
                                                      : Align(
                                                          alignment: Alignment.centerLeft,
                                                          child: Text(
                                                            groupInfo.name,
                                                            maxLines: 1,
                                                            overflow: TextOverflow.ellipsis,
                                                            style: titleStyle,
                                                          ),
                                                        ),
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              Text(
                                                (groupInfo.capacity == null || (groupInfo.capacity ?? 0) <= 0)
                                                    ? '${studentsInGroup.length}명'
                                                    : '${studentsInGroup.length}/${groupInfo.capacity}명',
                                                style: const TextStyle(
                                                  color: Colors.white70,
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );

                                    final baseBody = GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () => _applyGroupFilter(groupInfo.name),
                                      child: cardBody,
                                    );

                                    // 스와이프(드래그) 액션: 수업카드와 동일한 UX(편집/삭제)
                                    const double paneW = 140;
                                    final radius = BorderRadius.circular(12);
                                    final actionPane = Padding(
                                      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Material(
                                              color: const Color(0xFF223131),
                                              borderRadius: BorderRadius.circular(10),
                                              child: InkWell(
                                                onTap: () async {
                                                  final dialogStudents = widget.students
                                                      .where((s) => s.groupInfo?.id == groupInfo.id)
                                                      .toList();
                                                  final result = await showDialog<GroupInfo>(
                                                    context: context,
                                                    builder: (context) => GroupRegistrationDialog(
                                                      editMode: true,
                                                      groupInfo: groupInfo,
                                                      currentMemberCount: dialogStudents.length,
                                                      onSave: (_) {},
                                                    ),
                                                  );
                                                  if (result != null) {
                                                    widget.onGroupUpdated(result, index);
                                                  }
                                                },
                                                borderRadius: BorderRadius.circular(10),
                                                splashFactory: NoSplash.splashFactory,
                                                highlightColor: Colors.white.withOpacity(0.06),
                                                hoverColor: Colors.white.withOpacity(0.03),
                                                child: const SizedBox.expand(
                                                  child: Center(
                                                    child: Icon(Icons.edit_outlined, color: Color(0xFFEAF2F2), size: 18),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Material(
                                              color: const Color(0xFFB74C4C),
                                              borderRadius: BorderRadius.circular(10),
                                              child: InkWell(
                                                onTap: () async {
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
                                                          child: const Text('삭제', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                  if (confirm == true) {
                                                    widget.onGroupDeleted(groupInfo);
                                                  }
                                                },
                                                borderRadius: BorderRadius.circular(10),
                                                splashFactory: NoSplash.splashFactory,
                                                highlightColor: Colors.white.withOpacity(0.08),
                                                hoverColor: Colors.white.withOpacity(0.04),
                                                child: const SizedBox.expand(
                                                  child: Center(
                                                    child: Icon(Icons.delete_outline_rounded, color: Colors.white, size: 18),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    );

                                    final swiped = SwipeActionReveal(
                                      enabled: true,
                                      actionPaneWidth: paneW,
                                      borderRadius: radius,
                                      actionPane: actionPane,
                                      child: baseBody,
                                    );

                                    // ✅ 수업리스트와 동일: 기본은 "오래 눌러" 순서 이동(reorder)
                                    return isFiltered
                                        ? swiped
                                        : ReorderableDelayedDragStartListener(
                                            index: index,
                                            child: swiped,
                                          );
                                  },
                                ),
                              );
                            },
                          onReorder: widget.onReorder,
                        ),
                      ),
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: _buildRemoveFromGroupDropZone(),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 12),
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

    final List<MapEntry<int, List<StudentWithInfo>>> sortedEntries = students.entries
        .where((entry) => entry.value.isNotEmpty)
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    final List<Widget> gradeWidgets = sortedEntries
        .map<Widget>((entry) {
          final gradeStudents = entry.value;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 8, left: 5),
                child: Text(
                  '${entry.key}학년',
                  style: const TextStyle(
                    color: _studentListMutedTextColor,
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Wrap(
                spacing: 4,
                runSpacing: 8,
                children: gradeStudents.map((student) =>
                  _buildStudentDraggable(
                    student: student,
                    feedback: Material(
                      color: Colors.transparent,
                      child: Opacity(
                        opacity: 0.85,
                        child: StudentCard(
                          key: ValueKey('studentCard_feedback_${student.student.id}'),
                          studentWithInfo: student,
                          onShowDetails: (s) { _onShowDetails(s); widget.onShowDetails(s); }, // 연결 복구 + 내장 상세
                          onDelete: widget.onDeleteStudent,
                          onUpdate: widget.onStudentUpdated,
                          onOpenStudentPage: (s) {
                            Navigator.of(context).push(
                              DarkPanelRoute(
                                child: StudentCourseDetailScreen(studentWithInfo: s),
                              ),
                            );
                          },
                          enableLongPressDrag: false,
                        ),
                      ),
                    ),
                    childWhenDragging: Opacity(
                      opacity: 0.3,
                      child: StudentCard(
                        key: ValueKey('studentCard_placeholder_${student.student.id}'),
                        studentWithInfo: student,
                        onShowDetails: (s) { _onShowDetails(s); widget.onShowDetails(s); },
                        onDelete: widget.onDeleteStudent,
                        onUpdate: widget.onStudentUpdated,
                        onOpenStudentPage: (s) {
                          Navigator.of(context).push(
                            DarkPanelRoute(
                              child: StudentCourseDetailScreen(studentWithInfo: s),
                            ),
                          );
                        },
                        enableLongPressDrag: false,
                      ),
                    ),
                    child: StudentCard(
                      key: ValueKey('studentCard_${student.student.id}'),
                      studentWithInfo: student,
                      onShowDetails: (s) { _onShowDetails(s); widget.onShowDetails(s); },
                      onDelete: widget.onDeleteStudent,
                      onUpdate: widget.onStudentUpdated,
                      onOpenStudentPage: (s) {
                        Navigator.of(context).push(
                          DarkPanelRoute(
                            child: StudentCourseDetailScreen(studentWithInfo: s),
                          ),
                        );
                      },
                      enableLongPressDrag: false,
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
            Container(
              width: 6,
              height: 28,
              decoration: BoxDecoration(
                color: const Color(0xFF223131),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              title,
              style: const TextStyle(
                color: _studentListPrimaryTextColor,
                fontSize: 23,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '$totalCount명',
              style: const TextStyle(
                color: _studentListMutedTextColor,
                fontSize: 20,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ...gradeWidgets.map((widget) => Padding(
              padding: const EdgeInsets.only(left: 24),
              child: widget,
            )),
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
                      color: _studentListMutedTextColor,
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: 24),
            child: Wrap(
              spacing: 4,
              runSpacing: 8,
              children: gradeStudents.map((studentWithInfo) => StudentCard(
                key: ValueKey('studentCard_${studentWithInfo.student.id}'),
                studentWithInfo: studentWithInfo,
                onShowDetails: widget.onShowDetails, // 연결 복구
                onDelete: widget.onDeleteStudent, // 삭제 콜백 연결
                onUpdate: widget.onStudentUpdated,
                onOpenStudentPage: (s) {
                            Navigator.of(context).push(
                              DarkPanelRoute(
                      child: StudentCourseDetailScreen(studentWithInfo: s),
                    ),
                  );
                },
              )).toList(),
            ),
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
                color: Color(0xFF0F467D),
                fontSize: 23,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '$totalCount명',
              style: const TextStyle(
                color: Color(0xFF0F467D),
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

class _EmbeddedStudentDetailsCard extends StatelessWidget {
  final StudentWithInfo studentWithInfo;
  final Function(StudentWithInfo) onRequestCourseView;
  const _EmbeddedStudentDetailsCard({
    required this.studentWithInfo,
    required this.onRequestCourseView,
  });

  @override
  Widget build(BuildContext context) {
    final student = studentWithInfo.student;
    final basicInfo = studentWithInfo.basicInfo;
    final String levelName = getEducationLevelName(student.educationLevel);
    final grades = gradesByLevel[student.educationLevel] ?? [];
    final Grade grade = grades.firstWhere(
      (g) => g.value == student.grade,
      orElse: () => grades.isNotEmpty ? grades.first : Grade(student.educationLevel, '${student.grade}', student.grade),
    );
    final DateTime now = DateTime.now();
    final DateTime todayStart = DateTime(now.year, now.month, now.day);
    final DateTime registrationDate = basicInfo.registrationDate ?? now;

    final List<AttendanceRecord> recentAttendance = List<AttendanceRecord>.from(
      DataManager.instance.attendanceRecords.where((r) => r.studentId == student.id),
    )..sort((a, b) => b.classDateTime.compareTo(a.classDateTime));

    final List<StudentTimeBlock> timeBlocks = DataManager.instance.studentTimeBlocks
        .where((block) => block.studentId == student.id)
        .toList()
      ..sort((a, b) {
        if (a.dayIndex != b.dayIndex) return a.dayIndex.compareTo(b.dayIndex);
        final int aMinutes = a.startHour * 60 + a.startMinute;
        final int bMinutes = b.startHour * 60 + b.startMinute;
        return aMinutes.compareTo(bMinutes);
      });

    final List<AttendanceRecord> previousAttendance = recentAttendance
        .where((record) => record.classDateTime.isBefore(todayStart))
        .take(3)
        .toList();

    final List<_MonthlyPaymentStatus> monthlyStatuses = _buildRecentMonthlyStatuses(
      currentMonth: DateTime(now.year, now.month),
      registrationDate: registrationDate,
      studentId: student.id,
    );

    final Color bgColor = const Color(0xFF0B1112);
    final Color outlineColor = const Color(0xFF223131);
    final TextStyle labelStyle = const TextStyle(color: Color(0xFFAEC0C0), fontSize: 14);
    final TextStyle valueStyle = const TextStyle(color: Color(0xFFEAF2F2), fontSize: 15, fontWeight: FontWeight.w600);
    final String memoText = (basicInfo.memo ?? '').trim().isEmpty ? '메모가 없습니다.' : (basicInfo.memo ?? '').trim();

    Widget section({
      required IconData icon,
      required String title,
      Widget? action,
      required List<Widget> children,
    }) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        decoration: BoxDecoration(
          color: const Color(0xFF0B1112),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: outlineColor.withOpacity(0.4), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: const Color(0xFFB9C8C8)),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    color: _studentListPrimaryTextColor,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (action != null) action,
              ],
            ),
            const SizedBox(height: 14),
            ...children,
          ],
        ),
      );
    }

    Widget infoRow(String label, Widget value) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              label,
              style: labelStyle,
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Align(
              alignment: Alignment.centerRight,
              child: value,
            ),
          ),
        ],
      );
    }

    Widget textValue(String text) {
      return Text(
        text.isEmpty ? '-' : text,
        style: valueStyle,
      );
    }

    Widget statusChip(String text, Color background, {double borderWidth = 1}) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: background.withOpacity(0.15),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: background.withOpacity(0.6), width: borderWidth),
        ),
        child: Text(
          text,
          style: TextStyle(color: background, fontWeight: FontWeight.w600),
        ),
      );
    }

    List<Widget> scheduleChildren;
    if (timeBlocks.isEmpty) {
      scheduleChildren = [
        Text(
          '등록된 수업 시간이 없습니다.',
          style: valueStyle.copyWith(color: Colors.white60),
        ),
      ];
    } else {
      final Map<String, List<StudentTimeBlock>> groupedBlocks = {};
      for (final block in timeBlocks) {
        final String key = block.setId ?? 'single_${block.id}';
        groupedBlocks.putIfAbsent(key, () => []).add(block);
      }
      final entries = groupedBlocks.entries.toList()
        ..sort((a, b) {
          final StudentTimeBlock aFirst = _earliestBlock(a.value);
          final StudentTimeBlock bFirst = _earliestBlock(b.value);
          return _timeKey(aFirst).compareTo(_timeKey(bFirst));
        });

      scheduleChildren = entries.map((entry) {
        final blocks = entry.value..sort((a, b) => _timeKey(a).compareTo(_timeKey(b)));
        final StudentTimeBlock earliest = _earliestBlock(blocks);
        final StudentTimeBlock latest = _latestBlock(blocks);
        final String start = _formatTime(earliest.startHour, earliest.startMinute);
        final DateTime latestEnd = DateTime(2000, 1, 1, latest.startHour, latest.startMinute).add(latest.duration);
        final String end = _formatTime(latestEnd.hour, latestEnd.minute);
        final int? lessonOrder = earliest.weeklyOrder ?? earliest.number;

        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (lessonOrder != null)
                Text(
                  '수업 $lessonOrder',
                  style: labelStyle.copyWith(color: Colors.white70),
                )
              else
                const SizedBox.shrink(),
              const Spacer(),
              Text(
                _weekdayLabel(earliest.dayIndex),
                style: labelStyle.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 16),
              Text('$start ~ $end', style: valueStyle),
            ],
          ),
        );
      }).toList();
    }

    List<Widget> attendanceChips = [];
    if (previousAttendance.isNotEmpty) {
      attendanceChips = previousAttendance.map((record) {
        final String dateLabel = DateFormat('MM.dd').format(record.classDateTime);
        final bool isLate = record.arrivalTime != null &&
            record.arrivalTime!.isAfter(record.classDateTime.add(const Duration(minutes: 10)));
        final Color chipColor;
        if (!record.isPresent) {
          chipColor = const Color(0xFFE57373);
        } else if (isLate) {
          chipColor = const Color(0xFFF2B45B);
        } else {
          chipColor = const Color(0xFF33A373);
        }
        final Widget chip = Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: chipColor.withOpacity(0.15),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: chipColor.withOpacity(0.8), width: 2),
          ),
          child: Text(
            dateLabel,
            style: TextStyle(color: chipColor, fontWeight: FontWeight.w600),
          ),
        );
        return record.isPresent
            ? Tooltip(
                message: '등원 ${_hhmm(record.arrivalTime)} · 하원 ${_hhmm(record.departureTime)}',
                child: chip,
              )
            : chip;
      }).toList();
    }

    Widget attendanceRow() {
      if (previousAttendance.isEmpty) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: Text('최근 출석', style: labelStyle)),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: Text('기록 없음', style: valueStyle),
              ),
            ),
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text('최근 출석', style: labelStyle),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: attendanceChips,
              ),
            ),
          ),
        ],
      );
    }

    Widget paymentChipsRow(List<_MonthlyPaymentStatus> statuses) {
      if (statuses.isEmpty) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: Text('납부 상태', style: labelStyle)),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: Text('기록 없음', style: valueStyle),
              ),
            ),
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text('납부 상태', style: labelStyle),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: statuses.map((status) {
                  return Tooltip(
                    message: status.detail,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: status.color.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: status.color.withOpacity(0.8), width: 2),
                      ),
                      child: Text(
                        status.label,
                        style: TextStyle(color: status.color, fontWeight: FontWeight.w600),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: outlineColor, width: 1.2),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: student.groupInfo?.color ?? const Color(0xFF2C3A3A),
                child: Text(
                  student.name.characters.take(2).join(),
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      student.name,
                      style: const TextStyle(
                        color: Color(0xFFEAF2F2),
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${student.school} · $levelName · ${grade.name}',
                      style: const TextStyle(color: Color(0xFFCFDBDB), fontSize: 15),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text('등록일', style: TextStyle(color: Color(0xFFA6BAB7), fontSize: 12)),
                  const SizedBox(height: 4),
                  Text(
                    DateFormat('yyyy.MM.dd').format(registrationDate),
                    style: const TextStyle(color: Color(0xFFEAF2F2), fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 18),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                section(
                  icon: Icons.schedule_outlined,
                  title: '수업 시간',
                  children: scheduleChildren,
                ),
                const SizedBox(height: 12),
                section(
                  icon: Icons.timeline_outlined,
                  title: '최근 활동',
                  action: OutlinedButton.icon(
                    onPressed: () => onRequestCourseView(studentWithInfo),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF9FB3B3),
                      side: const BorderSide(color: Color(0xFF4D5A5A)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    ),
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: const Text('상세'),
                  ),
                  children: [
                    attendanceRow(),
                    const SizedBox(height: 16),
                    paymentChipsRow(monthlyStatuses),
                  ],
                ),
                const SizedBox(height: 12),
                section(
                  icon: Icons.group_work_outlined,
                  title: '소속 그룹',
                  children: [
                    student.groupInfo != null
                        ? statusChip(student.groupInfo!.name, student.groupInfo!.color, borderWidth: 2)
                        : textValue('미배정'),
                  ],
                ),
                const SizedBox(height: 12),
                section(
                  icon: Icons.phone_outlined,
                  title: '연락처',
                  children: [
                    infoRow('전화번호', textValue(basicInfo.phoneNumber ?? '-')),
                    const SizedBox(height: 10),
                    infoRow('학부모 번호', textValue(basicInfo.parentPhoneNumber ?? '-')),
                  ],
                ),
                const SizedBox(height: 12),
                section(
                  icon: Icons.notes_outlined,
                  title: '메모',
                  children: [
                    Text(
                      memoText,
                      style: valueStyle.copyWith(fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _weekdayLabel(int index) {
    const labels = ['월', '화', '수', '목', '금', '토', '일'];
    if (index < 0 || index >= labels.length) return '-';
    return labels[index];
  }

  StudentTimeBlock _earliestBlock(List<StudentTimeBlock> blocks) {
    return blocks.reduce((value, element) => _timeKey(value) <= _timeKey(element) ? value : element);
  }

  StudentTimeBlock _latestBlock(List<StudentTimeBlock> blocks) {
    return blocks.reduce((value, element) => _timeKey(value, end: true) >= _timeKey(element, end: true) ? value : element);
  }

  int _timeKey(StudentTimeBlock block, {bool end = false}) {
    final int base = block.dayIndex * 1440 + block.startHour * 60 + block.startMinute;
    return end ? base + block.duration.inMinutes : base;
  }

  String _formatTime(int hour, int minute) {
    final String hh = hour.toString().padLeft(2, '0');
    final String mm = minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  String _hhmm(DateTime? dateTime) {
    if (dateTime == null) return '--:--';
    final String hours = dateTime.hour.toString().padLeft(2, '0');
    final String minutes = dateTime.minute.toString().padLeft(2, '0');
    return '$hours:$minutes';
  }

  List<_MonthlyPaymentStatus> _buildRecentMonthlyStatuses({
    required DateTime currentMonth,
    required DateTime registrationDate,
    required String studentId,
  }) {
    final List<_MonthlyPaymentStatus> statuses = [];
    for (int offset = 2; offset >= 0; offset--) {
      final DateTime month = DateTime(currentMonth.year, currentMonth.month - offset, 1);
      final status = _buildMonthlyPaymentStatus(
        month: month,
        registrationDate: registrationDate,
        studentId: studentId,
      );
      if (status != null) {
        statuses.add(status);
      }
    }
    return statuses;
  }

  _MonthlyPaymentStatus? _buildMonthlyPaymentStatus({
    required DateTime month,
    required DateTime registrationDate,
    required String studentId,
  }) {
    final DateTime monthEnd = DateTime(month.year, month.month, DateUtils.getDaysInMonth(month.year, month.month));
    if (registrationDate.isAfter(monthEnd)) {
      return null;
    }
    final DateTime dueDate = _clampDueDate(month, registrationDate);
    final int cycle = _calculateCycleNumber(registrationDate, dueDate);
    final PaymentRecord? record = DataManager.instance.getPaymentRecord(studentId, cycle);
    final DateTime effectiveDue = record?.dueDate ?? dueDate;
    final DateTime? paidDate = record?.paidDate;
    final String dueLabel = DateFormat('MM.dd').format(effectiveDue);
    if (paidDate != null) {
      final String paidLabel = DateFormat('MM.dd').format(paidDate);
      return _MonthlyPaymentStatus(
        label: paidLabel,
        detail: '예정 $dueLabel · 납부 $paidLabel',
        color: const Color(0xFF33A373),
      );
    }
    if (effectiveDue.isAfter(DateTime.now())) {
      return _MonthlyPaymentStatus(
        label: dueLabel,
        detail: '예정 $dueLabel',
        color: const Color(0xFFF2B45B),
      );
    }
    return _MonthlyPaymentStatus(
      label: dueLabel,
      detail: '예정 $dueLabel · 미납',
      color: const Color(0xFFE57373),
    );
  }

  DateTime _clampDueDate(DateTime month, DateTime registrationDate) {
    final int lastDay = DateUtils.getDaysInMonth(month.year, month.month);
    final int dueDay = registrationDate.day > lastDay ? lastDay : registrationDate.day;
    return DateTime(month.year, month.month, dueDay);
  }

  int _calculateCycleNumber(DateTime registrationDate, DateTime paymentDate) {
    final regMonth = DateTime(registrationDate.year, registrationDate.month);
    final payMonth = DateTime(paymentDate.year, paymentDate.month);
    return (payMonth.year - regMonth.year) * 12 + (payMonth.month - regMonth.month) + 1;
  }
}

class _MonthlyPaymentStatus {
  final String label;
  final String detail;
  final Color color;

  const _MonthlyPaymentStatus({
    required this.label,
    required this.detail,
    required this.color,
  });
}