import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'screens/main_screen.dart';
import 'screens/settings/settings_screen.dart';
import 'screens/student/student_screen.dart';
import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/timetable/timetable_screen.dart';
import 'services/data_manager.dart';
import 'services/sync_service.dart';
import 'models/memo.dart';
import 'services/ai_summary.dart';
import 'dart:async';
import 'services/exam_mode.dart';

// 테스트 전용: 전역 RawKeyboardListener의 autofocus를 끌 수 있는 플래그 (기본값: 유지)
const bool kDisableGlobalKbAutofocus = bool.fromEnvironment('DISABLE_GLOBAL_KB_AUTOFOCUS', defaultValue: false);

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  final prefs = await SharedPreferences.getInstance();
  final fullscreen = prefs.getBool('fullscreen_enabled') ?? false;
  final maximizeFlag = prefs.getBool('maximize_enabled') ?? false;
  // 창을 보여주기 전에 최소/초기 크기를 먼저 적용해 즉시 제한이 걸리도록 처리
  // Surface Pro 12" (2196x1464 @150% → 1464x976) 의 95% 기준 최소 크기
  const Size kMinSize = Size(1430, 950);
  final windowOptions = WindowOptions(
    minimumSize: kMinSize,
    size: (fullscreen || maximizeFlag) ? null : kMinSize,
    center: !(fullscreen || maximizeFlag),
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    if (fullscreen || maximizeFlag) {
      // 일부 플랫폼에서 show 직후 maximize 타이밍 이슈가 있어 약간 지연
      await Future.delayed(const Duration(milliseconds: 60));
      if (fullscreen) {
        try {
          await windowManager.setFullScreen(true);
        } catch (_) {
          await windowManager.maximize();
        }
      } else {
        await windowManager.maximize();
      }
    } else {
      await windowManager.center();
    }
    await windowManager.focus();
  });
  runApp(MyApp(maximizeOnStart: fullscreen || maximizeFlag));
}

class MyApp extends StatelessWidget {
  final bool maximizeOnStart;
  const MyApp({super.key, required this.maximizeOnStart});

  @override
  Widget build(BuildContext context) {
    // 크기/최소 크기 설정은 main()에서 선적용했습니다.
    return RawKeyboardListener(
      focusNode: FocusNode(),
      autofocus: !kDisableGlobalKbAutofocus,
      onKey: (event) async {
        if (event is RawKeyDownEvent && event.logicalKey == LogicalKeyboardKey.f11) {
          bool isFull = await windowManager.isFullScreen();
          if (isFull) {
            await windowManager.setFullScreen(false);
            await windowManager.maximize();
          } else {
            await windowManager.setFullScreen(true);
          }
        }
      },
      child: FutureBuilder<void>(
        future: () async {
          // 초기 데이터 로드 후 최초 1회 동기화
          await DataManager.instance.initialize();
          await SyncService.instance.runInitialSyncIfNeeded();
        }(),
        builder: (context, snapshot) {
          return MaterialApp(
            scaffoldMessengerKey: rootScaffoldMessengerKey,
            navigatorKey: rootNavigatorKey,
            title: 'Yggdrasill',
            // 로케일 설정 추가
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: const [
              Locale('en', 'US'), // 영어 (기본)
              Locale('ko', 'KR'), // 한국어
            ],
            locale: const Locale('ko', 'KR'), // 기본 로케일을 한국어로 설정
            theme: ThemeData(
              useMaterial3: true,
              scaffoldBackgroundColor: const Color(0xFF1F1F1F),
              appBarTheme: const AppBarTheme(
                toolbarHeight: 80,  // 기본 56에서 24px 추가
                backgroundColor: Color(0xFF1F1F1F),
              ),
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
              floatingActionButtonTheme: FloatingActionButtonThemeData(
                backgroundColor: const Color(0xFF1976D2),
                foregroundColor: Colors.white,
              ),
            ),
            builder: (context, child) {
              // Overlay를 직접 제공하여 Tooltip/Overlay.of(context) 요구 충족
              return Overlay(
                initialEntries: [
                  // 기본 컨텐츠 + 사이드 패널
                  OverlayEntry(builder: (ctx) => Stack(children: [
                    child ?? const SizedBox.shrink(),
                    const _GlobalMemoOverlay(),
                  ])),
                  // 메모 플로팅 배너 (FAB보다 아래)
                  OverlayEntry(builder: (ctx) => const _GlobalMemoFloatingBanners()),
                  // 시험기간 FAB/인디케이터 (최상단)
                  OverlayEntry(builder: (ctx) => const _GlobalExamOverlay()),
                ],
              );
            },
            home: const MainScreen(),
            routes: {
              '/settings': (context) => const SettingsScreen(),
              '/students': (context) => const StudentScreen(),
            },
          );
        },
      ),
    );
  }
}

class _GlobalMemoOverlay extends StatefulWidget {
  const _GlobalMemoOverlay();
  @override
  State<_GlobalMemoOverlay> createState() => _GlobalMemoOverlayState();
}

