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
import 'models/memo.dart';
import 'services/ai_summary.dart';
import 'dart:async';

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
  final maximize = prefs.getBool('fullscreen_enabled') ?? false;
  // 창을 보여주기 전에 최소/초기 크기를 먼저 적용해 즉시 제한이 걸리도록 처리
  // Surface Pro 12" (2196x1464 @150% → 1464x976) 의 95% 기준 최소 크기
  const Size kMinSize = Size(1430, 950);
  final windowOptions = WindowOptions(
    minimumSize: kMinSize,
    size: maximize ? null : kMinSize,
    center: !maximize,
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    if (maximize) {
      // 일부 플랫폼에서 show 직후 maximize 타이밍 이슈가 있어 약간 지연
      await Future.delayed(const Duration(milliseconds: 60));
      await windowManager.maximize();
    } else {
      await windowManager.center();
    }
    await windowManager.focus();
  });
  runApp(MyApp(maximizeOnStart: maximize));
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
      child: MaterialApp(
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
        home: Stack(
          children: const [
            MainScreen(),
            // 전역 메모 패널 오버레이
            _GlobalMemoOverlay(),
            _GlobalMemoFloatingBanners(),
          ],
        ),
        routes: {
          '/settings': (context) => const SettingsScreen(),
          '/students': (context) => const StudentScreen(),
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

  @override
  void initState() {
    super.initState();
    // 주기적으로 현재 시간을 반영해 표시 대상 갱신
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
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
          // 일정 시간이 도래(또는 지남)했고 닫지 않은 메모만 표시
          final upcoming = memos
              .where((m) => m.scheduledAt != null && !m.dismissed && !_sessionDismissed.contains(m.id) && _isSameDay(m.scheduledAt!, now))
              .toList()
            ..sort((a, b) => a.scheduledAt!.compareTo(b.scheduledAt!));
          if (upcoming.isEmpty) return const SizedBox.shrink();
          // 아래에서 위로 쌓기
          return Material(
            color: Colors.transparent,
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: upcoming.take(3).map((m) {
              return _MemoBanner(
                memo: m,
                onClose: () async {
                  // X 클릭 시: DB flag는 유지(dismissed=false)하고 세션만 닫음
                  setState(() {
                    _sessionDismissed.add(m.id);
                  });
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

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      const double panelWidth = 75;
      return Stack(children: [
        Positioned(
          right: 0,
          top: kToolbarHeight,
          bottom: 0,
          width: 24,
          child: MouseRegion(
            onEnter: (_) {
              _hoveringEdge = true;
              _setOpen(true);
              _cancelCloseTimer();
            },
            onExit: (_) {
              _hoveringEdge = false;
              _scheduleMaybeClose();
            },
            child: const SizedBox.shrink(),
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
              child: MouseRegion(
                onEnter: (_) {
                  _panelHovered = true;
                  _cancelCloseTimer();
                },
                onExit: (_) {
                  _panelHovered = false;
                  _scheduleMaybeClose();
                },
                child: _MemoPanel(
                  memosListenable: widget.memosListenable,
                  onAddMemo: () => widget.onAddMemo(context),
                  onEditMemo: (m) => widget.onEditMemo(context, m),
                ),
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
                      child: Tooltip(
                        message: m.summary.isNotEmpty ? m.summary : m.original,
                        waitDuration: const Duration(milliseconds: 200),
                        child: InkWell(
                          onTap: () => onEditMemo(m),
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: const Color(0xFF2A2A2A),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              m.original,
                              maxLines: 6,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white70, fontSize: 12, height: 1.2),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    ));
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
                  style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.3),
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

 