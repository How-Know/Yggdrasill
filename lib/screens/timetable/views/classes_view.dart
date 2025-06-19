import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../models/operating_hours.dart';
import '../../../models/student_time_block.dart';
import '../../../models/student.dart';
import '../../../models/class_info.dart';
import '../../../services/data_manager.dart';
import '../../../models/education_level.dart';

class ClassesView extends StatefulWidget {
  final List<OperatingHours> operatingHours;
  final Color breakTimeColor;
  final bool isRegistrationMode;
  final int? selectedDayIndex;
  final Function(DateTime)? onTimeSelected;

  const ClassesView({
    super.key,
    required this.operatingHours,
    this.breakTimeColor = const Color(0xFF424242),
    this.isRegistrationMode = false,
    this.selectedDayIndex,
    this.onTimeSelected,
  });

  @override
  State<ClassesView> createState() => _ClassesViewState();
}

class _ClassesViewState extends State<ClassesView> with TickerProviderStateMixin {
  // (요일, 시간) => 펼침 여부
  final Map<String, bool> _expandedCells = {};
  // (요일, 시간) => AnimationController
  final Map<String, AnimationController> _animationControllers = {};
  final Map<String, Animation<double>> _animations = {};

  @override
  void dispose() {
    for (var controller in _animationControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<StudentTimeBlock>>(
      valueListenable: DataManager.instance.studentTimeBlocksNotifier,
      builder: (context, studentTimeBlocks, _) {
        final timeBlocks = _generateTimeBlocks();
        final double blockHeight = 90.0;
        final students = DataManager.instance.students;
        final classes = DataManager.instance.classes;
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
                      final isExpanded = _expandedCells[cellKey] ?? false;
                      final isHighlight = widget.isRegistrationMode && widget.selectedDayIndex == dayIdx;
                      
                      // 수업 정원 확인을 위한 클래스 정보 가져오기
                      final activeStudentCount = activeBlocks.length;
                      Color? countColor;
                      int? totalCapacity;
                      
                      if (activeStudentCount > 0) {
                        // 활성 블록들의 클래스 정원 합계 계산
                        final classCapacities = activeBlocks
                            .map((b) => b.classId)
                            .where((id) => id != null)
                            .toSet()
                            .map((classId) => classes.firstWhere((c) => c.id == classId, 
                                orElse: () => ClassInfo(id: '', name: '', description: '', capacity: 30, duration: 60, color: Colors.grey)))
                            .map((c) => c.capacity)
                            .fold(0, (sum, capacity) => sum + capacity);
                        
                        totalCapacity = classCapacities > 0 ? classCapacities : DataManager.instance.academySettings.defaultCapacity;
                        
                        final occupancyRate = activeStudentCount / totalCapacity;
                        if (occupancyRate >= 1.0) {
                          countColor = Colors.red;
                        } else if (occupancyRate <= 0.8) {
                          countColor = Colors.green;
                        } else {
                          countColor = Colors.orange;
                        }
                      }
                      
                      return Expanded(
                        child: GestureDetector(
                          onTap: () {
                            if (widget.isRegistrationMode && widget.selectedDayIndex == dayIdx && widget.onTimeSelected != null) {
                              widget.onTimeSelected!(timeBlocks[blockIdx].startTime);
                            } else if (cellBlocks.isNotEmpty) {
                              setState(() {
                                final wasExpanded = _expandedCells[cellKey] ?? false;
                                _expandedCells[cellKey] = !wasExpanded;
                                
                                // 애니메이션 컨트롤러 생성 또는 재사용
                                if (!_animationControllers.containsKey(cellKey)) {
                                  final controller = AnimationController(
                                    duration: const Duration(milliseconds: 300),
                                    vsync: this,
                                  );
                                  _animationControllers[cellKey] = controller;
                                  _animations[cellKey] = CurvedAnimation(
                                    parent: controller,
                                    curve: Curves.easeInOut,
                                  );
                                }
                                
                                if (!wasExpanded) {
                                  _animationControllers[cellKey]!.forward();
                                } else {
                                  _animationControllers[cellKey]!.reverse();
                                }
                              });
                            }
                          },
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Container(
                                decoration: BoxDecoration(
                                  color: isHighlight ? const Color(0xFF1976D2).withOpacity(0.10) : Colors.transparent,
                                  border: Border(
                                    left: BorderSide(
                                      color: Colors.white.withOpacity(0.1),
                                    ),
                                  ),
                                ),
                                child: cellBlocks.isEmpty
                                    ? (activeStudentCount > 0 
                                        ? Center(
                                            child: Container(
                                              margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                                              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                                              decoration: BoxDecoration(
                                                color: countColor?.withOpacity(0.2) ?? Colors.grey.shade300,
                                                borderRadius: BorderRadius.circular(8),
                                                border: Border.all(
                                                  color: countColor ?? Colors.grey.shade300,
                                                  width: 2,
                                                ),
                                              ),
                                              child: Text(
                                                '${activeStudentCount}명',
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w600,
                                                  color: countColor ?? Colors.black87,
                                                ),
                                                textAlign: TextAlign.center,
                                              ),
                                            ),
                                          )
                                        : null)
                                    : !isExpanded
                                        ? _CollapsedStudentBlock(
                                            count: activeStudentCount > 0 ? activeStudentCount : cellBlocks.length,
                                            color: countColor,
                                          )
                                        : null,
                              ),
                              if (isExpanded && cellBlocks.isNotEmpty)
                                Positioned(
                                  top: 0,
                                  left: 0,
                                  right: 0,
                                  child: AnimatedBuilder(
                                    animation: _animations[cellKey] ?? const AlwaysStoppedAnimation(1.0),
                                    builder: (context, child) {
                                      final animation = _animations[cellKey] ?? const AlwaysStoppedAnimation(1.0);
                                      return SlideTransition(
                                        position: Tween<Offset>(
                                          begin: const Offset(0, -0.5),
                                          end: Offset.zero,
                                        ).animate(animation),
                                        child: FadeTransition(
                                          opacity: animation,
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: Colors.black,
                                              borderRadius: BorderRadius.circular(8),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.black.withOpacity(0.3),
                                                  blurRadius: 8,
                                                  offset: const Offset(0, 2),
                                                ),
                                              ],
                                            ),
                                            padding: const EdgeInsets.all(4),
                                            child: Wrap(
                                              spacing: 4,
                                              runSpacing: 4,
                                              children: cellBlocks.map((block) {
                                                final student = students.firstWhere((s) => s.id == block.studentId, orElse: () => Student(
                                                  id: '', name: '알 수 없음', school: '', grade: 0, educationLevel: EducationLevel.elementary, registrationDate: DateTime.now()));
                                                final classInfo = block.classId != null ?
                                                  classes.firstWhere((c) => c.id == block.classId, orElse: () => ClassInfo(id: '', name: '', description: '', capacity: 0, duration: 60, color: Colors.grey)) : null;
                                                final columnWidth = (MediaQuery.of(context).size.width - 60) / 7;
                                                return SizedBox(
                                                  width: (columnWidth - 20) / 3 - 5,
                                                  child: _StudentTimeBlockCard(student: student, classInfo: classInfo),
                                                );
                                              }).toList(),
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  List<TimeBlock> _generateTimeBlocks() {
    final List<TimeBlock> blocks = [];
    
    // 첫 번째 운영시간만 사용하여 시간 블록 생성 (중복 방지)
    if (widget.operatingHours.isNotEmpty) {
      final hours = widget.operatingHours.first;
      var currentTime = hours.startTime;
      
      while (currentTime.isBefore(hours.endTime)) {
        // 30분 단위로 변경
        final endTime = currentTime.add(const Duration(minutes: 30));
        final isBreakTime = hours.breakTimes.any((breakTime) =>
            (currentTime.isAfter(breakTime.startTime) || currentTime.isAtSameMomentAs(breakTime.startTime)) &&
            currentTime.isBefore(breakTime.endTime));
        
        blocks.add(
          TimeBlock(
            startTime: currentTime,
            endTime: endTime,
            isBreakTime: isBreakTime,
          ),
        );
        currentTime = endTime;
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
}

class _StudentTimeBlockCard extends StatelessWidget {
  final Student student;
  final ClassInfo? classInfo;
  const _StudentTimeBlockCard({required this.student, this.classInfo});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade300,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (classInfo != null)
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: classInfo!.color,
                shape: BoxShape.circle,
              ),
              margin: const EdgeInsets.only(right: 4),
            ),
          Flexible(
            child: Text(
              student.name,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _CollapsedStudentBlock extends StatelessWidget {
  final int count;
  final Color? color;
  const _CollapsedStudentBlock({required this.count, this.color});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        decoration: BoxDecoration(
          color: color?.withOpacity(0.2) ?? Colors.grey.shade300,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: color ?? Colors.grey.shade300,
            width: 2,
          ),
        ),
        child: Text(
          '학생 $count명',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: color ?? Colors.black87,
          ),
          textAlign: TextAlign.center,
        ),
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