class _GlobalMemoOverlayState extends State<_GlobalMemoOverlay> {
  // 전역 패널 상태 공유 (앱 어디서나 동일 패널)
  final ValueNotifier<bool> _isOpen = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    // 앱 시작 시 메모 로드
    WidgetsBinding.instance.addPostFrameCallback((_) {
      DataManager.instance.loadMemos();
    });
  }

  @override
  Widget build(BuildContext context) {
    // TimetableScreen에서 정의한 위젯 재사용을 위해 import 사용
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: false,
        child: _MemoSlideOverlay(
          isOpenListenable: _isOpen,
          memosListenable: DataManager.instance.memosNotifier,
          onAddMemo: (ctx) async {
            final text = await showDialog<String>(
              context: context,
              builder: (_) => const _MemoInputDialog(),
            );
            if (text == null || text.trim().isEmpty) return;
            final now = DateTime.now();
            final memo = Memo(
              id: UniqueKey().toString(),
              original: text.trim(),
              summary: '요약 중...',
              scheduledAt: await AiSummaryService.extractDateTime(text.trim()),
              dismissed: false,
              createdAt: now,
              updatedAt: now,
            );
            await DataManager.instance.addMemo(memo);
            try {
              final summary = await AiSummaryService.summarize(memo.original);
              await DataManager.instance.updateMemo(memo.copyWith(summary: summary, updatedAt: DateTime.now()));
            } catch (_) {}
          },
          onEditMemo: (ctx, item) async {
            final edited = await showDialog<_MemoEditResult>(
              context: context,
              builder: (_) => _MemoEditDialog(initial: item.original, initialScheduledAt: item.scheduledAt),
            );
            if (edited == null) return;
            if (edited.action == _MemoEditAction.delete) {
              await DataManager.instance.deleteMemo(item.id);
              return;
            }
            final newOriginal = edited.text.trim();
            if (newOriginal.isEmpty) return;
            // 기존 메모 유지 후 필요한 필드만 업데이트 (요약은 비동기)
            var updated = item.copyWith(
              original: newOriginal,
              summary: '요약 중...',
              scheduledAt: edited.scheduledAt,
              updatedAt: DateTime.now(),
            );
            await DataManager.instance.updateMemo(updated);
            try {
              final summary = await AiSummaryService.summarize(newOriginal);
              updated = updated.copyWith(summary: summary, updatedAt: DateTime.now());
              await DataManager.instance.updateMemo(updated);
            } catch (_) {}
          },
        ),
      ),
    );
  }
}

class _GlobalMemoFloatingBanners extends StatefulWidget {
  const _GlobalMemoFloatingBanners();
  @override
  State<_GlobalMemoFloatingBanners> createState() => _GlobalMemoFloatingBannersState();
}

class _GlobalMemoFloatingBannersState extends State<_GlobalMemoFloatingBanners> {
  Timer? _ticker;
  // 세션 내에서만 유지되는 닫힘 기록 (앱 재시작 시 초기화)
  final Set<String> _sessionDismissed = <String>{};
  // 자정까지 유지되는 닫힘 기록(영속) - 일정 있는 메모용
  final Set<String> _persistDismissed = <String>{};
  // 일정 없는 메모 영구 해제 목록(메모 ID 기준)
  final Set<String> _persistDismissedUnscheduled = <String>{};

  String _keyFor(Memo m) {
    // 메모의 예정일(YYYYMMDD) 기준으로 키 생성 → 해당 날짜 자정까지 표시/해제 동작 유지
    final dt = m.scheduledAt ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${m.id}:${dt.year}${two(dt.month)}${two(dt.day)}';
  }

