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
import '../../widgets/main_fab_alternative.dart';
import '../../widgets/teacher_registration_dialog.dart';
import '../../widgets/teacher_details_dialog.dart';
import 'package:animations/animations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import '../../services/sync_service.dart';
import '../../services/update_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../services/tenant_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';

enum SettingType {
  academy,
  teachers,
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

// TimeRange도 int 기반으로 변경
class TimeRange {
  final int startHour;
  final int startMinute;
  final int endHour;
  final int endMinute;
  const TimeRange({required this.startHour, required this.startMinute, required this.endHour, required this.endMinute});
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
  // 스크롤 컨트롤러 (탭별)
  final ScrollController _academyScrollController = ScrollController();
  final ScrollController _teacherScrollController = ScrollController();
  final ScrollController _generalScrollController = ScrollController();
  
  // 학원 설정 컨트롤러들
  final TextEditingController _academyNameController = ImeAwareTextEditingController();
  final TextEditingController _sloganController = ImeAwareTextEditingController();
  final TextEditingController _capacityController = ImeAwareTextEditingController(text: '30');
  final TextEditingController _lessonDurationController = ImeAwareTextEditingController(text: '50');
  // [추가] 수강 횟수 컨트롤러
  final TextEditingController _courseCountController = ImeAwareTextEditingController();
  
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
  bool _fullscreenEnabled = false; // [추가] 전체화면 스위치 상태
  bool _maximizeEnabled = false; // [추가] 최대창 시작 스위치 상태
  ThemeMode _selectedThemeMode = ThemeMode.dark; // [추가] 테마 선택 상태
  bool _isOwner = false; // 원장 여부 캐시
  bool _isSuperAdmin = false; // 플랫폼 관리자 여부

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadFullscreenSetting();
    _loadOwnerFlag();
    _loadSuperAdminFlag();
  }

