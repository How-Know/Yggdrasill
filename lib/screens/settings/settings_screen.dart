import 'package:flutter/material.dart';
import '../../models/academy_settings.dart';
import '../../models/operating_hours.dart';
import '../../services/data_manager.dart';
import '../../models/payment_type.dart';

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
        const SizedBox(height: 48),
        // 테마 설정
        const Text(
          '테마',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w500,
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
      ],
    );
  }

  Widget _buildOperatingHoursSection() {
    const double blockWidth = 140.0;

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
        // 요일 버튼을 가로로 배치
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: DayOfWeek.values.map((day) {
              return Container(
                width: blockWidth,
                margin: const EdgeInsets.only(right: 8.0),
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2A2A2A),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                    minimumSize: Size.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: () => _selectOperatingHours(context, day),
                  child: Text(
                    day.koreanName,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 12),
        // 운영시간 블록들을 요일별로 표시
        Wrap(
          spacing: 8,
          runSpacing: 12,
          children: DayOfWeek.values.map((day) {
            if (_operatingHours[day] == null) return const SizedBox.shrink();
            
            return Container(
              width: blockWidth,
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A2A),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => _selectOperatingHours(context, day),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 운영시간
                        Text(
                          '${_formatTimeOfDay(_operatingHours[day]!.start)} - ${_formatTimeOfDay(_operatingHours[day]!.end)}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 8),
                        // 휴식시간 추가/삭제 버튼
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton.icon(
                              icon: const Icon(
                                Icons.add,
                                color: Color(0xFF1976D2),
                                size: 16,
                              ),
                              label: const Text(
                                '휴식',
                                style: TextStyle(
                                  color: Color(0xFF1976D2),
                                  fontSize: 12,
                                ),
                              ),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 4,
                                ),
                                minimumSize: Size.zero,
                              ),
                              onPressed: () => _addBreakTime(day),
                            ),
                            const SizedBox(width: 4),
                            IconButton(
                              icon: const Icon(
                                Icons.delete_outline,
                                color: Colors.white70,
                                size: 18,
                              ),
                              onPressed: () {
                                setState(() {
                                  _operatingHours[day] = null;
                                  _breakTimes[day]?.clear();
                                });
                              },
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              tooltip: '운영시간 삭제',
                            ),
                          ],
                        ),
                        // 휴식시간 목록
                        if (_breakTimes[day]?.isNotEmpty ?? false) ...[
                          const Divider(
                            color: Color(0xFF404040),
                            height: 16,
                            thickness: 1,
                            indent: 8,
                            endIndent: 8,
                          ),
                          ..._breakTimes[day]!.map((breakTime) => Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '${_formatTimeOfDay(breakTime.start)} - ${_formatTimeOfDay(breakTime.end)}',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                IconButton(
                                  icon: const Icon(
                                    Icons.close,
                                    color: Colors.white70,
                                    size: 14,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      _breakTimes[day]?.remove(breakTime);
                                    });
                                  },
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  tooltip: '휴식시간 삭제',
                                ),
                              ],
                            ),
                          )).toList(),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
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

  Widget _buildAcademySettings() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 48),
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
        Row(
          children: [
            // 기본 정원
            SizedBox(
              width: 290,
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
            // 수업 시간
            SizedBox(
              width: 290,
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
        const SizedBox(height: 30),
        _buildOperatingHoursSection(),
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

                // 2. 지불 방식 저장
                await DataManager.instance.savePaymentType(_paymentType);

                // 3. 운영 시간 및 Break Time 저장
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
        padding: const EdgeInsets.all(24.0),  // 모든 방향 24px 패딩
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
          ],
        ),
      ),
    );
  }
} 