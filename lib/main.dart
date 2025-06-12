import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:uuid/uuid.dart';
import 'models/student.dart';
import 'models/class_info.dart';
import 'widgets/student_registration_dialog.dart';
import 'widgets/class_registration_dialog.dart';
import 'widgets/class_student_card.dart';

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
  
  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
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
  }

  @override
  void dispose() {
    _animationController.dispose();
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
  PaymentType _paymentType = PaymentType.monthly;
  final Map<DayOfWeek, OperatingHours?> _operatingHours = {
    DayOfWeek.monday: null,
    DayOfWeek.tuesday: null,
    DayOfWeek.wednesday: null,
    DayOfWeek.thursday: null,
    DayOfWeek.friday: null,
    DayOfWeek.saturday: null,
    DayOfWeek.sunday: null,
  };
  
  // Break time을 저장하는 맵 추가
  final Map<DayOfWeek, List<TimeBlock>> _breakTimes = {
    DayOfWeek.monday: [],
    DayOfWeek.tuesday: [],
    DayOfWeek.wednesday: [],
    DayOfWeek.thursday: [],
    DayOfWeek.friday: [],
    DayOfWeek.saturday: [],
    DayOfWeek.sunday: [],
  };

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
          _operatingHours[day] = OperatingHours(startTime, endTime);
        });
      }
    }
  }

  Future<void> _addBreakTime(BuildContext context, DayOfWeek day) async {
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
          _breakTimes[day]!.add(TimeBlock(startTime, endTime));
        });
      }
    }
  }

  void _removeBreakTime(DayOfWeek day, int index) {
    setState(() {
      _breakTimes[day]!.removeAt(index);
    });
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
                  return const Color(0xFF1CB1F5).withOpacity(0.4);
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
        const SizedBox(height: 40),
        // 저장 버튼
        Center(
          child: ElevatedButton(
            onPressed: () {
              // TODO: 저장 기능 구현
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
                    await _addBreakTime(context, selectedDay);
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
              const SizedBox(width: 20),
              if (_breakTimes[day]!.isNotEmpty)
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: _breakTimes[day]!.asMap().entries.map((entry) =>
                        Padding(
                          padding: const EdgeInsets.only(right: 8.0),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1976D2).withOpacity(0.1),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '${entry.value.start.format(context)} - ${entry.value.end.format(context)}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                InkWell(
                                  onTap: () => _removeBreakTime(day, entry.key),
                                  child: const Icon(
                                    Icons.close,
                                    color: Colors.white,
                                    size: 20,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ).toList(),
                    ),
                  ),
                ),
            ],
          ),
        )).toList(),
        const SizedBox(height: 30),
        // 지불 방법
        const Text(
          '지불 방법',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 20),
        SegmentedButton<PaymentType>(
          segments: const [
            ButtonSegment<PaymentType>(
              value: PaymentType.monthly,
              label: Text('매달'),
            ),
            ButtonSegment<PaymentType>(
              value: PaymentType.perClass,
              label: Text('횟수'),
            ),
          ],
          selected: {_paymentType},
          onSelectionChanged: (Set<PaymentType> newSelection) {
            setState(() {
              _paymentType = newSelection.first;
            });
          },
          style: ButtonStyle(
            backgroundColor: MaterialStateProperty.resolveWith<Color>(
              (Set<MaterialState> states) {
                if (states.contains(MaterialState.selected)) {
                  return const Color(0xFF1CB1F5).withOpacity(0.4);
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
        // 저장 버튼
        Center(
          child: ElevatedButton(
            onPressed: () {
              // TODO: 저장 기능 구현
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
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        children: [
          const Center(
            child: Text(
              '설정',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 30),
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
                      return const Color(0xFF1CB1F5).withOpacity(0.4);
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
        ],
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
  StudentViewType _selectedView = StudentViewType.all;
  final List<ClassInfo> _classes = [];
  final List<Student> _students = [];
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  final Set<ClassInfo> _expandedClasses = {};

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _addStudent(Student student) {
    setState(() {
      _students.add(student);
    });
  }

  void _updateStudent(Student student, int index) {
    setState(() {
      _students[index] = student;
    });
  }

  void _deleteStudent(Student student) {
    setState(() {
      _students.remove(student);
    });
  }

  void _addClass(ClassInfo classInfo) {
    setState(() {
      _classes.add(classInfo);
    });
  }

  void _updateClass(ClassInfo classInfo, int index) {
    setState(() {
      _classes[index] = classInfo;
    });
  }

  void _deleteClass(String classId) {
    setState(() {
      _classes.removeWhere((c) => c.id == classId);
      for (var student in _students) {
        if (student.classInfo?.id == classId) {
          student.classInfo = null;
        }
      }
    });
  }

  void _moveStudent(Student student, ClassInfo? newClass) {
    setState(() {
      final index = _students.indexOf(student);
      if (index != -1) {
        _students[index] = student.copyWith(classInfo: newClass);
      }
    });
  }

  List<Student> get filteredStudents {
    if (_searchQuery.isEmpty) return _students;
    return _students.where((student) =>
      student.name.toLowerCase().contains(_searchQuery.toLowerCase())
    ).toList();
  }

  Widget _buildContent() {
    if (_selectedView == StudentViewType.byClass) {
      return _buildClassView();
    } else if (_selectedView == StudentViewType.bySchool) {
      return _buildSchoolView();
    } else if (_selectedView == StudentViewType.byGrade) {
      return _buildGradeView();
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
                        if (_selectedView == StudentViewType.byClass) {
                          _showClassRegistrationDialog(
                            editMode: false,
                            classInfo: null,
                            index: -1,
                          );
                        } else {
                          _showStudentRegistrationDialog();
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
                          value: StudentViewType.byGrade,
                          label: Text('학년별'),
                        ),
                        ButtonSegment<StudentViewType>(
                          value: StudentViewType.bySchool,
                          label: Text('학교별'),
                        ),
                      ],
                      selected: {_selectedView},
                      onSelectionChanged: (Set<StudentViewType> newSelection) {
                        setState(() {
                          _selectedView = newSelection.first;
                        });
                      },
                      style: ButtonStyle(
                        backgroundColor: MaterialStateProperty.resolveWith<Color>(
                          (Set<MaterialState> states) {
                            if (states.contains(MaterialState.selected)) {
                              return const Color(0xFF1CB1F5).withOpacity(0.4);
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
                        child: InkWell(
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
                                  width: 20,
                                  height: 20,
                                  decoration: BoxDecoration(
                                    color: classInfo.color,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 20),
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
                                    width: 196,
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
    // 임시로 빈 컨테이너 반환
    return Container();
  }

  Widget _buildGradeView() {
    final Map<EducationLevel, Map<int, List<Student>>> groupedStudents = {
      EducationLevel.elementary: {},
      EducationLevel.middle: {},
      EducationLevel.high: {},
    };

    for (final student in filteredStudents) {
      groupedStudents[student.educationLevel]![student.grade.value] ??= [];
      groupedStudents[student.educationLevel]![student.grade.value]!.add(student);
    }

    // 각 그룹 내에서 이름순으로 정렬
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

  Widget _buildAllStudentsView() {
    final Map<EducationLevel, Map<int, List<Student>>> groupedStudents = {
      EducationLevel.elementary: {},
      EducationLevel.middle: {},
      EducationLevel.high: {},
    };

    for (final student in filteredStudents) {
      groupedStudents[student.educationLevel]![student.grade.value] ??= [];
      groupedStudents[student.educationLevel]![student.grade.value]!.add(student);
    }

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
      .toList()
      .where((entry) => entry.value.isNotEmpty)
      .map<Widget>((entry) {
        final gradeStudents = entry.value;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 8),
              child: Text(
                gradeStudents.first.grade.name,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            LayoutBuilder(
              builder: (context, constraints) {
                final cardWidth = (constraints.maxWidth - 16 * 4) / 5;
                return Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: gradeStudents.map((student) => _buildStudentCard(student, cardWidth)).toList(),
                );
              },
            ),
          ],
        );
      })
      .toList()
      ..sort((a, b) {
        final aGrade = (a as Column).children[0] as Padding;
        final bGrade = (b as Column).children[0] as Padding;
        final aText = (aGrade.child as Text).data!;
        final bText = (bGrade.child as Text).data!;
        return aText.compareTo(bText);
      });

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

  Widget _buildStudentCard(Student student, double width) {
    return InkWell(
      onTap: () => _showStudentDetailsDialog(student),
      child: Container(
        width: 196,
        decoration: BoxDecoration(
          color: const Color(0xFF333333),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      student.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(
                      Icons.more_vert,
                      color: Colors.white70,
                      size: 20,
                    ),
                    color: const Color(0xFF1F1F1F),
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'edit',
                        child: Text(
                          '수정',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text(
                          '퇴원',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                    onSelected: (value) async {
                      if (value == 'edit') {
                        _showStudentRegistrationDialog(
                          editMode: true,
                          editingStudent: student,
                        );
                      } else if (value == 'delete') {
                        final bool? confirmed = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            backgroundColor: const Color(0xFF1F1F1F),
                            title: const Text(
                              '학생 퇴원',
                              style: TextStyle(color: Colors.white),
                            ),
                            content: const Text(
                              '삭제된 파일은 복구가 불가능합니다.\n퇴원시키겠습니까?',
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
                                child: const Text('퇴원'),
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
                    },
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Text(
                    '${_getEducationLevelName(student.educationLevel)} ${student.grade.name}',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      student.school,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (student.classInfo != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: student.classInfo!.color.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        student.classInfo!.name,
                        style: TextStyle(
                          color: student.classInfo!.color,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showStudentDetailsDialog(Student student) async {
    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          title: Text(
            student.name,
            style: const TextStyle(color: Colors.white),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildDetailRow('과정', _getEducationLevelName(student.educationLevel)),
              _buildDetailRow('학년', student.grade.name),
              _buildDetailRow('학교', student.school),
              _buildDetailRow('클래스', student.classInfo?.name ?? '미소속'),
              _buildDetailRow('연락처', student.phoneNumber),
              _buildDetailRow('부모님 연락처', student.parentPhoneNumber),
              _buildDetailRow(
                '등록일',
                '${student.registrationDate.year}년 ${student.registrationDate.month}월 ${student.registrationDate.day}일',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                '닫기',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 16,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _getEducationLevelName(EducationLevel level) {
    return getEducationLevelName(level);
  }

  Future<void> _showStudentRegistrationDialog({
    bool editMode = false,
    Student? editingStudent,
  }) async {
    final result = await showDialog<Student>(
      context: context,
      builder: (context) => StudentRegistrationDialog(
        editMode: editMode,
        editingStudent: editingStudent,
        classes: _classes,
      ),
    );
    if (result != null) {
      if (editMode) {
        final index = _students.indexOf(editingStudent!);
        _updateStudent(result, index);
      } else {
        _addStudent(result);
      }
    }
  }

  Future<void> _showClassRegistrationDialog({
    required bool editMode,
    ClassInfo? classInfo,
    required int index,
  }) async {
    final result = await showDialog<ClassInfo>(
      context: context,
      builder: (context) => ClassRegistrationDialog(
        editMode: editMode,
        classInfo: classInfo,
      ),
    );
    if (result != null) {
      if (editMode) {
        _updateClass(result, index);
      } else {
        _addClass(result);
      }
    }
  }
}

enum StudentViewType {
  all,
  byClass,
  byGrade,
  bySchool,
}

enum SettingType {
  academy,
  general,
}

enum PaymentType {
  monthly,
  perClass,
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

class OperatingHours {
  final TimeOfDay start;
  final TimeOfDay end;

  const OperatingHours(this.start, this.end);
}

class TimeBlock {
  final TimeOfDay start;
  final TimeOfDay end;

  const TimeBlock(this.start, this.end);
}

 