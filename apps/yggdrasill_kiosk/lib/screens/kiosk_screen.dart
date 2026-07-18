import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yggdrasill_ui/yggdrasill_ui.dart';

import '../models/kiosk_models.dart';
import '../services/kiosk_api_service.dart';
import '../services/weather_service.dart';
import '../widgets/attendance_sheet.dart';

class KioskScreen extends StatefulWidget {
  const KioskScreen({super.key});

  @override
  State<KioskScreen> createState() => _KioskScreenState();
}

enum _AppPhase { loading, configurationError, pairing, ready, error }

class _KioskScreenState extends State<KioskScreen> with WidgetsBindingObserver {
  static const _tokenKey = 'kiosk.deviceToken';
  static const _deviceIdKey = 'kiosk.deviceId';

  final _weatherService = WeatherService();
  KioskApiService? _api;
  KioskSession? _session;
  PairingState? _pairing;
  String _deviceId = '';
  BootstrapData? _bootstrap;
  List<StudentVisit> _students = const [];
  WeatherInfo? _weather;
  _AppPhase _phase = _AppPhase.loading;
  String _message = '키오스크를 준비하고 있습니다.';
  bool _sheetOpen = false;
  bool _refreshing = false;
  Timer? _clockTimer;
  Timer? _pollTimer;
  Timer? _pairTimer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    unawaited(_initialize());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clockTimer?.cancel();
    _pollTimer?.cancel();
    _pairTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _session != null) {
      unawaited(_refresh());
    }
  }

  Future<void> _initialize() async {
    try {
      _api = await KioskApiService.create();
      final preferences = await SharedPreferences.getInstance();
      final token = preferences.getString(_tokenKey) ?? '';
      _deviceId = preferences.getString(_deviceIdKey) ?? '';
      if (_deviceId.isEmpty) {
        _deviceId = _createDeviceId();
        await preferences.setString(_deviceIdKey, _deviceId);
      }
      if (token.isNotEmpty) {
        _session = KioskSession(deviceId: _deviceId, token: token);
        await _refresh(initial: true);
      } else {
        await _beginPairing();
      }
    } on KioskConfigurationException catch (error) {
      _setPhase(_AppPhase.configurationError, error.message);
    } catch (error) {
      _setPhase(_AppPhase.error, '키오스크를 시작하지 못했습니다.\n$error');
    }
  }

  String _createDeviceId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final hex = bytes.map((value) => value.toRadixString(16).padLeft(2, '0'));
    return 'webos-${hex.join()}';
  }

  void _setPhase(_AppPhase phase, String message) {
    if (!mounted) return;
    setState(() {
      _phase = phase;
      _message = message;
    });
  }

  Future<void> _beginPairing() async {
    _pollTimer?.cancel();
    _pairTimer?.cancel();
    _session = null;
    _setPhase(_AppPhase.loading, '연결 PIN을 발급하고 있습니다.');
    try {
      final pairing = await _api!.beginPairing(
        deviceId: _deviceId,
        deviceName: '스탠바이미 출석 키오스크',
      );
      if (!mounted) return;
      setState(() {
        _pairing = pairing;
        _phase = _AppPhase.pairing;
      });
      _pairTimer = Timer.periodic(
        const Duration(seconds: 3),
        (_) => unawaited(_pollPairing()),
      );
      unawaited(_pollPairing());
    } catch (error) {
      _setPhase(_AppPhase.error, '연결 PIN을 발급하지 못했습니다.\n$error');
    }
  }

  Future<void> _pollPairing() async {
    final pairing = _pairing;
    if (pairing == null || _session != null) return;
    if (pairing.expiresAt != null &&
        pairing.expiresAt!.isBefore(DateTime.now())) {
      await _beginPairing();
      return;
    }
    try {
      final session = await _api!.pollPairing(pairing);
      if (session == null) return;
      _pairTimer?.cancel();
      _session = session;
      final preferences = await SharedPreferences.getInstance();
      await Future.wait([
        preferences.setString(_tokenKey, session.token),
        preferences.setString(_deviceIdKey, session.deviceId),
      ]);
      await _refresh(initial: true);
    } catch (_) {
      // 승인 대기 중 일시적인 네트워크 오류는 다음 폴링에서 재시도한다.
    }
  }

  Future<void> _refresh({bool initial = false}) async {
    final session = _session;
    if (session == null || _refreshing) return;
    _refreshing = true;
    if (initial) _setPhase(_AppPhase.loading, '학원 정보를 불러오고 있습니다.');
    try {
      final results = await Future.wait([
        _api!.bootstrap(session),
        _api!.listToday(session),
      ]);
      final bootstrap = results[0] as BootstrapData;
      final students = results[1] as List<StudentVisit>;
      if (!mounted) return;
      setState(() {
        _bootstrap = bootstrap;
        _students = students;
        _phase = _AppPhase.ready;
      });
      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => unawaited(_refresh()),
      );
      unawaited(_loadWeather(bootstrap.academy.address));
    } on KioskApiException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        final preferences = await SharedPreferences.getInstance();
        await preferences.remove(_tokenKey);
        await _beginPairing();
      } else if (initial) {
        _setPhase(_AppPhase.error, error.message);
      }
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _loadWeather(String address) async {
    final weather = await _weatherService.getWeather(address);
    if (mounted && weather != null) setState(() => _weather = weather);
  }

  Future<List<StudentVisit>> _search(String query) async {
    final session = _session;
    if (session == null) return const [];
    try {
      return await _api!.searchStudents(session, query);
    } catch (_) {
      return const [];
    }
  }

  Future<CheckInResult> _checkIn(StudentVisit student, String pin) async {
    final session = _session;
    if (session == null) {
      return const CheckInResult(
        success: false,
        code: 'session',
        message: '기기 연결이 만료되었습니다.',
      );
    }
    final result = await _api!.checkIn(session, student, pin);
    if (result.success) await _refresh();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const designSize = Size(3840, 2160);
        final scale = (constraints.maxWidth / designSize.width).clamp(
          0.0,
          constraints.maxHeight / designSize.height,
        );
        return ColoredBox(
          color: const Color(0xFF080A0F),
          child: Center(
            child: SizedBox(
              width: designSize.width * scale,
              height: designSize.height * scale,
              child: Transform.scale(
                scale: scale,
                alignment: Alignment.topLeft,
                child: SizedBox.fromSize(
                  size: designSize,
                  child: _buildDesign(),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDesign() {
    if (_phase != _AppPhase.ready) {
      return _buildSetup();
    }
    return Stack(
      children: [
        const Positioned.fill(child: _PremiumBackground()),
        Positioned.fill(child: _buildContent()),
        Positioned(
          right: 92,
          bottom: 82,
          child: AnimatedOpacity(
            opacity: _sheetOpen ? 0 : 1,
            duration: const Duration(milliseconds: 220),
            child: IgnorePointer(
              ignoring: _sheetOpen,
              child: YggGlassButton(
                onPressed: () => setState(() => _sheetOpen = true),
                padding: const EdgeInsets.symmetric(
                  horizontal: 48,
                  vertical: 30,
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.how_to_reg_rounded,
                      size: 42,
                      color: Colors.white,
                    ),
                    SizedBox(width: 20),
                    Text(
                      '출석체크',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 34,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          right: _sheetOpen ? 0 : -960,
          top: 0,
          bottom: 0,
          width: 930,
          child: AttendanceSheet(
            students: _students,
            onClose: () => setState(() => _sheetOpen = false),
            onSearch: _search,
            onCheckIn: _checkIn,
          ),
        ),
      ],
    );
  }

  Widget _buildContent() {
    final announcement = _bootstrap?.announcement;
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(120, 70, 120, 90),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                DateFormat('M월 d일 EEEE', 'ko_KR').format(_now),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 44,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -1,
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 22),
                child: Text(
                  '·',
                  style: TextStyle(color: Colors.white38, fontSize: 38),
                ),
              ),
              Text(
                _weather?.label ?? _bootstrap!.academy.name,
                style: const TextStyle(color: Colors.white54, fontSize: 34),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            DateFormat('HH:mm').format(_now),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 172,
              fontWeight: FontWeight.w200,
              height: 1.05,
              letterSpacing: -9,
            ),
          ),
          const SizedBox(height: 40),
          Expanded(
            child: announcement != null
                ? _AnnouncementView(announcement: announcement)
                : _PosterView(sheetOpen: _sheetOpen),
          ),
        ],
      ),
    );
  }

  Widget _buildSetup() {
    return Stack(
      children: [
        const Positioned.fill(child: _PremiumBackground()),
        Center(
          child: YggGlassSurface(
            padding: const EdgeInsets.symmetric(horizontal: 110, vertical: 90),
            borderRadius: BorderRadius.circular(54),
            child: SizedBox(
              width: 1180,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.account_tree_rounded,
                    color: Color(0xFF8CB9FF),
                    size: 100,
                  ),
                  const SizedBox(height: 42),
                  if (_phase == _AppPhase.pairing) ...[
                    const Text(
                      '기기 연결 PIN',
                      style: TextStyle(color: Colors.white70, fontSize: 39),
                    ),
                    const SizedBox(height: 32),
                    Text(
                      _pairing!.pin,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 126,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 34,
                      ),
                    ),
                    const SizedBox(height: 38),
                    const Text(
                      '관리자 화면에서 PIN을 입력하면 자동으로 연결됩니다.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54, fontSize: 30),
                    ),
                    const SizedBox(height: 32),
                    const CircularProgressIndicator(color: Color(0xFF8CB9FF)),
                  ] else ...[
                    Text(
                      _message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 35,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 42),
                    if (_phase == _AppPhase.loading)
                      const CircularProgressIndicator(color: Color(0xFF8CB9FF))
                    else
                      FilledButton.icon(
                        onPressed: () {
                          setState(() => _phase = _AppPhase.loading);
                          unawaited(_initialize());
                        },
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('다시 시도'),
                        style: FilledButton.styleFrom(
                          textStyle: const TextStyle(fontSize: 28),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 40,
                            vertical: 24,
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PremiumBackground extends StatelessWidget {
  const _PremiumBackground();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(-.35, -.65),
          radius: 1.45,
          colors: [Color(0xFF18273C), Color(0xFF0E1420), Color(0xFF07090E)],
          stops: [0, .52, 1],
        ),
      ),
    );
  }
}

class _AnnouncementView extends StatelessWidget {
  const _AnnouncementView({required this.announcement});
  final Announcement announcement;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 2700),
        child: YggGlassSurface(
          padding: const EdgeInsets.symmetric(horizontal: 150, vertical: 100),
          borderRadius: BorderRadius.circular(52),
          tint: const Color(0x94131721),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                announcement.title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 76,
                  fontWeight: FontWeight.w700,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 55),
              Flexible(
                child: SingleChildScrollView(
                  child: Text(
                    announcement.body,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 43,
                      height: 1.65,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PosterView extends StatelessWidget {
  const _PosterView({required this.sheetOpen});
  final bool sheetOpen;

  @override
  Widget build(BuildContext context) {
    return AnimatedPadding(
      duration: const Duration(milliseconds: 420),
      padding: EdgeInsets.only(right: sheetOpen ? 900 : 0),
      child: Image.asset(
        'assets/poster.png',
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
        isAntiAlias: true,
        errorBuilder: (context, error, stackTrace) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.image_outlined,
                color: Colors.white.withValues(alpha: .18),
                size: 140,
              ),
              const SizedBox(height: 25),
              const Text(
                'assets/poster.png에 포스터를 추가해 주세요.',
                style: TextStyle(color: Colors.white30, fontSize: 28),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