  Future<void> _loadPersistDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('memo_dismissed_today') ?? <String>[];
    _persistDismissed
      ..clear()
      ..addAll(list);
    final uns = prefs.getStringList('memo_dismissed_unscheduled') ?? <String>[];
    _persistDismissedUnscheduled
      ..clear()
      ..addAll(uns);
  }

  Future<void> _savePersistDismissed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('memo_dismissed_today', _persistDismissed.toList());
    await prefs.setStringList('memo_dismissed_unscheduled', _persistDismissedUnscheduled.toList());
  }

  @override
  void initState() {
    super.initState();
    // 주기적으로 현재 시간을 반영해 표시 대상 갱신
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    _loadPersistDismissed().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // FAB 버튼을 가리지 않도록 위로 띄움 (기존 FAB 하단 패딩과 동일 오프셋 적용)
    return Positioned(
      right: 24,
      bottom: 100,
      child: ValueListenableBuilder<List<Memo>>(
        valueListenable: DataManager.instance.memosNotifier,
        builder: (context, memos, _) {
          // 가까운 미래 순 정렬, 해제되지 않은 배너만
          final now = DateTime.now();
          final endOfToday = DateTime(now.year, now.month, now.day, 23, 59, 59, 999);
          // 디버그: 전체/필터 단계별 카운트
          print('[FLOAT][DEBUG] total memos=${memos.length}');
          final withSchedule = memos.where((m) => m.scheduledAt != null).toList();
          print('[FLOAT][DEBUG] with scheduledAt != null: ${withSchedule.length}');
          final notDismissedFlag = withSchedule.where((m) => !m.dismissed).toList();
          print('[FLOAT][DEBUG] !dismissed: ${notDismissedFlag.length}');
          final notSessionDismissed = notDismissedFlag.where((m) => !_sessionDismissed.contains(m.id)).toList();
          print('[FLOAT][DEBUG] !sessionDismissed: ${notSessionDismissed.length}');
          // 오늘(자정)까지 도래한 모든 일정 포함 (과거+오늘, 미래 제외)
          final dueUntilToday = notSessionDismissed.where((m) => !m.scheduledAt!.isAfter(endOfToday)).toList();
          print('[FLOAT][DEBUG] dueUntilToday(<= today EOD): ${dueUntilToday.length}');
          // 일정 있는 메모 중 오늘까지 + 오늘 날짜 키로 해제되지 않은 항목
          final scheduledCandidates = dueUntilToday
              .toList()
            ..sort((a, b) => a.scheduledAt!.compareTo(b.scheduledAt!));
          // 일정 없는 메모: 생성 시점부터 X 누르기 전까지 항상 표시(영구 해제 목록 제외)
          final unscheduledCandidates = memos
              .where((m) => m.scheduledAt == null && !m.dismissed && !_sessionDismissed.contains(m.id))
              .toList();
          print('[FLOAT][DEBUG] unscheduled candidates: ${unscheduledCandidates.length}');
          // 결합 후 정렬: (scheduledAt ?? createdAt) 오름차순 → 최신이 아래쪽
          DateTime sortKey(m) => (m.scheduledAt ?? m.createdAt);
          final combined = [...scheduledCandidates, ...unscheduledCandidates]
            ..sort((a, b) => sortKey(a).compareTo(sortKey(b)));
          print('[FLOAT][DEBUG] combined after sort: ${combined.length}');
          for (final m in combined) {
            print('[FLOAT][DEBUG] show memo id=${m.id}, when=${m.scheduledAt}, createdAt=${m.createdAt}');
          }
          if (combined.isEmpty) return const SizedBox.shrink();
          // 아래에서 위로 쌓기
          return Material(
            color: Colors.transparent,
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: combined.take(5).map((m) {
              return _MemoBanner(
                memo: m,
                onClose: () async {
                  setState(() {
                    _sessionDismissed.add(m.id);
                  });
                  // 일정이 지난 메모에서 X를 누른 경우에만 영구 해제(전역 DB 저장)
                  if (m.scheduledAt != null && DateTime.now().isAfter(m.scheduledAt!)) {
                    await DataManager.instance.updateMemo(
                      m.copyWith(dismissed: true, updatedAt: DateTime.now()),
                    );
                  }
                },
              );
            }).toList(),
            ),
          );
        },
      ),
    );
  }
}

// ---------------- 시험기간 모드 전역 오버레이 ----------------
class _GlobalExamOverlay extends StatefulWidget {
  const _GlobalExamOverlay();
  @override
  State<_GlobalExamOverlay> createState() => _GlobalExamOverlayState();
}

class _GlobalExamOverlayState extends State<_GlobalExamOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _indicatorCtrl;

  @override
  void initState() {
    super.initState();
    _indicatorCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  }

  @override
  void dispose() {
    _indicatorCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: false,
        child: ValueListenableBuilder<bool>(
          valueListenable: ExamModeService.instance.isOn,
          builder: (context, isOn, _) {
            if (!isOn) return const SizedBox.shrink();
            return Stack(
              children: [
                // 하단 전역 인디케이터(직선, 밝기 시퀀셜 애니메이션)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 3,
                  child: AnimatedBuilder(
                    animation: _indicatorCtrl,
                    builder: (context, _) {
                      return RepaintBoundary(child: _AnimatedLinearGlow(
                        progress: _indicatorCtrl.value,
                        baseColor: const Color(0xFFE53935),
                        dimOpacity: 0.35,
                        glowOpacity: 1.0,
                        bandFraction: 0.18,
                      ));
                    },
                  ),
                ),
                // 하단 중앙 FAB 클러스터: 기존 전역 FAB라인보다 더 아래 정렬 (정밀 조정)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 30, // 필요 시 더 낮추려면 값 감소 (예: 48/40)
                  child: Center(child: _ExamFabCluster()),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ExamFabCluster extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xCC202024),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white12),
          boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 10, spreadRadius: 2)],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ExamActionButton(icon: Icons.event_note, label: '일정', onPressed: () async {
              await showDialog(
                context: rootNavigatorKey.currentContext!,
                builder: (ctx) => const _ExamScheduleDialog(),
              );
            }),
            const SizedBox(width: 12),
            _ExamActionButton(icon: Icons.crop_free, label: '범위', onPressed: () {
              rootScaffoldMessengerKey.currentState?.showSnackBar(const SnackBar(content: Text('시험기간: 범위')));
            }),
            const SizedBox(width: 12),
            // 설정 버튼은 아이콘만
            _ExamIconOnlyButton(icon: Icons.settings, onPressed: () {
              rootScaffoldMessengerKey.currentState?.showSnackBar(const SnackBar(content: Text('시험기간: 설정')));
            }),
          ],
        ),
      ),
    );
  }
}

class _ExamActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  const _ExamActionButton({required this.icon, required this.label, required this.onPressed});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 49, // 10% 감소
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: onPressed,
          child: Ink(
            decoration: const ShapeDecoration(
              color: Color(0xFF1976D2),
              shape: StadiumBorder(side: BorderSide(color: Colors.transparent, width: 0)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white, size: 22),
                const SizedBox(width: 9),
                Text(label, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ExamIconOnlyButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  const _ExamIconOnlyButton({required this.icon, required this.onPressed});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 49, // 10% 감소
      width: 49,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: onPressed,
          child: Ink(
            decoration: const ShapeDecoration(
              color: Color(0xFF1976D2),
              shape: StadiumBorder(side: BorderSide(color: Colors.transparent, width: 0)),
            ),
            child: const Center(
              child: Icon(Icons.settings, color: Colors.white, size: 22),
            ),
          ),
        ),
      ),
    );
  }
}

