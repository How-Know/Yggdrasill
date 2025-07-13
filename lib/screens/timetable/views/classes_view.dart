import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../models/operating_hours.dart';
import '../../../models/student_time_block.dart';
import '../../../models/student.dart';
import '../../../models/group_info.dart';
import '../../../services/data_manager.dart';
import '../../../models/education_level.dart';
import '../../../services/data_manager.dart';

class ClassesView extends StatefulWidget {
  final List<OperatingHours> operatingHours;
  final Color breakTimeColor;
  final bool isRegistrationMode;
  final int? selectedDayIndex;
  final void Function(int dayIdx, DateTime startTime)? onTimeSelected;
  final void Function(int dayIdx, DateTime startTime, List<StudentWithInfo> students)? onCellStudentsSelected;
  final ScrollController scrollController;

  const ClassesView({
    super.key,
    required this.operatingHours,
    this.breakTimeColor = const Color(0xFF424242),
    this.isRegistrationMode = false,
    this.selectedDayIndex,
    this.onTimeSelected,
    this.onCellStudentsSelected,
    required this.scrollController,
  });

  @override
  State<ClassesView> createState() => _ClassesViewState();
}

class _ClassesViewState extends State<ClassesView> with TickerProviderStateMixin {
  String? _expandedCellKey;
  final Map<String, GlobalKey> _cellKeys = {};
  final Map<String, AnimationController> _animationControllers = {};
  final Map<String, Animation<double>> _animations = {};
  // 기존: final ScrollController _scrollController = ScrollController();
  // 변경: widget.scrollController 사용
  String? _hoveredCellKey;
  bool _hasScrolledToCurrentTime = false;

