import 'package:flutter/material.dart';
import '../../models/academy_settings.dart';
import '../../models/operating_hours.dart';
import '../../services/data_manager.dart';
import '../../models/payment_type.dart';
import '../../services/academy_db.dart';
import 'package:flutter/foundation.dart';
import '../../services/academy_hive.dart';
import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';

enum SettingType {
  academy,
  general,
}

enum DayOfWeek {
  monday,
  tuesday,
  wednesday,
  thursday,
  friday,
  saturday,
  sunday;

  String get koreanName {
    switch (this) {
      case DayOfWeek.monday:
        return '월요일';
      case DayOfWeek.tuesday:
        return '화요일';
      case DayOfWeek.wednesday:
        return '수요일';
      case DayOfWeek.thursday:
        return '목요일';
      case DayOfWeek.friday:
        return '금요일';
      case DayOfWeek.saturday:
        return '토요일';
      case DayOfWeek.sunday:
        return '일요일';
    }
  }
}

class TimeRange {
  final TimeOfDay start;
  final TimeOfDay end;

  const TimeRange({required this.start, required this.end});
}

enum TeacherRole { all, part, assistant }

String getTeacherRoleLabel(TeacherRole role) {
  switch (role) {
    case TeacherRole.all:
      return '전체';
    case TeacherRole.part:
      return '일부';
    case TeacherRole.assistant:
      return '보조';
  }
}

class Teacher {
  final String name;
  final TeacherRole role;
  final String contact;
  final String email;
  final String description;
  Teacher({required this.name, required this.role, required this.contact, required this.email, required this.description});
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  SettingType _selectedType = SettingType.academy;
  DayOfWeek? _selectedDay = DayOfWeek.monday;
  PaymentType _paymentType = PaymentType.monthly;
  
  // 학원 설정 컨트롤러들
  final TextEditingController _academyNameController = TextEditingController();
  final TextEditingController _sloganController = TextEditingController();
  final TextEditingController _capacityController = TextEditingController(text: '30');
  final TextEditingController _lessonDurationController = TextEditingController(text: '50');
  
  final Map<DayOfWeek, TimeRange?> _operatingHours = {
    DayOfWeek.monday: null,
    DayOfWeek.tuesday: null,
    DayOfWeek.wednesday: null,
    DayOfWeek.thursday: null,
    DayOfWeek.friday: null,
    DayOfWeek.saturday: null,
    DayOfWeek.sunday: null,
  };
  
  // Break time을 저장하는 맵 추가
  final Map<DayOfWeek, List<TimeRange>> _breakTimes = {
    DayOfWeek.monday: [],
    DayOfWeek.tuesday: [],
    DayOfWeek.wednesday: [],
    DayOfWeek.thursday: [],
    DayOfWeek.friday: [],
    DayOfWeek.saturday: [],
    DayOfWeek.sunday: [],
  };

  int _customTabIndex = 0;
  List<Teacher> _teachers = [];

  // 운영시간 카드 hover 상태 관리
  final Set<int> _hoveredOperatingHourCards = {};

  final GlobalKey _academyInfoKey = GlobalKey();
  double _academyInfoHeight = 0;

  final Set<int> _hoveredTabs = {};

  // 운영시간/휴식 카드의 showActions 상태를 외부에서 관리
  final Map<String, bool> _cardActions = {};

