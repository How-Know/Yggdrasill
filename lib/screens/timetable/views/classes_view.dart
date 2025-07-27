import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../../models/operating_hours.dart';
import '../../../models/student_time_block.dart';
import '../../../models/student.dart';
import '../../../models/group_info.dart';
import '../../../services/data_manager.dart';
import '../../../models/education_level.dart';
import '../../../services/data_manager.dart';
import '../../../widgets/app_snackbar.dart';
import 'components/timetable_cell.dart';
import '../components/timetable_drag_selector.dart';
import '../../../models/self_study_time_block.dart';
import 'package:collection/collection.dart';

/// registrationModeType: 'student' | 'selfStudy' | null
typedef RegistrationModeType = String?;

class ClassesView extends StatefulWidget {
  final List<OperatingHours> operatingHours;
  final Color breakTimeColor;
  final bool isRegistrationMode; // deprecated
  final RegistrationModeType registrationModeType;
  final int? selectedDayIndex;
  final void Function(int dayIdx, DateTime startTime)? onTimeSelected;
  final void Function(int dayIdx, List<DateTime> startTimes, List<StudentWithInfo> students)? onCellStudentsSelected;
  final void Function(int dayIdx, DateTime startTime, List<StudentWithInfo> students)? onCellSelfStudyStudentsChanged;
  final ScrollController scrollController;
  final Set<String>? filteredStudentIds; // 추가: 필터된 학생 id 리스트
  final StudentWithInfo? selectedStudentWithInfo; // 변경: 학생+부가정보 통합 객체
  final StudentWithInfo? selectedSelfStudyStudent;
  final void Function(bool)? onSelectModeChanged; // 추가: 선택모드 해제 콜백

