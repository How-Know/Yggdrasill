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
    switch (_selectedIndex) {
      case 4: // 설정 메뉴
        return const SettingsScreen();
      case 1: // 학생 메뉴
        return const StudentScreen();
      default:
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

  Future<void> _showClassRegistrationDialog({
    bool editMode = false,
    ClassInfo? classInfo,
    int? index,
  }) async {
    String className = classInfo?.name ?? '';
    String description = classInfo?.description ?? '';
    String capacity = editMode ? classInfo!.capacity.toString() : '';
    Color selectedColor = classInfo?.color ?? classColors.first;

    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          title: Text(
            editMode ? '클래스 수정' : '클래스 등록',
            style: const TextStyle(color: Colors.white),
          ),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: TextEditingController(text: className)..selection = TextSelection.fromPosition(TextPosition(offset: className.length)),
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: '클래스명',
                      labelStyle: const TextStyle(color: Colors.white70),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1976D2)),
                      ),
                    ),
                    onChanged: (value) => className = value,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: TextEditingController(text: description)..selection = TextSelection.fromPosition(TextPosition(offset: description.length)),
                    style: const TextStyle(color: Colors.white),
                    maxLines: 3,
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
                    onChanged: (value) => description = value,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: TextEditingController(text: capacity)..selection = TextSelection.fromPosition(TextPosition(offset: capacity.length)),
                    style: const TextStyle(color: Colors.white),
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: '정원',
                      labelStyle: const TextStyle(color: Colors.white70),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: Color(0xFF1976D2)),
                      ),
                    ),
                    onChanged: (value) => capacity = value,
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    '클래스 색상',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 12),
                  StatefulBuilder(
                    builder: (context, setState) {
                      return Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: classColors.map((color) {
                          return InkWell(
                            onTap: () {
                              setState(() => selectedColor = color);
                            },
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: color,
                                shape: BoxShape.circle,
                                border: color == selectedColor
                                    ? Border.all(color: Colors.white, width: 2)
                                    : null,
                              ),
                            ),
                          );
                        }).toList(),
                      );
                    },
                  ),
                ],
              ),
            ),
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
            FilledButton(
              onPressed: () {
                final int? capacityValue = int.tryParse(capacity);
                if (className.isNotEmpty && capacityValue != null && capacityValue > 0) {
                  setState(() {
                    if (editMode) {
                      _classes[index!] = ClassInfo(
                        name: className,
                        description: description,
                        capacity: capacityValue,
                        color: selectedColor,
                      );
                    } else {
                      _classes.add(ClassInfo(
                        name: className,
                        description: description,
                        capacity: capacityValue,
                        color: selectedColor,
                      ));
                    }
                  });
                  Navigator.of(context).pop();
                }
              },
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1976D2),
              ),
              child: Text(
                editMode ? '수정' : '등록',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ],
        );
      },
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
              '학생',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 30),
          Stack(
            children: [
              Align(
                alignment: Alignment.center,
                child: SizedBox(
                  width: 400,
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
              Positioned(
                left: 0,
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
                        // TODO: 학생 등록 기능 구현
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

  Widget _buildContent() {
    if (_selectedView == StudentViewType.byClass) {
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
                      '0/${classInfo.capacity}명',
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
    return Container(); // 다른 뷰 타입에 대한 내용은 추후 구현
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
} 