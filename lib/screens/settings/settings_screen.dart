import 'package:flutter/material.dart';
import '../../models/academy_settings.dart';
import '../../models/operating_hours.dart';
import '../../services/data_manager.dart';
import '../../models/payment_type.dart';
import '../../services/academy_db.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../../widgets/app_bar_title.dart';
import 'dart:convert';
import '../../widgets/custom_tab_bar.dart';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import '../../models/teacher.dart';
import '../../widgets/main_fab.dart';
import '../../widgets/teacher_registration_dialog.dart';
import '../../widgets/teacher_details_dialog.dart';

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

  int _customTabIndex = 0;
  int _prevTabIndex = 0;

  // 운영시간 카드 hover 상태 관리
  final Set<int> _hoveredOperatingHourCards = {};

  final GlobalKey _academyInfoKey = GlobalKey();
  double _academyInfoHeight = 0;

  final Set<int> _hoveredTabs = {};

  // 운영시간/휴식 카드의 showActions 상태를 외부에서 관리
  final Map<String, bool> _cardActions = {};

  Uint8List? _academyLogo;

  // FAB 위치 조정용 상태 변수 추가
  double _fabBottomPadding = 16.0;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _snackBarController;

  bool _isTabAnimating = false;

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
        final logo = DataManager.instance.academySettings.logo;
        _academyLogo = (logo is Uint8List && logo.isNotEmpty) ? logo : null;
        print('[DEBUG] _loadSettings: 불러온 logo type=${logo?.runtimeType}, length=${logo?.length}, isNull=${logo == null}');
      });

      // 운영 시간 로드
      final hours = await DataManager.instance.getOperatingHours();
      setState(() {
        for (var d in DayOfWeek.values) {
          _operatingHours[d] = null;
          _breakTimes[d] = [];
        }
        for (var hour in hours) {
          final d = DayOfWeek.values[hour.dayOfWeek];
          _operatingHours[d] = TimeRange(
            start: TimeOfDay(hour: hour.startTime.hour, minute: hour.startTime.minute),
            end: TimeOfDay(hour: hour.endTime.hour, minute: hour.endTime.minute),
          );
          _breakTimes[d] = hour.breakTimes.map((breakTime) => TimeRange(
            start: TimeOfDay(hour: breakTime.startTime.hour, minute: breakTime.startTime.minute),
            end: TimeOfDay(hour: breakTime.endTime.hour, minute: breakTime.endTime.minute),
          )).toList();
        }
        print('[UI] _operatingHours after DB load:');
        _operatingHours.forEach((k, v) => print('  $k: $v'));
      });
    } catch (e) {
      print('Error loading settings: $e');
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
                              // TODO: 운영시간 수정 다이얼로그 연결
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
            // 왼쪽: 학원 정보 카드 + 로고 Stack
            Padding(
              padding: const EdgeInsets.only(top: 48),
              child: SizedBox(
                width: 650,
                height: 600,
                child: Stack(
                  children: [
                    Container(
                      height: 600,
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
                          const SizedBox(height: 30),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              const Text(
                                '학원 로고',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(width: 16),
                              const Text(
                                '권장 크기: 80x80px',
                                style: TextStyle(color: Colors.white70, fontSize: 14),
                              ),
                              const SizedBox(width: 16),
                              IconButton(
                                icon: Icon(Icons.image, color: Colors.white70),
                                tooltip: '학원 로고 등록',
                                onPressed: _pickLogoImage,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (_academyLogo != null && _academyLogo!.isNotEmpty)
                      Positioned(
                        right: 50,
                        bottom: 50,
                        child: GestureDetector(
                          onTap: _pickLogoImage,
                          child: CircleAvatar(
                            backgroundImage: MemoryImage(_academyLogo!),
                            radius: 50,
                          ),
                        ),
                      )
                    else
                      Positioned(
                        right: 50,
                        bottom: 50,
                        child: GestureDetector(
                          onTap: _pickLogoImage,
                          child: CircleAvatar(
                            radius: 50,
                            backgroundColor: Colors.grey[800],
                            child: Icon(Icons.image, color: Colors.white54, size: 40),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 24),
            // 오른쪽: 운영시간 컨테이너
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
        Stack(
          children: [
            Center(
              child: ElevatedButton(
                onPressed: () async {
                  try {
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    print('[DEBUG] 저장 버튼 클릭: _academyLogo type=${_academyLogo.runtimeType}, length=${_academyLogo?.length}, isNull=${_academyLogo == null}');
                    final academySettings = AcademySettings(
                      name: _academyNameController.text.trim(),
                      slogan: _sloganController.text.trim(),
                      defaultCapacity: int.tryParse(_capacityController.text.trim()) ?? 30,
                      lessonDuration: int.tryParse(_lessonDurationController.text.trim()) ?? 50,
                      logo: _academyLogo,
                    );
                    await DataManager.instance.saveAcademySettings(academySettings);
                    await DataManager.instance.savePaymentType(_paymentType);
                    await DataManager.instance.loadAcademySettings();
                    print('[DEBUG] 저장 후 불러온 logo: type=${DataManager.instance.academySettings.logo?.runtimeType}, length=${DataManager.instance.academySettings.logo?.length}, isNull=${DataManager.instance.academySettings.logo == null}');
                    setState(() {
                      final logo = DataManager.instance.academySettings.logo;
                      _academyLogo = (logo is Uint8List && logo.isNotEmpty) ? logo : null;
                    });
                    _onShowSnackBar();
                    _snackBarController = ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('저장되었습니다!'),
                      ),
                    );
                    _snackBarController?.closed.then((_) => _onHideSnackBar());
                  } catch (e) {
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    print('Error saving settings: $e');
                    _onShowSnackBar();
                    _snackBarController = ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('오류가 발생했습니다.'),
                      ),
                    );
                    _snackBarController?.closed.then((_) => _onHideSnackBar());
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
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    print('[DEBUG] SettingsScreen build: _customTabIndex=$_customTabIndex, _prevTabIndex=$_prevTabIndex');
    if (_academyLogo != null && _academyLogo!.isNotEmpty) {
      print('[UI] _academyLogo type=\x1b[36m${_academyLogo.runtimeType}\x1b[0m, length=\x1b[36m${_academyLogo?.length}\x1b[0m, isNull=${_academyLogo == null}');
    }
    return Scaffold(
      backgroundColor: const Color(0xFF1F1F1F),
      appBar: AppBarTitle(
        title: '설정',
        onBack: () {
          try {
            if (identical(0, 0.0)) {
              // ignore: avoid_web_libraries_in_flutter
              // html.window.history.back();
            } else {
              if (Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              }
            }
          } catch (_) {}
        },
        onForward: () {
          try {
            if (identical(0, 0.0)) {
              // ignore: avoid_web_libraries_in_flutter
              // html.window.history.forward();
            }
          } catch (_) {}
        },
        onRefresh: () => setState(() {}),
        onSettings: () {
          // MainScreen의 네비게이션 레일에서 처리하므로 별도 동작 없음
        },
      ),
      body: Column(
        children: [
          const SizedBox(height: 5),
          CustomTabBar(
            selectedIndex: _customTabIndex,
            tabs: const ['학원', '선생님', '일반'],
            onTabSelected: (idx) {
              if (_isTabAnimating || idx == _customTabIndex) return;
              setState(() {
                print('[DEBUG] 탭 클릭: 이전(_prevTabIndex)=$_prevTabIndex, 현재(_customTabIndex)=$_customTabIndex, 선택(idx)=$idx');
                _prevTabIndex = _customTabIndex;
                _customTabIndex = idx;
                _isTabAnimating = true;
              });
            },
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 400),
              child: _customTabIndex == 0
                  ? KeyedSubtree(key: ValueKey(0), child: _buildAcademySettings())
                  : _customTabIndex == 1
                      ? KeyedSubtree(key: ValueKey(1), child: _buildTeacherSettings())
                      : KeyedSubtree(key: ValueKey(2), child: _buildGeneralSettings()),
              transitionBuilder: (child, animation) {
                animation.addStatusListener((status) {
                  if (status == AnimationStatus.completed || status == AnimationStatus.dismissed) {
                    if (_isTabAnimating) {
                      setState(() {
                        _isTabAnimating = false;
                      });
                    }
                  }
                });
                final isForward = _customTabIndex > _prevTabIndex;
                final childKey = (child.key as ValueKey<int>).value;
                if (childKey == _customTabIndex) {
                  // 들어오는 위젯: 오른쪽(또는 왼쪽)에서 슬라이드 인
                  return SlideTransition(
                    position: Tween<Offset>(
                      begin: Offset(isForward ? 1.0 : -1.0, 0.0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  );
                } else {
                  // 나가는 위젯: 왼쪽(또는 오른쪽)으로 슬라이드 아웃
                  return SlideTransition(
                    position: Tween<Offset>(
                      begin: Offset.zero,
                      end: Offset(isForward ? -1.0 : 1.0, 0.0),
                    ).animate(animation),
                    child: child,
                  );
                }
              },
            ),
          ),
        ],
      ),
      floatingActionButton: const MainFab(),
    );
  }

  void _pickLogoImage() async {
    if (kIsWeb) {
      // 웹: FileUploadInputElement 사용 (주석 참고)
    } else {
      final result = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
      if (result != null && result.files.single.bytes != null) {
        setState(() {
          _academyLogo = result.files.single.bytes;
          print('[DEBUG] _pickLogoImage: _academyLogo type=${_academyLogo.runtimeType}, length=${_academyLogo?.length}, isNull=${_academyLogo == null}');
        });
      } else {
        print('[DEBUG] _pickLogoImage: result is null or bytes is null');
      }
    }
  }

  Future<void> _selectOperatingHours(BuildContext context, DayOfWeek day) async {
    final TimeOfDay? startTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: 9, minute: 0),
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
    if (startTime == null) return;
    final TimeOfDay? endTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: startTime.hour + 1, minute: startTime.minute),
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
    if (endTime == null) return;
    setState(() {
      _operatingHours[day] = TimeRange(start: startTime, end: endTime);
      print('[UI] _operatingHours after set:');
      _operatingHours.forEach((k, v) => print('  $k: $v'));
    });
    // DB 저장을 위해 전체 운영시간을 OperatingHours 리스트로 변환
    final List<OperatingHours> hoursList = _operatingHours.entries.where((e) => e.value != null).map((e) {
      final range = e.value!;
      final breaks = _breakTimes[e.key] ?? [];
      print('[UI] hoursList entry: day=${e.key}, range=$range');
      return OperatingHours(
        startTime: DateTime(2020, 1, 1, range.start.hour, range.start.minute),
        endTime: DateTime(2020, 1, 1, range.end.hour, range.end.minute),
        breakTimes: breaks.map((b) => BreakTime(
          startTime: DateTime(2020, 1, 1, b.start.hour, b.start.minute),
          endTime: DateTime(2020, 1, 1, b.end.hour, b.end.minute),
        )).toList(),
        dayOfWeek: e.key.index,
      );
    }).toList();
    print('[UI] hoursList to save: ${hoursList.length}개');
    await DataManager.instance.saveOperatingHours(hoursList);
    final hours = await DataManager.instance.getOperatingHours();
    print('[UI] hours loaded from DB: ${hours.length}개');
    for (var h in hours) {
      print('  start=${h.startTime}, end=${h.endTime}');
    }
    setState(() {
      for (var d in DayOfWeek.values) {
        _operatingHours[d] = null;
        _breakTimes[d] = [];
      }
      for (var hour in hours) {
        final d = DayOfWeek.values[hour.dayOfWeek];
        _operatingHours[d] = TimeRange(
          start: TimeOfDay(hour: hour.startTime.hour, minute: hour.startTime.minute),
          end: TimeOfDay(hour: hour.endTime.hour, minute: hour.endTime.minute),
        );
        _breakTimes[d] = hour.breakTimes.map((breakTime) => TimeRange(
          start: TimeOfDay(hour: breakTime.startTime.hour, minute: breakTime.startTime.minute),
          end: TimeOfDay(hour: breakTime.endTime.hour, minute: breakTime.endTime.minute),
        )).toList();
      }
      print('[UI] _operatingHours after DB load:');
      _operatingHours.forEach((k, v) => print('  $k: $v'));
    });
  }

  void _showAddTeacherDialog() async {
    await showDialog(
      context: context,
      builder: (context) => TeacherRegistrationDialog(
        onSave: (teacher) {
          DataManager.instance.addTeacher(teacher);
        },
      ),
    );
  }

  Widget _buildTeacherSettings() {
    return Padding(
      padding: const EdgeInsets.only(top: 48),
      child: Align(
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: 650,
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF18181A),
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      '선생님 관리',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    ElevatedButton(
                      onPressed: _showAddTeacherDialog,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1976D2),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                      ),
                      child: const Text('선생님 등록', style: TextStyle(fontSize: 16, color: Colors.white)),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                ValueListenableBuilder<List<Teacher>>(
                  valueListenable: DataManager.instance.teachersNotifier,
                  builder: (context, teachers, _) {
                    if (teachers.isEmpty) {
                      return Center(
                        child: Text(
                          '등록된 선생님이 없습니다.',
                          style: TextStyle(color: Colors.white70, fontSize: 18),
                        ),
                      );
                    }
                    return SizedBox(
                      height: (teachers.length * 64.0) + ((teachers.length - 1) * 16.0),
                      child: ReorderableListView(
                        buildDefaultDragHandles: false,
                        proxyDecorator: (child, index, animation) {
                          return Material(
                            color: Colors.transparent,
                            child: Container(
                              decoration: BoxDecoration(
                                color: const Color(0xFF23232A),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: child,
                            ),
                          );
                        },
                        onReorder: (oldIndex, newIndex) {
                          if (newIndex > oldIndex) newIndex--;
                          final newList = List<Teacher>.from(teachers);
                          final item = newList.removeAt(oldIndex);
                          newList.insert(newIndex, item);
                          DataManager.instance.setTeachersOrder(newList);
                        },
                        children: [
                          for (int i = 0; i < teachers.length; i++)
                            Padding(
                              key: ValueKey(teachers[i]),
                              padding: EdgeInsets.only(bottom: i == teachers.length - 1 ? 0 : 16),
                              child: _buildTeacherCard(teachers[i], key: ValueKey(teachers[i])),
                            ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 24), // 하단 여백
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTeacherCard(Teacher t, {Key? key}) {
    return Container(
      key: key,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
      decoration: BoxDecoration(
        color: const Color(0xFF23232A),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              t.name,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(width: 16),
          SizedBox(
            width: 60,
            child: Text(
              getTeacherRoleLabel(t.role),
              style: const TextStyle(color: Colors.white70, fontSize: 14),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(width: 16),
          SizedBox(
            width: 320,
            child: Text(
              t.description,
              style: const TextStyle(color: Colors.white60, fontSize: 13),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              mainAxisSize: MainAxisSize.max,
              children: [
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, color: Colors.white54),
                  color: const Color(0xFF2A2A2A),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  onSelected: (value) async {
                    if (value == 'edit') {
                      await showDialog(
                        context: context,
                        builder: (context) => TeacherRegistrationDialog(
                          teacher: t,
                          onSave: (updatedTeacher) {
                            final idx = DataManager.instance.teachersNotifier.value.indexOf(t);
                            if (idx != -1) {
                              DataManager.instance.updateTeacher(idx, updatedTeacher);
                            }
                          },
                        ),
                      );
                    } else if (value == 'delete') {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          backgroundColor: const Color(0xFF2A2A2A),
                          title: const Text('선생님 삭제', style: TextStyle(color: Colors.white)),
                          content: const Text('정말로 이 선생님을 삭제하시겠습니까?', style: TextStyle(color: Colors.white)),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(false),
                              child: const Text('취소'),
                            ),
                            FilledButton(
                              style: FilledButton.styleFrom(backgroundColor: Colors.red),
                              onPressed: () => Navigator.of(context).pop(true),
                              child: const Text('삭제'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true) {
                        final idx = DataManager.instance.teachersNotifier.value.indexOf(t);
                        if (idx != -1) {
                          DataManager.instance.deleteTeacher(idx);
                        }
                      }
                    } else if (value == 'details') {
                      await showDialog(
                        context: context,
                        builder: (context) => TeacherDetailsDialog(teacher: t),
                      );
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'edit',
                      child: ListTile(
                        leading: const Icon(Icons.edit_outlined, color: Colors.white70),
                        title: const Text('수정', style: TextStyle(color: Colors.white)),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: ListTile(
                        leading: const Icon(Icons.delete_outline, color: Colors.red),
                        title: const Text('삭제', style: TextStyle(color: Colors.red)),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'details',
                      child: ListTile(
                        leading: const Icon(Icons.info_outline, color: Colors.white70),
                        title: const Text('상세보기', style: TextStyle(color: Colors.white)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 2),
                ReorderableDragStartListener(
                  index: DataManager.instance.teachersNotifier.value.indexOf(t),
                  child: Icon(Icons.drag_handle, color: Colors.white38),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // FAB 위치 조정 함수
  void _onShowSnackBar() {
    setState(() {
      _fabBottomPadding = 80.0 + 16.0; // 스낵바 높이 + 기본 패딩
    });
  }
  void _onHideSnackBar() {
    setState(() {
      _fabBottomPadding = 16.0;
    });
  }
} 