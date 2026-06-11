import 'package:flutter/material.dart';
import '../../widgets/app_time_picker_dialog.dart';
import '../../models/academy_settings.dart';
import '../../models/operating_hours.dart';
import '../../services/data_manager.dart';
import '../../models/payment_type.dart';
import '../../services/academy_db.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import '../../models/teacher.dart';
import '../../widgets/teacher_registration_dialog.dart';
import 'package:animations/animations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import '../../services/update_service.dart';
import '../../services/print_routing_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../services/tenant_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';
import 'student_archives_screen.dart';
import '../../theme/ygg_semantic_colors.dart';
import '../../widgets/dialog_tokens.dart';
import '../design_preview/yggdrasill/settings/fab_tab_bar_preview.dart';

enum SettingType {
  academy,
  teachers,
  general,
}

enum _GeneralLaunchMode {
  defaultMode,
  fullscreen,
  maximize,
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
  /// Preview 전용: 설정 셸에서 + 버튼 목업까지 같이 띄울 때 사용하던 플래그.
  /// 본앱의 설정 내부 탭바는 항상 FAB 스타일 탭바를 사용한다.
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

  /// 본앱에도 새 학원 탭 UI를 적용한다.
  ///
  /// [previewUseFabStyleTabBar]는 하단 FAB형 탭바 목업 전용으로만 남긴다.
  bool get _usePreviewAcademyUi => true;

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

  /// Preview — 운영시간 행에서 인라인으로 펼쳐진 휴식 리스트.
  final Set<DayOfWeek> _previewBreakTimesExpanded = {};

  int _customTabIndex = 0;
  final FabStyleScreenTabBarOverlay _fabTabBarOverlay =
      FabStyleScreenTabBarOverlay();
  int _prevTabIndex = 0;

  // 운영시간 카드 hover 상태 관리
  final Set<int> _hoveredOperatingHourCards = {};

  final GlobalKey _academyInfoKey = GlobalKey();
  final GlobalKey _previewPaymentMenuAnchorKey = GlobalKey();
  final GlobalKey _previewThemeMenuAnchorKey = GlobalKey();
  final GlobalKey _previewLaunchModeMenuAnchorKey = GlobalKey();
  final GlobalKey _previewGeneralPrinterMenuAnchorKey = GlobalKey();
  final GlobalKey _previewTodoPrinterMenuAnchorKey = GlobalKey();
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
  ThemeMode _selectedThemeMode = ThemeMode.light; // [추가] 테마 선택 상태
  bool _isOwner = false; // 원장 여부 캐시
  bool _isSuperAdmin = false; // 플랫폼 관리자 여부
  bool _printerSettingsLoading = false;
  String _generalPrinterValue = _kSystemDefaultPrinterValue;
  String _todoPrinterValue = _kSystemDefaultPrinterValue;
  List<String> _installedPrinters = const <String>[];