/// 직선 모양을 유지하면서 밝기가 좌->우로 흐르는 효과
class _AnimatedLinearGlow extends StatelessWidget {
  final double progress; // 0..1
  final Color baseColor;
  final double dimOpacity;
  final double glowOpacity;
  final double bandFraction; // 화면폭 대비 하이라이트 밴드 비율(0..1)
  const _AnimatedLinearGlow({
    required this.progress,
    required this.baseColor,
    this.dimOpacity = 0.4,
    this.glowOpacity = 1.0,
    this.bandFraction = 0.2,
  });
  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _LinearGlowPainter(
        progress: progress,
        baseColor: baseColor,
        dimOpacity: dimOpacity,
        glowOpacity: glowOpacity,
        bandFraction: bandFraction,
      ),
    );
  }
}

class _LinearGlowPainter extends CustomPainter {
  final double progress;
  final Color baseColor;
  final double dimOpacity;
  final double glowOpacity;
  final double bandFraction;
  _LinearGlowPainter({
    required this.progress,
    required this.baseColor,
    required this.dimOpacity,
    required this.glowOpacity,
    required this.bandFraction,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width;
    final height = size.height;
    final Paint base = Paint()..color = baseColor.withOpacity(dimOpacity);
    canvas.drawRect(Rect.fromLTWH(0, 0, width, height), base);

    final double band = (width * bandFraction).clamp(24.0, width);
    final double center = progress * (width + band) - band / 2;
    final double left = (center - band / 2).clamp(0.0, width);
    final double right = (center + band / 2).clamp(0.0, width);
    if (right <= 0 || left >= width) return;

    final Rect rect = Rect.fromLTRB(left, 0, right, height);
    final Gradient grad = LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [
        baseColor.withOpacity(dimOpacity),
        baseColor.withOpacity(glowOpacity),
        baseColor.withOpacity(dimOpacity),
      ],
      stops: const [0.0, 0.5, 1.0],
    );
    final Paint glow = Paint()..shader = grad.createShader(rect);
    canvas.drawRect(rect, glow);
  }

  @override
  bool shouldRepaint(covariant _LinearGlowPainter old) {
    return old.progress != progress ||
        old.baseColor != baseColor ||
        old.dimOpacity != dimOpacity ||
        old.glowOpacity != glowOpacity ||
        old.bandFraction != bandFraction;
  }
}

class _ExamScheduleDialog extends StatelessWidget {
  const _ExamScheduleDialog();
  @override
  Widget build(BuildContext context) {
    final students = DataManager.instance.students;
    // 학교+학년 문자열 예: "대륜중 2학년"(교육단계도 반영 가능하지만 우선 학년 숫자만)
    final List<String> schoolGrade = students.map((s) {
      final school = s.student.school.trim();
      final grade = s.student.grade;
      return grade > 0 ? '$school ${grade}학년' : school;
    }).toSet().toList()
      ..sort();

    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: const Text('시험 일정 등록', style: TextStyle(color: Colors.white)),
      content: _ExamScheduleWizard(schoolGrade: schoolGrade),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('닫기', style: TextStyle(color: Colors.white70))),
      ],
    );
  }
}

class _ExamScheduleWizard extends StatefulWidget {
  final List<String> schoolGrade;
  const _ExamScheduleWizard({required this.schoolGrade});
  @override
  State<_ExamScheduleWizard> createState() => _ExamScheduleWizardState();
}

class _ExamScheduleWizardState extends State<_ExamScheduleWizard> {
  int _step = 0; // 0: 학교/학년 선택, 1: 날짜 다중 선택, 2: 시험명 매핑
  String? _selectedSchoolGrade;
  final Set<DateTime> _selectedDays = {};
  final Map<DateTime, List<String>> _titlesByDate = {};
  final TextEditingController _titleCtrl = TextEditingController();

