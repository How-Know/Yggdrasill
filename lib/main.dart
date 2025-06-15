import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:uuid/uuid.dart';
import 'models/student.dart';
import 'models/class_info.dart';
import 'models/operating_hours.dart';
import 'widgets/student_registration_dialog.dart';
import 'widgets/class_registration_dialog.dart';
import 'widgets/class_student_card.dart';
import 'widgets/student_card.dart';
import 'services/data_manager.dart';
import 'screens/timetable/timetable_screen.dart';
import 'screens/student/student_screen.dart';
import 'models/academy_settings.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Yggdrasill',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF1F1F1F),
        navigationRailTheme: const NavigationRailThemeData(
          backgroundColor: Color(0xFF1F1F1F),
          selectedIconTheme: IconThemeData(color: Colors.white, size: 30),
          unselectedIconTheme: IconThemeData(color: Colors.white70, size: 30),
          minWidth: 84,
          indicatorColor: Color(0xFF0F467D),
          groupAlignment: -1,
          useIndicator: true,
        ),
        tooltipTheme: TooltipThemeData(
          decoration: BoxDecoration(
            color: Color(0xFF1F1F1F),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.white24),
          ),
          textStyle: TextStyle(color: Colors.white),
        ),
      ),
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with SingleTickerProviderStateMixin {
  int _selectedIndex = 0;
  bool _isSideSheetOpen = false;
  late AnimationController _animationController;
  late Animation<double> _rotationAnimation;
  late Animation<double> _sideSheetAnimation;
  
  // FAB 확장 상태 추가
  bool _isFabExtended = false;

  StudentViewType _viewType = StudentViewType.all;
  final List<ClassInfo> _classes = [];
  final List<Student> _students = [];
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  final Set<ClassInfo> _expandedClasses = {};

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _rotationAnimation = Tween<double>(
      begin: 0,
      end: 0.35,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));
    _sideSheetAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));
    _initializeData();
  }

  Future<void> _initializeData() async {
    await DataManager.instance.initialize();
    setState(() {
      _classes.clear();
      _classes.addAll(DataManager.instance.classes);
      _students.clear();
      _students.addAll(DataManager.instance.students);
    });
  }

  @override
  void dispose() {
    _animationController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _toggleSideSheet() {
    setState(() {
      _isSideSheetOpen = !_isSideSheetOpen;
      if (_isSideSheetOpen) {
        _animationController.forward();
      } else {
        _animationController.reverse();
      }
    });
  }

  Widget _buildContent() {
    if (_selectedIndex == 4) {
      return const SettingsScreen();
    } else if (_selectedIndex == 1) {
      return const StudentScreen();
    } else if (_selectedIndex == 2) {
      return TimetableScreen();
    } else {
      return const Center(
        child: Text(
          '새로운 시작',
          style: TextStyle(color: Colors.white),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            backgroundColor: const Color(0xFF1F1F1F),
            selectedIndex: _selectedIndex,
            onDestinationSelected: (int index) {
              setState(() {
                _selectedIndex = index;
              });
            },
            leading: Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 8),
              child: IconButton(
                icon: AnimatedBuilder(
                  animation: _rotationAnimation,
                  builder: (context, child) => Transform.rotate(
                    angle: _rotationAnimation.value,
                    child: child,
                  ),
                  child: const Icon(
                    Symbols.package_2,
                    color: Colors.white,
                    size: 36,
                  ),
                ),
                onPressed: _toggleSideSheet,
              ),
            ),
            useIndicator: true,
            indicatorShape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            destinations: const [
              NavigationRailDestination(
                padding: EdgeInsets.symmetric(vertical: 10),
                icon: Tooltip(
                  message: '홈',
                  child: Icon(Symbols.home_rounded),
                ),
                selectedIcon: Tooltip(
                  message: '홈',
                  child: Icon(Symbols.home_rounded, weight: 700),
                ),
                label: Text(''),
              ),
              NavigationRailDestination(
                padding: EdgeInsets.symmetric(vertical: 10),
                icon: Tooltip(
                  message: '학생',
                  child: Icon(Symbols.person_rounded),
                ),
                selectedIcon: Tooltip(
                  message: '학생',
                  child: Icon(Symbols.person_rounded, weight: 700),
                ),
                label: Text(''),
              ),
              NavigationRailDestination(
                padding: EdgeInsets.symmetric(vertical: 10),
                icon: Tooltip(
                  message: '시간',
                  child: Icon(Symbols.timer_rounded),
                ),
                selectedIcon: Tooltip(
                  message: '시간',
                  child: Icon(Symbols.timer_rounded, weight: 700),
                ),
                label: Text(''),
              ),
              NavigationRailDestination(
                padding: EdgeInsets.symmetric(vertical: 10),
                icon: Tooltip(
                  message: '학습',
                  child: Icon(Symbols.school_rounded),
                ),
                selectedIcon: Tooltip(
                  message: '학습',
                  child: Icon(Symbols.school_rounded, weight: 700),
                ),
                label: Text(''),
              ),
              NavigationRailDestination(
                padding: EdgeInsets.symmetric(vertical: 10),
                icon: Tooltip(
                  message: '설정',
                  child: Icon(Symbols.settings_rounded),
                ),
                selectedIcon: Tooltip(
                  message: '설정',
                  child: Icon(Symbols.settings_rounded, weight: 700),
                ),
                label: Text(''),
              ),
            ],
          ),
          Container(
            width: 1,
            color: const Color(0xFF2A2A2A),
          ),
          AnimatedBuilder(
            animation: _sideSheetAnimation,
            builder: (context, child) => ClipRect(
              child: SizedBox(
                width: 300 * _sideSheetAnimation.value,
                child: Container(
                  color: const Color(0xFF2A2A2A),
                  child: const Center(
                    child: Text(
                      'Side Sheet Content',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Container(
            width: 1,
            color: const Color(0xFF2A2A2A),
          ),
          Expanded(
            child: _buildContent(),
          ),
        ],
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 16.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (_isFabExtended) ...[
              FloatingActionButton.extended(
                heroTag: 'registration',
                backgroundColor: const Color(0xFF42A5F5),
                foregroundColor: Colors.white,
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (context) => StudentRegistrationDialog(
                      onSave: (student) async {
                        await DataManager.instance.addStudent(student);
                        setState(() {
                          _initializeData();
                        });
                      },
                      classes: DataManager.instance.classes,
                    ),
                  );
                },
                label: const Text('수강 등록'),
                icon: const Icon(Icons.person_add),
              ),
              const SizedBox(height: 8),
              FloatingActionButton.extended(
                heroTag: 'makeup',
                backgroundColor: const Color(0xFF42A5F5),
                foregroundColor: Colors.white,
                onPressed: () {
                  // TODO: 보강 기능 구현
                },
                label: const Text('보강'),
                icon: const Icon(Icons.event_repeat),
              ),
              const SizedBox(height: 8),
              FloatingActionButton.extended(
                heroTag: 'consultation',
                backgroundColor: const Color(0xFF42A5F5),
                foregroundColor: Colors.white,
                onPressed: () {
                  // TODO: 상담 기능 구현
                },
                label: const Text('상담'),
                icon: const Icon(Icons.chat),
              ),
              const SizedBox(height: 8),
            ],
            FloatingActionButton(
              backgroundColor: const Color(0xFF42A5F5),
              foregroundColor: Colors.white,
              onPressed: () {
                setState(() {
                  _isFabExtended = !_isFabExtended;
                });
              },
              child: Icon(_isFabExtended ? Icons.close : Icons.add),
            ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  SettingType _selectedType = SettingType.academy;
  
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

  @override
  void initState() {
    super.initState();
    _loadSettings();
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
      setState(() {
        _academyNameController.text = DataManager.instance.academySettings.name;
        _sloganController.text = DataManager.instance.academySettings.slogan;
        _capacityController.text = DataManager.instance.academySettings.defaultCapacity.toString();
        _lessonDurationController.text = DataManager.instance.academySettings.lessonDuration.toString();
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 40),
        // 테마 설정
        const Text(
          '테마',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 20),
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
      ],
    );
  }

  Widget _buildAcademySettings() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 40),
        // 학원명 입력
        SizedBox(
          width: 300,
          child: TextField(
            controller: _academyNameController,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: '학원명',
              labelStyle: const TextStyle(color: Colors.white70),
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
          child: TextField(
            controller: _sloganController,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: '슬로건',
              labelStyle: const TextStyle(color: Colors.white70),
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
        // 수업 정원과 수업 시간을 나란히 배치
        Row(
          children: [
            // 수업 정원
            SizedBox(
              width: 140,
              child: TextField(
                controller: _capacityController,
                style: const TextStyle(color: Colors.white),
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: '수업 정원',
                  labelStyle: const TextStyle(color: Colors.white70),
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
            // 수업 시간
            SizedBox(
              width: 140,
              child: TextField(
                controller: _lessonDurationController,
                style: const TextStyle(color: Colors.white),
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: '수업 시간 (분)',
                  labelStyle: const TextStyle(color: Colors.white70),
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
        const SizedBox(height: 30),
        // 운영 시간
        SizedBox(
          width: 600,  // 슬로건 입력 필드와 같은 너비
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '운영 시간',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                ),
              ),
              TextButton.icon(
                onPressed: () async {
                  final DayOfWeek? selectedDay = await showDialog<DayOfWeek>(
                    context: context,
                    builder: (BuildContext context) {
                      return AlertDialog(
                        backgroundColor: const Color(0xFF1F1F1F),
                        title: const Text(
                          'Break Time 추가',
                          style: TextStyle(color: Colors.white),
                        ),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: DayOfWeek.values.map((day) => 
                            ListTile(
                              title: Text(
                                day.koreanName,
                                style: const TextStyle(color: Colors.white),
                              ),
                              onTap: () => Navigator.of(context).pop(day),
                            ),
                          ).toList(),
                        ),
                      );
                    },
                  );
                  if (selectedDay != null) {
                    await _selectOperatingHours(context, selectedDay);
                  }
                },
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF1976D2),
                ),
                icon: const Icon(Icons.add, size: 24),
                label: const Text(
                  'Break Time',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        ...DayOfWeek.values.map((day) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 100,
                child: Text(
                  day.koreanName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => _selectOperatingHours(context, day),
                child: Text(
                  _operatingHours[day] != null
                      ? '${_operatingHours[day]!.start.format(context)} - ${_operatingHours[day]!.end.format(context)}'
                      : '시간 선택',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                  ),
                ),
              ),
              if (_operatingHours[day] != null) ...[
                const SizedBox(width: 5),
                IconButton(
                  onPressed: () {
                    setState(() {
                      _operatingHours[day] = null;
                      _breakTimes[day]?.clear();
                    });
                  },
                  icon: const Icon(
                    Icons.close,
                    color: Colors.white54,
                    size: 20,
                  ),
                ),
              ],
            ],
          ),
        )).toList(),
        const SizedBox(height: 30),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1F1F1F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F1F1F),
        title: const Text(
          '설정',
          style: TextStyle(
            color: Colors.white,
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(24.0, 8.0, 24.0, 24.0),  // 상단 여백 8 추가
        child: Column(
          children: [
            Center(
              child: SegmentedButton<SettingType>(
                segments: const [
                  ButtonSegment<SettingType>(
                    value: SettingType.academy,
                    label: Text('학원'),
                  ),
                  ButtonSegment<SettingType>(
                    value: SettingType.general,
                    label: Text('일반'),
                  ),
                ],
                selected: {_selectedType},
                onSelectionChanged: (Set<SettingType> newSelection) {
                  setState(() {
                    _selectedType = newSelection.first;
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
            Expanded(
              child: SingleChildScrollView(
                child: _selectedType == SettingType.academy
                    ? _buildAcademySettings()
                    : _buildGeneralSettings(),
              ),
            ),
            const SizedBox(height: 40),
            // 저장 버튼
            Center(
              child: ElevatedButton(
                onPressed: () async {
                  try {
                    // 1. 학원 기본 정보 저장
                    final academySettings = AcademySettings(
                      name: _academyNameController.text.trim(),
                      slogan: _sloganController.text.trim(),
                      defaultCapacity: int.tryParse(_capacityController.text.trim()) ?? 30,
                      lessonDuration: int.tryParse(_lessonDurationController.text.trim()) ?? 50,
                    );
                    await DataManager.instance.saveAcademySettings(academySettings);

                    // 2. 운영 시간 및 Break Time 저장
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
                  minimumSize: const Size(200, 50),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text(
                  '저장',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class StudentScreen extends StatefulWidget {
  const StudentScreen({super.key});

  @override
  State<StudentScreen> createState() => _StudentScreenState();
}

class _StudentScreenState extends State<StudentScreen> with SingleTickerProviderStateMixin {
  StudentViewType _viewType = StudentViewType.all;
  final List<ClassInfo> _classes = [];
  final List<Student> _students = [];
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  final Set<ClassInfo> _expandedClasses = {};

  @override
  void initState() {
    super.initState();
    _initializeData();
  }

  Future<void> _initializeData() async {
    await DataManager.instance.initialize();
    setState(() {
      _classes.clear();
      _classes.addAll(DataManager.instance.classes);
      _students.clear();
      _students.addAll(DataManager.instance.students);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _addStudent(Student student) {
    setState(() {
      _students.add(student);
      DataManager.instance.addStudent(student);
    });
  }

  void _updateStudent(Student student, int index) {
    setState(() {
      _students[index] = student;
      DataManager.instance.updateStudent(student);
    });
  }

  void _deleteStudent(Student student) {
    setState(() {
      _students.remove(student);
      DataManager.instance.deleteStudent(student.id);
    });
  }

  void _addClass(ClassInfo classInfo) {
    setState(() {
      _classes.add(classInfo);
      DataManager.instance.addClass(classInfo);
    });
  }

  void _updateClass(ClassInfo classInfo, int index) {
    setState(() {
      _classes[index] = classInfo;
      DataManager.instance.updateClass(classInfo);
    });
  }

  void deleteClass(ClassInfo classInfo) {
    DataManager.instance.deleteClass(classInfo);
  }

  void moveStudent(Student student, ClassInfo? newClass) {
    DataManager.instance.updateStudentClass(student, newClass);
  }

  List<Student> get filteredStudents {
    if (_searchQuery.isEmpty) return _students;
    return _students.where((student) =>
      student.name.toLowerCase().contains(_searchQuery.toLowerCase())
    ).toList();
  }

  Widget _buildContent() {
    if (_viewType == StudentViewType.byClass) {
      return _buildClassView();
    } else if (_viewType == StudentViewType.bySchool) {
      return _buildSchoolView();
    } else if (_viewType == StudentViewType.byDate) {
      return _buildDateView();
    } else {
      return _buildAllStudentsView();
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
              '학생',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 30),
          Row(
            children: [
              // Left Section
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SizedBox(
                    width: 120,
                    child: FilledButton.icon(
                      onPressed: () {
                        if (_viewType == StudentViewType.byClass) {
                          _showClassRegistrationDialog(
                            editMode: false,
                            classInfo: null,
                            index: -1,
                          );
                        } else {
                          showDialog(
                            context: context,
                            builder: (context) => StudentRegistrationDialog(
                              onSave: (student) async {
                                await DataManager.instance.addStudent(student);
                                setState(() {
                                  _initializeData();
                                });
                              },
                              classes: DataManager.instance.classes,
                            ),
                          );
                        }
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF1976D2),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                      icon: const Icon(Icons.add, size: 24),
                      label: const Text(
                        '등록',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Center Section - Segmented Button
              Expanded(
                flex: 2,
                child: Center(
                  child: SizedBox(
                    width: 500,
                    child: SegmentedButton<StudentViewType>(
                      segments: const [
                        ButtonSegment<StudentViewType>(
                          value: StudentViewType.all,
                          label: Text('모든 학생'),
                        ),
                        ButtonSegment<StudentViewType>(
                          value: StudentViewType.byClass,
                          label: Text('클래스'),
                        ),
                        ButtonSegment<StudentViewType>(
                          value: StudentViewType.bySchool,
                          label: Text('학교별'),
                        ),
                        ButtonSegment<StudentViewType>(
                          value: StudentViewType.byDate,
                          label: Text('수강 일자'),
                        ),
                      ],
                      selected: {_viewType},
                      onSelectionChanged: (Set<StudentViewType> newSelection) {
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
              // Right Section
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: SizedBox(
                    width: 240,
                    child: SearchBar(
                      controller: _searchController,
                      onChanged: (value) {
                        setState(() {
                          _searchQuery = value;
                        });
                      },
                      hintText: '학생 검색',
                      leading: const Icon(
                        Icons.search,
                        color: Colors.white70,
                      ),
                      backgroundColor: MaterialStateColor.resolveWith(
                        (states) => const Color(0xFF2A2A2A),
                      ),
                      elevation: MaterialStateProperty.all(0),
                      padding: const MaterialStatePropertyAll<EdgeInsets>(
                        EdgeInsets.symmetric(horizontal: 16.0),
                      ),
                      textStyle: const MaterialStatePropertyAll<TextStyle>(
                        TextStyle(color: Colors.white),
                      ),
                      hintStyle: MaterialStatePropertyAll<TextStyle>(
                        TextStyle(color: Colors.white.withOpacity(0.5)),
                      ),
                      side: MaterialStatePropertyAll<BorderSide>(
                        BorderSide(color: Colors.white.withOpacity(0.2)),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          Expanded(
            child: SingleChildScrollView(
              child: _buildContent(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClassView() {
    return Padding(
      padding: const EdgeInsets.only(top: 24.0),
      child: ReorderableListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        padding: EdgeInsets.zero,
        proxyDecorator: (child, index, animation) {
          return AnimatedBuilder(
            animation: animation,
            builder: (BuildContext context, Widget? child) {
              return Material(
                color: Colors.transparent,
                child: child,
              );
            },
            child: child,
          );
        },
        itemCount: _classes.length,
        itemBuilder: (context, index) {
          final classInfo = _classes[index];
          final studentsInClass = _students.where((s) => s.classInfo == classInfo).toList();
          final isExpanded = _expandedClasses.contains(classInfo);
          
          return Padding(
            key: ValueKey(classInfo),
            padding: const EdgeInsets.only(bottom: 16),
            child: DragTarget<Student>(
              onWillAccept: (student) => student != null,
              onAccept: (student) {
                final oldClassInfo = student.classInfo;
                setState(() {
                  final index = _students.indexOf(student);
                  if (index != -1) {
                    _students[index] = student.copyWith(classInfo: classInfo);
                  }
                });
                
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      '${student.name}님이 ${oldClassInfo?.name ?? '미배정'} → ${classInfo.name}으로 이동되었습니다.',
                    ),
                    backgroundColor: const Color(0xFF2A2A2A),
                    behavior: SnackBarBehavior.floating,
                    action: SnackBarAction(
                      label: '실행 취소',
                      onPressed: () {
                        setState(() {
                          final index = _students.indexOf(student);
                          if (index != -1) {
                            _students[index] = student.copyWith(classInfo: oldClassInfo);
                          }
                        });
                      },
                    ),
                  ),
                );
              },
              builder: (context, candidateData, rejectedData) {
                return Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF121212),
                    borderRadius: BorderRadius.circular(12),
                    border: candidateData.isNotEmpty
                      ? Border.all(
                          color: classInfo.color,
                          width: 2,
                        )
                      : null,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Material(
                        color: Colors.transparent,
                        borderRadius: candidateData.isNotEmpty
                          ? const BorderRadius.vertical(
                              top: Radius.circular(10),
                              bottom: Radius.zero,
                            )
                          : BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: candidateData.isNotEmpty
                            ? const BorderRadius.vertical(
                                top: Radius.circular(10),
                                bottom: Radius.zero,
                              )
                            : BorderRadius.circular(12),
                          onTap: () {
                            setState(() {
                              if (isExpanded) {
                                _expandedClasses.remove(classInfo);
                              } else {
                                _expandedClasses.add(classInfo);
                              }
                            });
                          },
                          child: Container(
                            height: 88,
                            decoration: BoxDecoration(
                              color: const Color(0xFF121212),
                              borderRadius: candidateData.isNotEmpty
                                ? const BorderRadius.vertical(
                                    top: Radius.circular(10),
                                    bottom: Radius.zero,
                                  )
                                : BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                const SizedBox(width: 24),
                                Container(
                                  width: 12,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: classInfo.color,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                                const SizedBox(width: 24),
                                Expanded(
                                  child: Row(
                                    children: [
                                      Text(
                                        classInfo.name,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 22,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      if (classInfo.description.isNotEmpty) ...[
                                        const SizedBox(width: 16),
                                        Expanded(
                                          child: Text(
                                            classInfo.description,
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 18,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 20),
                                Text(
                                  '${studentsInClass.length}/${classInfo.capacity}명',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                AnimatedRotation(
                                  duration: const Duration(milliseconds: 200),
                                  turns: isExpanded ? 0.5 : 0,
                                  child: const Icon(
                                    Icons.expand_more,
                                    color: Colors.white70,
                                    size: 24,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      onPressed: () {
                                        _showClassRegistrationDialog(
                                          editMode: true,
                                          classInfo: classInfo,
                                          index: index,
                                        );
                                      },
                                      icon: const Icon(Icons.edit_rounded),
                                      style: IconButton.styleFrom(
                                        foregroundColor: Colors.white70,
                                      ),
                                    ),
                                    IconButton(
                                      onPressed: () {
                                        showDialog(
                                          context: context,
                                          builder: (BuildContext context) {
                                            return AlertDialog(
                                              backgroundColor: const Color(0xFF1F1F1F),
                                              title: Text(
                                                '${classInfo.name} 삭제',
                                                style: const TextStyle(color: Colors.white),
                                              ),
                                              content: const Text(
                                                '정말로 이 클래스를 삭제하시겠습니까?',
                                                style: TextStyle(color: Colors.white),
                                              ),
                                              actions: [
                                                TextButton(
                                                  onPressed: () {
                                                    Navigator.of(context).pop();
                                                  },
                                                  child: const Text(
                                                    '취소',
                                                    style: TextStyle(color: Colors.white70),
                                                  ),
                                                ),
                                                TextButton(
                                                  onPressed: () {
                                                    setState(() {
                                                      _classes.removeAt(index);
                                                      deleteClass(classInfo);
                                                    });
                                                    Navigator.of(context).pop();
                                                  },
                                                  child: const Text(
                                                    '삭제',
                                                    style: TextStyle(
                                                      color: Colors.red,
                                                      fontWeight: FontWeight.bold,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            );
                                          },
                                        );
                                      },
                                      icon: const Icon(Icons.delete_rounded),
                                      style: IconButton.styleFrom(
                                        foregroundColor: Colors.white70,
                                      ),
                                    ),
                                    ReorderableDragStartListener(
                                      index: index,
                                      child: IconButton(
                                        onPressed: () {},
                                        icon: const Icon(Icons.drag_handle_rounded),
                                        style: IconButton.styleFrom(
                                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          minimumSize: const Size(40, 40),
                                          padding: EdgeInsets.zero,
                                          foregroundColor: Colors.white70,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(width: 8),
                              ],
                            ),
                          ),
                        ),
                      ),
                      AnimatedCrossFade(
                        firstChild: const SizedBox.shrink(),
                        secondChild: studentsInClass.isNotEmpty
                          ? Container(
                              decoration: BoxDecoration(
                                color: const Color(0xFF121212),
                                borderRadius: candidateData.isNotEmpty
                                  ? const BorderRadius.vertical(
                                      top: Radius.zero,
                                      bottom: Radius.circular(10),
                                    )
                                  : BorderRadius.circular(12),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(30, 16, 24, 16),
                                child: Wrap(
                                  spacing: 16,
                                  runSpacing: 16,
                                  children: studentsInClass.map((student) => ClassStudentCard(
                                    student: student,
                                    onShowDetails: (student) => _showStudentDetails(student),
                                  )).toList(),
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
                        crossFadeState: isExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                        duration: const Duration(milliseconds: 200),
                      ),
                    ],
                  ),
                );
              },
            ),
          );
        },
        onReorder: (oldIndex, newIndex) {
          setState(() {
            if (newIndex > oldIndex) {
              newIndex -= 1;
            }
            final ClassInfo item = _classes.removeAt(oldIndex);
            _classes.insert(newIndex, item);
          });
        },
      ),
    );
  }

  Widget _buildSchoolView() {
    // 교육과정별, 학교별로 학생들을 그룹화
    final Map<EducationLevel, Map<String, List<Student>>> groupedStudents = {
      EducationLevel.elementary: <String, List<Student>>{},
      EducationLevel.middle: <String, List<Student>>{},
      EducationLevel.high: <String, List<Student>>{},
    };

    for (final student in filteredStudents) {
      final level = student.educationLevel;
      final school = student.school;
      if (groupedStudents[level]![school] == null) {
        groupedStudents[level]![school] = [];
      }
      groupedStudents[level]![school]!.add(student);
    }

    // 각 교육과정 내에서 학교를 가나다순으로 정렬하고,
    // 각 학교 내에서 학생들을 이름순으로 정렬
    for (final level in groupedStudents.keys) {
      final schoolMap = groupedStudents[level]!;
      for (final students in schoolMap.values) {
        students.sort((a, b) => a.name.compareTo(b.name));
      }
    }

    return SingleChildScrollView(
      child: Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(30.0, 24.0, 30.0, 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildEducationLevelSchoolGroup('초등', EducationLevel.elementary, groupedStudents),
              if (groupedStudents[EducationLevel.elementary]!.isNotEmpty &&
                  (groupedStudents[EducationLevel.middle]!.isNotEmpty ||
                   groupedStudents[EducationLevel.high]!.isNotEmpty))
                const Divider(color: Colors.white24, height: 48),
              _buildEducationLevelSchoolGroup('중등', EducationLevel.middle, groupedStudents),
              if (groupedStudents[EducationLevel.middle]!.isNotEmpty &&
                  groupedStudents[EducationLevel.high]!.isNotEmpty)
                const Divider(color: Colors.white24, height: 48),
              _buildEducationLevelSchoolGroup('고등', EducationLevel.high, groupedStudents),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEducationLevelSchoolGroup(
    String levelTitle,
    EducationLevel level,
    Map<EducationLevel, Map<String, List<Student>>> groupedStudents,
  ) {
    final schoolMap = groupedStudents[level]!;
    if (schoolMap.isEmpty) return const SizedBox.shrink();

    // 학교들을 가나다순으로 정렬
    final sortedSchools = schoolMap.keys.toList()..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 16.0),
          child: Text(
            levelTitle,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ),
        for (final school in sortedSchools) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 12.0),
            child: Text(
              school,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: Colors.white70,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 24.0),
            child: Wrap(
              alignment: WrapAlignment.start,
              spacing: 16.0,
              runSpacing: 16.0,
              children: [
                for (final student in schoolMap[school]!)
                  StudentCard(
                    student: student,
                    onShowDetails: (student) => _showStudentDetails(student),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _showDeleteConfirmationDialog(Student student) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1F1F1F),
        title: const Text(
          '학생 삭제',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          '정말 이 학생을 삭제하시겠습니까?',
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(
              '취소',
              style: TextStyle(color: Colors.white70),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: const Text('삭제'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() {
        _students.remove(student);
      });
    }
  }

  Widget _buildDateView() {
    // 임시로 빈 컨테이너 반환
    return Container();
  }

  Widget _buildAllStudentsView() {
    final Map<EducationLevel, Map<int, List<Student>>> groupedStudents = {
      EducationLevel.elementary: {},
      EducationLevel.middle: {},
      EducationLevel.high: {},
    };

    for (final student in filteredStudents) {
      groupedStudents[student.educationLevel]![student.grade] ??= [];
      groupedStudents[student.educationLevel]![student.grade]!.add(student);
    }

    // 각 교육과정 내에서 학년별로 학생들을 정렬
    for (final level in groupedStudents.keys) {
      for (final gradeStudents in groupedStudents[level]!.values) {
        gradeStudents.sort((a, b) => a.name.compareTo(b.name));
      }
    }

    return Padding(
      padding: const EdgeInsets.only(top: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildEducationLevelGroup('초등', EducationLevel.elementary, groupedStudents),
          const Divider(color: Colors.white24, height: 48),
          _buildEducationLevelGroup('중등', EducationLevel.middle, groupedStudents),
          const Divider(color: Colors.white24, height: 48),
          _buildEducationLevelGroup('고등', EducationLevel.high, groupedStudents),
        ],
      ),
    );
  }

  Widget _buildEducationLevelGroup(
    String title,
    EducationLevel level,
    Map<EducationLevel, Map<int, List<Student>>> groupedStudents,
  ) {
    final students = groupedStudents[level]!;
    final totalCount = students.values.fold<int>(0, (sum, list) => sum + list.length);

    final List<Widget> gradeWidgets = students.entries
        .where((entry) => entry.value.isNotEmpty)
        .map<Widget>((entry) {
          final gradeStudents = entry.value;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 16, bottom: 8),
                child: Text(
                  '${entry.key}학년',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Wrap(
                spacing: 16,
                runSpacing: 16,
                children: gradeStudents.map((student) => StudentCard(
                  student: student,
                  onShowDetails: (student) => _showStudentDetails(student),
                )).toList(),
              ),
            ],
          );
        })
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '$totalCount명',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 20,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ...gradeWidgets,
      ],
    );
  }

  void _showStudentDetails(Student student) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: Text(
          student.name,
          style: const TextStyle(color: Colors.white),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '학교: ${student.school}',
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 8),
            Text(
              '과정: ${getEducationLevelName(student.educationLevel)}',
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 8),
            Text(
              '학년: ${student.grade}학년',
              style: const TextStyle(color: Colors.white70),
            ),
            if (student.classInfo != null) ...[
              const SizedBox(height: 8),
              Text(
                '클래스: ${student.classInfo!.name}',
                style: TextStyle(color: student.classInfo!.color),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  void _showClassRegistrationDialog({
    bool editMode = false,
    ClassInfo? classInfo,
    int? index,
  }) async {
    final result = await showDialog<ClassInfo>(
      context: context,
      builder: (context) => ClassRegistrationDialog(
        editMode: editMode,
        classInfo: classInfo,
        index: index,
      ),
    );

    if (result != null) {
      setState(() {
        if (editMode && index != null) {
          // 수정된 클래스 정보로 업데이트
          _classes[index] = result;
          DataManager.instance.updateClass(result);
          
          // 해당 클래스에 소속된 학생들의 클래스 정보도 업데이트
          for (var i = 0; i < _students.length; i++) {
            if (_students[i].classInfo?.id == result.id) {
              _students[i] = _students[i].copyWith(classInfo: result);
            }
          }
        } else {
          _classes.add(result);
          DataManager.instance.addClass(result);
        }
      });
    }
  }

  void _showSettingsDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => const SettingsScreen(),
    );
    if (result == true) {
      setState(() {
        // 설정이 변경되었을 때의 처리
      });
    }
  }
}

enum StudentViewType {
  all,
  byClass,
  bySchool,
  byDate,
}

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

String getEducationLevelName(EducationLevel level) {
  switch (level) {
    case EducationLevel.elementary:
      return '초등';
    case EducationLevel.middle:
      return '중등';
    case EducationLevel.high:
      return '고등';
  }
}

class TimeRange {
  final TimeOfDay start;
  final TimeOfDay end;

  const TimeRange({required this.start, required this.end});
}

 