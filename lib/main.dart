import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

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
          AnimatedBuilder(
            animation: _sideSheetAnimation,
            builder: (context, child) => ClipRect(
              child: SizedBox(
                width: 300 * _sideSheetAnimation.value,
                child: Container(
                  color: const Color(0xFF121212),
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

class _StudentScreenState extends State<StudentScreen> {
  StudentViewType _selectedView = StudentViewType.all;
  final List<ClassInfo> _classes = [];
  final List<Student> _students = [];
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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
          final studentsInClass = _students.where((s) => s.classInfo == classInfo).length;
          
          return Padding(
            key: ValueKey(classInfo),
            padding: const EdgeInsets.only(bottom: 17.6),
            child: Container(
              height: 88,
              decoration: BoxDecoration(
                color: const Color(0xFF121212),
                borderRadius: BorderRadius.circular(16),
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
                    '$studentsInClass/${classInfo.capacity}명',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 24),
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
                                        _classes.removeAt(index!);
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
        width: 280,
        decoration: BoxDecoration(
          color: const Color(0xFF121212),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      student.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        onPressed: () {
                          _showStudentRegistrationDialog(
                            editMode: true,
                            editingStudent: student,
                            studentIndex: _students.indexOf(student),
                          );
                        },
                        icon: const Icon(Icons.edit_rounded),
                        style: IconButton.styleFrom(
                          foregroundColor: Colors.white70,
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      IconButton(
                        onPressed: () async {
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
                        },
                        icon: const Icon(Icons.delete_rounded),
                        style: IconButton.styleFrom(
                          foregroundColor: Colors.white70,
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Text(
                    student.grade.name,
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
    switch (level) {
      case EducationLevel.elementary:
        return '초등';
      case EducationLevel.middle:
        return '중등';
      case EducationLevel.high:
        return '고등';
    }
  }

  Future<void> _showClassRegistrationDialog({
    required bool editMode,
    ClassInfo? classInfo,
    required int index,
  }) async {
    final TextEditingController nameController = TextEditingController(text: classInfo?.name ?? '');
    final TextEditingController descriptionController = TextEditingController(text: classInfo?.description ?? '');
    final TextEditingController capacityController = TextEditingController(text: classInfo?.capacity.toString());
    Color selectedColor = classInfo?.color ?? Colors.blue;

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1F1F1F),
        title: Text(
          editMode ? '클래스 수정' : '새 클래스 등록',
          style: const TextStyle(color: Colors.white),
        ),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '기본 정보',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 24),
                // 이름과 정원을 나란히 배치 (3:2 비율)
                Row(
                  children: [
                    // 이름
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: nameController,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: '클래스 이름',
                          labelStyle: const TextStyle(color: Colors.white70),
                          hintText: '클래스 이름을 입력하세요',
                          hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                          enabledBorder: OutlineInputBorder(
                            borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                          ),
                          focusedBorder: const OutlineInputBorder(
                            borderSide: BorderSide(color: Color(0xFF1976D2)),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    // 정원
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: capacityController,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: '정원',
                          labelStyle: const TextStyle(color: Colors.white70),
                          hintText: '정원',
                          hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                          enabledBorder: OutlineInputBorder(
                            borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                          ),
                          focusedBorder: const OutlineInputBorder(
                            borderSide: BorderSide(color: Color(0xFF1976D2)),
                          ),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // 설명 (2줄 높이)
                TextField(
                  controller: descriptionController,
                  style: const TextStyle(color: Colors.white),
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: '설명',
                    labelStyle: const TextStyle(color: Colors.white70),
                    hintText: '클래스 설명을 입력하세요',
                    hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                    enabledBorder: OutlineInputBorder(
                      borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderSide: BorderSide(color: Color(0xFF1976D2)),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                // 색상 선택
                const Text(
                  '클래스 색상',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 16),
                // 색상 선택 그리드 (10x2)
                SizedBox(
                  height: 96,
                  child: GridView.count(
                    crossAxisCount: 10,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      // 첫 번째 줄: 밝은 색상들
                      Colors.red[500]!, // 빨강
                      Colors.pink[400]!, // 분홍
                      Colors.purple[400]!, // 보라
                      Colors.deepPurple[400]!, // 진보라
                      Colors.blue[500]!, // 파랑
                      Colors.lightBlue[400]!, // 하늘색
                      Colors.cyan[500]!, // 청록
                      Colors.teal[500]!, // 틸
                      Colors.green[500]!, // 초록
                      Colors.lightGreen[500]!, // 연두
                      // 두 번째 줄: 다양한 색조와 채도
                      Colors.amber[600]!, // 황금색
                      Colors.orange[600]!, // 주황
                      Colors.deepOrange[400]!, // 진주황
                      Colors.brown[400]!, // 갈색
                      Colors.blueGrey[400]!, // 블루그레이
                      Colors.indigo[400]!, // 인디고
                      Colors.lime[600]!, // 라임
                      Colors.yellow[600]!, // 노랑
                      const Color(0xFF2196F3), // 밝은 파랑
                      const Color(0xFF607D8B), // 그레이
                    ].map((color) {
                      return InkWell(
                        onTap: () {
                          setState(() {
                            selectedColor = color;
                          });
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: selectedColor == color ? Colors.white : Colors.transparent,
                              width: 2,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              '취소',
              style: TextStyle(color: Colors.white70),
            ),
          ),
          FilledButton(
            onPressed: () {
              final name = nameController.text.trim();
              final description = descriptionController.text.trim();
              final capacity = int.tryParse(capacityController.text.trim());

              if (name.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('클래스 이름을 입력해주세요')),
                );
                return;
              }

              if (capacity == null || capacity <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('올바른 정원을 입력해주세요')),
                );
                return;
              }

              setState(() {
                if (editMode && classInfo != null) {
                  _classes[index] = ClassInfo(
                    name: name,
                    description: description,
                    capacity: capacity,
                    color: selectedColor,
                  );
                } else {
                  _classes.add(ClassInfo(
                    name: name,
                    description: description,
                    capacity: capacity,
                    color: selectedColor,
                  ));
                }
              });

              Navigator.pop(context);
            },
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF1976D2),
            ),
            child: Text(editMode ? '수정' : '등록'),
          ),
        ],
      ),
    );
  }

  Future<void> _showStudentRegistrationDialog({
    bool editMode = false,
    Student? editingStudent,
    int? studentIndex,
  }) async {
    final TextEditingController nameController = TextEditingController(
      text: editMode ? editingStudent!.name : '',
    );
    final TextEditingController schoolController = TextEditingController(
      text: editMode ? editingStudent!.school : '',
    );
    final TextEditingController phoneController = TextEditingController(
      text: editMode ? editingStudent!.phoneNumber : '',
    );
    final TextEditingController parentPhoneController = TextEditingController(
      text: editMode ? editingStudent!.parentPhoneNumber : '',
    );
    
    EducationLevel? selectedEducationLevel = editMode ? editingStudent!.educationLevel : null;
    Grade? selectedGrade = editMode ? editingStudent!.grade : null;
    ClassInfo? selectedClass = editMode ? editingStudent!.classInfo : null;
    DateTime selectedDate = editMode ? editingStudent!.registrationDate : DateTime.now();

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) => AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          title: Text(
            editMode ? '학생 정보 수정' : '새 학생 등록',
            style: const TextStyle(color: Colors.white),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '기본 정보',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 24),
                // 이름
                SizedBox(
                  width: 300,
                  child: TextField(
                    controller: nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: '이름',
                      labelStyle: const TextStyle(color: Colors.white70),
                      hintText: '학생 이름을 입력하세요',
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1976D2)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // 클래스
                SizedBox(
                  width: 300,
                  child: DropdownButtonFormField<ClassInfo?>(
                    value: selectedClass,
                    style: const TextStyle(color: Colors.white),
                    dropdownColor: const Color(0xFF1F1F1F),
                    decoration: InputDecoration(
                      labelText: '클래스',
                      labelStyle: const TextStyle(color: Colors.white70),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1976D2)),
                      ),
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text(
                          '미소속',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      ..._classes.map((classInfo) {
                        return DropdownMenuItem(
                          value: classInfo,
                          child: Text(
                            classInfo.name,
                            style: const TextStyle(color: Colors.white),
                          ),
                        );
                      }).toList(),
                    ],
                    onChanged: (value) {
                      setState(() {
                        selectedClass = value;
                      });
                    },
                  ),
                ),
                const SizedBox(height: 16),
                // 과정과 학년을 나란히 배치
                Row(
                  children: [
                    // 과정
                    SizedBox(
                      width: 140,
                      child: DropdownButtonFormField<EducationLevel>(
                        value: selectedEducationLevel,
                        style: const TextStyle(color: Colors.white),
                        dropdownColor: const Color(0xFF1F1F1F),
                        decoration: InputDecoration(
                          labelText: '과정',
                          labelStyle: const TextStyle(color: Colors.white70),
                          enabledBorder: OutlineInputBorder(
                            borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                          ),
                          focusedBorder: const OutlineInputBorder(
                            borderSide: BorderSide(color: Color(0xFF1976D2)),
                          ),
                        ),
                        items: EducationLevel.values.map((level) {
                          return DropdownMenuItem(
                            value: level,
                            child: Text(
                              _getEducationLevelName(level),
                              style: const TextStyle(color: Colors.white),
                            ),
                          );
                        }).toList(),
                        onChanged: (value) {
                          setState(() {
                            selectedEducationLevel = value;
                            selectedGrade = value != null ? gradesByLevel[value]!.first : null;
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: 20),
                    // 학년
                    SizedBox(
                      width: 140,
                      child: DropdownButtonFormField<Grade>(
                        value: selectedGrade,
                        style: const TextStyle(color: Colors.white),
                        dropdownColor: const Color(0xFF1F1F1F),
                        decoration: InputDecoration(
                          labelText: '학년',
                          labelStyle: const TextStyle(color: Colors.white70),
                          enabledBorder: OutlineInputBorder(
                            borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                          ),
                          focusedBorder: const OutlineInputBorder(
                            borderSide: BorderSide(color: Color(0xFF1976D2)),
                          ),
                        ),
                        items: selectedEducationLevel != null
                            ? gradesByLevel[selectedEducationLevel]!.map((grade) {
                                return DropdownMenuItem(
                                  value: grade,
                                  child: Text(
                                    grade.name,
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                );
                              }).toList()
                            : null,
                        onChanged: selectedEducationLevel != null
                            ? (value) {
                                if (value != null) {
                                  setState(() {
                                    selectedGrade = value;
                                  });
                                }
                              }
                            : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // 학교
                SizedBox(
                  width: 300,
                  child: TextField(
                    controller: schoolController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: '학교',
                      labelStyle: const TextStyle(color: Colors.white70),
                      hintText: '학교 이름을 입력하세요',
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1976D2)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // 연락처
                SizedBox(
                  width: 300,
                  child: TextField(
                    controller: phoneController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: '연락처',
                      labelStyle: const TextStyle(color: Colors.white70),
                      hintText: '선택 사항',
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1976D2)),
                      ),
                    ),
                    keyboardType: TextInputType.phone,
                  ),
                ),
                const SizedBox(height: 16),
                // 부모님 연락처
                SizedBox(
                  width: 300,
                  child: TextField(
                    controller: parentPhoneController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: '부모님 연락처',
                      labelStyle: const TextStyle(color: Colors.white70),
                      hintText: '선택 사항',
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1976D2)),
                      ),
                    ),
                    keyboardType: TextInputType.phone,
                  ),
                ),
                const SizedBox(height: 16),
                // 등록일자
                SizedBox(
                  width: 300,
                  child: InkWell(
                    onTap: () async {
                      final DateTime? picked = await showDatePicker(
                        context: context,
                        initialDate: selectedDate,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                        builder: (context, child) {
                          return Theme(
                            data: Theme.of(context).copyWith(
                              colorScheme: const ColorScheme.dark(
                                primary: Color(0xFF1976D2),
                                onPrimary: Colors.white,
                                surface: Color(0xFF1F1F1F),
                                onSurface: Colors.white,
                              ),
                              dialogBackgroundColor: const Color(0xFF1F1F1F),
                            ),
                            child: child!,
                          );
                        },
                      );
                      if (picked != null) {
                        setState(() {
                          selectedDate = picked;
                        });
                      }
                    },
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: '등록일자',
                        labelStyle: const TextStyle(color: Colors.white70),
                        enabledBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                        ),
                        focusedBorder: const OutlineInputBorder(
                          borderSide: BorderSide(color: Color(0xFF1976D2)),
                        ),
                      ),
                      child: Text(
                        '${selectedDate.year}년 ${selectedDate.month}월 ${selectedDate.day}일',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                '취소',
                style: TextStyle(color: Colors.white70),
              ),
            ),
            FilledButton(
              onPressed: () {
                final name = nameController.text.trim();
                final school = schoolController.text.trim();
                final phone = phoneController.text.trim();
                final parentPhone = parentPhoneController.text.trim();

                if (name.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('학생 이름을 입력해주세요')),
                  );
                  return;
                }

                if (selectedEducationLevel == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('과정을 선택해주세요')),
                  );
                  return;
                }

                if (selectedGrade == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('학년을 선택해주세요')),
                  );
                  return;
                }

                                  // 새로운 학생 객체 생성
                  final Student student = Student(
                    name: name,
                    educationLevel: selectedEducationLevel!,
                    grade: selectedGrade!,
                    school: school,
                    classInfo: selectedClass,
                    phoneNumber: phone,
                    parentPhoneNumber: parentPhone,
                    registrationDate: selectedDate,
                  );

                  // 다이얼로그를 먼저 닫고
                  Navigator.pop(context);
                  
                  // 그 다음 상태를 업데이트
                  setState(() {
                    if (editMode && editingStudent != null) {
                      _students[studentIndex!] = student;
                    } else {
                      _students.add(student);
                    }
                  });
              },
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1976D2),
              ),
              child: Text(editMode ? '수정' : '등록'),
            ),
          ],
        ),
      ),
    );
  }
}