  @override
  void dispose() { _titleCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 620,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: _buildStep(),
      ),
    );
  }

  Widget _buildStep() {
    if (_step == 0) {
      return Column(
        key: const ValueKey('step0'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('학교/학년 선택', style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(color: const Color(0xFF2A2A2A), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white24)),
            constraints: const BoxConstraints(maxHeight: 280),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: widget.schoolGrade.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
              itemBuilder: (context, i) {
                final item = widget.schoolGrade[i];
                final selected = _selectedSchoolGrade == item;
                return ListTile(
                  dense: true,
                  title: Text(item, style: TextStyle(color: selected ? Colors.white : Colors.white70)),
                  selected: selected,
                  onTap: () => setState(() => _selectedSchoolGrade = item),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _selectedSchoolGrade == null ? null : () => setState(() => _step = 1),
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
              child: const Text('다음'),
            ),
          ),
        ],
      );
    }
    if (_step == 1) {
      // 달력: 간단히 한 달 범위 다중 선택 (좌/우 이동 버튼 포함)
      final now = DateTime.now();
      DateTime _displayMonth = DateTime(now.year, now.month, 1);
      return StatefulBuilder(builder: (context, setStateSB) {
        Widget dayCell(DateTime d) {
          final dateOnly = DateTime(d.year, d.month, d.day);
          final sel = _selectedDays.contains(dateOnly);
          return GestureDetector(
            onTap: () {
              setStateSB(() {
                if (sel) _selectedDays.remove(dateOnly); else _selectedDays.add(dateOnly);
              });
            },
            child: Container(
              margin: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: sel ? const Color(0xFF1976D2) : Colors.transparent,
                border: Border.all(color: sel ? const Color(0xFF1976D2) : Colors.white24),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(child: Text('${d.day}', style: TextStyle(color: sel ? Colors.white : Colors.white70))),
            ),
          );
        }

        List<Widget> buildCalendar(DateTime month) {
          final first = DateTime(month.year, month.month, 1);
          final firstWeekday = first.weekday; // 1..7
          final leading = (firstWeekday - 1) % 7;
          final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
          final cells = <DateTime>[];
          for (int i = 0; i < leading; i++) { cells.add(first.subtract(Duration(days: leading - i))); }
          for (int d = 0; d < daysInMonth; d++) { cells.add(DateTime(month.year, month.month, d + 1)); }
          while (cells.length % 7 != 0) { cells.add(cells.last.add(const Duration(days: 1))); }
          return [
            Row(
              children: [
                IconButton(onPressed: () => setStateSB(() => _displayMonth = DateTime(_displayMonth.year, _displayMonth.month - 1, 1)), icon: const Icon(Icons.chevron_left, color: Colors.white70)),
                Expanded(child: Center(child: Text('${_displayMonth.year}.${_displayMonth.month}', style: const TextStyle(color: Colors.white)))),
                IconButton(onPressed: () => setStateSB(() => _displayMonth = DateTime(_displayMonth.year, _displayMonth.month + 1, 1)), icon: const Icon(Icons.chevron_right, color: Colors.white70)),
              ],
            ),
            const SizedBox(height: 6),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 7, mainAxisSpacing: 4, crossAxisSpacing: 4),
              itemCount: cells.length,
              itemBuilder: (context, i) => dayCell(cells[i]),
            )
          ];
        }

        return Column(
          key: const ValueKey('step1'),
          mainAxisSize: MainAxisSize.min,
          children: [
            ...buildCalendar(_displayMonth),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _selectedDays.isEmpty ? null : () => setState(() => _step = 2),
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
                child: const Text('다음'),
              ),
            ),
          ],
        );
      });
    }
    // step 2: 날짜별 시험명 추가
    final dates = _selectedDays.toList()..sort();
    return Column(
      key: const ValueKey('step2'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('시험 날짜', style: TextStyle(color: Colors.white70)),
            const Spacer(),
            TextButton.icon(onPressed: () => setState(() => _step = 1), icon: const Icon(Icons.add, size: 16), label: const Text('날짜 추가')),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          constraints: const BoxConstraints(maxHeight: 240),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: dates.length,
            itemBuilder: (context, i) {
              final d = dates[i];
              final key = DateTime(d.year, d.month, d.day);
              final titles = _titlesByDate[key] ?? [];
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${key.year}.${key.month}.${key.day}', style: const TextStyle(color: Colors.white)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        ...titles.map((t) => Chip(label: Text(t), backgroundColor: Colors.white12, deleteIcon: const Icon(Icons.close, size: 16), onDeleted: () { setState(() { _titlesByDate[key] = List.from(titles)..remove(t); }); })),
                        SizedBox(
                          width: 260,
                          child: Row(children: [
                            Expanded(child: TextField(controller: _titleCtrl, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(hintText: '시험명', hintStyle: TextStyle(color: Colors.white38), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2)))))),
                            const SizedBox(width: 6),
                            FilledButton(onPressed: () {
                              final t = _titleCtrl.text.trim();
                              if (t.isEmpty) return;
                              setState(() {
                                _titlesByDate[key] = [...titles, t];
                                _titleCtrl.clear();
                              });
                            }, style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)), child: const Text('추가')),
                          ]),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: () {
              // TODO: 저장 로직(추후 DB 반영)
              Navigator.of(context).pop();
              rootScaffoldMessengerKey.currentState?.showSnackBar(const SnackBar(content: Text('시험 일정이 임시 저장되었습니다.')));
            },
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
            child: const Text('저장'),
          ),
        ),
      ],
    );
  }
}