  const ClassesView({
    super.key,
    required this.operatingHours,
    this.breakTimeColor = const Color(0xFF424242),
    this.isRegistrationMode = false, // deprecated
    this.registrationModeType,
    this.selectedDayIndex,
    this.onTimeSelected,
    this.onCellStudentsSelected,
    this.onCellSelfStudyStudentsChanged,
    required this.scrollController,
    this.filteredStudentIds, // 추가
    this.selectedStudentWithInfo, // 변경
    this.selectedSelfStudyStudent,
    this.onSelectModeChanged, // 추가
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

  // 드래그 상태 변수 (UI 구조는 그대로, 상태만 추가)
  int? dragStartIdx;
  int? dragEndIdx;
  int? dragDayIdx;
  bool isDragging = false;

  Set<String> get dragHighlightKeys {
    if (!isDragging || dragDayIdx == null || dragStartIdx == null || dragEndIdx == null) return {};
    final start = dragStartIdx!;
    final end = dragEndIdx!;
    final day = dragDayIdx!;
    if (start <= end) {
      return {for (int i = start; i <= end; i++) '$day-$i'};
    } else {
      return {for (int i = end; i <= start; i++) '$day-$i'};
    }
  }

  void _onCellPanStart(int dayIdx, int blockIdx) {
    final timeBlocks = _generateTimeBlocks();
    final blockTime = timeBlocks[blockIdx].startTime;
    if (!_areAllTimesWithinOperatingAndBreak(dayIdx, [blockTime])) {
      showAppSnackBar(context, '이미 등록된 시간입니다.');
      return;
    }
    setState(() {
      dragStartIdx = blockIdx;
      dragEndIdx = blockIdx;
      dragDayIdx = dayIdx;
      isDragging = true;
    });
  }

  void _onCellPanUpdate(int dayIdx, int blockIdx) {
    final timeBlocks = _generateTimeBlocks();
    final blockTime = timeBlocks[blockIdx].startTime;
    if (!isDragging || dragDayIdx != dayIdx) return;
    if (!_areAllTimesWithinOperatingAndBreak(dayIdx, [blockTime])) {
      showAppSnackBar(context, '이미 등록된 시간입니다.');
      return;
    }
    setState(() {
      dragEndIdx = blockIdx;
    });
  }

  void _onCellPanEnd(int dayIdx) async {
    print('[DEBUG][_onCellPanEnd] 호출: dayIdx=$dayIdx, registrationModeType=${widget.registrationModeType}, selectedStudentWithInfo=${widget.selectedStudentWithInfo}, selectedSelfStudyStudent=${widget.selectedSelfStudyStudent}');
    if (!isDragging || dragDayIdx != dayIdx || dragStartIdx == null || dragEndIdx == null) {
      setState(() { isDragging = false; });
      return;
    }
    final start = dragStartIdx!;
    final end = dragEndIdx!;
    final selectedIdxs = start <= end
        ? [for (int i = start; i <= end; i++) i]
        : [for (int i = end; i <= start; i++) i];
    setState(() {
      isDragging = false;
      dragStartIdx = null;
      dragEndIdx = null;
      dragDayIdx = null;
    });
    // 팩토리+DB 저장 로직 호출
    final mode = widget.registrationModeType;
    final timeBlocks = _generateTimeBlocks();
    final startTimes = selectedIdxs.map((blockIdx) => timeBlocks[blockIdx].startTime).toList();

    // [추가] 운영시간/휴식시간 체크 (콜백 호출 전에 반드시 return)
    if (!_areAllTimesWithinOperatingAndBreak(dayIdx, startTimes)) {
      showAppSnackBar(context, '이미 등록된 시간입니다.');
      return;
    }

    // [추가] 이미 등록된 시간(겹침) 체크 (학생/자습 모두)
    bool hasConflict = false;
    if (mode == 'student' && widget.selectedStudentWithInfo != null) {
      final studentId = widget.selectedStudentWithInfo!.student.id;
      final lessonDuration = DataManager.instance.academySettings.lessonDuration;
      for (final startTime in startTimes) {
        if (_isStudentTimeOverlap(studentId, dayIdx, startTime, lessonDuration)) {
          hasConflict = true;
          break;
        }
      }
    } else if (mode == 'selfStudy' && widget.selectedSelfStudyStudent != null) {
      final studentId = widget.selectedSelfStudyStudent!.student.id;
      final blockMinutes = 30; // 자습 블록 길이
      for (final startTime in startTimes) {
        if (_isStudentTimeOverlap(studentId, dayIdx, startTime, blockMinutes)) {
          hasConflict = true;
          break;
        }
      }
    }
    if (hasConflict) {
      showAppSnackBar(context, '이미 등록된 시간입니다.');
      return;
    }
    print('[DEBUG][_onCellPanEnd] mode=$mode, startTimes=$startTimes, selectedStudentWithInfo=${widget.selectedStudentWithInfo}, selectedSelfStudyStudent=${widget.selectedSelfStudyStudent}');
    if (mode == 'student' && widget.selectedStudentWithInfo != null && widget.onCellStudentsSelected != null) {
      print('[DEBUG][_onCellPanEnd] 수업 등록 분기 진입');
      widget.onCellStudentsSelected!(dayIdx, startTimes, [widget.selectedStudentWithInfo!]);
    } else if (mode == 'selfStudy' && widget.selectedSelfStudyStudent != null && widget.onCellStudentsSelected != null) {
      print('[DEBUG][_onCellPanEnd] 자습 등록 분기 진입');
      // 자습 블록 등록 전 중복 체크
      final studentId = widget.selectedSelfStudyStudent!.student.id;
      final blockMinutes = 30; // 자습 블록 길이
      bool hasConflict = false;
      
      for (final startTime in startTimes) {
        if (_isStudentTimeOverlap(studentId, dayIdx, startTime, blockMinutes)) {
          hasConflict = true;
          break;
        }
      }
      
      if (hasConflict) {
        // showAppSnackBar(context, '이미 등록된 수업시간과 겹칩니다. 자습시간을 등록할 수 없습니다.'); // 중복 메시지 제거
        return;
      }
      
      widget.onCellStudentsSelected!(dayIdx, startTimes, [widget.selectedSelfStudyStudent!]);
    } else {
      print('[DEBUG][_onCellPanEnd] 등록 분기 진입 실패: mode=$mode, selectedStudentWithInfo=${widget.selectedStudentWithInfo}, selectedSelfStudyStudent=${widget.selectedSelfStudyStudent}');
    }
  }

  @override
  void dispose() {
    for (var controller in _animationControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isRegistrationMode && _hoveredCellKey != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() { _hoveredCellKey = null; });
      });
    }
    print('[DEBUG][ClassesView.build] isRegistrationMode= [33m${widget.isRegistrationMode} [0m, registrationModeType= [33m${widget.registrationModeType} [0m, selectedStudentWithInfo= [33m${widget.selectedStudentWithInfo} [0m, selectedSelfStudyStudent= [33m${widget.selectedSelfStudyStudent} [0m');
    final timeBlocks = _generateTimeBlocks();
    final double blockHeight = 90.0;
    return Stack(
      children: [
        SingleChildScrollView(
          controller: widget.scrollController,
          child: ValueListenableBuilder<List<StudentTimeBlock>>(
            valueListenable: DataManager.instance.studentTimeBlocksNotifier,
            builder: (context, studentTimeBlocks, _) {
              final selfStudyTimeBlocks = DataManager.instance.selfStudyTimeBlocks;
              // 정원수 카운트 등에는 전체 studentTimeBlocks + selfStudyTimeBlocks를 합친 allBlocks 사용
              final allBlocks = <dynamic>[
                ...DataManager.instance.studentTimeBlocks,
                ...DataManager.instance.selfStudyTimeBlocks,
              ];
              // 학생 리스트 필터 등에는 기존 filteredStudentIds/filteredStudentBlocks 사용
              final filteredStudentBlocks = widget.filteredStudentIds == null
                  ? studentTimeBlocks
                  : studentTimeBlocks.where((b) => widget.filteredStudentIds!.contains(b.studentId)).toList();
              final filteredSelfStudyBlocks = widget.filteredStudentIds == null
                  ? selfStudyTimeBlocks
                  : selfStudyTimeBlocks.where((b) => widget.filteredStudentIds!.contains(b.studentId)).toList();
              print('[DEBUG][ValueListenableBuilder] studentTimeBlocks.length= [33m${studentTimeBlocks.length} [0m, selfStudyTimeBlocks.length= [33m${selfStudyTimeBlocks.length} [0m, allBlocks.length= [33m${allBlocks.length} [0m');
              final studentsWithInfo = DataManager.instance.students;
              final groups = DataManager.instance.groups;
              final lessonDuration = DataManager.instance.academySettings.lessonDuration;
              // 인원수 카운트 등 공통 필드만 쓸 때 allBlocks 사용, StudentTimeBlock만 필요한 곳에는 filteredStudentBlocks만 넘김
              final filteredBlocks = widget.filteredStudentIds == null
                  ? allBlocks
                  : allBlocks.where((b) {
                      if (b is StudentTimeBlock || b is SelfStudyTimeBlock) {
                        return widget.filteredStudentIds!.contains(b.studentId);
                      }
                      return false;
                    }).toList();
              print('[DEBUG][ValueListenableBuilder] filteredBlocks.length=${filteredBlocks.length}, studentsWithInfo.length=${studentsWithInfo.length}, groups.length=${groups.length}, lessonDuration=$lessonDuration');
              return Listener(
                onPointerDown: (event) {
                  print('[DEBUG][Listener] onPointerDown: isRegistrationMode=${widget.isRegistrationMode}, isDragging=$isDragging');
                  if (!widget.isRegistrationMode) return;
                  final box = context.findRenderObject() as RenderBox;
                  final local = box.globalToLocal(event.position);
                  final blockIdx = (local.dy / blockHeight).floor();
                  final dayIdx = ((local.dx - 60) / ((box.size.width - 60) / 7)).floor();
                  print('[DEBUG][Listener] blockIdx=$blockIdx, dayIdx=$dayIdx');
                  if (blockIdx >= 0 && blockIdx < timeBlocks.length && dayIdx >= 0 && dayIdx < 7) {
                    _onCellPanStart(dayIdx, blockIdx);
                  }
                },
                onPointerMove: (event) {
                  if (!widget.isRegistrationMode || !isDragging) return;
                  final box = context.findRenderObject() as RenderBox;
                  final local = box.globalToLocal(event.position);
                  final blockIdx = (local.dy / blockHeight).floor();
                  final dayIdx = ((local.dx - 60) / ((box.size.width - 60) / 7)).floor();
                  print('[DEBUG][Listener] onPointerMove: blockIdx=$blockIdx, dayIdx=$dayIdx, dragDayIdx=$dragDayIdx');
                  if (blockIdx >= 0 && blockIdx < timeBlocks.length && dayIdx == dragDayIdx) {
                    _onCellPanUpdate(dayIdx, blockIdx);
                  }
                },
                onPointerUp: (event) {
                  print('[DEBUG][Listener] onPointerUp: isDragging=$isDragging, dragDayIdx=$dragDayIdx');
                  if (!widget.isRegistrationMode || !isDragging) return;
                  if (dragDayIdx != null) {
                    _onCellPanEnd(dragDayIdx!);
                  }
                },
                child: Column(
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
                                        color: const Color(0xFF1976D2),
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
                              final activeBlocks = _getActiveStudentBlocks(
                                filteredStudentBlocks, // 반드시 StudentTimeBlock만!
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
                              final isDragHighlight = dragHighlightKeys.contains(cellKey);
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
                              // 시:분만 비교하는 함수
                              bool isSameTime(DateTime a, DateTime b) => a.hour == b.hour && a.minute == b.minute;
                              // 학생별 중복 없이, 요일+시:분이 같은 학생만 카운트
                              final activeStudentIds = allBlocks
                                .where((b) =>
                                  (b is StudentTimeBlock || b is SelfStudyTimeBlock) &&
                                  b.dayIndex == dayIdx &&
                                  isSameTime(b.startTime, timeBlocks[blockIdx].startTime)
                                )
                                .map((b) => b.studentId)
                                .toSet();
                              final activeStudentCount = activeStudentIds.length;
                              Color? countColor;
                              if (activeStudentCount > 0) {
                                if (activeStudentCount < DataManager.instance.academySettings.defaultCapacity * 0.7) {
                                  countColor = const Color(0xFF0C3A69);
                                } else if (activeStudentCount >= DataManager.instance.academySettings.defaultCapacity) {
                                  countColor = const Color(0xFFFB8C00);
                                } else {
                                  countColor = const Color(0xFF212A31);
                                }
                              } else {
                                countColor = const Color(0xFF0C3A69);
                              }
                              if (isDragHighlight) {
                                print('[DEBUG][Cell] isDragHighlight: cellKey=$cellKey, dragHighlightKeys=$dragHighlightKeys');
                              }
                              return Expanded(
                                child: MouseRegion(
                                  onEnter: (_) {
                                    if (widget.isRegistrationMode) {
                                      setState(() {
                                        _hoveredCellKey = cellKey;
                                        print('[DEBUG][MouseRegion] onEnter: cellKey=$cellKey, isRegistrationMode=${widget.isRegistrationMode}');
                                      });
                                    }
                                  },
                                  onExit: (_) {
                                    if (widget.isRegistrationMode) {
                                      setState(() {
                                        if (_hoveredCellKey == cellKey) _hoveredCellKey = null;
                                        print('[DEBUG][MouseRegion] onExit: cellKey=$cellKey, isRegistrationMode=${widget.isRegistrationMode}');
                                      });
                                    }
                                  },
                                  child: GestureDetector(
                                    onTap: () async {
                                      final lessonDuration = DataManager.instance.academySettings.lessonDuration;
                                      final selectedStudentWithInfo = widget.selectedStudentWithInfo;
                                      final studentId = selectedStudentWithInfo?.student.id;
                                      print('[DEBUG][Cell onTap] cellKey=$cellKey, isRegistrationMode=${widget.isRegistrationMode}, selectedStudentWithInfo=$selectedStudentWithInfo');
                                      if (studentId != null && _isStudentTimeOverlap(studentId, dayIdx, timeBlocks[blockIdx].startTime, lessonDuration)) {
                                        return;
                                      }
                                      if (widget.isRegistrationMode && widget.onCellStudentsSelected != null && selectedStudentWithInfo != null) {
                                        print('[DEBUG][등록시도] studentId=${selectedStudentWithInfo.student.id}, dayIdx=$dayIdx, startTime=${timeBlocks[blockIdx].startTime}');
                                        widget.onCellStudentsSelected!(
                                          dayIdx,
                                          [timeBlocks[blockIdx].startTime],
                                          [selectedStudentWithInfo],
                                        );
                                      } else if (widget.onTimeSelected != null) {
                                        // 자습 블록이 있는 경우 자습 블록 수정 콜백 호출
                                        final selfStudyBlocks = DataManager.instance.selfStudyTimeBlocks.where((block) {
                                          if (block.dayIndex != dayIdx) return false;
                                          final blockStartMinutes = block.startTime.hour * 60 + block.startTime.minute;
                                          final blockEndMinutes = blockStartMinutes + block.duration.inMinutes;
                                          final checkMinutes = timeBlocks[blockIdx].startTime.hour * 60 + timeBlocks[blockIdx].startTime.minute;
                                          return checkMinutes >= blockStartMinutes && checkMinutes < blockEndMinutes;
                                        }).toList();
                                        
                                        if (selfStudyBlocks.isNotEmpty && widget.onCellSelfStudyStudentsChanged != null) {
                                          final studentsWithInfo = DataManager.instance.students;
                                          final cellSelfStudyStudentWithInfos = selfStudyBlocks.map((b) => studentsWithInfo.firstWhere(
                                            (s) => s.student.id == b.studentId,
                                            orElse: () => StudentWithInfo(student: Student(id: '', name: '', school: '', grade: 0, educationLevel: EducationLevel.elementary, registrationDate: DateTime.now(), weeklyClassCount: 1), basicInfo: StudentBasicInfo(studentId: '', registrationDate: DateTime.now())),
                                          )).toList();
                                          widget.onCellSelfStudyStudentsChanged!(dayIdx, timeBlocks[blockIdx].startTime, cellSelfStudyStudentWithInfos);
                                        }
                                        
                                        widget.onTimeSelected!(dayIdx, timeBlocks[blockIdx].startTime);
                                      }
                                      // 선택모드 해제: 셀 클릭 시 onSelectModeChanged(false) 호출
                                      if (widget.onSelectModeChanged != null) {
                                        widget.onSelectModeChanged!(false);
                                      }
                                    },
                                    child: TimetableCell(
                                      dayIdx: dayIdx,
                                      blockIdx: blockIdx,
                                      cellKey: cellKey,
                                      startTime: timeBlocks[blockIdx].startTime,
                                      endTime: timeBlocks[blockIdx].endTime,
                                      students: activeBlocks,
                                      isBreakTime: isBreakTime,
                                      isExpanded: isExpanded,
                                      isDragHighlight: isDragHighlight,
                                      onTap: null,
                                      countColor: countColor,
                                      activeStudentCount: activeStudentCount,
                                      cellStudentWithInfos: cellStudentWithInfos,
                                      groups: groups,
                                      cellWidth: 0, // 필요시 전달
                                      registrationModeType: widget.registrationModeType,
                                    ),
                                  ),
                                ),
                              );
                            }),
                          ],
                        ),
                      ),
                  ],
                ),
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

  // 학생의 기존 시간표와 (요일, 시작시간, 수업시간) 겹침 여부 체크
  bool _isStudentTimeOverlap(String studentId, int dayIndex, DateTime startTime, int lessonDurationMinutes) {
    // 수업 블록과 자습 블록 모두 체크
    final studentBlocks = DataManager.instance.studentTimeBlocks.where((b) => b.studentId == studentId).toList();
    final selfStudyBlocks = DataManager.instance.selfStudyTimeBlocks.where((b) => b.studentId == studentId).toList();
    
    final newStart = startTime.hour * 60 + startTime.minute;
    final newEnd = newStart + lessonDurationMinutes;
    
    // 수업 블록 체크
    for (final block in studentBlocks) {
      final blockStart = block.startTime.hour * 60 + block.startTime.minute;
      final blockEnd = blockStart + block.duration.inMinutes;
      if (block.dayIndex == dayIndex && newStart < blockEnd && newEnd > blockStart) {
        print('[DEBUG][_isStudentTimeOverlap] 수업 블록 중복 감지: studentId=$studentId, dayIndex=$dayIndex, startTime=$startTime, block= [33m${block.toJson()} [0m');
        return true;
      }
    }
    
    // 자습 블록 체크
    for (final block in selfStudyBlocks) {
      final blockStart = block.startTime.hour * 60 + block.startTime.minute;
      final blockEnd = blockStart + block.duration.inMinutes;
      if (block.dayIndex == dayIndex && newStart < blockEnd && newEnd > blockStart) {
        print('[DEBUG][_isStudentTimeOverlap] 자습 블록 중복 감지: studentId=$studentId, dayIndex=$dayIndex, startTime=$startTime, block= [33m${block.toJson()} [0m');
        return true;
      }
    }
    
    print('[DEBUG][_isStudentTimeOverlap] 중복 없음: studentId=$studentId, dayIndex=$dayIndex, startTime=$startTime');
    return false;
  }

  // [추가] 운영시간/휴식시간 체크 함수
  bool _areAllTimesWithinOperatingAndBreak(int dayIdx, List<DateTime> times) {
    final op = widget.operatingHours.firstWhereOrNull((o) => o.dayOfWeek == dayIdx + 1);
    if (op == null) return false;
    for (final t in times) {
      // 운영시간 내인지
      final tMinutes = t.hour * 60 + t.minute;
      final opStart = op.startTime.hour * 60 + op.startTime.minute;
      final opEnd = op.endTime.hour * 60 + op.endTime.minute;
      if (tMinutes < opStart || tMinutes >= opEnd) return false;
      // 휴식시간과 겹치는지
      for (final br in op.breakTimes) {
        final brStart = br.startTime.hour * 60 + br.startTime.minute;
        final brEnd = br.endTime.hour * 60 + br.endTime.minute;
        if (tMinutes >= brStart && tMinutes < brEnd) return false;
      }
    }
    return true;
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

  Widget _buildExpandedStudentCards(List<StudentTimeBlock> cellBlocks, List<StudentWithInfo> studentsWithInfo, List<GroupInfo> groups, double cellWidth, bool isExpanded) {
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
                final studentWithInfo = studentsWithInfo.firstWhere((s) => s.student.id == block.studentId, orElse: () => StudentWithInfo(student: Student(id: '', name: '', school: '', grade: 0, educationLevel: EducationLevel.elementary, registrationDate: DateTime.now(), weeklyClassCount: 1), basicInfo: StudentBasicInfo(studentId: '', registrationDate: DateTime.now())));
                final groupInfo = block.groupId != null ?
                  groups.firstWhere((g) => g.id == block.groupId, orElse: () => GroupInfo(id: '', name: '', description: '', capacity: 0, duration: 60, color: Colors.grey)) : null;
                // 삭제된 학생이면 카드 자체를 렌더링하지 않음
                if (studentWithInfo.student.id.isEmpty) return const SizedBox.shrink();
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
                    if (selected == 'delete') {
                      try {
                        if (block.setId != null) {
                          final allBlocks = DataManager.instance.studentTimeBlocks;
                          // 같은 학생 id와 set_id를 모두 만족하는 블록만 삭제
                          final toDelete = allBlocks.where((b) => b.setId == block.setId && b.studentId == block.studentId).toList();
                          print('[삭제드롭존][진단] 전체 블록 setId 목록: ' + allBlocks.map((b) => b.setId).toList().toString());
                          print('[삭제드롭존][진단] 전체 블록 studentId 목록: ' + allBlocks.map((b) => b.studentId).toList().toString());
                          print('[삭제드롭존] setId=${block.setId}, studentId=${block.studentId}, 삭제 대상 블록 개수: ${toDelete.length}');
                          for (final b in toDelete) {
                            print('[삭제드롭존] 삭제 시도: block.id=${b.id}, block.setId=${b.setId}, block.studentId=${b.studentId}, block.dayIndex=${b.dayIndex}, block.startTime=${b.startTime}');
                            await DataManager.instance.removeStudentTimeBlock(b.id);
                          }
                        } else {
                          print('[삭제드롭존] setId=null, 단일 삭제: block.id=${block.id}');
                          await DataManager.instance.removeStudentTimeBlock(block.id);
                        }
                      } catch (_) {}
                    }
                  },
                  child: SizedBox(
                    width: 109,
                    height: 39,
                    child: _StudentTimeBlockCard(student: studentWithInfo.student, groupInfo: groupInfo),
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