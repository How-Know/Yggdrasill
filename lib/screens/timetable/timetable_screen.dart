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

enum TimetableViewType {
  classes,    // 수업
  schedule;   // 스케줄

  String get name {
    switch (this) {
      case TimetableViewType.classes:
        return '수업';
      case TimetableViewType.schedule:
        return '스케줄';
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
  DateTime? _selectedStartTime;
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
  Student? _selectedStudentForTime;
  // 학생 연속 등록을 위한 상태 변수 추가
  int? _remainingRegisterCount;
  final ScrollController _timetableScrollController = ScrollController();
  bool _hasScrolledToCurrentTime = false;
  // 셀 선택 시 학생 리스트 상태 추가
  List<StudentWithInfo>? _selectedCellStudents;
  int? _selectedCellDayIndex; // 셀 선택시 요일 인덱스
  DateTime? _selectedCellStartTime; // 셀 선택시 시작 시간
  final FocusNode _focusNode = FocusNode();

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
      print('[DEBUG][_scrollToCurrentTime] block[$i]: ' + block.startTime.toString() + ' ~ ' + block.endTime.toString());
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
      final dayIdx = block.dayIndex;
      if (dayIdx >= allHours.length) continue;
      final op = allHours[dayIdx];
      final blockMinutes = block.startTime.hour * 60 + block.startTime.minute;
      final startMinutes = op.startTime.hour * 60 + op.startTime.minute;
      final endMinutes = op.endTime.hour * 60 + op.endTime.minute;
      if (blockMinutes < startMinutes || blockMinutes >= endMinutes) {
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
    if (_splitButtonSelected == '학생') {
      // 학생 수업시간 등록 모드 진입 시 다이얼로그 띄우기
      final selectedStudent = await showDialog<Student>(
        context: context,
        barrierDismissible: true,
        builder: (context) => StudentSearchDialog(onlyShowIncompleteStudents: true),
      );
      if (selectedStudent != null) {
        // StudentWithInfo에서 basicInfo.weeklyClassCount를 가져옴
        final studentWithInfo = DataManager.instance.students.firstWhere(
          (s) => s.student.id == selectedStudent.id,
          orElse: () => StudentWithInfo(student: selectedStudent, basicInfo: StudentBasicInfo(studentId: selectedStudent.id, registrationDate: selectedStudent.registrationDate ?? DateTime.now())),
        );
        final classCount = studentWithInfo.basicInfo.weeklyClassCount;
        setState(() {
          _isStudentRegistrationMode = true;
          _isClassRegistrationMode = false;
          _selectedStudentForTime = selectedStudent;
          // StudentBasicInfo의 weeklyClassCount로 초기화
          _remainingRegisterCount = classCount;
        });
        print('[DEBUG] 학생 선택 후 등록모드 진입: _isStudentRegistrationMode=$_isStudentRegistrationMode, _remainingRegisterCount=$_remainingRegisterCount');
      } else {
        setState(() {
          _isStudentRegistrationMode = false;
          _isClassRegistrationMode = false;
          _selectedStudentForTime = null;
          _remainingRegisterCount = null;
        });
        print('[DEBUG] 학생 선택 취소: _isStudentRegistrationMode=$_isStudentRegistrationMode');
      }
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

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    print('[DEBUG][TimetableScreen] build: _isStudentRegistrationMode= [38;5;246m$_isStudentRegistrationMode [0m');
    return RawKeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKey: (event) {
        if ((event.logicalKey == LogicalKeyboardKey.escape) && (_isStudentRegistrationMode || _isClassRegistrationMode)) {
          setState(() {
            _isStudentRegistrationMode = false;
            _isClassRegistrationMode = false;
            _selectedStudentForTime = null;
            _remainingRegisterCount = null;
          });
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          if (_isStudentRegistrationMode || _isClassRegistrationMode) {
            setState(() {
              _isStudentRegistrationMode = false;
              _isClassRegistrationMode = false;
              _selectedStudentForTime = null;
              _remainingRegisterCount = null;
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
        return TimetableContentView(
          // key: ValueKey(_isStudentRegistrationMode), // 강제 리빌드 제거
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
                ),
                SizedBox(height: 0),
                Flexible(
                  child: _buildClassView(),
                ),
              ],
            ),
          ),
          onRegisterPressed: () {
            if (_splitButtonSelected == '학생') {
              _handleRegistrationButton();
            } else if (_splitButtonSelected == '그룹') {
              setState(() {
                _isClassRegistrationMode = true;
              });
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
          selectedCellStudents: _selectedCellStudents,
          selectedCellDayIndex: _selectedCellDayIndex,
          selectedCellStartTime: _selectedCellStartTime,
          onCellStudentsChanged: (updatedList) {
            setState(() {
              _selectedCellStudents = updatedList;
            });
          },
        );
      case TimetableViewType.schedule:
        return Container(); // TODO: Implement ScheduleView
    }
  }

  Widget _buildClassView() {
    // StudentWithInfo에서 basicInfo.weeklyClassCount를 가져옴
    int? totalClassCount;
    if (_isStudentRegistrationMode && _selectedStudentForTime != null) {
      final studentWithInfo = DataManager.instance.students.firstWhere(
        (s) => s.student.id == _selectedStudentForTime!.id,
        orElse: () => StudentWithInfo(
          student: _selectedStudentForTime!,
          basicInfo: StudentBasicInfo(
            studentId: _selectedStudentForTime!.id,
            registrationDate: _selectedStudentForTime!.registrationDate ?? DateTime.now(),
          ),
        ),
      );
      totalClassCount = studentWithInfo.basicInfo.weeklyClassCount ?? 1;
    }
    return Column(
      children: [
        if (_isStudentRegistrationMode && _selectedStudentForTime != null && _remainingRegisterCount != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: Text(
              '${_selectedStudentForTime!.name} 학생: 수업시간 등록 (${(totalClassCount ?? 1) - (_remainingRegisterCount ?? 0) + 1}/${totalClassCount ?? 1})',
              style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
            ),
          ),
        Expanded(
          child: ClassesView(
            scrollController: _timetableScrollController,
            operatingHours: _operatingHours,
            breakTimeColor: const Color(0xFF424242),
            isRegistrationMode: _isStudentRegistrationMode || _isClassRegistrationMode,
            selectedDayIndex: _isStudentRegistrationMode ? null : _selectedDayIndex,
            onTimeSelected: (int dayIdx, DateTime startTime) {
              _handleTimeSelection(dayIdx, startTime);
            },
            onCellStudentsSelected: (int dayIdx, DateTime startTime, List<StudentWithInfo> students) {
              setState(() {
                _selectedCellStudents = students;
                _selectedCellDayIndex = dayIdx;
                _selectedCellStartTime = startTime;
              });
            },
          ),
        ),
      ],
    );
  }

  Future<void> _handleTimeSelection(int dayIdx, DateTime startTime) async {
    print('[DEBUG] _handleTimeSelection called: dayIdx=$dayIdx, startTime=$startTime, _isStudentRegistrationMode=$_isStudentRegistrationMode, _remainingRegisterCount=$_remainingRegisterCount');
    if (_isStudentRegistrationMode && _remainingRegisterCount != null && _remainingRegisterCount! > 0) {
      // 요일별 운영시간 체크
      final operatingHours = _operatingHours.length > dayIdx ? _operatingHours[dayIdx] : null;
      if (operatingHours != null) {
        final start = DateTime(startTime.year, startTime.month, startTime.day, operatingHours.startTime.hour, operatingHours.startTime.minute);
        final end = DateTime(startTime.year, startTime.month, startTime.day, operatingHours.endTime.hour, operatingHours.endTime.minute);
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
      // 학생 등록: 이미 선택된 학생(_selectedStudentForTime)로 바로 등록
      final student = _selectedStudentForTime;
      print('[DEBUG] _selectedStudentForTime: $student');
      if (student != null) {
        final block = StudentTimeBlock(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          studentId: student.id,
          groupId: student.groupInfo?.id,
          dayIndex: dayIdx,
          startTime: startTime,
          duration: Duration(minutes: DataManager.instance.academySettings.lessonDuration),
          createdAt: DateTime.now(),
        );
        await DataManager.instance.addStudentTimeBlock(block);
        print('[DEBUG] StudentTimeBlock 등록 완료: $block');
        // 스낵바 출력
        if (mounted) {
          print('[DEBUG] 스낵바 출력');
          showAppSnackBar(context, '${student.name} 학생의 시간이 등록되었습니다.', useRoot: true);
        } else {
          print('[DEBUG] context not mounted, 스낵바 출력 불가');
        }
      } else {
        print('[DEBUG] student == null, 등록 실패');
      }
      setState(() {
        if (_remainingRegisterCount != null && _remainingRegisterCount! > 1) {
          _remainingRegisterCount = _remainingRegisterCount! - 1;
          // 등록모드 유지, 다음 셀 선택 대기
        } else {
          // 마지막 등록, 등록모드 종료
          _isStudentRegistrationMode = false;
          _selectedStudentForTime = null;
          _selectedDayIndex = null;
          _selectedStartTime = null;
          _remainingRegisterCount = null;
        }
      });
      // 마지막 등록 후 안내
      if (_remainingRegisterCount == null) {
        if (mounted && student != null) {
          showAppSnackBar(context, '${student.name} 학생의 수업시간 등록이 완료되었습니다.', useRoot: true);
        }
      }
      return;
    }
    if (_isClassRegistrationMode && _currentGroupSchedule != null) {
      print('[DEBUG] 클래스 등록모드 진입');
      // 기존 클래스 등록 로직은 유지
      final operatingHours = _operatingHours.length > dayIdx ? _operatingHours[dayIdx] : null;
      if (operatingHours != null) {
        final start = DateTime(startTime.year, startTime.month, startTime.day, operatingHours.startTime.hour, operatingHours.startTime.minute);
        final end = DateTime(startTime.year, startTime.month, startTime.day, operatingHours.endTime.hour, operatingHours.endTime.minute);
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
        _selectedStartTime = null;
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