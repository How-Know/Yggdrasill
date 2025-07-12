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
  int? _selectedDayIndex = 0;
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

  @override
  void initState() {
    super.initState();
    _loadData();
    _loadOperatingHours();
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

  void _handleRegistrationButton() {
    if (_registrationButtonText == '학생') {
      setState(() {
        _isStudentRegistrationMode = !_isStudentRegistrationMode;
        _isClassRegistrationMode = false;
        if (!_isStudentRegistrationMode) {
          _registrationButtonText = '등록';
        }
      });
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
    if (_isStudentRegistrationMode || _isClassRegistrationMode) {
      setState(() {
        _selectedDayIndex = dayIndex;
        if (_currentGroupSchedule != null) {
          // 클래스 스케줄의 요일 업데이트
          _currentGroupSchedule = _currentGroupSchedule!.copyWith(dayIndex: dayIndex);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1F1F1F),
      appBar: const AppBarTitle(title: '시간'),
      body: Container(
        color: const Color(0xFF1F1F1F), // 프로그램 전체 배경색
        child: Column(
          children: [
            const SizedBox(height: 5),
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
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    switch (_viewType) {
      case TimetableViewType.classes:
        return TimetableContentView(
          timetableChild: Container(
            width: double.infinity,
            padding: EdgeInsets.zero,
            decoration: BoxDecoration(
              color: Color(0xFF18181A),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                SizedBox(
                  width: 450, // 기존 375에서 20% 증가 (375 * 1.2 = 450)
                  child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('모두')),
                      ButtonSegment(value: 1, label: Text('학년')),
                      ButtonSegment(value: 2, label: Text('학교')),
                      ButtonSegment(value: 3, label: Text('그룹')),
                    ],
                    selected: {_segmentIndex},
                    onSelectionChanged: (Set<int> newSelection) {
                      setState(() {
                        _segmentIndex = newSelection.first;
                      });
                    },
                    style: ButtonStyle(
                      backgroundColor: MaterialStateProperty.all(Colors.transparent),
                      foregroundColor: MaterialStateProperty.resolveWith<Color>(
                        (Set<MaterialState> states) {
                          if (states.contains(MaterialState.selected)) {
                            return Colors.white;
                          }
                          return Colors.white70;
                        },
                      ),
                      textStyle: MaterialStateProperty.all(
                        const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20), // 기존 10 → 20으로 변경
                TimetableHeader(
                  selectedDate: _selectedDate,
                  onDateChanged: _handleDateChanged,
                  selectedDayIndex: _isStudentRegistrationMode ? (_selectedDayIndex ?? 0) : null,
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
            setState(() {
              _isClassRegistrationMode = true;
            });
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
              _isDropdownOpen = false;
            });
          },
        );
      case TimetableViewType.schedule:
        return Container(); // TODO: Implement ScheduleView
    }
  }

  Widget _buildClassView() {
    return ClassesView(
      operatingHours: _operatingHours,
      breakTimeColor: const Color(0xFF424242),
      selectedDayIndex: _selectedDayIndex ?? 0,
      isRegistrationMode: _isStudentRegistrationMode || _isClassRegistrationMode,
      onTimeSelected: _handleTimeSelection,
    );
  }

  Future<void> _onTimeCellSelected(DateTime startTime) async {
    if (_isStudentRegistrationMode && _selectedDayIndex != null) {
      setState(() {
        _selectedStartTime = startTime;
      });
      final student = await showDialog<Student>(
        context: context,
        builder: (context) => const StudentSearchDialog(),
      );
      if (student != null) {
        final block = StudentTimeBlock(
          id: const Uuid().v4(),
          studentId: student.id,
          groupId: student.groupInfo?.id,
          dayIndex: _selectedDayIndex!,
          startTime: startTime,
          duration: const Duration(hours: 1),
          createdAt: DateTime.now(),
        );
        await DataManager.instance.addStudentTimeBlock(block);
      }
      setState(() {
        _isStudentRegistrationMode = false;
        _selectedDayIndex = null;
        _selectedStartTime = null;
        _registrationButtonText = '등록';
      });
    }
  }

  Future<void> _handleTimeSelection(DateTime startTime) async {
    if (_isStudentRegistrationMode) {
      // 요일별 운영시간 체크
      final dayIdx = _selectedDayIndex ?? 0;
      final operatingHours = _operatingHours.length > dayIdx ? _operatingHours[dayIdx] : null;
      if (operatingHours != null) {
        final start = DateTime(startTime.year, startTime.month, startTime.day, operatingHours.startTime.hour, operatingHours.startTime.minute);
        final end = DateTime(startTime.year, startTime.month, startTime.day, operatingHours.endTime.hour, operatingHours.endTime.minute);
        if (startTime.isBefore(start) || !startTime.isBefore(end)) {
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
      // 기존 학생 등록 코드
      final existingBlocks = DataManager.instance.studentTimeBlocksNotifier.value
          .where((block) => 
              block.dayIndex == (_selectedDayIndex ?? 0) &&
              block.startTime.hour == startTime.hour &&
              block.startTime.minute == startTime.minute)
          .toList();
      final excludedStudentIds = existingBlocks.map((block) => block.studentId).toSet();
      
      final student = await showDialog<Student>(
        context: context,
        builder: (context) => StudentSearchDialog(excludedStudentIds: excludedStudentIds),
      );
      if (student != null) {
        final block = StudentTimeBlock(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          studentId: student.id,
          groupId: student.groupInfo?.id,
          dayIndex: _selectedDayIndex ?? 0,
          startTime: startTime,
          duration: const Duration(hours: 1),
          createdAt: DateTime.now(),
        );
        await DataManager.instance.addStudentTimeBlock(block);
      }
      setState(() {
        _isStudentRegistrationMode = false;
        // 버튼 텍스트는 변경하지 않음 (학생으로 유지)
      });
    } else if (_isClassRegistrationMode && _currentGroupSchedule != null) {
      // 클래스 스케줄 등록/수정 전 운영시간 체크
      final dayIdx = _currentGroupSchedule!.dayIndex;
      final operatingHours = _operatingHours.length > dayIdx ? _operatingHours[dayIdx] : null;
      if (operatingHours != null) {
        final start = DateTime(startTime.year, startTime.month, startTime.day, operatingHours.startTime.hour, operatingHours.startTime.minute);
        final end = DateTime(startTime.year, startTime.month, startTime.day, operatingHours.endTime.hour, operatingHours.endTime.minute);
        if (startTime.isBefore(start) || !startTime.isBefore(end)) {
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
      // 클래스 스케줄 등록/수정
      final updatedSchedule = _currentGroupSchedule!.copyWith(
        startTime: startTime,
        dayIndex: _selectedDayIndex ?? 0,
      );
      
      if (_currentGroupSchedule!.createdAt == _currentGroupSchedule!.updatedAt) {
        // 새로운 스케줄
        await DataManager.instance.addGroupSchedule(updatedSchedule);
      } else {
        // 기존 스케줄 수정
        await DataManager.instance.updateGroupSchedule(updatedSchedule);
      }
      
      // 해당 클래스의 모든 학생들에게 적용
      await DataManager.instance.applyGroupScheduleToStudents(updatedSchedule);
      
      setState(() {
        _isClassRegistrationMode = false;
        _currentGroupSchedule = null;
      });
      
      // 성공 메시지 표시
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_selectedGroup!.name} 클래스 시간이 등록되었습니다.'),
            backgroundColor: const Color(0xFF1976D2),
            behavior: SnackBarBehavior.floating,
            margin: EdgeInsets.only(bottom: 80, left: 20, right: 20),
          ),
        );
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