bool _isSameDay(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

// ---------------- 공유 메모 패널 위젯들 (전역용) ----------------
class _MemoSlideOverlay extends StatefulWidget {
  final ValueListenable<bool> isOpenListenable;
  final ValueListenable<List<Memo>> memosListenable;
  final Future<void> Function(BuildContext context) onAddMemo;
  final Future<void> Function(BuildContext context, Memo item) onEditMemo;
  const _MemoSlideOverlay({
    Key? key,
    required this.isOpenListenable,
    required this.memosListenable,
    required this.onAddMemo,
    required this.onEditMemo,
  }) : super(key: key);

  @override
  State<_MemoSlideOverlay> createState() => _MemoSlideOverlayState();
}

class _MemoSlideOverlayState extends State<_MemoSlideOverlay> {
  bool _hoveringEdge = false;
  bool _panelHovered = false;
  Timer? _closeTimer;
  // 터치 전용 드래그 상태 (엣지 오픈)
  bool _edgeTouchActive = false;
  Offset? _edgeDragStart;
  // 터치 전용 드래그 상태 (패널 닫기)
  bool _panelTouchActive = false;
  Offset? _panelDragStart;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      const double panelWidth = 99; // 기존 75에서 +24 확장
      return Stack(children: [
        // 패널이 열려 있을 때, 패널 바깥 영역을 탭/클릭하면 닫기
        ValueListenableBuilder<bool>(
          valueListenable: widget.isOpenListenable,
          builder: (context, open, _) {
            if (!open) return const SizedBox.shrink();
            return Positioned(
              left: 0,
              top: kToolbarHeight,
              bottom: 0,
              right: panelWidth,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _setOpen(false),
                onDoubleTap: () => _setOpen(false),
              ),
            );
          },
        ),
        Positioned(
          right: 0,
          top: kToolbarHeight,
          bottom: 0,
          width: 24,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 마우스 호버로 오픈 (기존 동작)
              MouseRegion(
                onEnter: (_) {
                  _hoveringEdge = true;
                  _setOpen(true);
                  _cancelCloseTimer();
                },
                onExit: (_) {
                  _hoveringEdge = false;
                  // 엣지에서 패널로 이동하는 순간에 닫기 타이머가 먼저 실행되며 깜빡임이 발생하므로
                  // 여기서는 닫기를 스케줄하지 않고, 패널 영역 MouseRegion.onExit에서만 닫도록 위임한다.
                  _cancelCloseTimer();
                },
                child: const SizedBox.shrink(),
              ),
              // 터치/펜 엣지 스와이프로 오픈
              Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (event) {
                  if (event.kind == PointerDeviceKind.touch || event.kind == PointerDeviceKind.stylus) {
                    _edgeTouchActive = true;
                    _edgeDragStart = event.position;
                  }
                },
                onPointerMove: (event) {
                  if (_edgeTouchActive && _edgeDragStart != null) {
                    final dx = event.position.dx - _edgeDragStart!.dx;
                    // 오른쪽 엣지에서 왼쪽으로 24px 이상 드래그 시 오픈
                    if (dx < -24) {
                      _setOpen(true);
                    }
                  }
                },
                onPointerUp: (event) {
                  _edgeTouchActive = false;
                  _edgeDragStart = null;
                },
                onPointerCancel: (event) {
                  _edgeTouchActive = false;
                  _edgeDragStart = null;
                },
              ),
            ],
          ),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: widget.isOpenListenable,
          builder: (context, open, _) {
            return AnimatedPositioned(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeInOut,
              right: open ? 0 : -panelWidth,
              top: kToolbarHeight,
              bottom: 0,
              width: panelWidth,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  MouseRegion(
                    onEnter: (_) {
                      _panelHovered = true;
                      _cancelCloseTimer(); // 패널에 진입하는 즉시 닫기 타이머 해제
                    },
                    onExit: (_) {
                      _panelHovered = false;
                      _scheduleMaybeClose(); // 패널을 벗어날 때에만 닫기 스케줄
                    },
                    child: const SizedBox.shrink(),
                  ),
                  // 패널 내부 터치 드래그로 닫기 (오른쪽으로 24px 이상)
                  Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: (event) {
                      if (event.kind == PointerDeviceKind.touch || event.kind == PointerDeviceKind.stylus) {
                        _panelTouchActive = true;
                        _panelDragStart = event.position;
                      }
                    },
                    onPointerMove: (event) {
                      if (_panelTouchActive && _panelDragStart != null) {
                        final dx = event.position.dx - _panelDragStart!.dx;
                        if (dx > 24) {
                          _setOpen(false);
                        }
                      }
                    },
                    onPointerUp: (_) {
                      _panelTouchActive = false;
                      _panelDragStart = null;
                      _scheduleMaybeClose();
                    },
                    onPointerCancel: (_) {
                      _panelTouchActive = false;
                      _panelDragStart = null;
                      _scheduleMaybeClose();
                    },
                    child: _MemoPanel(
                      memosListenable: widget.memosListenable,
                      onAddMemo: () => widget.onAddMemo(context),
                      onEditMemo: (m) => widget.onEditMemo(context, m),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ]);
    });
  }

  void _setOpen(bool value) {
    if (widget.isOpenListenable is ValueNotifier<bool>) {
      (widget.isOpenListenable as ValueNotifier<bool>).value = value;
    }
  }

  void _scheduleMaybeClose() {
    _closeTimer?.cancel();
    _closeTimer = Timer(const Duration(milliseconds: 220), () {
      if (!_hoveringEdge && !_panelHovered) {
        _setOpen(false);
      }
    });
  }

  void _cancelCloseTimer() {
    _closeTimer?.cancel();
    _closeTimer = null;
  }
}

class _MemoPanel extends StatelessWidget {
  final ValueListenable<List<Memo>> memosListenable;
  final VoidCallback onAddMemo;
  final void Function(Memo item) onEditMemo;
  const _MemoPanel({required this.memosListenable, required this.onAddMemo, required this.onEditMemo});