class ClassInfo {
  final String name;
  final String description;
  final int capacity;
  final Color color;

  ClassInfo({
    required this.name,
    required this.description,
    required this.capacity,
    required this.color,
  });
}

// 20가지 클래스 색상 정의
const classColors = [
  Color(0xFF1976D2), // Blue
  Color(0xFF2196F3), // Light Blue
  Color(0xFF00BCD4), // Cyan
  Color(0xFF009688), // Teal
  Color(0xFF4CAF50), // Green
  Color(0xFF8BC34A), // Light Green
  Color(0xFFCDDC39), // Lime
  Color(0xFFFFEB3B), // Yellow
  Color(0xFFFFC107), // Amber
  Color(0xFFFF9800), // Orange
  Color(0xFFFF5722), // Deep Orange
  Color(0xFFF44336), // Red
  Color(0xFFE91E63), // Pink
  Color(0xFF9C27B0), // Purple
  Color(0xFF673AB7), // Deep Purple
  Color(0xFF3F51B5), // Indigo
  Color(0xFF795548), // Brown
  Color(0xFF607D8B), // Blue Grey
  Color(0xFF9E9E9E), // Grey
  Color(0xFF455A64), // Dark Blue Grey
];

enum SettingType {
  academy,
  general,
}

enum PaymentType {
  monthly,
  perClass,
}