  @override
  void initState() {
    super.initState();
    _selectedThemeMode = AppThemeController.mode.value;
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncFabTabBarOverlay();
    });
  }

  void _syncFabTabBarOverlay() {
    _fabTabBarOverlay.sync(
      context,
      selectedIndex: _customTabIndex,
      tabs: const ['학원', '선생님', '일반'],
      onTabSelected: _selectSettingsTab,
    );
  }

  void _selectSettingsTab(int index) {
    setState(() {
      _prevTabIndex = _customTabIndex;
      _customTabIndex = index;
      _selectedType = index == 0
          ? SettingType.academy
          : (index == 1 ? SettingType.teachers : SettingType.general);
    });
    _fabTabBarOverlay.sync(
      context,
      selectedIndex: _customTabIndex,
      tabs: const ['학원', '선생님', '일반'],
      onTabSelected: _selectSettingsTab,
    );
  }

  @override
  void dispose() {
    _fabTabBarOverlay.dispose();
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

  Future<bool> _generalAiApiKeyConfigured() async {
    try {
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
  }

  Future<bool> _generalAiSummaryEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('ai_summary_enabled') ?? false;
  }

  String _previewThemeModeLabel(ThemeMode mode) {
    return mode == ThemeMode.dark ? '다크' : '기본';
  }

  _GeneralLaunchMode _currentLaunchMode() {
    if (_fullscreenEnabled) return _GeneralLaunchMode.fullscreen;
    if (_maximizeEnabled) return _GeneralLaunchMode.maximize;
    return _GeneralLaunchMode.defaultMode;
  }

  String _launchModeLabel(_GeneralLaunchMode mode) {
    switch (mode) {
      case _GeneralLaunchMode.defaultMode:
        return '기본';
      case _GeneralLaunchMode.fullscreen:
        return '전체화면';
      case _GeneralLaunchMode.maximize:
        return '최대창';
    }
  }

  Future<void> _applyLaunchMode(_GeneralLaunchMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    switch (mode) {
      case _GeneralLaunchMode.defaultMode:
        setState(() {
          _fullscreenEnabled = false;
          _maximizeEnabled = false;
        });
        await prefs.setBool('fullscreen_enabled', false);
        await prefs.setBool('maximize_enabled', false);
        break;
      case _GeneralLaunchMode.fullscreen:
        setState(() {
          _fullscreenEnabled = true;
          _maximizeEnabled = false;
        });
        await prefs.setBool('fullscreen_enabled', true);
        await prefs.setBool('maximize_enabled', false);
        break;
      case _GeneralLaunchMode.maximize:
        setState(() {
          _fullscreenEnabled = false;
          _maximizeEnabled = true;
        });
        await prefs.setBool('fullscreen_enabled', false);
        await prefs.setBool('maximize_enabled', true);
        break;
    }
  }

  Future<void> _openPreviewThemeMenu(PreviewAcademyPanelStyle style) async {
    final box = _previewThemeMenuAnchorKey.currentContext?.findRenderObject()
        as RenderBox?;
    if (box == null) return;

    final pickedId = await PreviewAcademyGlassMenu.show(
      context: context,
      anchor: box,
      style: style,
      selectedId: _selectedThemeMode.name,
      options: const [
        PreviewAcademyMenuOption(id: 'light', label: '기본'),
        PreviewAcademyMenuOption(id: 'dark', label: '다크'),
      ],
    );

    if (pickedId == null || !mounted) return;
    final next =
        pickedId == 'dark' ? ThemeMode.dark : ThemeMode.light;
    setState(() => _selectedThemeMode = next);
    AppThemeController.setMode(next);
  }

  Future<void> _openPreviewLaunchModeMenu(
    PreviewAcademyPanelStyle style,
  ) async {
    final box =
        _previewLaunchModeMenuAnchorKey.currentContext?.findRenderObject()
            as RenderBox?;
    if (box == null) return;

    final current = _currentLaunchMode();
    final pickedId = await PreviewAcademyGlassMenu.show(
      context: context,
      anchor: box,
      style: style,
      selectedId: current.name,
      options: const [
        PreviewAcademyMenuOption(id: 'defaultMode', label: '기본'),
        PreviewAcademyMenuOption(id: 'fullscreen', label: '전체화면'),
        PreviewAcademyMenuOption(id: 'maximize', label: '최대창'),
      ],
    );

    if (pickedId == null || !mounted) return;
    final next = _GeneralLaunchMode.values.firstWhere(
      (mode) => mode.name == pickedId,
    );
    await _applyLaunchMode(next);
  }

  Future<void> _openPreviewPrinterMenu(
    PreviewAcademyPanelStyle style, {
    required GlobalKey anchorKey,
    required String selectedValue,
    required void Function(String value) onSelected,
  }) async {
    if (_printerSettingsLoading) return;
    if (_installedPrinters.isEmpty) {
      await _loadPrinterRoutingSettings(refreshList: true);
      if (!mounted) return;
    }

    final box = anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;

    final options = _printerValuesForDropdown(selectedValue);
    final pickedId = await PreviewAcademyGlassMenu.show(
      context: context,
      anchor: box,
      style: style,
      selectedId: selectedValue,
      options: [
        for (final value in options)
          PreviewAcademyMenuOption(
            id: value,
            label: _printerLabel(value),
          ),
      ],
    );

    if (pickedId == null || !mounted) return;
    onSelected(pickedId);
  }

  Widget _buildGeneralPrinterSection(PreviewAcademyPanelStyle style) {
    return PreviewAcademyLabeledCardSection(
      style: style,
      title: '프린터',
      card: PreviewAcademyGroupedFieldsCard(
        style: style,
        rows: [
          PreviewAcademyInfoRow(
            label: '일반 인쇄',
            value: _printerLabel(_generalPrinterValue),
            showChevron: false,
            valueUsesHintStyle: true,
            trailingAlignsWithChevron: true,
            trailing: PreviewAcademyPaymentMenuAnchor(
              key: _previewGeneralPrinterMenuAnchorKey,
              style: style,
            ),
            onTap: _printerSettingsLoading
                ? null
                : () => _openPreviewPrinterMenu(
                      style,
                      anchorKey: _previewGeneralPrinterMenuAnchorKey,
                      selectedValue: _generalPrinterValue,
                      onSelected: (value) async {
                        setState(() => _generalPrinterValue = value);
                        await _savePrinterRoutingSettings(
                          channel: PrintRoutingChannel.general,
                          uiValue: value,
                        );
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('일반 인쇄 프린터가 저장되었습니다.'),
                            backgroundColor: _kSignatureGreen,
                          ),
                        );
                      },
                    ),
          ),
          PreviewAcademyInfoRow(
            label: '알림장 인쇄',
            value: _printerLabel(_todoPrinterValue),
            showChevron: false,
            valueUsesHintStyle: true,
            trailingAlignsWithChevron: true,
            trailing: PreviewAcademyPaymentMenuAnchor(
              key: _previewTodoPrinterMenuAnchorKey,
              style: style,
            ),
            onTap: _printerSettingsLoading
                ? null
                : () => _openPreviewPrinterMenu(
                      style,
                      anchorKey: _previewTodoPrinterMenuAnchorKey,
                      selectedValue: _todoPrinterValue,
                      onSelected: (value) async {
                        setState(() => _todoPrinterValue = value);
                        await _savePrinterRoutingSettings(
                          channel: PrintRoutingChannel.todoSheet,
                          uiValue: value,
                        );
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('알림장 인쇄 프린터가 저장되었습니다.'),
                            backgroundColor: _kSignatureGreen,
                          ),
                        );
                      },
                    ),
          ),
        ],
      ),
    );
  }

  Widget _buildGeneralAppSection(PreviewAcademyPanelStyle style) {
    final switchInactive = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF3A3A3C)
        : const Color(0xFFE5E5EA);

    return FutureBuilder<bool>(
      future: _generalAiApiKeyConfigured(),
      builder: (context, apiSnapshot) {
        final hasApiKey = apiSnapshot.data ?? false;
        return FutureBuilder<bool>(
          future: _generalAiSummaryEnabled(),
          builder: (context, enabledSnapshot) {
            final isEnabled = enabledSnapshot.data ?? false;
            return FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, packageSnapshot) {
                final ver = packageSnapshot.data?.version ?? '';
                final build = packageSnapshot.data?.buildNumber ?? '';
                final versionText = (ver.isEmpty && build.isEmpty)
                    ? '버전 확인 중...'
                    : '$ver+$build';

                return PreviewAcademyLabeledCardSection(
                  style: style,
                  title: '앱',
                  card: PreviewAcademyGroupedFieldsCard(
                    style: style,
                    rows: [
                      PreviewAcademyInfoRow(
                        label: '업데이트',
                        value: versionText,
                        onTap: () async {
                          await UpdateService.oneClickUpdate(context);
                        },
                      ),
                      PreviewAcademyInfoRow(
                        label: 'AI 요약',
                        value: '',
                        showChevron: false,
                        valueWidget: const SizedBox.shrink(),
                        trailing: PreviewAcademyIosSwitch(
                          value: hasApiKey && isEnabled,
                          onChanged: hasApiKey
                              ? (value) async {
                                  final prefs =
                                      await SharedPreferences.getInstance();
                                  await prefs.setBool(
                                    'ai_summary_enabled',
                                    value,
                                  );
                                  if (mounted) setState(() {});
                                }
                              : null,
                          inactiveColor: switchInactive,
                        ),
                      ),
                      PreviewAcademyInfoRow(
                        label: '테마',
                        value: _previewThemeModeLabel(_selectedThemeMode),
                        showChevron: false,
                        valueUsesHintStyle: true,
                        trailingAlignsWithChevron: true,
                        trailing: PreviewAcademyPaymentMenuAnchor(
                          key: _previewThemeMenuAnchorKey,
                          style: style,
                        ),
                        onTap: () => _openPreviewThemeMenu(style),
                      ),
                      PreviewAcademyInfoRow(
                        label: '실행',
                        value: _launchModeLabel(_currentLaunchMode()),
                        showChevron: false,
                        valueUsesHintStyle: true,
                        trailingAlignsWithChevron: true,
                        trailing: PreviewAcademyPaymentMenuAnchor(
                          key: _previewLaunchModeMenuAnchorKey,
                          style: style,
                        ),
                        onTap: () => _openPreviewLaunchModeMenu(style),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildGeneralSettings() {
    final style = _previewAcademyPanelStyle(context)!;

    return _buildPreviewAcademySectionScope(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const FabStyleScreenMainTitle(title: '일반'),
          _buildGeneralAppSection(style),
          const SizedBox(
            height: FabTabBarTokens.previewAcademySectionListSpacing,
          ),
          _buildGeneralPrinterSection(style),
        ],
      ),
    );
  }

  Widget _buildPreviewOperatingHoursPills(
    PreviewAcademyPanelStyle previewStyle,
    DayOfWeek day,
  ) {
    final range = _operatingHours[day];
    final hasRange = range != null && !_isLastThirtyMarkerDay(day);

    if (!hasRange) {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => _pickOperatingStartTime(context, day),
          behavior: HitTestBehavior.opaque,
          child: Text(
            '시간 등록',
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: FabTabBarTokens.previewAcademyFieldDisplayStyle(
              previewStyle,
              isEmpty: true,
            ),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PreviewAcademyTimePill(
          style: previewStyle,
          text: PreviewAcademyTimePill.formatTimeOfDay(
            TimeOfDay(hour: range.startHour, minute: range.startMinute),
          ),
          onTap: () => _pickOperatingStartTime(context, day),
        ),
        const SizedBox(width: FabTabBarTokens.previewAcademyTimePillGap),
        PreviewAcademyTimePill(
          style: previewStyle,
          text: PreviewAcademyTimePill.formatTimeOfDay(
            TimeOfDay(hour: range.endHour, minute: range.endMinute),
          ),
          onTap: () => _pickOperatingEndTime(context, day),
        ),
      ],
    );
  }

  Future<void> _saveOperatingHoursToDb() async {
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
    final hours = await DataManager.instance.getOperatingHours();
    if (!mounted) return;
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
      _syncPreviewOperatingDaysActiveFromHours();
    });
  }

  bool _hasRegisteredOperatingHours(DayOfWeek day) {
    final range = _operatingHours[day];
    return range != null && !_isLastThirtyMarkerDay(day);
  }

  Future<void> _pickOperatingStartTime(
    BuildContext context,
    DayOfWeek day,
  ) async {
    final isNew = !_hasRegisteredOperatingHours(day);
    final range = _operatingHours[day];
    final initial = !isNew && range != null
        ? TimeOfDay(hour: range.startHour, minute: range.startMinute)
        : const TimeOfDay(hour: 9, minute: 0);
    final picked = await AppTimePickerDialog.show(
      context: context,
      title: day.koreanName,
      initialTime: initial,
    );
    if (picked == null) return;

    setState(() {
      final existing = _operatingHours[day];
      if (!isNew && existing != null) {
        _operatingHours[day] = TimeRange(
          startHour: picked.hour,
          startMinute: picked.minute,
          endHour: existing.endHour,
          endMinute: existing.endMinute,
        );
      } else {
        _operatingHours[day] = TimeRange(
          startHour: picked.hour,
          startMinute: picked.minute,
          endHour: (picked.hour + 1) % 24,
          endMinute: picked.minute,
        );
      }
      _previewOperatingDaysActive.add(day);
    });

    if (isNew) {
      await _pickOperatingEndTime(context, day, fromRegistration: true);
      return;
    }
    await _saveOperatingHoursToDb();
  }

  Future<void> _pickOperatingEndTime(
    BuildContext context,
    DayOfWeek day, {
    bool fromRegistration = false,
  }) async {
    if (!_hasRegisteredOperatingHours(day)) {
      if (fromRegistration) {
        await _saveOperatingHoursToDb();
        return;
      }
      await _pickOperatingStartTime(context, day);
      return;
    }

    final range = _operatingHours[day]!;
    final picked = await AppTimePickerDialog.show(
      context: context,
      title: day.koreanName,
      initialTime: TimeOfDay(hour: range.endHour, minute: range.endMinute),
    );
    if (picked == null) {
      if (fromRegistration) {
        await _saveOperatingHoursToDb();
      }
      return;
    }

    setState(() {
      _operatingHours[day] = TimeRange(
        startHour: range.startHour,
        startMinute: range.startMinute,
        endHour: picked.hour,
        endMinute: picked.minute,
      );
      _previewOperatingDaysActive.add(day);
    });
    await _saveOperatingHoursToDb();
  }

  Future<void> _openPreviewBreakTimesDialog(
    BuildContext context,
    DayOfWeek day,
  ) async {
    final previewStyle = _previewAcademyPanelStyle(context);
    if (previewStyle == null) return;

    final range = _operatingHours[day];
    if (range == null || _isLastThirtyMarkerDay(day)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('먼저 운영시간을 등록하세요.')),
      );
      return;
    }

    final initialBreaks = (_breakTimes[day] ?? [])
        .map(
          (b) => PreviewAcademyBreakTimeRange(
            startHour: b.startHour,
            startMinute: b.startMinute,
            endHour: b.endHour,
            endMinute: b.endMinute,
          ),
        )
        .toList();

    final result = await PreviewAcademyBreakTimesSheet.show(
      context: context,
      style: previewStyle,
      title: day.koreanName,
      initialBreaks: initialBreaks,
    );
    if (result == null) return;

    setState(() {
      _breakTimes[day] = result
          .map(
            (b) => TimeRange(
              startHour: b.startHour,
              startMinute: b.startMinute,
              endHour: b.endHour,
              endMinute: b.endMinute,
            ),
          )
          .toList();
    });
    await _saveOperatingHoursToDb();
  }

  void _togglePreviewBreakTimes(DayOfWeek day) {
    if (!_hasRegisteredOperatingHours(day)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('먼저 운영시간을 등록하세요.')),
      );
      return;
    }

    setState(() {
      if (_previewBreakTimesExpanded.contains(day)) {
        _previewBreakTimesExpanded.remove(day);
      } else {
        _previewBreakTimesExpanded.add(day);
      }
    });
  }

  Future<void> _pickPreviewBreakRange({
    required DayOfWeek day,
    TimeRange? initial,
    required ValueChanged<TimeRange> onPicked,
  }) async {
    final startInitial = initial != null
        ? TimeOfDay(hour: initial.startHour, minute: initial.startMinute)
        : TimeOfDay.now();
    final start = await AppTimePickerDialog.show(
      context: context,
      title: day.koreanName,
      initialTime: startInitial,
    );
    if (start == null || !mounted) return;

    final endInitial = initial != null
        ? TimeOfDay(hour: initial.endHour, minute: initial.endMinute)
        : TimeOfDay(hour: (start.hour + 1) % 24, minute: start.minute);
    final end = await AppTimePickerDialog.show(
      context: context,
      title: day.koreanName,
      initialTime: endInitial,
    );
    if (end == null || !mounted) return;

    onPicked(
      TimeRange(
        startHour: start.hour,
        startMinute: start.minute,
        endHour: end.hour,
        endMinute: end.minute,
      ),
    );
    await _saveOperatingHoursToDb();
  }

  Future<void> _addPreviewBreakTime(DayOfWeek day) async {
    await _pickPreviewBreakRange(
      day: day,
      onPicked: (value) {
        setState(() {
          _breakTimes[day] ??= [];
          _breakTimes[day]!.add(value);
          _previewBreakTimesExpanded.add(day);
        });
      },
    );
  }

  Future<void> _editPreviewBreakTime(DayOfWeek day, int index) async {
    final breaks = _breakTimes[day];
    if (breaks == null || index >= breaks.length) return;
    await _pickPreviewBreakRange(
      day: day,
      initial: breaks[index],
      onPicked: (value) {
        setState(() {
          _breakTimes[day]![index] = value;
          _previewBreakTimesExpanded.add(day);
        });
      },
    );
  }

  Future<void> _deletePreviewBreakTime(DayOfWeek day, int index) async {
    setState(() {
      final breaks = _breakTimes[day];
      if (breaks == null || index >= breaks.length) return;
      breaks.removeAt(index);
      _previewBreakTimesExpanded.add(day);
    });
    await _saveOperatingHoursToDb();
  }

  String _previewOperatingHoursTimeLabel(DayOfWeek day) {
    final range = _operatingHours[day];
    if (range == null || _isLastThirtyMarkerDay(day)) {
      return '';
    }
    final start = PreviewAcademyTimePill.formatTimeOfDay(
      TimeOfDay(hour: range.startHour, minute: range.startMinute),
    );
    final end = PreviewAcademyTimePill.formatTimeOfDay(
      TimeOfDay(hour: range.endHour, minute: range.endMinute),
    );
    final breaks = _breakTimes[day] ?? [];
    if (breaks.isEmpty) {
      return '$start - $end';
    }
    final breakSummary = breaks
        .map(
          (b) =>
              '${PreviewAcademyTimePill.formatTimeOfDay(TimeOfDay(hour: b.startHour, minute: b.startMinute))}-${PreviewAcademyTimePill.formatTimeOfDay(TimeOfDay(hour: b.endHour, minute: b.endMinute))}',
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

    return PreviewAcademyLabeledCardSection(
      style: previewStyle,
      title: '운영 시간',
      card: Container(
        width: double.infinity,
        decoration: PreviewAcademyGroupedFieldsCard.cardDecoration(
          previewStyle,
          brightness: Theme.of(context).brightness,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: _buildPreviewOperatingHoursCardChildren(
            previewStyle,
            switchInactive,
          ),
        ),
      ),
    );
  }

  List<Widget> _buildPreviewOperatingHoursCardChildren(
    PreviewAcademyPanelStyle previewStyle,
    Color switchInactive,
  ) {
    final children = <Widget>[];
    for (final day in DayOfWeek.values) {
      if (children.isNotEmpty) {
        children.add(_previewOperatingDivider(previewStyle));
      }
      children.add(
        _buildPreviewOperatingHoursRow(previewStyle, day, switchInactive),
      );
      children.add(_buildPreviewBreakTimesInlineSection(previewStyle, day));
    }
    return children;
  }

  Widget _buildPreviewBreakTimesInlineSection(
    PreviewAcademyPanelStyle previewStyle,
    DayOfWeek day,
  ) {
    final isExpanded = _previewBreakTimesExpanded.contains(day) &&
        _hasRegisteredOperatingHours(day);
    final breaks = _breakTimes[day] ?? [];

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: ClipRect(
        child: isExpanded
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (int i = 0; i < breaks.length; i++) ...[
                    _previewOperatingDivider(previewStyle),
                    _buildPreviewBreakTimeInlineRow(
                      previewStyle,
                      day,
                      i,
                      breaks[i],
                    ),
                  ],
                  _previewOperatingDivider(previewStyle),
                  _buildPreviewBreakTimeAddInlineRow(previewStyle, day),
                ],
              )
            : const SizedBox(width: double.infinity),
      ),
    );
  }

  Widget _previewOperatingDivider(PreviewAcademyPanelStyle previewStyle) {
    return Divider(
      height: 1,
      thickness: 1,
      indent: FabTabBarTokens.previewAcademyGroupedRowPaddingHorizontal,
      endIndent: FabTabBarTokens.previewAcademyGroupedRowPaddingHorizontal,
      color: previewStyle.divider,
    );
  }

  Widget _buildPreviewOperatingHoursRow(
    PreviewAcademyPanelStyle previewStyle,
    DayOfWeek day,
    Color switchInactive,
  ) {
    final isActive = _previewOperatingDayIsActive(day);
    final canExpand = isActive && _hasRegisteredOperatingHours(day);
    final isExpanded = _previewBreakTimesExpanded.contains(day);

    return SizedBox(
      height: FabTabBarTokens.previewAcademyOperatingRowHeight,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: canExpand ? () => _togglePreviewBreakTimes(day) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal:
                  FabTabBarTokens.previewAcademyGroupedRowPaddingHorizontal,
            ),
            child: Row(
              children: [
                Text(
                  day.koreanName,
                  style: FabTabBarTokens.previewRowLabelStyle(previewStyle),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: isActive
                        ? Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                fit: FlexFit.loose,
                                child: IntrinsicWidth(
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: _buildPreviewOperatingHoursPills(
                                      previewStyle,
                                      day,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                isExpanded
                                    ? Icons.keyboard_arrow_down
                                    : Icons.chevron_right,
                                size: FabTabBarTokens.previewAcademyChevronSize,
                                color: previewStyle.chevron,
                              ),
                            ],
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
                const SizedBox(width: 16),
                PreviewAcademyIosSwitch(
                  key: ValueKey('preview-hours-switch-${day.name}'),
                  value: isActive,
                  inactiveColor: switchInactive,
                  onChanged: (enabled) {
                    setState(() {
                      if (enabled) {
                        _previewOperatingDaysActive.add(day);
                      } else {
                        _previewOperatingDaysActive.remove(day);
                        _previewBreakTimesExpanded.remove(day);
                        _operatingHours[day] = null;
                        _breakTimes[day] = [];
                      }
                    });
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPreviewBreakTimeInlineRow(
    PreviewAcademyPanelStyle previewStyle,
    DayOfWeek day,
    int index,
    TimeRange breakTime,
  ) {
    return SizedBox(
      height: FabTabBarTokens.previewAcademyOperatingRowHeight,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => _editPreviewBreakTime(day, index),
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal:
                  FabTabBarTokens.previewAcademyGroupedRowPaddingHorizontal,
            ),
            child: Row(
              children: [
                Text(
                  '휴식 ${index + 1}',
                  style: FabTabBarTokens.previewRowLabelStyle(previewStyle),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        PreviewAcademyTimePill(
                          style: previewStyle,
                          text: PreviewAcademyTimePill.formatTimeOfDay(
                            TimeOfDay(
                              hour: breakTime.startHour,
                              minute: breakTime.startMinute,
                            ),
                          ),
                        ),
                        const SizedBox(
                          width: FabTabBarTokens.previewAcademyTimePillGap,
                        ),
                        PreviewAcademyTimePill(
                          style: previewStyle,
                          text: PreviewAcademyTimePill.formatTimeOfDay(
                            TimeOfDay(
                              hour: breakTime.endHour,
                              minute: breakTime.endMinute,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => _deletePreviewBreakTime(day, index),
                  behavior: HitTestBehavior.opaque,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        Icons.close,
                        size: 18,
                        color: previewStyle.hint,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPreviewBreakTimeAddInlineRow(
    PreviewAcademyPanelStyle previewStyle,
    DayOfWeek day,
  ) {
    return PreviewAcademyCardAddActionRow(
      style: previewStyle,
      label: '휴식 추가',
      onTap: () => _addPreviewBreakTime(day),
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
    final containerRadius =
        isPreview ? FabTabBarTokens.previewAcademyGroupedCardRadius : 16.0;
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
                icon: const Icon(Icons.add, color: _kSignatureGreen, size: 18),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF18181A), // 컨테이너와 동일하게
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: Color(0xFF1F1F1F), width: 3), // 아웃라인 카드 스타일(배경색)
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
                          onEnter: (_) => setState(
                              () => _hoveredOperatingHourCards.add(dayIndex)),
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
                                            color: Colors.white, fontSize: 13)),
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
                                        dialogBackgroundColor: kDlgBg,
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
                                      hour: currentRange.endHour,
                                      minute: currentRange.endMinute),
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
                                        dialogBackgroundColor: kDlgBg,
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
                                              startMinute:
                                                  breakTime.startMinute,
                                              endHour: breakTime.endHour,
                                              endMinute: breakTime.endMinute,
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
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        _formatTimeOfDay(TimeOfDay(
                                            hour:
                                                _operatingHours[day]!.startHour,
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
                                            hour: _operatingHours[day]!.endHour,
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
                                    fontSize: 14, fontWeight: FontWeight.w500),
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
                            final TimeOfDay? newStart = await showTimePicker(
                              context: context,
                              initialTime: TimeOfDay(
                                  hour: breakTime.startHour,
                                  minute: breakTime.startMinute),
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
                                    dialogBackgroundColor: kDlgBg,
                                    timePickerTheme: const TimePickerThemeData(
                                      backgroundColor: Color(0xFF18181A),
                                      hourMinuteColor: _kSignatureGreen,
                                      hourMinuteTextColor: Colors.white,
                                      dialHandColor: _kSignatureGreen,
                                      dialBackgroundColor: Color(0xFF18181A),
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
                                      ...GlobalMaterialLocalizations.delegates,
                                    ],
                                    child: Builder(
                                      builder: (context) {
                                        return MediaQuery(
                                          data: MediaQuery.of(context).copyWith(
                                              alwaysUse24HourFormat: false),
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
                                    dialogBackgroundColor: kDlgBg,
                                    timePickerTheme: const TimePickerThemeData(
                                      backgroundColor: Color(0xFF18181A),
                                      hourMinuteColor: _kSignatureGreen,
                                      hourMinuteTextColor: Colors.white,
                                      dialHandColor: _kSignatureGreen,
                                      dialBackgroundColor: Color(0xFF18181A),
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
                                      ...GlobalMaterialLocalizations.delegates,
                                    ],
                                    child: Builder(
                                      builder: (context) {
                                        return MediaQuery(
                                          data: MediaQuery.of(context).copyWith(
                                              alwaysUse24HourFormat: false),
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
                                  _breakTimes[day]?.indexOf(breakTime) ?? -1;
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
          backgroundColor: kDlgBg,
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
            dialogBackgroundColor: kDlgBg,
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
              dialogBackgroundColor: kDlgBg,
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
    if (!_usePreviewAcademyUi && !widget.previewUseFabStyleTabBar) return null;
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
            horizontal:
                FabTabBarTokens.previewAcademySectionScopePaddingHorizontal,
          ),
          child: child,
        ),
      ),
    );
  }

  Future<void> _saveAcademyProfileSettings() async {
    final academySettings = AcademySettings(
      name: _academyNameController.text.trim(),
      address: _academyAddressController.text.trim(),
      slogan: _sloganController.text.trim(),
      defaultCapacity: int.tryParse(_capacityController.text.trim()) ?? 30,
      lessonDuration: int.tryParse(_lessonDurationController.text.trim()) ?? 50,
      logo: _academyLogo,
      sessionCycle: int.tryParse(_courseCountController.text.trim()) ?? 1,
      activeExamSeasonId:
          DataManager.instance.academySettings.activeExamSeasonId,
    );
    DataManager.instance.paymentType = _paymentType;
    await DataManager.instance.saveAcademySettings(academySettings);
    await DataManager.instance.savePaymentType(_paymentType);
  }

  Future<void> _previewAcademyFieldTap(String fieldLabel) async {
    if (fieldLabel != '기준 수강 횟수') return;
    final style = _previewAcademyPanelStyle(context);
    if (style == null) return;
    final result = await PreviewAcademySingleNumberInputSheet.show(
      context: context,
      style: style,
      title: '수업',
      label: '기준 수강 횟수',
      emptyHintText: '회',
      initialValue: _courseCountController.text,
    );
    if (result == null || !mounted) return;
    setState(() {
      _courseCountController.text = result;
    });
    await _saveAcademyProfileSettings();
  }

  Future<void> _openPreviewAcademyCapacityDialog(
    PreviewAcademyPanelStyle style, {
    PreviewAcademyCapacityField initialFocusField =
        PreviewAcademyCapacityField.capacity,
  }) async {
    final result = await PreviewAcademyCapacityInputSheet.show(
      context: context,
      style: style,
      initialValues: PreviewAcademyCapacityValues(
        capacity: _capacityController.text,
        lessonDurationMinutes: _lessonDurationController.text,
      ),
      initialFocusField: initialFocusField,
    );
    if (result != null && mounted) {
      setState(() {
        _capacityController.text = result.capacity;
        _lessonDurationController.text = result.lessonDurationMinutes;
      });
      await _saveAcademyProfileSettings();
    }
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
      await _saveAcademyProfileSettings();
    }
  }

  Future<void> _openPreviewPaymentMenu(PreviewAcademyPanelStyle style) async {
    final box = _previewPaymentMenuAnchorKey.currentContext?.findRenderObject()
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
        _paymentType =
            pickedId == 'monthly' ? PaymentType.monthly : PaymentType.perClass;
      });
      await _saveAcademyProfileSettings();
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
          const FabStyleScreenMainTitle(title: '학원정보'),
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
                      backgroundColor: FabTabBarTokens.paletteFor(
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
                  vertical:
                      FabTabBarTokens.previewAcademyChangeButtonPaddingVertical,
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
          onTap: () => _openPreviewAcademyCapacityDialog(
            academyStyle,
            initialFocusField: PreviewAcademyCapacityField.capacity,
          ),
        ),
        PreviewAcademyInfoRow(
          label: '수업 시간',
          value: _previewLessonDurationValue(),
          onTap: () => _openPreviewAcademyCapacityDialog(
            academyStyle,
            initialFocusField: PreviewAcademyCapacityField.lessonDuration,
          ),
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
                      int.tryParse(_lessonDurationController.text.trim()) ?? 50,
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
    if (_usePreviewAcademyUi) {
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
                          decoration: _academyFieldDecoration(context, '학원명'),
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
                          decoration: _academyFieldDecoration(context, '학원 주소'),
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
                          decoration: _academyFieldDecoration(context, '슬로건'),
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
                                  color:
                                      academyStyle?.inputText ?? Colors.white,
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
                                  color:
                                      academyStyle?.inputText ?? Colors.white,
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
                                  color:
                                      academyStyle?.inputText ?? Colors.white,
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
    final content = Column(
      children: [
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
      body: content,
    );
  }

  Future<void> _pickLogoImage() async {
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
        await _saveAcademyProfileSettings();
      } else {
        print('[DEBUG] _pickLogoImage: result is null or bytes is null');
      }
    }
  }

  Future<void> _selectOperatingHours(
      BuildContext context, DayOfWeek day) async {
    await _pickOperatingStartTime(context, day);
  }

  void _showAddTeacherDialog() async {
    await TeacherRegistrationDialog.show(
      context: context,
      onSave: (teacher) {
        DataManager.instance.addTeacher(teacher);
      },
    );
  }

  Widget _buildTeacherSettings() {
    final teacherStyle = _previewAcademyPanelStyle(context)!;

    return _buildPreviewAcademySectionScope(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const FabStyleScreenMainTitle(title: '선생님'),
          ValueListenableBuilder<List<Teacher>>(
            valueListenable: DataManager.instance.teachersNotifier,
            builder: (context, teachers, _) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildTeacherAvatarStack(teachers),
                  const SizedBox(
                    height: FabTabBarTokens.previewAcademySectionListSpacing,
                  ),
                  PreviewAcademyGroupedRowsCard(
                    style: teacherStyle,
                    rows: [
                      if (teachers.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: FabTabBarTokens
                                .previewAcademyGroupedRowPaddingHorizontal,
                            vertical: FabTabBarTokens
                                .previewAcademyGroupedRowPaddingVertical,
                          ),
                          child: Center(
                            child: Text(
                              '등록된 선생님이 없습니다.',
                              style: FabTabBarTokens
                                  .previewAcademyTwoLineSubtitleStyle(
                                      teacherStyle),
                            ),
                          ),
                        )
                      else
                        for (final t in teachers)
                          _buildTeacherRow(t, teacherStyle),
                      _buildTeacherAddInlineRow(teacherStyle),
                    ],
                  ),
                  const SizedBox(
                    height: FabTabBarTokens.previewAcademySectionListSpacing,
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  /// 학원 탭 「휴식 추가」와 동일한 인라인 행 스타일.
  Widget _buildTeacherAddInlineRow(PreviewAcademyPanelStyle style) {
    return Opacity(
      opacity: _isOwner ? 1.0 : 0.45,
      child: PreviewAcademyCardAddActionRow(
        style: style,
        label: '선생님 추가',
        onTap: _isOwner ? _showAddTeacherDialog : null,
      ),
    );
  }

  /// 선생님 프로필 사진을 겹쳐 쌓아 보여준다. (로고 대비 15% 작은 원)
  Widget _buildTeacherAvatarStack(List<Teacher> teachers) {
    final Color borderColor = context.yggSurfaceBase;
    const double radius = FabTabBarTokens.previewTeacherAvatarRadius;
    const double diameter = radius * 2;
    const double overlap =
        diameter * FabTabBarTokens.previewTeacherAvatarOverlapFraction;
    const double step = diameter - overlap;

    if (teachers.isEmpty) {
      return Center(
        child: _buildTeacherAvatar(
          null,
          radius: radius,
          borderColor: borderColor,
        ),
      );
    }

    final double totalWidth = diameter + step * (teachers.length - 1);
    return SizedBox(
      height: diameter,
      child: Center(
        child: SizedBox(
          width: totalWidth,
          height: diameter,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // 뒤에서부터 그려 맨 앞(리스트 첫 번째) 프로필이 z-order 최상단에 오게 한다.
              for (int i = teachers.length - 1; i >= 0; i--)
                Positioned(
                  left: step * i,
                  top: 0,
                  child: _buildTeacherAvatar(
                    teachers[i],
                    radius: radius,
                    borderColor: borderColor,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 단일 선생님 아바타. [borderColor]가 있으면 배경색 테두리로 겹침을 구분한다.
  Widget _buildTeacherAvatar(
    Teacher? t, {
    required double radius,
    Color? borderColor,
  }) {
    const double borderWidth = FabTabBarTokens.previewTeacherAvatarBorderWidth;
    ImageProvider? img;
    if ((t?.avatarUrl ?? '').toString().isNotEmpty) {
      img = NetworkImage(t!.avatarUrl!);
    }
    final Color bg = _parseAvatarColor(t?.avatarPresetColor);
    final String label = (t?.avatarPresetInitial != null &&
            t!.avatarPresetInitial!.isNotEmpty)
        ? t.avatarPresetInitial!
        : _avatarInitials(t?.name ?? '');
    final double labelFontSize =
        ((radius - 8).clamp(10.0, radius)).toDouble();

    Widget avatar = CircleAvatar(
      radius: radius,
      backgroundColor: img == null ? bg : null,
      backgroundImage: img,
      child: (img == null && (t?.avatarUseIcon ?? false))
          ? Icon(Icons.person, color: Colors.white, size: radius)
          : (img == null
              ? Text(
                  label,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: labelFontSize,
                    fontWeight: FontWeight.w900,
                  ),
                )
              : null),
    );

    if (borderColor != null && borderWidth > 0) {
      avatar = Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: borderColor, width: borderWidth),
        ),
        child: avatar,
      );
    }
    return avatar;
  }

  Color _parseAvatarColor(String? raw) {
    final value = (raw ?? '').trim();
    if (value.isEmpty) return const Color(0xFF2A2A2A);
    var hex = value.replaceAll('#', '');
    if (hex.length == 6) hex = 'FF$hex';
    final parsed = int.tryParse(hex, radix: 16);
    if (parsed == null) return const Color(0xFF2A2A2A);
    return Color(parsed);
  }

  String _avatarInitials(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    return trimmed.characters.first.toString();
  }

  /// 그룹 카드 안 선생님 한 줄(2줄: 이름 + 역할/설명).
  Widget _buildTeacherRow(Teacher t, PreviewAcademyPanelStyle style) {
    final role = getTeacherRoleLabel(t.role);
    final desc = t.description.trim();
    final subtitle = desc.isEmpty ? role : '$role · $desc';
    return PreviewAcademyTwoLineRow(
      key: ValueKey(t),
      style: style,
      leading: _buildTeacherAvatar(t, radius: 22),
      title: t.name,
      subtitle: subtitle,
      onTap: () => _openTeacherEditor(t),
    );
  }

  Future<void> _openTeacherEditor(Teacher t) async {
    if (!_isOwner) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('원장만 수정/삭제할 수 있습니다.')),
      );
      return;
    }

    final isOwnerTeacher = TeacherRegistrationDialog.isOwnerTeacher(t);
    await TeacherRegistrationDialog.show(
      context: context,
      teacher: t,
      onSave: (updatedTeacher) {
        final idx = DataManager.instance.teachersNotifier.value.indexOf(t);
        if (idx != -1) {
          DataManager.instance.updateTeacher(idx, updatedTeacher);
        }
      },
      onDelete: isOwnerTeacher
          ? null
          : () async {
              final idx = DataManager.instance.teachersNotifier.value.indexOf(t);
              if (idx != -1) {
                await DataManager.instance.deleteTeacher(idx);
              }
            },
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
              bottom: FabTabBarTokens.fabStyleScreenTabBarBottomPadding,
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
              bottom: FabTabBarTokens.fabStyleScreenTabBarBottomPadding,
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
              bottom: FabTabBarTokens.fabStyleScreenTabBarBottomPadding,
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
