import 'package:flutter/material.dart';
import '../../models/class_info.dart';
import '../../models/operating_hours.dart';
import '../../models/student.dart';
import '../../services/data_manager.dart';
import '../../widgets/student_search_dialog.dart';
import '../../widgets/class_schedule_dialog.dart';
import '../../models/class_schedule.dart';
import 'components/timetable_header.dart';
import 'views/classes_view.dart';
import '../../models/student_time_block.dart';
import 'package:uuid/uuid.dart';
import '../../models/education_level.dart';

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
  List<ClassInfo> _classes = [];
  TimetableViewType _viewType = TimetableViewType.classes;
  List<OperatingHours> _operatingHours = [];
  final MenuController _menuController = MenuController();
  int? _selectedDayIndex = 0;
  DateTime? _selectedStartTime;
  bool _isStudentRegistrationMode = false;
  bool _isClassRegistrationMode = false;
  String _registrationButtonText = '등록';
  ClassInfo? _selectedClass;
  ClassSchedule? _currentClassSchedule;
  bool _showOperatingHoursAlert = false;

  @override
  void initState() {
    super.initState();
    _loadData();
    _loadOperatingHours();
  }

  Future<void> _loadData() async {
    await DataManager.instance.loadClasses();
    setState(() {
      _classes = List.from(DataManager.instance.classes);
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
          final s = DataManager.instance.students.firstWhere((s) => s.id == b.studentId, orElse: () => Student(id: '', name: '알 수 없음', school: '', grade: 0, educationLevel: EducationLevel.elementary, registrationDate: DateTime.now()));
          return s.name;
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
    } else if (_selectedClass != null) {
      // 클래스 등록 모드
      _showClassScheduleDialog();
    }
  }

  void _showClassScheduleDialog() {
    showDialog(
      context: context,
      builder: (context) => ClassScheduleDialog(
        classInfo: _selectedClass!,
        onScheduleSelected: (schedule) {
          Navigator.of(context).pop();
          setState(() {
            _currentClassSchedule = schedule;
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
        if (_currentClassSchedule != null) {
          // 클래스 스케줄의 요일 업데이트
          _currentClassSchedule = _currentClassSchedule!.copyWith(dayIndex: dayIndex);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        children: [
          const Center(
            child: Text(
              '시간',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Container(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Primary Button
                    SizedBox(
                      width: 110,
                      height: 40,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF1976D2),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          minimumSize: const Size.fromHeight(40),
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.horizontal(
                              left: Radius.circular(20),
                              right: Radius.circular(4),
                            ),
                          ),
                        ),
                        onPressed: _handleRegistrationButton,
                        icon: const Icon(Icons.edit, size: 20),
                        label: Text(
                          _registrationButtonText,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 3),
                    // Menu Button
                    MenuAnchor(
                      controller: _menuController,
                      menuChildren: [
                        MenuItemButton(
                          child: const Text(
                            '학생',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                          ),
                          onPressed: () {
                            _handleStudentMenu();
                            _menuController.close();
                          },
                        ),
                        ..._classes.map((classInfo) => 
                          MenuItemButton(
                            child: Text(
                              classInfo.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                              ),
                            ),
                            onPressed: () {
                              setState(() {
                                _selectedClass = classInfo;
                                _registrationButtonText = '클래스';
                                _isStudentRegistrationMode = false;
                              });
                              _menuController.close();
                            },
                          ),
                        ).toList(),
                      ],
                      style: const MenuStyle(
                        backgroundColor: MaterialStatePropertyAll(Color(0xFF2A2A2A)),
                        padding: MaterialStatePropertyAll(EdgeInsets.symmetric(vertical: 8)),
                        shape: MaterialStatePropertyAll(
                          RoundedRectangleBorder(
                            borderRadius: BorderRadius.all(Radius.circular(8)),
                          ),
                        ),
                      ),
                      builder: (context, controller, child) {
                        return SizedBox(
                          width: 40,
                          height: 40,
                          child: IconButton(
                            style: IconButton.styleFrom(
                              backgroundColor: const Color(0xFF1976D2),
                              shape: controller.isOpen 
                                ? const CircleBorder()
                                : const RoundedRectangleBorder(
                                    borderRadius: BorderRadius.horizontal(
                                      left: Radius.circular(4),
                                      right: Radius.circular(20),
                                    ),
                                  ),
                              padding: EdgeInsets.zero,
                            ),
                            icon: Icon(
                              controller.isOpen ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                              color: Colors.white,
                              size: 20,
                            ),
                            onPressed: () {
                              if (controller.isOpen) {
                                controller.close();
                              } else {
                                controller.open();
                              }
                            },
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Center(
                  child: SizedBox(
                    width: 250,
                    child: SegmentedButton<TimetableViewType>(
                      segments: TimetableViewType.values.map((type) => ButtonSegment(
                        value: type,
                        label: Text(
                          type.name,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      )).toList(),
                      selected: {_viewType},
                      onSelectionChanged: (Set<TimetableViewType> newSelection) {
                        setState(() {
                          _viewType = newSelection.first;
                        });
                      },
                      style: ButtonStyle(
                        backgroundColor: MaterialStateProperty.resolveWith<Color>(
                          (Set<MaterialState> states) {
                            if (states.contains(MaterialState.selected)) {
                              return const Color(0xFF78909C);
                            }
                            return Colors.transparent;
                          },
                        ),
                        foregroundColor: MaterialStateProperty.resolveWith<Color>(
                          (Set<MaterialState> states) {
                            if (states.contains(MaterialState.selected)) {
                              return Colors.white;
                            }
                            return Colors.white70;
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Container(width: 140),
            ],
          ),
          const SizedBox(height: 24),
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
          classId: student.classInfo?.id,
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
          classId: student.classInfo?.id,
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
    } else if (_isClassRegistrationMode && _currentClassSchedule != null) {
      // 클래스 스케줄 등록/수정 전 운영시간 체크
      final dayIdx = _currentClassSchedule!.dayIndex;
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
      final updatedSchedule = _currentClassSchedule!.copyWith(
        startTime: startTime,
        dayIndex: _selectedDayIndex ?? 0,
      );
      
      if (_currentClassSchedule!.createdAt == _currentClassSchedule!.updatedAt) {
        // 새로운 스케줄
        await DataManager.instance.addClassSchedule(updatedSchedule);
      } else {
        // 기존 스케줄 수정
        await DataManager.instance.updateClassSchedule(updatedSchedule);
      }
      
      // 해당 클래스의 모든 학생들에게 적용
      await DataManager.instance.applyClassScheduleToStudents(updatedSchedule);
      
      setState(() {
        _isClassRegistrationMode = false;
        _currentClassSchedule = null;
      });
      
      // 성공 메시지 표시
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${_selectedClass!.name} 클래스 시간이 등록되었습니다.'),
            backgroundColor: const Color(0xFF1976D2),
          ),
        );
      }
    }
  }
}