enum ThemeMode {
  system,
  light,
  dark,
}

enum DayOfWeek {
  monday('월요일'),
  tuesday('화요일'),
  wednesday('수요일'),
  thursday('목요일'),
  friday('금요일'),
  saturday('토요일'),
  sunday('일요일');

  final String koreanName;
  const DayOfWeek(this.koreanName);
}

class OperatingHours {
  final TimeOfDay start;
  final TimeOfDay end;

  OperatingHours(this.start, this.end);
}

class TimeBlock {
  final TimeOfDay start;
  final TimeOfDay end;

  TimeBlock(this.start, this.end);
}

enum StudentViewType {
  all,
  byClass,
  bySchool,
  byGrade,
}

enum EducationLevel {
  elementary,
  middle,
  high
}

class Grade {
  final EducationLevel level;
  final String name;
  final int value;

  const Grade(this.level, this.name, this.value);
}

final Map<EducationLevel, List<Grade>> gradesByLevel = {
  EducationLevel.elementary: [
    Grade(EducationLevel.elementary, '1학년', 1),
    Grade(EducationLevel.elementary, '2학년', 2),
    Grade(EducationLevel.elementary, '3학년', 3),
    Grade(EducationLevel.elementary, '4학년', 4),
    Grade(EducationLevel.elementary, '5학년', 5),
    Grade(EducationLevel.elementary, '6학년', 6),
  ],
  EducationLevel.middle: [
    Grade(EducationLevel.middle, '1학년', 1),
    Grade(EducationLevel.middle, '2학년', 2),
    Grade(EducationLevel.middle, '3학년', 3),
  ],
  EducationLevel.high: [
    Grade(EducationLevel.high, '1학년', 1),
    Grade(EducationLevel.high, '2학년', 2),
    Grade(EducationLevel.high, '3학년', 3),
    Grade(EducationLevel.high, 'N수', 4),
  ],
};

class Student {
  final String name;
  final EducationLevel educationLevel;
  final Grade grade;
  final String school;
  final ClassInfo? classInfo;
  final String phoneNumber;
  final String parentPhoneNumber;
  final DateTime registrationDate;

  const Student({
    required this.name,
    required this.educationLevel,
    required this.grade,
    required this.school,
    this.classInfo,
    required this.phoneNumber,
    required this.parentPhoneNumber,
    required this.registrationDate,
  });
} 