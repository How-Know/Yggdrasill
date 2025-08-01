import 'package:flutter/material.dart';
import '../../models/group_info.dart';
import '../../models/operating_hours.dart';
import '../../models/student.dart';
import '../../services/data_manager.dart';
import '../../widgets/student_search_dialog.dart';
import '../../widgets/group_schedule_dialog.dart';
import '../../models/group_schedule.dart';
import 'components/timetable_header.dart';
import 'views/classes_view.dart';
import '../../models/student_time_block.dart';
import 'package:uuid/uuid.dart';
import '../../models/education_level.dart';
import '../../widgets/custom_tab_bar.dart';
import '../../widgets/app_bar_title.dart';
import 'package:morphable_shape/morphable_shape.dart';
import 'package:dimension/dimension.dart';
import 'components/timetable_content_view.dart';
import '../../widgets/app_snackbar.dart';
import 'package:flutter/services.dart';
import 'components/self_study_registration_view.dart';
import '../../models/self_study_time_block.dart';
import 'package:collection/collection.dart'; // Added for firstWhereOrNull
import 'views/attendance_view.dart';

enum TimetableViewType {
  classes,    // 수업
  schedule,   // 일정
  attendance; // 출석

  String get name {
    switch (this) {
      case TimetableViewType.classes:
        return '수업';
      case TimetableViewType.schedule:
        return '일정';
      case TimetableViewType.attendance:
        return '출석';
    }
  }
}

class TimetableScreen extends StatefulWidget {
  const TimetableScreen({Key? key}) : super(key: key);

  @override
  State<TimetableScreen> createState() => _TimetableScreenState();
}

class _TimetableScreenState extends State<TimetableScreen> {
  DateTime _selectedDate = DateTime.now();
  List<GroupInfo> _groups = [];
  TimetableViewType _viewType = TimetableViewType.classes;
  List<OperatingHours> _operatingHours = [];
  final MenuController _menuController = MenuController();
  int? _selectedDayIndex = null;
  int? _selectedStartTimeHour;
  int? _selectedStartTimeMinute;
  bool _isStudentRegistrationMode = false;
  bool _isClassRegistrationMode = false;
  String _registrationButtonText = '등록';
  GroupInfo? _selectedGroup;
  GroupSchedule? _currentGroupSchedule;
  bool _showOperatingHoursAlert = false;
  // SplitButton 관련 상태 추가
  String _splitButtonSelected = '학생';
  bool _isDropdownOpen = false;
  int _segmentIndex = 0; // 0: 모두, 1: 학년, 2: 학교, 3: 그룹
  // 클래스 멤버에 선택된 학생 상태 추가
  StudentWithInfo? _selectedStudentWithInfo; // 추가: 학생+부가정보 통합 객체
  // 학생 연속 등록을 위한 상태 변수 추가
  int? _remainingRegisterCount;
  final ScrollController _timetableScrollController = ScrollController();
  bool _hasScrolledToCurrentTime = false;
  bool _hasScrolledOnTabClick = false; // 탭 클릭 시 스크롤 플래그 추가
  // 셀 선택 시 학생 리스트 상태 추가
  // 학생 리스트는 timetable_content_view.dart에서 계산
  int? _selectedCellDayIndex; // 셀 선택시 요일 인덱스
  final FocusNode _focusNode = FocusNode();
  // 필터 chips 상태
  Set<String> _selectedEducationLevels = {};
  Set<String> _selectedGrades = {};
  Set<String> _selectedSchools = {};
  Set<String> _selectedGroups = {};
  Set<String> _selectedClasses = {}; // 수업별 필터링 추가
  // 실제 적용된 필터 상태
  Map<String, Set<String>>? _activeFilter;
  // TimetableContentView의 검색 리셋 메서드에 접근하기 위한 key
  final GlobalKey<TimetableContentViewState> _contentViewKey = GlobalKey<TimetableContentViewState>();
  // 선택 모드 및 선택 학생 상태 추가
  bool _isSelectMode = false;
  Set<String> _selectedStudentIds = {};
  // 자습 등록 모드 상태
  bool _isSelfStudyRegistrationMode = false;
  StudentWithInfo? _selectedSelfStudyStudent;

  @override
  void initState() {
    super.initState();
    _loadData();
    _loadOperatingHours();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 운영시간 로드 후에만 스크롤 이동하도록 변경 (여기서는 호출하지 않음)
    // if (!_hasScrolledToCurrentTime) {
    //   WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrentTime());
    //   _hasScrolledToCurrentTime = true;
    // }
  }