  Box? _teacherBox;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _initAndLoadAcademySettings();
    _initAndLoadTeachers();
  }

  @override
  void dispose() {
    _academyNameController.dispose();
    _sloganController.dispose();
    _capacityController.dispose();
    _lessonDurationController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    try {
      // 학원 기본 정보 로드
      await DataManager.instance.loadAcademySettings();
      await DataManager.instance.loadPaymentType();
      setState(() {
        _academyNameController.text = DataManager.instance.academySettings.name;
        _sloganController.text = DataManager.instance.academySettings.slogan;
        _capacityController.text = DataManager.instance.academySettings.defaultCapacity.toString();
        _lessonDurationController.text = DataManager.instance.academySettings.lessonDuration.toString();
        _paymentType = DataManager.instance.paymentType;
      });

      // 운영 시간 로드
      final hours = await DataManager.instance.getOperatingHours();
      setState(() {
        for (var hour in hours) {
          final day = DayOfWeek.values[hour.startTime.weekday - 1];
          _operatingHours[day] = TimeRange(
            start: TimeOfDay(hour: hour.startTime.hour, minute: hour.startTime.minute),
            end: TimeOfDay(hour: hour.endTime.hour, minute: hour.endTime.minute),
          );
          _breakTimes[day] = hour.breakTimes.map((breakTime) => TimeRange(
            start: TimeOfDay(hour: breakTime.startTime.hour, minute: breakTime.startTime.minute),
            end: TimeOfDay(hour: breakTime.endTime.hour, minute: breakTime.endTime.minute),
          )).toList();
        }
      });
    } catch (e) {
      print('Error loading settings: $e');
    }
  }

  Future<void> _initAndLoadAcademySettings() async {
    if (kIsWeb) {
      await AcademyHiveService.init();
      final dbData = AcademyHiveService.getAcademySettings();
      if (dbData != null) {
        setState(() {
          _academyNameController.text = dbData['name'] ?? '';
          _sloganController.text = dbData['slogan'] ?? '';
          _capacityController.text = (dbData['default_capacity'] ?? 30).toString();
          _lessonDurationController.text = (dbData['lesson_duration'] ?? 50).toString();
          final pt = dbData['payment_type'] as String?;
          if (pt == 'monthly') {
            _paymentType = PaymentType.monthly;
          } else if (pt == 'perClass') {
            _paymentType = PaymentType.perClass;
          }
        });
      }
    } else {
      await AcademyDbService.instance.getAcademySettings().then((dbData) {
        if (dbData != null) {
          setState(() {
            _academyNameController.text = dbData['name'] ?? '';
            _sloganController.text = dbData['slogan'] ?? '';
            _capacityController.text = (dbData['default_capacity'] ?? 30).toString();
            _lessonDurationController.text = (dbData['lesson_duration'] ?? 50).toString();
            final pt = dbData['payment_type'] as String?;
            if (pt == 'monthly') {
              _paymentType = PaymentType.monthly;
            } else if (pt == 'perClass') {
              _paymentType = PaymentType.perClass;
            }
          });
        }
      });
    }
  }

  Future<void> _initAndLoadTeachers() async {
    if (kIsWeb) {
      await Hive.initFlutter();
      _teacherBox = await Hive.openBox('teachers_box');
    }
    await _loadTeachers();
  }

  Future<void> _saveOperatingHours() async {
    try {
      final now = DateTime.now();
      final hours = <OperatingHours>[];
      
      for (var day in DayOfWeek.values) {
        final operatingHour = _operatingHours[day];
        if (operatingHour != null) {
          final startTime = DateTime(
            now.year,
            now.month,
            now.day + day.index + 1,
            operatingHour.start.hour,
            operatingHour.start.minute,
          );
          final endTime = DateTime(
            now.year,
            now.month,
            now.day + day.index + 1,
            operatingHour.end.hour,
            operatingHour.end.minute,
          );
          
          final breakTimes = _breakTimes[day]?.map((block) {
            final breakStartTime = DateTime(
              now.year,
              now.month,
              now.day + day.index + 1,
              block.start.hour,
              block.start.minute,
            );
            final breakEndTime = DateTime(
              now.year,
              now.month,
              now.day + day.index + 1,
              block.end.hour,
              block.end.minute,
            );
            return BreakTime(
              startTime: breakStartTime,
              endTime: breakEndTime,
            );
          }).toList() ?? [];

          hours.add(OperatingHours(
            startTime: startTime,
            endTime: endTime,
            breakTimes: breakTimes,
          ));
        }
      }

      await DataManager.instance.saveOperatingHours(hours);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('운영 시간이 저장되었습니다.')),
      );
    } catch (e) {
      print('Error saving operating hours: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('운영 시간 저장에 실패했습니다.')),
      );
    }
  }

  Future<void> _selectOperatingHours(BuildContext context, DayOfWeek day) async {
    final TimeOfDay? startTime = await showTimePicker(
      context: context,
      initialTime: _operatingHours[day]?.start ?? TimeOfDay.now(),
      builder: (BuildContext context, Widget? child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF1976D2),
              onPrimary: Colors.white,
              surface: Color(0xFF1F1F1F),
              onSurface: Colors.white,
            ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(
                foregroundColor: Color(0xFF1976D2),
              ),
            ),
          ),
          child: child!,
        );
      },
    );

    if (startTime != null) {
      final TimeOfDay? endTime = await showTimePicker(
        context: context,
        initialTime: startTime,
        builder: (BuildContext context, Widget? child) {
          return Theme(
            data: Theme.of(context).copyWith(
              colorScheme: const ColorScheme.dark(
                primary: Color(0xFF1976D2),
                onPrimary: Colors.white,
                surface: Color(0xFF1F1F1F),
                onSurface: Colors.white,
              ),
            ),
            child: child!,
          );
        },
      );

      if (endTime != null) {
        setState(() {
          _operatingHours[day] = TimeRange(start: startTime, end: endTime);
        });
      }
    }
  }

  Widget _buildGeneralSettings() {
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 48),
        child: Container(
          width: 1000,
          padding: const EdgeInsets.symmetric(horizontal: 28),
          decoration: BoxDecoration(
            color: Color(0xFF18181A),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 테마 설정
              const Padding(
                padding: EdgeInsets.only(top: 24),
                child: Text(
                  '테마',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              SegmentedButton<ThemeMode>(
                segments: const [
                  ButtonSegment<ThemeMode>(
                    value: ThemeMode.system,
                    label: Text('시스템'),
                  ),
                  ButtonSegment<ThemeMode>(
                    value: ThemeMode.light,
                    label: Text('라이트'),
                  ),
                  ButtonSegment<ThemeMode>(
                    value: ThemeMode.dark,
                    label: Text('다크'),
                  ),
                ],
                selected: {ThemeMode.dark},
                onSelectionChanged: (Set<ThemeMode> newSelection) {
                  // TODO: 테마 변경 기능 구현
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
              const SizedBox(height: 40),
              // 언어 설정
              const Text(
                '언어',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: 300,
                child: DropdownButtonFormField<String>(
                  value: 'ko',
                  decoration: InputDecoration(
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFF1976D2)),
                    ),
                  ),
                  dropdownColor: const Color(0xFF1F1F1F),
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                  items: const [
                    DropdownMenuItem(value: 'ko', child: Text('한국어')),
                    DropdownMenuItem(value: 'en', child: Text('English')),
                    DropdownMenuItem(value: 'ja', child: Text('日本語')),
                  ],
                  onChanged: (String? value) {
                    // TODO: 언어 변경 기능 구현
                  },
                ),
              ),
              const SizedBox(height: 40),
              // 알림 설정
              const Text(
                '알림',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 20),
              SwitchListTile(
                title: const Text(
                  '수업 시작 알림',
                  style: TextStyle(color: Colors.white, fontSize: 18),
                ),
                subtitle: const Text(
                  '수업 시작 10분 전에 알림을 받습니다',
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
                value: true,
                onChanged: (bool value) {
                  // TODO: 알림 설정 기능 구현
                },
                activeColor: const Color(0xFF1976D2),
              ),
              SwitchListTile(
                title: const Text(
                  '휴식 시간 알림',
                  style: TextStyle(color: Colors.white, fontSize: 18),
                ),
                subtitle: const Text(
                  '휴식 시간 시작과 종료 시 알림을 받습니다',
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
                value: true,
                onChanged: (bool value) {
                  // TODO: 알림 설정 기능 구현
                },
                activeColor: const Color(0xFF1976D2),
              ),
              const SizedBox(height: 40),
              // 자동 백업
              const Text(
                '자동 백업',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 20),
              SwitchListTile(
                title: const Text(
                  '클라우드 백업',
                  style: TextStyle(color: Colors.white, fontSize: 18),
                ),
                subtitle: const Text(
                  '매일 자정에 데이터를 자동으로 백업합니다',
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
                value: true,
                onChanged: (bool value) {
                  // TODO: 백업 설정 기능 구현
                },
                activeColor: const Color(0xFF1976D2),
              ),
              const Padding(padding: EdgeInsets.only(bottom: 24)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOperatingHoursSection() {
    const double blockWidth = 110.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '운영 시간',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 20),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: DayOfWeek.values.map((day) {
              return Container(
                width: blockWidth,
                margin: const EdgeInsets.only(right: 8.0),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2A2A),
                      borderRadius: BorderRadius.circular(8),
                    ),
                child: Center(
                  child: Text(
                    day.koreanName,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: Colors.white,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 12,
          children: DayOfWeek.values.map((day) {
            int dayIndex = day.index;
            final hasOperatingHours = _operatingHours[day] != null;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 운영시간 카드
                hasOperatingHours
                    ? MouseRegion(
                        cursor: SystemMouseCursors.click,
                        onEnter: (_) => setState(() => _hoveredOperatingHourCards.add(dayIndex)),
                        onExit: (_) => setState(() => _hoveredOperatingHourCards.remove(dayIndex)),
                        child: GestureDetector(
                          onTapDown: (details) async {
                            final selected = await showMenu<String>(
                              context: context,
                              position: RelativeRect.fromLTRB(
                                details.globalPosition.dx,
                                details.globalPosition.dy,
                                details.globalPosition.dx,
                                details.globalPosition.dy,
                              ),
                              items: [
                                PopupMenuItem(
                                  value: 'edit',
                                  child: const Text('수정', style: TextStyle(color: Colors.white)),
                                  height: 40,
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: const Text('삭제', style: TextStyle(color: Colors.white)),
                                  height: 40,
                                ),
                              ],
                              color: const Color(0xFF1F1F1F),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            );
                            if (selected == 'edit') {
                              _selectOperatingHours(context, day);
                            } else if (selected == 'delete') {
                              setState(() {
                                _operatingHours[day] = null;
                                _breakTimes[day]?.clear();
                              });
                            }
                          },
                          child: AnimatedContainer(
                            duration: Duration(milliseconds: 150),
                            width: blockWidth,
                            decoration: BoxDecoration(
                              color: const Color(0xFF18181A),
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.white.withOpacity(0.07),
                                  blurRadius: 0,
                                  spreadRadius: 0,
                                  offset: Offset(0, 0),
                                ),
                              ],
                            ),
                            child: Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                  child: Center(
                                    child: Text(
                                      '${_formatTimeOfDay(_operatingHours[day]!.start)} - ${_formatTimeOfDay(_operatingHours[day]!.end)}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      )
                    : Container(
                        width: blockWidth,
                        height: 40,
                        padding: EdgeInsets.zero,
                        decoration: BoxDecoration(
                          color: const Color(0xFF18181A),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Center(
                          child: IconButton(
                            icon: const Icon(Icons.add, color: Color(0xFF1976D2), size: 28),
                            tooltip: '운영시간 등록',
                            onPressed: () => _selectOperatingHours(context, day),
                          ),
                        ),
                      ),
                // 운영시간 카드와 휴식시간 카드 사이 여백
                if ((_breakTimes[day]?.isNotEmpty ?? false) && hasOperatingHours) const SizedBox(height: 10),
                // 휴식시간 카드들
                ...((_breakTimes[day]?.asMap().entries ?? []).map((entry) {
                  final breakIndex = entry.key;
                  final breakTime = entry.value;
                  final breakKey = 'br${dayIndex}_$breakIndex';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: GestureDetector(
                      onTapDown: (details) async {
                        final selected = await showMenu<String>(
                          context: context,
                          position: RelativeRect.fromLTRB(
                            details.globalPosition.dx,
                            details.globalPosition.dy,
                            details.globalPosition.dx,
                            details.globalPosition.dy,
                          ),
                          items: [
                            PopupMenuItem(
                              value: 'edit',
                              child: const Text('수정', style: TextStyle(color: Colors.white)),
                              height: 40,
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: const Text('삭제', style: TextStyle(color: Colors.white)),
                              height: 40,
                            ),
                          ],
                          color: const Color(0xFF1F1F1F),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        );
                        if (selected == 'edit') {
                          // TODO: 휴식시간 수정 다이얼로그 연결
                        } else if (selected == 'delete') {
                          setState(() {
                            _breakTimes[day]?.remove(breakTime);
                          });
                        }
                      },
                      child: AnimatedContainer(
                        duration: Duration(milliseconds: 150),
                        width: blockWidth,
                        decoration: BoxDecoration(
                          color: const Color(0xFF18181A),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Color(0xFF1976D2)),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 5),
                          child: Center(
                            child: Text(
                              '${_formatTimeOfDay(breakTime.start)} - ${_formatTimeOfDay(breakTime.end)}',
                              style: const TextStyle(
                                color: Color(0xFF1976D2),
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList()),
                // +휴식 버튼 (TextButton)
                if (hasOperatingHours)
                  TextButton.icon(
                    icon: const Icon(Icons.add, color: Color(0xFF1976D2), size: 18),
                    label: const Text('휴식', style: TextStyle(color: Color(0xFF1976D2), fontSize: 13)),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF1976D2),
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                    ),
                    onPressed: () => _addBreakTime(day),
                  ),
              ],
            );
          }).toList(),
        ),
      ],
    );
  }

  String _formatTimeOfDay(TimeOfDay time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Future<void> _addBreakTime(DayOfWeek day) async {
    final TimeOfDay? startTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
      builder: (BuildContext context, Widget? child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF1976D2),
              onPrimary: Colors.white,
              surface: Color(0xFF1F1F1F),
              onSurface: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );

    if (startTime != null) {
      final TimeOfDay? endTime = await showTimePicker(
        context: context,
        initialTime: startTime,
        builder: (BuildContext context, Widget? child) {
          return Theme(
            data: Theme.of(context).copyWith(
              colorScheme: const ColorScheme.dark(
                primary: Color(0xFF1976D2),
                onPrimary: Colors.white,
                surface: Color(0xFF1F1F1F),
                onSurface: Colors.white,
              ),
            ),
            child: child!,
          );
        },
      );

      if (endTime != null) {
        setState(() {
          _breakTimes[day] ??= [];
          _breakTimes[day]!.add(TimeRange(start: startTime, end: endTime));
        });
      }
    }
  }

  void _showAddTeacherDialog() {
    final nameController = TextEditingController();
    final contactController = TextEditingController();
    final emailController = TextEditingController();
    final descController = TextEditingController();
    TeacherRole selectedRole = TeacherRole.all;
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF18181A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('선생님 등록', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: '이름',
                    labelStyle: const TextStyle(color: Colors.white70),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFF1976D2)),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<TeacherRole>(
                  value: selectedRole,
                  dropdownColor: const Color(0xFF18181A),
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: '관리 범위',
                    labelStyle: const TextStyle(color: Colors.white70),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFF1976D2)),
                    ),
                  ),
                  items: TeacherRole.values.map((role) => DropdownMenuItem(
                    value: role,
                    child: Text(getTeacherRoleLabel(role), style: const TextStyle(color: Colors.white)),
                  )).toList(),
                  onChanged: (role) {
                    if (role != null) selectedRole = role;
                  },
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: contactController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: '연락처',
                    labelStyle: const TextStyle(color: Colors.white70),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFF1976D2)),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: emailController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: '이메일',
                    labelStyle: const TextStyle(color: Colors.white70),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFF1976D2)),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: descController,
                  style: const TextStyle(color: Colors.white),
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: '설명',
                    labelStyle: const TextStyle(color: Colors.white70),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFF1976D2)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소', style: TextStyle(color: Colors.white70)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
              onPressed: () async {
                setState(() {
                  _teachers.add(Teacher(
                    name: nameController.text.trim(),
                    role: selectedRole,
                    contact: contactController.text.trim(),
                    email: emailController.text.trim(),
                    description: descController.text.trim(),
                  ));
                });
                await _saveTeachers();
                await _loadTeachers();
                await Future.delayed(const Duration(milliseconds: 100));
                Navigator.pop(context);
              },
              child: const Text('등록', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  Widget _buildAcademySettings() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _academyInfoKey.currentContext;
      if (ctx != null) {
        final h = ctx.size?.height ?? 0;
        if (h != _academyInfoHeight) {
          setState(() {
            _academyInfoHeight = h;
          });
        }
      }
    });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 650,
              child: SingleChildScrollView(
                child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 48),
                    Container(
                      width: 650,
                      margin: const EdgeInsets.only(right: 20, left: 20, bottom: 20),
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 28),
                      decoration: BoxDecoration(
                        color: Color(0xFF18181A),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
        const Text(
          '학원 정보',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 24),
        // 학원명 입력
        SizedBox(
          width: 600,
          child: TextFormField(
            controller: _academyNameController,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: '학원명',
              labelStyle: TextStyle(color: Colors.white.withOpacity(0.7)),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
              ),
              focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: Color(0xFF1976D2)),
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        // 슬로건 입력
        SizedBox(
          width: 600,
          child: TextFormField(
            controller: _sloganController,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: '슬로건',
              labelStyle: TextStyle(color: Colors.white.withOpacity(0.7)),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
              ),
              focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: Color(0xFF1976D2)),
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        // 기본 정원과 수업 시간을 나란히 배치
            SizedBox(
                            width: 600,
                            child: Row(
                              children: [
                                Expanded(
              child: TextFormField(
                controller: _capacityController,
                style: const TextStyle(color: Colors.white),
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: '기본 정원',
                  labelStyle: TextStyle(color: Colors.white.withOpacity(0.7)),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                  ),
                  focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFF1976D2)),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 20),
                                Expanded(
              child: TextFormField(
                controller: _lessonDurationController,
                style: const TextStyle(color: Colors.white),
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: '수업 시간 (분)',
                  labelStyle: TextStyle(color: Colors.white.withOpacity(0.7)),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                  ),
                  focusedBorder: const OutlineInputBorder(
                    borderSide: BorderSide(color: Color(0xFF1976D2)),
                  ),
                ),
              ),
            ),
          ],
                            ),
        ),
        const SizedBox(height: 30),
        const Text(
          '지불 방식',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: 290,
          child: DropdownButtonFormField<PaymentType>(
            value: _paymentType,
            decoration: InputDecoration(
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
              ),
              focusedBorder: const OutlineInputBorder(
                borderSide: BorderSide(color: Color(0xFF1976D2)),
              ),
            ),
            dropdownColor: const Color(0xFF1F1F1F),
            style: const TextStyle(color: Colors.white, fontSize: 16),
            items: [
              DropdownMenuItem(
                value: PaymentType.monthly,
                child: Text('월 결제'),
              ),
              DropdownMenuItem(
                value: PaymentType.perClass,
                child: Text('회당 결제'),
              ),
            ],
            onChanged: (PaymentType? value) {
              if (value != null) {
                setState(() {
                  _paymentType = value;
                });
              }
            },
          ),
        ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(width: 24),
            Container(
              width: 900,
              margin: const EdgeInsets.only(top: 48, right: 20, left: 0, bottom: 20),
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 28),
              decoration: BoxDecoration(
                color: Color(0xFF18181A),
                borderRadius: BorderRadius.circular(16),
              ),
              child: _buildOperatingHoursSection(),
            ),
          ],
        ),
        const SizedBox(height: 40),
        // 저장 버튼
        Center(
          child: ElevatedButton(
            onPressed: () async {
              try {
                final academySettings = AcademySettings(
                  name: _academyNameController.text.trim(),
                  slogan: _sloganController.text.trim(),
                  defaultCapacity: int.tryParse(_capacityController.text.trim()) ?? 30,
                  lessonDuration: int.tryParse(_lessonDurationController.text.trim()) ?? 50,
                );
                final paymentTypeStr = _paymentType == PaymentType.monthly ? 'monthly' : 'perClass';
                if (kIsWeb) {
                  await AcademyHiveService.saveAcademySettings(academySettings, paymentTypeStr);
                } else {
                  await AcademyDbService.instance.saveAcademySettings(academySettings, paymentTypeStr);
                }
                await DataManager.instance.savePaymentType(_paymentType);
                await _saveOperatingHours();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('설정이 저장되었습니다.')),
                );
              } catch (e) {
                print('Error saving settings: $e');
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('설정 저장에 실패했습니다.')),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1976D2),
              padding: const EdgeInsets.symmetric(horizontal: 72, vertical: 16),
            ),
            child: const Text(
              '저장',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTeacherSettings() {
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 48),
        child: Container(
          width: 1000,
          height: 450,
          margin: const EdgeInsets.only(right: 0, left: 0, bottom: 20),
          padding: const EdgeInsets.symmetric(horizontal: 28),
          decoration: BoxDecoration(
            color: Color(0xFF18181A),
            borderRadius: BorderRadius.circular(16),
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const SizedBox(height: 28),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('선생님 관리', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w500)),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
                      onPressed: _showAddTeacherDialog,
                      child: const Text('선생님 등록', style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                if (_teachers.isEmpty)
                  const Text('등록된 선생님이 없습니다.', style: TextStyle(color: Colors.white70)),
                if (_teachers.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8, left: 8, right: 8),
                    child: Container(
                      width: 944,
                      child: Row(
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(left: 24),
                            child: SizedBox(
                              width: 80,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text('이름', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 14)),
                              ),
                            ),
                          ),
                          SizedBox(width: 40),
                          SizedBox(width: 60, child: Text('관리', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 14), overflow: TextOverflow.ellipsis)),
                          SizedBox(width: 130, child: Text('연락처', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 14), overflow: TextOverflow.ellipsis)),
                          SizedBox(width: 40),
                          SizedBox(width: 210, child: Text('이메일', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 14), overflow: TextOverflow.ellipsis)),
                          SizedBox(width: 90, child: Text('상세 정보', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 14), overflow: TextOverflow.ellipsis)),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [],
                          ),
                        ],
                      ),
                    ),
                  ),
                if (_teachers.isNotEmpty)
                  SizedBox(
                    height: 320,
                    child: ReorderableListView(
                      buildDefaultDragHandles: false,
                      proxyDecorator: _teacherCardProxyDecorator,
                      onReorder: (oldIndex, newIndex) {
                        setState(() {
                          if (newIndex > oldIndex) newIndex--;
                          final item = _teachers.removeAt(oldIndex);
                          _teachers.insert(newIndex, item);
                        });
                        _saveTeachers();
                      },
                      children: [
                        for (int i = 0; i < _teachers.length; i++)
                          Padding(
                            key: ValueKey('teacher_card_$i'),
                            padding: const EdgeInsets.only(bottom: 16),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF232326),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              width: 944,
                              child: Row(
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(left: 24),
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(_teachers[i].name, style: const TextStyle(color: Colors.white, fontSize: 16), overflow: TextOverflow.ellipsis),
                                    ),
                                  ),
                                  SizedBox(width: 40),
                                  Expanded(flex: 10, child: Text(getTeacherRoleLabel(_teachers[i].role), style: const TextStyle(color: Colors.white70, fontSize: 14), overflow: TextOverflow.ellipsis)),
                                  Expanded(flex: 10, child: Text(_teachers[i].contact, style: const TextStyle(color: Colors.white70, fontSize: 14), overflow: TextOverflow.ellipsis)),
                                  SizedBox(width: 40),
                                  Expanded(flex: 25, child: Text(_teachers[i].email, style: const TextStyle(color: Colors.white70, fontSize: 14), overflow: TextOverflow.ellipsis)),
                                  Expanded(flex: 25, child: Text(_teachers[i].description, style: const TextStyle(color: Colors.white70, fontSize: 14), overflow: TextOverflow.ellipsis, maxLines: 1)),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ReorderableDragStartListener(
                                        index: i,
                                        child: const Padding(
                                          padding: EdgeInsets.symmetric(horizontal: 4),
                                          child: Icon(Icons.drag_handle, color: Colors.white38),
                                        ),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.edit, color: Colors.white70),
                                        onPressed: () {
                                          _showEditTeacherDialog(i);
                                        },
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.delete, color: Colors.white70),
                                        onPressed: () async {
                                          final confirm = await showDialog<bool>(
                                            context: context,
                                            builder: (context) => AlertDialog(
                                              backgroundColor: const Color(0xFF18181A),
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                              title: const Text('삭제 확인', style: TextStyle(color: Colors.white)),
                                              content: const Text('정말로 이 선생님 정보를 삭제하시겠습니까?', style: TextStyle(color: Colors.white70)),
                                              actions: [
                                                TextButton(
                                                  onPressed: () => Navigator.pop(context, false),
                                                  child: const Text('취소', style: TextStyle(color: Colors.white70)),
                                                ),
                                                ElevatedButton(
                                                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
                                                  onPressed: () => Navigator.pop(context, true),
                                                  child: const Text('삭제', style: TextStyle(color: Colors.white)),
                                                ),
                                              ],
                                            ),
                                          );
                                          if (confirm == true) {
                                            setState(() {
                                              _teachers.removeAt(i);
                                            });
                                            _saveTeachers();
                                          }
                                        },
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
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
    return Scaffold(
        backgroundColor: const Color(0xFF1F1F1F),
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(60),
        child: Column(
          children: [
            const SizedBox(height: 10),
            AppBar(
          backgroundColor: const Color(0xFF1F1F1F),
              leadingWidth: 120,
              leading: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: Icon(Icons.arrow_back_ios_new, color: Colors.white70),
                    onPressed: null, // 기능 미구현
                    tooltip: '뒤로가기',
                  ),
                  IconButton(
                    icon: Icon(Icons.arrow_forward_ios, color: Colors.white70),
                    onPressed: null, // 기능 미구현
                    tooltip: '앞으로가기',
                  ),
                  IconButton(
                    icon: Icon(Icons.refresh, color: Colors.white70),
                    onPressed: null, // 기능 미구현
                    tooltip: '새로고침',
                  ),
                ],
              ),
              title: const Text(
              '설정',
              style: TextStyle(
                  color: Colors.white70,
                  fontSize: 28,
            ),
          ),
              centerTitle: true,
              toolbarHeight: 50,
              actions: [
                IconButton(
                  icon: Icon(Icons.apps, color: Colors.white70),
                  onPressed: null, // 기능 미구현
                  tooltip: '더보기',
                ),
                IconButton(
                  icon: Icon(Icons.settings, color: Colors.white70),
                  onPressed: null, // 기능 미구현
                  tooltip: '설정',
                ),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: CircleAvatar(
                    radius: 16,
                    backgroundColor: Colors.grey.shade700,
                    child: Icon(Icons.person, color: Colors.white70, size: 20),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          const SizedBox(height: 5),
          CustomTabBar(
            selectedIndex: _customTabIndex,
            tabs: const ['학원', '선생님', '일반'],
            onTabSelected: (idx) => setState(() => _customTabIndex = idx),
              ),
              Expanded(
            child: IndexedStack(
              index: _customTabIndex,
                  children: [
                    _buildAcademySettings(),
                _buildTeacherSettings(),
                    _buildGeneralSettings(),
                  ],
                ),
              ),
            ],
          ),
    );
  }

  // 드래그 피드백 카드 스타일 함수
  Widget _teacherCardProxyDecorator(Widget child, int index, Animation<double> animation) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF232326),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.15),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        constraints: const BoxConstraints(maxWidth: 944),
        child: child,
      ),
    );
  }

  // 선생님 정보 수정 다이얼로그
  void _showEditTeacherDialog(int index) {
    final teacher = _teachers[index];
    final nameController = TextEditingController(text: teacher.name);
    final contactController = TextEditingController(text: teacher.contact);
    final emailController = TextEditingController(text: teacher.email);
    final descController = TextEditingController(text: teacher.description);
    TeacherRole selectedRole = teacher.role;
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF18181A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('선생님 정보 수정', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: '이름',
                    labelStyle: const TextStyle(color: Colors.white70),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFF1976D2)),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<TeacherRole>(
                  value: selectedRole,
                  dropdownColor: const Color(0xFF18181A),
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: '관리 범위',
                    labelStyle: const TextStyle(color: Colors.white70),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFF1976D2)),
                    ),
                  ),
                  items: TeacherRole.values.map((role) => DropdownMenuItem(
                    value: role,
                    child: Text(getTeacherRoleLabel(role), style: const TextStyle(color: Colors.white)),
                  )).toList(),
                  onChanged: (role) {
                    if (role != null) selectedRole = role;
                  },
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: contactController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: '연락처',
                    labelStyle: const TextStyle(color: Colors.white70),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFF1976D2)),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: emailController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: '이메일',
                    labelStyle: const TextStyle(color: Colors.white70),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFF1976D2)),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: descController,
                  style: const TextStyle(color: Colors.white),
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: '설명',
                    labelStyle: const TextStyle(color: Colors.white70),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFF1976D2)),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소', style: TextStyle(color: Colors.white70)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
              onPressed: () async {
                setState(() {
                  _teachers[index] = Teacher(
                    name: nameController.text.trim(),
                    role: selectedRole,
                    contact: contactController.text.trim(),
                    email: emailController.text.trim(),
                    description: descController.text.trim(),
                  );
                });
                await _saveTeachers();
                await _loadTeachers();
                await Future.delayed(const Duration(milliseconds: 100));
                Navigator.pop(context);
              },
              child: const Text('저장', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  Future<void> _saveTeachers() async {
    if (kIsWeb && _teacherBox != null) {
      final data = _teachers.map((t) => {
        'name': t.name,
        'role': t.role.index,
        'contact': t.contact,
        'email': t.email,
        'description': t.description,
      }).toList();
      await _teacherBox!.put('teachers', data);
      print('Hive save teachers: $data');
      // 저장 후 setState로 반영 (불러오기와 동일하게)
      final saved = _teacherBox!.get('teachers') as List?;
      print('Hive saved teachers after put: $saved');
      if (saved != null) {
        setState(() {
          _teachers = saved.map((row) => Teacher(
            name: row['name'] as String? ?? '',
            role: TeacherRole.values[row['role'] as int? ?? 0],
            contact: row['contact'] as String? ?? '',
            email: row['email'] as String? ?? '',
            description: row['description'] as String? ?? '',
          )).toList();
        });
      }
    } else {
      await AcademyDbService.instance.saveTeachers(_teachers);
    }
  }

  Future<void> _loadTeachers() async {
    if (kIsWeb) {
      try {
        if (_teacherBox == null || !_teacherBox!.isOpen) {
          await Hive.initFlutter();
          _teacherBox = await Hive.openBox('teachers_box');
        }
        final data = _teacherBox!.get('teachers') as List?;
        print('Hive load teachers: $data');
        if (data != null) {
          setState(() {
            _teachers = data.map((row) => Teacher(
              name: row['name'] as String? ?? '',
              role: TeacherRole.values[row['role'] as int? ?? 0],
              contact: row['contact'] as String? ?? '',
              email: row['email'] as String? ?? '',
              description: row['description'] as String? ?? '',
            )).toList();
          });
        }
      } catch (e) {
        print('Error loading teachers from Hive: $e');
      }
    } else {
      final dbList = await AcademyDbService.instance.getTeachers();
      setState(() {
        _teachers = dbList.map((row) => Teacher(
          name: row['name'] as String? ?? '',
          role: TeacherRole.values[row['role'] as int? ?? 0],
          contact: row['contact'] as String? ?? '',
          email: row['email'] as String? ?? '',
          description: row['description'] as String? ?? '',
        )).toList();
      });
    }
  }

  Widget teacherRow({
    required String name,
    required String role,
    required String contact,
    required String email,
    required String desc,
    Widget? dragHandle,
    Widget? editBtn,
    Widget? deleteBtn,
    bool isHeader = false,
  }) {
    final textStyle = isHeader
        ? const TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 16)
        : const TextStyle(color: Colors.white, fontSize: 16);
    final descStyle = isHeader
        ? textStyle
        : const TextStyle(color: Colors.white70, fontSize: 14);
    return Padding(
      padding: const EdgeInsets.only(left: 24, right: 8, bottom: 8),
      child: Row(
        children: [
          Expanded(flex: 2, child: Text(name, style: textStyle, overflow: TextOverflow.ellipsis)),
          Expanded(flex: 2, child: Text(role, style: textStyle, overflow: TextOverflow.ellipsis)),
          Expanded(flex: 3, child: Text(contact, style: textStyle, overflow: TextOverflow.ellipsis)),
          Expanded(flex: 3, child: Text(email, style: textStyle, overflow: TextOverflow.ellipsis)),
          Expanded(flex: 4, child: Text(desc, style: descStyle, overflow: TextOverflow.ellipsis, maxLines: 1)),
          if (dragHandle != null) dragHandle,
          if (editBtn != null) editBtn,
          if (deleteBtn != null) deleteBtn,
          if (dragHandle == null && editBtn == null && deleteBtn == null) SizedBox(width: 60),
        ],
      ),
    );
  }
}

