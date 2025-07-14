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
                            child: Row(
                              children: [
                                if (blockIdx == _getCurrentTimeBlockIndex(timeBlocks))
                                  Container(
                                    width: 8,
                                    height: blockHeight - 10,
                                    margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 0),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF1976D2), // 시그니처 색상(탭바 인디케이터와 동일)
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                  ),
                                Expanded(
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
                              ],
                            ),
                          ),
                          // Day columns
                          ...List.generate(7, (dayIdx) {
                            final cellKey = '$dayIdx-$blockIdx';
                            _cellKeys.putIfAbsent(cellKey, () => GlobalKey());
                            // 셀 내부에서 학생카드와 인원수 카운트 모두 activeBlocks 기준으로 표시
                            final activeBlocks = _getActiveStudentBlocks(
                              studentTimeBlocks, 
                              dayIdx, 
                              timeBlocks[blockIdx].startTime,
                              lessonDuration,
                            );
                            final cellStudentWithInfos = activeBlocks.map((b) => studentsWithInfo.firstWhere(
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
                                      child: Stack(
                                        children: [
                                          // 셀 배경 및 경계선(구분선)은 그대로 유지
                                          Container(
                                            decoration: BoxDecoration(
                                              color: isBreakTime
                                                ? const Color(0xFF1F1F1F) // 프로그램 배경색
                                                : (_hoveredCellKey == cellKey && widget.isRegistrationMode)
                                                  ? const Color(0xFF1976D2).withOpacity(0.10)
                                                  : Colors.transparent,
                                              border: Border(
                                                left: BorderSide(
                                                  color: Colors.white.withOpacity(0.1),
                                                ),
                                              ),
                                            ),
                                          ),
                                          // 휴식시간 셀: 중앙에 '휴식' 텍스트만 표시, 나머지 위젯은 출력하지 않음
                                          if (isBreakTime)
                                            Center(
                                              child: Text(
                                                '휴식',
                                                style: TextStyle(
                                                  color: Colors.grey.shade400, // 앱바 타이틀 색상
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            )
                                          else ...[
                                            // 인원수 카드: 0명이면 아무것도 출력하지 않음, 1명 이상이면 상단에 붙임
                                            if (activeStudentCount > 0)
                                              Positioned(
                                                top: 0,
                                                left: 0,
                                                right: 0,
                                                child: CapacityCardWidget(
                                                  count: activeStudentCount,
                                                  color: countColor,
                                                ),
                                              ),
                                            // 펼침 상태일 때만 학생카드 그리드 + 닫힘 GestureDetector
                                            if (isExpanded && activeBlocks.isNotEmpty)
                                              _buildExpandedStudentCards(
                                                activeBlocks,
                                                activeBlocks.map((b) =>
                                                  studentsWithInfo.firstWhere(
                                                    (s) => s.student.id == b.studentId,
                                                    orElse: () => StudentWithInfo(
                                                      student: Student(id: '', name: '', school: '', grade: 0, educationLevel: EducationLevel.elementary, registrationDate: DateTime.now(), weeklyClassCount: 1),
                                                      basicInfo: StudentBasicInfo(studentId: '', registrationDate: DateTime.now()),
                                                    )
                                                  ).student
                                                ).toList(),
                                                groups,
                                                constraints.maxWidth,
                                                isExpanded,
                                              ),
                                          ],
                                        ],
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
      // 날짜 무시, 요일+시:분+duration만 비교
      final blockStartMinutes = block.startTime.hour * 60 + block.startTime.minute;
      final blockEndMinutes = blockStartMinutes + block.duration.inMinutes;
      final checkMinutes = checkTime.hour * 60 + checkTime.minute;
      return checkMinutes >= blockStartMinutes && checkMinutes < blockEndMinutes;
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
                // 삭제된 학생이면 카드 자체를 렌더링하지 않음
                if (student.id.isEmpty) return const SizedBox.shrink();
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
                      try {
                        await DataManager.instance.removeStudentTimeBlock(block.id);
                      } catch (_) {}
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

class CapacityCardWidget extends StatelessWidget {
  final int count;
  final Color? color;
  final double cellHeight;
  const CapacityCardWidget({
    required this.count,
    this.color,
    this.cellHeight = 90.0,
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 색상 인디케이터(막대) - 셀 전체 높이, 둥근 직사각형
        Container(
          width: 11, // 기존 8에서 20% 증가
          height: cellHeight,
          margin: EdgeInsets.zero,
          decoration: BoxDecoration(
            color: color ?? Colors.blue,
            borderRadius: BorderRadius.circular(5), // 둥근 직사각형
          ),
        ),
        // 인원수 바 (셀 전체 너비, 배경색)
        Expanded(
          child: Container(
            height: 28,
            width: double.infinity,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
            decoration: BoxDecoration(
              color: Colors.transparent, // 배경색 완전 투명
              borderRadius: const BorderRadius.only(
                topRight: Radius.circular(8),
                bottomRight: Radius.circular(8),
              ),
            ),
            child: Text(
              '$count', // 숫자만 표시
              style: const TextStyle(
                fontSize: 22, // 기존 15에서 2포인트 증가
                fontWeight: FontWeight.w600,
                color: Colors.white70, // 요일 row와 동일한 회색
              ),
            ),
          ),
        ),
      ],
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

int _getCurrentTimeBlockIndex(List<TimeBlock> timeBlocks) {
  final now = DateTime.now();
  int currentIdx = 0;
  for (int i = 0; i < timeBlocks.length; i++) {
    final block = timeBlocks[i];
    if (block.startTime.hour < now.hour || (block.startTime.hour == now.hour && block.startTime.minute <= now.minute)) {
      currentIdx = i;
    }
  }
  // 운영시간 외일 때(현재 시간이 마지막 블록보다 늦음) 마지막 셀에 인디케이터
  final lastBlock = timeBlocks.isNotEmpty ? timeBlocks.last : null;
  if (lastBlock != null) {
    final nowMinutes = now.hour * 60 + now.minute;
    final lastMinutes = lastBlock.startTime.hour * 60 + lastBlock.startTime.minute;
    if (nowMinutes > lastMinutes) {
      return timeBlocks.length - 1;
    }
  }
  return currentIdx;
} 