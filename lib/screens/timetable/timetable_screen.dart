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
    return Column(
      children: [
        const AppBarTitle(title: '시간'),
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
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 메인(시간표) 컨테이너
                Expanded(
                  flex: 5,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Color(0xFF18181A),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        TimetableHeader(
                          selectedDate: _selectedDate,
                          onDateChanged: _handleDateChanged,
                          selectedDayIndex: _isStudentRegistrationMode ? (_selectedDayIndex ?? 0) : null,
                          onDaySelected: _onDayHeaderSelected,
                          isRegistrationMode: _isStudentRegistrationMode || _isClassRegistrationMode,
                        ),
                        const SizedBox(height: 24),
                        Expanded(
                          child: SingleChildScrollView(
                            child: _buildContent(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 32),
                // 오른쪽 2:5 비율 컨테이너 (상하 분할)
                Expanded(
                  flex: 2,
                  child: Column(
                    children: [
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Color(0xFF18181A),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          margin: const EdgeInsets.only(bottom: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(12.0),
                                child: Row(
                                  children: [
                                    // SplitButton: 등록 + 드롭다운
                                    Expanded(
                                      child: Material(
                                        color: const Color(0xFF7C4DFF),
                                        borderRadius: const BorderRadius.only(
                                          topLeft: Radius.circular(32),
                                          bottomLeft: Radius.circular(32),
                                          topRight: Radius.circular(12),
                                          bottomRight: Radius.circular(12),
                                        ),
                                        child: InkWell(
                                          borderRadius: const BorderRadius.only(
                                            topLeft: Radius.circular(32),
                                            bottomLeft: Radius.circular(32),
                                            topRight: Radius.circular(12),
                                            bottomRight: Radius.circular(12),
                                          ),
                                          onTap: () {
                                            if (_splitButtonSelected == '학생') {
                                              setState(() {
                                                _isStudentRegistrationMode = !_isStudentRegistrationMode;
                                                _isClassRegistrationMode = false;
                                              });
                                            } else {
                                              // 그룹명과 매칭되는 그룹 찾기 (GroupInfo? 타입 안전 처리)
                                              GroupInfo? group;
                                              if (_groups.isNotEmpty) {
                                                group = _groups.firstWhere(
                                                  (g) => g.name == _splitButtonSelected,
                                                  orElse: () => _groups.first,
                                                );
                                              } else {
                                                group = null;
                                              }
                                              if (group != null) {
                                                setState(() {
                                                  _selectedGroup = group;
                                                });
                                                _showGroupScheduleDialog();
                                              }
                                            }
                                          },
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
                                            child: Row(
                                              mainAxisAlignment: MainAxisAlignment.center,
                                              children: [
                                                Icon(Icons.edit, color: Colors.white),
                                                const SizedBox(width: 8),
                                                Text('등록', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    Container(
                                      height: 56,
                                      width: 2,
                                      color: Colors.white.withOpacity(0.1),
                                    ),
                                    Material(
                                      color: const Color(0xFF7C4DFF),
                                      borderRadius: const BorderRadius.only(
                                        topRight: Radius.circular(32),
                                        bottomRight: Radius.circular(32),
                                      ),
                                      child: PopupMenuButton<String>(
                                        icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white),
                                        color: Colors.white,
                                        onSelected: (value) {
                                          setState(() {
                                            _splitButtonSelected = value;
                                          });
                                        },
                                        itemBuilder: (context) {
                                          return [
                                            const PopupMenuItem<String>(
                                              value: '학생',
                                              child: Text('학생'),
                                            ),
                                            ..._groups.map((g) => PopupMenuItem<String>(
                                              value: g.name,
                                              child: Text(g.name),
                                            )),
                                          ];
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              // 기존 컨테이너 내용이 있다면 여기에 추가
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Color(0xFF18181A),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          margin: const EdgeInsets.only(top: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildContent() {
    switch (_viewType) {
      case TimetableViewType.classes:
        return ClassesView(
          operatingHours: _operatingHours,
          breakTimeColor: const Color(0xFF424242),
          selectedDayIndex: _selectedDayIndex ?? 0,
          isRegistrationMode: _isStudentRegistrationMode || _isClassRegistrationMode,
          onTimeSelected: _handleTimeSelection,
        );
      case TimetableViewType.schedule:
        return Container(); // TODO: Implement ScheduleView
    }
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