  @override
  void dispose() {
    for (var controller in _animationControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    print('[DEBUG][ClassesView] build: isRegistrationMode= ${widget.isRegistrationMode}');
    final timeBlocks = _generateTimeBlocks();
    return Stack(
      children: [
        SingleChildScrollView(
          controller: widget.scrollController,
          child: ValueListenableBuilder<List<StudentTimeBlock>>(
            valueListenable: DataManager.instance.studentTimeBlocksNotifier,
            builder: (context, studentTimeBlocks, _) {
              final double blockHeight = 90.0;
              final studentsWithInfo = DataManager.instance.students;
              final groups = DataManager.instance.groups;
              final lessonDuration = DataManager.instance.academySettings.lessonDuration;
              return Column(
                children: [
                  for (int blockIdx = 0; blockIdx < timeBlocks.length; blockIdx++)
                    Container(
                      height: blockHeight,
                      decoration: BoxDecoration(
                        color: timeBlocks[blockIdx].isBreakTime ? widget.breakTimeColor : Colors.transparent,
                        border: Border(
                          bottom: BorderSide(
                            color: Colors.white.withOpacity(0.1),
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          // Time indicator
                          SizedBox(
                            width: 60,
                            child: Center(
                              child: Text(
                                timeBlocks[blockIdx].timeString,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ),
                          // Day columns
                          ...List.generate(7, (dayIdx) {
                            final cellKey = '$dayIdx-$blockIdx';
                            _cellKeys.putIfAbsent(cellKey, () => GlobalKey());
                            // 현재 시간에 수업 중인 모든 학생 블록 가져오기
                            final activeBlocks = _getActiveStudentBlocks(
                              studentTimeBlocks, 
                              dayIdx, 
                              timeBlocks[blockIdx].startTime,
                              lessonDuration,
                            );
                            final cellBlocks = studentTimeBlocks.where((b) {
                              return b.dayIndex == dayIdx &&
                                b.startTime.hour == timeBlocks[blockIdx].startTime.hour &&
                                b.startTime.minute == timeBlocks[blockIdx].startTime.minute;
                            }).toList();
                            final cellStudentWithInfos = cellBlocks.map((b) => studentsWithInfo.firstWhere(
                              (s) => s.student.id == b.studentId,
                              orElse: () => StudentWithInfo(
                                student: Student(id: '', name: '', school: '', grade: 0, educationLevel: EducationLevel.elementary, registrationDate: DateTime.now(), weeklyClassCount: 1),
                                basicInfo: StudentBasicInfo(studentId: '', registrationDate: DateTime.now()),
                              ),
                            )).toList();
                            final isExpanded = _expandedCellKey == cellKey;
                            bool isHoverHighlight = false;
                            // 상태 변수로 hover 추적 필요: _hoveredCellKey
                            
                            // --- 여기서 breakTime 체크 ---
                            bool isBreakTime = false;
                            if (widget.operatingHours.length > dayIdx) {
                              final hours = widget.operatingHours[dayIdx];
                              for (final breakTime in hours.breakTimes) {
                                final breakStart = DateTime(
                                  timeBlocks[blockIdx].startTime.year,
                                  timeBlocks[blockIdx].startTime.month,
                                  timeBlocks[blockIdx].startTime.day,
                                  breakTime.startTime.hour,
                                  breakTime.startTime.minute,
                                );
                                final breakEnd = DateTime(
                                  timeBlocks[blockIdx].startTime.year,
                                  timeBlocks[blockIdx].startTime.month,
                                  timeBlocks[blockIdx].startTime.day,
                                  breakTime.endTime.hour,
                                  breakTime.endTime.minute,
                                );
                                if ((timeBlocks[blockIdx].startTime.isAfter(breakStart) || timeBlocks[blockIdx].startTime.isAtSameMomentAs(breakStart)) &&
                                    timeBlocks[blockIdx].startTime.isBefore(breakEnd)) {
                                  isBreakTime = true;
                                  break;
                                }
                              }
                            }
                            // --- breakTime 체크 끝 ---
                            
                            // 수업 정원 확인을 위한 클래스 정보 가져오기
                            final activeStudentCount = activeBlocks.length;
                            Color? countColor;
                            int? totalCapacity;
                            
                            if (activeStudentCount > 0) {
                              if (activeStudentCount < DataManager.instance.academySettings.defaultCapacity * 0.8) {
                                countColor = Colors.green;
                              } else if (activeStudentCount >= DataManager.instance.academySettings.defaultCapacity) {
                                countColor = Colors.red;
                              } else {
                                countColor = Colors.grey;
                              }
                            } else {
                              countColor = Colors.green;
                            }
                            
                            return Expanded(
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final cellWidth = constraints.maxWidth;
                                  return MouseRegion(
                                    onEnter: (_) => setState(() { _hoveredCellKey = cellKey; }),
                                    onExit: (_) => setState(() { if (_hoveredCellKey == cellKey) _hoveredCellKey = null; }),
                                    child: GestureDetector(
                                      onTap: () {
                                        if (widget.isRegistrationMode && widget.onTimeSelected != null) {
                                          widget.onTimeSelected!(dayIdx, timeBlocks[blockIdx].startTime);
                                        } else {
                                          // 셀 클릭 시 학생 리스트 상위로 전달
                                          if (widget.onCellStudentsSelected != null) {
                                            widget.onCellStudentsSelected!(dayIdx, timeBlocks[blockIdx].startTime, cellStudentWithInfos);
                                          }
                                        }
                                      },
                                      child: Container(
                                        width: cellWidth,
                                        child: Stack(
                                          children: [
                                            // 정원카드/정원표시 카드
                                            Container(
                                              decoration: BoxDecoration(
                                                color: (_hoveredCellKey == cellKey && widget.isRegistrationMode)
                                                  ? const Color(0xFF1976D2).withOpacity(0.10)
                                                  : Colors.transparent,
                                                border: Border(
                                                  left: BorderSide(
                                                    color: Colors.white.withOpacity(0.1),
                                                  ),
                                                ),
                                              ),
                                              child: cellBlocks.isEmpty
                                                  ? (activeStudentCount > 0 
                                                      ? CapacityCountWidget(count: activeStudentCount, color: countColor)
                                                      : null)
                                                  : !isExpanded
                                                      ? CapacityCardWidget(
                                                          count: activeStudentCount > 0 ? activeStudentCount : cellBlocks.length,
                                                          color: countColor,
                                                          showArrow: true,
                                                          isExpanded: false,
                                                          expandedBlocks: cellBlocks,
                                                          students: studentsWithInfo.map((s) => s.student).toList(),
                                                          groups: groups,
                                                        )
                                                      : CapacityCardWidget(
                                                          count: activeStudentCount > 0 ? activeStudentCount : cellBlocks.length,
                                                          color: countColor,
                                                          showArrow: true,
                                                          isExpanded: true,
                                                          expandedBlocks: cellBlocks,
                                                          students: studentsWithInfo.map((s) => s.student).toList(),
                                                          groups: groups,
                                                        ),
                                            ),
                                            // 펼침 상태일 때만 학생카드 그리드 + 닫힘 GestureDetector
                                            if (isExpanded && cellBlocks.isNotEmpty)
                                              _buildExpandedStudentCards(cellBlocks, studentsWithInfo.map((s) => s.student).toList(), groups, constraints.maxWidth, isExpanded),
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  List<TimeBlock> _generateTimeBlocks() {
    final List<TimeBlock> blocks = [];
    if (widget.operatingHours.isNotEmpty) {
      final now = DateTime.now();
      // 모든 요일의 운영시간에서 가장 이른 startTime, 가장 늦은 endTime 찾기
      int minHour = 23, minMinute = 59, maxHour = 0, maxMinute = 0;
      for (final hours in widget.operatingHours) {
        if (hours.startTime.hour < minHour || (hours.startTime.hour == minHour && hours.startTime.minute < minMinute)) {
          minHour = hours.startTime.hour;
          minMinute = hours.startTime.minute;
        }
        if (hours.endTime.hour > maxHour || (hours.endTime.hour == maxHour && hours.endTime.minute > maxMinute)) {
          maxHour = hours.endTime.hour;
          maxMinute = hours.endTime.minute;
        }
      }
      var currentTime = DateTime(now.year, now.month, now.day, minHour, minMinute);
      final endTime = DateTime(now.year, now.month, now.day, maxHour, maxMinute);
      while (currentTime.isBefore(endTime)) {
        final blockEndTime = currentTime.add(const Duration(minutes: 30));
        // 각 요일별로 breakTime 체크
        // blocks는 시간 단위로만 생성, 요일별 breakTime은 셀에서 판단
        blocks.add(TimeBlock(
          startTime: currentTime,
          endTime: blockEndTime,
          isBreakTime: false, // 기본값 false, 실제 셀에서 판단
        ));
        currentTime = blockEndTime;
      }
    }
    return blocks;
  }

  // 주어진 시간에 수업 중인 학생 블록들을 가져오는 메서드
  List<StudentTimeBlock> _getActiveStudentBlocks(
    List<StudentTimeBlock> allBlocks,
    int dayIndex,
    DateTime checkTime,
    int lessonDurationMinutes,
  ) {
    return allBlocks.where((block) {
      if (block.dayIndex != dayIndex) return false;
      
      final blockEndTime = block.startTime.add(Duration(minutes: lessonDurationMinutes));
      final checkEndTime = checkTime.add(const Duration(minutes: 30));
      
      // 블록이 체크 시간 범위와 겹치는지 확인
      return block.startTime.isBefore(checkEndTime) && blockEndTime.isAfter(checkTime);
    }).toList();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 스크롤 이동 로직 완전 제거
  }

  void _tryScrollToCurrentTime() async {
    await Future.delayed(const Duration(milliseconds: 120));
    _scrollToCurrentTime();
  }

  void _scrollToCurrentTime() {
    final timeBlocks = _generateTimeBlocks();
    final now = TimeOfDay.now();
    int currentIdx = 0;
    for (int i = 0; i < timeBlocks.length; i++) {
      final block = timeBlocks[i];
      if (block.startTime.hour < now.hour || (block.startTime.hour == now.hour && block.startTime.minute <= now.minute)) {
        currentIdx = i;
      }
    }
    final blockHeight = 90.0;
    final visibleRows = 5;
    // 현재 시간이 운영시간 범위 내에 있는지 체크
    final firstBlock = timeBlocks.isNotEmpty ? timeBlocks.first : null;
    final lastBlock = timeBlocks.isNotEmpty ? timeBlocks.last : null;
    int scrollIdx = currentIdx;
    if (firstBlock != null && lastBlock != null) {
      final nowMinutes = now.hour * 60 + now.minute;
      final firstMinutes = firstBlock.startTime.hour * 60 + firstBlock.startTime.minute;
      final lastMinutes = lastBlock.startTime.hour * 60 + lastBlock.startTime.minute;
      if (nowMinutes < firstMinutes) {
        scrollIdx = 0;
      } else if (nowMinutes > lastMinutes) {
        scrollIdx = timeBlocks.length - 1;
      }
    }
    final targetOffset = (scrollIdx - (visibleRows ~/ 2)) * blockHeight;
    if (widget.scrollController.hasClients) {
      final maxOffset = widget.scrollController.position.maxScrollExtent;
      final minOffset = widget.scrollController.position.minScrollExtent;
      final scrollTo = targetOffset.clamp(minOffset, maxOffset);
      widget.scrollController.animateTo(
        scrollTo,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    }
  }

  Widget _buildExpandedStudentCards(List<StudentTimeBlock> cellBlocks, List<Student> students, List<GroupInfo> groups, double cellWidth, bool isExpanded) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        setState(() {
          _expandedCellKey = null;
        });
      },
      child: Container(
        width: cellWidth,
        child: AnimatedScale(
          scale: isExpanded ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 1000),
          curve: Curves.easeOut,
          child: AnimatedOpacity(
            opacity: isExpanded ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 1000),
            child: Wrap(
              spacing: 5,
              runSpacing: 10,
              children: List.generate(cellBlocks.length, (i) {
                final block = cellBlocks[i];
                final student = students.firstWhere((s) => s.id == block.studentId, orElse: () => Student(id: '', name: '', school: '', grade: 0, educationLevel: EducationLevel.elementary, registrationDate: DateTime.now(), weeklyClassCount: 1));
                final groupInfo = block.groupId != null ?
                  groups.firstWhere((g) => g.id == block.groupId, orElse: () => GroupInfo(id: '', name: '', description: '', capacity: 0, duration: 60, color: Colors.grey)) : null;
                return GestureDetector(
                  onTapDown: (details) async {
                    final selected = await showMenu<String>(
                      context: context,
                      position: RelativeRect.fromLTRB(
                        details.globalPosition.dx,
                        details.globalPosition.dy,
                        details.globalPosition.dx + 1,
                        details.globalPosition.dy + 1,
                      ),
                      color: Colors.black,
                      items: [
                        const PopupMenuItem<String>(
                          value: 'edit',
                          child: Text('수정', style: TextStyle(color: Colors.white)),
                        ),
                        const PopupMenuItem<String>(
                          value: 'delete',
                          child: Text('삭제', style: TextStyle(color: Colors.white)),
                        ),
                      ],
                    );
                    if (selected == 'edit') {
                      // TODO: 시간/요일 수정 다이얼로그 진입
                    } else if (selected == 'delete') {
                      // TODO: 삭제 확인 다이얼로그 진입
                    }
                  },
                  child: SizedBox(
                    width: 109,
                    height: 39,
                    child: _StudentTimeBlockCard(student: student, groupInfo: groupInfo),
                  ),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}

class _StudentTimeBlockCard extends StatelessWidget {
  final Student student;
  final GroupInfo? groupInfo;
  const _StudentTimeBlockCard({required this.student, this.groupInfo});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 109,
      height: 39,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey.shade300,
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 5),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (groupInfo != null)
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: groupInfo!.color,
                  shape: BoxShape.circle,
                ),
                margin: const EdgeInsets.only(right: 4),
              ),
            Flexible(
              child: Text(
                student.name,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CapacityCardWidget extends StatefulWidget {
  final int count;
  final Color? color;
  final bool showArrow;
  final bool isExpanded;
  final List<StudentTimeBlock>? expandedBlocks;
  final List<Student>? students;
  final List<GroupInfo>? groups;
  const CapacityCardWidget({
    required this.count,
    this.color,
    this.showArrow = false,
    this.isExpanded = false,
    this.expandedBlocks,
    this.students,
    this.groups,
    Key? key,
  }) : super(key: key);

  @override
  State<CapacityCardWidget> createState() => _CapacityCardWidgetState();
}

class _CapacityCardWidgetState extends State<CapacityCardWidget> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _controller.value = widget.isExpanded ? 1.0 : 0.0;
  }

  @override
  void didUpdateWidget(covariant CapacityCardWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isExpanded != oldWidget.isExpanded) {
      if (widget.isExpanded) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isExpanded && widget.expandedBlocks != null && widget.students != null && widget.groups != null) {
      final cellBlocks = widget.expandedBlocks!;
      final students = widget.students!;
      final groups = widget.groups!;
      return Container(
        width: double.infinity,
        child: AnimatedScale(
          scale: widget.isExpanded ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 1000),
          curve: Curves.easeOut,
          child: AnimatedOpacity(
            opacity: widget.isExpanded ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 1000),
            child: Wrap(
              spacing: 5,
              runSpacing: 10,
              children: List.generate(cellBlocks.length, (i) {
                final block = cellBlocks[i];
                final student = students.firstWhere((s) => s.id == block.studentId, orElse: () => Student(id: '', name: '', school: '', grade: 0, educationLevel: EducationLevel.elementary, registrationDate: DateTime.now(), weeklyClassCount: 1));
                final groupInfo = block.groupId != null ?
                  groups.firstWhere((g) => g.id == block.groupId, orElse: () => GroupInfo(id: '', name: '', description: '', capacity: 0, duration: 60, color: Colors.grey)) : null;
                return GestureDetector(
                  onTapDown: (details) async {
                    final selected = await showMenu<String>(
                      context: context,
                      position: RelativeRect.fromLTRB(
                        details.globalPosition.dx,
                        details.globalPosition.dy,
                        details.globalPosition.dx + 1,
                        details.globalPosition.dy + 1,
                      ),
                      color: Colors.black,
                      items: [
                        const PopupMenuItem<String>(
                          value: 'edit',
                          child: Text('수정', style: TextStyle(color: Colors.white)),
                        ),
                        const PopupMenuItem<String>(
                          value: 'delete',
                          child: Text('삭제', style: TextStyle(color: Colors.white)),
                        ),
                      ],
                    );
                    if (selected == 'edit') {
                      // TODO: 시간/요일 수정 다이얼로그 진입
                    } else if (selected == 'delete') {
                      // TODO: 삭제 확인 다이얼로그 진입
                    }
                  },
                  child: SizedBox(
                    width: 109,
                    height: 39,
                    child: _StudentTimeBlockCard(student: student, groupInfo: groupInfo),
                  ),
                );
              }),
            ),
          ),
        ),
      );
    }
    return Center(
      child: Container(
        width: 110,
        margin: const EdgeInsets.symmetric(vertical: 0, horizontal: 0),
        padding: const EdgeInsets.symmetric(vertical: 0, horizontal: 0),
        constraints: const BoxConstraints(minHeight: 35, maxHeight: 35),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: widget.color ?? Colors.grey,
            width: 2,
          ),
        ),
        child: widget.count > 0
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${widget.count}명',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: widget.color ?? Colors.black87,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  if (widget.showArrow) ...[
                    const SizedBox(width: 6),
                    Icon(
                      Icons.arrow_downward,
                      size: 16,
                      color: widget.color ?? Colors.black87,
                    ),
                  ],
                ],
              )
            : null,
      ),
    );
  }
}

class CapacityCountWidget extends StatelessWidget {
  final int count;
  final Color? color;
  const CapacityCountWidget({
    required this.count,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 110,
        margin: const EdgeInsets.symmetric(vertical: 0, horizontal: 0),
        padding: const EdgeInsets.symmetric(vertical: 0, horizontal: 0),
        constraints: const BoxConstraints(minHeight: 35, maxHeight: 35),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: color ?? Colors.grey,
            width: 2,
          ),
        ),
        child: count > 0
            ? Center(
                child: Text(
                  '$count명',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: color ?? Colors.black87,
                  ),
                  textAlign: TextAlign.center,
                ),
              )
            : null,
      ),
    );
  }
}

class TimeBlock {
  final DateTime startTime;
  final DateTime endTime;
  final bool isBreakTime;

  TimeBlock({
    required this.startTime,
    required this.endTime,
    this.isBreakTime = false,
  });

  String get timeString {
    return _formatTime(startTime);
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
} 