  @override
  Widget build(BuildContext context) {
    final double screenW = MediaQuery.of(context).size.width;
    // 최소창(≈1430)에서 12, 넓을수록 16까지 선형 증가
    const double minW = 1430;
    const double maxW = 2200;
    const double fsMin = 12;
    const double fsMax = 16;
    final double t = ((screenW - minW) / (maxW - minW)).clamp(0.0, 1.0);
    final double memoFontSize = fsMin + (fsMax - fsMin) * t;
    return Material(
      color: Colors.transparent,
      child: Container(
      decoration: const BoxDecoration(
        color: Color(0xFF18181A),
        border: Border(left: BorderSide(color: Color(0xFF2A2A2A), width: 1)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          SizedBox(
            height: 40,
            child: IconButton(
              onPressed: onAddMemo,
              icon: const Icon(Icons.add, color: Colors.white, size: 22),
              tooltip: '+ 메모 추가',
            ),
          ),
          const Divider(height: 1, color: Colors.white10),
          Expanded(
            child: ValueListenableBuilder<List<Memo>>(
              valueListenable: memosListenable,
              builder: (context, memos, _) {
                if (memos.isEmpty) {
                  return const Center(child: Text('메모 없음', style: TextStyle(color: Colors.white24, fontSize: 12)));
                }
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: memos.length,
                  itemBuilder: (context, index) {
                    final m = memos[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                      child: _MemoItemWidget(memo: m, memoFontSize: memoFontSize, onEdit: () => onEditMemo(m)),
                    );
                  },
                );
              },
            ),
          ),
          const Divider(height: 1, color: Colors.white10),
          SizedBox(
            height: 40,
            child: Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: TextButton.icon(
                  onPressed: () async {
                    await showDialog(
                      context: context,
                      builder: (context) {
                        return AlertDialog(
                          backgroundColor: const Color(0xFF18181A),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          title: const Text('메모 목록', style: TextStyle(color: Colors.white)),
                          content: SizedBox(
                            width: 520,
                            height: 420,
                            child: ValueListenableBuilder<List<Memo>>(
                              valueListenable: memosListenable,
                              builder: (context, memos, _) {
                                if (memos.isEmpty) return const Center(child: Text('메모 없음', style: TextStyle(color: Colors.white54)));
                                return ListView.separated(
                                  itemCount: memos.length,
                                  separatorBuilder: (_, __) => const Divider(color: Colors.white10),
                                  itemBuilder: (context, i) {
                                    final m = memos[i];
                                    return ListTile(
                                      dense: true,
                                      title: Text(m.summary.isNotEmpty ? m.summary : m.original, style: const TextStyle(color: Colors.white)),
                                      subtitle: Row(
                                        children: [
                                          Text('${m.createdAt.month}/${m.createdAt.day}', style: const TextStyle(color: Colors.white54)),
                                          if (m.scheduledAt != null) ...[
                                            const SizedBox(width: 12),
                                            Text('일정 ${m.scheduledAt!.month}/${m.scheduledAt!.day} ${m.scheduledAt!.hour.toString().padLeft(2,'0')}:${m.scheduledAt!.minute.toString().padLeft(2,'0')}', style: const TextStyle(color: Colors.white38)),
                                          ]
                                        ],
                                      ),
                                      trailing: IconButton(
                                        icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                                        onPressed: () async {
                                          await DataManager.instance.deleteMemo(m.id);
                                        },
                                      ),
                                      onTap: () => onEditMemo(m),
                                    );
                                  },
                                );
                              },
                            ),
                          ),
                          actions: [
                            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('닫기', style: TextStyle(color: Colors.white70))),
                          ],
                        );
                      },
                    );
                  },
                  icon: const Icon(Icons.list, color: Colors.white70, size: 18),
                  label: const Text('list', style: TextStyle(color: Colors.white70)),
                  style: TextButton.styleFrom(foregroundColor: Colors.white70),
                ),
              ),
            ),
          ),
        ],
      ),
    ));
  }
}

class _MemoItemWidget extends StatefulWidget {
  final Memo memo;
  final double memoFontSize;
  final VoidCallback onEdit;
  const _MemoItemWidget({required this.memo, required this.memoFontSize, required this.onEdit});

  @override
  State<_MemoItemWidget> createState() => _MemoItemWidgetState();
}

class _MemoItemWidgetState extends State<_MemoItemWidget> {
  @override
  Widget build(BuildContext context) {
    final m = widget.memo;
    final content = InkWell(
      onTap: widget.onEdit,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 상단: 생성일 + 삭제 버튼
            Row(
              children: [
                Text(
                  '${m.createdAt.month}/${m.createdAt.day}',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '삭제',
                  onPressed: () async {
                    await DataManager.instance.deleteMemo(m.id);
                  },
                  icon: const Icon(Icons.close, size: 16, color: Colors.white38),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                )
              ],
            ),
            // 본문: 요약(없으면 원문)
            Text(
              (m.summary.isNotEmpty ? m.summary : m.original),
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white70, fontSize: widget.memoFontSize, height: 1.2),
            ),
          ],
        ),
      ),
    );

    if (m.scheduledAt != null) {
      final tooltip = '일정: ${m.scheduledAt!.month}/${m.scheduledAt!.day} ${m.scheduledAt!.hour.toString().padLeft(2, '0')}:${m.scheduledAt!.minute.toString().padLeft(2, '0')}';
      return Tooltip(message: tooltip, waitDuration: const Duration(milliseconds: 150), child: content);
    }
    return content;
  }
}

class _MemoInputDialog extends StatefulWidget {
  const _MemoInputDialog();
  @override
  State<_MemoInputDialog> createState() => _MemoInputDialogState();
}