  void _loadFullscreenSetting() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _fullscreenEnabled = prefs.getBool('fullscreen_enabled') ?? false;
      _maximizeEnabled = prefs.getBool('maximize_enabled') ?? false;
    });
  }

  Future<void> _loadOwnerFlag() async {
    try {
      final isOwner = await TenantService.instance.isOwnerOfActiveAcademy();
      if (!mounted) return;
      setState(() { _isOwner = isOwner; });
    } catch (_) {
      if (!mounted) return;
      setState(() { _isOwner = false; });
    }
  }

  Future<void> _loadSuperAdminFlag() async {
    try {
      final isAdmin = await TenantService.instance.isSuperAdmin();
      if (!mounted) return;
      setState(() { _isSuperAdmin = isAdmin; });
    } catch (_) {
      if (!mounted) return;
      setState(() { _isSuperAdmin = false; });
    }
  }

  @override
  void dispose() {
    _academyNameController.dispose();
    _sloganController.dispose();
    _capacityController.dispose();
    _lessonDurationController.dispose();
    _courseCountController.dispose(); // [추가]
    _academyScrollController.dispose();
    _teacherScrollController.dispose();
    _generalScrollController.dispose();
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
        _courseCountController.text = DataManager.instance.academySettings.sessionCycle.toString(); // [추가] 수강 횟수 불러오기
        _paymentType = DataManager.instance.paymentType; // [보완] 결제 방식 불러오기
        final logo = DataManager.instance.academySettings.logo;
        _academyLogo = (logo is Uint8List && logo.isNotEmpty) ? logo : null;
        print('[DEBUG] _loadSettings: 불러온 logo type=${logo?.runtimeType}, length=${logo?.length}, isNull=${logo == null}');
      });

      // 운영 시간 로드
      final hours = await DataManager.instance.getOperatingHours();
      print('[DEBUG][LOAD] DB에서 불러온 hours:');
      for (final h in hours) {
        print('  dayOfWeek= [36m${h.dayOfWeek} [0m start=${h.startHour}:${h.startMinute} end=${h.endHour}:${h.endMinute}');
      }
      setState(() {
        for (var d in DayOfWeek.values) {
          _operatingHours[d] = null;
          _breakTimes[d] = [];
        }
        for (var hour in hours) {
          final d = DayOfWeek.values[hour.dayOfWeek];
          print('[DEBUG][MAPPING] hour.dayOfWeek=${hour.dayOfWeek} → DayOfWeek.${d.name}');
          _operatingHours[d] = TimeRange(
            startHour: hour.startHour,
            startMinute: hour.startMinute,
            endHour: hour.endHour,
            endMinute: hour.endMinute,
          );
          _breakTimes[d] = hour.breakTimes.map((breakTime) => TimeRange(
            startHour: breakTime.startHour,
            startMinute: breakTime.startMinute,
            endHour: breakTime.endHour,
            endMinute: breakTime.endMinute,
          )).toList();
        }
        print('[DEBUG][MAPPING] 최종 _operatingHours:');
        _operatingHours.forEach((k, v) => print('  ${k.name}: $v'));
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
        child: SizedBox(
          width: 650,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            decoration: BoxDecoration(
              color: Color(0xFF18181A),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 업데이트 섹션
                const Padding(
                  padding: EdgeInsets.only(top: 24),
                  child: Text(
                    '업데이트',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '최신 버전 확인 및 설치를 진행합니다.',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                    FutureBuilder<PackageInfo>(
                      future: PackageInfo.fromPlatform(),
                      builder: (context, snapshot) {
                        final ver = snapshot.data?.version ?? '';
                        final build = snapshot.data?.buildNumber ?? '';
                        final text = (ver.isEmpty && build.isEmpty)
                            ? '버전 확인 중...'
                            : '현재 버전: $ver+$build';
                        return Padding(
                          padding: const EdgeInsets.only(right: 12.0),
                          child: Text(text, style: const TextStyle(color: Colors.white60)),
                        );
                      },
                    ),
                    FilledButton.icon(
                      onPressed: () async {
                        await UpdateService.oneClickUpdate(context);
                      },
                      style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('업데이트 확인'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // AI 기능 토글
                const Padding(
                  padding: EdgeInsets.only(top: 24),
                  child: Text(
                    'AI',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FutureBuilder<bool>(
                  future: () async {
                    try {
                      // platform_config에서 API 키가 설정되어 있는지 확인
                      final res = await Supabase.instance.client
                          .from('platform_config')
                          .select('config_value')
                          .eq('config_key', 'openai_api_key')
                          .maybeSingle();
                      return res != null && (res['config_value'] as String? ?? '').isNotEmpty;
                    } catch (_) {
                      return false;
                    }
                  }(),
                  builder: (context, snapshot) {
                    final hasApiKey = snapshot.data ?? false;
                    return FutureBuilder<bool>(
                      future: SharedPreferences.getInstance().then((p) => p.getBool('ai_summary_enabled') ?? false),
                      builder: (context, enabledSnapshot) {
                        final isEnabled = enabledSnapshot.data ?? false;
                        return Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1F1F1F),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'AI 요약 사용',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      hasApiKey
                                          ? 'AI가 자동으로 메모를 요약합니다.'
                                          : 'API 키가 설정되지 않았습니다. 관리자에게 문의하세요.',
                                      style: TextStyle(
                                        color: hasApiKey ? Colors.white70 : Colors.amber,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Switch.adaptive(
                                value: hasApiKey && isEnabled,
                                onChanged: hasApiKey ? (value) async {
                                  final p = await SharedPreferences.getInstance();
                                  await p.setBool('ai_summary_enabled', value);
                                  setState(() {});
                                } : null,
                                activeColor: const Color(0xFF1976D2),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
                const SizedBox(height: 28),
                // 결제 데이터 보정 섹션은 요청으로 제거되었습니다.
                // 카카오 연동
                const Padding(
                  padding: EdgeInsets.only(top: 24),
                  child: Text(
                    '카카오 연동',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                // Base URL 입력
                FutureBuilder<String?>(
                  future: SharedPreferences.getInstance().then((p) => p.getString('kakao_api_base_url')),
                  builder: (context, snapshot) {
                    final controller = ImeAwareTextEditingController(text: snapshot.data ?? '');
                    return Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: controller,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              labelText: '서버 주소 (예: https://api.yourapp.com)',
                              labelStyle: TextStyle(color: Colors.white70),
                              hintText: '백엔드 서버 기본 주소를 입력하세요',
                              hintStyle: TextStyle(color: Colors.white24),
                              enabledBorder: OutlineInputBorder(
                                borderSide: BorderSide(color: Colors.white24),
                              ),
                              focusedBorder: const OutlineInputBorder(
                                borderSide: BorderSide(color: Color(0xFF1976D2)),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: () async {
                            final prefs = await SharedPreferences.getInstance();
                            final value = controller.text.trim();
                            if (value.isEmpty) {
                              await prefs.remove('kakao_api_base_url');
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                content: Text('서버 주소가 제거되었습니다.', style: TextStyle(color: Colors.white)),
                                backgroundColor: Color(0xFF1976D2),
                              ));
                            } else {
                              await prefs.setString('kakao_api_base_url', value);
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                content: Text('서버 주소가 저장되었습니다.', style: TextStyle(color: Colors.white)),
                                backgroundColor: Color(0xFF1976D2),
                              ));
                            }
                            setState(() {});
                          },
                          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
                          child: const Text('저장'),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
                // 설문 웹 Base URL
                const Padding(
                  padding: EdgeInsets.only(top: 24),
                  child: Text(
                    '설문 웹',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                FutureBuilder<String?>(
                  future: SharedPreferences.getInstance().then((p) => p.getString('survey_base_url')),
                  builder: (context, snapshot) {
                    final controller = ImeAwareTextEditingController(text: snapshot.data ?? 'http://localhost:5173');
                    return Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: controller,
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              labelText: '설문 웹 주소 (예: http://localhost:5173 또는 배포 URL)',
                              labelStyle: TextStyle(color: Colors.white70),
                              hintText: '설문 웹의 기본 주소를 입력하세요',
                              hintStyle: TextStyle(color: Colors.white24),
                              enabledBorder: OutlineInputBorder(
                                borderSide: BorderSide(color: Colors.white24),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderSide: BorderSide(color: Color(0xFF1976D2)),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: () async {
                            final prefs = await SharedPreferences.getInstance();
                            final value = controller.text.trim();
                            if (value.isEmpty) {
                              await prefs.remove('survey_base_url');
                            } else {
                              await prefs.setString('survey_base_url', value);
                            }
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                              content: Text('설문 웹 주소가 저장되었습니다.', style: TextStyle(color: Colors.white)),
                              backgroundColor: Color(0xFF1976D2),
                            ));
                            setState(() {});
                          },
                          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
                          child: const Text('저장'),
                        ),
                      ],
                    );
                  },
                ),
                // API 토큰 입력
                FutureBuilder<String?>(
                  future: SharedPreferences.getInstance().then((p) => p.getString('kakao_api_token')),
                  builder: (context, snapshot) {
                    final controller = ImeAwareTextEditingController(text: snapshot.data ?? '');
                    return Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: controller,
                            style: const TextStyle(color: Colors.white),
                            obscureText: true,
                            decoration: InputDecoration(
                              labelText: 'API 토큰 (선택)',
                              labelStyle: TextStyle(color: Colors.white70),
                              hintText: '백엔드 인증용 토큰이 있다면 입력하세요',
                              hintStyle: TextStyle(color: Colors.white24),
                              enabledBorder: OutlineInputBorder(
                                borderSide: BorderSide(color: Colors.white24),
                              ),
                              focusedBorder: const OutlineInputBorder(
                                borderSide: BorderSide(color: Color(0xFF1976D2)),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: () async {
                            final prefs = await SharedPreferences.getInstance();
                            final value = controller.text.trim();
                            if (value.isEmpty) {
                              await prefs.remove('kakao_api_token');
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                content: Text('API 토큰이 제거되었습니다.', style: TextStyle(color: Colors.white)),
                                backgroundColor: Color(0xFF1976D2),
                              ));
                            } else {
                              await prefs.setString('kakao_api_token', value);
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                content: Text('API 토큰이 저장되었습니다.', style: TextStyle(color: Colors.white)),
                                backgroundColor: Color(0xFF1976D2),
                              ));
                            }
                            setState(() {});
                          },
                          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
                          child: const Text('저장'),
                        ),
                        const SizedBox(width: 8),
                        Icon((snapshot.data != null && (snapshot.data ?? '').isNotEmpty) ? Icons.check_circle : Icons.error_outline,
                            color: (snapshot.data != null && (snapshot.data ?? '').isNotEmpty) ? Colors.lightGreen : Colors.orangeAccent, size: 18),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
                // 내부 동기화 토큰(SYNC_TOKEN) 입력
                FutureBuilder<String?>(
                  future: SharedPreferences.getInstance().then((p) => p.getString('kakao_internal_token')),
                  builder: (context, snapshot) {
                    final controller = ImeAwareTextEditingController(text: snapshot.data ?? '');
                    return Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: controller,
                            style: const TextStyle(color: Colors.white),
                            obscureText: true,
                            decoration: const InputDecoration(
                              labelText: '내부 동기화 토큰 (SYNC_TOKEN)',
                              labelStyle: TextStyle(color: Colors.white70),
                              hintText: '배포 서버의 SYNC_TOKEN 값을 입력하세요',
                              hintStyle: TextStyle(color: Colors.white24),
                              enabledBorder: OutlineInputBorder(
                                borderSide: BorderSide(color: Colors.white24),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderSide: BorderSide(color: Color(0xFF1976D2)),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: () async {
                            final prefs = await SharedPreferences.getInstance();
                            final value = controller.text.trim();
                            if (value.isEmpty) {
                              await prefs.remove('kakao_internal_token');
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                content: Text('내부 동기화 토큰이 제거되었습니다.', style: TextStyle(color: Colors.white)),
                                backgroundColor: Color(0xFF1976D2),
                              ));
                            } else {
                              await prefs.setString('kakao_internal_token', value);
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                content: Text('내부 동기화 토큰이 저장되었습니다.', style: TextStyle(color: Colors.white)),
                                backgroundColor: Color(0xFF1976D2),
                              ));
                            }
                            setState(() {});
                          },
                          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
                          child: const Text('저장'),
                        ),
                        const SizedBox(width: 8),
                        Icon((snapshot.data != null && (snapshot.data ?? '').isNotEmpty) ? Icons.check_circle : Icons.error_outline,
                            color: (snapshot.data != null && (snapshot.data ?? '').isNotEmpty) ? Colors.lightGreen : Colors.orangeAccent, size: 18),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                // 데이터 동기화 섹션
                const Text(
                  '데이터 동기화',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    FilledButton(
                      onPressed: () async {
                        final scaffold = ScaffoldMessenger.of(context);
                        scaffold.showSnackBar(const SnackBar(
                          content: Text('초기 동기화 재실행 중...', style: TextStyle(color: Colors.white)),
                          backgroundColor: Color(0xFF1976D2),
                          duration: Duration(milliseconds: 1200),
                        ));
                        await SyncService.instance.resetInitialSyncFlag();
                        await SyncService.instance.runInitialSyncIfNeeded();
                        scaffold.showSnackBar(const SnackBar(
                          content: Text('초기 동기화 트리거 완료', style: TextStyle(color: Colors.white)),
                          backgroundColor: Color(0xFF1976D2),
                        ));
                      },
                      style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
                      child: const Text('초기 동기화 재실행'),
                    ),
                    const SizedBox(width: 8),
                    // 학생-전화 동기화 토글(기본 off)
                    FutureBuilder<bool>(
                      future: SharedPreferences.getInstance().then((p) => p.getBool('enable_students_sync') ?? false),
                      builder: (context, snap) {
                        final enabled = snap.data ?? false;
                        return Row(children: [
                          Switch(
                            value: enabled,
                            onChanged: (v) async {
                              final prefs = await SharedPreferences.getInstance();
                              await prefs.setBool('enable_students_sync', v);
                              setState(() {});
                            },
                            activeColor: const Color(0xFF1976D2),
                          ),
                          const Text('학생/전화 동기화', style: TextStyle(color: Colors.white70)),
                        ]);
                      },
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () async {
                        final scaffold = ScaffoldMessenger.of(context);
                        scaffold.showSnackBar(const SnackBar(
                          content: Text('수동 동기화(최근 7주) 시작', style: TextStyle(color: Colors.white)),
                          backgroundColor: Color(0xFF1976D2),
                          duration: Duration(milliseconds: 800),
                        ));
                        await SyncService.instance.manualSync(days: 49);
                        scaffold.showSnackBar(const SnackBar(
                          content: Text('수동 동기화 완료', style: TextStyle(color: Colors.white)),
                          backgroundColor: Color(0xFF1976D2),
                        ));
                      },
                      style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF1976D2), side: const BorderSide(color: Color(0xFF1976D2))),
                      child: const Text('지금 동기화(7주)'),
                    ),
                  ],
                ),
                const SizedBox(height: 28),
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
                  selected: {_selectedThemeMode},
                  onSelectionChanged: (Set<ThemeMode> newSelection) {
                    setState(() {
                      _selectedThemeMode = newSelection.first;
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
                // [추가] 실행/전체화면 설정
                const SizedBox(height: 40),
                const Text(
                  '실행',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 20),
                SwitchListTile(
                  title: const Text(
                    '전체 화면',
                    style: TextStyle(color: Colors.white, fontSize: 18),
                  ),
                  subtitle: const Text(
                    '프로그램 시작시 전체화면으로 시작합니다.',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  value: _fullscreenEnabled,
                  onChanged: (bool value) async {
                    setState(() {
                      _fullscreenEnabled = value;
                      if (value) _maximizeEnabled = false; // 상호 배타
                    });
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool('fullscreen_enabled', value);
                    if (value) await prefs.setBool('maximize_enabled', false);
                  },
                  activeColor: const Color(0xFF1976D2),
                ),
                SwitchListTile(
                  title: const Text(
                    '최대창으로 시작',
                    style: TextStyle(color: Colors.white, fontSize: 18),
                  ),
                  subtitle: const Text(
                    '프로그램 시작시 최대화된 창으로 시작합니다.',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  value: _maximizeEnabled,
                  onChanged: (bool value) async {
                    setState(() {
                      _maximizeEnabled = value;
                      if (value) _fullscreenEnabled = false; // 상호 배타
                    });
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool('maximize_enabled', value);
                    if (value) await prefs.setBool('fullscreen_enabled', false);
                  },
                  activeColor: const Color(0xFF1976D2),
                ),
                const Padding(padding: EdgeInsets.only(bottom: 24)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOperatingHoursSection() {
    const double blockWidth = 100.0; // 더 좁게
    return Center(
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF18181A), // 학원 정보 컨테이너와 동일하게
          borderRadius: BorderRadius.circular(16), // 학원 정보 라운드 값과 동일하게
        ),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '운영 시간',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 14),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min, // 내부 내용만큼만 가로로
                children: DayOfWeek.values.map((day) {
                  return Container(
                    width: blockWidth,
                    margin: const EdgeInsets.only(right: 4.0),
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF18181A), // 컨테이너와 동일하게
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Color(0xFF1F1F1F), width: 3), // 아웃라인 카드 스타일(배경색)
                    ),
                    child: Center(
                      child: Text(
                        day.koreanName,
                        style: const TextStyle(
                          fontSize: 15, // 기존 14 → 15 (1pt 크게)
                          fontWeight: FontWeight.w500,
                          color: Colors.grey, // 흰색 유지
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 4,
              runSpacing: 8,
              children: DayOfWeek.values.map((day) {
                int dayIndex = day.index;
                final hasOperatingHours = _operatingHours[day] != null;
                // 마지막 30분(휴무) 요일 판별
                bool isLastThirty = false;
                if (_operatingHours[day] != null) {
                  // 전체 요일 중 가장 늦은 endTime 찾기
                  TimeOfDay? latestEnd;
                  for (var v in _operatingHours.values) {
                    if (v != null) {
                      if (latestEnd == null || v.endHour > latestEnd.hour || (v.endHour == latestEnd.hour && v.endMinute > latestEnd.minute)) {
                        latestEnd = TimeOfDay(hour: v.endHour, minute: v.endMinute);
                      }
                    }
                  }
                  // 30분 전 시간 계산
                  TimeOfDay? latestStart;
                  if (latestEnd != null) {
                    int endMinutes = latestEnd.hour * 60 + latestEnd.minute;
                    int startMinutes = endMinutes - 30;
                    latestStart = TimeOfDay(hour: startMinutes ~/ 60, minute: startMinutes % 60);
                  }
                  final range = _operatingHours[day]!;
                  if (latestStart != null && latestEnd != null &&
                      range.startHour == latestStart.hour && range.startMinute == latestStart.minute &&
                      range.endHour == latestEnd.hour && range.endMinute == latestEnd.minute) {
                    isLastThirty = true;
                  }
                }
                print('[DEBUG][UI] 렌더링 day=${day.name} index=$dayIndex hasOperatingHours=$hasOperatingHours isLastThirty=$isLastThirty range=${_operatingHours[day]}');
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 운영시간 카드
                    hasOperatingHours && !isLastThirty
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
                                      child: const Text('수정', style: TextStyle(color: Colors.white, fontSize: 13)), // 기존 12 → 13
                                      height: 32,
                                    ),
                                    PopupMenuItem(
                                      value: 'delete',
                                      child: const Text('삭제', style: TextStyle(color: Colors.white, fontSize: 13)),
                                      height: 32,
                                    ),
                                  ],
                                  color: const Color(0xFF1F1F1F),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                );
                                if (selected == 'edit') {
                                  // 운영시간 수정 다이얼로그 연결
                                  final currentRange = _operatingHours[day]!;
                                  final TimeOfDay? newStart = await showTimePicker(
                                    context: context,
                                    initialTime: TimeOfDay(hour: currentRange.startHour, minute: currentRange.startMinute),
                                    builder: (BuildContext context, Widget? child) {
                                      return Theme(
                                        data: Theme.of(context).copyWith(
                                          colorScheme: const ColorScheme(
                                            brightness: Brightness.dark,
                                            primary: Color(0xFF1976D2),
                                            onPrimary: Colors.white,
                                            secondary: Color(0xFF1976D2),
                                            onSecondary: Colors.white,
                                            error: Color(0xFFB00020),
                                            onError: Colors.white,
                                            background: Color(0xFF18181A),
                                            onBackground: Colors.white,
                                            surface: Color(0xFF18181A),
                                            onSurface: Colors.white,
                                          ),
                                          dialogBackgroundColor: const Color(0xFF18181A),
                                          timePickerTheme: const TimePickerThemeData(
                                            backgroundColor: Color(0xFF18181A),
                                            hourMinuteColor: Color(0xFF1976D2),
                                            hourMinuteTextColor: Colors.white,
                                            dialHandColor: Color(0xFF1976D2),
                                            dialBackgroundColor: Color(0xFF18181A),
                                            entryModeIconColor: Color(0xFF1976D2),
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
                                            helpTextStyle: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                            dayPeriodTextColor: Colors.white,
                                            dayPeriodColor: Color(0xFF1976D2),
                                          ),
                                        ),
                                        child: Localizations.override(
                                          context: context,
                                          locale: const Locale('ko'),
                                          delegates: [
                                            ...GlobalMaterialLocalizations.delegates,
                                          ],
                                          child: Builder(
                                            builder: (context) {
                                              return MediaQuery(
                                                data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: false),
                                        child: child!,
                                              );
                                            },
                                          ),
                                        ),
                                      );
                                    },
                                  );
                                  if (newStart == null) return;
                                  final TimeOfDay? newEnd = await showTimePicker(
                                    context: context,
                                    initialTime: TimeOfDay(hour: currentRange.endHour, minute: currentRange.endMinute),
                                    builder: (BuildContext context, Widget? child) {
                                      return Theme(
                                        data: Theme.of(context).copyWith(
                                          colorScheme: const ColorScheme(
                                            brightness: Brightness.dark,
                                            primary: Color(0xFF1976D2),
                                            onPrimary: Colors.white,
                                            secondary: Color(0xFF1976D2),
                                            onSecondary: Colors.white,
                                            error: Color(0xFFB00020),
                                            onError: Colors.white,
                                            background: Color(0xFF18181A),
                                            onBackground: Colors.white,
                                            surface: Color(0xFF18181A),
                                            onSurface: Colors.white,
                                          ),
                                          dialogBackgroundColor: const Color(0xFF18181A),
                                          timePickerTheme: const TimePickerThemeData(
                                            backgroundColor: Color(0xFF18181A),
                                            hourMinuteColor: Color(0xFF1976D2),
                                            hourMinuteTextColor: Colors.white,
                                            dialHandColor: Color(0xFF1976D2),
                                            dialBackgroundColor: Color(0xFF18181A),
                                            entryModeIconColor: Color(0xFF1976D2),
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
                                            helpTextStyle: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                            dayPeriodTextColor: Colors.white,
                                            dayPeriodColor: Color(0xFF1976D2),
                                          ),
                                        ),
                                        child: Localizations.override(
                                          context: context,
                                          locale: const Locale('ko'),
                                          delegates: [
                                            ...GlobalMaterialLocalizations.delegates,
                                          ],
                                          child: Builder(
                                            builder: (context) {
                                              return MediaQuery(
                                                data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: false),
                                        child: child!,
                                              );
                                            },
                                          ),
                                        ),
                                      );
                                    },
                                  );
                                  if (newEnd == null) return;
                                  setState(() {
                                    _operatingHours[day] = TimeRange(
                                      startHour: newStart.hour,
                                      startMinute: newStart.minute,
                                      endHour: newEnd.hour,
                                      endMinute: newEnd.minute,
                                    );
                                  });
                                  // DB 저장
                                  final List<OperatingHours> hoursList = _operatingHours.entries.where((e) => e.value != null).map((e) {
                                    final range = e.value!;
                                    final breaks = _breakTimes[e.key] ?? [];
                                    return OperatingHours(
                                      dayOfWeek: e.key.index,
                                      startHour: range.startHour,
                                      startMinute: range.startMinute,
                                      endHour: range.endHour,
                                      endMinute: range.endMinute,
                                      breakTimes: breaks.map((b) => BreakTime(
                                        startHour: b.startHour,
                                        startMinute: b.startMinute,
                                        endHour: b.endHour,
                                        endMinute: b.endMinute,
                                      )).toList(),
                                    );
                                  }).toList();
                                  await DataManager.instance.saveOperatingHours(hoursList);
                                  final hours = await DataManager.instance.getOperatingHours();
                                  setState(() {
                                    for (var d in DayOfWeek.values) {
                                      _operatingHours[d] = null;
                                      _breakTimes[d] = [];
                                    }
                                    for (var hour in hours) {
                                      final d = DayOfWeek.values[hour.dayOfWeek];
                                      _operatingHours[d] = TimeRange(
                                        startHour: hour.startHour,
                                        startMinute: hour.startMinute,
                                        endHour: hour.endHour,
                                        endMinute: hour.endMinute,
                                      );
                                      _breakTimes[d] = hour.breakTimes.map((breakTime) => TimeRange(
                                        startHour: breakTime.startHour,
                                        startMinute: breakTime.startMinute,
                                        endHour: breakTime.endHour,
                                        endMinute: breakTime.endMinute,
                                      )).toList();
                                    }
                                  });
                                  return;
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
                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                                      child: Center(
                                        child: Text(
                                          '${_formatTimeOfDay(TimeOfDay(hour: _operatingHours[day]!.startHour, minute: _operatingHours[day]!.startMinute))} - ${_formatTimeOfDay(TimeOfDay(hour: _operatingHours[day]!.endHour, minute: _operatingHours[day]!.endMinute))}',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 13, // 기존 12 → 13
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
                            height: 32,
                            margin: const EdgeInsets.only(bottom: 0),
                            padding: EdgeInsets.zero,
                            child: Center(
                              child: TextButton(
                                onPressed: () => _selectOperatingHours(context, day),
                                style: TextButton.styleFrom(
                                  foregroundColor: Color(0xFF1976D2),
                                  textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                                  padding: EdgeInsets.zero,
                                ),
                                child: const Text('휴무'),
                              ),
                            ),
                          ),
                    // 운영시간 카드와 휴식시간 카드 사이 여백
                    if ((_breakTimes[day]?.isNotEmpty ?? false) && hasOperatingHours) const SizedBox(height: 6),
                    // 휴식시간 카드들
                    ...((_breakTimes[day]?.asMap().entries ?? []).map((entry) {
                      final breakIndex = entry.key;
                      final breakTime = entry.value;
                      final breakKey = 'br${dayIndex}_$breakIndex';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 1),
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
                                  child: const Text('수정', style: TextStyle(color: Colors.white, fontSize: 12)), // 기존 11 → 12
                                  height: 28,
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: const Text('삭제', style: TextStyle(color: Colors.white, fontSize: 12)),
                                  height: 28,
                                ),
                              ],
                              color: const Color(0xFF1F1F1F),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            );
                            if (selected == 'edit') {
                              // 운영시간 등록과 동일한 스타일의 showTimePicker 2개 호출
                              final TimeOfDay? newStart = await showTimePicker(
                                context: context,
                                initialTime: TimeOfDay(hour: breakTime.startHour, minute: breakTime.startMinute),
                                builder: (BuildContext context, Widget? child) {
                                  return Theme(
                                    data: Theme.of(context).copyWith(
                                      colorScheme: const ColorScheme(
                                        brightness: Brightness.dark,
                                        primary: Color(0xFF1976D2),
                                        onPrimary: Colors.white,
                                        secondary: Color(0xFF1976D2),
                                        onSecondary: Colors.white,
                                        error: Color(0xFFB00020),
                                        onError: Colors.white,
                                        background: Color(0xFF18181A),
                                        onBackground: Colors.white,
                                        surface: Color(0xFF18181A),
                                        onSurface: Colors.white,
                                      ),
                                      dialogBackgroundColor: const Color(0xFF18181A),
                                      timePickerTheme: const TimePickerThemeData(
                                        backgroundColor: Color(0xFF18181A),
                                        hourMinuteColor: Color(0xFF1976D2),
                                        hourMinuteTextColor: Colors.white,
                                        dialHandColor: Color(0xFF1976D2),
                                        dialBackgroundColor: Color(0xFF18181A),
                                        entryModeIconColor: Color(0xFF1976D2),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
                                        helpTextStyle: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                        dayPeriodTextColor: Colors.white,
                                        dayPeriodColor: Color(0xFF1976D2),
                                      ),
                                    ),
                                    child: Localizations.override(
                                      context: context,
                                      locale: const Locale('ko'),
                                      delegates: [
                                        ...GlobalMaterialLocalizations.delegates,
                                      ],
                                      child: Builder(
                                        builder: (context) {
                                          return MediaQuery(
                                            data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: false),
                                            child: child!,
                                          );
                                        },
                                      ),
                                    ),
                                  );
                                },
                              );
                              if (newStart == null) return;
                              final TimeOfDay? newEnd = await showTimePicker(
                                context: context,
                                initialTime: TimeOfDay(hour: breakTime.endHour, minute: breakTime.endMinute),
                                builder: (BuildContext context, Widget? child) {
                                  return Theme(
                                    data: Theme.of(context).copyWith(
                                      colorScheme: const ColorScheme(
                                        brightness: Brightness.dark,
                                        primary: Color(0xFF1976D2),
                                        onPrimary: Colors.white,
                                        secondary: Color(0xFF1976D2),
                                        onSecondary: Colors.white,
                                        error: Color(0xFFB00020),
                                        onError: Colors.white,
                                        background: Color(0xFF18181A),
                                        onBackground: Colors.white,
                                        surface: Color(0xFF18181A),
                                        onSurface: Colors.white,
                                      ),
                                      dialogBackgroundColor: const Color(0xFF18181A),
                                      timePickerTheme: const TimePickerThemeData(
                                        backgroundColor: Color(0xFF18181A),
                                        hourMinuteColor: Color(0xFF1976D2),
                                        hourMinuteTextColor: Colors.white,
                                        dialHandColor: Color(0xFF1976D2),
                                        dialBackgroundColor: Color(0xFF18181A),
                                        entryModeIconColor: Color(0xFF1976D2),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
                                        helpTextStyle: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                        dayPeriodTextColor: Colors.white,
                                        dayPeriodColor: Color(0xFF1976D2),
                                      ),
                                    ),
                                    child: Localizations.override(
                                      context: context,
                                      locale: const Locale('ko'),
                                      delegates: [
                                        ...GlobalMaterialLocalizations.delegates,
                                      ],
                                      child: Builder(
                                        builder: (context) {
                                          return MediaQuery(
                                            data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: false),
                                            child: child!,
                                          );
                                        },
                                      ),
                                    ),
                                  );
                                },
                              );
                              if (newEnd == null) return;
                              setState(() {
                                final idx = _breakTimes[day]?.indexOf(breakTime) ?? -1;
                                if (idx != -1) {
                                  _breakTimes[day]![idx] = TimeRange(
                                    startHour: newStart.hour,
                                    startMinute: newStart.minute,
                                    endHour: newEnd.hour,
                                    endMinute: newEnd.minute,
                                  );
                                }
                              });
                              // DB 저장
                              final List<OperatingHours> hoursList = _operatingHours.entries.where((e) => e.value != null).map((e) {
                                final range = e.value!;
                                final breaks = _breakTimes[e.key] ?? [];
                                return OperatingHours(
                                  dayOfWeek: e.key.index,
                                  startHour: range.startHour,
                                  startMinute: range.startMinute,
                                  endHour: range.endHour,
                                  endMinute: range.endMinute,
                                  breakTimes: breaks.map((b) => BreakTime(
                                    startHour: b.startHour,
                                    startMinute: b.startMinute,
                                    endHour: b.endHour,
                                    endMinute: b.endMinute,
                                  )).toList(),
                                );
                              }).toList();
                              await DataManager.instance.saveOperatingHours(hoursList);
                            } else if (selected == 'delete') {
                              setState(() {
                                _breakTimes[day]?.remove(breakTime);
                                print('[DEBUG][휴식삭제] day=$day, _breakTimes[day]=${_breakTimes[day]?.map((b) => '${b.startHour}:${b.startMinute}~${b.endHour}:${b.endMinute}').toList()}');
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
                              padding: const EdgeInsets.fromLTRB(4, 0, 4, 3),
                              child: Center(
                                child: Text(
                                  '${_formatTimeOfDay(TimeOfDay(hour: breakTime.startHour, minute: breakTime.startMinute))} - ${_formatTimeOfDay(TimeOfDay(hour: breakTime.endHour, minute: breakTime.endMinute))}',
                                  style: const TextStyle(
                                    color: Color(0xFF1976D2),
                                    fontSize: 12, // 기존 11 → 12
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
                    if (hasOperatingHours && !isLastThirty)
                      TextButton.icon(
                        icon: const Icon(Icons.add, color: Color(0xFF1976D2), size: 15), // 기존 14 → 15
                        label: const Text('휴식', style: TextStyle(color: Color(0xFF1976D2), fontSize: 12)), // 기존 11 → 12
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF1976D2),
                          minimumSize: const Size(0, 24),
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                        ),
                        onPressed: () => _addBreakTime(day),
                      ),
                  ],
                );
              }).toList(),
            ),
          ],
        ),
      ),
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
            colorScheme: const ColorScheme(
              brightness: Brightness.dark,
              primary: Color(0xFF1976D2),
              onPrimary: Colors.white,
              secondary: Color(0xFF1976D2),
              onSecondary: Colors.white,
              error: Color(0xFFB00020),
              onError: Colors.white,
              background: Color(0xFF18181A),
              onBackground: Colors.white,
              surface: Color(0xFF18181A),
              onSurface: Colors.white,
            ),
            dialogBackgroundColor: const Color(0xFF18181A),
            timePickerTheme: const TimePickerThemeData(
              backgroundColor: Color(0xFF18181A),
              hourMinuteColor: Color(0xFF1976D2),
              hourMinuteTextColor: Colors.white,
              dialHandColor: Color(0xFF1976D2),
              dialBackgroundColor: Color(0xFF18181A),
              entryModeIconColor: Color(0xFF1976D2),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
              helpTextStyle: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              dayPeriodTextColor: Colors.white,
              dayPeriodColor: Color(0xFF1976D2),
            ),
          ),
          child: Localizations.override(
            context: context,
            locale: const Locale('ko'),
            delegates: [
              ...GlobalMaterialLocalizations.delegates,
            ],
            child: Builder(
              builder: (context) {
                return MediaQuery(
                  data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: false),
          child: child!,
        );
      },
            ),
          ),
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
              colorScheme: const ColorScheme(
                brightness: Brightness.dark,
                primary: Color(0xFF1976D2),
                onPrimary: Colors.white,
                secondary: Color(0xFF1976D2),
                onSecondary: Colors.white,
                error: Color(0xFFB00020),
                onError: Colors.white,
                background: Color(0xFF18181A),
                onBackground: Colors.white,
                surface: Color(0xFF18181A),
                onSurface: Colors.white,
              ),
              dialogBackgroundColor: const Color(0xFF18181A),
              timePickerTheme: const TimePickerThemeData(
                backgroundColor: Color(0xFF18181A),
                hourMinuteColor: Color(0xFF1976D2),
                hourMinuteTextColor: Colors.white,
                dialHandColor: Color(0xFF1976D2),
                dialBackgroundColor: Color(0xFF18181A),
                entryModeIconColor: Color(0xFF1976D2),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
                helpTextStyle: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                dayPeriodTextColor: Colors.white,
                dayPeriodColor: Color(0xFF1976D2),
              ),
            ),
            child: Localizations.override(
              context: context,
              locale: const Locale('ko'),
              delegates: [
                ...GlobalMaterialLocalizations.delegates,
              ],
              child: Builder(
                builder: (context) {
                  return MediaQuery(
                    data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: false),
            child: child!,
          );
        },
              ),
            ),
      );
        },
      );
      if (endTime != null) {
        setState(() {
          _breakTimes[day] ??= [];
          _breakTimes[day]!.add(TimeRange(
            startHour: startTime.hour,
            startMinute: startTime.minute,
            endHour: endTime.hour,
            endMinute: endTime.minute,
          ));
          print('[DEBUG][휴식추가] day=$day, _breakTimes[day]=${_breakTimes[day]?.map((b) => '${b.startHour}:${b.startMinute}~${b.endHour}:${b.endMinute}').toList()}');
        });
        // DB 저장
        final List<OperatingHours> hoursList = _operatingHours.entries.where((e) => e.value != null).map((e) {
          final range = e.value!;
          final breaks = _breakTimes[e.key] ?? [];
          return OperatingHours(
            dayOfWeek: e.key.index,
            startHour: range.startHour,
            startMinute: range.startMinute,
            endHour: range.endHour,
            endMinute: range.endMinute,
            breakTimes: breaks.map((b) => BreakTime(
              startHour: b.startHour,
              startMinute: b.startMinute,
              endHour: b.endHour,
              endMinute: b.endMinute,
            )).toList(),
          );
        }).toList();
        await DataManager.instance.saveOperatingHours(hoursList);
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
                width: 780,
                height: 600,
                child: Container(
                  height: 600,
                  margin: EdgeInsets.zero,
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
                        width: 300,
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
                      // [수정] 지불 방식과 수강 횟수를 한 줄(Row)로 배치
                      Row(
                        children: [
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
                                  child: Text('횟수제'),
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
                          const SizedBox(width: 20),
                          if (_paymentType == PaymentType.perClass)
                          SizedBox(
                            width: 290,
                            child: TextFormField(
                              controller: _courseCountController,
                              style: const TextStyle(color: Colors.white),
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(
                                  labelText: '기준 수강 횟수',
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
                      // 학원 로고 미리보기 (컨테이너 내부, 왼쪽 정렬)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 16.0, left: 8.0),
                            child: GestureDetector(
                              onTap: _pickLogoImage,
                              child: _academyLogo != null && _academyLogo!.isNotEmpty
                                  ? CircleAvatar(
                                      backgroundImage: MemoryImage(_academyLogo!),
                                      radius: 45,
                                    )
                                  : CircleAvatar(
                                      radius: 45,
                                      backgroundColor: Colors.grey[800],
                                      child: Icon(Icons.image, color: Colors.white54, size: 36),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 32),
        _buildOperatingHoursSection(),
        const SizedBox(height: 40),
        // 저장 버튼
        Stack(
          children: [
            Center(
              child: ElevatedButton(
                onPressed: () async {
                  // 모든 요일이 휴무(운영시간 없음)일 경우 저장 제한
                  if (_operatingHours.values.where((v) => v != null).isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('하나 이상의 운영시간이 등록되어야 합니다.', style: TextStyle(color: Colors.white)),
                        backgroundColor: Color(0xFF1976D2),
                      ),
                    );
                    return;
                  }
                  try {
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    print('저장 시 _paymentType:  [36m [1m [4m$_paymentType [0m');
                    print('[DEBUG] 저장 버튼 클릭: _academyLogo type= [36m${_academyLogo.runtimeType} [0m, length=${_academyLogo?.length}, isNull=${_academyLogo == null}');
                    final academySettings = AcademySettings(
                      name: _academyNameController.text.trim(),
                      slogan: _sloganController.text.trim(),
                      defaultCapacity: int.tryParse(_capacityController.text.trim()) ?? 30,
                      lessonDuration: int.tryParse(_lessonDurationController.text.trim()) ?? 50,
                      logo: _academyLogo,
                      sessionCycle: int.tryParse(_courseCountController.text.trim()) ?? 1, // [추가]
                    );
                    DataManager.instance.paymentType = _paymentType; // [수정] public setter 사용
                    await DataManager.instance.saveAcademySettings(academySettings);
                    await DataManager.instance.savePaymentType(_paymentType);
                    // 운영시간/휴식시간도 함께 저장
                    // 1. 운영시간이 있는 요일 중 가장 마지막 endTime 찾기
                    TimeOfDay? latestEnd;
                    for (var v in _operatingHours.values) {
                      if (v != null) {
                        if (latestEnd == null || v.endHour > latestEnd.hour || (v.endHour == latestEnd.hour && v.endMinute > latestEnd.minute)) {
                          latestEnd = TimeOfDay(hour: v.endHour, minute: v.endMinute);
                        }
                      }
                    }
                    // 2. 30분 전 시간 계산
                    TimeOfDay? latestStart;
                    if (latestEnd != null) {
                      int endMinutes = latestEnd.hour * 60 + latestEnd.minute;
                      int startMinutes = endMinutes - 30;
                      latestStart = TimeOfDay(hour: startMinutes ~/ 60, minute: startMinutes % 60);
                    }
                    // 3. hoursList 생성 (휴무 요일은 latestStart~latestEnd로 저장)
                    final List<OperatingHours> hoursList = DayOfWeek.values.map((day) {
                      final range = _operatingHours[day];
                      final breaks = _breakTimes[day] ?? [];
                      print('[DEBUG][저장] day=$day, breaks=${breaks.map((b) => '${b.startHour}:${b.startMinute}~${b.endHour}:${b.endMinute}').toList()}');
                      if (range != null) {
                        return OperatingHours(
                          dayOfWeek: day.index,
                          startHour: range.startHour,
                          startMinute: range.startMinute,
                          endHour: range.endHour,
                          endMinute: range.endMinute,
                          breakTimes: breaks.map((b) => BreakTime(
                            startHour: b.startHour,
                            startMinute: b.startMinute,
                            endHour: b.endHour,
                            endMinute: b.endMinute,
                          )).toList(),
                        );
                      } else if (latestStart != null && latestEnd != null) {
                        // 휴무 요일 처리: 가장 늦은 시간 30분 블록 저장
                        return OperatingHours(
                          dayOfWeek: day.index,
                          startHour: latestStart.hour,
                          startMinute: latestStart.minute,
                          endHour: latestEnd.hour,
                          endMinute: latestEnd.minute,
                        );
                      } else {
                        // 완전 초기(모든 요일 휴무) 방어
                        return null;
                      }
                    }).whereType<OperatingHours>().toList();
                    print('[DEBUG][저장] hoursList.length=${hoursList.length}');
                    for (final h in hoursList) {
                      print('[DEBUG][저장] dayOfWeek=${h.dayOfWeek}, breakTimes.length=${h.breakTimes.length}, breakTimes=${h.breakTimes.map((b) => '${b.startHour}:${b.startMinute}~${b.endHour}:${b.endMinute}').toList()}');
                    }
                    await DataManager.instance.saveOperatingHours(hoursList);
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
    return Scaffold(
      backgroundColor: const Color(0xFF1F1F1F),
      appBar: AppBarTitle(
        title: '설정',
        onBack: () {
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
        },
        onForward: () {},
        onRefresh: () => setState(() {}),
      ),
      body: Column(
        children: [
          const SizedBox(height: 0),
          SizedBox(height: 5),
          SizedBox(
            height: 48,
            child: LayoutBuilder(
              builder: (context, constraints) {
                const tabWidth = 120.0;
                final tabCount = 3; // 학원, 선생님, 일반
                final tabGap = 21.0;
                final totalWidth = tabWidth * tabCount + tabGap * (tabCount - 1);
                final leftPadding = (constraints.maxWidth - totalWidth) / 2;
                return Stack(
                  children: [
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 400),
                      curve: Curves.easeOutBack,
                      left: leftPadding + (_customTabIndex * (tabWidth + tabGap)),
                      bottom: 0,
                      child: Container(
                        width: tabWidth,
                        height: 6,
                        decoration: BoxDecoration(
                          color: Colors.blue,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: tabWidth,
                          child: TextButton(
                            onPressed: () => setState(() {
                              _prevTabIndex = _customTabIndex;
                              _customTabIndex = 0;
                              _selectedType = SettingType.academy;
                            }),
                            child: Text(
                              '학원',
                              style: TextStyle(
                                color: _customTabIndex == 0 ? Colors.blue : Colors.white70,
                                fontWeight: FontWeight.bold,
                                fontSize: 18,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: tabGap),
                        SizedBox(
                          width: tabWidth,
                          child: TextButton(
                            onPressed: () => setState(() {
                              _prevTabIndex = _customTabIndex;
                              _customTabIndex = 1;
                              _selectedType = SettingType.teachers;
                            }),
                            child: Text(
                              '선생님',
                              style: TextStyle(
                                color: _customTabIndex == 1 ? Colors.blue : Colors.white70,
                                fontWeight: FontWeight.bold,
                                fontSize: 18,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: tabGap),
                        SizedBox(
                          width: tabWidth,
                          child: TextButton(
                            onPressed: () => setState(() {
                              _prevTabIndex = _customTabIndex;
                              _customTabIndex = 2;
                              _selectedType = SettingType.general;
                            }),
                            child: Text(
                              '일반',
                              style: TextStyle(
                                color: _customTabIndex == 2 ? Colors.blue : Colors.white70,
                                fontWeight: FontWeight.bold,
                                fontSize: 18,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              switchInCurve: Curves.easeInOut,
              switchOutCurve: Curves.easeInOut,
              layoutBuilder: (Widget? currentChild, List<Widget> previousChildren) {
                return Stack(
                  alignment: Alignment.topCenter,
                  fit: StackFit.passthrough,
                  children: <Widget>[
                    ...previousChildren,
                    if (currentChild != null) currentChild,
                  ],
                );
              },
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: child,
                );
              },
              child: Builder(
                key: ValueKey(_customTabIndex),
                builder: (context) {
                  if (_customTabIndex == 0) {
                    return _buildAcademySettingsContainer();
                  } else if (_customTabIndex == 1) {
                    return _buildTeacherSettingsContainer();
                  } else {
                    return _buildGeneralSettingsContainer();
                  }
                },
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: const MainFabAlternative(),
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
            colorScheme: const ColorScheme(
              brightness: Brightness.dark,
              primary: Color(0xFF1976D2),
              onPrimary: Colors.white,
              secondary: Color(0xFF1976D2),
              onSecondary: Colors.white,
              error: Color(0xFFB00020),
              onError: Colors.white,
              background: Color(0xFF18181A),
              onBackground: Colors.white,
              surface: Color(0xFF18181A), // 프로그램 배경색
              onSurface: Colors.white,
            ),
            dialogBackgroundColor: const Color(0xFF18181A),
            timePickerTheme: const TimePickerThemeData(
              backgroundColor: Color(0xFF18181A), // 프로그램 배경색
              hourMinuteColor: Color(0xFF1976D2),
              hourMinuteTextColor: Colors.white,
              dialHandColor: Color(0xFF1976D2),
              dialBackgroundColor: Color(0xFF18181A),
              entryModeIconColor: Color(0xFF1976D2),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
              helpTextStyle: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              dayPeriodTextColor: Colors.white,
              dayPeriodColor: Color(0xFF1976D2),
            ),
          ),
          child: Localizations.override(
            context: context,
            locale: const Locale('ko'),
            delegates: [
              ...GlobalMaterialLocalizations.delegates,
            ],
            child: Builder(
              builder: (context) {
                return MediaQuery(
                  data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: false),
                  child: child!,
                );
              },
            ),
          ),
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
            colorScheme: const ColorScheme(
              brightness: Brightness.dark,
              primary: Color(0xFF1976D2),
              onPrimary: Colors.white,
              secondary: Color(0xFF1976D2),
              onSecondary: Colors.white,
              error: Color(0xFFB00020),
              onError: Colors.white,
              background: Color(0xFF18181A),
              onBackground: Colors.white,
              surface: Color(0xFF18181A), // 프로그램 배경색
              onSurface: Colors.white,
            ),
            dialogBackgroundColor: const Color(0xFF18181A),
            timePickerTheme: const TimePickerThemeData(
              backgroundColor: Color(0xFF18181A), // 프로그램 배경색
              hourMinuteColor: Color(0xFF1976D2),
              hourMinuteTextColor: Colors.white,
              dialHandColor: Color(0xFF1976D2),
              dialBackgroundColor: Color(0xFF18181A),
              entryModeIconColor: Color(0xFF1976D2),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
              helpTextStyle: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              dayPeriodTextColor: Colors.white,
              dayPeriodColor: Color(0xFF1976D2),
            ),
          ),
          child: Localizations.override(
            context: context,
            locale: const Locale('ko'),
            delegates: [
              ...GlobalMaterialLocalizations.delegates,
            ],
            child: Builder(
              builder: (context) {
                return MediaQuery(
                  data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: false),
                  child: child!,
                );
              },
            ),
          ),
        );
      },
    );
    if (endTime == null) return;
    setState(() {
      _operatingHours[day] = TimeRange(
        startHour: startTime.hour,
        startMinute: startTime.minute,
        endHour: endTime.hour,
        endMinute: endTime.minute,
      );
      print('[UI] _operatingHours after set:');
      _operatingHours.forEach((k, v) => print('  $k: $v'));
    });
    // DB 저장을 위해 전체 운영시간을 OperatingHours 리스트로 변환
    final List<OperatingHours> hoursList = _operatingHours.entries.where((e) => e.value != null).map((e) {
      final range = e.value!;
      final breaks = _breakTimes[e.key] ?? [];
      print('[UI] hoursList entry: day=$day, range=$range');
      return OperatingHours(
        dayOfWeek: e.key.index,
        startHour: range.startHour,
        startMinute: range.startMinute,
        endHour: range.endHour,
        endMinute: range.endMinute,
        breakTimes: breaks.map((b) => BreakTime(
          startHour: b.startHour,
          startMinute: b.startMinute,
          endHour: b.endHour,
          endMinute: b.endMinute,
        )).toList(),
      );
    }).toList();
    print('[UI] hoursList to save: ${hoursList.length}개');
    await DataManager.instance.saveOperatingHours(hoursList);
    final hours = await DataManager.instance.getOperatingHours();
    print('[UI] hours loaded from DB: ${hours.length}개');
    for (var h in hours) {
      print('  start= [36m${h.startHour}:${h.startMinute} [0m, end=${h.endHour}:${h.endMinute}');
    }
    setState(() {
      for (var d in DayOfWeek.values) {
        _operatingHours[d] = null;
        _breakTimes[d] = [];
      }
      for (var hour in hours) {
        final d = DayOfWeek.values[hour.dayOfWeek];
        _operatingHours[d] = TimeRange(
          startHour: hour.startHour,
          startMinute: hour.startMinute,
          endHour: hour.endHour,
          endMinute: hour.endMinute,
        );
        _breakTimes[d] = hour.breakTimes.map((breakTime) => TimeRange(
          startHour: breakTime.startHour,
          startMinute: breakTime.startMinute,
          endHour: breakTime.endHour,
          endMinute: breakTime.endMinute,
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
                      onPressed: _isOwner ? _showAddTeacherDialog : null,
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
                          // 드래그 피드백 크기 과대 표시 이슈 해결: 외부 Padding 제거
                          Widget feedback = child;
                          if (feedback is Padding) {
                            final inner = feedback.child;
                            if (inner != null) {
                              feedback = inner;
                            }
                          }
                          return Material(
                            color: Colors.transparent,
                            child: feedback,
                          );
                        },
                        onReorder: (oldIndex, newIndex) {
                          if (!_isOwner) return; // 원장만 순서 변경 가능
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
        color: const Color(0xFF1F1F1F), // 배경색을 0xFF1F1F1F로 변경
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
                    if (!_isOwner) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('원장만 수정/삭제할 수 있습니다.')));
                      return;
                    }
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
                  child: Icon(Icons.drag_handle, color: _isOwner ? Colors.white38 : Colors.white10),
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
    if (!mounted) return;
    setState(() {
      _fabBottomPadding = 80.0 + 16.0; // 스낵바 높이 + 기본 패딩
    });
  }
  void _onHideSnackBar() {
    if (!mounted) return;
    setState(() {
      _fabBottomPadding = 16.0;
    });
  }

  // 각 내용 위젯을 배경색 컨테이너로 감싸는 래퍼 추가
  Widget _buildAcademySettingsContainer() {
    return Container(
      color: const Color(0xFF1F1F1F),
      child: ScrollConfiguration(
        behavior: const ScrollBehavior(),
        child: Scrollbar(
          controller: _academyScrollController,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _academyScrollController,
            padding: const EdgeInsets.only(bottom: 24),
            physics: const AlwaysScrollableScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Align(
                  alignment: Alignment.topCenter,
                  child: _buildAcademySettings(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
  Widget _buildTeacherSettingsContainer() {
    return Container(
      color: const Color(0xFF1F1F1F),
      child: ScrollConfiguration(
        behavior: const ScrollBehavior(),
        child: Scrollbar(
          controller: _teacherScrollController,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _teacherScrollController,
            padding: const EdgeInsets.only(bottom: 24),
            physics: const AlwaysScrollableScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Align(
                  alignment: Alignment.topCenter,
                  child: _buildTeacherSettings(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
  Widget _buildGeneralSettingsContainer() {
    return Container(
      color: const Color(0xFF1F1F1F),
      child: ScrollConfiguration(
        behavior: const ScrollBehavior(),
        child: Scrollbar(
          controller: _generalScrollController,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _generalScrollController,
            padding: const EdgeInsets.only(bottom: 24),
            physics: const AlwaysScrollableScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Align(
                  alignment: Alignment.topCenter,
                  child: _buildGeneralSettings(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
} 