class CustomTabBar extends StatefulWidget {
  final int selectedIndex;
  final List<String> tabs;
  final ValueChanged<int> onTabSelected;
  const CustomTabBar({
    required this.selectedIndex,
    required this.tabs,
    required this.onTabSelected,
    super.key,
  });

  @override
  State<CustomTabBar> createState() => _CustomTabBarState();
}

class _CustomTabBarState extends State<CustomTabBar> {
  final Set<int> _hoveredTabs = {};

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(widget.tabs.length, (i) {
            final isSelected = i == widget.selectedIndex;
            final isHovered = _hoveredTabs.contains(i);
            return MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _hoveredTabs.add(i)),
              onExit: (_) => setState(() => _hoveredTabs.remove(i)),
              child: GestureDetector(
                onTap: () {
                  widget.onTabSelected(i);
                  if (widget.tabs[i] == '선생님') {
                    final state = context.findAncestorStateOfType<_SettingsScreenState>();
                    state?._loadTeachers();
                  }
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  padding: const EdgeInsets.symmetric(horizontal: 23, vertical: 8),
                  decoration: BoxDecoration(
                    color: isHovered && !isSelected
                        ? Colors.white.withOpacity(0.07)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    children: [
                      Text(
                        widget.tabs[i],
                        style: TextStyle(
                          color: isSelected ? Color(0xFF1976D2) : Colors.white70,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        height: 6,
                        width: 60,
                        decoration: BoxDecoration(
                          color: isSelected ? Color(0xFF1976D2) : Colors.transparent,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
} 