import 'package:flutter/material.dart';
import '../../widgets/pill_tab_selector.dart';
import '../../models/academy_settings.dart';
import '../../models/operating_hours.dart';
import '../../services/data_manager.dart';
import '../../services/attendance_service.dart';
import '../../models/payment_type.dart';
import '../../services/academy_db.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:convert';
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
import '../../services/print_routing_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../services/tenant_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';
import 'student_archives_screen.dart';
import '../../theme/ygg_semantic_colors.dart';
import '../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';

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
  const TimeRange(
      {required this.startHour,
      required this.startMinute,
      required this.endHour,
      required this.endMinute});
}

class SettingsScreen extends StatefulWidget {
  /// Preview 전용: 기존 상단 PillTabSelector 대신 하단 중앙 FAB 스타일 탭바를 표시한다.
  /// 기본값은 false라 본앱 라우트에는 적용되지 않는다.
  final bool previewUseFabStyleTabBar;

  const SettingsScreen({
    super.key,
    this.previewUseFabStyleTabBar = false,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const Color _kSignatureGreen = Color(0xFF33A373);
  static const String _kSystemDefaultPrinterValue = '__system_default__';

  SettingType _selectedType = SettingType.academy;
  DayOfWeek? _selectedDay = DayOfWeek.monday;
  PaymentType _paymentType = PaymentType.monthly;
  // 스크롤 컨트롤러 (탭별)
  final ScrollController _academyScrollController = ScrollController();
  final ScrollController _teacherScrollController = ScrollController();
  final ScrollController _generalScrollController = ScrollController();

  // 학원 설정 컨트롤러들
  final TextEditingController _academyNameController =
      ImeAwareTextEditingController();
  final TextEditingController _academyAddressController =
      ImeAwareTextEditingController();
  final TextEditingController _sloganController =
      ImeAwareTextEditingController();
  final TextEditingController _capacityController =
      ImeAwareTextEditingController();
  final TextEditingController _lessonDurationController =
      ImeAwareTextEditingController();
  // [추가] 수강 횟수 컨트롤러
  final TextEditingController _courseCountController =
      ImeAwareTextEditingController();

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

  /// Preview — 요일별 수업 여부(스위치). 시간 등록과 분리.
  final Set<DayOfWeek> _previewOperatingDaysActive = {};

  int _customTabIndex = 0;
  int _prevTabIndex = 0;

  // 운영시간 카드 hover 상태 관리
  final Set<int> _hoveredOperatingHourCards = {};

  final GlobalKey _academyInfoKey = GlobalKey();
  final GlobalKey _previewPaymentMenuAnchorKey = GlobalKey();
  double _academyInfoHeight = 0;

  final Set<int> _hoveredTabs = {};

  // 운영시간/휴식 카드의 showActions 상태를 외부에서 관리
  final Map<String, bool> _cardActions = {};

  Uint8List? _academyLogo;

  // FAB 위치 조정용 상태 변수 추가
  double _fabBottomPadding = 16.0;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>?
      _snackBarController;

  bool _isTabAnimating = false;
  bool _fullscreenEnabled = false; // [추가] 전체화면 스위치 상태
  bool _maximizeEnabled = false; // [추가] 최대창 시작 스위치 상태
  ThemeMode _selectedThemeMode = ThemeMode.dark; // [추가] 테마 선택 상태
  bool _isOwner = false; // 원장 여부 캐시
  bool _isSuperAdmin = false; // 플랫폼 관리자 여부
  bool _resettingPlannedAll = false; // [추가] 예정 수업 전체 재생성 진행 상태
  bool _occurrenceBackfillRunning = false; // [임시] occurrence 백필 도구 실행 상태
  bool _cycleOrderBackfillRunning =
      false; // [임시] 출석 cycle/session_order 백필 도구 실행 상태
  bool _printerSettingsLoading = false;
  String _generalPrinterValue = _kSystemDefaultPrinterValue;
  String _todoPrinterValue = _kSystemDefaultPrinterValue;
  List<String> _installedPrinters = const <String>[];

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadFullscreenSetting();
    _loadPrinterRoutingSettings();
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

  String _toUiPrinterValue(String? saved) {
    final v = (saved ?? '').trim();
    return v.isEmpty ? _kSystemDefaultPrinterValue : v;
  }

  String? _fromUiPrinterValue(String? uiValue) {
    final v = (uiValue ?? '').trim();
    if (v.isEmpty || v == _kSystemDefaultPrinterValue) return null;
    return v;
  }

  List<String> _printerValuesForDropdown(String selectedValue) {
    final values = <String>[
      _kSystemDefaultPrinterValue,
      ..._installedPrinters,
    ];
    if (selectedValue != _kSystemDefaultPrinterValue &&
        !values.contains(selectedValue)) {
      values.add(selectedValue);
    }
    return values;
  }

  String _printerLabel(String value) {
    if (value == _kSystemDefaultPrinterValue) return '시스템 기본 프린터';
    if (!_installedPrinters.contains(value)) return '$value (현재 목록에 없음)';
    return value;
  }

  Future<void> _loadPrinterRoutingSettings({bool refreshList = false}) async {
    if (mounted) {
      setState(() {
        _printerSettingsLoading = true;
      });
    }
    try {
      final service = PrintRoutingService.instance;
      final generalSaved =
          await service.loadConfiguredPrinter(PrintRoutingChannel.general);
      final todoSaved =
          await service.loadConfiguredPrinter(PrintRoutingChannel.todoSheet);
      final printers = (refreshList || _installedPrinters.isEmpty)
          ? await service.listInstalledPrinters()
          : _installedPrinters;

      if (!mounted) return;
      final generalUi = _toUiPrinterValue(generalSaved);
      final todoUi = _toUiPrinterValue(todoSaved);
      setState(() {
        _installedPrinters = printers;
        _generalPrinterValue = generalUi;
        _todoPrinterValue = todoUi;
        _printerSettingsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _printerSettingsLoading = false;
      });
    }
  }

  Future<void> _savePrinterRoutingSettings({
    required PrintRoutingChannel channel,
    required String uiValue,
  }) async {
    final printerName = _fromUiPrinterValue(uiValue);
    await PrintRoutingService.instance.saveConfiguredPrinter(
      channel: channel,
      printerName: printerName,
    );
  }

  Widget _buildPrinterRoutingRow({
    required String label,
    required String selectedValue,
    required ValueChanged<String?> onChanged,
  }) {
    final options = _printerValuesForDropdown(selectedValue);
    final normalizedValue = options.contains(selectedValue)
        ? selectedValue
        : _kSystemDefaultPrinterValue;
    return Row(
      children: [
        SizedBox(
          width: 124,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ),
        Expanded(
          child: DropdownButtonFormField<String>(
            value: normalizedValue,
            isExpanded: true,
            items: [
              for (final value in options)
                DropdownMenuItem<String>(
                  value: value,
                  child: Text(
                    _printerLabel(value),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _printerSettingsLoading ? null : onChanged,
            dropdownColor: const Color(0xFF1F1F1F),
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: const InputDecoration(
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Colors.white24),
              ),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: _kSignatureGreen),
              ),
              disabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Colors.white24),
              ),
            ),
            iconEnabledColor: Colors.white70,
          ),
        ),
      ],
    );
  }

  Future<void> _loadOwnerFlag() async {
    try {
      final isOwner = await TenantService.instance.isOwnerOfActiveAcademy();
      if (!mounted) return;
      setState(() {
        _isOwner = isOwner;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isOwner = false;
      });
    }
  }

  Future<void> _loadSuperAdminFlag() async {
    try {
      final isAdmin = await TenantService.instance.isSuperAdmin();
      if (!mounted) return;
      setState(() {
        _isSuperAdmin = isAdmin;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isSuperAdmin = false;
      });
    }
  }

  Future<void> _runOccurrenceBackfillTool() async {
    if (!_isOwner && !_isSuperAdmin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('권한이 없습니다. (원장/플랫폼 관리자만 실행 가능)')),
      );
      return;
    }
    if (_occurrenceBackfillRunning) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0B1112),
        title: const Text('occurrence 백필(임시 도구)',
            style: TextStyle(
                color: Color(0xFFEAF2F2), fontWeight: FontWeight.w900)),
        content: const Text(
          '원본 회차(lesson_occurrences)를 생성/보장하고,\n'
          'attendance_records / session_overrides의 occurrence_id를 채웁니다.\n\n'
          '- 보강(replace): 원본 cycle/회차 고정\n'
          '- 추가수업(add): extra occurrence로 분리(사이클 집계 제외)\n\n'
          '데이터 양에 따라 시간이 오래 걸릴 수 있습니다.',
          style: TextStyle(
              color: Colors.white70, height: 1.35, fontWeight: FontWeight.w600),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소',
                style: TextStyle(
                    color: Colors.white70, fontWeight: FontWeight.w700)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('실행',
                style: TextStyle(
                    color: Color(0xFF33A373), fontWeight: FontWeight.w900)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _occurrenceBackfillRunning = true);

    String phase = '시작 준비 중...';
    int done = 0;
    int total = 1;
    String finalMessage = '';
    BuildContext? dialogCtx;
    StateSetter? dialogSetState;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dialogCtx = ctx;
        return StatefulBuilder(
          builder: (ctx, setStateDialog) {
            dialogSetState = setStateDialog;
            final double? v =
                (total <= 0) ? null : (done / total).clamp(0.0, 1.0);
            return AlertDialog(
              backgroundColor: const Color(0xFF0B1112),
              title: const Text('백필 진행 중',
                  style: TextStyle(
                      color: Color(0xFFEAF2F2), fontWeight: FontWeight.w900)),
              content: SizedBox(
                width: 520,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(phase,
                        style: const TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 14),
                    LinearProgressIndicator(value: v, minHeight: 6),
                    const SizedBox(height: 10),
                    Text('$done / $total',
                        style: const TextStyle(
                            color: Colors.white54,
                            fontWeight: FontWeight.w600)),
                    if (finalMessage.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(finalMessage,
                          style: const TextStyle(
                              color: Colors.white70,
                              fontWeight: FontWeight.w600)),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    try {
      // dialog build가 완료되기 전에 progress callback이 먼저 올 수 있어서 약간 대기
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final res = await AttendanceService.instance.runOccurrenceBackfillTool(
        onProgress: (p, d, t) {
          phase = p;
          done = d;
          total = t <= 0 ? 1 : t;
          dialogSetState?.call(() {});
        },
      );
      finalMessage =
          '완료: regular cycle=${res.ensuredCycles}, overrides=${res.updatedOverrides}, attendance=${res.updatedAttendance}, extra=${res.createdExtraOccurrences}';
      dialogSetState?.call(() {});
      await Future<void>.delayed(const Duration(milliseconds: 250));
    } catch (e) {
      finalMessage = '실패: $e';
      dialogSetState?.call(() {});
      await Future<void>.delayed(const Duration(milliseconds: 250));
    } finally {
      if (mounted) setState(() => _occurrenceBackfillRunning = false);
      try {
        if (dialogCtx != null) Navigator.of(dialogCtx!).pop();
      } catch (_) {}
      if (mounted && finalMessage.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(finalMessage)));
      }
    }
  }

  Future<void> _runCycleOrderBackfillTool() async {
    if (!_isOwner && !_isSuperAdmin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('권한이 없습니다. (원장/플랫폼 관리자만 실행 가능)')),
      );
      return;
    }
    if (_cycleOrderBackfillRunning) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0B1112),
        title: const Text('출석 cycle/회차 백필(임시 도구)',
            style: TextStyle(
                color: Color(0xFFEAF2F2), fontWeight: FontWeight.w900)),
        content: const Text(
          '모든 학생의 attendance_records에 대해 cycle/session_order를 재계산합니다.\n\n'
          '- 등록일자 이전(class_date_time < registration_date) 기록은 cycle/session_order를 null로 비웁니다.\n'
          '- 결제 사이클 내 수업을 시간순(+set_id tie-break)으로 나열한 값을 회차로 사용합니다.\n'
          '- 보강(replace)은 원본 시간 기준으로 계산합니다.\n\n'
          '⚠️ 대량 업데이트로 인해 updated_at/version이 변경됩니다.\n'
          '실행 중에는 다른 기기에서 출석/시간표 편집을 피해주세요.',
          style: TextStyle(
              color: Colors.white70, height: 1.35, fontWeight: FontWeight.w600),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소',
                style: TextStyle(
                    color: Colors.white70, fontWeight: FontWeight.w700)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('실행',
                style: TextStyle(
                    color: Color(0xFF33A373), fontWeight: FontWeight.w900)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _cycleOrderBackfillRunning = true);

    String phase = '시작 준비 중...';
    int done = 0;
    int total = 1;
    String finalMessage = '';
    BuildContext? dialogCtx;
    StateSetter? dialogSetState;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        dialogCtx = ctx;
        return StatefulBuilder(
          builder: (ctx, setStateDialog) {
            dialogSetState = setStateDialog;
            final double? v =
                (total <= 0) ? null : (done / total).clamp(0.0, 1.0);
            return AlertDialog(
              backgroundColor: const Color(0xFF0B1112),
              title: const Text('백필 진행 중',
                  style: TextStyle(
                      color: Color(0xFFEAF2F2), fontWeight: FontWeight.w900)),
              content: SizedBox(
                width: 520,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(phase,
                        style: const TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 14),
                    LinearProgressIndicator(value: v, minHeight: 6),
                    const SizedBox(height: 10),
                    Text('$done / $total',
                        style: const TextStyle(
                            color: Colors.white54,
                            fontWeight: FontWeight.w600)),
                    if (finalMessage.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(finalMessage,
                          style: const TextStyle(
                              color: Colors.white70,
                              fontWeight: FontWeight.w600)),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    try {
      final res =
          await AttendanceService.instance.runCycleSessionOrderBackfillTool(
        pastDays: 365 * 2,
        futureDays: 365,
        onProgress: (p, d, t) {
          phase = p;
          done = d;
          total = t;
          dialogSetState?.call(() {});
        },
      );
      finalMessage =
          '스캔: ${res.scanned}건\n업데이트: ${res.updated}건\n등록일 이전 null 처리: ${res.clearedBeforeRegistration}건';
      dialogSetState?.call(() {});
      await Future.delayed(const Duration(milliseconds: 350));
    } catch (e) {
      finalMessage = '실패: $e';
      dialogSetState?.call(() {});
    } finally {
      if (mounted) setState(() => _cycleOrderBackfillRunning = false);
      if (dialogCtx != null && Navigator.of(dialogCtx!).canPop()) {
        Navigator.of(dialogCtx!).pop();
      }
      if (mounted && finalMessage.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(finalMessage)));
      }
    }
  }

  @override
  void dispose() {
    _academyNameController.dispose();
    _academyAddressController.dispose();
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
        _academyAddressController.text =
            DataManager.instance.academySettings.address;
        _sloganController.text = DataManager.instance.academySettings.slogan;
        if (widget.previewUseFabStyleTabBar) {
          _capacityController.text = '';
          _lessonDurationController.text = '';
        } else {
          _capacityController.text =
              DataManager.instance.academySettings.defaultCapacity.toString();
          _lessonDurationController.text =
              DataManager.instance.academySettings.lessonDuration.toString();
        }
        _courseCountController.text = DataManager
            .instance.academySettings.sessionCycle
            .toString(); // [추가] 수강 횟수 불러오기
        _paymentType = DataManager.instance.paymentType; // [보완] 결제 방식 불러오기
        final logo = DataManager.instance.academySettings.logo;
        _academyLogo = (logo is Uint8List && logo.isNotEmpty) ? logo : null;
        print(
            '[DEBUG] _loadSettings: 불러온 logo type=${logo?.runtimeType}, length=${logo?.length}, isNull=${logo == null}');
      });

      // 운영 시간 로드
      final hours = await DataManager.instance.getOperatingHours();
      print('[DEBUG][LOAD] DB에서 불러온 hours:');
      for (final h in hours) {
        print(
            '  dayOfWeek= [36m${h.dayOfWeek} [0m start=${h.startHour}:${h.startMinute} end=${h.endHour}:${h.endMinute}');
      }
      setState(() {
        for (var d in DayOfWeek.values) {
          _operatingHours[d] = null;
          _breakTimes[d] = [];
        }
        for (var hour in hours) {
          final d = DayOfWeek.values[hour.dayOfWeek];
          print(
              '[DEBUG][MAPPING] hour.dayOfWeek=${hour.dayOfWeek} → DayOfWeek.${d.name}');
          _operatingHours[d] = TimeRange(
            startHour: hour.startHour,
            startMinute: hour.startMinute,
            endHour: hour.endHour,
            endMinute: hour.endMinute,
          );
          _breakTimes[d] = hour.breakTimes
              .map((breakTime) => TimeRange(
                    startHour: breakTime.startHour,
                    startMinute: breakTime.startMinute,
                    endHour: breakTime.endHour,
                    endMinute: breakTime.endMinute,
                  ))
              .toList();
        }
        print('[DEBUG][MAPPING] 최종 _operatingHours:');
        _operatingHours.forEach((k, v) => print('  ${k.name}: $v'));
        _syncPreviewOperatingDaysActiveFromHours();
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
                          child: Text(text,
                              style: const TextStyle(color: Colors.white60)),
                        );
                      },
                    ),
                    FilledButton.icon(
                      onPressed: () async {
                        await UpdateService.oneClickUpdate(context);
                      },
                      style: FilledButton.styleFrom(
                          backgroundColor: _kSignatureGreen),
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('업데이트 확인'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Padding(
                  padding: EdgeInsets.only(top: 24),
                  child: Text(
                    '프린터',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1F1F1F),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '자동 인쇄 프린터를 일반 출력/알림장으로 분리합니다.',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          OutlinedButton.icon(
                            onPressed: _printerSettingsLoading
                                ? null
                                : () async {
                                    await _loadPrinterRoutingSettings(
                                      refreshList: true,
                                    );
                                    if (!mounted) return;
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          '프린터 목록을 새로고침했습니다.',
                                          style: TextStyle(color: Colors.white),
                                        ),
                                        backgroundColor: _kSignatureGreen,
                                      ),
                                    );
                                  },
                            style: OutlinedButton.styleFrom(
                              foregroundColor: _kSignatureGreen,
                              side: const BorderSide(color: _kSignatureGreen),
                            ),
                            icon: _printerSettingsLoading
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: _kSignatureGreen,
                                    ),
                                  )
                                : const Icon(Icons.refresh, size: 16),
                            label: const Text('새로고침'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _buildPrinterRoutingRow(
                        label: '일반 인쇄',
                        selectedValue: _generalPrinterValue,
                        onChanged: (value) async {
                          if (value == null) return;
                          setState(() {
                            _generalPrinterValue = value;
                          });
                          await _savePrinterRoutingSettings(
                            channel: PrintRoutingChannel.general,
                            uiValue: value,
                          );
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                '일반 인쇄 프린터가 저장되었습니다.',
                                style: TextStyle(color: Colors.white),
                              ),
                              backgroundColor: _kSignatureGreen,
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 10),
                      _buildPrinterRoutingRow(
                        label: '알림장 인쇄',
                        selectedValue: _todoPrinterValue,
                        onChanged: (value) async {
                          if (value == null) return;
                          setState(() {
                            _todoPrinterValue = value;
                          });
                          await _savePrinterRoutingSettings(
                            channel: PrintRoutingChannel.todoSheet,
                            uiValue: value,
                          );
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                '알림장 인쇄 프린터가 저장되었습니다.',
                                style: TextStyle(color: Colors.white),
                              ),
                              backgroundColor: _kSignatureGreen,
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '설정은 현재 PC에만 저장됩니다.',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.6),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // [임시] 관리 도구
                if (_isOwner || _isSuperAdmin) ...[
                  const Padding(
                    padding: EdgeInsets.only(top: 24),
                    child: Text(
                      '관리 도구(임시)',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1F1F1F),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '원본 회차(occurrence) 백필',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                'lesson_occurrences 생성 + attendance/session_overrides occurrence_id 채움\n'
                                '(보강은 원본 cycle 귀속, 추가수업은 extra로 분리)',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: _occurrenceBackfillRunning
                              ? null
                              : () async => _runOccurrenceBackfillTool(),
                          style: FilledButton.styleFrom(
                              backgroundColor: _kSignatureGreen),
                          child: _occurrenceBackfillRunning
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white),
                                )
                              : const Text('실행'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1F1F1F),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '출석 cycle/회차 백필',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                'attendance_records의 cycle/session_order를 재계산\n'
                                '(등록일 이전은 null, 결제 사이클 내 시간순 정렬 기반)',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: _cycleOrderBackfillRunning
                              ? null
                              : () async => _runCycleOrderBackfillTool(),
                          style: FilledButton.styleFrom(
                              backgroundColor: _kSignatureGreen),
                          child: _cycleOrderBackfillRunning
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white),
                                )
                              : const Text('실행'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
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
                      return res != null &&
                          (res['config_value'] as String? ?? '').isNotEmpty;
                    } catch (_) {
                      return false;
                    }
                  }(),
                  builder: (context, snapshot) {
                    final hasApiKey = snapshot.data ?? false;
                    return FutureBuilder<bool>(
                      future: SharedPreferences.getInstance().then(
                          (p) => p.getBool('ai_summary_enabled') ?? false),
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
                                        color: hasApiKey
                                            ? Colors.white70
                                            : Colors.amber,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Switch.adaptive(
                                value: hasApiKey && isEnabled,
                                onChanged: hasApiKey
                                    ? (value) async {
                                        final p = await SharedPreferences
                                            .getInstance();
                                        await p.setBool(
                                            'ai_summary_enabled', value);
                                        setState(() {});
                                      }
                                    : null,
                                activeColor: _kSignatureGreen,
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
                  future: SharedPreferences.getInstance()
                      .then((p) => p.getString('kakao_api_base_url')),
                  builder: (context, snapshot) {
                    final controller = ImeAwareTextEditingController(
                        text: snapshot.data ?? '');
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
                                borderSide: BorderSide(color: _kSignatureGreen),
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
                              ScaffoldMessenger.of(context)
                                  .showSnackBar(const SnackBar(
                                content: Text('서버 주소가 제거되었습니다.',
                                    style: TextStyle(color: Colors.white)),
                                backgroundColor: _kSignatureGreen,
                              ));
                            } else {
                              await prefs.setString(
                                  'kakao_api_base_url', value);
                              ScaffoldMessenger.of(context)
                                  .showSnackBar(const SnackBar(
                                content: Text('서버 주소가 저장되었습니다.',
                                    style: TextStyle(color: Colors.white)),
                                backgroundColor: _kSignatureGreen,
                              ));
                            }
                            setState(() {});
                          },
                          style: FilledButton.styleFrom(
                              backgroundColor: _kSignatureGreen),
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
                  future: SharedPreferences.getInstance()
                      .then((p) => p.getString('survey_base_url')),
                  builder: (context, snapshot) {
                    final controller = ImeAwareTextEditingController(
                        text: snapshot.data ?? 'http://localhost:5173');
                    return Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: controller,
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              labelText:
                                  '설문 웹 주소 (예: http://localhost:5173 또는 배포 URL)',
                              labelStyle: TextStyle(color: Colors.white70),
                              hintText: '설문 웹의 기본 주소를 입력하세요',
                              hintStyle: TextStyle(color: Colors.white24),
                              enabledBorder: OutlineInputBorder(
                                borderSide: BorderSide(color: Colors.white24),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderSide: BorderSide(color: _kSignatureGreen),
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
                            ScaffoldMessenger.of(context)
                                .showSnackBar(const SnackBar(
                              content: Text('설문 웹 주소가 저장되었습니다.',
                                  style: TextStyle(color: Colors.white)),
                              backgroundColor: _kSignatureGreen,
                            ));
                            setState(() {});
                          },
                          style: FilledButton.styleFrom(
                              backgroundColor: _kSignatureGreen),
                          child: const Text('저장'),
                        ),
                      ],
                    );
                  },
                ),
                // API 토큰 입력
                FutureBuilder<String?>(
                  future: SharedPreferences.getInstance()
                      .then((p) => p.getString('kakao_api_token')),
                  builder: (context, snapshot) {
                    final controller = ImeAwareTextEditingController(
                        text: snapshot.data ?? '');
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
                                borderSide: BorderSide(color: _kSignatureGreen),
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
                              ScaffoldMessenger.of(context)
                                  .showSnackBar(const SnackBar(
                                content: Text('API 토큰이 제거되었습니다.',
                                    style: TextStyle(color: Colors.white)),
                                backgroundColor: _kSignatureGreen,
                              ));
                            } else {
                              await prefs.setString('kakao_api_token', value);
                              ScaffoldMessenger.of(context)
                                  .showSnackBar(const SnackBar(
                                content: Text('API 토큰이 저장되었습니다.',
                                    style: TextStyle(color: Colors.white)),
                                backgroundColor: _kSignatureGreen,
                              ));
                            }
                            setState(() {});
                          },
                          style: FilledButton.styleFrom(
                              backgroundColor: _kSignatureGreen),
                          child: const Text('저장'),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                            (snapshot.data != null &&
                                    (snapshot.data ?? '').isNotEmpty)
                                ? Icons.check_circle
                                : Icons.error_outline,
                            color: (snapshot.data != null &&
                                    (snapshot.data ?? '').isNotEmpty)
                                ? Colors.lightGreen
                                : Colors.orangeAccent,
                            size: 18),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
                // 내부 동기화 토큰(SYNC_TOKEN) 입력
                FutureBuilder<String?>(
                  future: SharedPreferences.getInstance()
                      .then((p) => p.getString('kakao_internal_token')),
                  builder: (context, snapshot) {
                    final controller = ImeAwareTextEditingController(
                        text: snapshot.data ?? '');
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
                                borderSide: BorderSide(color: _kSignatureGreen),
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
                              ScaffoldMessenger.of(context)
                                  .showSnackBar(const SnackBar(
                                content: Text('내부 동기화 토큰이 제거되었습니다.',
                                    style: TextStyle(color: Colors.white)),
                                backgroundColor: _kSignatureGreen,
                              ));
                            } else {
                              await prefs.setString(
                                  'kakao_internal_token', value);
                              ScaffoldMessenger.of(context)
                                  .showSnackBar(const SnackBar(
                                content: Text('내부 동기화 토큰이 저장되었습니다.',
                                    style: TextStyle(color: Colors.white)),
                                backgroundColor: _kSignatureGreen,
                              ));
                            }
                            setState(() {});
                          },
                          style: FilledButton.styleFrom(
                              backgroundColor: _kSignatureGreen),
                          child: const Text('저장'),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                            (snapshot.data != null &&
                                    (snapshot.data ?? '').isNotEmpty)
                                ? Icons.check_circle
                                : Icons.error_outline,
                            color: (snapshot.data != null &&
                                    (snapshot.data ?? '').isNotEmpty)
                                ? Colors.lightGreen
                                : Colors.orangeAccent,
                            size: 18),
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
                          content: Text('초기 동기화 재실행 중...',
                              style: TextStyle(color: Colors.white)),
                          backgroundColor: _kSignatureGreen,
                          duration: Duration(milliseconds: 1200),
                        ));
                        await SyncService.instance.resetInitialSyncFlag();
                        await SyncService.instance.runInitialSyncIfNeeded();
                        scaffold.showSnackBar(const SnackBar(
                          content: Text('초기 동기화 트리거 완료',
                              style: TextStyle(color: Colors.white)),
                          backgroundColor: _kSignatureGreen,
                        ));
                      },
                      style: FilledButton.styleFrom(
                          backgroundColor: _kSignatureGreen),
                      child: const Text('초기 동기화 재실행'),
                    ),
                    const SizedBox(width: 8),
                    // 학생-전화 동기화 토글(기본 off)
                    FutureBuilder<bool>(
                      future: SharedPreferences.getInstance().then(
                          (p) => p.getBool('enable_students_sync') ?? false),
                      builder: (context, snap) {
                        final enabled = snap.data ?? false;
                        return Row(children: [
                          Switch(
                            value: enabled,
                            onChanged: (v) async {
                              final prefs =
                                  await SharedPreferences.getInstance();
                              await prefs.setBool('enable_students_sync', v);
                              setState(() {});
                            },
                            activeColor: _kSignatureGreen,
                          ),
                          const Text('학생/전화 동기화',
                              style: TextStyle(color: Colors.white70)),
                        ]);
                      },
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () async {
                        final scaffold = ScaffoldMessenger.of(context);
                        scaffold.showSnackBar(const SnackBar(
                          content: Text('수동 동기화(최근 7주) 시작',
                              style: TextStyle(color: Colors.white)),
                          backgroundColor: _kSignatureGreen,
                          duration: Duration(milliseconds: 800),
                        ));
                        await SyncService.instance.manualSync(days: 49);
                        scaffold.showSnackBar(const SnackBar(
                          content: Text('수동 동기화 완료',
                              style: TextStyle(color: Colors.white)),
                          backgroundColor: _kSignatureGreen,
                        ));
                      },
                      style: OutlinedButton.styleFrom(
                          foregroundColor: _kSignatureGreen,
                          side: const BorderSide(color: _kSignatureGreen)),
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
                    backgroundColor:
                        MaterialStateProperty.all(Colors.transparent),
                    foregroundColor: MaterialStateProperty.resolveWith<Color>(
                      (Set<MaterialState> states) {
                        if (states.contains(MaterialState.selected)) {
                          return Colors.white;
                        }
                        return Colors.white70;
                      },
                    ),
                    textStyle: MaterialStateProperty.all(
                      const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w500),
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
                        borderSide:
                            BorderSide(color: Colors.white.withOpacity(0.3)),
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: _kSignatureGreen),
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
                  activeColor: _kSignatureGreen,
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
                  activeColor: _kSignatureGreen,
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
                  activeColor: _kSignatureGreen,
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
                  activeColor: _kSignatureGreen,
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
                  activeColor: _kSignatureGreen,
                ),
                const SizedBox(height: 40),
                const Text(
                  '데이터',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1F1F1F),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Expanded(
                        child: Text(
                          '모든 학생의 "순수 예정 수업"(is_planned=true, 출석/등원 기록 없는 것)만 전부 삭제한 뒤,\n'
                          '현재 시간표(student_time_blocks)를 기준으로 예정 수업을 다시 생성합니다.\n'
                          '※ 시간이 오래 걸릴 수 있습니다.',
                          style: TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                              height: 1.35),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed: _resettingPlannedAll
                            ? null
                            : () async {
                                if (!(_isOwner || _isSuperAdmin)) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text('원장/관리자만 실행할 수 있습니다.')),
                                  );
                                  return;
                                }
                                final ok = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    backgroundColor: const Color(0xFF0B1112),
                                    title: const Text('예정 수업 전체 재생성',
                                        style: TextStyle(
                                            color: Color(0xFFEAF2F2),
                                            fontWeight: FontWeight.w900)),
                                    content: const Text(
                                      '모든 학생의 순수 예정 수업을 삭제하고 앞으로 15일치만 다시 생성합니다.\n'
                                      '출석/등원/하원 기록이 있는 행은 삭제하지 않습니다.\n\n'
                                      '진행할까요?',
                                      style: TextStyle(
                                          color: Colors.white70,
                                          fontWeight: FontWeight.w600,
                                          height: 1.35),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(ctx).pop(false),
                                        child: const Text('취소',
                                            style: TextStyle(
                                                color: Colors.white70,
                                                fontWeight: FontWeight.w700)),
                                      ),
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(ctx).pop(true),
                                        child: const Text('재생성',
                                            style: TextStyle(
                                                color: Color(0xFF33A373),
                                                fontWeight: FontWeight.w900)),
                                      ),
                                    ],
                                  ),
                                );
                                if (ok != true) return;
                                setState(() => _resettingPlannedAll = true);
                                try {
                                  await DataManager.instance
                                      .resetPlannedAttendanceForAllStudents(
                                          days: 15);
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content: Text('예정 수업이 재생성되었습니다.')),
                                    );
                                  }
                                } catch (e) {
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('재생성 실패: $e')),
                                    );
                                  }
                                } finally {
                                  if (mounted)
                                    setState(
                                        () => _resettingPlannedAll = false);
                                }
                              },
                        style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFB74C4C)),
                        icon: _resettingPlannedAll
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.refresh, size: 18),
                        label: const Text('예정 전체 재생성'),
                      ),
                    ],
                  ),
                ),
                const Padding(padding: EdgeInsets.only(bottom: 24)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _previewOperatingHoursTimeLabel(DayOfWeek day) {
    final range = _operatingHours[day];
    if (range == null || _isLastThirtyMarkerDay(day)) {
      return '';
    }
    final start = _formatTimeOfDay(
      TimeOfDay(hour: range.startHour, minute: range.startMinute),
    );
    final end = _formatTimeOfDay(
      TimeOfDay(hour: range.endHour, minute: range.endMinute),
    );
    final breaks = _breakTimes[day] ?? [];
    if (breaks.isEmpty) {
      return '$start - $end';
    }
    final breakSummary = breaks
        .map(
          (b) =>
              '${_formatTimeOfDay(TimeOfDay(hour: b.startHour, minute: b.startMinute))}-${_formatTimeOfDay(TimeOfDay(hour: b.endHour, minute: b.endMinute))}',
        )
        .join(', ');
    return '$start - $end · 휴식 $breakSummary';
  }

  String _previewOperatingHoursText(DayOfWeek day) {
    final timeLabel = _previewOperatingHoursTimeLabel(day);
    return timeLabel.isEmpty ? '휴무' : timeLabel;
  }

  void _syncPreviewOperatingDaysActiveFromHours() {
    _previewOperatingDaysActive.clear();
    for (final day in DayOfWeek.values) {
      final range = _operatingHours[day];
      if (range != null && !_isLastThirtyMarkerDay(day)) {
        _previewOperatingDaysActive.add(day);
      }
    }
  }

  bool _previewOperatingDayIsActive(DayOfWeek day) {
    return _previewOperatingDaysActive.contains(day);
  }

  Widget _buildPreviewOperatingHoursSection(
    PreviewAcademyPanelStyle previewStyle,
  ) {
    final switchInactive = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF3A3A3C)
        : const Color(0xFFE5E5EA);

    final rows = DayOfWeek.values.map((day) {
      final isActive = _previewOperatingDayIsActive(day);
      final timeLabel = _previewOperatingHoursTimeLabel(day);
      return PreviewAcademyInfoRow(
        label: day.koreanName,
        value: '',
        suppressInkHighlight: true,
        valueWidget: isActive
            ? Row(
                mainAxisAlignment: MainAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      timeLabel.isEmpty ? '시간' : timeLabel,
                      textAlign: TextAlign.right,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: FabTabBarTokens.previewRowValueStyle(previewStyle)
                          .copyWith(
                        color: timeLabel.isEmpty
                            ? previewStyle.hint
                            : previewStyle.rowValue,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.chevron_right,
                    size: FabTabBarTokens.previewAcademyChevronSize,
                    color: previewStyle.chevron,
                  ),
                ],
              )
            : const SizedBox.shrink(),
        onTap: isActive
            ? () => _selectOperatingHours(context, day)
            : null,
        showChevron: false,
        trailing: PreviewAcademyIosSwitch(
          key: ValueKey('preview-hours-switch-${day.name}'),
          value: isActive,
          inactiveColor: switchInactive,
          onChanged: (enabled) {
            setState(() {
              if (enabled) {
                _previewOperatingDaysActive.add(day);
              } else {
                _previewOperatingDaysActive.remove(day);
                _operatingHours[day] = null;
                _breakTimes[day] = [];
              }
            });
          },
        ),
      );
    }).toList();

    final horizontalInset =
        FabTabBarTokens.previewAcademyGroupedRowPaddingHorizontal;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalInset),
          child: Row(
            children: [
              Text(
                '운영 시간',
                style: FabTabBarTokens.previewSectionTitleStyle(previewStyle)
                    .copyWith(color: previewStyle.hint),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _promptAddBreakTime,
                style: TextButton.styleFrom(
                  foregroundColor: FabTabBarTokens.previewConfirmActionColor,
                  minimumSize: Size.zero,
                  padding: EdgeInsets.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(
                  Icons.add,
                  size: 18,
                  color: FabTabBarTokens.previewConfirmActionColor,
                ),
                label: const Text(
                  '휴식',
                  style: TextStyle(
                    color: FabTabBarTokens.previewConfirmActionColor,
                    fontSize: FabTabBarTokens.previewAcademyBaseFontSize,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(
          height: FabTabBarTokens.previewAcademySectionHeaderToCardSpacing,
        ),
        PreviewAcademyGroupedFieldsCard(
          style: previewStyle,
          rows: rows,
        ),
      ],
    );
  }

  String _previewPaymentTypeLabel(PaymentType type) {
    switch (type) {
      case PaymentType.monthly:
        return '월결제';
      case PaymentType.perClass:
        return '횟수제';
    }
  }

  Widget _buildOperatingHoursSection() {
    final isPreview = widget.previewUseFabStyleTabBar;
    final previewStyle = isPreview ? _previewAcademyPanelStyle(context) : null;
    if (isPreview && previewStyle != null) {
      return _buildPreviewOperatingHoursSection(previewStyle);
    }

    final sectionWidth = 780.0;
    final blockWidth = isPreview ? 105.0 : 100.0;
    final containerColor = isPreview
        ? previewStyle!.groupedCardBackground
        : const Color(0xFF18181A);
    final containerRadius = isPreview
        ? FabTabBarTokens.previewAcademyGroupedCardRadius
        : 16.0;
    final horizontalPadding = isPreview
        ? FabTabBarTokens.previewAcademyGroupedRowPaddingHorizontal
        : 28.0;

    final hoursCard = Container(
      width: isPreview ? double.infinity : null,
      decoration: BoxDecoration(
        color: containerColor,
        borderRadius: BorderRadius.circular(containerRadius),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: horizontalPadding,
        vertical: 24,
      ),
      child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      '운영 시간',
                      style: isPreview
                          ? FabTabBarTokens.previewSectionTitleStyle(
                              previewStyle!,
                            )
                          : const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w500,
                            ),
                    ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _promptAddBreakTime,
                    icon: const Icon(Icons.add,
                        color: _kSignatureGreen, size: 18),
                    label: Text(
                      '휴식',
                      style: TextStyle(
                        color: _kSignatureGreen,
                        fontSize: isPreview
                            ? FabTabBarTokens.previewAcademyBaseFontSize
                            : 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: _kSignatureGreen,
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                    ),
                  ),
                ],
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
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFF18181A), // 컨테이너와 동일하게
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: Color(0xFF1F1F1F),
                            width: 3), // 아웃라인 카드 스타일(배경색)
                      ),
                      child: Center(
                        child: Text(
                          day.koreanName,
                          style: isPreview
                              ? FabTabBarTokens.previewBodyTextStyle(
                                  previewStyle!,
                                  color: previewStyle.hint,
                                  fontWeight: FontWeight.w500,
                                )
                              : const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                  color: Colors.grey,
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
                        if (latestEnd == null ||
                            v.endHour > latestEnd.hour ||
                            (v.endHour == latestEnd.hour &&
                                v.endMinute > latestEnd.minute)) {
                          latestEnd =
                              TimeOfDay(hour: v.endHour, minute: v.endMinute);
                        }
                      }
                    }
                    // 30분 전 시간 계산
                    TimeOfDay? latestStart;
                    if (latestEnd != null) {
                      int endMinutes = latestEnd.hour * 60 + latestEnd.minute;
                      int startMinutes = endMinutes - 30;
                      latestStart = TimeOfDay(
                          hour: startMinutes ~/ 60, minute: startMinutes % 60);
                    }
                    final range = _operatingHours[day]!;
                    if (latestStart != null &&
                        latestEnd != null &&
                        range.startHour == latestStart.hour &&
                        range.startMinute == latestStart.minute &&
                        range.endHour == latestEnd.hour &&
                        range.endMinute == latestEnd.minute) {
                      isLastThirty = true;
                    }
                  }
                  print(
                      '[DEBUG][UI] 렌더링 day=${day.name} index=$dayIndex hasOperatingHours=$hasOperatingHours isLastThirty=$isLastThirty range=${_operatingHours[day]}');
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 운영시간 카드
                      hasOperatingHours && !isLastThirty
                          ? MouseRegion(
                              cursor: SystemMouseCursors.click,
                              onEnter: (_) => setState(() =>
                                  _hoveredOperatingHourCards.add(dayIndex)),
                              onExit: (_) => setState(() =>
                                  _hoveredOperatingHourCards.remove(dayIndex)),
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
                                        child: const Text('수정',
                                            style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 13)), // 기존 12 → 13
                                        height: 32,
                                      ),
                                      PopupMenuItem(
                                        value: 'delete',
                                        child: const Text('삭제',
                                            style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 13)),
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
                                    final TimeOfDay? newStart =
                                        await showTimePicker(
                                      context: context,
                                      initialTime: TimeOfDay(
                                          hour: currentRange.startHour,
                                          minute: currentRange.startMinute),
                                      builder: (BuildContext context,
                                          Widget? child) {
                                        return Theme(
                                          data: Theme.of(context).copyWith(
                                            colorScheme: const ColorScheme(
                                              brightness: Brightness.dark,
                                              primary: _kSignatureGreen,
                                              onPrimary: Colors.white,
                                              secondary: _kSignatureGreen,
                                              onSecondary: Colors.white,
                                              error: Color(0xFFB00020),
                                              onError: Colors.white,
                                              background: Color(0xFF18181A),
                                              onBackground: Colors.white,
                                              surface: Color(0xFF18181A),
                                              onSurface: Colors.white,
                                            ),
                                            dialogBackgroundColor:
                                                const Color(0xFF18181A),
                                            timePickerTheme:
                                                const TimePickerThemeData(
                                              backgroundColor:
                                                  Color(0xFF18181A),
                                              hourMinuteColor: _kSignatureGreen,
                                              hourMinuteTextColor: Colors.white,
                                              dialHandColor: _kSignatureGreen,
                                              dialBackgroundColor:
                                                  Color(0xFF18181A),
                                              entryModeIconColor:
                                                  _kSignatureGreen,
                                              shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.all(
                                                          Radius.circular(24))),
                                              helpTextStyle: TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.bold),
                                              dayPeriodTextColor: Colors.white,
                                              dayPeriodColor: _kSignatureGreen,
                                            ),
                                          ),
                                          child: Localizations.override(
                                            context: context,
                                            locale: const Locale('ko'),
                                            delegates: [
                                              ...GlobalMaterialLocalizations
                                                  .delegates,
                                            ],
                                            child: Builder(
                                              builder: (context) {
                                                return MediaQuery(
                                                  data: MediaQuery.of(context)
                                                      .copyWith(
                                                          alwaysUse24HourFormat:
                                                              false),
                                                  child: child!,
                                                );
                                              },
                                            ),
                                          ),
                                        );
                                      },
                                    );
                                    if (newStart == null) return;
                                    final TimeOfDay? newEnd =
                                        await showTimePicker(
                                      context: context,
                                      initialTime: TimeOfDay(
                                          hour: currentRange.endHour,
                                          minute: currentRange.endMinute),
                                      builder: (BuildContext context,
                                          Widget? child) {
                                        return Theme(
                                          data: Theme.of(context).copyWith(
                                            colorScheme: const ColorScheme(
                                              brightness: Brightness.dark,
                                              primary: _kSignatureGreen,
                                              onPrimary: Colors.white,
                                              secondary: _kSignatureGreen,
                                              onSecondary: Colors.white,
                                              error: Color(0xFFB00020),
                                              onError: Colors.white,
                                              background: Color(0xFF18181A),
                                              onBackground: Colors.white,
                                              surface: Color(0xFF18181A),
                                              onSurface: Colors.white,
                                            ),
                                            dialogBackgroundColor:
                                                const Color(0xFF18181A),
                                            timePickerTheme:
                                                const TimePickerThemeData(
                                              backgroundColor:
                                                  Color(0xFF18181A),
                                              hourMinuteColor: _kSignatureGreen,
                                              hourMinuteTextColor: Colors.white,
                                              dialHandColor: _kSignatureGreen,
                                              dialBackgroundColor:
                                                  Color(0xFF18181A),
                                              entryModeIconColor:
                                                  _kSignatureGreen,
                                              shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.all(
                                                          Radius.circular(24))),
                                              helpTextStyle: TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.bold),
                                              dayPeriodTextColor: Colors.white,
                                              dayPeriodColor: _kSignatureGreen,
                                            ),
                                          ),
                                          child: Localizations.override(
                                            context: context,
                                            locale: const Locale('ko'),
                                            delegates: [
                                              ...GlobalMaterialLocalizations
                                                  .delegates,
                                            ],
                                            child: Builder(
                                              builder: (context) {
                                                return MediaQuery(
                                                  data: MediaQuery.of(context)
                                                      .copyWith(
                                                          alwaysUse24HourFormat:
                                                              false),
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
                                    final List<OperatingHours> hoursList =
                                        _operatingHours.entries
                                            .where((e) => e.value != null)
                                            .map((e) {
                                      final range = e.value!;
                                      final breaks = _breakTimes[e.key] ?? [];
                                      return OperatingHours(
                                        dayOfWeek: e.key.index,
                                        startHour: range.startHour,
                                        startMinute: range.startMinute,
                                        endHour: range.endHour,
                                        endMinute: range.endMinute,
                                        breakTimes: breaks
                                            .map((b) => BreakTime(
                                                  startHour: b.startHour,
                                                  startMinute: b.startMinute,
                                                  endHour: b.endHour,
                                                  endMinute: b.endMinute,
                                                ))
                                            .toList(),
                                      );
                                    }).toList();
                                    await DataManager.instance
                                        .saveOperatingHours(hoursList);
                                    final hours = await DataManager.instance
                                        .getOperatingHours();
                                    setState(() {
                                      for (var d in DayOfWeek.values) {
                                        _operatingHours[d] = null;
                                        _breakTimes[d] = [];
                                      }
                                      for (var hour in hours) {
                                        final d =
                                            DayOfWeek.values[hour.dayOfWeek];
                                        _operatingHours[d] = TimeRange(
                                          startHour: hour.startHour,
                                          startMinute: hour.startMinute,
                                          endHour: hour.endHour,
                                          endMinute: hour.endMinute,
                                        );
                                        _breakTimes[d] = hour.breakTimes
                                            .map((breakTime) => TimeRange(
                                                  startHour:
                                                      breakTime.startHour,
                                                  startMinute:
                                                      breakTime.startMinute,
                                                  endHour: breakTime.endHour,
                                                  endMinute:
                                                      breakTime.endMinute,
                                                ))
                                            .toList();
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
                                  height: 60,
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
                                  child: Center(
                                    child: Padding(
                                      padding:
                                          const EdgeInsets.fromLTRB(4, 6, 4, 9),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Text(
                                            _formatTimeOfDay(TimeOfDay(
                                                hour: _operatingHours[day]!
                                                    .startHour,
                                                minute: _operatingHours[day]!
                                                    .startMinute)),
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                              height: 1.05,
                                            ),
                                            maxLines: 1,
                                            textAlign: TextAlign.center,
                                          ),
                                          const Text(
                                            '-',
                                            style: TextStyle(
                                              color: Colors.white54,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                              height: 1.0,
                                            ),
                                            maxLines: 1,
                                            textAlign: TextAlign.center,
                                          ),
                                          Text(
                                            _formatTimeOfDay(TimeOfDay(
                                                hour: _operatingHours[day]!
                                                    .endHour,
                                                minute: _operatingHours[day]!
                                                    .endMinute)),
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                              height: 1.05,
                                            ),
                                            maxLines: 1,
                                            textAlign: TextAlign.center,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            )
                          : Container(
                              width: blockWidth,
                              height: 60,
                              margin: const EdgeInsets.only(bottom: 0),
                              padding: EdgeInsets.zero,
                              child: Center(
                                child: TextButton(
                                  onPressed: () =>
                                      _selectOperatingHours(context, day),
                                  style: TextButton.styleFrom(
                                    foregroundColor: _kSignatureGreen,
                                    textStyle: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500),
                                    padding: EdgeInsets.zero,
                                  ),
                                  child: const Text('휴무'),
                                ),
                              ),
                            ),
                      // 운영시간 카드와 휴식시간 카드 사이 여백
                      if ((_breakTimes[day]?.isNotEmpty ?? false) &&
                          hasOperatingHours)
                        const SizedBox(height: 6),
                      // 휴식시간 카드들
                      ...((_breakTimes[day]?.asMap().entries ?? [])
                          .map((entry) {
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
                                    child: const Text('수정',
                                        style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 12)), // 기존 11 → 12
                                    height: 28,
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: const Text('삭제',
                                        style: TextStyle(
                                            color: Colors.white, fontSize: 12)),
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
                                final TimeOfDay? newStart =
                                    await showTimePicker(
                                  context: context,
                                  initialTime: TimeOfDay(
                                      hour: breakTime.startHour,
                                      minute: breakTime.startMinute),
                                  builder:
                                      (BuildContext context, Widget? child) {
                                    return Theme(
                                      data: Theme.of(context).copyWith(
                                        colorScheme: const ColorScheme(
                                          brightness: Brightness.dark,
                                          primary: _kSignatureGreen,
                                          onPrimary: Colors.white,
                                          secondary: _kSignatureGreen,
                                          onSecondary: Colors.white,
                                          error: Color(0xFFB00020),
                                          onError: Colors.white,
                                          background: Color(0xFF18181A),
                                          onBackground: Colors.white,
                                          surface: Color(0xFF18181A),
                                          onSurface: Colors.white,
                                        ),
                                        dialogBackgroundColor:
                                            const Color(0xFF18181A),
                                        timePickerTheme:
                                            const TimePickerThemeData(
                                          backgroundColor: Color(0xFF18181A),
                                          hourMinuteColor: _kSignatureGreen,
                                          hourMinuteTextColor: Colors.white,
                                          dialHandColor: _kSignatureGreen,
                                          dialBackgroundColor:
                                              Color(0xFF18181A),
                                          entryModeIconColor: _kSignatureGreen,
                                          shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.all(
                                                  Radius.circular(24))),
                                          helpTextStyle: TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold),
                                          dayPeriodTextColor: Colors.white,
                                          dayPeriodColor: _kSignatureGreen,
                                        ),
                                      ),
                                      child: Localizations.override(
                                        context: context,
                                        locale: const Locale('ko'),
                                        delegates: [
                                          ...GlobalMaterialLocalizations
                                              .delegates,
                                        ],
                                        child: Builder(
                                          builder: (context) {
                                            return MediaQuery(
                                              data: MediaQuery.of(context)
                                                  .copyWith(
                                                      alwaysUse24HourFormat:
                                                          false),
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
                                  initialTime: TimeOfDay(
                                      hour: breakTime.endHour,
                                      minute: breakTime.endMinute),
                                  builder:
                                      (BuildContext context, Widget? child) {
                                    return Theme(
                                      data: Theme.of(context).copyWith(
                                        colorScheme: const ColorScheme(
                                          brightness: Brightness.dark,
                                          primary: _kSignatureGreen,
                                          onPrimary: Colors.white,
                                          secondary: _kSignatureGreen,
                                          onSecondary: Colors.white,
                                          error: Color(0xFFB00020),
                                          onError: Colors.white,
                                          background: Color(0xFF18181A),
                                          onBackground: Colors.white,
                                          surface: Color(0xFF18181A),
                                          onSurface: Colors.white,
                                        ),
                                        dialogBackgroundColor:
                                            const Color(0xFF18181A),
                                        timePickerTheme:
                                            const TimePickerThemeData(
                                          backgroundColor: Color(0xFF18181A),
                                          hourMinuteColor: _kSignatureGreen,
                                          hourMinuteTextColor: Colors.white,
                                          dialHandColor: _kSignatureGreen,
                                          dialBackgroundColor:
                                              Color(0xFF18181A),
                                          entryModeIconColor: _kSignatureGreen,
                                          shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.all(
                                                  Radius.circular(24))),
                                          helpTextStyle: TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold),
                                          dayPeriodTextColor: Colors.white,
                                          dayPeriodColor: _kSignatureGreen,
                                        ),
                                      ),
                                      child: Localizations.override(
                                        context: context,
                                        locale: const Locale('ko'),
                                        delegates: [
                                          ...GlobalMaterialLocalizations
                                              .delegates,
                                        ],
                                        child: Builder(
                                          builder: (context) {
                                            return MediaQuery(
                                              data: MediaQuery.of(context)
                                                  .copyWith(
                                                      alwaysUse24HourFormat:
                                                          false),
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
                                  final idx =
                                      _breakTimes[day]?.indexOf(breakTime) ??
                                          -1;
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
                                final List<OperatingHours> hoursList =
                                    _operatingHours.entries
                                        .where((e) => e.value != null)
                                        .map((e) {
                                  final range = e.value!;
                                  final breaks = _breakTimes[e.key] ?? [];
                                  return OperatingHours(
                                    dayOfWeek: e.key.index,
                                    startHour: range.startHour,
                                    startMinute: range.startMinute,
                                    endHour: range.endHour,
                                    endMinute: range.endMinute,
                                    breakTimes: breaks
                                        .map((b) => BreakTime(
                                              startHour: b.startHour,
                                              startMinute: b.startMinute,
                                              endHour: b.endHour,
                                              endMinute: b.endMinute,
                                            ))
                                        .toList(),
                                  );
                                }).toList();
                                await DataManager.instance
                                    .saveOperatingHours(hoursList);
                              } else if (selected == 'delete') {
                                setState(() {
                                  _breakTimes[day]?.remove(breakTime);
                                  print(
                                      '[DEBUG][휴식삭제] day=$day, _breakTimes[day]=${_breakTimes[day]?.map((b) => '${b.startHour}:${b.startMinute}~${b.endHour}:${b.endMinute}').toList()}');
                                });
                              }
                            },
                            child: AnimatedContainer(
                              duration: Duration(milliseconds: 150),
                              width: blockWidth,
                              decoration: BoxDecoration(
                                color: const Color(0xFF18181A),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: _kSignatureGreen),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(4, 0, 4, 3),
                                child: Center(
                                  child: Text(
                                    '${_formatTimeOfDay(TimeOfDay(hour: breakTime.startHour, minute: breakTime.startMinute))} - ${_formatTimeOfDay(TimeOfDay(hour: breakTime.endHour, minute: breakTime.endMinute))}',
                                    style: const TextStyle(
                                      color: _kSignatureGreen,
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
                    ],
                  );
                }).toList(),
              ),
            ],
          ),
    );

    if (isPreview) {
      return _buildPreviewAcademySectionScope(child: hoursCard);
    }

    return Center(
      child: SizedBox(
        width: sectionWidth,
        child: hoursCard,
      ),
    );
  }

  String _formatTimeOfDay(TimeOfDay time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  bool _isLastThirtyMarkerDay(DayOfWeek day) {
    final range = _operatingHours[day];
    if (range == null) return false;

    TimeOfDay? latestEnd;
    for (var v in _operatingHours.values) {
      if (v != null) {
        if (latestEnd == null ||
            v.endHour > latestEnd.hour ||
            (v.endHour == latestEnd.hour && v.endMinute > latestEnd.minute)) {
          latestEnd = TimeOfDay(hour: v.endHour, minute: v.endMinute);
        }
      }
    }
    if (latestEnd == null) return false;

    final endMinutes = latestEnd.hour * 60 + latestEnd.minute;
    final startMinutes = endMinutes - 30;
    final latestStart =
        TimeOfDay(hour: startMinutes ~/ 60, minute: startMinutes % 60);

    return range.startHour == latestStart.hour &&
        range.startMinute == latestStart.minute &&
        range.endHour == latestEnd.hour &&
        range.endMinute == latestEnd.minute;
  }

  Future<void> _promptAddBreakTime() async {
    final availableDays = DayOfWeek.values
        .where((d) => _operatingHours[d] != null && !_isLastThirtyMarkerDay(d))
        .toList();
    if (availableDays.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('휴식을 추가할 요일이 없습니다. 먼저 운영시간을 등록하세요.')));
      return;
    }

    final DayOfWeek? pickedDay = await showDialog<DayOfWeek>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: const Color(0xFF18181A),
          title: const Text('요일 선택',
              style: TextStyle(
                  color: Color(0xFFEAF2F2), fontWeight: FontWeight.w900)),
          content: SizedBox(
            width: 320,
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: availableDays.length,
              separatorBuilder: (_, __) =>
                  const Divider(height: 1, color: Colors.white12),
              itemBuilder: (_, i) {
                final d = availableDays[i];
                return ListTile(
                  dense: true,
                  title: Text(d.koreanName,
                      style: const TextStyle(
                          color: Colors.white70, fontWeight: FontWeight.w700)),
                  trailing:
                      const Icon(Icons.chevron_right, color: Colors.white24),
                  onTap: () => Navigator.of(ctx).pop(d),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('취소',
                  style: TextStyle(
                      color: Colors.white70, fontWeight: FontWeight.w700)),
            ),
          ],
        );
      },
    );

    if (pickedDay == null) return;
    await _addBreakTime(pickedDay);
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
              primary: _kSignatureGreen,
              onPrimary: Colors.white,
              secondary: _kSignatureGreen,
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
              hourMinuteColor: _kSignatureGreen,
              hourMinuteTextColor: Colors.white,
              dialHandColor: _kSignatureGreen,
              dialBackgroundColor: Color(0xFF18181A),
              entryModeIconColor: _kSignatureGreen,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(24))),
              helpTextStyle:
                  TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              dayPeriodTextColor: Colors.white,
              dayPeriodColor: _kSignatureGreen,
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
                  data: MediaQuery.of(context)
                      .copyWith(alwaysUse24HourFormat: false),
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
                primary: _kSignatureGreen,
                onPrimary: Colors.white,
                secondary: _kSignatureGreen,
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
                hourMinuteColor: _kSignatureGreen,
                hourMinuteTextColor: Colors.white,
                dialHandColor: _kSignatureGreen,
                dialBackgroundColor: Color(0xFF18181A),
                entryModeIconColor: _kSignatureGreen,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.all(Radius.circular(24))),
                helpTextStyle:
                    TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                dayPeriodTextColor: Colors.white,
                dayPeriodColor: _kSignatureGreen,
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
                    data: MediaQuery.of(context)
                        .copyWith(alwaysUse24HourFormat: false),
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
          print(
              '[DEBUG][휴식추가] day=$day, _breakTimes[day]=${_breakTimes[day]?.map((b) => '${b.startHour}:${b.startMinute}~${b.endHour}:${b.endMinute}').toList()}');
        });
        // DB 저장
        final List<OperatingHours> hoursList =
            _operatingHours.entries.where((e) => e.value != null).map((e) {
          final range = e.value!;
          final breaks = _breakTimes[e.key] ?? [];
          return OperatingHours(
            dayOfWeek: e.key.index,
            startHour: range.startHour,
            startMinute: range.startMinute,
            endHour: range.endHour,
            endMinute: range.endMinute,
            breakTimes: breaks
                .map((b) => BreakTime(
                      startHour: b.startHour,
                      startMinute: b.startMinute,
                      endHour: b.endHour,
                      endMinute: b.endMinute,
                    ))
                .toList(),
          );
        }).toList();
        await DataManager.instance.saveOperatingHours(hoursList);
      }
    }
  }

  PreviewAcademyPanelStyle? _previewAcademyPanelStyle(BuildContext context) {
    if (!widget.previewUseFabStyleTabBar) return null;
    return FabTabBarTokens.previewAcademyPanelStyleFor(
      Theme.of(context).brightness,
    );
  }

  InputDecoration _academyFieldDecoration(BuildContext context, String label) {
    final preview = _previewAcademyPanelStyle(context);
    if (preview != null) return preview.inputDecoration(label);
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(color: Colors.white.withOpacity(0.7)),
      enabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
      ),
      focusedBorder: const OutlineInputBorder(
        borderSide: BorderSide(color: _kSignatureGreen),
      ),
    );
  }

  InputDecoration _academyDropdownDecoration(BuildContext context) {
    final preview = _previewAcademyPanelStyle(context);
    if (preview != null) return preview.dropdownDecoration();
    return InputDecoration(
      enabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
      ),
      focusedBorder: const OutlineInputBorder(
        borderSide: BorderSide(color: _kSignatureGreen),
      ),
    );
  }

  TextStyle _academySectionTitleStyle(BuildContext context) {
    final previewStyle = _previewAcademyPanelStyle(context);
    if (previewStyle != null) {
      return FabTabBarTokens.previewSectionTitleStyle(previewStyle);
    }
    return const TextStyle(
      color: Colors.white,
      fontSize: 20,
      fontWeight: FontWeight.w500,
    );
  }

  Widget _buildPreviewAcademySectionScope({required Widget child}) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: FabTabBarTokens.previewAcademySectionMaxWidth,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: FabTabBarTokens.previewAcademySectionScopePaddingHorizontal,
          ),
          child: child,
        ),
      ),
    );
  }

  void _previewAcademyFieldTap(String fieldLabel) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Preview: $fieldLabel 편집 (다이얼로그 추후 구현)'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _openPreviewAcademyBasicInfoDialog(
    PreviewAcademyPanelStyle style, {
    PreviewAcademyBasicInfoField initialFocusField =
        PreviewAcademyBasicInfoField.academyName,
  }) async {
    final result = await PreviewAcademyFieldInputSheet.show(
      context: context,
      style: style,
      initialValues: PreviewAcademyBasicInfoValues(
        academyName: _academyNameController.text,
        academyAddress: _academyAddressController.text,
        slogan: _sloganController.text,
      ),
      initialFocusField: initialFocusField,
    );
    if (result != null && mounted) {
      setState(() {
        _academyNameController.text = result.academyName;
        _academyAddressController.text = result.academyAddress;
        _sloganController.text = result.slogan;
      });
    }
  }

  Future<void> _openPreviewPaymentMenu(PreviewAcademyPanelStyle style) async {
    final box =
        _previewPaymentMenuAnchorKey.currentContext?.findRenderObject()
            as RenderBox?;
    if (box == null) return;

    final pickedId = await PreviewAcademyGlassMenu.show(
      context: context,
      anchor: box,
      style: style,
      selectedId: _paymentType.name,
      options: const [
        PreviewAcademyMenuOption(id: 'monthly', label: '월결제'),
        PreviewAcademyMenuOption(id: 'perClass', label: '횟수제'),
      ],
    );

    if (pickedId != null && mounted) {
      setState(() {
        _paymentType = pickedId == 'monthly'
            ? PaymentType.monthly
            : PaymentType.perClass;
      });
    }
  }

  String _previewAcademyRowValue(TextEditingController controller) {
    final text = controller.text.trim();
    return text.isEmpty ? '' : text;
  }

  String _previewLessonDurationValue() {
    final text = _lessonDurationController.text.trim();
    if (text.isEmpty) return '';
    return '$text분';
  }

  Widget _buildAcademySettingsPreview() {
    final academyStyle = _previewAcademyPanelStyle(context)!;

    return _buildPreviewAcademySectionScope(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: FabTabBarTokens.previewAcademyTopInset),
          Text(
            '학원정보',
            textAlign: TextAlign.center,
            style: FabTabBarTokens.previewAcademyMainTitleStyle(academyStyle),
          ),
          const SizedBox(
            height: FabTabBarTokens.previewAcademyMainTitleToLogoSpacing,
          ),
          Center(
            child: GestureDetector(
              onTap: _pickLogoImage,
              child: _academyLogo != null && _academyLogo!.isNotEmpty
                  ? CircleAvatar(
                      radius: FabTabBarTokens.previewAcademyLogoRadius,
                      backgroundImage: MemoryImage(_academyLogo!),
                    )
                  : CircleAvatar(
                      radius: FabTabBarTokens.previewAcademyLogoRadius,
                      backgroundColor:
                          FabTabBarTokens.paletteFor(
                            Theme.of(context).brightness,
                          ).highlight,
                      child: Icon(
                        Icons.school_outlined,
                        size: FabTabBarTokens.previewAcademyLogoIconSize,
                        color: academyStyle.avatarPlaceholderIcon,
                      ),
                    ),
            ),
          ),
          const SizedBox(
            height: FabTabBarTokens.previewAcademyLogoToChangeSpacing,
          ),
          Center(
            child: TextButton(
              onPressed: _pickLogoImage,
              style: TextButton.styleFrom(
                backgroundColor: academyStyle.changeButtonBackground,
                foregroundColor: FabTabBarTokens.previewConfirmActionColor,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: FabTabBarTokens
                      .previewAcademyChangeButtonPaddingVertical,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              child: Text(
                '변경',
                style: TextStyle(
                  fontSize: FabTabBarTokens.previewAcademyBaseFontSize,
                  fontWeight: FontWeight.w600,
                  color: FabTabBarTokens.previewConfirmActionColor,
                ),
              ),
            ),
          ),
          const SizedBox(
            height: FabTabBarTokens.previewAcademySectionListSpacing,
          ),
          PreviewAcademyGroupedFieldsCard(
            style: academyStyle,
            rows: [
              PreviewAcademyInfoRow(
                label: '학원명',
                value: _previewAcademyRowValue(_academyNameController),
                onTap: () => _openPreviewAcademyBasicInfoDialog(
                  academyStyle,
                  initialFocusField: PreviewAcademyBasicInfoField.academyName,
                ),
              ),
              PreviewAcademyInfoRow(
                label: '학원주소',
                value: _previewAcademyRowValue(_academyAddressController),
                onTap: () => _openPreviewAcademyBasicInfoDialog(
                  academyStyle,
                  initialFocusField:
                      PreviewAcademyBasicInfoField.academyAddress,
                ),
              ),
              PreviewAcademyInfoRow(
                label: '슬로건',
                value: _previewAcademyRowValue(_sloganController),
                onTap: () => _openPreviewAcademyBasicInfoDialog(
                  academyStyle,
                  initialFocusField: PreviewAcademyBasicInfoField.slogan,
                ),
              ),
            ],
          ),
          const SizedBox(
            height: FabTabBarTokens.previewAcademySectionListSpacing,
          ),
          _buildAcademySettingsPreviewCapacitySection(academyStyle),
          const SizedBox(
            height: FabTabBarTokens.previewAcademySectionListSpacing,
          ),
          _buildPreviewOperatingHoursSection(academyStyle),
        ],
      ),
    );
  }

  InputDecoration _previewAcademyInlineFieldDecoration(
    PreviewAcademyPanelStyle style, {
    String? hintText,
  }) {
    return InputDecoration(
      hintText: hintText,
      hintStyle: TextStyle(
        color: style.hint,
        fontSize: FabTabBarTokens.previewAcademyBaseFontSize,
      ),
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      isDense: true,
      contentPadding: EdgeInsets.zero,
    );
  }

  Widget _buildAcademySettingsPreviewCapacitySection(
    PreviewAcademyPanelStyle academyStyle,
  ) {
    return PreviewAcademyGroupedFieldsCard(
      style: academyStyle,
      rows: [
        PreviewAcademyInfoRow(
          label: '기본 정원',
          value: _previewAcademyRowValue(_capacityController),
          onTap: () => _previewAcademyFieldTap('기본 정원'),
        ),
        PreviewAcademyInfoRow(
          label: '수업 시간',
          value: _previewLessonDurationValue(),
          onTap: () => _previewAcademyFieldTap('수업 시간'),
        ),
        PreviewAcademyInfoRow(
          label: '지불 방식',
          value: _previewPaymentTypeLabel(_paymentType),
          showChevron: false,
          valueUsesHintStyle: true,
          trailingAlignsWithChevron: true,
          trailing: PreviewAcademyPaymentMenuAnchor(
            key: _previewPaymentMenuAnchorKey,
            style: academyStyle,
          ),
          onTap: () => _openPreviewPaymentMenu(academyStyle),
        ),
        if (_paymentType == PaymentType.perClass)
          PreviewAcademyInfoRow(
            label: '기준 수강 횟수',
            value: _previewAcademyRowValue(_courseCountController),
            onTap: () => _previewAcademyFieldTap('기준 수강 횟수'),
          ),
      ],
    );
  }

  List<Widget> _buildAcademySettingsFooterWidgets() {
    final archiveButton = Center(
      child: ElevatedButton(
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const StudentArchivesScreen(),
            ),
          );
        },
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF2A2A2A),
          padding: const EdgeInsets.symmetric(horizontal: 72, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
        ),
        child: const Text(
          '퇴원 학생 아카이브',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );

    final saveButton = Stack(
      children: [
        Center(
          child: ElevatedButton(
            onPressed: () async {
                if (_operatingHours.values.where((v) => v != null).isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('하나 이상의 운영시간이 등록되어야 합니다.'),
                      backgroundColor: _kSignatureGreen,
                    ),
                  );
                  return;
                }
                try {
                  ScaffoldMessenger.of(context).hideCurrentSnackBar();
                  final academySettings = AcademySettings(
                    name: _academyNameController.text.trim(),
                    address: _academyAddressController.text.trim(),
                    slogan: _sloganController.text.trim(),
                    defaultCapacity:
                        int.tryParse(_capacityController.text.trim()) ?? 30,
                    lessonDuration:
                        int.tryParse(_lessonDurationController.text.trim()) ??
                            50,
                    logo: _academyLogo,
                    sessionCycle:
                        int.tryParse(_courseCountController.text.trim()) ?? 1,
                    activeExamSeasonId:
                        DataManager.instance.academySettings.activeExamSeasonId,
                  );
                  DataManager.instance.paymentType = _paymentType;
                  await DataManager.instance.saveAcademySettings(academySettings);
                  await DataManager.instance.savePaymentType(_paymentType);
                  TimeOfDay? latestEnd;
                  for (var v in _operatingHours.values) {
                    if (v != null) {
                      if (latestEnd == null ||
                          v.endHour > latestEnd.hour ||
                          (v.endHour == latestEnd.hour &&
                              v.endMinute > latestEnd.minute)) {
                        latestEnd =
                            TimeOfDay(hour: v.endHour, minute: v.endMinute);
                      }
                    }
                  }
                  TimeOfDay? latestStart;
                  if (latestEnd != null) {
                    int endMinutes = latestEnd.hour * 60 + latestEnd.minute;
                    int startMinutes = endMinutes - 30;
                    latestStart = TimeOfDay(
                      hour: startMinutes ~/ 60,
                      minute: startMinutes % 60,
                    );
                  }
                  final List<OperatingHours> hoursList = DayOfWeek.values.map(
                    (day) {
                      final range = _operatingHours[day];
                      final breaks = _breakTimes[day] ?? [];
                      if (range != null) {
                        return OperatingHours(
                          dayOfWeek: day.index,
                          startHour: range.startHour,
                          startMinute: range.startMinute,
                          endHour: range.endHour,
                          endMinute: range.endMinute,
                          breakTimes: breaks
                              .map(
                                (b) => BreakTime(
                                  startHour: b.startHour,
                                  startMinute: b.startMinute,
                                  endHour: b.endHour,
                                  endMinute: b.endMinute,
                                ),
                              )
                              .toList(),
                        );
                      }
                      return OperatingHours(
                        dayOfWeek: day.index,
                        startHour: latestStart?.hour ?? 9,
                        startMinute: latestStart?.minute ?? 0,
                        endHour: latestEnd?.hour ?? 18,
                        endMinute: latestEnd?.minute ?? 0,
                        breakTimes: breaks
                            .map(
                              (b) => BreakTime(
                                startHour: b.startHour,
                                startMinute: b.startMinute,
                                endHour: b.endHour,
                                endMinute: b.endMinute,
                              ),
                            )
                            .toList(),
                      );
                    },
                  ).toList();
                  await DataManager.instance.saveOperatingHours(hoursList);
                  await DataManager.instance.loadAcademySettings();
                  setState(() {
                    final logo = DataManager.instance.academySettings.logo;
                    _academyLogo =
                        (logo is Uint8List && logo.isNotEmpty) ? logo : null;
                  });
                  _onShowSnackBar();
                  _snackBarController =
                      ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('저장되었습니다!')),
                  );
                  _snackBarController?.closed.then((_) => _onHideSnackBar());
                } catch (e) {
                  ScaffoldMessenger.of(context).hideCurrentSnackBar();
                  _onShowSnackBar();
                  _snackBarController =
                      ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('오류가 발생했습니다.')),
                  );
                  _snackBarController?.closed.then((_) => _onHideSnackBar());
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: widget.previewUseFabStyleTabBar
                    ? FabTabBarTokens.previewConfirmActionColor
                    : _kSignatureGreen,
                padding:
                    const EdgeInsets.symmetric(horizontal: 72, vertical: 16),
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

    final actionButtons = <Widget>[
      archiveButton,
      const SizedBox(height: 18),
      saveButton,
    ];

    if (widget.previewUseFabStyleTabBar) {
      return const [];
    }

    return [
      const SizedBox(height: 32),
      _buildOperatingHoursSection(),
      const SizedBox(height: 40),
      ...actionButtons,
    ];
  }

  Widget _buildAcademySettings() {
    if (widget.previewUseFabStyleTabBar) {
      return _buildAcademySettingsPreview();
    }
    return _buildAcademySettingsLegacy();
  }

  Widget _buildAcademySettingsLegacy() {
    const double academyInfoCardHeight = 680;
    final academyStyle = _previewAcademyPanelStyle(context);
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
                height: academyInfoCardHeight,
                child: Container(
                  height: academyInfoCardHeight,
                  margin: EdgeInsets.zero,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 28, vertical: 28),
                  decoration: BoxDecoration(
                    color: const Color(0xFF18181A),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '학원 정보',
                        style: _academySectionTitleStyle(context),
                      ),
                      const SizedBox(height: 24),
                      // 학원명 입력
                      SizedBox(
                        width: 300,
                        child: TextFormField(
                          controller: _academyNameController,
                          style: TextStyle(
                            color: academyStyle?.inputText ?? Colors.white,
                          ),
                          decoration:
                              _academyFieldDecoration(context, '학원명'),
                        ),
                      ),
                      const SizedBox(height: 20),
                      // 주소 입력
                      SizedBox(
                        width: 600,
                        child: TextFormField(
                          controller: _academyAddressController,
                          style: TextStyle(
                            color: academyStyle?.inputText ?? Colors.white,
                          ),
                          decoration:
                              _academyFieldDecoration(context, '학원 주소'),
                        ),
                      ),
                      const SizedBox(height: 20),
                      // 슬로건 입력
                      SizedBox(
                        width: 600,
                        child: TextFormField(
                          controller: _sloganController,
                          style: TextStyle(
                            color: academyStyle?.inputText ?? Colors.white,
                          ),
                          decoration:
                              _academyFieldDecoration(context, '슬로건'),
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
                                style: TextStyle(
                                  color: academyStyle?.inputText ?? Colors.white,
                                ),
                                keyboardType: TextInputType.number,
                                decoration: _academyFieldDecoration(
                                  context,
                                  '기본 정원',
                                ),
                              ),
                            ),
                            const SizedBox(width: 20),
                            Expanded(
                              child: TextFormField(
                                controller: _lessonDurationController,
                                style: TextStyle(
                                  color: academyStyle?.inputText ?? Colors.white,
                                ),
                                keyboardType: TextInputType.number,
                                decoration: _academyFieldDecoration(
                                  context,
                                  '수업 시간 (분)',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 30),
                      Text(
                        '지불 방식',
                        style: _academySectionTitleStyle(context),
                      ),
                      const SizedBox(height: 12),
                      // [수정] 지불 방식과 수강 횟수를 한 줄(Row)로 배치
                      Row(
                        children: [
                          SizedBox(
                            width: 290,
                            child: DropdownButtonFormField<PaymentType>(
                              value: _paymentType,
                              decoration: _academyDropdownDecoration(context),
                              dropdownColor: academyStyle?.dropdownBackground ??
                                  const Color(0xFF1F1F1F),
                              style: TextStyle(
                                color: academyStyle?.inputText ?? Colors.white,
                                fontSize: 16,
                              ),
                              items: [
                                DropdownMenuItem(
                                  value: PaymentType.monthly,
                                  child: Text(
                                    '월 결제',
                                    style: TextStyle(
                                      color: academyStyle?.inputText ??
                                          Colors.white,
                                    ),
                                  ),
                                ),
                                DropdownMenuItem(
                                  value: PaymentType.perClass,
                                  child: Text(
                                    '횟수제',
                                    style: TextStyle(
                                      color: academyStyle?.inputText ??
                                          Colors.white,
                                    ),
                                  ),
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
                                style: TextStyle(
                                  color: academyStyle?.inputText ?? Colors.white,
                                ),
                                keyboardType: TextInputType.number,
                                decoration: _academyFieldDecoration(
                                  context,
                                  '기준 수강 횟수',
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 30),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            '학원 로고',
                            style: _academySectionTitleStyle(context),
                          ),
                          const SizedBox(width: 16),
                          Text(
                            '권장 크기: 80x80px',
                            style: TextStyle(
                              color: academyStyle?.hint ?? Colors.white70,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(width: 16),
                          IconButton(
                            icon: Icon(
                              Icons.image,
                              color: academyStyle?.icon ?? Colors.white70,
                            ),
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
                            padding:
                                const EdgeInsets.only(top: 16.0, left: 8.0),
                            child: GestureDetector(
                              onTap: _pickLogoImage,
                              child: _academyLogo != null &&
                                      _academyLogo!.isNotEmpty
                                  ? CircleAvatar(
                                      backgroundImage:
                                          MemoryImage(_academyLogo!),
                                      radius: 45,
                                    )
                                  : CircleAvatar(
                                      radius: 45,
                                      backgroundColor: academyStyle
                                              ?.avatarPlaceholderBackground ??
                                          Colors.grey[800],
                                      child: Icon(
                                        Icons.image,
                                        color: academyStyle
                                                ?.avatarPlaceholderIcon ??
                                            Colors.white54,
                                        size: 36,
                                      ),
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
        ..._buildAcademySettingsFooterWidgets(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    void selectTab(int i) {
      setState(() {
        _prevTabIndex = _customTabIndex;
        _customTabIndex = i;
        _selectedType = i == 0
            ? SettingType.academy
            : (i == 1 ? SettingType.teachers : SettingType.general);
      });
    }

    final content = Column(
      children: [
        if (!widget.previewUseFabStyleTabBar) ...[
          const SizedBox(height: 0),
          const SizedBox(height: 8),
          Center(
            child: PillTabSelector(
              selectedIndex: _customTabIndex,
              tabs: const ['학원', '선생님', '일반'],
              onTabSelected: selectTab,
            ),
          ),
          const SizedBox(height: 24),
        ],
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            switchInCurve: Curves.easeInOut,
            switchOutCurve: Curves.easeInOut,
            layoutBuilder:
                (Widget? currentChild, List<Widget> previousChildren) {
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
    );

    return Scaffold(
      backgroundColor: context.yggSurfaceBase,
      body: widget.previewUseFabStyleTabBar
          ? Stack(
              children: [
                Positioned.fill(child: content),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: FabTabBarTokens.fabBarBottomInset,
                  child: Center(
                    child: FabStyleTabBar(
                      selectedIndex: _customTabIndex,
                      tabs: const ['학원', '선생님', '일반'],
                      onTabSelected: selectTab,
                    ),
                  ),
                ),
                Positioned(
                  right: FabTabBarTokens.fabBarRightInset,
                  bottom: FabTabBarTokens.fabBarBottomInset,
                  child: FabStyleActionButton(
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Preview: FAB 메뉴는 목업 스타일만 적용됩니다.',
                          ),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                  ),
                ),
              ],
            )
          : content,
      floatingActionButton: widget.previewUseFabStyleTabBar
          ? null
          : const MainFabAlternative(),
    );
  }
  void _pickLogoImage() async {
    if (kIsWeb) {
      // 웹: FileUploadInputElement 사용 (주석 참고)
    } else {
      final result = await FilePicker.platform
          .pickFiles(type: FileType.image, withData: true);
      if (result != null && result.files.single.bytes != null) {
        setState(() {
          _academyLogo = result.files.single.bytes;
          print(
              '[DEBUG] _pickLogoImage: _academyLogo type=${_academyLogo.runtimeType}, length=${_academyLogo?.length}, isNull=${_academyLogo == null}');
        });
      } else {
        print('[DEBUG] _pickLogoImage: result is null or bytes is null');
      }
    }
  }

  Future<void> _selectOperatingHours(
      BuildContext context, DayOfWeek day) async {
    final TimeOfDay? startTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: 9, minute: 0),
      builder: (BuildContext context, Widget? child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme(
              brightness: Brightness.dark,
              primary: _kSignatureGreen,
              onPrimary: Colors.white,
              secondary: _kSignatureGreen,
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
              hourMinuteColor: _kSignatureGreen,
              hourMinuteTextColor: Colors.white,
              dialHandColor: _kSignatureGreen,
              dialBackgroundColor: Color(0xFF18181A),
              entryModeIconColor: _kSignatureGreen,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(24))),
              helpTextStyle:
                  TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              dayPeriodTextColor: Colors.white,
              dayPeriodColor: _kSignatureGreen,
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
                  data: MediaQuery.of(context)
                      .copyWith(alwaysUse24HourFormat: false),
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
      initialTime:
          TimeOfDay(hour: startTime.hour + 1, minute: startTime.minute),
      builder: (BuildContext context, Widget? child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme(
              brightness: Brightness.dark,
              primary: _kSignatureGreen,
              onPrimary: Colors.white,
              secondary: _kSignatureGreen,
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
              hourMinuteColor: _kSignatureGreen,
              hourMinuteTextColor: Colors.white,
              dialHandColor: _kSignatureGreen,
              dialBackgroundColor: Color(0xFF18181A),
              entryModeIconColor: _kSignatureGreen,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(24))),
              helpTextStyle:
                  TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              dayPeriodTextColor: Colors.white,
              dayPeriodColor: _kSignatureGreen,
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
                  data: MediaQuery.of(context)
                      .copyWith(alwaysUse24HourFormat: false),
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
      _previewOperatingDaysActive.add(day);
      print('[UI] _operatingHours after set:');
      _operatingHours.forEach((k, v) => print('  $k: $v'));
    });
    // DB 저장을 위해 전체 운영시간을 OperatingHours 리스트로 변환
    final List<OperatingHours> hoursList =
        _operatingHours.entries.where((e) => e.value != null).map((e) {
      final range = e.value!;
      final breaks = _breakTimes[e.key] ?? [];
      print('[UI] hoursList entry: day=$day, range=$range');
      return OperatingHours(
        dayOfWeek: e.key.index,
        startHour: range.startHour,
        startMinute: range.startMinute,
        endHour: range.endHour,
        endMinute: range.endMinute,
        breakTimes: breaks
            .map((b) => BreakTime(
                  startHour: b.startHour,
                  startMinute: b.startMinute,
                  endHour: b.endHour,
                  endMinute: b.endMinute,
                ))
            .toList(),
      );
    }).toList();
    print('[UI] hoursList to save: ${hoursList.length}개');
    await DataManager.instance.saveOperatingHours(hoursList);
    final hours = await DataManager.instance.getOperatingHours();
    print('[UI] hours loaded from DB: ${hours.length}개');
    for (var h in hours) {
      print(
          '  start= [36m${h.startHour}:${h.startMinute} [0m, end=${h.endHour}:${h.endMinute}');
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
        _breakTimes[d] = hour.breakTimes
            .map((breakTime) => TimeRange(
                  startHour: breakTime.startHour,
                  startMinute: breakTime.startMinute,
                  endHour: breakTime.endHour,
                  endMinute: breakTime.endMinute,
                ))
            .toList();
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
                        backgroundColor: _kSignatureGreen,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 24, vertical: 10),
                      ),
                      child: const Text('선생님 등록',
                          style: TextStyle(fontSize: 16, color: Colors.white)),
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
                      height: (teachers.length * 64.0) +
                          ((teachers.length - 1) * 16.0),
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
                              padding: EdgeInsets.only(
                                  bottom: i == teachers.length - 1 ? 0 : 16),
                              child: _buildTeacherCard(teachers[i],
                                  key: ValueKey(teachers[i])),
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
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                  onSelected: (value) async {
                    if (!_isOwner) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('원장만 수정/삭제할 수 있습니다.')));
                      return;
                    }
                    if (value == 'edit') {
                      await showDialog(
                        context: context,
                        builder: (context) => TeacherRegistrationDialog(
                          teacher: t,
                          onSave: (updatedTeacher) {
                            final idx = DataManager
                                .instance.teachersNotifier.value
                                .indexOf(t);
                            if (idx != -1) {
                              DataManager.instance
                                  .updateTeacher(idx, updatedTeacher);
                            }
                          },
                        ),
                      );
                    } else if (value == 'delete') {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          backgroundColor: const Color(0xFF2A2A2A),
                          title: const Text('선생님 삭제',
                              style: TextStyle(color: Colors.white)),
                          content: const Text('정말로 이 선생님을 삭제하시겠습니까?',
                              style: TextStyle(color: Colors.white)),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(false),
                              child: const Text('취소'),
                            ),
                            FilledButton(
                              style: FilledButton.styleFrom(
                                  backgroundColor: Colors.red),
                              onPressed: () => Navigator.of(context).pop(true),
                              child: const Text('삭제'),
                            ),
                          ],
                        ),
                      );
                      if (confirmed == true) {
                        final idx = DataManager.instance.teachersNotifier.value
                            .indexOf(t);
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
                        leading: const Icon(Icons.edit_outlined,
                            color: Colors.white70),
                        title: const Text('수정',
                            style: TextStyle(color: Colors.white)),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: ListTile(
                        leading:
                            const Icon(Icons.delete_outline, color: Colors.red),
                        title: const Text('삭제',
                            style: TextStyle(color: Colors.red)),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'details',
                      child: ListTile(
                        leading: const Icon(Icons.info_outline,
                            color: Colors.white70),
                        title: const Text('상세보기',
                            style: TextStyle(color: Colors.white)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 2),
                ReorderableDragStartListener(
                  index: DataManager.instance.teachersNotifier.value.indexOf(t),
                  child: Icon(Icons.drag_handle,
                      color: _isOwner ? Colors.white38 : Colors.white10),
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
      color: context.yggSurfaceBase,
      child: ScrollConfiguration(
        behavior: const ScrollBehavior(),
        child: Scrollbar(
          controller: _academyScrollController,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _academyScrollController,
            padding: EdgeInsets.only(
              bottom: widget.previewUseFabStyleTabBar ? 120 : 24,
            ),
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
      color: context.yggSurfaceBase,
      child: ScrollConfiguration(
        behavior: const ScrollBehavior(),
        child: Scrollbar(
          controller: _teacherScrollController,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _teacherScrollController,
            padding: EdgeInsets.only(
              bottom: widget.previewUseFabStyleTabBar ? 120 : 24,
            ),
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
      color: context.yggSurfaceBase,
      child: ScrollConfiguration(
        behavior: const ScrollBehavior(),
        child: Scrollbar(
          controller: _generalScrollController,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _generalScrollController,
            padding: EdgeInsets.only(
              bottom: widget.previewUseFabStyleTabBar ? 120 : 24,
            ),
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