class _MemoInputDialogState extends State<_MemoInputDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _saving = false;
  @override
  void dispose() { _controller.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      title: const Text('메모 추가', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 380,
        child: TextField(
          controller: _controller,
          minLines: 4,
          maxLines: 8,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: '메모를 입력하세요',
            hintStyle: TextStyle(color: Colors.white38),
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.of(context).pop(), child: const Text('취소', style: TextStyle(color: Colors.white70))),
        FilledButton(
          onPressed: _saving ? null : () { Navigator.of(context).pop(_controller.text); },
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
          child: const Text('저장'),
        ),
      ],
    );
  }
}

enum _MemoEditAction { save, delete }
class _MemoEditResult {
  final _MemoEditAction action;
  final String text;
  final DateTime? scheduledAt;
  const _MemoEditResult(this.action, this.text, {this.scheduledAt});
}

class _MemoEditDialog extends StatefulWidget {
  final String initial;
  final DateTime? initialScheduledAt;
  const _MemoEditDialog({required this.initial, this.initialScheduledAt});
  @override
  State<_MemoEditDialog> createState() => _MemoEditDialogState();
}

class _MemoEditDialogState extends State<_MemoEditDialog> {
  late TextEditingController _controller;
  bool _saving = false;
  DateTime? _scheduledAt;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
    _scheduledAt = widget.initialScheduledAt;
  }
  @override
  void dispose() { _controller.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      title: const Text('메모 보기/수정', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _controller,
              minLines: 6,
              maxLines: 12,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final now = DateTime.now();
                      final pickedDate = await showDatePicker(
                        context: context,
                        initialDate: _scheduledAt ?? now,
                        firstDate: now.subtract(const Duration(days: 1)),
                        lastDate: DateTime(now.year + 2),
                        builder: (context, child) => Theme(
                          data: Theme.of(context).copyWith(colorScheme: const ColorScheme.dark(primary: Color(0xFF1976D2)), dialogBackgroundColor: const Color(0xFF18181A)),
                          child: child!,
                        ),
                      );
                      if (pickedDate == null) return;
                      final pickedTime = await showTimePicker(
                        context: context,
                        initialTime: TimeOfDay.fromDateTime(_scheduledAt ?? now),
                        builder: (context, child) => Theme(
                          data: Theme.of(context).copyWith(colorScheme: const ColorScheme.dark(primary: Color(0xFF1976D2)), dialogBackgroundColor: const Color(0xFF18181A)),
                          child: child!,
                        ),
                      );
                      if (pickedTime == null) return;
                      setState(() {
                        _scheduledAt = DateTime(pickedDate.year, pickedDate.month, pickedDate.day, pickedTime.hour, pickedTime.minute);
                      });
                    },
                    icon: const Icon(Icons.event, size: 18),
                    label: Text(_scheduledAt == null ? '일정 없음' : '${_scheduledAt!.month}/${_scheduledAt!.day} ${_scheduledAt!.hour.toString().padLeft(2, '0')}:${_scheduledAt!.minute.toString().padLeft(2, '0')}'),
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.white70, side: const BorderSide(color: Colors.white24)),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () => setState(() => _scheduledAt = null),
                  tooltip: '일정 제거',
                  icon: const Icon(Icons.close, color: Colors.white38),
                )
              ],
            )
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.of(context).pop(), child: const Text('취소', style: TextStyle(color: Colors.white70))),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(const _MemoEditResult(_MemoEditAction.delete, '')),
          style: TextButton.styleFrom(foregroundColor: Colors.white, backgroundColor: Colors.red),
          child: const Text('삭제'),
        ),
        FilledButton(
          onPressed: _saving ? null : () async {
            setState(() => _saving = true);
            Navigator.of(context).pop(_MemoEditResult(_MemoEditAction.save, _controller.text, scheduledAt: _scheduledAt));
          },
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
          child: const Text('저장'),
        ),
      ],
    );
  }
}


class _MemoBanner extends StatelessWidget {
  final Memo memo;
  final VoidCallback? onClose;
  const _MemoBanner({required this.memo, this.onClose});

  @override
  Widget build(BuildContext context) {
    final double screenW = MediaQuery.of(context).size.width;
    // 최소창(≈1430)에서 14, 넓을수록 18까지 선형 증가
    const double minW = 1430;
    const double maxW = 2200;
    const double fsMin = 14;
    const double fsMax = 17; // 최대창 기준 1pt 감소
    final double t = ((screenW - minW) / (maxW - minW)).clamp(0.0, 1.0);
    final double bannerFontSize = fsMin + (fsMax - fsMin) * t;
    final when = memo.scheduledAt != null
        ? '${memo.scheduledAt!.month}/${memo.scheduledAt!.day} ${memo.scheduledAt!.hour.toString().padLeft(2, '0')}:${memo.scheduledAt!.minute.toString().padLeft(2, '0')}'
        : '';
    return Material(
      color: Colors.transparent,
      child: Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      constraints: const BoxConstraints(maxWidth: 360),
      decoration: BoxDecoration(
        color: const Color(0xFF232326),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.18), blurRadius: 12, offset: const Offset(0, 6)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (when.isNotEmpty)
                  Text(when, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 4),
                Text(
                  memo.summary.isNotEmpty ? memo.summary : memo.original,
                  style: TextStyle(color: Colors.white, fontSize: bannerFontSize, height: 1.3),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: onClose,
            child: const Padding(
              padding: EdgeInsets.all(4.0),
              child: Icon(Icons.close, color: Colors.white54, size: 18),
            ),
          )
        ],
      ),
      ),
    );
  }
}

 