  void _scrollToCurrentTime() {
    final timeBlocks = _generateTimeBlocks();
    // 타임블록 개수 및 각 블록 정보 로그 출력
    print('[DEBUG][_scrollToCurrentTime] timeBlocks.length: ' + timeBlocks.length.toString());
    for (int i = 0; i < timeBlocks.length; i++) {
      final block = timeBlocks[i];
      print('[DEBUG][_scrollToCurrentTime] block[$i]: ' + TimeOfDay(hour: block.startTime.hour, minute: block.startTime.minute).format(context) + ' ~ ' + block.endTime.toString());
    }
    // 대한민국 표준시(KST)로 현재 시간 계산
    final nowKst = DateTime.now().toUtc().add(const Duration(hours: 9));
    final now = TimeOfDay(hour: nowKst.hour, minute: nowKst.minute);
    print('[DEBUG][_scrollToCurrentTime] nowKst: ' + nowKst.toString() + ', now: ' + now.format(context));
    int currentIdx = 0;
    for (int i = 0; i < timeBlocks.length; i++) {
      final block = timeBlocks[i];
      if (block.startTime.hour < now.hour || (block.startTime.hour == now.hour && block.startTime.minute <= now.minute)) {
        currentIdx = i;
      }
    }
    final blockHeight = 90.0;
    final visibleRows = 5;
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
    print('[DEBUG][_scrollToCurrentTime] scrollIdx: ' + scrollIdx.toString() + ', targetOffset: ' + targetOffset.toString());
    if (_timetableScrollController.hasClients) {
      final maxOffset = _timetableScrollController.position.maxScrollExtent;
      final minOffset = _timetableScrollController.position.minScrollExtent;
      final scrollTo = targetOffset.clamp(minOffset, maxOffset);
      print('[DEBUG][_scrollToCurrentTime] scrollTo: ' + scrollTo.toString() + ', minOffset: ' + minOffset.toString() + ', maxOffset: ' + maxOffset.toString());
      _timetableScrollController.animateTo(
        scrollTo,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    } else {
      print('[DEBUG][_scrollToCurrentTime] _timetableScrollController.hasClients == false');
    }
  }

  List<TimeBlock> _generateTimeBlocks() {
    // ClassesView의 _generateTimeBlocks 로직 복사
    final List<TimeBlock> blocks = [];
    if (_operatingHours.isNotEmpty) {
      final now = DateTime.now();
      int minHour = 23, minMinute = 59, maxHour = 0, maxMinute = 0;
      for (final hours in _operatingHours) {
        if (hours.startHour < minHour || (hours.startHour == minHour && hours.startMinute < minMinute)) {
          minHour = hours.startHour;
          minMinute = hours.startMinute;
        }
        if (hours.endHour > maxHour || (hours.endHour == maxHour && hours.endMinute > maxMinute)) {
          maxHour = hours.endHour;
          maxMinute = hours.endMinute;
        }
      }
      var currentTime = DateTime(now.year, now.month, now.day, minHour, minMinute);
      final endTime = DateTime(now.year, now.month, now.day, maxHour, maxMinute);
      while (currentTime.isBefore(endTime)) {
        final blockEndTime = currentTime.add(const Duration(minutes: 30));
        blocks.add(TimeBlock(
          startTime: currentTime,
          endTime: blockEndTime,
          isBreakTime: false,
        ));
        currentTime = blockEndTime;
      }
    }
    return blocks;
  }

  Future<void> _loadData() async {
    await DataManager.instance.loadGroups();
    setState(() {
      _groups = List.from(DataManager.instance.groups);
    });
  }

  Future<void> _loadOperatingHours() async {
    final hours = await DataManager.instance.getOperatingHours();
    setState(() {
      _operatingHours = hours;
    });
    // 운영시간 로드 후에만 스크롤 이동 시도
    if (!_hasScrolledToCurrentTime) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrentTime());
      _hasScrolledToCurrentTime = true;
    }
    // 운영시간 외 학생 시간 삭제 및 안내
    final allHours = hours;
    final toRemove = <StudentTimeBlock>[];
    for (final block in DataManager.instance.studentTimeBlocks) {
      final op = allHours.firstWhereOrNull((o) => o.dayOfWeek == block.dayIndex);
      if (op == null) {
        toRemove.add(block);
        continue;
      }
      final blockMinutes = block.startHour * 60 + block.startMinute;
      final startMinutes = op.startHour * 60 + op.startMinute;
      final endMinutes = op.endHour * 60 + op.endMinute;
      if (blockMinutes < startMinutes || blockMinutes > endMinutes) {
        toRemove.add(block);
      }
    }
    if (toRemove.isNotEmpty) {
      for (final block in toRemove) {
        await DataManager.instance.removeStudentTimeBlock(block.id);
      }
      if (!_showOperatingHoursAlert) {
        _showOperatingHoursAlert = true;
        final studentNames = toRemove.map((b) {
          final s = DataManager.instance.students.firstWhere((s) => s.student.id == b.studentId, orElse: () => StudentWithInfo(
            student: Student(id: '', name: '알 수 없음', school: '', grade: 0, educationLevel: EducationLevel.elementary),
            basicInfo: StudentBasicInfo(studentId: '', registrationDate: DateTime.now()),
          ));
          return s.student.name;
        }).toSet().join(', ');
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          await showDialog(
            context: context,
            builder: (context) => AlertDialog(
              backgroundColor: Colors.black,
              title: const Text('운영시간 외 학생 시간 삭제', style: TextStyle(color: Colors.white)),
              content: Text('운영시간이 변경되어 운영시간 외 학생 시간표가 삭제되었습니다.\n삭제된 학생: $studentNames', style: const TextStyle(color: Colors.white70)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('확인', style: TextStyle(color: Colors.white)),
                ),
              ],
            ),
          );
        });
      }
    }
  }

  void _handleDateChanged(DateTime date) {
    setState(() {
      _selectedDate = date;
    });
  }

  void _handleStudentMenu() {
    setState(() {
      _registrationButtonText = '학생';
    });
  }

  void _handleRegistrationButton() async {
    print('[DEBUG] _handleRegistrationButton 진입: _isStudentRegistrationMode=$_isStudentRegistrationMode');
    // 학생 수업시간 등록 모드 진입 시 다이얼로그 띄우기
    // 1. 항상 최신 데이터로 동기화
    await DataManager.instance.loadStudentTimeBlocks();
    await DataManager.instance.loadStudents();
    if (_splitButtonSelected == '학생') {
      final selectedStudent = await showDialog<Student>(
        context: context,
        barrierDismissible: true,
        builder: (context) => StudentSearchDialog(isSelfStudyMode: false),
      );
      StudentWithInfo? studentWithInfo;
      if (selectedStudent != null) {
        // 항상 students에서 StudentWithInfo를 찾아서 사용
        studentWithInfo = DataManager.instance.students.firstWhere(
          (s) => s.student.id == selectedStudent.id,
          orElse: () => StudentWithInfo(student: selectedStudent, basicInfo: StudentBasicInfo(studentId: selectedStudent.id, registrationDate: selectedStudent.registrationDate ?? DateTime.now())),
        );
        // 만약 students에 없다면 loadStudents를 강제로 다시 불러오고 재시도
        if (studentWithInfo.student.id != selectedStudent.id) {
          await DataManager.instance.loadStudents();
          studentWithInfo = DataManager.instance.students.firstWhere(
            (s) => s.student.id == selectedStudent.id,
            orElse: () => StudentWithInfo(student: selectedStudent, basicInfo: StudentBasicInfo(studentId: selectedStudent.id, registrationDate: selectedStudent.registrationDate ?? DateTime.now())),
          );
        }
        final classCount = studentWithInfo.basicInfo.weeklyClassCount;
        // setId 기준 등록된 수업 차수 개수 계산
        final blocks = DataManager.instance.studentTimeBlocks.where((b) => b.studentId == selectedStudent.id).toList();
        final setIds = blocks.map((b) => b.setId).toSet();
        final registeredCount = setIds.length;
        final remaining = classCount - registeredCount;
        setState(() {
          _isStudentRegistrationMode = true;
          _isClassRegistrationMode = false;
          _selectedStudentWithInfo = studentWithInfo != null ? studentWithInfo : null;
          _remainingRegisterCount = remaining > 0 ? remaining : 0;
          print('[DEBUG][setState:학생선택] _isStudentRegistrationMode=$_isStudentRegistrationMode, _selectedStudentWithInfo=$_selectedStudentWithInfo, _remainingRegisterCount=$_remainingRegisterCount');
        });
        print('[DEBUG] 학생 선택 후 등록모드 진입: _isStudentRegistrationMode=$_isStudentRegistrationMode, _remainingRegisterCount=$_remainingRegisterCount');
      } else {
        setState(() {
          _isStudentRegistrationMode = false;
          _isClassRegistrationMode = false;
          _selectedStudentWithInfo = null;
          _remainingRegisterCount = null;
          print('[DEBUG][setState:학생선택취소] _isStudentRegistrationMode=$_isStudentRegistrationMode, _selectedStudentWithInfo=$_selectedStudentWithInfo, _remainingRegisterCount=$_remainingRegisterCount');
        });
        print('[DEBUG] 학생 선택 취소: _isStudentRegistrationMode=$_isStudentRegistrationMode');
      }
    } else if (_splitButtonSelected == '자습') {
      // 자습 등록 모드 진입 막기: 아무 동작도 하지 않음
      return;
    } else if (_selectedGroup != null) {
      // 클래스 등록 모드
      _showGroupScheduleDialog();
    }
  }

  void _showGroupScheduleDialog() {
    showDialog(
      context: context,
      builder: (context) => GroupScheduleDialog(
        groupInfo: _selectedGroup!,
        onScheduleSelected: (schedule) {
          Navigator.of(context).pop();
          setState(() {
            _currentGroupSchedule = schedule;
            _isClassRegistrationMode = true;
            _isStudentRegistrationMode = false;
          });
        },
      ),
    );
  }

  // TimetableHeader 요일 클릭 콜백
  void _onDayHeaderSelected(int dayIndex) {
    // 요일 선택 기능 완전 비활성화: 아무 동작도 하지 않음
  }

  void _showFilterDialog() async {
    final students = DataManager.instance.students;
    final groups = DataManager.instance.groups;
    final classes = DataManager.instance.classesNotifier.value; // 수업 데이터 추가
    // 학년 chips
    final educationLevels = ['초등', '중등', '고등'];
    final grades = [
      '초1', '초2', '초3', '초4', '초5', '초6',
      '중1', '중2', '중3',
      '고1', '고2', '고3', 'N수',
    ];
    // 학교 chips (학생 정보 기준, 중복 제거)
    final schools = students.map((s) => s.student.school).toSet().toList();
    // 그룹 chips (등록된 그룹명)
    final groupNames = groups.map((g) => g.name).toList();
    // 수업 chips (등록된 수업명)
    final classNames = classes.map((c) => c.name).toList();
    final chipBorderColor = const Color(0xFFB0B0B0);
    final chipSelectedBg = const Color(0xFF353545); // 진한 회색
    final chipUnselectedBg = const Color(0xFF1F1F1F); // 다이얼로그 배경색
    final chipLabelStyle = TextStyle(color: chipBorderColor, fontWeight: FontWeight.w500, fontSize: 15);
    final chipShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
    // chips 임시 상태 변수
    Set<String> tempSelectedEducationLevels = Set.from(_selectedEducationLevels);
    Set<String> tempSelectedGrades = Set.from(_selectedGrades);
    Set<String> tempSelectedSchools = Set.from(_selectedSchools);
    Set<String> tempSelectedGroups = Set.from(_selectedGroups);
    Set<String> tempSelectedClasses = Set.from(_selectedClasses);
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1F1F1F),
              contentPadding: const EdgeInsets.fromLTRB(32, 28, 32, 16),
              title: const Text('filter', style: TextStyle(color: Color(0xFFB0B0B0), fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
              content: SizedBox(
                width: 480,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 학년 chips
                      Row(
                        children: [
                          Icon(Icons.school_outlined, color: chipBorderColor, size: 20),
                          const SizedBox(width: 6),
                          Text('학년별', style: TextStyle(color: Color(0xFFB0B0B0), fontSize: 16, fontWeight: FontWeight.w600)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8, runSpacing: 8,
                        children: [
                          ...educationLevels.map((level) => FilterChip(
                            label: Text(level, style: chipLabelStyle),
                            selected: tempSelectedEducationLevels.contains(level),
                            onSelected: (selected) {
                              setState(() {
                                if (selected) {
                                  tempSelectedEducationLevels.add(level);
                                } else {
                                  tempSelectedEducationLevels.remove(level);
                                }
                              });
                            },
                            backgroundColor: chipUnselectedBg,
                            selectedColor: chipSelectedBg,
                            side: BorderSide(color: chipBorderColor, width: 1.2),
                            shape: chipShape,
                            showCheckmark: true,
                            checkmarkColor: chipBorderColor,
                          )),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8, runSpacing: 8,
                        children: [
                          ...grades.map((grade) => FilterChip(
                            label: Text(grade, style: chipLabelStyle),
                            selected: tempSelectedGrades.contains(grade),
                            onSelected: (selected) {
                              setState(() {
                                if (selected) {
                                  tempSelectedGrades.add(grade);
                                } else {
                                  tempSelectedGrades.remove(grade);
                                }
                              });
                            },
                            backgroundColor: chipUnselectedBg,
                            selectedColor: chipSelectedBg,
                            side: BorderSide(color: chipBorderColor, width: 1.2),
                            shape: chipShape,
                            showCheckmark: true,
                            checkmarkColor: chipBorderColor,
                          )),
                        ],
                      ),
                      const SizedBox(height: 18),
                      // 학교 chips
                      Row(
                        children: [
                          Icon(Icons.location_city_outlined, color: chipBorderColor, size: 20),
                          const SizedBox(width: 6),
                          Text('학교', style: TextStyle(color: Color(0xFFB0B0B0), fontSize: 16, fontWeight: FontWeight.w600)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8, runSpacing: 8,
                        children: [
                          ...schools.map((school) => FilterChip(
                            label: Text(school, style: chipLabelStyle),
                            selected: tempSelectedSchools.contains(school),
                            onSelected: (selected) {
                              setState(() {
                                if (selected) {
                                  tempSelectedSchools.add(school);
                                } else {
                                  tempSelectedSchools.remove(school);
                                }
                              });
                            },
                            backgroundColor: chipUnselectedBg,
                            selectedColor: chipSelectedBg,
                            side: BorderSide(color: chipBorderColor, width: 1.2),
                            shape: chipShape,
                            showCheckmark: true,
                            checkmarkColor: chipBorderColor,
                          )),
                        ],
                      ),
                      const SizedBox(height: 18),
                      // 그룹 chips
                      Row(
                        children: [
                          Icon(Icons.groups_2_outlined, color: chipBorderColor, size: 20),
                          const SizedBox(width: 6),
                          Text('그룹', style: TextStyle(color: Color(0xFFB0B0B0), fontSize: 16, fontWeight: FontWeight.w600)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8, runSpacing: 8,
                        children: [
                          ...groupNames.map((group) => FilterChip(
                            label: Text(group, style: chipLabelStyle),
                            selected: tempSelectedGroups.contains(group),
                            onSelected: (selected) {
                              setState(() {
                                if (selected) {
                                  tempSelectedGroups.add(group);
                                } else {
                                  tempSelectedGroups.remove(group);
                                }
                              });
                            },
                            backgroundColor: chipUnselectedBg,
                            selectedColor: chipSelectedBg,
                            side: BorderSide(color: chipBorderColor, width: 1.2),
                            shape: chipShape,
                            showCheckmark: true,
                            checkmarkColor: chipBorderColor,
                          )),
                        ],
                      ),
                      const SizedBox(height: 18),
                      // 수업 chips
                      Row(
                        children: [
                          Icon(Icons.class_outlined, color: chipBorderColor, size: 20),
                          const SizedBox(width: 6),
                          Text('수업', style: TextStyle(color: Color(0xFFB0B0B0), fontSize: 16, fontWeight: FontWeight.w600)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8, runSpacing: 8,
                        children: [
                          ...classNames.map((className) => FilterChip(
                            label: Text(className, style: chipLabelStyle),
                            selected: tempSelectedClasses.contains(className),
                            onSelected: (selected) {
                              setState(() {
                                if (selected) {
                                  tempSelectedClasses.add(className);
                                } else {
                                  tempSelectedClasses.remove(className);
                                }
                              });
                            },
                            backgroundColor: chipUnselectedBg,
                            selectedColor: chipSelectedBg,
                            side: BorderSide(color: chipBorderColor, width: 1.2),
                            shape: chipShape,
                            showCheckmark: true,
                            checkmarkColor: chipBorderColor,
                          )),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('취소', style: TextStyle(color: Color(0xFFB0B0B0))),
                ),
                FilledButton(
                  onPressed: () {
                    // chips 상태를 부모에 반영
                    _selectedEducationLevels = Set.from(tempSelectedEducationLevels);
                    _selectedGrades = Set.from(tempSelectedGrades);
                    _selectedSchools = Set.from(tempSelectedSchools);
                    _selectedGroups = Set.from(tempSelectedGroups);
                    _selectedClasses = Set.from(tempSelectedClasses);
                    _activeFilter = {
                      'educationLevels': Set.from(tempSelectedEducationLevels),
                      'grades': Set.from(tempSelectedGrades),
                      'schools': Set.from(tempSelectedSchools),
                      'groups': Set.from(tempSelectedGroups),
                      'classes': Set.from(tempSelectedClasses),
                    };
                    Navigator.of(context).pop(true);
                  },
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
                  child: const Text('적용', style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
    // 다이얼로그 닫힌 후, 적용 시 화면 리빌드
    if (result == true) {
      setState(() {});
    }
  }

  void _clearFilter() {
    setState(() {
      _activeFilter = null;
      _selectedEducationLevels.clear();
      _selectedGrades.clear();
      _selectedSchools.clear();
      _selectedGroups.clear();
      _selectedClasses.clear();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void exitSelectMode() {
    print('[DEBUG][TimetableScreen][exitSelectMode] 호출됨 - 선택 모드 종료, _isSelectMode: $_isSelectMode -> false, _selectedStudentIds: $_selectedStudentIds');
    setState(() {
      _isSelectMode = false;
      _selectedStudentIds.clear();
    });
    print('[DEBUG][TimetableScreen][exitSelectMode] 완료 - _isSelectMode: $_isSelectMode, _selectedStudentIds: $_selectedStudentIds');
  }

  @override
  Widget build(BuildContext context) {
    print('[DEBUG][TimetableScreen][${DateTime.now().toIso8601String()}] build: _isStudentRegistrationMode=$_isStudentRegistrationMode, _isClassRegistrationMode=$_isClassRegistrationMode, _isSelfStudyRegistrationMode=$_isSelfStudyRegistrationMode, _isSelectMode=$_isSelectMode, _selectedStudentIds=$_selectedStudentIds');
    return RawKeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKey: (event) {
        if (event is RawKeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
          if (_isStudentRegistrationMode || _isClassRegistrationMode) {
            setState(() {
              _isStudentRegistrationMode = false;
              _isClassRegistrationMode = false;
              _selectedStudentWithInfo = null;
              _selectedDayIndex = null;
              _selectedStartTimeHour = null;
              _selectedStartTimeMinute = null;
            });
          }
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          // 검색 내역이 있으면 리셋
          _contentViewKey.currentState?.clearSearch();
          if (_isStudentRegistrationMode || _isClassRegistrationMode) {
            setState(() {
              _isStudentRegistrationMode = false;
              _isClassRegistrationMode = false;
              _selectedStudentWithInfo = null;
              _remainingRegisterCount = null;
            });
          }
          // 선택모드 해제: 셀 클릭 시 자동으로 선택모드 false
          if (_isSelectMode) {
            setState(() {
              _isSelectMode = false;
              print('[DEBUG][TimetableScreen] 선택모드 해제(셀 클릭): _isSelectMode=$_isSelectMode, _selectedCellDayIndex=$_selectedCellDayIndex, _selectedStartTimeHour=$_selectedStartTimeHour, _selectedStartTimeMinute=$_selectedStartTimeMinute');
            });
          }
        },
        child: Scaffold(
          backgroundColor: const Color(0xFF1F1F1F),
          appBar: const AppBarTitle(title: '시간'),
          body: Container(
            color: const Color(0xFF1F1F1F), // 프로그램 전체 배경색
            child: Column(
              children: [
                SizedBox(height: 5), // TimetableHeader 위 여백을 5로 수정
                CustomTabBar(
                  selectedIndex: TimetableViewType.values.indexOf(_viewType),
                  tabs: TimetableViewType.values.map((e) => e.name).toList(),
                  onTabSelected: (i) {
                    setState(() {
                      _viewType = TimetableViewType.values[i];
                    });
                    
                    // 수업 탭 클릭 시에만 스크롤
                    if (TimetableViewType.values[i] == TimetableViewType.classes && 
                        !_hasScrolledOnTabClick) {
                      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrentTime());
                      _hasScrolledOnTabClick = true;
                    }
                  },
                ),
                const SizedBox(height: 24),
                Expanded(
                  child: _buildContent(),
                ),
                const SizedBox(height: 50), // 하단 여백은 Expanded 바깥에서!
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    switch (_viewType) {
      case TimetableViewType.classes:
        final Set<String>? filteredStudentIds = _activeFilter == null
          ? null
          : _filteredStudents.map((s) => s.student.id).toSet();
        return TimetableContentView(
          key: _contentViewKey, // 추가: 검색 리셋을 위해 key 부여
          filteredStudentIds: filteredStudentIds, // 필터링 정보 전달
          timetableChild: Container(
            width: double.infinity,
            // margin: EdgeInsets.zero, // margin 제거
            decoration: BoxDecoration(
              color: Color(0xFF18181A),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                SizedBox(height: 20),
                TimetableHeader(
                  selectedDate: _selectedDate,
                  onDateChanged: _handleDateChanged,
                  selectedDayIndex: _isStudentRegistrationMode ? null : _selectedDayIndex,
                  onDaySelected: _onDayHeaderSelected,
                  isRegistrationMode: _isStudentRegistrationMode || _isClassRegistrationMode,
                  onFilterPressed: _activeFilter == null ? _showFilterDialog : _clearFilter,
                  isFilterActive: _activeFilter != null, // 추가
                  onSelectModeChanged: (selecting) {
                    setState(() {
                      _isSelectMode = selecting;
                      if (!selecting) _selectedStudentIds.clear();
                      // print('[DEBUG][TimetableScreen] onSelectModeChanged: $selecting, _isSelectMode=$_isSelectMode, _selectedCellDayIndex=$_selectedCellDayIndex, _selectedStartTimeHour=$_selectedStartTimeHour, _selectedStartTimeMinute=$_selectedStartTimeMinute');
                    });
                  },
                  isSelectMode: _isSelectMode, // 추가: 선택모드 상태 명시적으로 전달
                  onSelectAllStudents: () {
                    print('[DEBUG][onSelectAllStudents] _selectedCellDayIndex=$_selectedCellDayIndex, _selectedStartTimeHour=$_selectedStartTimeHour, _selectedStartTimeMinute=$_selectedStartTimeMinute');
                    // studentTimeBlocks 전체 프린트
                    // print('[DEBUG][전체 studentTimeBlocks]');
                    for (final b in DataManager.instance.studentTimeBlocks) {
                      // print('id=${b.id}, studentId=${b.studentId}, dayIndex=${b.dayIndex}, startHour=${b.startHour}, startMinute=${b.startMinute}');
                    }
                    if (_selectedCellDayIndex != null && _selectedStartTimeHour != null && _selectedStartTimeMinute != null) {
                      // print('[DEBUG][onSelectAllStudents] 비교값: dayIndex=$_selectedCellDayIndex, startHour=$_selectedStartTimeHour, startMinute=$_selectedStartTimeMinute');
                      final cellStudents = _getCellStudents(_selectedCellDayIndex!, _selectedStartTimeHour!, _selectedStartTimeMinute!);
                      // print('[DEBUG][onSelectAllStudents] cellStudents(모두버튼): ${cellStudents.map((s) => s.student.id).toList()}');
                      setState(() {
                        _selectedStudentIds = cellStudents.map((s) => s.student.id).toSet();
                      });
                    }
                  },
                ),
                if (_isStudentRegistrationMode && _selectedStudentWithInfo != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8.0),
                    child: Builder(
                      builder: (context) {
                        final studentWithInfo = _selectedStudentWithInfo!;
                        final studentId = studentWithInfo.student.id;
                        final blocks = DataManager.instance.studentTimeBlocks.where((b) => b.studentId == studentId).toList();
                        final setIds = blocks.map((b) => b.setId).toSet();
                        final registeredCount = setIds.length;
                        final totalCount = studentWithInfo.basicInfo.weeklyClassCount ?? 1;
                        return Text(
                          '${studentWithInfo.student.name} 학생: 수업시간 등록 ($registeredCount/$totalCount)',
                          style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                        );
                      },
                    ),
                  ),
                SizedBox(height: 0),
                Flexible(
                  child: ClassesView(
                    operatingHours: _operatingHours,
                    breakTimeColor: const Color(0xFF424242),
                    isRegistrationMode: _isStudentRegistrationMode || _isClassRegistrationMode || _isSelfStudyRegistrationMode,
                    registrationModeType: _isSelfStudyRegistrationMode ? 'selfStudy' : (_isStudentRegistrationMode ? 'student' : null),
                    selectedDayIndex: _selectedDayIndex,
                    onTimeSelected: (dayIdx, startTime) {
                      print('[DEBUG][onTimeSelected] 셀 클릭: dayIdx=$dayIdx, startTime=$startTime');
                      setState(() {
                        _selectedCellDayIndex = dayIdx;
                        _selectedStartTimeHour = startTime.hour;
                        _selectedStartTimeMinute = startTime.minute;
                        print('[DEBUG][onTimeSelected][setState후] _selectedCellDayIndex=$_selectedCellDayIndex, _selectedStartTimeHour=$_selectedStartTimeHour, _selectedStartTimeMinute=$_selectedStartTimeMinute');
                      });
                    },
                    onCellStudentsSelected: (dayIdx, startTimes, students) async {
                      print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 호출: dayIdx=$dayIdx, startTimes=$startTimes, startTimes.length=${startTimes.length}, students=$students, _isSelfStudyRegistrationMode=$_isSelfStudyRegistrationMode, _isStudentRegistrationMode=$_isStudentRegistrationMode, _selectedSelfStudyStudent=${_selectedSelfStudyStudent?.student.name}, _selectedStudentWithInfo=${_selectedStudentWithInfo?.student.name}');
                      // 셀 클릭 시 검색 리셋
                      _contentViewKey.currentState?.clearSearch();
                      setState(() {
                        _selectedCellDayIndex = dayIdx;
                        _selectedStartTimeHour = startTimes.isNotEmpty ? startTimes.first.hour : null;
                        _selectedStartTimeMinute = startTimes.isNotEmpty ? startTimes.first.minute : null;
                      });
                      // 자습 등록 모드 처리
                      if (_isSelfStudyRegistrationMode && _selectedSelfStudyStudent != null) {
                        print('[DEBUG][onCellStudentsSelected] 자습 등록 분기 진입');
                        final studentId = _selectedSelfStudyStudent!.student.id;
                        final blockMinutes = 30; // 자습 블록 길이(분)
                        List<DateTime> actualStartTimes = startTimes;
                        // 클릭(단일 셀) 시에는 30분 블록 1개 생성
                        if (startTimes.length == 1) {
                          actualStartTimes = [startTimes.first];
                        }
                        
                        // 수업 블록과의 중복 체크
                        bool hasConflict = false;
                        for (final startTime in actualStartTimes) {
                          final conflictingBlocks = DataManager.instance.studentTimeBlocks.where((b) {
                            if (b.studentId != studentId || b.dayIndex != dayIdx) return false;
                            final blockStartMinutes = b.startHour * 60 + b.startMinute;
                            final blockEndMinutes = blockStartMinutes + b.duration.inMinutes;
                            final checkStartMinutes = startTime.hour * 60 + startTime.minute;
                            final checkEndMinutes = checkStartMinutes + blockMinutes;
                            return checkStartMinutes < blockEndMinutes && checkEndMinutes > blockStartMinutes;
                          }).toList();
                          
                          if (conflictingBlocks.isNotEmpty) {
                            hasConflict = true;
                            break;
                          }
                        }
                        
                        if (hasConflict) {
                          showAppSnackBar(context, '이미 등록된 수업시간과 겹칩니다. 자습시간을 등록할 수 없습니다.', useRoot: true);
                          return;
                        }
                        
                        print('[DEBUG][onCellStudentsSelected] 생성할 자습 블록 actualStartTimes: $actualStartTimes');
                        final blocks = SelfStudyTimeBlockFactory.createBlocksWithSetIdAndNumber(
                          studentId: studentId,
                          dayIndex: dayIdx,
                          startTimes: actualStartTimes,
                          duration: Duration(minutes: blockMinutes),
                        );
                        print('[DEBUG][onCellStudentsSelected] SelfStudyTimeBlock 생성: ${blocks.map((b) => b.toJson()).toList()}');
                        for (final block in blocks) {
                          print('[DEBUG][onCellStudentsSelected] addSelfStudyTimeBlock 호출: ${block.toJson()}');
                          print('[DEBUG][onCellStudentsSelected] block.setId=${block.setId}, block.number=${block.number}');
                          await DataManager.instance.addSelfStudyTimeBlock(block);
                        }
                        setState(() {
                          _isSelfStudyRegistrationMode = false;
                          _selectedSelfStudyStudent = null;
                        });
                        showAppSnackBar(context, '자습 시간이 등록되었습니다.', useRoot: true);
                        return;
                      }
                      // 학생 등록 모드에서만 동작
                      if (_isStudentRegistrationMode && _selectedStudentWithInfo != null && _remainingRegisterCount != null && _remainingRegisterCount! > 0) {
                        final studentWithInfo = _selectedStudentWithInfo!;
                        final student = studentWithInfo.student;
                        
                        if (startTimes.length > 1) {
                          // 드래그 등록 분기: 블록 생성/등록은 이미 완료됨, 상태만 갱신
                          print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 드래그 등록 분기 진입: startTimes.length=${startTimes.length}');
                          print('[DEBUG][onCellStudentsSelected] 선택된 학생: ${student.id}, 이름: ${student.name}');
                          
                          // 저장된 블록들을 조회하여 set_id 개수 계산
                          await DataManager.instance.loadStudentTimeBlocks();
                          final allBlocksAfter = DataManager.instance.studentTimeBlocks.where((b) => b.studentId == student.id).toList();
                          print('[DEBUG][onCellStudentsSelected] 저장 후 전체 블록: ${allBlocksAfter.map((b) => b.toJson()).toList()}');
                          final setIds = allBlocksAfter.map((b) => b.setId).toSet();
                          int usedCount = setIds.length;
                          print('[DEBUG][onCellStudentsSelected] set_id 개수(수업차감): $usedCount');
                          
                          final foundStudentWithInfo = DataManager.instance.students.firstWhere(
                            (s) => s.student.id == student.id,
                            orElse: () => StudentWithInfo(student: student, basicInfo: StudentBasicInfo(studentId: student.id, registrationDate: student.registrationDate ?? DateTime.now())),
                          );
                          final maxCount = foundStudentWithInfo.basicInfo.weeklyClassCount;
                          print('[DEBUG][onCellStudentsSelected] weeklyClassCount: $maxCount');
                          
                          print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 드래그 등록 setState 전: _remainingRegisterCount=$_remainingRegisterCount, _isStudentRegistrationMode=$_isStudentRegistrationMode');
                          setState(() {
                            _remainingRegisterCount = (maxCount - usedCount) > 0 ? (maxCount - usedCount) : 0;
                            print('[DEBUG][onCellStudentsSelected] 남은 수업횟수: $_remainingRegisterCount');
                            if (_remainingRegisterCount == 0) {
                              print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 드래그 등록모드 종료');
                              _isStudentRegistrationMode = false;
                              _selectedStudentWithInfo = null;
                              _selectedDayIndex = null;
                              _selectedStartTimeHour = null;
                              _selectedStartTimeMinute = null;
                            }
                          });
                          print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 드래그 등록 setState 후: _remainingRegisterCount=$_remainingRegisterCount, _isStudentRegistrationMode=$_isStudentRegistrationMode');
                          
                          if (_remainingRegisterCount == 0 && mounted) {
                            showAppSnackBar(context, '${student.name} 학생의 수업시간 등록이 완료되었습니다.', useRoot: true);
                          }
                          print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 드래그 등록 분기 return');
                          return;
                        } else if (startTimes.length == 1) {
                          // 클릭 등록 분기: 블록 생성/등록부터 수행
                          print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 클릭 등록 분기 진입: startTimes.length=${startTimes.length}');
                          print('[DEBUG][onCellStudentsSelected] 선택된 학생: ${student.id}, 이름: ${student.name}');
                          final blockMinutes = 30; // 한 블록 30분 기준
                          final lessonDuration = DataManager.instance.academySettings.lessonDuration;
                          final blockCount = (lessonDuration / blockMinutes).ceil();
                          List<DateTime> actualStartTimes = List.generate(blockCount, (i) => startTimes.first.add(Duration(minutes: i * blockMinutes)));
                          
                          print('[DEBUG][onCellStudentsSelected] 생성할 블록 actualStartTimes: $actualStartTimes');
                          // --- 중복 방어 강화: 하나라도 겹치면 전체 등록 불가 ---
                          final allBlocks = DataManager.instance.studentTimeBlocks;
                          bool hasConflict = false;
                          for (final startTime in actualStartTimes) {
                            final conflictBlock = allBlocks.firstWhereOrNull((b) => b.studentId == student.id && b.dayIndex == dayIdx && b.startHour == startTime.hour && b.startMinute == startTime.minute);
                            if (conflictBlock != null) {
                              hasConflict = true;
                              break;
                            }
                          }
                          print('[DEBUG][onCellStudentsSelected] 클릭 등록 중복체크 결과: hasConflict=$hasConflict');
                          if (hasConflict) {
                            showAppSnackBar(context, '이미 등록된 시간입니다.', useRoot: true);
                            return;
                          }
                          // --- 기존 로직 ---
                          final blocks = StudentTimeBlockFactory.createBlocksWithSetIdAndNumber(
                            studentIds: [student.id],
                            dayIndex: dayIdx,
                            startTimes: actualStartTimes,
                            duration: Duration(minutes: blockMinutes),
                          );
                          print('[DEBUG][onCellStudentsSelected] StudentTimeBlock 생성: ${blocks.map((b) => b.toJson()).toList()}');
                          for (final block in blocks) {
                            print('[DEBUG][onCellStudentsSelected] addStudentTimeBlock 호출: ${block.toJson()}');
                            await DataManager.instance.addStudentTimeBlock(block);
                          }
                          print('[DEBUG][onCellStudentsSelected] loadStudentTimeBlocks 호출');
                          await DataManager.instance.loadStudentTimeBlocks();
                          final allBlocksAfter = DataManager.instance.studentTimeBlocks.where((b) => b.studentId == student.id).toList();
                          print('[DEBUG][onCellStudentsSelected] 저장 후 전체 블록: ${allBlocksAfter.map((b) => b.toJson()).toList()}');
                          final setIds = allBlocksAfter.map((b) => b.setId).toSet();
                          int usedCount = setIds.length;
                          print('[DEBUG][onCellStudentsSelected] set_id 개수(수업차감): $usedCount');
                          final foundStudentWithInfo = DataManager.instance.students.firstWhere(
                            (s) => s.student.id == student.id,
                            orElse: () => StudentWithInfo(student: student, basicInfo: StudentBasicInfo(studentId: student.id, registrationDate: student.registrationDate ?? DateTime.now())),
                          );
                          final maxCount = foundStudentWithInfo.basicInfo.weeklyClassCount;
                          print('[DEBUG][onCellStudentsSelected] weeklyClassCount: $maxCount');
                          
                          print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 클릭 등록 setState 전: _remainingRegisterCount=$_remainingRegisterCount, _isStudentRegistrationMode=$_isStudentRegistrationMode');
                          setState(() {
                            _remainingRegisterCount = (maxCount - usedCount) > 0 ? (maxCount - usedCount) : 0;
                            print('[DEBUG][onCellStudentsSelected] 남은 수업횟수: $_remainingRegisterCount');
                            if (_remainingRegisterCount == 0) {
                              print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 클릭 등록모드 종료');
                              _isStudentRegistrationMode = false;
                              _selectedStudentWithInfo = null;
                              _selectedDayIndex = null;
                              _selectedStartTimeHour = null;
                              _selectedStartTimeMinute = null;
                            }
                          });
                          print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 클릭 등록 setState 후: _remainingRegisterCount=$_remainingRegisterCount, _isStudentRegistrationMode=$_isStudentRegistrationMode');
                          
                          if (_remainingRegisterCount == 0 && mounted) {
                            showAppSnackBar(context, '${student.name} 학생의 수업시간 등록이 완료되었습니다.', useRoot: true);
                          }
                          print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 클릭 등록 분기 완료');
                        }
                      }
                    },
                    scrollController: _timetableScrollController,
                    // filteredStudentIds 정의 추가
                    filteredStudentIds: _activeFilter == null
                      ? null
                      : _filteredStudents.map((s) => s.student.id).toSet(),
                    selectedStudentWithInfo: _selectedStudentWithInfo,
                    selectedSelfStudyStudent: _selectedSelfStudyStudent,
                    onSelectModeChanged: (selecting) {
                      setState(() {
                        _isSelectMode = selecting;
                        if (!selecting) _selectedStudentIds.clear();
                        print('[DEBUG][TimetableScreen][ClassesView] onSelectModeChanged: $selecting, _isSelectMode=$_isSelectMode');
                      });
                    },
                  ),
                ),
                SizedBox(height: 24), // 시간표 위젯 하단 내부 여백 추가
              ],
            ),
          ),
          onRegisterPressed: () {
            if (_splitButtonSelected == '학생') {
              _handleRegistrationButton();
            } else if (_splitButtonSelected == '보강') {
              // TODO: 보강 등록 모드 구현
            } else if (_splitButtonSelected == '자습') {
              _handleSelfStudyRegistration();
            }
          },
          splitButtonSelected: _splitButtonSelected,
          isDropdownOpen: _isDropdownOpen,
          onDropdownOpenChanged: (open) {
            setState(() {
              _isDropdownOpen = open;
            });
          },
          onDropdownSelected: (value) {
            setState(() {
              _splitButtonSelected = value;
            });
          },
          selectedCellDayIndex: _selectedCellDayIndex,
          selectedCellStartTime: _selectedStartTimeHour != null && _selectedStartTimeMinute != null ? DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day, _selectedStartTimeHour!, _selectedStartTimeMinute!) : null,
          onCellStudentsChanged: (dayIdx, startTime, students) {
            setState(() {
              _selectedCellDayIndex = dayIdx;
              _selectedStartTimeHour = startTime.hour;
              _selectedStartTimeMinute = startTime.minute;
              // 학생 리스트는 timetable_content_view.dart에서 계산
            });
          },
          onCellSelfStudyStudentsChanged: (dayIdx, startTime, students) {
            setState(() {
              _selectedCellDayIndex = dayIdx;
              _selectedStartTimeHour = startTime.hour;
              _selectedStartTimeMinute = startTime.minute;
              // 자습 학생 리스트는 timetable_content_view.dart에서 계산
            });
          },
          clearSearch: () => _contentViewKey.currentState?.clearSearch(), // 추가: 검색 리셋 콜백 전달
          isSelectMode: _isSelectMode,
          selectedStudentIds: _selectedStudentIds,
          onStudentSelectChanged: (id, selected) {
            setState(() {
              if (selected) {
                _selectedStudentIds.add(id);
              } else {
                _selectedStudentIds.remove(id);
              }
              print('[DEBUG][TimetableScreen] onStudentSelectChanged: $id, $selected, _selectedStudentIds=$_selectedStudentIds');
            });
          },
          onExitSelectMode: exitSelectMode, // 콜백 전달
        );
      case TimetableViewType.schedule:
        return Container(); // TODO: Implement ScheduleView
      case TimetableViewType.attendance:
        return const AttendanceView();
    }
  }

  Widget _buildClassView() {
    int? totalClassCount;
    if (_isStudentRegistrationMode && _selectedStudentWithInfo != null) {
      final studentWithInfo = _selectedStudentWithInfo!;
      totalClassCount = studentWithInfo.basicInfo.weeklyClassCount ?? 1;
    }
    print('[DEBUG][_buildClassView] _isStudentRegistrationMode=$_isStudentRegistrationMode, _selectedStudentWithInfo=$_selectedStudentWithInfo, _remainingRegisterCount=$_remainingRegisterCount');
    final Set<String>? filteredStudentIds = _activeFilter == null
        ? null
        : _filteredStudents.map((s) => s.student.id).toSet();
    return Column(
      children: [
        // 상단 UI (월정보, 세그먼트, 선택, 필터 버튼 등)
        TimetableHeader(
          selectedDate: _selectedDate,
          onDateChanged: _handleDateChanged,
          selectedDayIndex: _isStudentRegistrationMode ? null : _selectedDayIndex,
          onDaySelected: _onDayHeaderSelected,
          isRegistrationMode: _isStudentRegistrationMode || _isClassRegistrationMode,
          onFilterPressed: _activeFilter == null ? _showFilterDialog : _clearFilter,
          isFilterActive: _activeFilter != null,
          onSelectModeChanged: (selecting) {
            setState(() {
              _isSelectMode = selecting;
              if (!selecting) _selectedStudentIds.clear();
              print('[DEBUG][TimetableScreen] onSelectModeChanged: $selecting, _isSelectMode=$_isSelectMode');
            });
          },
          isSelectMode: _isSelectMode,
        ),
        // 등록 안내문구/카운트
        if (_isStudentRegistrationMode && _selectedStudentWithInfo != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: Text(
              '${_selectedStudentWithInfo!.student.name} 학생: 수업시간 등록 (${(totalClassCount ?? 1) - (_remainingRegisterCount ?? 0) + 1}/${totalClassCount ?? 1})',
              style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
            ),
          ),
        // 시간표 본문
        Expanded(
          child: ClassesView(
            scrollController: _timetableScrollController,
            operatingHours: _operatingHours,
            breakTimeColor: const Color(0xFF424242),
            isRegistrationMode: _isStudentRegistrationMode || _isClassRegistrationMode,
            selectedDayIndex: _isStudentRegistrationMode ? null : _selectedDayIndex,
            onTimeSelected: (int dayIdx, DateTime startTime) {
              print('[DEBUG][onTimeSelected] 셀 클릭: dayIdx=$dayIdx, startTime=$startTime');
              setState(() {
                _selectedCellDayIndex = dayIdx;
                _selectedStartTimeHour = startTime.hour;
                _selectedStartTimeMinute = startTime.minute;
                print('[DEBUG][onTimeSelected][setState후] _selectedCellDayIndex=$_selectedCellDayIndex, _selectedStartTimeHour=$_selectedStartTimeHour, _selectedStartTimeMinute=$_selectedStartTimeMinute');
              });
            },
            onCellStudentsSelected: (int dayIdx, List<DateTime> startTimes, List<StudentWithInfo> students) async {
              print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 호출: dayIdx=$dayIdx, startTimes=$startTimes, startTimes.length=${startTimes.length}, students=$students, _isSelfStudyRegistrationMode=$_isSelfStudyRegistrationMode, _isStudentRegistrationMode=$_isStudentRegistrationMode, _selectedSelfStudyStudent=${_selectedSelfStudyStudent?.student.name}, _selectedStudentWithInfo=${_selectedStudentWithInfo?.student.name}');
              // 셀 클릭 시 검색 리셋
              _contentViewKey.currentState?.clearSearch();
              setState(() {
                _selectedCellDayIndex = dayIdx;
                _selectedStartTimeHour = startTimes.isNotEmpty ? startTimes.first.hour : null;
                _selectedStartTimeMinute = startTimes.isNotEmpty ? startTimes.first.minute : null;
              });
              // 학생 등록 모드에서만 동작
              if (_isStudentRegistrationMode && _selectedStudentWithInfo != null && _remainingRegisterCount != null && _remainingRegisterCount! > 0) {
                final studentWithInfo = _selectedStudentWithInfo!;
                final student = studentWithInfo.student;
                final blockMinutes = 30;
                List<DateTime> actualStartTimes = startTimes;
                if (startTimes.length > 1) {
                  // 드래그 등록 분기: 블록 생성/등록/중복체크/스낵바 모두 건너뛰고 상태만 갱신
                  print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 드래그 등록 분기 진입: startTimes=$startTimes, startTimes.length=${startTimes.length}');
                  final allBlocksAfter = DataManager.instance.studentTimeBlocks.where((b) => b.studentId == student.id).toList();
                  final setIds = allBlocksAfter.map((b) => b.setId).toSet();
                  int usedCount = setIds.length;
                  final foundStudentWithInfo = DataManager.instance.students.firstWhere(
                    (s) => s.student.id == student.id,
                    orElse: () => StudentWithInfo(student: student, basicInfo: StudentBasicInfo(studentId: student.id, registrationDate: student.registrationDate ?? DateTime.now())),
                  );
                  final maxCount = foundStudentWithInfo.basicInfo.weeklyClassCount;
                  print('[DEBUG][onCellStudentsSelected] 드래그 등록 상태: usedCount=$usedCount, maxCount=$maxCount, _remainingRegisterCount=$_remainingRegisterCount');
                  print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 드래그 등록 setState 전: _remainingRegisterCount=$_remainingRegisterCount, _isStudentRegistrationMode=$_isStudentRegistrationMode, _selectedStudentWithInfo=$_selectedStudentWithInfo');
                  setState(() {
                    _remainingRegisterCount = (maxCount - usedCount) > 0 ? (maxCount - usedCount) : 0;
                    print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 드래그 등록 setState 후: _remainingRegisterCount=$_remainingRegisterCount, _isStudentRegistrationMode=$_isStudentRegistrationMode, _selectedStudentWithInfo=$_selectedStudentWithInfo');
                    if (_remainingRegisterCount == 0) {
                      print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 드래그 등록 등록모드 종료');
                      _isStudentRegistrationMode = false;
                      _selectedStudentWithInfo = null;
                      _selectedDayIndex = null;
                      _selectedStartTimeHour = null;
                      _selectedStartTimeMinute = null;
                    }
                  });
                  print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 드래그 등록 return');
                  return;
                }
                if (startTimes.length == 1) {
                  // 클릭 등록 분기: 기존대로 블록 생성/중복체크/등록
                  print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 클릭 등록 분기 진입: startTimes=$startTimes, startTimes.length=${startTimes.length}');
                  final studentWithInfo = _selectedStudentWithInfo!;
                  final student = studentWithInfo.student;
                  final blockMinutes = 30; // 한 블록 30분 기준
                  List<DateTime> actualStartTimes = startTimes;
                  final lessonDuration = DataManager.instance.academySettings.lessonDuration;
                  final blockCount = (lessonDuration / blockMinutes).ceil();
                  actualStartTimes = List.generate(blockCount, (i) => startTimes.first.add(Duration(minutes: i * blockMinutes)));
                  print('[DEBUG][onCellStudentsSelected] 클릭 등록 생성할 블록 actualStartTimes: $actualStartTimes');
                  final allBlocks = DataManager.instance.studentTimeBlocks;
                  bool hasConflict = false;
                  for (final startTime in actualStartTimes) {
                    final conflictBlock = allBlocks.firstWhereOrNull((b) => b.studentId == student.id && b.dayIndex == dayIdx && b.startHour == startTime.hour && b.startMinute == startTime.minute);
                    if (conflictBlock != null) {
                      hasConflict = true;
                      print('[DEBUG][onCellStudentsSelected] 클릭 등록 중복 블록 발견: $conflictBlock');
                      break;
                    }
                  }
                  if (hasConflict) {
                    print('[DEBUG][onCellStudentsSelected] 클릭 등록 중복 SnackBar 발생');
                    showAppSnackBar(context, '이미 등록된 시간입니다.', useRoot: true);
                    return;
                  }
                  final blocks = StudentTimeBlockFactory.createBlocksWithSetIdAndNumber(
                    studentIds: [student.id],
                    dayIndex: dayIdx,
                    startTimes: actualStartTimes,
                    duration: Duration(minutes: blockMinutes),
                  );
                  print('[DEBUG][onCellStudentsSelected] 클릭 등록 생성된 블록: ${blocks.map((b) => b.toJson()).toList()}');
                  for (final block in blocks) {
                    print('[DEBUG][onCellStudentsSelected] 클릭 등록 addStudentTimeBlock 호출: ${block.toJson()}');
                    await DataManager.instance.addStudentTimeBlock(block);
                  }
                  print('[DEBUG][onCellStudentsSelected] 클릭 등록 loadStudentTimeBlocks 호출');
                  await DataManager.instance.loadStudentTimeBlocks();
                  final allBlocksAfter = DataManager.instance.studentTimeBlocks.where((b) => b.studentId == student.id).toList();
                  final setIds = allBlocksAfter.map((b) => b.setId).toSet();
                  int usedCount = setIds.length;
                  final foundStudentWithInfo = DataManager.instance.students.firstWhere(
                    (s) => s.student.id == student.id,
                    orElse: () => StudentWithInfo(student: student, basicInfo: StudentBasicInfo(studentId: student.id, registrationDate: student.registrationDate ?? DateTime.now())),
                  );
                  final maxCount = foundStudentWithInfo.basicInfo.weeklyClassCount;
                  print('[DEBUG][onCellStudentsSelected] 클릭 등록 상태: usedCount=$usedCount, maxCount=$maxCount, _remainingRegisterCount=$_remainingRegisterCount');
                  print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 클릭 등록 setState 전: _remainingRegisterCount=$_remainingRegisterCount, _isStudentRegistrationMode=$_isStudentRegistrationMode, _selectedStudentWithInfo=$_selectedStudentWithInfo');
                  setState(() {
                    _remainingRegisterCount = (maxCount - usedCount) > 0 ? (maxCount - usedCount) : 0;
                    print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 클릭 등록 setState 후: _remainingRegisterCount=$_remainingRegisterCount, _isStudentRegistrationMode=$_isStudentRegistrationMode, _selectedStudentWithInfo=$_selectedStudentWithInfo');
                    if (_remainingRegisterCount == 0) {
                      print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 클릭 등록 등록모드 종료');
                      _isStudentRegistrationMode = false;
                      _selectedStudentWithInfo = null;
                      _selectedDayIndex = null;
                      _selectedStartTimeHour = null;
                      _selectedStartTimeMinute = null;
                    }
                  });
                  if (_remainingRegisterCount == 0 && mounted) {
                    print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 클릭 등록 완료 스낵바');
                    showAppSnackBar(context, '\x1b[33m${student.name}\x1b[0m 학생의 수업시간 등록이 완료되었습니다.', useRoot: true);
                  }
                  print('[DEBUG][onCellStudentsSelected][${DateTime.now().toIso8601String()}] 클릭 등록 return');
                }
              }
            },
            filteredStudentIds: filteredStudentIds, // 추가: 필터 적용
            selectedStudentWithInfo: _selectedStudentWithInfo, // 추가
            onCellSelfStudyStudentsChanged: (dayIdx, startTime, students) {
              // 자습 블록 수정 로직은 TimetableContentView에서 처리
            },
          ),
        ),
      ],
    );
  }

  Future<void> _handleTimeSelection(int dayIdx, DateTime startTime) async {
    print('[DEBUG] _handleTimeSelection called: dayIdx= [33m$dayIdx [0m, startTime= [33m$startTime [0m, _isStudentRegistrationMode=$_isStudentRegistrationMode, _remainingRegisterCount=$_remainingRegisterCount');
    if (_isStudentRegistrationMode && _remainingRegisterCount != null && _remainingRegisterCount! > 0) {
      // 요일별 운영시간 체크
      final operatingHours = _operatingHours.length > dayIdx ? _operatingHours[dayIdx] : null;
      if (operatingHours != null) {
        final start = DateTime(startTime.year, startTime.month, startTime.day, operatingHours.startHour, operatingHours.startMinute);
        final end = DateTime(startTime.year, startTime.month, startTime.day, operatingHours.endHour, operatingHours.endMinute);
        if (startTime.isBefore(start) || !startTime.isBefore(end)) {
          print('[DEBUG] 시간 범위 벗어남: start=$start, end=$end');
          await showDialog(
            context: context,
            builder: (context) => AlertDialog(
              backgroundColor: Colors.black,
              title: const Text('운영시간 외 등록 불가', style: TextStyle(color: Colors.white)),
              content: const Text('해당 요일의 운영시간 내에서만 학생을 등록할 수 있습니다.', style: TextStyle(color: Colors.white70)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('확인', style: TextStyle(color: Colors.white)),
                ),
              ],
            ),
          );
          return;
        }
      }
      // 학생 등록: 이미 선택된 학생(_selectedStudentWithInfo)로 바로 등록
      final studentWithInfo = _selectedStudentWithInfo;
      print('[DEBUG] _selectedStudentWithInfo: $studentWithInfo');
      if (studentWithInfo != null) {
        // 1. 기존 등록된 블록 개수 확인
        final existingBlocks = DataManager.instance.studentTimeBlocks
            .where((b) => b.studentId == studentWithInfo.student.id)
            .length;
        final foundStudentWithInfo = DataManager.instance.students.firstWhere(
          (s) => s.student.id == studentWithInfo.student.id,
          orElse: () => StudentWithInfo(student: studentWithInfo.student, basicInfo: StudentBasicInfo(studentId: studentWithInfo.student.id, registrationDate: studentWithInfo.student.registrationDate ?? DateTime.now())),
        );
        final maxCount = foundStudentWithInfo.basicInfo.weeklyClassCount;
        if (existingBlocks >= maxCount) {
          // 이미 최대 등록, 추가 불가
          showAppSnackBar(context, '${studentWithInfo.student.name} 학생은 이미 최대 수업시간이 등록되어 있습니다.', useRoot: true);
          return;
        }
        // 2. 시간블록 추가 (팩토리 사용, 단일 등록도 일관성 있게)
        final blocks = StudentTimeBlockFactory.createBlocksWithSetIdAndNumber(
          studentIds: [studentWithInfo.student.id],
          dayIndex: dayIdx,
          startTimes: [startTime],
          duration: Duration(minutes: DataManager.instance.academySettings.lessonDuration),
        );
        await DataManager.instance.addStudentTimeBlock(blocks.first);
        print('[DEBUG] StudentTimeBlock 등록 완료: ${blocks.first}');
        // 스낵바 출력
        if (mounted) {
          print('[DEBUG] 스낵바 출력');
          showAppSnackBar(context, '${studentWithInfo.student.name} 학생의 시간이 등록되었습니다.', useRoot: true);
        } else {
          print('[DEBUG] context not mounted, 스낵바 출력 불가');
        }
      } else {
        print('[DEBUG] studentWithInfo == null, 등록 실패');
      }
      setState(() {
        if (_remainingRegisterCount != null && _remainingRegisterCount! > 1) {
          _remainingRegisterCount = _remainingRegisterCount! - 1;
          // 등록모드 유지, 다음 셀 선택 대기
        } else {
          // 마지막 등록, 등록모드 종료
          _isStudentRegistrationMode = false;
          _selectedStudentWithInfo = null;
          _selectedDayIndex = null;
          _selectedStartTimeHour = null;
          _selectedStartTimeMinute = null;
          _remainingRegisterCount = null;
        }
      });
      // 마지막 등록 후 안내
      if (_remainingRegisterCount == null) {
        if (mounted && studentWithInfo != null) {
          showAppSnackBar(context, '${studentWithInfo.student.name} 학생의 수업시간 등록이 완료되었습니다.', useRoot: true);
        }
      }
      return;
    }
    if (_isClassRegistrationMode && _currentGroupSchedule != null) {
      print('[DEBUG] 클래스 등록모드 진입');
      // 기존 클래스 등록 로직은 유지
      final operatingHours = _operatingHours.length > dayIdx ? _operatingHours[dayIdx] : null;
      if (operatingHours != null) {
        final start = DateTime(startTime.year, startTime.month, startTime.day, operatingHours.startHour, operatingHours.startMinute);
        final end = DateTime(startTime.year, startTime.month, startTime.day, operatingHours.endHour, operatingHours.endMinute);
        if (startTime.isBefore(start) || !startTime.isBefore(end)) {
          print('[DEBUG] 클래스 시간 범위 벗어남: start=$start, end=$end');
          await showDialog(
            context: context,
            builder: (context) => AlertDialog(
              backgroundColor: Colors.black,
              title: const Text('운영시간 외 등록 불가', style: TextStyle(color: Colors.white)),
              content: const Text('해당 요일의 운영시간 내에서만 클래스 시간을 등록할 수 있습니다.', style: TextStyle(color: Colors.white70)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('확인', style: TextStyle(color: Colors.white)),
                ),
              ],
            ),
          );
          return;
        }
      }
      final updatedSchedule = _currentGroupSchedule!.copyWith(
        startTime: startTime,
        dayIndex: dayIdx,
      );
      if (_currentGroupSchedule!.createdAt == _currentGroupSchedule!.updatedAt) {
        await DataManager.instance.addGroupSchedule(updatedSchedule);
        print('[DEBUG] 새 클래스 스케줄 등록');
      } else {
        await DataManager.instance.updateGroupSchedule(updatedSchedule);
        print('[DEBUG] 기존 클래스 스케줄 수정');
      }
      await DataManager.instance.applyGroupScheduleToStudents(updatedSchedule);
      setState(() {
        print('[DEBUG] setState: 클래스 등록모드 종료');
        _isClassRegistrationMode = false;
        _currentGroupSchedule = null;
        _selectedDayIndex = null;
        _selectedStartTimeHour = null;
        _selectedStartTimeMinute = null;
      });
      if (mounted) {
        print('[DEBUG] 클래스 스낵바 출력');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_selectedGroup!.name} 클래스 시간이 등록되었습니다.'),
            backgroundColor: const Color(0xFF1976D2),
            behavior: SnackBarBehavior.floating,
            margin: EdgeInsets.only(bottom: 80, left: 20, right: 20),
          ),
        );
      } else {
        print('[DEBUG] context not mounted, 클래스 스낵바 출력 불가');
      }
    }
  }

  // --- 필터 학생 getter 및 변환 함수 복구 ---
  List<StudentWithInfo> get _filteredStudents {
    final all = DataManager.instance.students;
    final f = _activeFilter;
    if (f == null) return all;
    final filtered = all.where((s) {
      final student = s.student;
      final info = s.basicInfo;
      if (f['educationLevels']!.isNotEmpty) {
        final levelStr = _educationLevelToKor(student.educationLevel);
        if (!f['educationLevels']!.contains(levelStr)) return false;
      }
      if (f['grades']!.isNotEmpty) {
        final gradeStr = _gradeToKor(student.educationLevel, student.grade);
        if (!f['grades']!.contains(gradeStr)) return false;
      }
      if (f['schools']!.isNotEmpty && !f['schools']!.contains(student.school)) return false;
      if (f['groups']!.isNotEmpty && (student.groupInfo == null || !f['groups']!.contains(student.groupInfo!.name))) return false;
      
      // 수업별 필터링 추가
      if (f['classes']!.isNotEmpty) {
        final classes = DataManager.instance.classesNotifier.value;
        final selectedClassIds = f['classes']!.map((className) {
          final classInfo = classes.firstWhereOrNull((c) => c.name == className);
          return classInfo?.id;
        }).where((id) => id != null).cast<String>().toSet();
        
        if (selectedClassIds.isNotEmpty) {
          final studentBlocks = DataManager.instance.studentTimeBlocks.where((b) => b.studentId == student.id).toList();
          final hasMatchingClass = studentBlocks.any((block) => 
            block.sessionTypeId != null && selectedClassIds.contains(block.sessionTypeId));
          if (!hasMatchingClass) return false;
        }
      }
      
      return true;
    }).toList();
    print('[DEBUG] 필터 적용 결과: ${filtered.map((s) => s.student.name).toList()}');
    return filtered;
  }

  String _educationLevelToKor(EducationLevel level) {
    switch (level) {
      case EducationLevel.elementary: return '초등';
      case EducationLevel.middle: return '중등';
      case EducationLevel.high: return '고등';
    }
  }

  String _gradeToKor(EducationLevel level, int grade) {
    if (level == EducationLevel.elementary) return '초$grade';
    if (level == EducationLevel.middle) return '중$grade';
    if (level == EducationLevel.high) {
      if (grade >= 1 && grade <= 3) return '고$grade';
      if (grade == 0) return 'N수';
    }
    return '';
  }

  // dayIdx, startTime에 해당하는 학생 리스트 반환
  List<StudentWithInfo> _getCellStudents(int dayIdx, int startHour, int startMinute) {
    final blocks = DataManager.instance.studentTimeBlocks.where((b) {
      //print('[DEBUG][_getCellStudents] 비교: b.dayIndex=${b.dayIndex} == $dayIdx, b.startHour=${b.startHour} == $startHour, b.startMinute=${b.startMinute} == $startMinute, b.studentId=${b.studentId}');
      return b.dayIndex == dayIdx && b.startHour == startHour && b.startMinute == startMinute;
    }).toList();
    final students = DataManager.instance.students;
    final result = blocks.map((b) =>
      students.firstWhere(
        (s) => s.student.id == b.studentId,
        orElse: () => StudentWithInfo(
          student: Student(id: '', name: '', school: '', grade: 0, educationLevel: EducationLevel.elementary),
          basicInfo: StudentBasicInfo(studentId: '', registrationDate: DateTime.now()),
        ),
      )
    ).toList();
    //print('[DEBUG][_getCellStudents] dayIdx=$dayIdx, startHour=$startHour, startMinute=$startMinute, blockCount=${blocks.length}, studentIds=${result.map((s) => s.student.id).toList()}');
    return result;
  }

  void _handleSelfStudyRegistration() {
    showDialog(
      context: context,
      builder: (context) => SelfStudyRegistrationDialog(
        onStudentSelected: (student) {
          setState(() {
            _isSelfStudyRegistrationMode = true;
            _selectedSelfStudyStudent = student;
            print('[DEBUG][setState] _selectedSelfStudyStudent:  [33m$_selectedSelfStudyStudent [0m');
          });
        },
      ),
    ).then((value) {
      if (value != null) {
        setState(() {
          _isSelfStudyRegistrationMode = true;
          _selectedSelfStudyStudent = value;
          print('[DEBUG][TimetableScreen] showDialog 반환값:  [33m$value [0m');
        });
      }
    });
  }
}

class SelfStudyRegistrationDialog extends StatefulWidget {
  final ValueChanged<StudentWithInfo> onStudentSelected;
  const SelfStudyRegistrationDialog({Key? key, required this.onStudentSelected}) : super(key: key);

  @override
  State<SelfStudyRegistrationDialog> createState() => _SelfStudyRegistrationDialogState();
}

class _SelfStudyRegistrationDialogState extends State<SelfStudyRegistrationDialog> {
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  List<StudentWithInfo> get _eligibleStudents => DataManager.instance.getSelfStudyEligibleStudents();
  List<StudentWithInfo> get _searchResults {
    if (_searchQuery.isEmpty) return [];
    final results = _eligibleStudents.where((student) {
      final nameMatch = student.student.name.toLowerCase().contains(_searchQuery.toLowerCase());
      final schoolMatch = student.student.school.toLowerCase().contains(_searchQuery.toLowerCase());
      final gradeMatch = student.student.grade.toString().contains(_searchQuery);
      return nameMatch || schoolMatch || gradeMatch;
    }).toList();
    print('[DEBUG][SelfStudyRegistrationDialog] 자습 등록 가능 학생 검색 결과: ' + results.map((s) => s.student.name).toList().toString());
    return results;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      title: const Text('자습 등록', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white),
              onChanged: (value) => setState(() => _searchQuery = value),
              decoration: InputDecoration(
                labelText: '학생 이름 또는 학교 검색',
                labelStyle: const TextStyle(color: Colors.white70),
                prefixIcon: const Icon(Icons.search, color: Colors.white70),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                ),
                focusedBorder: const OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF1976D2)),
                ),
              ),
            ),
            const SizedBox(height: 18),
            SizedBox(
              height: 120,
              child: _searchQuery.isEmpty
                  ? const Center(child: Text('학생을 검색하세요.', style: TextStyle(color: Colors.white38, fontSize: 15)))
                  : _searchResults.isEmpty
                      ? const Center(child: Text('검색 결과가 없습니다.', style: TextStyle(color: Colors.white38, fontSize: 15)))
                      : Scrollbar(
                          thumbVisibility: true,
                          child: ListView.separated(
                            itemCount: _searchResults.length,
                            separatorBuilder: (_, __) => const Divider(color: Colors.white12, height: 1),
                            itemBuilder: (context, idx) {
                              final info = _searchResults[idx];
                              return ListTile(
                                title: Text(info.student.name, style: const TextStyle(color: Colors.white)),
                                subtitle: Text('${info.student.school} / ${info.student.grade}학년', style: const TextStyle(color: Colors.white70, fontSize: 14)),
                                onTap: () {
                                  print('[DEBUG][SelfStudyRegistrationDialog] 학생 선택:  [33m${info.student.name} [0m');
                                  Navigator.of(context).pop(info); // 반드시 StudentWithInfo 반환
                                },
                              );
                            },
                          ),
                        ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기', style: TextStyle(color: Colors.white70)),
        ),
      ],
    );
  }
}

class _DropdownMenuButton extends StatefulWidget {
  final bool isOpen;
  final ValueChanged<bool> onOpenChanged;
  final ValueChanged<String> onSelected;
  const _DropdownMenuButton({required this.isOpen, required this.onOpenChanged, required this.onSelected});

  @override
  State<_DropdownMenuButton> createState() => _DropdownMenuButtonState();
}

class _DropdownMenuButtonState extends State<_DropdownMenuButton> with SingleTickerProviderStateMixin {
  final GlobalKey _buttonKey = GlobalKey();
  OverlayEntry? _overlayEntry;
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
  }

  @override
  void dispose() {
    _controller.dispose();
    _removeOverlay();
    super.dispose();
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _toggleDropdown() {
    if (_overlayEntry == null) {
      _controller.forward();
      _overlayEntry = _createOverlayEntry();
      Overlay.of(context).insert(_overlayEntry!);
      widget.onOpenChanged(true);
    } else {
      _controller.reverse();
      _removeOverlay();
      widget.onOpenChanged(false);
    }
  }

  OverlayEntry _createOverlayEntry() {
    RenderBox renderBox = _buttonKey.currentContext!.findRenderObject() as RenderBox;
    final size = renderBox.size;
    final offset = renderBox.localToGlobal(Offset.zero);
    return OverlayEntry(
      builder: (context) => Positioned(
        left: offset.dx,
        top: offset.dy + size.height + 4,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.all(24), // 상하좌우 여백 24
            decoration: BoxDecoration(
              color: const Color(0xFF1F1F1F), // 학생카드와 동일한 색상
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.18),
                  blurRadius: 16,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ...['학생', '그룹', '보강', '일정'].map((label) =>
                  FadeTransition(
                    opacity: _controller,
                    child: ScaleTransition(
                      scale: _controller,
                      child: _DropdownMenuItem(
                        label: label,
                        onTap: () {
                          widget.onSelected(label);
                          _toggleDropdown();
                        },
                        width: 84, // 30% 줄임 (120 -> 84)
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: _buttonKey,
      onTap: _toggleDropdown,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        width: 44,
        height: 44,
        decoration: ShapeDecoration(
          color: const Color(0xFF1976D2),
          shape: RectangleShapeBorder(
            borderRadius: widget.isOpen
              ? DynamicBorderRadius.all(DynamicRadius.circular(50.toPercentLength))
              : DynamicBorderRadius.only(
                  topLeft: DynamicRadius.circular(6.toPXLength),
                  bottomLeft: DynamicRadius.circular(6.toPXLength),
                  topRight: DynamicRadius.circular(32.toPXLength),
                  bottomRight: DynamicRadius.circular(32.toPXLength),
                ),
          ),
        ),
        child: Center(
          child: AnimatedRotation(
            turns: widget.isOpen ? 0.5 : 0.0, // 0.5turn = 180도
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeInOut,
            child: const Icon(
              Icons.keyboard_arrow_down,
              color: Colors.white,
              size: 28,
              key: ValueKey('arrow'),
            ),
          ),
        ),
      ),
    );
  }
}

// 학생카드 하위 버튼 스타일과 동일하게
class _DropdownMenuItem extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final double width;
  const _DropdownMenuItem({required this.label, required this.onTap, this.width = 84});

  @override
  State<_DropdownMenuItem> createState() => _DropdownMenuItemState();
}

class _DropdownMenuItemState extends State<_DropdownMenuItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: widget.width,
          height: 38, // 기존 48에서 20% 감소
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 14), // 높이 줄임
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            color: _hovered ? const Color(0xFF353545) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.centerLeft,
          child: Text(
            widget.label,
            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
          ),
        ),
      ),
    );
  }
}

// 버튼이 원형/네모로 바뀔 때만 바운스 효과 적용하는 위젯
class _BouncyDropdownButton extends StatefulWidget {
  final bool isOpen;
  final Widget child;
  const _BouncyDropdownButton({required this.isOpen, required this.child});

  @override
  State<_BouncyDropdownButton> createState() => _BouncyDropdownButtonState();
}

class _BouncyDropdownButtonState extends State<_BouncyDropdownButton> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnim;
  bool _prevIsOpen = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 1.08)
        .chain(CurveTween(curve: Curves.elasticOut))
        .animate(_controller);
    _prevIsOpen = widget.isOpen;
  }

  @override
  void didUpdateWidget(covariant _BouncyDropdownButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isOpen != widget.isOpen) {
      if (widget.isOpen) {
        _controller.forward(from: 0);
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
    return ScaleTransition(
      scale: _scaleAnim,
      child: widget.child,
    );
  }
}